<#
.SYNOPSIS
    Build and query a cached unit-price table for Microsoft Foundry models,
    from the anonymous Azure Retail Prices API.

.DESCRIPTION
    An AI gateway that computes cost inline (tokens x unit price) needs a price
    table. This builds one safely.

    "Safely" is doing real work in that sentence. The Retail Prices API has
    several behaviours that quietly produce wrong numbers rather than errors,
    and a naive price table is worse than no price table: it produces confident,
    plausible, wrong invoices.

    THE CENTRAL PROBLEM: ONE MODEL HAS MANY PRICES

    gpt-oss-120B in a single region has seven distinct meters:

        gpt-oss-120B Inp glbl        0.15  /1M   <- Global Standard, input
        gpt-oss-120B Outp glbl       0.60  /1M   <- Global Standard, output
        gpt-oss-120B Inp DZone       0.165 /1M   <- Data Zone, input  (+10%)
        gpt-oss-120B Outp DZone      0.66  /1M   <- Data Zone, output (+10%)
        FW GPT OSS 120B Inp DZ       0.165 /1M   <- Fireworks-hosted
        FW GPT OSS 120B Outp DZ      0.66  /1M
        FW GPT OSS 120B Cache Inp DZ 0.082 /1M   <- cached input

    So a cache keyed on model name alone is ambiguous. Pick Data Zone when the
    deployment is actually Global and every cost figure is 10% high - not
    obviously broken, just steadily wrong.

    The key must be: model + scope + token kind + context tier + deployment type.

    VERIFIED PRICE RELATIONSHIPS (eastus2, Oct 2026)

        Data Zone   = Global x 1.10     Grok 4.3 input: 1.25 -> 1.375
        Long context= base   x 2.00     Grok 4.3 input: 1.25 -> 2.50
        Batch       = base   x 0.50     GPT 5.4 pro input: 30 -> 15
        Cached input= roughly 16% of input (varies by model; never assume)

    These are observations, not contracts. The table reads actual meters.

.NOTES
    The Retail Prices API is anonymous: no auth, no subscription context.
    That means prices are LIST prices. If you have an EA, MACC or negotiated
    discount, your real rate is lower. See the IsListPrice flag on the table.
#>

# ---------------------------------------------------------------------------
# Meter-name vocabulary.
#
# meterName is abbreviated, inconsistent between model families, and in one
# case actively misleading: 'opt' means OUTPUT, not "optional" or "optimised".
# A parser that guesses will mis-key output tokens and silently under-bill,
# because output is typically 4-6x the input rate.
#
# The naming is NOT tokenised consistently, so matching on whitespace-split
# tokens is too brittle. All four of these appear in one region:
#
#     ... Inp DZone Tokens          single token
#     ... Inp Data Zone Tokens      TWO words
#     ... BatchOutp DataZone Tokens concatenated, and one-word DataZone
#     ... txt-out-glbl Tokens       hyphen separated, 'out' not 'outp'
#
# So matching is regex-based against the whole normalised name, with word
# boundaries where a short token could otherwise match inside another word.
# ---------------------------------------------------------------------------

# Order matters, first match wins.
#   CacheWrite before CachedInput: a cache-write meter reads 'Cd Wr', which also
#     contains the cached marker. These are NOT the same price - verified on
#     gpt-5.6-sol long context: Cd Wr = $20.00/1M, Cd Inp = $1.60/1M. 12.5x apart.
#     Collapsing them into one Kind makes the cache key collide and the winner
#     arbitrary, so cache reads can be billed at 12.5x or writes at 1/12.5x.
#   CachedInput before Input: a cached-input meter also contains 'Inp'.
# Cached has four spellings in the wild: cach, cchd, cched, cd.
$script:KindPatterns = [ordered]@{
    'CacheWrite'  = 'cache\s*write|\bwr\b|\bcw\b'
    'CachedInput' = 'cach|cchd|cched|\bcd\b'
    'Output'      = 'outp|output|\bout\b|\bopt\b'
    'Input'       = 'inp|input|\bin\b'
}

# Data Zone has FIVE spellings: 'Data Zone', 'DataZone', 'DZone', 'DZn', 'DZ'.
# Any one missed silently falls through to the Global default, a 10% under-bill
# (verified: gpt-4.1 Global $2.00 vs Data Zone $2.20).
$script:ScopePatterns = [ordered]@{
    'DataZone' = 'data\s*zone|dzone|\bdzn\b|\bdz\b'
    'Regional' = 'regnl|regional|\brgnl\b'
    'Global'   = 'glbl|global|\bgl\b'
}

# Publishers that do not bill through the Retail Prices API at all.
# Anthropic / Claude bills through Azure Marketplace in Claude Consumption Units
# (CCU), so a missing meter is CORRECT for these - not a coverage gap. A gateway
# that reads "no meter" as "free" would bill nothing for Claude traffic.
#
# CCU is a single Marketplace meter with NO per-model dimension, which means
# per-Claude-model cost cannot be derived from Cost Management either. Token
# counts remain exact and come from Azure Monitor or the inference response;
# only the per-model DOLLAR figure is unavailable. See:
#   https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing
$script:NonRetailPublishers = @('Anthropic')

# model.format (publisher) -> Retail Prices productName prefixes
$script:FamilyMap = @{
    'OpenAI'     = @('Azure OpenAI')     # prefix: covers GPT5, GPT6, Reasoning, Embedding, Media
    'OpenAI-OSS' = @('Azure OpenAI OSS Models')
    'DeepSeek'   = @('Azure Deepseek Models')   # lowercase 's' - deliberate
    'xAI'        = @('Azure Grok Models')
    'Meta'       = @('Azure Llama Models')
    'Mistral AI' = @('Azure Mistral Models')
    'MoonshotAI' = @('Azure Kimi')
    'Alibaba'    = @('Qwen models')
    'Cohere'     = @('Cohere Models')
    'Microsoft'  = @('MAI Models', 'Azure Phi Models')
    'Fireworks'  = @('Azure Fireworks Models')
}


function ConvertTo-MeterAttributes {
    <#
    .SYNOPSIS
        Parse one meterName into structured pricing attributes.
    #>
    param([string] $MeterName, [string] $UnitOfMeasure, [double] $RetailPrice)

    # Normalise separators so hyphenated and concatenated forms behave the same.
    $n = ($MeterName -replace '[\-_]', ' ' -replace '\s+', ' ').Trim().ToLowerInvariant()

    $scope = 'Global'      # meters carrying no scope marker are Global in practice
    foreach ($s in $script:ScopePatterns.Keys) {
        if ($n -match $script:ScopePatterns[$s]) { $scope = $s; break }
    }

    $kind = $null
    foreach ($k in $script:KindPatterns.Keys) {
        if ($n -match $script:KindPatterns[$k]) { $kind = $k; break }
    }

    # Context tier. Abbreviated as LoCo / ShCo as well as LongCo / ShortCo, and
    # a bare 'l'. Long context is verified at exactly 2x base, so a missed
    # marker is a 50% under-bill.
    $contextTier = 'Standard'
    if     ($n -match 'longco|\bloco\b|\blong\b|\bl\b')  { $contextTier = 'Long' }
    elseif ($n -match 'shortco|\bshco\b|\bshort\b')      { $contextTier = 'Short' }

    # Service / deployment tier. Batch is verified at exactly 50% of standard.
    # 'PP' is Priority Processing, verified at exactly 2x standard across all
    # four kinds - it is NOT Provisioned/PTU. PTU is capacity billed hourly
    # ('1/Hour'), so it never appears as a per-token meter at all.
    # 'Flex' / 'Fl' is a third tier and must not collide with Standard.
    $deploymentType = 'Standard'
    if     ($n -match 'batch')                       { $deploymentType = 'Batch' }
    elseif ($n -match '\bflex\b|\bfl\b')             { $deploymentType = 'Flex' }
    elseif ($n -match '\bpp\b')                      { $deploymentType = 'Priority' }
    elseif ($n -match '\bft\b|finetuned|fine tuned') { $deploymentType = 'FineTuned' }

    # Host: Fireworks-hosted meters are prefixed FW and are a different SKU
    # from the Azure-direct model of the same name.
    $host_ = if ($n -match '^fw\b|\bfw\b') { 'Fireworks' } else { 'AzureDirect' }

    # Purpose. Fine-tuning *grader* meters price evaluation runs, not inference.
    # They sit alongside real inference meters for the same model and would
    # otherwise be a candidate for an ordinary chat lookup.
    $purpose = if ($n -match '\bgrdr\b|\bgrader\b') { 'Grader' } else { 'Inference' }

    # Modality - non-text meters must not be used for chat token maths.
    # Audio meters carry a date suffix ('aud1217', 'aud 0828'), so a bare \baud\b
    # misses them and they default to Text - an $11/1M audio meter then becomes a
    # candidate for a text chat lookup.
    $modality = 'Text'
    if     ($n -match '\bimg\b|\bimage\b')  { $modality = 'Image' }
    elseif ($n -match '\brt\b|realtime')    {
        $modality = if ($n -match '\baud\d*\b|\baudio\b') { 'RealtimeAudio' } else { 'Realtime' }
    }
    elseif ($n -match '\baud\d*\b|\baudio\b|\btts\b|trscb|tcrb|transcribe') { $modality = 'Audio' }

    # Normalise price to USD per 1M tokens, honouring unitOfMeasure per row.
    # Token meters are '1K' or '1M'; PTU is '1/Hour'; reservations are '1/Month'.
    # A blanket multiplier misreports the non-token meters by 1000x.
    $per1M = switch -Regex ($UnitOfMeasure) {
        '^1K' { $RetailPrice * 1000 ; break }
        '^1M' { $RetailPrice        ; break }
        default { $null }      # not token-denominated: exclude from the table
    }

    [pscustomobject]@{
        Scope          = $scope
        Kind           = $kind
        ContextTier    = $contextTier
        DeploymentType = $deploymentType
        Host           = $host_
        Modality       = $modality
        Purpose        = $purpose
        PricePer1M     = if ($null -ne $per1M) { [math]::Round($per1M, 8) } else { $null }
        IsTokenMeter   = ($null -ne $per1M)
    }
}


function Build-FoundryPriceTable {
    <#
    .SYNOPSIS
        Fetch and cache the unit-price table for a region.

    .DESCRIPTION
        Call this on a schedule (daily is plenty - prices change rarely) and
        persist the result. Do NOT call it per request.

    .EXAMPLE
        $table = Build-FoundryPriceTable -Region eastus2 -CachePath .\prices.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Region,
        [string] $CachePath,
        [int]    $MaxAgeHours = 24,
        [switch] $Force
    )

    # Serve from cache when fresh enough.
    if ($CachePath -and -not $Force -and (Test-Path $CachePath)) {
        try {
            $cached = Get-Content $CachePath -Raw | ConvertFrom-Json
            $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($cached.BuiltAtUtc).ToUniversalTime()
            if ($age.TotalHours -lt $MaxAgeHours -and $cached.Region -eq $Region) {
                Write-Verbose "Price cache hit ($([math]::Round($age.TotalHours,1))h old)"
                return $cached
            }
        } catch { Write-Warning "Price cache unreadable, rebuilding: $($_.Exception.Message)" }
    }

    # GOTCHA 1: serviceName is 'Foundry Models'. The old 'Cognitive Services'
    # value returns HTTP 200 with zero rows - a silent failure, not an error.
    $filter = "serviceName eq 'Foundry Models' and armRegionName eq '$Region' and contains(meterName,'Tokens')"
    $uri    = "https://prices.azure.com/api/retail/prices?`$filter=" + [uri]::EscapeDataString($filter)

    $raw  = [System.Collections.Generic.List[object]]::new()
    $next = $uri
    $fail = 0
    while ($next) {
        try {
            $page = Invoke-RestMethod -Uri $next -TimeoutSec 60 -ErrorAction Stop
            foreach ($i in $page.Items) { $raw.Add($i) }
            $next = $page.NextPageLink
            $fail = 0
        }
        catch {
            # Throw rather than return a partial table. A half-built cache looks
            # like genuine missing coverage and would under-bill silently.
            if (++$fail -gt 4) { throw "Retail Prices API failed after $fail attempts: $($_.Exception.Message)" }
            Start-Sleep -Seconds 12
        }
    }

    if ($raw.Count -eq 0) {
        throw "Retail Prices returned zero rows for '$Region'. If you changed the filter, check serviceName is 'Foundry Models' - the old 'Cognitive Services' value returns an empty 200."
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $raw) {
        $attr = ConvertTo-MeterAttributes -MeterName $item.meterName `
                    -UnitOfMeasure $item.unitOfMeasure -RetailPrice $item.retailPrice
        if (-not $attr.IsTokenMeter) { continue }   # drop 1/Hour, 1/Month
        if (-not $attr.Kind)         { continue }   # drop meters we cannot classify

        $entries.Add([pscustomobject]@{
            ProductName    = $item.productName
            MeterName      = $item.meterName
            SkuName        = $item.skuName
            Scope          = $attr.Scope
            Kind           = $attr.Kind
            ContextTier    = $attr.ContextTier
            DeploymentType = $attr.DeploymentType
            Host           = $attr.Host
            Modality       = $attr.Modality
            Purpose        = $attr.Purpose
            UnitOfMeasure  = $item.unitOfMeasure
            RetailPrice    = $item.retailPrice
            PricePer1M     = $attr.PricePer1M
        })
    }

    $table = [pscustomobject]@{
        Region       = $Region
        BuiltAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        MeterCount   = $entries.Count
        RawRowCount  = $raw.Count
        Entries      = $entries

        # Surfaced in the data structure itself so downstream code cannot forget.
        IsListPrice  = $true
        PriceBasis   = 'Azure Retail Prices API (anonymous). LIST prices only - no EA, MACC or negotiated discount is reflected. Reconcile against Cost Management before using for external billing.'
        SourceUrl    = 'https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices'
    }

    if ($CachePath) {
        $table | ConvertTo-Json -Depth 6 | Set-Content $CachePath -Encoding UTF8
        Write-Verbose "Price table cached to $CachePath ($($entries.Count) meters)"
    }

    $table
}


function Get-TokenPrice {
    <#
    .SYNOPSIS
        Look up the unit price for one model + deployment + token kind.

    .DESCRIPTION
        NEVER returns 0 for an unknown model. Returns a Status so the caller
        must decide what to do. Treating "no meter" as "free" is the single
        most expensive mistake available here - it bills nothing for real usage.

        Status values:
          Priced                  price is usable
          NoMeter                 model has no published meter: COVERAGE GAP
          BilledOutsideRetailAPI  publisher bills via Marketplace (e.g. Anthropic).
                                  Absence is correct. Do NOT treat as free.
          UnknownPublisher        not in the family map; no verdict claimed
          Ambiguous               several candidate meters, none decisive

    .EXAMPLE
        $p = Get-TokenPrice -Table $t -ModelName 'gpt-oss-120b' `
                 -Publisher 'OpenAI-OSS' -Sku 'GlobalStandard' -Kind Input
        if ($p.Status -ne 'Priced') { ... handle, do not assume zero ... }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][string] $ModelName,
        [string] $Publisher,
        [string] $Sku = 'GlobalStandard',
        [string] $ModelVersion,
        [Parameter(Mandatory)][ValidateSet('Input','Output','CachedInput','CacheWrite')][string] $Kind,
        [ValidateSet('Standard','Long','Short')][string] $ContextTier = 'Standard',
        [ValidateSet('Text','Image','Audio','Realtime','RealtimeAudio')][string] $Modality = 'Text',
        [ValidateSet('Inference','Grader')][string] $Purpose = 'Inference'
    )

    function New-Result($status, $price, $meter, $note) {
        [pscustomobject]@{
            ModelName   = $ModelName
            Kind        = $Kind
            Sku         = $Sku
            Status      = $status
            PricePer1M  = $price      # $null unless Status -eq 'Priced'
            MeterName   = $meter
            Note        = $note
            IsListPrice = $Table.IsListPrice
        }
    }

    if ($Publisher -and $Publisher -in $script:NonRetailPublishers) {
        return New-Result 'BilledOutsideRetailAPI' $null $null `
            "$Publisher bills through Azure Marketplace in Claude Consumption Units (CCU). No Retail Prices meter exists and that is correct. CCU is a single meter with no per-model dimension, so Cost Management cannot break cost down per model either - do not expect to reconcile this model's dollars. Token counts are still exact from Azure Monitor. Rates: https://aka.ms/ccu-pricing"
    }

    # Derive scope and deployment type from the deployment SKU.
    $scope = switch -Regex ($Sku) {
        'DataZone'  { 'DataZone'; break }
        'Global'    { 'Global';   break }
        default     { 'Regional' }
    }
    # Provisioned (PTU) is capacity billed per hour, not per token. There is no
    # per-token retail meter to find, so searching for one and returning NoMeter
    # would read as a coverage gap. Say what it actually is.
    if ($Sku -match 'Provisioned|PTU') {
        return New-Result 'BilledAsCapacity' $null $null `
            "SKU '$Sku' is provisioned throughput: billed per PTU per hour ('1/Hour'), not per token. Token counts are still useful for utilisation, but cost comes from the PTU reservation - not from this table."
    }

    $depType = switch -Regex ($Sku) {
        'Batch'    { 'Batch';     break }
        'Flex'     { 'Flex';      break }
        'Priority' { 'Priority';  break }
        default    { 'Standard' }
    }

    $candidates = $Table.Entries | Where-Object {
        $_.Kind           -eq $Kind        -and
        $_.Scope          -eq $scope       -and
        $_.ContextTier    -eq $ContextTier -and
        $_.DeploymentType -eq $depType     -and
        $_.Modality       -eq $Modality    -and
        $_.Purpose        -eq $Purpose     -and
        $_.Host           -eq 'AzureDirect'
    }

    # Narrow to this model. meterName carries abbreviations, not model IDs, so
    # match on the distinctive version token rather than the whole name.
    # A bare substring match is dangerous: '3' from 'qwen3-32b' matches
    # 'o3 mini ... Tokens', producing a confident wrong price.
    if ($Publisher -and $script:FamilyMap.ContainsKey($Publisher)) {
        $fams = $script:FamilyMap[$Publisher]
        $candidates = $candidates | Where-Object {
            $pn = $_.ProductName
            ($fams | Where-Object { $pn -like "$_*" }).Count -gt 0
        }
    }
    elseif ($Publisher) {
        return New-Result 'UnknownPublisher' $null $null `
            "Publisher '$Publisher' is not in the family map. No verdict claimed - add it rather than assuming a price."
    }

    # Narrow to this model. meterName carries abbreviations, not model IDs, so
    # match on the distinctive version token rather than the whole name.
    #
    # Substring matching is NOT safe here, in both directions:
    #   '20' from gpt-oss-20b is a substring of 'gpt-oss-120B'   -> 4x   wrong
    #   '4'  from gpt-4o      is a token of    'gpt-4-turbo128K' -> 3.2x wrong
    #   '1'  from DeepSeek-R1 sits inside      'V3.1 Inp glbl'   -> 9%   wrong
    #
    # So the token keeps BOTH a glued letter prefix and any trailing letters -
    # 'R1', 'V3.2', 'K2', 'o3', '4o', '20b' - because for these publishers the
    # letter is part of the version spelling, not a separate word. The match is
    # then anchored on both sides against digits, letters AND '.', so a token
    # can never match a fragment of a longer version.
    $verMatch = [regex]::Match($ModelName, '(?<![A-Za-z])([A-Za-z]?\d+(?:\.\d+)*[A-Za-z]*)')
    if ($verMatch.Success) {
        $tok = $verMatch.Value
        $mkAnchor = { param($s) '(?<![0-9A-Za-z.])' + [regex]::Escape($s) + '(?![0-9A-Za-z.])' }
        $anchored = & $mkAnchor $tok

        # Flex-tier meters drop the dot from the version ('54 inp Flex Gl' for
        # gpt-5.4), so a dotted token can never reach them. Try the dot-stripped
        # form as a fallback - still anchored, so it cannot match a fragment.
        $alt = if ($tok -match '\.') { & $mkAnchor ($tok -replace '\.', '') } else { $null }

        $narrowed = @($candidates | Where-Object {
            $mn = ($_.MeterName -replace '[\-_]', ' ')
            ($mn -match $anchored) -or ($alt -and $mn -match $alt)
        })
        if ($narrowed) { $candidates = @($narrowed) }
        else {
            # Distinguish a genuine coverage gap from a query mismatch. If the
            # model has meters at a DIFFERENT context tier or deployment type,
            # say so - the newest models (5.5, 5.6, 6.x) have no Standard-tier
            # meter at all and are priced only in Short/Long context bands.
            $elsewhere = @($Table.Entries | Where-Object {
                $_.Kind -eq $Kind -and $_.Host -eq 'AzureDirect' -and
                $(($_.MeterName -replace '[\-_]',' ') -match $anchored)
            })
            if ($elsewhere.Count -gt 0) {
                $tiers = ($elsewhere.ContextTier    | Sort-Object -Unique) -join '/'
                $types = ($elsewhere.DeploymentType | Sort-Object -Unique) -join '/'
                $scopes= ($elsewhere.Scope          | Sort-Object -Unique) -join '/'
                return New-Result 'NoMeter' $null $null `
                    "No meter for model=$ModelName at scope=$scope tier=$ContextTier type=$depType kind=$Kind, but $($elsewhere.Count) meters DO exist for it at scope=$scopes tier=$tiers type=$types. This is most likely a query mismatch rather than a coverage gap - the newest models have no Standard context tier and must be priced as Short or Long. Do NOT bill this as zero."
            }
            return New-Result 'NoMeter' $null $null `
                "No meter matches version token '$tok' for this model in scope=$scope kind=$Kind. This is a real coverage gap - models can be deployable and GA with no published price. Do NOT bill this as zero."
        }
    }
    else {
        # No version token at all ('whisper', 'gpt-realtime', 'model-router').
        # There is nothing left to discriminate on: the variant filter alone
        # would happily match any no-variant meter, which is how these models
        # ended up priced from '5.5 ShortCo inp Gl' at $5.00. Refuse instead.
        return New-Result 'NoMeter' $null $null `
            "Model '$ModelName' carries no version token, so it cannot be matched against abbreviated meter names without guessing. Meters for such models must be mapped explicitly. Do NOT bill this as zero."
    }

    # Variant disambiguation. The version token alone is not enough: 'gpt-5.4'
    # matches the meters for 5.4, 5.4 pro, 5.4 mini and 5.4 nano, whose prices
    # differ by an order of magnitude. Require the variant to match on BOTH
    # sides - the base model must not silently pick up a 'pro' meter.
    #
    # 'opt' must NOT appear here: it is the OUTPUT marker, not a variant.
    # Listing it gave every output meter a phantom variant that could never
    # match a model name, so $exact was always empty and disambiguation
    # silently disabled itself for every output lookup - reopening the trap.
    # Values are regex alternations because meters abbreviate ('mini' -> 'mn').
    $variantAliases = [ordered]@{
        'pro'   = 'pro';   'mini' = 'mini|mn'; 'nano'  = 'nano'
        'codex' = 'codex'; 'flash'= 'flash';   'lite'  = 'lite'
        'turbo' = 'turbo'; 'sol'  = 'sol';     'luna'  = 'luna'
        'terra' = 'terra'; 'astra'= 'astra';   'chat'  = 'chat'
        'reasoning' = 'reasoning'; 'mm' = 'mm|multimodal'
        'research'  = 'research|deep research'
        'medium' = 'medium'; 'large' = 'large'; 'small' = 'small'
    }

    # Collect ALL variant markers on each side and compare as sets. Stopping at
    # the first hit loses information when a name carries two markers:
    # 'Phi-4-Mini MM-Input' is both 'mini' AND 'mm', and reducing it to 'mini'
    # alone made it mismatch 'Phi-4-multimodal-instruct' - so the correct $0.08
    # meter was discarded in favour of the plain Phi-4 meter at $0.125.
    function Get-VariantSet([string] $Text, $Aliases) {
        $t = $Text.ToLowerInvariant() -replace '[\-_]', ' '
        $found = [System.Collections.Generic.SortedSet[string]]::new()
        foreach ($v in $Aliases.Keys) {
            if ($t -match "(^|\s)($($Aliases[$v]))(\s|$)") { [void]$found.Add($v) }
        }
        ($found -join '+')
    }

    $modelVariant = Get-VariantSet $ModelName $variantAliases

    $exact = @($candidates | Where-Object {
        (Get-VariantSet $_.MeterName $variantAliases) -eq $modelVariant
    })

    # The filter is applied unconditionally. An earlier version did
    # `if ($exact) { $candidates = $exact }`, which meant an EMPTY result
    # silently bypassed the filter and left every variant meter in play - so a
    # base model could be priced from a variant's meter:
    #   gpt-5.3 -> '5.3 codex inp Gl'        (model has no variant, meter does)
    #   gpt-4o-mini -> 'gpt-4-turbo128K Inp' (model has a variant, meter does not)
    # An empty set means "no meter matches this model's variant", which is a
    # NoMeter answer, not a licence to guess.
    if ($exact.Count -eq 0) {
        $offered = @($candidates | Select-Object -ExpandProperty MeterName -First 4) -join ' | '
        $want = if ($modelVariant) { "variant '$modelVariant'" } else { 'the base model (no variant)' }
        $vt   = if ($verMatch.Success) { "Version token '$($verMatch.Value)'" } else { 'The model name' }
        return New-Result 'NoMeter' $null $null `
            "$vt matched $($candidates.Count) meter(s) at scope=$scope tier=$ContextTier type=$depType, but none is for $want - closest were: $offered. Billing from a different variant can be an order of magnitude out, so no price is claimed. Do NOT bill this as zero."
    }
    $candidates = @($exact)

    if ($candidates.Count -gt 1) {
        # Dated meters: gpt-4o ships as 0513 / 0806 / 1120 and those prices
        # differ 2x ($5.00 vs $2.50). The model NAME cannot tell them apart, so
        # if the caller knows the deployed version, use it. Azure Monitor exposes
        # this as the ModelVersion dimension and the ARM catalog as Version.
        if ($ModelVersion) {
            # Catalog version strings are not uniform: '2024-11-20',
            # 'turbo-2024-04-09', '2024-08-06-preview', '001', 'latest'.
            # Pull MMDD from anywhere in the string rather than anchoring, and
            # say so when it cannot be used - the caller supplied disambiguating
            # information and deserves to know it was ignored.
            $mmdd = if ($ModelVersion -match '(\d{2})-(\d{2})(?!\d)') { "$($Matches[1])$($Matches[2])" }
                    elseif ($ModelVersion -match '^\d{4}$')           { $ModelVersion }
                    else { $null }
            if ($mmdd) {
                $dated = @($candidates | Where-Object {
                    ($_.MeterName -replace '[\-_]',' ') -match "(?<![0-9])$mmdd(?![0-9])"
                })
                if ($dated.Count -gt 0) { $candidates = $dated }
                else { Write-Verbose "ModelVersion '$ModelVersion' parsed to '$mmdd' but matched no meter; ignoring." }
            }
            else {
                Write-Warning "ModelVersion '$ModelVersion' is not in a form this lookup can use (expects YYYY-MM-DD or MMDD). Ignoring it - the result may be Ambiguous."
            }
        }
    }

    if ($candidates.Count -gt 1) {
        $distinct = @($candidates.PricePer1M | Sort-Object -Unique)
        if ($distinct.Count -eq 1) {
            return New-Result 'Priced' $distinct[0] $candidates[0].MeterName `
                "$($candidates.Count) meters matched, all at the same price."
        }
        $hint = if (-not $ModelVersion) { " If these are version-dated meters (e.g. 0513 / 0806 / 1120), pass -ModelVersion to pick one." } else { '' }
        return New-Result 'Ambiguous' $null ($candidates.MeterName -join ' | ') `
            "$($candidates.Count) meters matched with $($distinct.Count) different prices: $($distinct -join ', '). Narrow by ContextTier or Modality rather than guessing.$hint"
    }

    New-Result 'Priced' $candidates[0].PricePer1M $candidates[0].MeterName $null
}


function Get-UnpricedModels {
    <#
    .SYNOPSIS
        List models that are deployable in a region but have no usable price.

    .DESCRIPTION
        Run this after building the table and before trusting any cost figure.
        A model can be deployable, Generally Available, consuming quota, and
        have no published meter - verified on a real GA model.

        Treat the output as an operational alert, not a report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)] $Catalog   # from Get-FoundryModelCatalog
    )

    foreach ($m in $Catalog) {
        $r = Get-TokenPrice -Table $Table -ModelName $m.Name -Publisher $m.Publisher `
                 -Sku 'GlobalStandard' -Kind Input -ErrorAction SilentlyContinue
        if ($r.Status -ne 'Priced') {
            [pscustomobject]@{
                Model     = $m.Name
                Version   = $m.Version
                Publisher = $m.Publisher
                Lifecycle = $m.Lifecycle
                Status    = $r.Status
                Note      = $r.Note
            }
        }
    }
}


function Measure-RequestCost {
    <#
    .SYNOPSIS
        Cost one metered request. Returns $null cost - never 0 - when any
        required price is unavailable.

    .EXAMPLE
        Measure-RequestCost -Table $t -ModelName 'gpt-oss-120b' `
            -Publisher 'OpenAI-OSS' -Sku GlobalStandard `
            -InputTokens 1500 -CachedTokens 1000 -OutputTokens 300

    .EXAMPLE
        # The newest models (5.5, 5.6, 6.x) have NO Standard-tier meter - they
        # are priced only in Short/Long context bands, which differ by 2x. You
        # must say which band the request fell into.
        Measure-RequestCost -Table $t -ModelName 'gpt-6-astra' `
            -Publisher 'OpenAI' -Sku GlobalStandard -ContextTier Short `
            -InputTokens 1000 -OutputTokens 500
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][string] $ModelName,
        [string] $Publisher,
        [string] $Sku = 'GlobalStandard',
        [string] $ModelVersion,
        [ValidateSet('Standard','Long','Short')][string] $ContextTier = 'Standard',
        [ValidateSet('Text','Image','Audio','Realtime','RealtimeAudio')][string] $Modality = 'Text',
        [int] $InputTokens      = 0,
        [int] $CachedTokens     = 0,
        [int] $CacheWriteTokens = 0,
        [int] $OutputTokens     = 0
    )

    $common = @{
        Table = $Table; ModelName = $ModelName; Publisher = $Publisher
        Sku = $Sku; ContextTier = $ContextTier; Modality = $Modality
    }
    if ($ModelVersion) { $common.ModelVersion = $ModelVersion }

    $inP  = Get-TokenPrice @common -Kind Input
    $outP = Get-TokenPrice @common -Kind Output

    # Cached input is optional: many models have no cached meter, in which case
    # cached tokens bill at the standard input rate.
    $cacP = $null
    if ($CachedTokens -gt 0) {
        $cacP = Get-TokenPrice @common -Kind CachedInput
    }

    # Cache WRITE is a separate, far more expensive meter (verified 12.5x the
    # cache-read rate). If the caller reports write tokens we must not bill them
    # at the read rate, and we must not silently drop them either.
    $cwP = $null
    if ($CacheWriteTokens -gt 0) {
        $cwP = Get-TokenPrice @common -Kind CacheWrite
        if ($cwP.Status -ne 'Priced') {
            return [pscustomobject]@{
                ModelName   = $ModelName
                CostUSD     = $null
                Status      = "Unpriced: cacheWrite=$($cwP.Status)"
                Note        = "CacheWriteTokens were supplied but no cache-write meter resolved. Billing them at the read rate would understate cost by roughly 12x, so no cost is claimed. $($cwP.Note)"
                IsListPrice = $Table.IsListPrice
            }
        }
    }

    if ($inP.Status -ne 'Priced' -or $outP.Status -ne 'Priced') {
        return [pscustomobject]@{
            ModelName   = $ModelName
            CostUSD     = $null          # explicitly null, never 0
            Status      = "Unpriced: input=$($inP.Status) output=$($outP.Status)"
            Note        = ($inP.Note, $outP.Note | Where-Object { $_ }) -join ' / '
            IsListPrice = $Table.IsListPrice
        }
    }

    # prompt_tokens already includes cached tokens, so bill the remainder at the
    # standard input rate and the cached portion at the cached rate.
    # Integer division is not a risk here: PowerShell's / on int operands yields
    # a double, so 1000/1000000 is 0.001 and not 0.
    $billableIn = [math]::Max(0, $InputTokens - $CachedTokens)
    $cachedRate = if ($cacP -and $cacP.Status -eq 'Priced') { $cacP.PricePer1M } else { $inP.PricePer1M }
    $cwRate     = if ($cwP) { $cwP.PricePer1M } else { $null }

    $cost = ($billableIn   / 1000000 * $inP.PricePer1M) +
            ($CachedTokens / 1000000 * $cachedRate) +
            ($OutputTokens / 1000000 * $outP.PricePer1M)
    if ($CacheWriteTokens -gt 0) { $cost += ($CacheWriteTokens / 1000000 * $cwRate) }

    [pscustomobject]@{
        ModelName    = $ModelName
        CostUSD      = [math]::Round($cost, 8)
        Status       = 'Priced'
        ContextTier  = $ContextTier
        InputRate1M  = $inP.PricePer1M
        CachedRate1M = $cachedRate
        CacheWriteRate1M = $cwRate
        OutputRate1M = $outP.PricePer1M
        CachedRateIsFallback = -not ($cacP -and $cacP.Status -eq 'Priced')
        IsListPrice  = $Table.IsListPrice
    }
}

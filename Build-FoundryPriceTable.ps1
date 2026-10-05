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
# A parser that guesses will mis-key output tokens as something else and
# silently under-bill, because output is typically 4-6x the input rate.
# ---------------------------------------------------------------------------

$script:ScopeTokens = @{
    'glbl' = 'Global'; 'gl' = 'Global'; 'global' = 'Global'
    'dz'   = 'DataZone'; 'dzone' = 'DataZone'
    'regnl'= 'Regional'; 'regional' = 'Regional'
}

$script:KindTokens = @{
    'inp'    = 'Input';  'input' = 'Input'
    'outp'   = 'Output'; 'output' = 'Output'
    'opt'    = 'Output'      # NOT "optional" - verified against price ratios
    'cached' = 'CachedInput'; 'cache' = 'CachedInput'
    'cchd'   = 'CachedInput'; 'cd' = 'CachedInput'
}

# Publishers that do not bill through the Retail Prices API at all.
# Anthropic / Claude is Marketplace / committed-consumption billed, so a missing
# meter is CORRECT for these - not a coverage gap. A gateway that reads
# "no meter" as "free" would bill nothing for Claude traffic.
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

    $words = $MeterName -split '[\s\-]+' | Where-Object { $_ }
    $lower = $words | ForEach-Object { $_.ToLowerInvariant() }

    $scope = 'Global'      # meters with no scope token are Global in practice
    $kind  = $null
    foreach ($w in $lower) {
        if ($script:ScopeTokens.ContainsKey($w)) { $scope = $script:ScopeTokens[$w] }
        # First kind token wins: "Cached Inp" must resolve to CachedInput,
        # not be overwritten by the Inp that follows it.
        if (-not $kind -and $script:KindTokens.ContainsKey($w)) { $kind = $script:KindTokens[$w] }
    }
    # "Cached Inp" / "Cache Inp" - the cached marker precedes the input marker
    if ($lower -contains 'cached' -or $lower -contains 'cache' -or $lower -contains 'cchd') {
        $kind = 'CachedInput'
    }

    # Context tier. A bare 'L' token means long context (verified: exactly 2x base).
    $contextTier = 'Standard'
    if ($lower -contains 'longco' -or $lower -contains 'l') { $contextTier = 'Long' }
    elseif ($lower -contains 'shortco')                     { $contextTier = 'Short' }

    # Deployment type. Batch is verified at exactly 50% of standard.
    $deploymentType = 'Standard'
    if     ($lower -contains 'batch') { $deploymentType = 'Batch' }
    elseif ($lower -contains 'pp')    { $deploymentType = 'Provisioned' }
    elseif ($lower -contains 'ft')    { $deploymentType = 'FineTuned' }

    # Host: Fireworks-hosted meters are prefixed FW and are a different SKU
    # from the Azure-direct model of the same name.
    $host_ = if ($lower -contains 'fw') { 'Fireworks' } else { 'AzureDirect' }

    # Modality - non-text meters must not be used for chat token maths.
    $modality = 'Text'
    if     ($lower -contains 'img' -or $lower -contains 'image') { $modality = 'Image' }
    elseif ($lower -contains 'aud' -or $lower -contains 'audio') { $modality = 'Audio' }
    elseif ($lower -contains 'rt')                               { $modality = 'Realtime' }

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
        [Parameter(Mandatory)][ValidateSet('Input','Output','CachedInput')][string] $Kind,
        [ValidateSet('Standard','Long','Short')][string] $ContextTier = 'Standard',
        [ValidateSet('Text','Image','Audio','Realtime')][string] $Modality = 'Text'
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
            "$Publisher bills through Marketplace / committed consumption. No Retail Prices meter exists and that is correct. Source cost from Cost Management, not from this table."
    }

    # Derive scope and deployment type from the deployment SKU.
    $scope = switch -Regex ($Sku) {
        'DataZone'  { 'DataZone'; break }
        'Global'    { 'Global';   break }
        default     { 'Regional' }
    }
    $depType = switch -Regex ($Sku) {
        'Batch'       { 'Batch';       break }
        'Provisioned' { 'Provisioned'; break }
        default       { 'Standard' }
    }

    $candidates = $Table.Entries | Where-Object {
        $_.Kind           -eq $Kind        -and
        $_.Scope          -eq $scope       -and
        $_.ContextTier    -eq $ContextTier -and
        $_.DeploymentType -eq $depType     -and
        $_.Modality       -eq $Modality    -and
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

    $verMatch = [regex]::Match($ModelName, '(\d+(?:\.\d+)+|\d{2,})')
    if ($verMatch.Success) {
        $tok = $verMatch.Value
        $narrowed = $candidates | Where-Object { $_.MeterName -like "*$tok*" }
        if ($narrowed) { $candidates = $narrowed }
        else {
            return New-Result 'NoMeter' $null $null `
                "No meter matches version token '$tok' for this model in scope=$scope kind=$Kind. This is a real coverage gap - models can be deployable and GA with no published price. Do NOT bill this as zero."
        }

        # Variant disambiguation.
        # The version token alone is not enough: 'gpt-5.4' matches the meters for
        # 5.4, 5.4 pro, 5.4 mini and 5.4 nano, whose prices differ by an order of
        # magnitude. Require the variant suffix to match on BOTH sides - the base
        # model must not silently pick up a 'pro' meter.
        $variants = @('pro','mini','nano','codex','flash','lite','turbo','sol','luna','terra','astra','chat','opt')
        $modelLower = $ModelName.ToLowerInvariant()
        $modelVariant = $null
        foreach ($v in $variants) {
            # Match as a discrete token, so 'flash' in 'V4-Flash' counts but a
            # chance substring does not.
            if ($modelLower -match "[\s\-_]$v(\b|[\s\-_]|$)") { $modelVariant = $v; break }
        }

        $exact = $candidates | Where-Object {
            $mn = $_.MeterName.ToLowerInvariant()
            $meterVariant = $null
            foreach ($v in $variants) {
                if ($mn -match "(^|[\s\-])$v([\s\-]|$)") { $meterVariant = $v; break }
            }
            $meterVariant -eq $modelVariant
        }
        if ($exact) { $candidates = $exact }
    }

    $candidates = @($candidates)
    if ($candidates.Count -eq 0) {
        return New-Result 'NoMeter' $null $null `
            "No candidate meter for model=$ModelName scope=$scope kind=$Kind. Do NOT bill this as zero."
    }
    if ($candidates.Count -gt 1) {
        $distinct = @($candidates.PricePer1M | Sort-Object -Unique)
        if ($distinct.Count -eq 1) {
            return New-Result 'Priced' $distinct[0] $candidates[0].MeterName `
                "$($candidates.Count) meters matched, all at the same price."
        }
        return New-Result 'Ambiguous' $null ($candidates.MeterName -join ' | ') `
            "$($candidates.Count) meters matched with $($distinct.Count) different prices: $($distinct -join ', '). Narrow by ContextTier or Modality rather than guessing."
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][string] $ModelName,
        [string] $Publisher,
        [string] $Sku = 'GlobalStandard',
        [int] $InputTokens  = 0,
        [int] $CachedTokens = 0,
        [int] $OutputTokens = 0
    )

    $inP  = Get-TokenPrice -Table $Table -ModelName $ModelName -Publisher $Publisher -Sku $Sku -Kind Input
    $outP = Get-TokenPrice -Table $Table -ModelName $ModelName -Publisher $Publisher -Sku $Sku -Kind Output

    # Cached input is optional: many models have no cached meter, in which case
    # cached tokens bill at the standard input rate.
    $cacP = $null
    if ($CachedTokens -gt 0) {
        $cacP = Get-TokenPrice -Table $Table -ModelName $ModelName -Publisher $Publisher -Sku $Sku -Kind CachedInput
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
    $billableIn = [math]::Max(0, $InputTokens - $CachedTokens)
    $cachedRate = if ($cacP -and $cacP.Status -eq 'Priced') { $cacP.PricePer1M } else { $inP.PricePer1M }

    $cost = ($billableIn  / 1000000 * $inP.PricePer1M) +
            ($CachedTokens / 1000000 * $cachedRate) +
            ($OutputTokens / 1000000 * $outP.PricePer1M)

    [pscustomobject]@{
        ModelName    = $ModelName
        CostUSD      = [math]::Round($cost, 8)
        Status       = 'Priced'
        InputRate1M  = $inP.PricePer1M
        CachedRate1M = $cachedRate
        OutputRate1M = $outP.PricePer1M
        CachedRateIsFallback = -not ($cacP -and $cacP.Status -eq 'Priced')
        IsListPrice  = $Table.IsListPrice
    }
}

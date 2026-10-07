#Requires -Version 7.0
<#
.SYNOPSIS
    Reference sample: model catalog, unit pricing, per-request metering, token
    usage and cost telemetry for an AI gateway built on Microsoft Foundry.

.DESCRIPTION
    Shows the Azure APIs an AI gateway needs to report usage and cost to its
    own tenants, and the correct way to combine them.

      1. Catalog, deployments - ARM                         (real time)
      2. Unit pricing         - Azure Retail Prices API     (list prices; cache daily)
      3. Inline metering      - the inference response      (per request)
      4. Token usage          - Azure Monitor metrics       (about 1 min behind)
      5. Near-real-time cost  - (4) x (2)                   (about 1 min behind)
      6. Billed cost          - Cost Management Query API   (hours behind; throttled)

    Section 5 is a join, not a data source. A sixth source, the per-request
    diagnostic logs (RequestResponse and AzureOpenAIRequestUsage in Log
    Analytics), needs a diagnostic setting on the account, so this script does
    not read it; the README covers it.

    KEY POINT #1 - AZURE MONITOR: ONE SCHEMA, DIFFERENT SEMANTICS
    Azure Monitor reports tokens under the same metric names for every
    publisher - InputTokens, OutputTokens, TotalTokens - split by deployment,
    model and version. The names match; the meaning does not:
      * OpenAI-path InputTokens INCLUDE cached and cache-write tokens. Claude's
        InputTokens EXCLUDE them; Claude cache traffic has its own metrics.
      * xAI OutputTokens EXCLUDE reasoning, which appears only in TotalTokens.
        Azure did not bill that reasoning: for grok-4.3, billed output equalled
        OutputTokens exactly (Cost Management, Oct 2026). Price InputTokens and
        OutputTokens; never TotalTokens - InputTokens.
      * Monitor is close to the bill, not equal to it. Over 124 deployment-days
        of OpenAI-path traffic, billed quantities matched InputTokens and
        OutputTokens exactly on 86. Busy days were within about 5%; quiet days
        were billed in part or not at all.
      * One metrics request covers at most 31 days. A longer timespan is
        silently shortened to its last 31 days (HTTP 200), so query longer
        periods in pieces.
    Use Monitor for totals and for catching traffic that bypassed the gateway;
    use Cost Management for the invoice.

    KEY POINT #2 - NO TENANT DIMENSION
    Monitor splits by deployment, model, version, region and API - never by
    caller. The diagnostic logs carry the caller's object ID, which behind a
    gateway is the gateway's own identity. Per-tenant attribution has to
    happen in the request path, and it has to be provider-aware, because each
    publisher reports usage differently (section 3).

    KEY POINT #3 - RECONCILE PER DEPLOYMENT, NOT PER MODEL
    Cost Management rows carry a 'deployment' tag (value lowercased) that
    joins to Monitor's ModelDeploymentName. Model names do not join: a
    deployment named gpt-5-chat can run the model gpt-chat-latest, and meter
    names are abbreviations ('gpt 4.1 Inp glbl Tokens'). Never add quantities
    across meters: Cost Management's UnitOfMeasure is '1M' on some token meters
    and '1K' on others. Three cases need care:
      * Claude is not billed on the Foundry account at all (below).
      * model-router bills a router fee ('Model Routers GL 1M Tokens', listed
        under serviceName 'Foundry Tools' in the Retail Prices API) plus the
        meters of each model it routed to, all tagged with the router's
        deployment.
      * Some models bill on meters with no list price: DeepSeek-V4.1-Flash
        bills on 'DS30 1M Tokens' and 'DS31 1M Tokens', which only Cost
        Management shows.

    ANTHROPIC / CLAUDE BILLS THROUGH AZURE MARKETPLACE
    Claude is not in the Retail Prices API and is not billed on the Foundry
    account. Its charges land on Marketplace SaaS resources (MeterCategory
    'SaaS'), so a Cost Management query scoped to the account shows no
    Claude spend. New deployments bill in Claude Consumption Units (CCU);
    deployments created before CCU billing became generally available keep
    their per-model token plan, with meters such as 'Claude Sonnet 4.6 -
    msft-sonnet-4-6-flat-100 - paygo-inference-input-tokens'. A CCU meter
    names the plan and the hosting ('Azure hosted' or 'Anthropic hosted'),
    never the model, and the rows carry no deployment tag. Every Claude
    resource seen was named '<Claude name, cut to 15 characters>-<first 15
    characters of the account's internalId>-<32 hex digits>'. The middle
    part ties a resource to its account; the Claude name does not identify
    the deployment: claude-opus-5's usage was billed on a resource named
    'claude-opus-5-5-...'. Claude token counts are exact in the response;
    Claude cost per deployment can only be estimated. See
    https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing

.PARAMETER AccountName
    The Foundry (Microsoft.CognitiveServices) account name.

.PARAMETER SubscriptionId
    Defaults to the Azure CLI's current subscription.

.PARAMETER ResourceGroup
    Looked up from the account name when omitted.

.PARAMETER Region
    Region for the model catalog and the price table. Defaults to the
    account's location.

.PARAMETER Deployment
    The deployment section 3 calls. Default: one chat deployment per publisher,
    excluding model-router - name it here to exercise router pricing.

.PARAMETER LookbackMins
    Azure Monitor window for sections 4 and 5: 1 to 44640 minutes (31 days,
    the most one metrics request covers).

.PARAMETER IncludeCost
    Also run section 6: billed cost for the last 5 UTC days plus today. Slow
    and throttled.

.PARAMETER SkipInference
    Skip section 3, so no tokens are spent. Use it for an identity without
    data-plane access to the account.

.EXAMPLE
    ./Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry

.EXAMPLE
    ./Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry -Deployment model-router -LookbackMins 1440 -IncludeCost

.NOTES
    Requires PowerShell 7 and the Azure CLI, signed in (az login), with
    Build-FoundryPriceTable.ps1 in the same folder. Every call uses an Entra
    token; no API keys.
      - ARM, Azure Monitor, Cost Management -> audience https://management.azure.com
      - Inference                           -> audience https://cognitiveservices.azure.com
      - Retail Prices API                   -> anonymous

    RBAC. These come from the role definitions and the Cost Management docs;
    least privilege was NOT tested (the test identity held Owner, Foundry
    User, Cognitive Services User and Cognitive Services OpenAI User):
      - Sections 1, 4, 5: Reader on the subscription. The model catalog and
        the account lookup are subscription-scope calls.
      - Section 2: none - the Retail Prices API is anonymous.
      - Section 3: data-plane access to the account, e.g. Foundry User (data
        actions Microsoft.CognitiveServices/*). Without it, use -SkipInference.
      - Section 6: Reader (or Cost Management Reader) on the subscription. On
        an Enterprise Agreement the 'AO view charges' setting must be on; on a
        CSP subscription the partner must enable cost visibility.

    Verified in October 2026 against a Foundry (AIServices) account in eastus2
    with OpenAI, Anthropic, xAI and DeepSeek deployments.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AccountName,
    [string] $SubscriptionId,
    [string] $ResourceGroup,
    [string] $Region,
    [string] $Deployment,
    [ValidateRange(1, 44640)][int] $LookbackMins = 60,
    [switch] $IncludeCost,
    [switch] $SkipInference
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ------------------------------- HELPERS ------------------------------------

function Get-EntraToken {
    # Entra access token for one audience, from the Azure CLI's signed-in
    # identity. --subscription selects that subscription's tenant.
    param(
        [Parameter(Mandatory)][string] $Resource,
        [string] $SubscriptionId
    )
    $azArgs = @('account', 'get-access-token', '--resource', $Resource, '--query', 'accessToken', '-o', 'tsv')
    if ($SubscriptionId) { $azArgs += @('--subscription', $SubscriptionId) }
    $t = az @azArgs
    if ($LASTEXITCODE -ne 0 -or -not $t) {
        throw "Could not get a token for '$Resource' from the Azure CLI. Run 'az login', and 'az account set --subscription <id>' if needed."
    }
    $t
}

function Invoke-ArmWithRetry {
    <#
      One ARM-style REST call (ARM, Azure Monitor, Cost Management) with
      back-off. Retries 408, 429, 5xx and network errors, honouring every
      *retry-after header: Cost Management sends
      x-ms-ratelimit-microsoft.costmanagement-{qpu,entity,tenant,clienttype}-
      retry-after as well as Retry-After, and waits for the largest. Any other
      HTTP error throws, with an excerpt of the response body.
    #>
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('Get', 'Post')][string] $Method = 'Get',
        $Body,
        [Parameter(Mandatory)][string] $Token,
        [int] $MaxAttempts = 6,
        [int] $DelaySec = 5
    )
    $p = @{
        Uri = $Uri; Method = $Method; Headers = @{ Authorization = "Bearer $Token" }
        SkipHttpErrorCheck = $true; TimeoutSec = 120
    }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        $p.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $p.ContentType = 'application/json'
    }
    $where = "$Method $(($Uri -split '\?')[0])"
    $code  = 0
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $r = $null; $code = 0
        try { $r = Invoke-WebRequest @p; $code = [int]$r.StatusCode }
        catch { Write-Verbose "Network error on attempt $i ($where): $($_.Exception.Message)" }

        if ($code -ge 200 -and $code -lt 300) {
            $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
            if (-not $text) { return $null }
            return ($text | ConvertFrom-Json)
        }
        if ($code -ne 0 -and $code -notin 408, 429, 500, 502, 503, 504) {
            $excerpt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) -replace '\s+', ' '
            if ($excerpt.Length -gt 400) { $excerpt = $excerpt.Substring(0, 400) }
            throw "HTTP $code from ${where}: $excerpt"
        }
        if ($i -eq $MaxAttempts) { break }

        $wait = [math]::Min(120, $DelaySec * [math]::Pow(2, $i - 1))
        if ($r) {
            # PowerShell 7 returns each header value as a string array.
            $hinted = foreach ($k in $r.Headers.Keys) {
                if ($k -match 'retry-after$') {
                    $v = (@($r.Headers[$k]) -join ',').Split(',')[0].Trim()
                    $n = 0
                    if ([int]::TryParse($v, [ref]$n)) { $n }
                }
            }
            if ($hinted) { $wait = [math]::Min(300, ($hinted | Measure-Object -Maximum).Maximum + 1) }
        }
        Write-Verbose "HTTP $code on attempt $i ($where); retrying in $wait s"
        Start-Sleep -Seconds $wait
    }
    throw "Gave up on $where after $MaxAttempts attempts (last HTTP status: $code)."
}

function Get-ArmCollection {
    # Every item of an ARM list, following nextLink. Do not stop at an empty
    # page: the subscription-wide accounts list has returned an empty first
    # page with a nextLink, and the account was on a later one.
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Token
    )
    $next = $Uri
    while ($next) {
        $page = Invoke-ArmWithRetry -Uri $next -Token $Token
        foreach ($item in @($page.value)) { if ($null -ne $item) { $item } }
        $next = $page.nextLink
    }
}

function ConvertTo-DateText($Value) {
    # 'yyyy-MM-dd' from an ISO date string or a [datetime]. PowerShell 7's
    # ConvertFrom-Json turns ISO date strings into [datetime] (Kind Utc for a
    # 'Z' string), so the same field can arrive as either type.
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) {
        $d = if ($Value.Kind -eq [DateTimeKind]::Local) { $Value.ToUniversalTime() } else { $Value }
        return $d.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    }
    ([string]$Value).Split('T')[0]
}

function Format-Number($Value) {
    # Money and rates as invariant text, for display only. PowerShell 7.6's
    # Format-Table shows a double to 2 decimal places, so a $0.0375 rate
    # prints as 0.04 and a whole small request as 0.00. Never round the value
    # itself.
    if ($null -eq $Value) { return 'n/a' }
    ([double]$Value).ToString('0.########', [cultureinfo]::InvariantCulture)
}

# ---------------------------------------------------------------------------
# 1. CATALOG AND DEPLOYMENTS  -  ARM, real time
#    The catalog says what can be deployed in a region, with lifecycle and
#    retirement dates; there is no RSS feed or webhook. The deployments say
#    what is deployed, and from whom.
# ---------------------------------------------------------------------------
function Get-FoundryModelCatalog {
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $Region,
        [Parameter(Mandatory)][string] $Token,
        [string] $Kind    # the account's kind ('AIServices', 'OpenAI'); omit for every kind
    )

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId" +
           "/providers/Microsoft.CognitiveServices/locations/$Region" +
           "/models?api-version=2024-10-01"

    # One entry per model version PER ACCOUNT KIND: eastus2 returned 338
    # entries for 169 versions of 141 models (2026-10-07) - every version under
    # 'AIServices', and again under 'OpenAI', 'MaaS' or 'MAI'. Filter to the
    # account's kind, then collapse to one row per model name while UNIONING
    # the SKUs and versions. Taking the first entry wholesale under-reports
    # both.
    $byName = [ordered]@{}
    foreach ($item in (Get-ArmCollection -Uri $uri -Token $Token)) {
        if ($Kind -and $item.kind -ne $Kind) { continue }
        $m = $item.model
        if (-not $m.name) { continue }
        if (-not $byName.Contains($m.name)) {
            $byName[$m.name] = [pscustomobject]@{
                Head      = $null
                Skus      = [System.Collections.Generic.HashSet[string]]::new()
                ByVersion = @{}
            }
        }
        $row = $byName[$m.name]
        # The head row describes the default version where there is one; 10
        # of 141 models in eastus2 had none (2026-10-07).
        if (-not $row.Head -or ($m.isDefaultVersion -and -not $row.Head.isDefaultVersion)) { $row.Head = $m }
        foreach ($s in @($m.skus)) { if ($s.name) { [void]$row.Skus.Add($s.name) } }
        if ($m.version) {
            $row.ByVersion[[string]$m.version] = [pscustomobject]@{
                Lifecycle           = $m.lifecycleStatus
                InferenceRetirement = ConvertTo-DateText $m.deprecation.inference
            }
        }
    }

    foreach ($name in $byName.Keys) {
        $row = $byName[$name]
        $h   = $row.Head
        [pscustomobject]@{
            Name                = $name
            Version             = $h.version
            HasDefault          = [bool]$h.isDefaultVersion
            Versions            = (@($row.ByVersion.Keys | Sort-Object) -join ',')
            Format              = $h.format
            # GOTCHA: the publisher key is 'format', not 'publisher'. format is
            # on every entry and equals the deployment's properties.model.format
            # ('OpenAI', 'OpenAI-OSS', 'Anthropic', 'xAI', 'DeepSeek',
            # 'Mistral AI', ...), the value Get-TokenPrice -Publisher expects.
            # 'publisher' is absent on every OpenAI-format entry and present on
            # every other one - 182 of 338 in eastus2 (2026-10-07), which is
            # exactly the 156 OpenAI entries missing it. For gpt-oss it says
            # 'OpenAI' where format says 'OpenAI-OSS'.
            Publisher           = $h.format
            Lifecycle           = $h.lifecycleStatus
            InferenceRetirement = ConvertTo-DateText $h.deprecation.inference
            Skus                = (@($row.Skus | Sort-Object) -join ',')
            # usageName is the join key to quota; useful for capacity
            # dashboards. Guarded: $null[0] throws, and with
            # $ErrorActionPreference='Stop' one entry lacking a skus array
            # would abort the whole catalog call.
            UsageName           = if ($h.skus -and @($h.skus).Count -gt 0) { @($h.skus)[0].usageName } else { $null }
            ByVersion           = $row.ByVersion
        }
    }
}

# DEPLOYMENT -> PUBLISHER  -  the join inline metering depends on
#
#   You cannot infer the publisher from a deployment name: operators rename
#   deployments freely, and 'my-fast-model' says nothing about who built it.
#   properties.model.format on the ARM deployment is the authoritative key,
#   and it is what Get-ProviderProfile and Get-TokenPrice both expect.
#   Guessing wrong here sends Claude traffic to the OpenAI path, which fails
#   the call outright.
function Get-FoundryDeployments {
    param(
        [Parameter(Mandatory)][string] $AccountResourceId,
        [Parameter(Mandatory)][string] $Token
    )
    $uri = "https://management.azure.com$AccountResourceId/deployments?api-version=2024-10-01"
    foreach ($d in (Get-ArmCollection -Uri $uri -Token $Token)) {
        [pscustomobject]@{
            Deployment = $d.name
            Model      = $d.properties.model.name
            Publisher  = $d.properties.model.format
            Version    = $d.properties.model.version
            Sku        = $d.sku.name
            Capacity   = $d.sku.capacity
            State      = $d.properties.provisioningState
        }
    }
}

# ---------------------------------------------------------------------------
# 2. UNIT PRICING  -  Azure Retail Prices API
#    Anonymous, no subscription context. LIST prices: no EA, MACC or
#    negotiated discount. Prices change rarely: cache daily.
#    Build-FoundryPriceTable.ps1 builds and caches the per-token table; this
#    section turns it into per-deployment rates.
#
#    GOTCHAS (every one of these was hit in practice):
#
#      * serviceName is 'Foundry Models', NOT 'Cognitive Services'. The old
#        value now returns ZERO rows silently - an HTTP 200 with Count=0, not
#        an error. Any query still using it will look like "no pricing exists".
#
#      * The model-router fee is not under 'Foundry Models'. It is
#        'Model Routers GL 1M Tokens' (DZ for Data Zone) under serviceName
#        'Foundry Tools'.
#
#      * unitOfMeasure is MIXED within the same service - both '1K' and '1M'
#        appear. You must normalise per row: reading every row as per 1M
#        understates the 1K meters 1000x, and reading every row as per 1K
#        overstates the 1M meters 1000x.
#
#      * productName spelling is inconsistent. 'Azure Deepseek Models' has a
#        lowercase 's' - a case-sensitive match on 'DeepSeek' misses it.
#
#      * meterName uses abbreviations, not model IDs - and not consistently.
#        Input: 'Inp', 'Inpt', 'Input'. Output: 'Outp', 'outpt', 'Opt',
#        'Output'. Cached: 'cd', 'cchd', 'Cached', 'Cache'. Global: 'glbl',
#        'Gl', 'global'. Data Zone: 'DZ', 'DZone', 'Data Zone', 'datazone'.
#        Regional: 'regnl', 'rgnl', 'regional'. Searching for 'gpt-4.1' will
#        not match 'gpt 4.1 Inp glbl Tokens'.
#
#      * PowerShell 7.6's Format-Table shows doubles to 2 decimal places, so
#        per-token prices render as 0.00 and the catalog looks free. Format
#        rates as text before display (Format-Number).
#
#      * Paginated via NextPageLink and throttled - handle both.
# ---------------------------------------------------------------------------
function Get-AzureRetailPrices {
    param([Parameter(Mandatory)][string] $Filter)

    # Pin the API version so the response shape cannot change under this
    # parser without a code change. NextPageLink carries it to later pages.
    $uri  = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&`$filter=" + [uri]::EscapeDataString($Filter)
    $all  = [System.Collections.Generic.List[object]]::new()
    $next = $uri
    $fail = 0

    while ($next) {
        try {
            $page = Invoke-RestMethod -Uri $next -TimeoutSec 60 -ErrorAction Stop
            foreach ($i in @($page.Items)) { $all.Add($i) }
            $next = $page.NextPageLink
            $fail = 0
        }
        catch {
            if (++$fail -gt 4) { throw "Retail Prices API failed after $fail attempts: $($_.Exception.Message)" }
            Start-Sleep -Seconds 12
        }
    }

    $all | ForEach-Object {
        # Capture the pipeline object explicitly. Inside `switch -Regex`, $_ is
        # rebound to the switch input, so $_.retailPrice would silently be $null.
        $item = $_

        # Normalise every meter to USD per 1M tokens, honouring unitOfMeasure.
        $per1M = switch -Regex ($item.unitOfMeasure) {
            '^1K'   { $item.retailPrice * 1000 ; break }   # price is per 1K tokens
            '^1M'   { $item.retailPrice        ; break }   # already per 1M
            default { $null }                              # not token-denominated
        }

        [pscustomobject]@{
            ProductName   = $item.productName
            MeterName     = $item.meterName
            SkuName       = $item.skuName
            ServiceName   = $item.serviceName
            Type          = $item.type
            Region        = $item.armRegionName
            UnitOfMeasure = $item.unitOfMeasure
            RetailPrice   = $item.retailPrice
            PricePer1M    = if ($null -ne $per1M) { [math]::Round($per1M, 6) } else { $null }
        }
    }
}

function Resolve-ModelPrice {
    <#
      Resolves one deployed model to the rates inline metering and the
      near-real-time join need - input, output, cached input and cache write -
      at each service tier that has meters. BillingModel says why a cost may
      be null:

        Derived      list prices from the Retail Prices API
        Router       model-router: a router fee plus the routed model's rates,
                     resolved per request (Get-RoutedPrice)
        Marketplace  Anthropic: billed through Azure Marketplace, not here
        Capacity     provisioned throughput: billed per hour, not per token
        NoMeter      no usable list price; Note says why

      Service tiers are 'default', 'priority' and 'flex', keyed as the
      response's service_tier reports them. Models priced only in Short and
      Long context bands (gpt-5.5 and later) are resolved at Short; a request
      past the long-context threshold bills at the Long rates.
    #>
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][string] $ModelName,
        [string] $Publisher,
        [string] $Sku = 'GlobalStandard',
        [string] $Version,
        $RouterMeters,                        # Get-AzureRetailPrices rows for 'Model Routers'
        [hashtable] $PublisherOf = @{}        # model name -> publisher, for routed models
    )

    $entry = [pscustomobject]@{
        Model        = $ModelName
        Publisher    = $Publisher
        Sku          = $Sku
        BillingModel = 'NoMeter'
        Note         = $null
        Tiers        = @{}
        RouterPer1M  = $null
        RouterMeter  = $null
        Routed       = @{}
        Table        = $Table
        PublisherOf  = $PublisherOf
    }

    if ($ModelName -eq 'model-router') {
        # Every request bills a router fee on its input tokens, plus the
        # routed model's own meters. The fee meter follows the deployment
        # type: 'GL' for Global, 'DZ' for Data Zone.
        $entry.BillingModel = 'Router'
        $like = if ($Sku -match 'DataZone') { '* DZ *' } elseif ($Sku -match 'Global') { '* GL *' } else { $null }
        $fee  = if ($like) {
            @($RouterMeters | Where-Object { $_.Type -eq 'Consumption' -and $null -ne $_.PricePer1M -and $_.MeterName -like $like })[0]
        }
        if ($fee) { $entry.RouterPer1M = $fee.PricePer1M; $entry.RouterMeter = $fee.MeterName }
        else      { $entry.Note = "No router-fee meter for SKU '$Sku' in the Retail Prices API, so router costs are not computed." }
        return $entry
    }

    $q = @{ Table = $Table; ModelName = $ModelName; Publisher = $Publisher; Sku = $Sku; WarningAction = 'SilentlyContinue' }
    if ($Version) { $q.ModelVersion = $Version }

    $probe = Get-TokenPrice @q -Kind Input
    if ($probe.Status -eq 'BilledOutsideRetailAPI') { $entry.BillingModel = 'Marketplace'; $entry.Note = $probe.Note; return $entry }
    if ($probe.Status -eq 'BilledAsCapacity')       { $entry.BillingModel = 'Capacity';    $entry.Note = $probe.Note; return $entry }

    foreach ($tier in 'default', 'priority', 'flex') {
        # Priority and Flex have their own meters; their ratio to Standard
        # varies by model, so read each tier's meter rather than scaling.
        $tq = @{}
        if ($tier -eq 'priority') { $tq.ServiceTier = 'Priority' }
        if ($tier -eq 'flex')     { $tq.ServiceTier = 'Flex' }
        foreach ($ct in 'Standard', 'Short') {
            $in = Get-TokenPrice @q @tq -Kind Input -ContextTier $ct
            if ($in.Status -ne 'Priced') { continue }
            $out = Get-TokenPrice @q @tq -Kind Output      -ContextTier $ct
            $cin = Get-TokenPrice @q @tq -Kind CachedInput -ContextTier $ct
            $cw  = Get-TokenPrice @q @tq -Kind CacheWrite  -ContextTier $ct
            $entry.Tiers[$tier] = [pscustomobject]@{
                ContextTier      = $ct
                InputPer1M       = $in.PricePer1M
                InputMeter       = $in.MeterName
                OutputPer1M      = if ($out.Status -eq 'Priced') { $out.PricePer1M } else { $null }
                OutputMeter      = if ($out.Status -eq 'Priced') { $out.MeterName }  else { $null }
                CachedInputPer1M = if ($cin.Status -eq 'Priced') { $cin.PricePer1M } else { $null }
                CacheWritePer1M  = if ($cw.Status  -eq 'Priced') { $cw.PricePer1M }  else { $null }
            }
            break
        }
    }

    if ($entry.Tiers.ContainsKey('default')) { $entry.BillingModel = 'Derived' }
    else { $entry.Note = "[$($probe.Status)] $($probe.Note)" }
    $entry
}

function Get-RoutedPrice {
    # Rates for the model a model-router request was routed to, cached on the
    # router's entry. The response names it with its version appended
    # ('gpt-5.4-nano-2026-03-17'); Monitor gives name and version separately.
    param(
        [Parameter(Mandatory)] $RouterEntry,
        [Parameter(Mandatory)][string] $ModelName,
        [string] $Version
    )
    $m = $ModelName
    $v = $Version
    if (-not $v -and $ModelName -match '^(.+)-(\d{4}-\d{2}-\d{2})$') { $m = $Matches[1]; $v = $Matches[2] }
    $key = "$m|$v"
    if (-not $RouterEntry.Routed.ContainsKey($key)) {
        $RouterEntry.Routed[$key] = Resolve-ModelPrice -Table $RouterEntry.Table -ModelName $m `
            -Publisher $RouterEntry.PublisherOf[$m] -Sku $RouterEntry.Sku -Version $v
    }
    $RouterEntry.Routed[$key]
}

function Measure-TokenCost {
    <#
      USD cost of a token count at one tier's rates, or a $null Cost - never
      0 - when a rate it needs is missing. -InputTokens is the UNCACHED
      remainder: prompt - cached - cache write on the OpenAI path, input_tokens
      on Anthropic. Decimal arithmetic, rounded to 8 places.
    #>
    param(
        $Rates,
        [long] $InputTokens      = 0,
        [long] $CachedTokens     = 0,
        [long] $CacheWriteTokens = 0,
        [long] $OutputTokens     = 0
    )
    function New-Cost($cost, $note) { [pscustomobject]@{ Cost = $cost; Note = $note } }

    if ($InputTokens -lt 0 -or $CachedTokens -lt 0 -or $CacheWriteTokens -lt 0 -or $OutputTokens -lt 0) {
        return New-Cost $null 'Negative token count: the usage block is inconsistent. No cost claimed.'
    }
    if (-not $Rates -or $null -eq $Rates.InputPer1M) { return New-Cost $null 'No input rate.' }

    $note = $null
    [decimal] $sum = 0
    if ($InputTokens -gt 0) { $sum += [decimal]$InputTokens * [decimal]$Rates.InputPer1M }
    if ($CachedTokens -gt 0) {
        if ($null -ne $Rates.CachedInputPer1M) { $sum += [decimal]$CachedTokens * [decimal]$Rates.CachedInputPer1M }
        else {
            $sum += [decimal]$CachedTokens * [decimal]$Rates.InputPer1M
            $note = 'No cached-input rate: cached tokens priced at the input rate, so this is an upper bound.'
        }
    }
    if ($CacheWriteTokens -gt 0) {
        # Cache writes bill ABOVE the input rate (1.25x on gpt-5.6 and gpt-6),
        # so no fallback rate would be safe.
        if ($null -eq $Rates.CacheWritePer1M) { return New-Cost $null 'Cache-write tokens but no cache-write rate. No cost claimed.' }
        $sum += [decimal]$CacheWriteTokens * [decimal]$Rates.CacheWritePer1M
    }
    if ($OutputTokens -gt 0) {
        if ($null -eq $Rates.OutputPer1M) { return New-Cost $null 'Output tokens but no output rate. No cost claimed.' }
        $sum += [decimal]$OutputTokens * [decimal]$Rates.OutputPer1M
    }
    New-Cost ([double][math]::Round($sum / 1000000, 8)) $note
}

# ---------------------------------------------------------------------------
# 3. INLINE METERING  -  read usage straight off the inference response
#
#    The only per-request, per-tenant source: Monitor has no tenant dimension
#    (key point #2). Meter inline for attribution; use Monitor for totals and
#    to catch traffic that bypassed the gateway.
#
#    *** INLINE METERING IS PROVIDER-SHAPED. *** Verified live, Oct 2026:
#
#    ENDPOINT
#      OpenAI / xAI / DeepSeek -> /openai/v1/chat/completions
#      Anthropic               -> /anthropic/v1/messages   + anthropic-version
#      All three account hosts (<account>.services.ai.azure.com,
#      .openai.azure.com and .cognitiveservices.azure.com) route both paths.
#      Claude on the OpenAI path is HTTP 404 api_not_supported; omitting
#      anthropic-version is HTTP 400.
#
#    FIELD NAMES
#      OpenAI path -> prompt_tokens / completion_tokens / total_tokens
#      Anthropic   -> input_tokens  / output_tokens      (no total)
#      A parser reading prompt_tokens off Anthropic records 0, not an error.
#
#    CACHE - THE ASYMMETRY THAT BREAKS COST MATH
#      OpenAI path  prompt_tokens INCLUDES prompt_tokens_details.cached_tokens
#                   and, where reported (gpt-5.6, gpt-6, model-router),
#                   prompt_tokens_details.cache_write_tokens
#                   -> uncached input = prompt - cached - cache_write
#      Anthropic    input_tokens EXCLUDES cache_read_input_tokens and
#                   cache_creation_input_tokens, which are siblings
#                   -> uncached input = input_tokens   (no subtraction)
#      Subtracting on Anthropic double-discounts. Not subtracting on the
#      OpenAI path bills cached tokens twice.
#
#    REASONING
#      o4-mini   prompt 15, completion 174, reasoning 128, total 189:
#                reasoning is INSIDE completion_tokens (15 + 174 = 189).
#      grok-4.3  prompt 18, completion 1, reasoning 691, total 710:
#                reasoning is OUTSIDE completion_tokens (18 + 1 + 691 = 710).
#                Azure billed completion_tokens alone: grok-4.3's billed output
#                equalled Monitor's OutputTokens exactly, with the reasoning
#                unbilled (Cost Management, Oct 2026). Microsoft's Grok
#                documentation says completion tokens include reasoning, so
#                detect the convention from the totals on every response and
#                check it against your own bill.
#
#    STREAMING
#      OpenAI models send usage only when stream_options.include_usage is
#      true; xAI and DeepSeek send it regardless. Anthropic always streams
#      usage and REJECTS stream_options (HTTP 400), so never inject it there.
#      Take the LAST usage object: Anthropic's message_start carries a partial
#      output count and message_delta the final one - but only message_start
#      splits cache writes into 5-minute and 1-hour. A complete stream ends
#      with 'data: [DONE]' (OpenAI path) or 'event: message_stop' (Anthropic).
#
#    OUTPUT LIMIT
#      max_completion_tokens was accepted by all 14 OpenAI-path deployments
#      tested (OpenAI models, grok-4.3, DeepSeek-V4.1-Flash, model-router).
#      max_tokens was rejected with HTTP 400 by 8 of them: o4-mini, gpt-5-mini,
#      gpt-5.1, gpt-5.4, gpt-5.4-mini, gpt-5.6-sol, gpt-6-sol, gpt-6-astra.
#      Anthropic takes max_tokens only. On grok-4.3 neither capped reasoning.
#
#    FAILURE
#      Judge failure by the HTTP status. A 200 can carry an error object: a
#      gpt-4.1 completion returned HTTP 200, finish_reason 'stop' and a full
#      usage block, with prompt_filter_results[0].content_filter_results
#      .defender_for_ai.details.error = {"code":"408","message":"DefenderForAI
#      request exceeded 300ms timeout."}. Searching the body for "error":{
#      would have discarded a billed response.
#
#    REQUEST ID
#      The apim-request-id response header equals CorrelationId in the
#      AzureOpenAIRequestUsage log for OpenAI models (not for model-router).
#      Record it to join a request to the diagnostic logs.
#
#    SERVICE TIER
#      Priority and Flex are chosen per request and bill on their own meters:
#      Priority at 2x Standard on most models (1.75x on gpt-4.1 and
#      gpt-4.1-mini, 1.8x on gpt-5-mini, 2.5x on gpt-5.5), Flex at 0.5x where
#      a Flex meter exists. Only the response's service_tier is authoritative:
#      gpt-4.1-mini answered 'default' to a priority request, and an
#      unsupported flex request is HTTP 400. grok-4.3 omits service_tier on
#      non-streamed responses; Claude reports 'standard'.
#
#    LATENCY
#      OpenAI models return a latency_checkpoint block (engine_ttft_ms,
#      service_ttft_ms, ...): inside usage on a non-streamed response, at the
#      top level of a streamed chunk. Engine and service TTFT differ - 64 vs
#      518 ms on one request. Anthropic returns none. A buffered client (as
#      here) cannot see TTFT itself, so measure it at the proxy as well.
# ---------------------------------------------------------------------------

function Get-ProviderProfile {
    <#
      Maps a publisher to what differs about calling and metering it. The
      publisher is the deployment's properties.model.format. Only Anthropic
      needs a profile of its own: xAI and DeepSeek use the OpenAI-compatible
      path and field names, and where they differ (reasoning outside
      completion_tokens, no prompt_tokens_details) ConvertTo-NormalizedUsage
      detects it from the numbers, not from the publisher name.
    #>
    param([Parameter(Mandatory)][string] $Publisher)

    if ($Publisher -eq 'Anthropic') {
        return [pscustomobject]@{
            Provider           = 'Anthropic'
            Api                = 'AnthropicMessages'
            PathSuffix         = '/anthropic/v1/messages'
            ExtraHeaders       = @{ 'anthropic-version' = '2023-06-01' }
            UsesStreamOptions  = $false    # streams usage anyway; 400s on stream_options
            InputIncludesCache = $false
            HasTotalTokens     = $false
            MarketplaceBilled  = $true
        }
    }
    [pscustomobject]@{
        Provider           = $Publisher
        Api                = 'OpenAIChatCompletions'
        PathSuffix         = '/openai/v1/chat/completions'
        ExtraHeaders       = @{}
        UsesStreamOptions  = $true
        InputIncludesCache = $true
        HasTotalTokens     = $true
        MarketplaceBilled  = $false
    }
}

function ConvertTo-NormalizedUsage {
    <#
      Collapses every publisher's usage block into one schema:

        InputTokens        uncached input, cache reads and writes removed
        CachedReadTokens   input served from cache (cached-input rate)
        CacheWriteTokens   input written to cache (cache-write rate)
        CacheWrite5m/1h    Anthropic's split of CacheWriteTokens, if reported
        OutputTokens       completion_tokens / output_tokens as reported
        ReasoningTokens    as reported
        ReasoningInOutput  $true  - reasoning is inside OutputTokens (o-series)
                           $false - reasoning is outside it (grok-4.3); it is
                                    not in OutputTokens or TotalTokens
                           $null  - no reasoning reported
        TotalTokens        Input + CachedRead + CacheWrite + Output: the
                           tokens a price applies to
        ReportedTotal      the provider's own total_tokens, if any

      [long] throughout: a long-context prompt is fine in [int], but these
      counts get summed, and a day's total for one deployment can pass the
      2.1 billion an [int] holds.
    #>
    param(
        [Parameter(Mandatory)] $Usage,
        [Parameter(Mandatory)] $ProviderProfile
    )

    $reason = [long]0; $reasonInOut = $null; $reported = $null
    $w5m = $null; $w1h = $null

    if ($ProviderProfile.Api -eq 'AnthropicMessages') {
        # input_tokens EXCLUDES cache reads and writes - do not subtract.
        $inTok   = [long]$Usage.input_tokens
        $cacheRd = [long]$Usage.cache_read_input_tokens
        $cacheWr = [long]$Usage.cache_creation_input_tokens
        $outTok  = [long]$Usage.output_tokens
        if ($Usage.cache_creation) {
            $w5m = [long]$Usage.cache_creation.ephemeral_5m_input_tokens
            $w1h = [long]$Usage.cache_creation.ephemeral_1h_input_tokens
        }
    }
    else {
        # prompt_tokens INCLUDES cache reads and writes - subtract both.
        # DeepSeek has no prompt_tokens_details; [long]$null is 0, which is right.
        $prompt  = [long]$Usage.prompt_tokens
        $cacheRd = [long]$Usage.prompt_tokens_details.cached_tokens
        $cacheWr = [long]$Usage.prompt_tokens_details.cache_write_tokens
        $inTok   = $prompt - $cacheRd - $cacheWr
        $outTok  = [long]$Usage.completion_tokens
        $reason  = [long]$Usage.completion_tokens_details.reasoning_tokens
        if ($null -ne $Usage.total_tokens) { $reported = [long]$Usage.total_tokens }

        # Which side of completion_tokens is reasoning on? Decide from the
        # provider's own total rather than a publisher list. A total that fits
        # neither reading means the accounting changed - surface it loudly
        # rather than ship a quietly wrong invoice.
        if ($null -ne $reported) {
            if ($reported -eq $prompt + $outTok) {
                if ($reason -gt 0) { $reasonInOut = $true }
            }
            elseif ($reason -gt 0 -and $reported -eq $prompt + $outTok + $reason) {
                $reasonInOut = $false
            }
            else {
                Write-Warning ("Usage mismatch for {0}: total_tokens {1} is neither prompt + completion ({2}) nor that plus reasoning ({3}). Token accounting for this publisher may have changed." -f `
                    $ProviderProfile.Provider, $reported, ($prompt + $outTok), ($prompt + $outTok + $reason))
            }
        }
    }

    [pscustomobject]@{
        Provider          = $ProviderProfile.Provider
        InputTokens       = $inTok
        CachedReadTokens  = $cacheRd
        CacheWriteTokens  = $cacheWr
        CacheWrite5m      = $w5m
        CacheWrite1h      = $w1h
        OutputTokens      = $outTok
        ReasoningTokens   = $reason
        ReasoningInOutput = $reasonInOut
        TotalTokens       = $inTok + $cacheRd + $cacheWr + $outTok
        ReportedTotal     = $reported
    }
}

function Invoke-MeteredCompletion {
    <#
      Provider-aware metering wrapper. Picks the path, headers and payload
      shape for the publisher, sends one request, and returns exact token
      counts, the service tier the request ran at and its list-price cost -
      or nothing, with a warning, when the call failed or carried no usage.
    #>
    param(
        [Parameter(Mandatory)][string] $Endpoint,    # the account's 'AI Foundry API' endpoint
        [Parameter(Mandatory)][string] $Deployment,
        [Parameter(Mandatory)] $Messages,
        [Parameter(Mandatory)][string] $Publisher,   # from the ARM deployment: properties.model.format
        $PriceEntry,                                 # from Resolve-ModelPrice
        [int] $MaxTokens = 256,
        [switch] $Stream,
        [ValidateSet('auto', 'default', 'priority', 'flex')][string] $ServiceTier,
        [int] $TimeoutSec = 120,
        [string] $Token,
        [string] $TenantTag = 'default'              # your own tenant / user attribution
    )

    $prof = Get-ProviderProfile -Publisher $Publisher
    if (-not $Token) { $Token = Get-EntraToken -Resource 'https://cognitiveservices.azure.com' }

    $headers = @{ Authorization = "Bearer $Token" }
    foreach ($k in $prof.ExtraHeaders.Keys) { $headers[$k] = $prof.ExtraHeaders[$k] }
    $url = $Endpoint.TrimEnd('/') + $prof.PathSuffix

    # max_completion_tokens on the OpenAI path: every deployment tested took
    # it, and the reasoning models reject max_tokens. A publisher that wants
    # max_tokens instead gets one retry - on an HTTP 400, so no charged
    # response is ever discarded. Anthropic takes max_tokens only.
    $limitParam = if ($prof.Api -eq 'AnthropicMessages') { 'max_tokens' } else { 'max_completion_tokens' }
    $resp = $null; $status = 0; $body = ''; $sw = $null

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $payload = [ordered]@{ model = $Deployment; messages = $Messages }
        $payload[$limitParam] = $MaxTokens
        if ($Stream) {
            $payload.stream = $true
            if ($prof.UsesStreamOptions) {
                # Without this, OpenAI models stream no usage at all.
                $payload.stream_options = @{ include_usage = $true }
            }
        }
        if ($ServiceTier) {
            if ($prof.Api -eq 'AnthropicMessages') { Write-Warning "service_tier is not sent to Anthropic; '$Deployment' runs at its default tier." }
            else { $payload.service_tier = $ServiceTier }
        }
        # UTF-8 bytes, so a non-English prompt reaches the model intact.
        $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10 -Compress))

        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bytes `
                        -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec $TimeoutSec
        }
        catch {
            Write-Warning ("{0} call to '{1}' got no response: {2} Tokens may still have been consumed - reconcile against Azure Monitor." -f `
                $prof.Provider, $Deployment, $_.Exception.Message)
            return
        }
        finally { $sw.Stop() }

        $status = [int]$resp.StatusCode
        $body   = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        if ($attempt -eq 1 -and $status -eq 400 -and $limitParam -eq 'max_completion_tokens' -and
            $body -match 'max_completion_tokens' -and $body -match '(?i)unsupported|not supported|unrecognized|unknown') {
            Write-Verbose "'$Deployment' rejected max_completion_tokens; retrying with max_tokens."
            $limitParam = 'max_tokens'
            continue
        }
        break
    }

    $requestId = $null
    foreach ($k in $resp.Headers.Keys) { if ($k -ieq 'apim-request-id') { $requestId = @($resp.Headers[$k])[0] } }

    # Judge failure by the HTTP status ONLY. A 200 can carry a nested error
    # object (Defender for AI's 408 timeout, above) on a response that was
    # served and billed. Surface a real rejection instead of reporting it as
    # "no usage": the difference between a visible outage and a silent
    # revenue leak.
    if ($status -lt 200 -or $status -ge 300) {
        $code = $null; $msg = $null
        try {
            $e    = ($body | ConvertFrom-Json -ErrorAction Stop).error
            $code = if ($e.code) { $e.code } else { $e.type }
            $msg  = $e.message
        } catch { }
        if (-not $msg) {
            $msg = $body -replace '\s+', ' '
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
        }
        Write-Warning ("{0} call to '{1}' failed: HTTP {2} [{3}] {4} (apim-request-id {5})" -f `
            $prof.Provider, $Deployment, $status, $code, $msg, $requestId)
        return
    }

    # Usage objects nest at most two levels ('prompt_tokens_details',
    # 'cache_creation'). JSON escaping turns any model-authored quotes into
    # \" so generated text cannot forge a "usage" key. Take the LAST match:
    # streams repeat or update usage, and the final object is complete.
    $usage = $null
    $hits  = [regex]::Matches($body, '"usage"\s*:\s*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}')
    if ($hits.Count -gt 0) {
        try { $usage = ('{' + $hits[$hits.Count - 1].Value + '}' | ConvertFrom-Json).usage } catch { }
        if ($usage -and $hits.Count -gt 1 -and $prof.Api -eq 'AnthropicMessages') {
            # Fields only message_start carries (the 5m / 1h cache split)
            # are filled from the first usage object.
            try {
                $first = ('{' + $hits[0].Value + '}' | ConvertFrom-Json).usage
                foreach ($p in $first.PSObject.Properties) {
                    $cur = $usage.PSObject.Properties[$p.Name]
                    if (-not $cur -or $null -eq $cur.Value) {
                        $usage | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                    }
                }
            } catch { }
        }
    }

    if (-not $usage) {
        # Two distinct causes, and they need different responses:
        #
        #  a) include_usage was not set on a streamed OpenAI-path call. That is
        #     a code defect and under-bills every streamed request silently.
        #
        #  b) The response body came back EMPTY - no SSE frames, no error JSON.
        #     Seen once during development; NOT reproducible. 120 back-to-back
        #     streamed gpt-4.1-mini calls with include_usage set (60 with no
        #     pause, 60 at 150 ms apart, 2026-10-07) all returned a usage block:
        #     0 empty bodies. Treat it as rare rather than as a rate. The caller
        #     gets nothing either, so it surfaces as a failed request rather
        #     than a silent under-bill, but the tokens may still have been
        #     consumed upstream.
        #
        # In both cases: never record zero. Azure Monitor counts this traffic
        # independently, so the reconciliation tier is what recovers it.
        if ($Stream -and $prof.UsesStreamOptions) {
            Write-Warning ("No usage block on streamed call to '{0}' (apim-request-id {1}). Either include_usage was dropped or the response body was empty. Do NOT bill zero - reconcile this window against Azure Monitor." -f $Deployment, $requestId)
        } else {
            Write-Warning ("No usage block returned by {0} deployment '{1}' (apim-request-id {2}). Do NOT bill zero - reconcile against Azure Monitor." -f $prof.Provider, $Deployment, $requestId)
        }
        return
    }

    $n = ConvertTo-NormalizedUsage -Usage $usage -ProviderProfile $prof

    $tierHits = [regex]::Matches($body, '"service_tier"\s*:\s*"([^"]+)"')
    $tierRaw  = if ($tierHits.Count -gt 0) { $tierHits[$tierHits.Count - 1].Groups[1].Value.ToLowerInvariant() } else { $null }
    $tierKey  = if ($tierRaw -in 'priority', 'flex') { $tierRaw } else { 'default' }

    $latency = $null
    $latHits = [regex]::Matches($body, '"latency_checkpoint"\s*:\s*\{[^{}]*\}')
    if ($latHits.Count -gt 0) {
        try { $latency = ('{' + $latHits[$latHits.Count - 1].Value + '}' | ConvertFrom-Json).latency_checkpoint } catch { }
    }

    # The model that served the request, versioned ('gpt-4.1-2025-04-14').
    # For model-router it is the routed model, which decides the price.
    $modelHits = [regex]::Matches($body, '"model"\s*:\s*"([^"]+)"')
    $served    = if ($modelHits.Count -gt 0) { $modelHits[$modelHits.Count - 1].Groups[1].Value } else { $null }

    $complete = $null
    if ($Stream) {
        $complete = ($body -match '(?m)^data:\s*\[DONE\]') -or ($body -match '(?m)^event:\s*message_stop')
        if (-not $complete) {
            Write-Warning ("Stream from '{0}' ended without its terminator (apim-request-id {1}); the usage may be partial - reconcile against Azure Monitor." -f $Deployment, $requestId)
        }
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    if ($tierRaw -and $tierRaw -notin 'default', 'standard', 'priority', 'flex') {
        $notes.Add("Unrecognised service_tier '$tierRaw', priced at the default tier.")
    }
    elseif (-not $tierRaw -and $ServiceTier -in 'priority', 'flex') {
        $notes.Add("Requested '$ServiceTier' but the response reported no service_tier; priced at the default tier.")
    }

    # Cost at response time. Null - never 0 - when it cannot be known, and
    # BillingModel says which kind of null this is.
    $cost    = $null
    $billing = if ($PriceEntry) { $PriceEntry.BillingModel } else { 'NoMeter' }
    switch ($billing) {
        'Marketplace' { $notes.Add('Billed through Azure Marketplace, not on the account: tokens are exact, cost can only be estimated.') }
        'Capacity'    { $notes.Add($PriceEntry.Note) }
        'Router' {
            if (-not $served) { $notes.Add('The response named no model, so the routed rates are unknown.'); break }
            $routed = Get-RoutedPrice -RouterEntry $PriceEntry -ModelName $served
            $rates  = $routed.Tiers[$tierKey]
            if ($routed.BillingModel -ne 'Derived' -or -not $rates) {
                $why = if ($routed.Note) { $routed.Note } else { "no $tierKey-tier meter" }
                $notes.Add("No list price for routed model '$served': $why"); break
            }
            if ($null -eq $PriceEntry.RouterPer1M) { $notes.Add($PriceEntry.Note); break }
            $c = Measure-TokenCost -Rates $rates -InputTokens $n.InputTokens -CachedTokens $n.CachedReadTokens `
                     -CacheWriteTokens $n.CacheWriteTokens -OutputTokens $n.OutputTokens
            if ($null -eq $c.Cost) { $notes.Add($c.Note); break }
            # The fee applies to every prompt token. Billing showed the fee
            # quantity equal to the router's input tokens; whether cached
            # prompt tokens attract it was not separately verified.
            $fee  = [decimal]$PriceEntry.RouterPer1M * [decimal]($n.InputTokens + $n.CachedReadTokens + $n.CacheWriteTokens) / 1000000
            $cost = [double][math]::Round([decimal]$c.Cost + $fee, 8)
            $notes.Add("Routed to $served; includes the router fee ($($PriceEntry.RouterMeter)).")
            if ($c.Note) { $notes.Add($c.Note) }
        }
        'Derived' {
            $rates = $PriceEntry.Tiers[$tierKey]
            if (-not $rates) { $notes.Add("No list price for the '$tierKey' service tier on this model."); break }
            $c = Measure-TokenCost -Rates $rates -InputTokens $n.InputTokens -CachedTokens $n.CachedReadTokens `
                     -CacheWriteTokens $n.CacheWriteTokens -OutputTokens $n.OutputTokens
            $cost = $c.Cost
            if ($c.Note) { $notes.Add($c.Note) }
            if ($rates.ContextTier -eq 'Short') { $notes.Add('Priced at the Short context band.') }
        }
        default {
            $notes.Add($(if ($PriceEntry -and $PriceEntry.Note) { $PriceEntry.Note } else { 'No price entry for this deployment.' }))
        }
    }
    if ($n.ReasoningInOutput -is [bool] -and -not $n.ReasoningInOutput) {
        $notes.Add("$($n.ReasoningTokens) reasoning tokens were reported outside completion_tokens and are not priced; for grok-4.3 Azure billed completion_tokens only (Cost Management, Oct 2026).")
    }

    [pscustomobject]@{
        Tenant            = $TenantTag
        Provider          = $n.Provider
        Deployment        = $Deployment
        ServedModel       = $served
        Streamed          = [bool]$Stream
        StreamComplete    = $complete
        RequestId         = $requestId
        ServiceTier       = $tierRaw
        InputTokens       = $n.InputTokens
        CachedTokens      = $n.CachedReadTokens
        CacheWrite        = $n.CacheWriteTokens
        OutputTokens      = $n.OutputTokens
        Reasoning         = $n.ReasoningTokens
        ReasoningInOutput = $n.ReasoningInOutput
        TotalTokens       = $n.TotalTokens
        ReportedTotal     = $n.ReportedTotal
        CostUSD           = $cost
        BillingModel      = $billing
        CostNote          = ($notes -join ' ')
        # Whole-response time as this buffered client sees it; for a stream
        # that is time to LAST token, not first.
        WallClockMs       = [int]$sw.ElapsedMilliseconds
        EngineTtftMs      = $latency.engine_ttft_ms
        ServiceTtftMs     = $latency.service_ttft_ms
        Latency           = $latency
    }
}

# ---------------------------------------------------------------------------
# 4. TOKEN USAGE  -  Azure Monitor metrics
#
#    One query covers every publisher on the account: InputTokens,
#    OutputTokens and TotalTokens split by deployment, model and version.
#    Read key point #1 before summing anything. Token counts are exact, not
#    sampled.
#
#    VERIFIED BEHAVIOUR (Oct 2026)
#      * Lag: a request appeared 48-60 s after its response, in the minute
#        bucket after the one its Date header falls in.
#      * interval=FULL returns one total per series, equal to the sum of the
#        fine-grain points. PT1M over 7 days fails (HTTP 400: the response
#        would pass 8 MB), so ask for FULL unless you need the time series.
#      * One request covers at most 31 days; a longer timespan is silently
#        shortened to its last 31 days (HTTP 200).
#      * top defaults to 10 series. Set it, or a busy account is truncated.
#      * Metadata names come back lowercase ('modeldeploymentname').
#      * ModelRequests counts failed calls too - 400, 404, 408, 429, 499 -
#        so split it by StatusCode. claude-opus-5 logged over 3,000 HTTP 429s
#        in 30 days, as requests with no tokens.
#      * For model-router, ModelName is the model each request was routed to,
#        but ModelVersion on the token metrics is the ROUTER's version
#        (2025-11-18) whatever model served; ModelRequests carries the served
#        model's own version. Token metrics have also reported '__Empty' as a
#        version. Take a deployment's version from its successful requests.
#      * Claude cache traffic has its own metrics: cacheReadInputTokens,
#        ephemeral5mInputTokens and ephemeral1hInputTokens (which also split
#        by ContextLength). There is no cached-token count for the OpenAI
#        path: those cache hits are inside InputTokens, invisible here.
#      * ProcessedPromptTokens / GeneratedTokens split by ServiceTierResponse
#        ('default', 'priority', 'flex') - the only metrics that show which
#        tier tokens ran at - but have NO ModelName dimension, and only
#        OpenAI models report them (none for Claude, DeepSeek or grok).
#      * The token metrics do not reconcile exactly. TotalTokens -
#        InputTokens - OutputTokens is xAI's unbilled reasoning; elsewhere it
#        is usually 0, but daily totals were off by up to 0.04% on gpt-6-astra
#        (either sign) and up to -1% on claude-opus-5-5. Claude's TotalTokens
#        leaves out cache reads and writes. On model-router, OutputTokens ran
#        above the billed output (36 against 32 on one day); GeneratedTokens
#        matched it.
#      * FoundryModelEstimatedCost is not a bill: for gpt-6-astra it showed
#        $147.62 over 7 days against $4,072.34 billed.
# ---------------------------------------------------------------------------
function Get-TokenUsage {
    param(
        [Parameter(Mandatory)][string] $ResourceId,
        [Parameter(Mandatory)][string] $Token,
        [ValidateRange(1, 44640)][int] $LookbackMins = 60,
        [int] $Top = 1000
    )

    $inv   = [cultureinfo]::InvariantCulture
    $end   = [datetime]::UtcNow
    $start = $end.AddMinutes(-$LookbackMins)
    $fmt   = "yyyy-MM-dd'T'HH':'mm':'ss'Z'"
    $span  = $start.ToString($fmt, $inv) + '/' + $end.ToString($fmt, $inv)

    $query = {
        param([string] $Metrics, [string] $Filter)
        $uri = "https://management.azure.com$ResourceId/providers/microsoft.insights/metrics" +
               "?api-version=2024-02-01&metricnames=$Metrics&timespan=$span&interval=FULL" +
               "&aggregation=Total&top=$Top&`$filter=" + [uri]::EscapeDataString($Filter)
        $resp = Invoke-ArmWithRetry -Uri $uri -Token $Token

        $from = $null
        if ($resp.timespan) {
            $from = [datetimeoffset]::Parse(($resp.timespan -split '/')[0], $inv).UtcDateTime
            if ($from -gt $start.AddMinutes(5)) {
                Write-Warning "Azure Monitor returned data from $($from.ToString('u', $inv)) only, not $($start.ToString('u', $inv)): one request covers at most 31 days."
            }
        }
        foreach ($metric in @($resp.value)) {
            $series = @($metric.timeseries)
            if ($series.Count -ge $Top) {
                Write-Warning "$($metric.name.value): $($series.Count) series returned, the -Top limit. Totals may be truncated; raise -Top."
            }
            foreach ($s in $series) {
                $md = @{}
                foreach ($mv in @($s.metadatavalues)) { $md[$mv.name.value] = $mv.value }
                $total = [long]0
                foreach ($pt in @($s.data)) { if ($null -ne $pt.total) { $total += [long]$pt.total } }
                if ($total -le 0) { continue }
                [pscustomobject]@{
                    Timespan    = $resp.timespan
                    Metric      = $metric.name.value
                    Deployment  = $md['modeldeploymentname']
                    Model       = $md['modelname']
                    Version     = $md['modelversion']
                    ServiceTier = $md['servicetierresponse']
                    StatusCode  = $md['statuscode']
                    Total       = $total
                }
            }
        }
    }

    # (a) Token totals, every publisher. Required.
    & $query 'InputTokens,OutputTokens,TotalTokens' `
             "ModelDeploymentName eq '*' and ModelName eq '*' and ModelVersion eq '*'"
    # (b) Request counts by HTTP status. Required: unsplit, ModelRequests
    # mixes failed calls in with the served ones.
    & $query 'ModelRequests' `
             "ModelDeploymentName eq '*' and ModelName eq '*' and ModelVersion eq '*' and StatusCode eq '*'"

    # (c) Claude cache metrics. (d) Tokens per service tier. Both optional:
    # an account without such traffic must not fail the whole call.
    try {
        & $query 'cacheReadInputTokens,ephemeral5mInputTokens,ephemeral1hInputTokens' `
                 "ModelDeploymentName eq '*' and ModelName eq '*' and ModelVersion eq '*'"
    } catch { Write-Warning "Claude cache metrics unavailable: $($_.Exception.Message)" }
    try {
        & $query 'ProcessedPromptTokens,GeneratedTokens' "ModelDeploymentName eq '*' and ServiceTierResponse eq '*'"
    } catch { Write-Warning "Service-tier metrics unavailable: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# 5. THE JOIN  -  near-real-time cost: Monitor tokens (4) x list prices (2)
#
#    About a minute behind instead of hours. An estimate, for these reasons:
#      * It prices InputTokens and OutputTokens, as Azure bills them - not
#        TotalTokens - InputTokens, which would bill xAI reasoning that Azure
#        did not charge for. TotalTokens - InputTokens - OutputTokens is
#        reported as ResidualTokens, for diagnosis only: xAI reasoning, or a
#        small skew between the metrics (section 4).
#      * OpenAI-path InputTokens include cached tokens and Monitor does not
#        break them out, so all input is priced uncached. On gpt-6-astra
#        (96.2% of input cached) that came to $18,150 against $2,963.56
#        billed - about 6.1x. Nor is it a strict upper bound: cache writes
#        bill above the input rate.
#      * Models priced only in Short and Long context bands are priced at
#        Short. Long-context requests bill higher (input x2, output x1.5 to x2).
#      * A deployment that served Priority or Flex traffic is priced per tier
#        from ProcessedPromptTokens / GeneratedTokens.
#      * List prices: no EA, MACC or negotiated discount.
#
#    BillingModel says why a cost is null:
#      Derived      priced from the Retail Prices API
#      Router       router fee + the routed model's rates
#      Marketplace  Claude: billed through Azure Marketplace (section 6)
#      Capacity     provisioned throughput: billed per hour, not per token
#      NoMeter      no list price - a coverage gap to alert on
# ---------------------------------------------------------------------------
function Get-NearRealTimeCost {
    param(
        $Usage,
        [Parameter(Mandatory)][hashtable] $PriceOf,              # deployment -> Resolve-ModelPrice entry
        [hashtable] $PublisherOfDeployment = @{}
    )

    function Get-Sum($rows, [string] $metric) {
        [long](($rows | Where-Object Metric -eq $metric | Measure-Object Total -Sum).Sum)
    }

    $tierMetrics = 'ProcessedPromptTokens', 'GeneratedTokens'
    $tokenRows   = @($Usage | Where-Object { $_.Metric -notin $tierMetrics })
    $tierRows    = @($Usage | Where-Object { $_.Metric -in $tierMetrics })

    foreach ($dg in ($tokenRows | Group-Object Deployment)) {
        $dep   = $dg.Name
        $entry = $PriceOf[$dep]
        $billing = if ($entry) { $entry.BillingModel } else { 'NoMeter' }

        # A router deployment serves several models at different rates, so
        # it gets one row per routed model; any other deployment, one row.
        # Not split by version: the router's token metrics carry its own.
        $parts = [System.Collections.Generic.List[object]]::new()
        if ($billing -eq 'Router') { foreach ($g in ($dg.Group | Group-Object Model)) { $parts.Add(@($g.Group)) } }
        else                       { $parts.Add(@($dg.Group)) }

        foreach ($rows in $parts) {
            $in  = Get-Sum $rows 'InputTokens'
            $out = Get-Sum $rows 'OutputTokens'
            $tot = Get-Sum $rows 'TotalTokens'
            $okRows   = @($rows | Where-Object { $_.Metric -eq 'ModelRequests' -and (-not $_.StatusCode -or "$($_.StatusCode)" -like '2*') })
            $okCount  = [long](($okRows | Measure-Object Total -Sum).Sum)
            $models   = @($rows.Model | Where-Object { $_ } | Sort-Object -Unique)
            # The version that served, from successful requests only. Outside
            # a router, the token metrics' version will do as a fallback.
            $versions = @($okRows.Version | Where-Object { $_ -and $_ -ne '__Empty' } | Sort-Object -Unique)
            if (-not $versions -and $billing -ne 'Router') {
                $versions = @(($rows | Where-Object Metric -ne 'ModelRequests').Version | Where-Object { $_ -and $_ -ne '__Empty' } | Sort-Object -Unique)
            }
            $pub      = $PublisherOfDeployment[$dep]
            $cost = $null; $basis = $null; $split = $null
            $notes = [System.Collections.Generic.List[string]]::new()

            switch ($billing) {
                'Marketplace' { $notes.Add('Claude: billed through Azure Marketplace (section 6). Tokens are exact; cost is not on the account.') }
                'Capacity'    { $notes.Add($entry.Note) }
                'NoMeter'     { $notes.Add($(if ($entry) { $entry.Note } else { "'$dep' is not a current deployment on the account." })) }
                'Router' {
                    $basis = 'InputTokens x (router fee + routed input) + OutputTokens x routed output'
                    if (-not $models) { $notes.Add('No routed model name in Monitor.'); break }
                    if ($models[0] -eq 'model-router') { $notes.Add('Not attributed to a routed model.'); break }
                    # The routed model's own version picks between dated
                    # meters (gpt-4o 0513 / 0806 / 1120 differ 2x).
                    $routed = Get-RoutedPrice -RouterEntry $entry -ModelName $models[0] -Version $(if ($versions.Count -eq 1) { $versions[0] })
                    $pub    = $routed.Publisher
                    $rates  = $routed.Tiers['default']
                    if (-not $rates)                     { $notes.Add("No list price for routed model '$($models[0])': $($routed.Note)"); break }
                    if ($null -eq $entry.RouterPer1M)    { $notes.Add($entry.Note); break }
                    if ($out -gt 0 -and $null -eq $rates.OutputPer1M) { $notes.Add("No output rate for routed model '$($models[0])'."); break }
                    [decimal] $acc = [decimal]$in * ([decimal]$entry.RouterPer1M + [decimal]$rates.InputPer1M)
                    if ($out -gt 0) { $acc += [decimal]$out * [decimal]$rates.OutputPer1M }
                    $cost = [double][math]::Round($acc / 1000000, 8)
                    $notes.Add('Cached prompt tokens are not visible in Monitor; all input priced uncached.')
                }
                'Derived' {
                    $byTier = @{}
                    foreach ($t in @($tierRows | Where-Object Deployment -eq $dep)) {
                        $k = if ("$($t.ServiceTier)" -in 'priority', 'flex') { "$($t.ServiceTier)".ToLowerInvariant() } else { 'default' }
                        if (-not $byTier.ContainsKey($k)) { $byTier[$k] = @{ PP = [long]0; Gen = [long]0 } }
                        if ($t.Metric -eq 'ProcessedPromptTokens') { $byTier[$k].PP += $t.Total } else { $byTier[$k].Gen += $t.Total }
                    }
                    $otherTiers = @($byTier.Keys | Where-Object { $_ -ne 'default' -and ($byTier[$_].PP + $byTier[$_].Gen) -gt 0 })
                    if ($otherTiers.Count -gt 0) {
                        # Priority / Flex traffic: price each tier's tokens at
                        # its own meters. A tier with no meter makes the whole
                        # figure unknown rather than understated.
                        $basis = 'ProcessedPromptTokens / GeneratedTokens per service tier'
                        $split = (@($byTier.Keys | Sort-Object | ForEach-Object { "$_ $($byTier[$_].PP)/$($byTier[$_].Gen)" }) -join '; ')
                        [decimal] $acc = 0; $known = $true
                        foreach ($k in ($byTier.Keys | Sort-Object)) {
                            $pp = $byTier[$k].PP; $gen = $byTier[$k].Gen
                            if ($pp + $gen -eq 0) { continue }
                            $rates = $entry.Tiers[$k]
                            if (-not $rates -or ($gen -gt 0 -and $null -eq $rates.OutputPer1M)) {
                                $known = $false; $notes.Add("$pp prompt / $gen generated tokens ran at the '$k' tier, which has no list price here."); continue
                            }
                            $acc += [decimal]$pp * [decimal]$rates.InputPer1M
                            if ($gen -gt 0) { $acc += [decimal]$gen * [decimal]$rates.OutputPer1M }
                        }
                        if ($known) { $cost = [double][math]::Round($acc / 1000000, 8) }
                    }
                    else {
                        $basis = 'InputTokens x input + OutputTokens x output (default tier)'
                        $c = Measure-TokenCost -Rates $entry.Tiers['default'] -InputTokens $in -OutputTokens $out
                        $cost = $c.Cost
                        if ($c.Note) { $notes.Add($c.Note) }
                    }
                    if ($entry.Tiers['default'].ContextTier -eq 'Short') { $notes.Add('Short context band assumed.') }
                    $notes.Add('Cached prompt tokens are not visible in Monitor; all input priced uncached.')
                }
            }

            [pscustomobject]@{
                Deployment       = $dep
                Model            = ($models -join ',')
                Version          = ($versions -join ',')
                Publisher        = $pub
                Requests         = $okCount
                FailedRequests   = (Get-Sum $rows 'ModelRequests') - $okCount
                InputTokens      = $in
                OutputTokens     = $out
                TotalTokens      = $tot
                ResidualTokens   = $tot - $in - $out
                CacheReadTokens  = Get-Sum $rows 'cacheReadInputTokens'
                CacheWriteTokens = (Get-Sum $rows 'ephemeral5mInputTokens') + (Get-Sum $rows 'ephemeral1hInputTokens')
                TierSplit        = $split
                EstCostUSD       = $cost
                BillingModel     = $billing
                Basis            = $basis
                Note             = ($notes -join ' ')
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 6. BILLED COST  -  Cost Management Query API
#
#    The invoice view: hours behind (over 5 hours observed) and heavily
#    throttled. Run it on a schedule and cache the result - never on a
#    user-facing path.
#
#    VERIFIED BEHAVIOUR (Oct 2026)
#      * timePeriod requires timeframe 'Custom', and 'Custom' requires
#        timePeriod; either mismatch is HTTP 400. Usage dates are UTC days.
#      * 429s carry x-ms-ratelimit-microsoft.costmanagement-{qpu,entity,
#        tenant,clienttype}-retry-after headers (Invoke-ArmWithRetry).
#      * Pages continue at properties.nextLink: POST the same body to it.
#      * Filters are case-insensitive.
#      * The 'deployment' tag (value lowercased) joins rows to Monitor's
#        ModelDeploymentName. Some meters on the account carry no deployment
#        tag: 'Standard Tokens' (Defender for AI), 'Platform Logs Data
#        Processed', 'Hosted Memory Usage' and 'Hosted vCPU Usage'.
#      * UnitOfMeasure differs by meter ('1M', '1K', '1 Hour', '1 GB'): add up
#        cost, never quantities across meters.
#      * model-router bills a fee meter ('Model Routers GL 1M Tokens') plus
#        the routed models' own meters, all under the router's deployment tag.
#      * Claude is not on the account. Its charges are on Marketplace SaaS
#        resources (MeterCategory 'SaaS'; here, in the account's resource
#        group), queried separately below; free test plans show as $0. Those
#        rows carry no deployment tag, and a resource's name does not say
#        which deployment it bills: one named 'claude-opus-5-5-...' carried
#        claude-opus-5's usage - its daily CCU followed that deployment's
#        Monitor tokens, idle days included, and began six days before any
#        deployment named claude-opus-5-5 existed - while another of the
#        same name carried claude-opus-5-5's. Neither ARM nor Resource Graph
#        returned these resource IDs. What the name does carry is the first
#        15 characters of the account's internalId.
# ---------------------------------------------------------------------------
function Get-BilledCost {
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $AccountResourceId,
        [Parameter(Mandatory)][string] $Token,
        [string] $AccountInternalId,    # the account's properties.internalId
        [ValidateRange(0, 365)][int] $Days = 5
    )

    $inv   = [cultureinfo]::InvariantCulture
    $today = [datetime]::UtcNow.Date
    $uri   = "https://management.azure.com/subscriptions/$SubscriptionId" +
             "/providers/Microsoft.CostManagement/query?api-version=2024-08-01"

    $newBody = {
        param($Grouping, $Filter)
        @{
            type       = 'ActualCost'
            timeframe  = 'Custom'
            timePeriod = @{
                from = $today.AddDays(-$Days).ToString("yyyy-MM-dd'T00:00:00Z'", $inv)
                to   = $today.ToString("yyyy-MM-dd'T23:59:59Z'", $inv)
            }
            dataset    = @{
                granularity = 'None'
                aggregation = @{
                    totalCost     = @{ name = 'Cost';          function = 'Sum' }
                    totalQuantity = @{ name = 'UsageQuantity'; function = 'Sum' }
                }
                grouping    = $Grouping
                filter      = $Filter
            }
        }
    }
    $runQuery = {
        param($Body)
        $next = $uri
        while ($next) {
            $resp = Invoke-ArmWithRetry -Uri $next -Method Post -Body $Body -Token $Token
            $cols = @($resp.properties.columns.name)
            foreach ($row in @($resp.properties.rows)) {
                $o = @{}
                for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
                $o
            }
            $next = $resp.properties.nextLink
        }
    }

    # The Foundry account, per deployment tag and meter.
    $accountBody = & $newBody `
        @(@{ type = 'TagKey'; name = 'deployment' }, @{ type = 'Dimension'; name = 'Meter' }, @{ type = 'Dimension'; name = 'UnitOfMeasure' }) `
        @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @($AccountResourceId) } }
    foreach ($o in (& $runQuery $accountBody)) {
        [pscustomobject]@{
            Source     = 'Foundry account'
            Deployment = if ($o['TagValue']) { $o['TagValue'] } else { '(untagged)' }
            Resource   = $null
            Meter      = $o['Meter']
            Unit       = $o['UnitOfMeasure']
            Quantity   = $o['UsageQuantity']
            Cost       = $o['Cost']
            Currency   = $o['Currency']
        }
    }

    # Claude: Marketplace SaaS resources, from the whole subscription. A name
    # ending '-<15 hex>-<32 hex>' carries an account's internalId prefix:
    # kept when it is this account's, dropped when another's, wherever the
    # resource group. Any other SaaS row is kept only if it is in the
    # account's resource group and its meter or resource names Claude - a
    # name match, which is all the data offers. Reported per resource, never
    # per deployment (see above).
    $saasBody = & $newBody `
        @(@{ type = 'Dimension'; name = 'ResourceId' }, @{ type = 'Dimension'; name = 'Meter' }, @{ type = 'Dimension'; name = 'UnitOfMeasure' }) `
        @{ dimensions = @{ name = 'MeterCategory'; operator = 'In'; values = @('SaaS') } }
    $idPrefix = if ($AccountInternalId.Length -ge 15) { $AccountInternalId.Substring(0, 15) }
    foreach ($o in (& $runQuery $saasBody)) {
        $id   = "$($o['ResourceId'])"
        $name = ($id -split '/')[-1]
        if ($idPrefix -and $name -match '-([0-9a-f]{15})-[0-9a-f]{32}$') {
            if ($Matches[1] -ne $idPrefix) { continue }
        }
        elseif ($id -notmatch "/resourcegroups/$([regex]::Escape($ResourceGroup))/" -or
                ("$($o['Meter'])" -notmatch 'claude' -and $name -notmatch '^claude')) { continue }
        [pscustomobject]@{
            Source     = 'Marketplace'
            Deployment = $null
            Resource   = $name
            Meter      = $o['Meter']
            Unit       = $o['UnitOfMeasure']
            Quantity   = $o['UsageQuantity']
            Cost       = $o['Cost']
            Currency   = $o['Currency']
        }
    }
}

# =============================== DEMO =======================================

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "The Azure CLI ('az') is required: https://learn.microsoft.com/cli/azure/install-azure-cli - then sign in with 'az login'."
}
if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $SubscriptionId) { throw "No Azure CLI subscription. Run 'az login', or pass -SubscriptionId." }
}
$armToken = Get-EntraToken -Resource 'https://management.azure.com' -SubscriptionId $SubscriptionId

if (-not $ResourceGroup) {
    $found = @(Get-ArmCollection -Token $armToken `
                 -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CognitiveServices/accounts?api-version=2024-10-01" |
               Where-Object { $_.name -eq $AccountName })
    if ($found.Count -ne 1) {
        throw "Found $($found.Count) accounts named '$AccountName' in subscription $SubscriptionId. Check the name, or pass -ResourceGroup."
    }
    $ResourceGroup = ($found[0].id -split '/')[4]
}
$accountId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName"
$account   = Invoke-ArmWithRetry -Uri "https://management.azure.com${accountId}?api-version=2024-10-01" -Token $armToken
if (-not $Region) { $Region = $account.location }
# The 'AI Foundry API' endpoint (<account>.services.ai.azure.com) serves every
# publisher. Accounts of kind 'OpenAI' have only properties.endpoint.
$endpoint = $account.properties.endpoints.'AI Foundry API'
if (-not $endpoint) { $endpoint = $account.properties.endpoint }

Write-Host "`nAccount $AccountName ($($account.kind), $($account.location)) in resource group $ResourceGroup" -ForegroundColor Green

# ---- 1 ----
Write-Host "`n=== 1. CATALOG AND DEPLOYMENTS (ARM, real time) ===" -ForegroundColor Cyan
$deployments = @(Get-FoundryDeployments -AccountResourceId $accountId -Token $armToken)
$catalog     = @(Get-FoundryModelCatalog -SubscriptionId $SubscriptionId -Region $Region -Token $armToken -Kind $account.kind)
Write-Host "$($catalog.Count) models deployable in $Region on an account of kind '$($account.kind)'; $($deployments.Count) deployments on $AccountName."

$catalogByName = @{}
foreach ($c in $catalog) { $catalogByName[$c.Name] = $c }
$deployments | Sort-Object Deployment | ForEach-Object {
    $c = $catalogByName[$_.Model]
    $v = if ($c -and $_.Version) { $c.ByVersion[[string]$_.Version] } else { $null }
    [pscustomobject]@{
        Deployment = $_.Deployment
        Model      = $_.Model
        Version    = $_.Version
        Publisher  = $_.Publisher
        Sku        = $_.Sku
        State      = $_.State
        # The DEPLOYED version's lifecycle, not the catalog default's.
        Lifecycle  = if ($v) { $v.Lifecycle } else { 'not in catalog' }
        Retires    = if ($v) { $v.InferenceRetirement } else { $null }
    }
} | Format-Table -AutoSize

# ---- 2 ----
Write-Host "=== 2. UNIT PRICING (Retail Prices API; list prices, cache daily) ===" -ForegroundColor Cyan
# Rates come from the real price table, never hardcoded: hardcoded rates in a
# cost path are what this repo argues against, so the demo does not use them.
$builder = Join-Path $PSScriptRoot 'Build-FoundryPriceTable.ps1'
if (-not (Test-Path $builder)) {
    throw "Build-FoundryPriceTable.ps1 must be next to this script: it builds the price table that sections 2, 3 and 5 use."
}
. $builder
$priceTable = Build-FoundryPriceTable -Region $Region -CachePath (Join-Path ([IO.Path]::GetTempPath()) "foundry-prices-$Region.json")
$built = $priceTable.BuiltAtUtc
if ($built -is [datetime]) { $built = $built.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) }
Write-Host "$($priceTable.MeterCount) token meters in $Region, built $built UTC. LIST prices - no negotiated discount."

$routerMeters = @()
if ($deployments.Model -contains 'model-router') {
    $routerMeters = @(Get-AzureRetailPrices -Filter "serviceName eq 'Foundry Tools' and armRegionName eq '$Region' and contains(meterName, 'Model Routers')")
}

# Publisher per model name, for models model-router routes to. The live
# deployment list is more authoritative than the regional catalog for models
# actually in use, so it wins.
$publisherOf = @{}
foreach ($c in $catalog)     { if ($c.Name  -and $c.Format)    { $publisherOf[$c.Name]  = $c.Format } }
foreach ($d in $deployments) { if ($d.Model -and $d.Publisher) { $publisherOf[$d.Model] = $d.Publisher } }

$priceOf = @{}
$publisherOfDeployment = @{}
foreach ($d in $deployments) {
    $publisherOfDeployment[$d.Deployment] = $d.Publisher
    $priceOf[$d.Deployment] = Resolve-ModelPrice -Table $priceTable -ModelName $d.Model -Publisher $d.Publisher `
        -Sku $d.Sku -Version $d.Version -RouterMeters $routerMeters -PublisherOf $publisherOf
}

$priceRows = foreach ($d in ($deployments | Sort-Object Deployment)) {
    $e = $priceOf[$d.Deployment]
    if ($e.BillingModel -eq 'Router') {
        [pscustomobject]@{ Deployment = $d.Deployment; Billing = 'Router'; Tier = '-'; Context = '-'
                           'Input/1M' = Format-Number $e.RouterPer1M; 'Cached/1M' = '-'; 'CacheWrite/1M' = '-'; 'Output/1M' = '-' }
        continue
    }
    if ($e.Tiers.Count -eq 0) {
        [pscustomobject]@{ Deployment = $d.Deployment; Billing = $e.BillingModel; Tier = '-'; Context = '-'
                           'Input/1M' = 'n/a'; 'Cached/1M' = 'n/a'; 'CacheWrite/1M' = 'n/a'; 'Output/1M' = 'n/a' }
        continue
    }
    foreach ($tier in 'default', 'priority', 'flex') {
        $r = $e.Tiers[$tier]
        if (-not $r) { continue }
        [pscustomobject]@{
            Deployment      = $d.Deployment
            Billing         = $e.BillingModel
            Tier            = $tier
            Context         = $r.ContextTier
            'Input/1M'      = Format-Number $r.InputPer1M
            'Cached/1M'     = Format-Number $r.CachedInputPer1M
            'CacheWrite/1M' = Format-Number $r.CacheWritePer1M
            'Output/1M'     = Format-Number $r.OutputPer1M
        }
    }
}
$priceRows | Format-Table -AutoSize
foreach ($d in ($deployments | Sort-Object Deployment)) {
    $e = $priceOf[$d.Deployment]
    if ($e.BillingModel -eq 'Router') {
        $feeText = if ($e.RouterMeter) { "'$($e.RouterMeter)' at `$$(Format-Number $e.RouterPer1M) per 1M input tokens" } else { $e.Note }
        Write-Host "  $($d.Deployment) [Router]: router fee $feeText, plus the routed model's own rates." -ForegroundColor DarkGray
    }
    elseif ($e.BillingModel -ne 'Derived') {
        Write-Host "  $($d.Deployment) [$($e.BillingModel)]: $($e.Note)" -ForegroundColor DarkYellow
    }
}

# ---- 3 ----
if ($SkipInference) {
    Write-Host "`n=== 3. INLINE METERING - skipped (-SkipInference) ===" -ForegroundColor Cyan
}
elseif (-not $deployments) {
    Write-Warning "No deployments on '$AccountName'; skipping inline metering."
}
else {
    Write-Host "`n=== 3. INLINE METERING (the inference response, per request) ===" -ForegroundColor Cyan
    # Exercise ONE deployment per publisher so provider-specific handling is
    # actually covered rather than assumed. A single-provider smoke test is how
    # the Anthropic and xAI defects survived in the first place.
    $targets = if ($Deployment) {
        @($deployments | Where-Object Deployment -eq $Deployment)
    } else {
        # Exclude non-chat deployments before picking. Embedding, audio and image
        # models carry format='OpenAI' too, so an unfiltered pick can hand a
        # chat-completions payload to an embedding deployment purely on ARM
        # ordering - a confusing first-run failure that looks like a bug here.
        # model-router is left to -Deployment: its price depends on where it
        # routes.
        @($deployments |
            Where-Object { $_.State -eq 'Succeeded' -and $_.Model -ne 'model-router' -and
                           $_.Model -notmatch 'embedding|whisper|tts|transcribe|dall-e|sora|image|audio|realtime|moderation' } |
            Sort-Object Deployment | Group-Object Publisher | ForEach-Object { $_.Group[0] })
    }
    if (-not $targets) { Write-Warning "Deployment '$Deployment' not found on '$AccountName'." }

    $aiToken = Get-EntraToken -Resource 'https://cognitiveservices.azure.com' -SubscriptionId $SubscriptionId
    $msgs    = @(@{ role = 'user'; content = 'Reply with exactly: ok' })
    $inline  = @(foreach ($t in $targets) {
        foreach ($s in $false, $true) {
            Invoke-MeteredCompletion -Endpoint $endpoint -Deployment $t.Deployment -Publisher $t.Publisher `
                -Messages $msgs -PriceEntry $priceOf[$t.Deployment] -MaxTokens 16 -Stream:$s `
                -Token $aiToken -TenantTag "tenant-$($t.Publisher)"
        }
    }) | Where-Object { $_ }

    $inline | Format-Table Provider, Deployment, Streamed,
        @{ n = 'Tier';      e = { $_.ServiceTier } },
        @{ n = 'In';        e = { $_.InputTokens } },
        @{ n = 'Cached';    e = { $_.CachedTokens } },
        @{ n = 'Out';       e = { $_.OutputTokens } },
        @{ n = 'Reasoning'; e = { $_.Reasoning } },
        @{ n = 'CostUSD';   e = { Format-Number $_.CostUSD } },
        @{ n = 'Ms';        e = { $_.WallClockMs } },
        @{ n = 'TTFT';      e = { $_.EngineTtftMs } } -AutoSize
    foreach ($r in $inline) {
        $tail = if ($r.CostNote) { " $($r.CostNote)" } else { '' }
        Write-Host ("  {0} ({1}) served by {2}, apim-request-id {3}.{4}" -f $r.Deployment, $(if ($r.Streamed) { 'stream' } else { 'non-stream' }), $r.ServedModel, $r.RequestId, $tail) -ForegroundColor DarkGray
    }
}

# ---- 4 ----
Write-Host "`n=== 4. TOKEN USAGE (Azure Monitor, last $LookbackMins min; about 1 min behind) ===" -ForegroundColor Cyan
if (-not $SkipInference) { Write-Host "Section 3's requests reach Monitor about a minute after they complete." -ForegroundColor DarkGray }
$usage = @(Get-TokenUsage -ResourceId $accountId -Token $armToken -LookbackMins $LookbackMins)
# Failed requests (429, 404, ...) are counted apart. Version is the one that
# successful requests ran on: on model-router the token metrics carry the
# router's own version, whichever model served.
$usage | Where-Object Metric -in 'InputTokens', 'OutputTokens', 'TotalTokens', 'ModelRequests' |
    Group-Object Deployment, Model | ForEach-Object {
        $g = $_.Group
        $sum = { param($m) [long](($g | Where-Object Metric -eq $m | Measure-Object Total -Sum).Sum) }
        $ok  = @($g | Where-Object { $_.Metric -eq 'ModelRequests' -and (-not $_.StatusCode -or "$($_.StatusCode)" -like '2*') })
        $okN = [long](($ok | Measure-Object Total -Sum).Sum)
        [pscustomobject]@{
            Deployment = $g[0].Deployment
            Model      = $g[0].Model
            Version    = (@($ok.Version | Where-Object { $_ -and $_ -ne '__Empty' } | Sort-Object -Unique) -join ',')
            Requests   = $okN
            Failed     = (& $sum 'ModelRequests') - $okN
            Input      = & $sum 'InputTokens'
            Output     = & $sum 'OutputTokens'
            Total      = & $sum 'TotalTokens'
            # Large for xAI: reasoning Azure did not bill. Elsewhere 0 or a
            # small skew of either sign (see section 4's notes).
            Residual   = (& $sum 'TotalTokens') - (& $sum 'InputTokens') - (& $sum 'OutputTokens')
        }
    } | Sort-Object Input -Descending | Format-Table -AutoSize
foreach ($g in ($usage | Where-Object Metric -notin 'InputTokens', 'OutputTokens', 'TotalTokens', 'ModelRequests' | Group-Object Metric)) {
    $parts = $g.Group | Group-Object Deployment, ServiceTier | ForEach-Object {
        $label = if ($_.Group[0].ServiceTier) { "$($_.Group[0].Deployment) ($($_.Group[0].ServiceTier))" } else { $_.Group[0].Deployment }
        "$label $(($_.Group | Measure-Object Total -Sum).Sum)"
    }
    Write-Host "  $($g.Name): $($parts -join '; ')" -ForegroundColor DarkGray
}

# ---- 5 ----
Write-Host "`n=== 5. NEAR-REAL-TIME COST (Monitor tokens x list prices) ===" -ForegroundColor Cyan
$nrt = @(Get-NearRealTimeCost -Usage $usage -PriceOf $priceOf -PublisherOfDeployment $publisherOfDeployment |
         Sort-Object InputTokens -Descending)
$nrt | Format-Table Deployment, Model, Version, Publisher,
    @{ n = 'Input';      e = { $_.InputTokens } },
    @{ n = 'Output';     e = { $_.OutputTokens } },
    @{ n = 'EstCostUSD'; e = { Format-Number $_.EstCostUSD } },
    @{ n = 'Billing';    e = { $_.BillingModel } } -AutoSize
foreach ($r in $nrt) {
    $extra = @()
    if ($r.TierSplit) { $extra += "tiers (prompt/generated): $($r.TierSplit)." }
    if ($r.CacheReadTokens -or $r.CacheWriteTokens) { $extra += "cache read $($r.CacheReadTokens), cache write $($r.CacheWriteTokens)." }
    if ($r.Note) { $extra += $r.Note }
    if ($extra) { Write-Host "  $($r.Deployment) / $($r.Model): $($extra -join ' ')" -ForegroundColor DarkGray }
}
$seen = @($nrt.Publisher | Where-Object { $_ } | Sort-Object -Unique)
if ($seen) { Write-Host "Publishers in this one Monitor query: $($seen -join ', ')" -ForegroundColor DarkGray }

# ---- 6 ----
if ($IncludeCost) {
    Write-Host "`n=== 6. BILLED COST (Cost Management; hours behind, throttled) ===" -ForegroundColor Cyan
    Write-Host "Last 5 UTC days plus today. Claude bills on Marketplace SaaS resources, tied to this account by its internalId - never per deployment." -ForegroundColor DarkGray
    $billed = @(Get-BilledCost -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AccountResourceId $accountId -AccountInternalId $account.properties.internalId -Token $armToken -Days 5)
    foreach ($src in ($billed | Group-Object Source)) {
        Write-Host "$($src.Name), top 30 rows by cost:"
        $top = $src.Group | Sort-Object { [double]$_.Cost } -Descending | Select-Object -First 30
        $cols = @(@{ n = 'Cost'; e = { Format-Number $_.Cost } }, 'Currency', @{ n = 'Quantity'; e = { Format-Number $_.Quantity } }, 'Unit', 'Meter')
        if ($src.Group[0].Deployment) { $top | Format-Table (@('Deployment') + $cols) -AutoSize }
        # SaaS resource and meter names run past 60 characters: a table per resource.
        else { $top | Sort-Object Resource | Format-Table $cols -GroupBy Resource -AutoSize -Wrap }
    }
    foreach ($g in ($billed | Group-Object Source, Currency)) {
        $sum = ($g.Group | Measure-Object Cost -Sum).Sum
        Write-Host ("  {0}: {1} {2} across {3} rows (quantities are not added: units differ by meter)." -f $g.Group[0].Source, (Format-Number ([math]::Round([double]$sum, 2))), $g.Group[0].Currency, $g.Count) -ForegroundColor DarkGray
    }
}

<#
.SYNOPSIS
    Reference sample: real-time pricing, model catalog, token usage and cost
    telemetry for an AI gateway built on Microsoft Foundry.

.DESCRIPTION
    Demonstrates the four Azure APIs an AI gateway needs to surface usage
    metrics to its own tenants, and shows the correct way to combine them.

      1. Model catalog   - ARM CognitiveServices models        (real time)
      2. Unit pricing    - Azure Retail Prices API             (static, cache daily)
      3. Token usage     - Azure Monitor metrics               (~3 min lag)
      4. Billed cost     - Cost Management Query API           (hours lag, throttled)

    KEY ARCHITECTURAL POINT
    Do not poll Cost Management for near-real-time cost. It lags by hours and is
    aggressively throttled. Instead compute cost yourself:

        cost = (InputTokens x inputUnitPrice) + (OutputTokens x outputUnitPrice)

    using Azure Monitor token metrics (per deployment, per model, 1-minute grain)
    and cached unit prices. Use Cost Management only for daily reconciliation.

.NOTES
    Auth: all four use Entra tokens. No API keys.
      - ARM / Monitor / Cost Management -> audience https://management.azure.com
      - Retail Prices API               -> anonymous, no auth, no subscription

    Required RBAC on the Foundry resource / subscription:
      - Monitoring Reader   (Azure Monitor metrics)
      - Cost Management Reader (Cost Management query)
      - Reader              (model catalog)
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId,
    [string] $ResourceGroup,
    [Parameter(Mandatory)][string] $AccountName,
    [string] $Region       = "eastus2",
    [string] $Deployment,
    [int]    $LookbackMins = 60,
    [switch] $IncludeCost
)

$ErrorActionPreference = "Stop"

function Get-ArmToken {
    az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
}

# Azure throttles several of these endpoints. Always back off rather than fail.
function Invoke-ArmWithRetry {
    param($Uri, $Method = "Get", $Body = $null, $Token, [int]$MaxAttempts = 6, [int]$DelaySec = 40)
    $headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            if ($Body) { return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $Body -ErrorAction Stop }
            else       { return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -ErrorAction Stop }
        }
        catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -ne 429 -or $i -eq $MaxAttempts) { throw }
            Write-Verbose "HTTP 429 on attempt $i; backing off $DelaySec s"
            Start-Sleep -Seconds $DelaySec
        }
    }
}

# ---------------------------------------------------------------------------
# 0. INLINE METERING  -  read `usage` straight off the inference response
#
#    THIS IS THE PRIMARY SOURCE FOR A GATEWAY. Zero lag.
#    The gateway already sits in the response path, so it can meter every
#    request at the moment it completes - no polling, no 3-minute delay.
#
#    *** CRITICAL GOTCHA ***
#    Streaming responses OMIT the usage block entirely unless the request sets
#        "stream_options": { "include_usage": true }
#    Verified: stream:true alone -> no usage. With include_usage -> usage in the
#    final SSE chunk. A gateway that forgets this silently loses token counts on
#    every streamed request and under-bills.
#
#    The gateway should INJECT include_usage into all upstream streaming calls
#    regardless of what the caller sent, then optionally strip the final usage
#    chunk before relaying to the client.
#
#    The response also carries latency_checkpoint (engine_ttft_ms, engine_tbt_ms,
#    engine_ttlt_ms, pre_inference_ms, service_ttft_ms) - per-request latency
#    telemetry for free, no extra API call.
# ---------------------------------------------------------------------------
function Invoke-MeteredCompletion {
    <#
      Minimal reference implementation of the metering wrapper a gateway would
      apply to every upstream call. Returns the model output plus exact token
      counts and the cost computed at response time.
    #>
    param(
        [Parameter(Mandatory)] $Endpoint,       # https://<account>.openai.azure.com
        [Parameter(Mandatory)] $Deployment,
        [Parameter(Mandatory)] $Messages,
        $PriceTable,
        [int]  $MaxTokens = 256,
        [switch] $Stream,
        $Token,
        [string] $TenantTag = "default"          # your own tenant/user attribution
    )

    if (-not $Token) {
        $Token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
    }

    $payload = [ordered]@{
        model      = $Deployment
        messages   = $Messages
        max_tokens = $MaxTokens
    }

    if ($Stream) {
        $payload.stream = $true
        # THE INJECTION. Without this the usage block never arrives.
        $payload.stream_options = @{ include_usage = $true }
    }

    # GetTempPath() rather than $env:TEMP: TEMP is unset on Linux/macOS pwsh, so
    # Join-Path would throw on a null path before any call was issued.
    # utf8NoBOM rather than ascii: ascii replaces every non-ASCII codepoint with
    # '?', silently mangling any non-English prompt before it reaches the model.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("req-" + [guid]::NewGuid().ToString('N') + ".json")
    ($payload | ConvertTo-Json -Depth 8 -Compress) | Set-Content $tmp -Encoding utf8NoBOM

    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $raw = curl.exe -s -N -X POST "$Endpoint/openai/v1/chat/completions" `
             -H "Authorization: Bearer $Token" -H "Content-Type: application/json" -d "@$tmp"
    $sw.Stop()
    Remove-Item $tmp -ErrorAction SilentlyContinue

    $joined = $raw -join ''

    # Streaming returns SSE frames; the usage block rides in the final chunk.
    $usage = $null
    $m = [regex]::Match($joined, '"usage":\s*\{(?:[^{}]|\{[^{}]*\})*\}')
    if ($m.Success) {
        try { $usage = ("{" + $m.Value + "}" | ConvertFrom-Json).usage } catch { }
    }

    if (-not $usage) {
        Write-Warning "No usage block returned. If this was a streaming call, stream_options.include_usage was not honoured."
        return $null
    }

    $inTok     = [int]$usage.prompt_tokens
    $outTok    = [int]$usage.completion_tokens
    $cachedTok = [int]$usage.prompt_tokens_details.cached_tokens

    $cost = $null
    $price = if ($PriceTable) { $PriceTable[$Deployment] } else { $null }
    if ($price) {
        # Cached input tokens bill at the cached rate when the model exposes one.
        $billableIn  = $inTok - $cachedTok
        $cachedRate  = if ($price.CachedInputPer1M) { $price.CachedInputPer1M } else { $price.InputPer1M }
        $cost = [math]::Round(
            ($billableIn / 1000000 * $price.InputPer1M) +
            ($cachedTok  / 1000000 * $cachedRate) +
            ($outTok     / 1000000 * $price.OutputPer1M), 8)
    }

    [pscustomobject]@{
        Tenant        = $TenantTag
        Deployment    = $Deployment
        Streamed      = [bool]$Stream
        InputTokens   = $inTok
        CachedTokens  = $cachedTok
        OutputTokens  = $outTok
        TotalTokens   = [int]$usage.total_tokens
        CostUSD       = $cost
        PriceKnown    = [bool]$price
        WallClockMs   = [int]$sw.ElapsedMilliseconds
        # Per-request latency telemetry, free with the response.
        TtftMs        = $usage.latency_checkpoint.engine_ttft_ms
        TbtMs         = $usage.latency_checkpoint.engine_tbt_ms
        TtltMs        = $usage.latency_checkpoint.engine_ttlt_ms
    }
}

# ---------------------------------------------------------------------------
# 1. MODEL CATALOG  -  what models exist, which SKUs, lifecycle status
#    Real time. This is the authoritative feed; there is no RSS or webhook.
# ---------------------------------------------------------------------------
function Get-FoundryModelCatalog {
    param($SubscriptionId, $Region, $Token)

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId" +
           "/providers/Microsoft.CognitiveServices/locations/$Region" +
           "/models?api-version=2024-06-01-preview"

    $resp = Invoke-ArmWithRetry -Uri $uri -Token $Token

    # The API returns one entry per SKU AND per version, so collapse to one row
    # per model name while UNIONING the SKUs. Keying on name alone and taking
    # the first entry wholesale would under-report which SKUs a model supports.
    $byName = [ordered]@{}
    foreach ($item in $resp.value) {
        $m = $item.model
        if (-not $byName.Contains($m.name)) {
            $byName[$m.name] = [pscustomobject]@{
                Name       = $m.name
                Version    = $m.version
                Format     = $m.format
                # GOTCHA: the ARM catalog's 'publisher' field is EMPTY on every
                # entry (verified: 328/328 null in eastus2). The publisher key
                # actually lives in 'format' - and its values ('OpenAI',
                # 'OpenAI-OSS', 'DeepSeek', 'Mistral AI', ...) are exactly what
                # Get-TokenPrice -Publisher expects. Reading 'publisher'
                # directly yields a silent null, not an error.
                Publisher  = if ($m.publisher) { $m.publisher } else { $m.format }
                Lifecycle  = $m.lifecycleStatus
                Skus       = [System.Collections.Generic.HashSet[string]]::new()
                Versions   = [System.Collections.Generic.HashSet[string]]::new()
                # usageName is the join key to quota; useful for capacity
                # dashboards. Guarded: $null[0] throws, and with
                # $ErrorActionPreference='Stop' one entry lacking a skus array
                # would abort the whole catalog call.
                UsageName  = if ($m.skus -and $m.skus.Count -gt 0) { $m.skus[0].usageName } else { $null }
            }
        }
        $row = $byName[$m.name]
        if ($m.version) { [void]$row.Versions.Add($m.version) }
        foreach ($s in $m.skus) { if ($s.name) { [void]$row.Skus.Add($s.name) } }
    }

    foreach ($row in $byName.Values) {
        [pscustomobject]@{
            Name       = $row.Name
            Version    = $row.Version
            Versions   = (($row.Versions | Sort-Object) -join ',')
            Format     = $row.Format
            Publisher  = $row.Publisher
            Lifecycle  = $row.Lifecycle
            Skus       = (($row.Skus | Sort-Object) -join ',')
            UsageName  = $row.UsageName
        }
    }
}

# ---------------------------------------------------------------------------
# 2. UNIT PRICING  -  Azure Retail Prices API
#    Anonymous, no subscription context. Prices change rarely: cache daily.
#
#    GOTCHAS (every one of these was hit in practice):
#
#      * serviceName is 'Foundry Models', NOT 'Cognitive Services'. The old
#        value now returns ZERO rows silently - an HTTP 200 with Count=0, not
#        an error. Any query still using it will look like "no pricing exists".
#
#      * unitOfMeasure is MIXED within the same service - both '1K' and '1M'
#        appear. You must normalise per row. Blindly multiplying retailPrice
#        by 1e6 overstates 1K-denominated meters by 1000x.
#
#      * productName spelling is inconsistent. 'Azure Deepseek Models' has a
#        lowercase 's' - contains(productName,'DeepSeek') returns zero rows.
#
#      * meterName uses abbreviations, not model IDs: 'Inp'/'Outp' for
#        input/output, 'glbl' for Global Standard, 'DZone' for Data Zone.
#        Searching for 'gpt-4.1' will not match 'gpt 4.1 Inp glbl Tokens'.
#
#      * Format-Table rounds to 2dp. Normalise BEFORE formatting or per-token
#        prices all render as 0.00 and the catalog looks free.
#
#      * Paginated via NextPageLink and throttled - handle both.
# ---------------------------------------------------------------------------
function Get-AzureRetailPrices {
    param([string] $Filter)

    $uri  = "https://prices.azure.com/api/retail/prices?`$filter=" + [uri]::EscapeDataString($Filter)
    $all  = @()
    $next = $uri
    $fail = 0

    while ($next) {
        try {
            $page = Invoke-RestMethod -Uri $next -ErrorAction Stop
            $all += $page.Items
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
            Region        = $item.armRegionName
            UnitOfMeasure = $item.unitOfMeasure
            RetailPrice   = $item.retailPrice
            PricePer1M    = if ($null -ne $per1M) { [math]::Round($per1M, 6) } else { $null }
        }
    }
}

# ---------------------------------------------------------------------------
# 3. TOKEN USAGE  -  Azure Monitor metrics
#    1-minute grain. Measured end-to-end lag from inference to visibility:
#    ~3 minutes. Token counts are exact, not sampled.
#
#    Dimensions: ApiName, Region, ModelDeploymentName, ModelName, ModelVersion
#    ModelRequests adds StatusCode, StreamType, IsSpillover, ServiceTierRequest.
# ---------------------------------------------------------------------------
function Get-TokenUsage {
    param($SubscriptionId, $ResourceGroup, $AccountName, $Token, [int]$LookbackMins = 60, [string]$Grain = "PT1M")

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
                  "/providers/Microsoft.CognitiveServices/accounts/$AccountName"

    $end   = (Get-Date).ToUniversalTime()
    $start = $end.AddMinutes(-$LookbackMins)
    $span  = "{0:yyyy-MM-ddTHH:mm:ssZ}/{1:yyyy-MM-ddTHH:mm:ssZ}" -f $start, $end

    # Splitting by both deployment and model lets the gateway attribute spend
    # to the tenant that owns the deployment.
    $filter = [uri]::EscapeDataString("ModelDeploymentName eq '*' and ModelName eq '*'")

    $uri = "https://management.azure.com$resourceId/providers/microsoft.insights/metrics" +
           "?api-version=2024-02-01" +
           "&metricnames=InputTokens,OutputTokens,TotalTokens,ModelRequests" +
           "&timespan=$span&interval=$Grain&aggregation=Total&`$filter=$filter"

    $resp = Invoke-ArmWithRetry -Uri $uri -Token $Token

    $rows = @()
    foreach ($metric in $resp.value) {
        foreach ($series in $metric.timeseries) {
            $dep   = ($series.metadatavalues | Where-Object { $_.name.value -eq 'modeldeploymentname' }).value
            $model = ($series.metadatavalues | Where-Object { $_.name.value -eq 'modelname' }).value
            foreach ($pt in ($series.data | Where-Object { $_.total -gt 0 })) {
                $rows += [pscustomobject]@{
                    TimeStamp  = [datetime]$pt.timeStamp
                    Metric     = $metric.name.value
                    Deployment = $dep
                    Model      = $model
                    Total      = [long]$pt.total
                }
            }
        }
    }
    $rows
}

# ---------------------------------------------------------------------------
# 4. BILLED COST  -  Cost Management Query API
#    Hours of lag. HEAVILY THROTTLED - 4 consecutive 429s observed before a
#    single query succeeded. Do NOT put this on a user-facing refresh path.
#    Run it on a schedule (hourly at most) and cache the result.
#
#    GOTCHA: timePeriod is only honoured when timeframe = "Custom".
#            Any other timeframe value returns HTTP 400.
# ---------------------------------------------------------------------------
function Get-BilledCost {
    param($SubscriptionId, $Token, [int]$Days = 5)

    $body = @{
        type      = "ActualCost"
        timeframe = "Custom"
        timePeriod = @{
            from = (Get-Date).AddDays(-$Days).ToString("yyyy-MM-ddT00:00:00Z")
            to   = (Get-Date).ToString("yyyy-MM-ddT23:59:59Z")
        }
        dataset = @{
            granularity = "Daily"
            aggregation = @{ totalCost = @{ name = "Cost"; function = "Sum" } }
            grouping    = @(@{ type = "Dimension"; name = "MeterCategory" })
        }
    } | ConvertTo-Json -Depth 10

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId" +
           "/providers/Microsoft.CostManagement/query?api-version=2024-08-01"

    $resp = Invoke-ArmWithRetry -Uri $uri -Method Post -Body $body -Token $Token

    $cols = $resp.properties.columns.name
    foreach ($row in $resp.properties.rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

# ---------------------------------------------------------------------------
# 5. THE JOIN  -  near-real-time cost attribution
#    Token metrics (~3 min) x cached unit price = per-deployment cost at
#    1-minute grain, instead of waiting hours for Cost Management.
# ---------------------------------------------------------------------------
function Get-NearRealTimeCost {
    param($Usage, $PriceTable)

    $byDeployment = $Usage |
        Where-Object { $_.Metric -in @('InputTokens', 'OutputTokens') } |
        Group-Object Deployment, Model

    foreach ($g in $byDeployment) {
        $dep   = $g.Group[0].Deployment
        $model = $g.Group[0].Model
        $in    = ($g.Group | Where-Object { $_.Metric -eq 'InputTokens'  } | Measure-Object Total -Sum).Sum
        $out   = ($g.Group | Where-Object { $_.Metric -eq 'OutputTokens' } | Measure-Object Total -Sum).Sum

        $price = $PriceTable[$model]
        $cost  = $null
        if ($price) {
            $cost = [math]::Round(
                ($in  / 1000000 * $price.InputPer1M) +
                ($out / 1000000 * $price.OutputPer1M), 6)
        }

        [pscustomobject]@{
            Deployment   = $dep
            Model        = $model
            InputTokens  = $in
            OutputTokens = $out
            EstCostUSD   = $cost          # $null when the model has no meter
            PriceKnown   = [bool]$price
        }
    }
}

# =============================== DEMO =======================================

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
if (-not $ResourceGroup)  {
    $ResourceGroup = az cognitiveservices account list `
        --query "[?name=='$AccountName'].resourceGroup" -o tsv
}

$token = Get-ArmToken

# Resolve a deployment to exercise rather than assuming one exists. A hardcoded
# name is the most likely first-run failure on someone else's subscription.
if (-not $Deployment) {
    $Deployment = az cognitiveservices account deployment list `
        -n $AccountName -g $ResourceGroup --query "[0].name" -o tsv 2>$null
}

Write-Host "`n=== 0. INLINE METERING (zero lag - primary source for a gateway) ===" -ForegroundColor Green
if (-not $Deployment) {
    Write-Warning "No model deployment found on '$AccountName'. Skipping inline metering. Pass -Deployment <name> to target one explicitly."
}
else {
    Write-Host "Using deployment '$Deployment'"

    # Illustrative rates so this section runs standalone. Build the real table
    # with Build-FoundryPriceTable.ps1 - do not hardcode prices in production.
    $inlinePrices = @{
        $Deployment = @{ InputPer1M = 2.00; CachedInputPer1M = 0.50; OutputPer1M = 8.00 }
    }
    $endpoint = "https://$AccountName.openai.azure.com"
    $msgs = @(@{ role = "user"; content = "Reply with exactly: ok" })

    $nonStream = Invoke-MeteredCompletion -Endpoint $endpoint -Deployment $Deployment `
                    -Messages $msgs -PriceTable $inlinePrices -MaxTokens 16 -TenantTag 'tenant-A'
    $streamed  = Invoke-MeteredCompletion -Endpoint $endpoint -Deployment $Deployment `
                    -Messages $msgs -PriceTable $inlinePrices -MaxTokens 16 -TenantTag 'tenant-B' -Stream

    @($nonStream, $streamed) | Where-Object { $_ } |
        Format-Table Tenant, Streamed, InputTokens, CachedTokens, OutputTokens, CostUSD, TtftMs, TtltMs -AutoSize
}

Write-Host "=== 1. MODEL CATALOG (real time) ===" -ForegroundColor Cyan
$catalog = Get-FoundryModelCatalog -SubscriptionId $SubscriptionId -Region $Region -Token $token
Write-Host "$($catalog.Count) distinct models in $Region"
$catalog | Select-Object -First 5 Name, Version, Lifecycle, Skus | Format-Table -AutoSize

Write-Host "=== 2. UNIT PRICING (cache daily) ===" -ForegroundColor Cyan
# NOTE serviceName = 'Foundry Models'. The old 'Cognitive Services' value
# returns HTTP 200 with zero rows - a silent failure, not an error.
$prices = Get-AzureRetailPrices -Filter "serviceName eq 'Foundry Models' and armRegionName eq '$Region' and contains(meterName,'Tokens')"
Write-Host "$($prices.Count) token meters in $Region"
$prices | Where-Object { $_.MeterName -match 'glbl' } |
    Sort-Object MeterName | Select-Object -First 8 MeterName, UnitOfMeasure, RetailPrice, PricePer1M |
    Format-Table -AutoSize

Write-Host "=== 3. TOKEN USAGE (~3 min lag, 1 min grain) ===" -ForegroundColor Cyan
$usage = Get-TokenUsage -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
                        -AccountName $AccountName -Token $token -LookbackMins $LookbackMins
Write-Host "$($usage.Count) datapoints in the last $LookbackMins min"
$usage | Group-Object Deployment |
    Select-Object @{n='Deployment';e={$_.Name}},
                  @{n='Datapoints';e={$_.Count}},
                  @{n='TotalTokens';e={($_.Group | Where-Object Metric -eq 'TotalTokens' | Measure-Object Total -Sum).Sum}} |
    Sort-Object TotalTokens -Descending | Select-Object -First 8 | Format-Table -AutoSize

Write-Host "=== 4. NEAR-REAL-TIME COST (tokens x cached price) ===" -ForegroundColor Cyan
# Derive rates from the real price table rather than hardcoding them. Hardcoded
# rates in a cost path are the thing this repo exists to argue against, so the
# demo should not do it either.
$builder = Join-Path $PSScriptRoot 'Build-FoundryPriceTable.ps1'
$priceTable = @{}
if (Test-Path $builder) {
    . $builder
    $pt = Build-FoundryPriceTable -Region $Region
    # Resolve the real publisher per model. Hardcoding 'OpenAI' made Claude
    # traffic come back Ambiguous instead of BilledOutsideRetailAPI, which hides
    # the fact that Anthropic bills through Marketplace and is not in this table.
    $pubOf = @{}
    $verOf = @{}
    foreach ($c in $catalog) {
        if ($c.Name -and -not $pubOf.ContainsKey($c.Name)) {
            $pubOf[$c.Name] = $c.Publisher
            $verOf[$c.Name] = $c.Version
        }
    }

    foreach ($m in ($usage | Select-Object -ExpandProperty Model -Unique | Where-Object { $_ })) {
        $pub = $pubOf[$m]
        if (-not $pub) { Write-Warning "Model '$m' not in the $Region catalog; cannot resolve publisher. Skipping."; continue }
        $lookup = @{ Table = $pt; ModelName = $m; Publisher = $pub; Sku = 'GlobalStandard' }
        if ($verOf[$m]) { $lookup.ModelVersion = $verOf[$m] }
        $in  = Get-TokenPrice @lookup -Kind Input
        $out = Get-TokenPrice @lookup -Kind Output
        # The newest models have no Standard context tier. Retry in the Short
        # band rather than reporting a false coverage gap.
        if ($in.Status -eq 'NoMeter' -or $out.Status -eq 'NoMeter') {
            $inS  = Get-TokenPrice @lookup -Kind Input  -ContextTier Short
            $outS = Get-TokenPrice @lookup -Kind Output -ContextTier Short
            if ($inS.Status -eq 'Priced' -and $outS.Status -eq 'Priced') { $in = $inS; $out = $outS }
        }
        if ($in.Status -eq 'Priced' -and $out.Status -eq 'Priced') {
            $priceTable[$m] = @{ InputPer1M = $in.PricePer1M; OutputPer1M = $out.PricePer1M }
        }
        else {
            # Deliberately leave the model out. A missing entry yields a null
            # cost downstream; inventing a rate would yield a confident wrong one.
            Write-Warning "No usable price for '$m' [$pub] (in=$($in.Status), out=$($out.Status)). Cost will be null, not zero."
        }
    }
}
else {
    Write-Warning "Build-FoundryPriceTable.ps1 not found alongside this script. Skipping cost estimation rather than hardcoding rates."
}
Get-NearRealTimeCost -Usage $usage -PriceTable $priceTable |
    Sort-Object InputTokens -Descending | Select-Object -First 8 | Format-Table -AutoSize

if ($IncludeCost) {
    Write-Host "=== 5. BILLED COST (hours lag, throttled) ===" -ForegroundColor Cyan
    Get-BilledCost -SubscriptionId $SubscriptionId -Token $token -Days 5 | Format-Table -AutoSize
}


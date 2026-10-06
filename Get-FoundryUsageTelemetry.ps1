<#
.SYNOPSIS
    Reference sample: real-time pricing, model catalog, token usage and cost
    telemetry for an AI gateway built on Microsoft Foundry.

.DESCRIPTION
    Demonstrates the Azure APIs an AI gateway needs to surface usage metrics to
    its own tenants, and shows the correct way to combine them.

      1. Model catalog   - ARM CognitiveServices models        (real time)
      2. Unit pricing    - Azure Retail Prices API             (static, cache daily)
      3. Token usage     - Azure Monitor metrics               (~1-3 min lag)
      4. Billed cost     - Cost Management Query API           (hours lag, throttled)

    KEY ARCHITECTURAL POINT #1 - AZURE MONITOR IS THE PREFERRED SOURCE
    Azure Monitor is the only surface that reports token usage identically for
    every model publisher. Its InputTokens / OutputTokens / TotalTokens metrics
    carry the same name, unit and dimensions whether the deployment is OpenAI,
    Anthropic, xAI or DeepSeek. Every other source is provider-shaped:
    the inference response differs per publisher, and Anthropic is not in the
    Retail Prices API at all. Treat Monitor as the source of truth for totals,
    reconciliation and anything that must span publishers.

    KEY ARCHITECTURAL POINT #2 - MONITOR CANNOT REPLACE INLINE METERING
    Monitor's dimensions are ApiName, Region, ModelDeploymentName, ModelName and
    ModelVersion. There is NO tenant dimension. If a gateway must attribute spend
    to the tenant that made the call, that attribution can only happen in the
    request path. So inline metering stays - but it must be provider-aware,
    because each publisher reports usage differently (see Get-ProviderProfile).

    KEY ARCHITECTURAL POINT #3 - DO NOT POLL COST MANAGEMENT
    It lags by hours and is aggressively throttled. Compute cost from token
    counts and cached unit prices; use Cost Management only for reconciliation.
    For Anthropic, per-model cost reconciliation is impossible by design - see
    the CCU note below.

    ANTHROPIC / CLAUDE BILLS IN CCU
    Claude models bill through Azure Marketplace in Claude Consumption Units.
    Azure Cost Management shows a SINGLE CCU meter with no per-model dimension,
    so derived cost (billed / tokens) cannot be computed per Claude model. This
    is documented behaviour, not a coverage gap. Token usage is still exact and
    available from Azure Monitor and from the inference response.

.NOTES
    Auth: all use Entra tokens. No API keys.
      - ARM / Monitor / Cost Management -> audience https://management.azure.com
      - Inference (both endpoints)      -> audience https://cognitiveservices.azure.com
      - Retail Prices API               -> anonymous, no auth, no subscription

    Required RBAC on the Foundry resource / subscription:
      - Monitoring Reader   (Azure Monitor metrics)
      - Cost Management Reader (Cost Management query)
      - Reader              (model catalog)

    Verified against kd-foundry/eastus2 with live deployments from four
    publishers: OpenAI, Anthropic, xAI and DeepSeek.
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
# 0. INLINE METERING  -  read usage straight off the inference response
#
#    Use this ONLY for per-tenant attribution. Azure Monitor (section 3) is the
#    preferred source for totals because it is identical across publishers and
#    cannot be bypassed. Inline metering exists because Monitor has no tenant
#    dimension - nothing else.
#
#    *** INLINE METERING IS PROVIDER-SHAPED. ***
#    Every publisher reports usage differently. An OpenAI-shaped parser does not
#    merely degrade on other publishers - it hard-fails on Anthropic and
#    silently under-bills xAI. All of the following were verified live:
#
#    ENDPOINT
#      OpenAI / xAI / DeepSeek -> /openai/v1/chat/completions
#      Anthropic               -> /anthropic/v1/messages   + anthropic-version
#      Calling Anthropic on the OpenAI path returns:
#        {"error":{"code":"api_not_supported", ...}}       <- HTTP error, no tokens
#      Omitting anthropic-version returns:
#        "anthropic-version: header is required"           <- HTTP 400
#
#    FIELD NAMES
#      OpenAI family -> prompt_tokens / completion_tokens / total_tokens
#      Anthropic     -> input_tokens  / output_tokens      (NO total_tokens)
#      A parser reading prompt_tokens off Anthropic records 0, not an error.
#
#    CACHE SEMANTICS - THE ASYMMETRY THAT BREAKS COST MATH
#      OpenAI    prompt_tokens INCLUDES cached tokens
#                -> billable input = prompt_tokens - cached_tokens
#      Anthropic input_tokens  EXCLUDES cached tokens; cache_read_input_tokens
#                and cache_creation_input_tokens are SIBLING fields
#                -> billable input = input_tokens   (NO subtraction)
#      Subtracting on Anthropic double-discounts. Not subtracting on OpenAI
#      over-bills. The same code path cannot do both.
#
#    REASONING TOKENS - THE EXPENSIVE ONE
#      OpenAI  reasoning_tokens are INCLUDED in completion_tokens
#      xAI     reasoning_tokens are EXCLUDED from completion_tokens but are
#              INCLUDED in total_tokens
#      Measured on grok-4.3: prompt=13 completion=81 reasoning=451 total=545.
#      13 + 81 = 94, not 545. A gateway billing completion_tokens charges for
#      81 output tokens instead of 532 - an 85% under-bill on one request.
#      Correct for xAI: output = completion_tokens + reasoning_tokens.
#      Measured on o4-mini:  prompt=15 completion=174 reasoning=128 total=189.
#      15 + 174 = 189 exactly, so adding reasoning there would DOUBLE-COUNT it.
#
#    STREAMING
#      OpenAI / xAI  omit usage unless stream_options.include_usage = true
#      Anthropic     ALWAYS streams usage, and REJECTS stream_options outright:
#                      "stream_options: Extra inputs are not permitted" (400)
#                    so injecting it universally breaks every streamed Claude call.
#      Anthropic also emits usage TWICE: message_start carries a PARTIAL
#      output_tokens, message_delta carries the final one. Measured: 1 then 13.
#      Taking the first regex match under-bills by whatever streamed after.
#      Always take the LAST usage object on an Anthropic stream.
#
#    OUTPUT-LIMIT PARAMETER
#      max_tokens            -> gpt-4.x, gpt-4o, model-router, xAI, DeepSeek, Anthropic
#      max_completion_tokens -> o-series and gpt-5 / gpt-6 reasoning models
#      Sending the wrong one is HTTP 400, not a warning. Every current OpenAI
#      flagship rejects max_tokens, so a sample hardcoding it cannot call any
#      of them. Detect from the error and retry; name lists rot.
#
#    LATENCY
#      OpenAI family exposes usage.latency_checkpoint (engine_ttft_ms etc) on
#      NON-streamed calls only - it is absent from the streamed usage chunk.
#      Anthropic does not expose it at all. Measure TTFT at the proxy for both.
# ---------------------------------------------------------------------------

function Get-ProviderProfile {
    <#
      Maps a model publisher to everything that differs about metering it.
      Publisher comes from the ARM deployment's properties.model.format, which
      is the only populated publisher field (the 'publisher' field is null on
      every catalog entry).
    #>
    param([Parameter(Mandatory)][string] $Publisher)

    switch -Regex ($Publisher) {
        '^Anthropic$' {
            [pscustomobject]@{
                Provider          = 'Anthropic'
                Api               = 'AnthropicMessages'
                PathSuffix        = '/anthropic/v1/messages'
                ExtraHeaders      = @{ 'anthropic-version' = '2023-06-01' }
                # Anthropic streams usage unconditionally and 400s on stream_options.
                UsesStreamOptions = $false
                # input_tokens already excludes cache reads.
                InputIncludesCache      = $false
                # reasoning is not separately reported; output_tokens is complete.
                OutputIncludesReasoning = $true
                HasTotalTokens    = $false
                HasLatencyBlock   = $false
                # message_start usage is partial; the final one wins.
                UseLastUsageMatch = $true
                CcuBilled         = $true
                BillingNote       = 'CCU via Azure Marketplace - no per-model cost meter'
            }
            break
        }
        '^xAI$' {
            [pscustomobject]@{
                Provider          = 'xAI'
                Api               = 'OpenAIChatCompletions'
                PathSuffix        = '/openai/v1/chat/completions'
                ExtraHeaders      = @{}
                UsesStreamOptions = $true
                InputIncludesCache      = $true
                # THE DEFECT: completion_tokens omits reasoning_tokens.
                OutputIncludesReasoning = $false
                HasTotalTokens    = $true
                HasLatencyBlock   = $false
                UseLastUsageMatch = $false
                CcuBilled         = $false
                BillingNote       = 'Retail Prices API'
            }
            break
        }
        default {
            # OpenAI, DeepSeek, Mistral, Meta and other OpenAI-compatible
            # publishers. DeepSeek omits prompt_tokens_details entirely, which
            # the normaliser handles by coalescing a null cache count to 0.
            [pscustomobject]@{
                Provider          = $Publisher
                Api               = 'OpenAIChatCompletions'
                PathSuffix        = '/openai/v1/chat/completions'
                ExtraHeaders      = @{}
                UsesStreamOptions = $true
                InputIncludesCache      = $true
                OutputIncludesReasoning = $true
                HasTotalTokens    = $true
                HasLatencyBlock   = ($Publisher -eq 'OpenAI')
                UseLastUsageMatch = $false
                CcuBilled         = $false
                BillingNote       = 'Retail Prices API'
            }
        }
    }
}

function ConvertTo-NormalizedUsage {
    <#
      Collapses every publisher's usage block into one schema:

        InputTokens       billable input, cache reads already removed
        CachedReadTokens  input served from cache (cheaper rate)
        CacheWriteTokens  input written to cache (Anthropic only, premium rate)
        OutputTokens      billable output, reasoning already included
        ReasoningTokens   subset of OutputTokens, for visibility only
        TotalTokens       always recomputed, never trusted from the provider

      TotalTokens is recomputed rather than read because Anthropic does not
      report one and xAI's disagrees with its own component fields.
    #>
    param(
        [Parameter(Mandatory)] $Usage,
        [Parameter(Mandatory)] $ProviderProfile
    )

    if ($ProviderProfile.Api -eq 'AnthropicMessages') {
        # input_tokens EXCLUDES cache reads - do not subtract.
        $inTok   = [int]$Usage.input_tokens
        $cacheRd = [int]$Usage.cache_read_input_tokens
        $cacheWr = [int]$Usage.cache_creation_input_tokens
        $outTok  = [int]$Usage.output_tokens
        $reason  = 0
    }
    else {
        # prompt_tokens INCLUDES cache reads - subtract to get billable input.
        # DeepSeek has no prompt_tokens_details; [int]$null is 0, which is right.
        $cacheRd = [int]$Usage.prompt_tokens_details.cached_tokens
        $inTok   = [int]$Usage.prompt_tokens - $cacheRd
        $cacheWr = 0
        $reason  = [int]$Usage.completion_tokens_details.reasoning_tokens
        $outTok  = [int]$Usage.completion_tokens
        if (-not $ProviderProfile.OutputIncludesReasoning) {
            # xAI: reasoning is billed but omitted from completion_tokens.
            $outTok += $reason
        }
    }

    $computedTotal = $inTok + $cacheRd + $cacheWr + $outTok
    $reported      = if ($ProviderProfile.HasTotalTokens) { [int]$Usage.total_tokens } else { $null }

    # Self-check against the provider's own total. A mismatch means the publisher
    # changed its accounting and this normaliser needs revisiting - surface it
    # loudly rather than shipping a quietly wrong invoice.
    if ($null -ne $reported -and $reported -ne $computedTotal) {
        Write-Warning ("Usage reconciliation mismatch for {0}: computed {1} vs reported {2}. Token accounting for this publisher may have changed." -f `
            $ProviderProfile.Provider, $computedTotal, $reported)
    }

    [pscustomobject]@{
        Provider         = $ProviderProfile.Provider
        InputTokens      = $inTok
        CachedReadTokens = $cacheRd
        CacheWriteTokens = $cacheWr
        OutputTokens     = $outTok
        ReasoningTokens  = $reason
        TotalTokens      = $computedTotal
        ReportedTotal    = $reported
    }
}

function Invoke-MeteredCompletion {
    <#
      Provider-aware metering wrapper. Resolves the publisher, picks the right
      endpoint, headers and payload shape, then normalises the usage block so
      callers get one schema regardless of who built the model.

      Returns model output plus exact token counts and cost at response time.
    #>
    param(
        [Parameter(Mandatory)] $Endpoint,       # https://<account>.services.ai.azure.com
        [Parameter(Mandatory)] $Deployment,
        [Parameter(Mandatory)] $Messages,
        [Parameter(Mandatory)][string] $Publisher,   # from the ARM deployment: model.format
        $PriceTable,
        [int]  $MaxTokens = 256,
        [switch] $Stream,
        $Token,
        [string] $TenantTag = "default"          # your own tenant/user attribution
    )

    $prof = Get-ProviderProfile -Publisher $Publisher

    if (-not $Token) {
        $Token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
    }

    # The OpenAI-compatible path has TWO mutually exclusive output-limit
    # parameters and the model decides which one it accepts:
    #   max_tokens            - gpt-4.x, gpt-4o, model-router, xAI, DeepSeek
    #   max_completion_tokens - o-series and gpt-5 / gpt-6 reasoning models
    # Sending the wrong one is a hard HTTP 400, not a warning. Measured: every
    # current OpenAI flagship (o4-mini, gpt-5-mini, gpt-5.1, gpt-5.4, gpt-5.6-sol,
    # gpt-6-sol) rejects max_tokens outright.
    # Name patterns rot as new families ship, so detect from the error and retry
    # once rather than maintaining a model list.
    $useCompletionTokens = $false
    $attempt             = 0
    $joined              = $null
    $sw                  = $null

    while ($attempt -lt 2) {
        $attempt++

        $payload = [ordered]@{
            model    = $Deployment
            messages = $Messages
        }
        if ($prof.Api -eq 'AnthropicMessages') {
            # Anthropic requires max_tokens and has no alternate spelling.
            $payload.max_tokens = $MaxTokens
        }
        elseif ($useCompletionTokens) {
            $payload.max_completion_tokens = $MaxTokens
        }
        else {
            $payload.max_tokens = $MaxTokens
        }

        if ($Stream) {
            $payload.stream = $true
            if ($prof.UsesStreamOptions) {
                # THE INJECTION. Without this the usage block never arrives on
                # the OpenAI-compatible path. Verified: stream:true alone returns none.
                $payload.stream_options = @{ include_usage = $true }
            }
            # Deliberately NOT set for Anthropic: it returns HTTP 400
            # "stream_options: Extra inputs are not permitted" and streams usage
            # unconditionally anyway.
        }

        # GetTempPath() rather than $env:TEMP: TEMP is unset on Linux/macOS pwsh,
        # so Join-Path would throw on a null path before any call was issued.
        # utf8NoBOM rather than ascii: ascii replaces every non-ASCII codepoint
        # with '?', silently mangling any non-English prompt before it reaches
        # the model.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("req-" + [guid]::NewGuid().ToString('N') + ".json")
        ($payload | ConvertTo-Json -Depth 8 -Compress) | Set-Content $tmp -Encoding utf8NoBOM

        $url   = $Endpoint.TrimEnd('/') + $prof.PathSuffix
        $cargs = @('-s','-N','-X','POST',$url,
                   '-H',"Authorization: Bearer $Token",
                   '-H','Content-Type: application/json',
                   '-d',"@$tmp")
        foreach ($k in $prof.ExtraHeaders.Keys) {
            $cargs += @('-H', ("{0}: {1}" -f $k, $prof.ExtraHeaders[$k]))
        }

        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        try   { $raw = & curl.exe @cargs }
        finally {
            # finally, not a bare call after the invocation: with
            # $ErrorActionPreference='Stop' a curl failure would skip the cleanup
            # and leak the request body into TEMP on every failed call.
            $sw.Stop()
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }

        $joined = $raw -join "`n"

        # Adapt and retry once on the output-limit parameter mismatch.
        # Both conditions are required. Matching the bare word anywhere in the
        # body is not safe: a SUCCESSFUL completion whose text happens to discuss
        # "max_completion_tokens" would match, discarding a response that was
        # already charged upstream and billing only the retry. Requiring a
        # genuine top-level error object avoids that - JSON escaping turns any
        # model-authored quotes into \" so content cannot forge an error block.
        if ($attempt -eq 1 -and -not $useCompletionTokens -and
            $joined -match '"error"\s*:\s*\{' -and
            $joined -match 'max_completion_tokens') {
            Write-Verbose "'$Deployment' requires max_completion_tokens; retrying."
            $useCompletionTokens = $true
            continue
        }
        break
    }

    # Surface an API-level rejection instead of reporting it as "no usage".
    # Calling Anthropic on the OpenAI path lands here, and the distinction
    # between "the call failed" and "the call worked but had no usage" is the
    # difference between a visible outage and a silent revenue leak.
    if ($joined -match '"error"\s*:\s*\{') {
        $msg  = ([regex]::Match($joined, '"message"\s*:\s*"([^"]{0,300})"')).Groups[1].Value
        $code = ([regex]::Match($joined, '"(?:code|type)"\s*:\s*"([^"]{0,80})"')).Groups[1].Value
        Write-Warning ("{0} call to '{1}' failed [{2}]: {3}" -f $prof.Provider, $Deployment, $code, $msg)
        return $null
    }

    # Streaming returns SSE frames. On Anthropic usage appears twice -
    # message_start (partial output_tokens) then message_delta (final) - so the
    # LAST match is the authoritative one. Taking the first under-bills.
    $usage = $null
    $hits  = [regex]::Matches($joined, '"usage"\s*:\s*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}')
    if ($hits.Count -gt 0) {
        $pick = if ($prof.UseLastUsageMatch) { $hits[$hits.Count - 1] } else { $hits[0] }
        try { $usage = ("{" + $pick.Value + "}" | ConvertFrom-Json).usage } catch { }
    }

    if (-not $usage) {
        # Two distinct causes, and they need different responses:
        #
        #  a) include_usage was not set on a streamed OpenAI-path call. That is
        #     a code defect and under-bills every streamed request silently.
        #
        #  b) The response body came back EMPTY. Measured 2 occurrences in 60
        #     rapid back-to-back streamed calls (~3%) on gpt-4.1-mini with
        #     include_usage correctly set - a 2-byte body, no SSE frames, no
        #     error JSON. The caller gets nothing either, so this surfaces as a
        #     failed request rather than a silent under-bill, but the tokens may
        #     still have been consumed upstream.
        #
        # In both cases: never record zero. Azure Monitor counts this traffic
        # independently, so the reconciliation tier is what recovers it.
        if ($Stream -and $prof.UsesStreamOptions) {
            Write-Warning ("No usage block on streamed call to '{0}'. Either include_usage was dropped or the response body was empty. Do NOT bill zero - reconcile this window against Azure Monitor." -f $Deployment)
        } else {
            Write-Warning ("No usage block returned by {0} deployment '{1}'. Do NOT bill zero - reconcile against Azure Monitor." -f $prof.Provider, $Deployment)
        }
        return $null
    }

    $n = ConvertTo-NormalizedUsage -Usage $usage -ProviderProfile $prof

    # CCU INVARIANT. Claude bills in Claude Consumption Units through Azure
    # Marketplace as a single aggregate meter with no per-model dimension, so a
    # per-model cost is not merely unknown - it does not exist. Compute it here
    # and the inline meter would emit a fabricated number, contradicting the
    # whole premise. Tokens stay exact; cost is null by design, and BillingModel
    # says which kind of null this is so a caller can tell "impossible" from
    # "missing price", exactly as Get-NearRealTimeCost does.
    $cost         = $null
    $billingModel = 'NoMeter'
    $price        = if ($PriceTable) { $PriceTable[$Deployment] } else { $null }

    if ($prof.CcuBilled) {
        $billingModel = 'CCU'
    }
    elseif ($price) {
        $billingModel = 'Derived'
        # Cached input bills at the cached rate when the model exposes one.
        # Anthropic additionally charges a PREMIUM for cache writes; when no
        # explicit write rate is known, fall back to the standard input rate
        # rather than treating the write as free.
        # $null -ne, not truthiness: a genuine 0.0 rate (some tiers price cache
        # reads at zero) is falsy in PowerShell and would silently fall back to
        # the FULL input rate, overcharging the customer.
        $cachedRate = if ($null -ne $price.CachedInputPer1M) { $price.CachedInputPer1M } else { $price.InputPer1M }
        $writeRate  = if ($null -ne $price.CacheWritePer1M)  { $price.CacheWritePer1M }  else { $price.InputPer1M }
        $cost = [math]::Round(
            ($n.InputTokens      / 1000000 * $price.InputPer1M) +
            ($n.CachedReadTokens / 1000000 * $cachedRate) +
            ($n.CacheWriteTokens / 1000000 * $writeRate) +
            ($n.OutputTokens     / 1000000 * $price.OutputPer1M), 8)
    }

    [pscustomobject]@{
        Tenant        = $TenantTag
        Provider      = $n.Provider
        Deployment    = $Deployment
        Streamed      = [bool]$Stream
        InputTokens   = $n.InputTokens
        CachedTokens  = $n.CachedReadTokens
        CacheWrite    = $n.CacheWriteTokens
        OutputTokens  = $n.OutputTokens
        Reasoning     = $n.ReasoningTokens
        TotalTokens   = $n.TotalTokens
        CostUSD       = $cost
        BillingModel  = $billingModel
        PriceKnown    = [bool]$price
        WallClockMs   = [int]$sw.ElapsedMilliseconds
        # Per-request latency telemetry, free with the response - OpenAI only.
        # Anthropic has no latency_checkpoint; these stay null and TTFT must be
        # measured at the proxy instead.
        TtftMs        = if ($prof.HasLatencyBlock) { $usage.latency_checkpoint.engine_ttft_ms } else { $null }
        TbtMs         = if ($prof.HasLatencyBlock) { $usage.latency_checkpoint.engine_tbt_ms }  else { $null }
        TtltMs        = if ($prof.HasLatencyBlock) { $usage.latency_checkpoint.engine_ttlt_ms } else { $null }
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
# 2b. DEPLOYMENT -> PUBLISHER  -  the join inline metering depends on
#
#     You cannot infer the publisher from a deployment name: operators rename
#     deployments freely, and 'my-fast-model' says nothing about who built it.
#     properties.model.format on the ARM deployment is the authoritative key,
#     and it is what Get-ProviderProfile and Get-TokenPrice both expect.
#     Guessing wrong here sends Claude traffic to the OpenAI endpoint, which
#     fails the call outright.
# ---------------------------------------------------------------------------
function Get-FoundryDeployments {
    param($AccountName, $ResourceGroup)

    $json = az cognitiveservices account deployment list `
                -n $AccountName -g $ResourceGroup -o json 2>$null
    if (-not $json) { return @() }

    foreach ($d in ($json | ConvertFrom-Json)) {
        [pscustomobject]@{
            Deployment = $d.name
            Model      = $d.properties.model.name
            Publisher  = $d.properties.model.format
            Version    = $d.properties.model.version
            Sku        = $d.sku.name
        }
    }
}

# ---------------------------------------------------------------------------
# 3. TOKEN USAGE  -  Azure Monitor metrics      *** PREFERRED SOURCE ***
#
#    This is the only surface that reports token usage identically for every
#    publisher. InputTokens / OutputTokens / TotalTokens carry the same name,
#    unit and dimensions for OpenAI, Anthropic, xAI and DeepSeek deployments
#    alike, so one query covers the whole account with no per-provider parsing.
#
#    Prefer it for:
#      * account-wide and per-deployment totals
#      * anything that must span publishers
#      * reconciliation against gateway-side inline counts (bypass detection)
#      * Anthropic token usage, where no per-model cost meter exists at all
#
#    1-minute grain. Token counts are exact, not sampled.
#
#    LIMITS YOU MUST DESIGN AROUND
#      * NO TENANT DIMENSION. Dimensions are ApiName, Region,
#        ModelDeploymentName, ModelName, ModelVersion. Monitor can tell you a
#        deployment burned 40k tokens; it cannot tell you which of your tenants
#        burned them. Per-tenant attribution has to happen in the request path.
#      * Lag of roughly 2 minutes, so it cannot back a live per-request meter.
#      * TokensCacheMatchRate and ProvisionedConsumedTokens are PTU-only
#        metrics. Claude runs Global Standard / Data Zone Standard, so no cache
#        hit-rate metric is available for it here.
#
#    *** DO NOT BILL OutputTokens DIRECTLY ***
#    The schema is uniform across publishers but the SEMANTICS of OutputTokens
#    are not. Monitor inherits the xAI reasoning-token quirk from the inference
#    API: OutputTokens excludes reasoning tokens, TotalTokens includes them.
#    Measured on grok-4.3: in=34 out=99 total=998, so in+out=133 against a real
#    billable output of 964.
#    Use (TotalTokens - InputTokens). It equals OutputTokens for publishers that
#    are consistent (verified exactly on OpenAI and Anthropic) and recovers the
#    missing tokens for those that are not.
#
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
#    Monitor token metrics (~1-3 min) x cached unit price = per-deployment cost
#    at 1-minute grain, instead of waiting hours for Cost Management.
#
#    BillingModel distinguishes three outcomes that must not be conflated:
#      Derived  - priced from the Retail Prices API, EstCostUSD is a number
#      CCU      - Anthropic; bills via Marketplace with no per-model meter, so
#                 cost is permanently null here BY DESIGN, not pending a fix
#      NoMeter  - a real coverage gap; alert on this one
# ---------------------------------------------------------------------------
function Get-NearRealTimeCost {
    param($Usage, $PriceTable, $CcuModels = @{})

    $byDeployment = $Usage |
        Where-Object { $_.Metric -in @('InputTokens', 'OutputTokens', 'TotalTokens') } |
        Group-Object Deployment, Model

    foreach ($g in $byDeployment) {
        $dep   = $g.Group[0].Deployment
        $model = $g.Group[0].Model
        $in    = ($g.Group | Where-Object { $_.Metric -eq 'InputTokens'  } | Measure-Object Total -Sum).Sum
        $out   = ($g.Group | Where-Object { $_.Metric -eq 'OutputTokens' } | Measure-Object Total -Sum).Sum
        $tot   = ($g.Group | Where-Object { $_.Metric -eq 'TotalTokens'  } | Measure-Object Total -Sum).Sum

        # *** DO NOT BILL OutputTokens DIRECTLY. ***
        # Azure Monitor inherits the same reasoning-token quirk as the inference
        # API: for xAI, OutputTokens EXCLUDES reasoning tokens while TotalTokens
        # includes them. Measured on grok-4.3:
        #     in=34  out=99  total=998
        #     in + out      = 133   <- what a naive dashboard shows
        #     total - in    = 964   <- actual billable output
        # That is a 7x under-report of output on a reasoning workload.
        #
        # (TotalTokens - InputTokens) is correct for EVERY publisher measured:
        #   claude-opus-5-5  in 6803   out 322316  total 329119  -> total-in = out
        #   gpt-4.1-mini     in 1639   out 739     total 2378    -> total-in = out
        #   grok-4.3         in 34     out 99      total 998     -> total-in = 964
        # So it equals OutputTokens where the publisher is consistent and
        # recovers the missing reasoning tokens where it is not.
        #
        # The fallback is NOT equivalent. If the TotalTokens series is missing
        # for a window, raw OutputTokens reintroduces exactly the xAI
        # under-report this function exists to prevent, so say so rather than
        # quietly emitting a low number.
        if ($null -ne $tot -and $null -ne $in -and $tot -gt 0) {
            $billableOut = $tot - $in
        }
        else {
            $billableOut = $out
            Write-Warning ("No TotalTokens for '{0}' in this window; falling back to raw OutputTokens. " -f $model +
                           "This UNDER-REPORTS output on publishers that exclude reasoning tokens (xAI). Widen -LookbackMins or re-poll.")
        }

        $price = $PriceTable[$model]
        $cost  = $null
        $billingModel = 'NoMeter'

        if ($CcuModels -and $CcuModels.ContainsKey($model)) {
            # Claude. Tokens are exact; cost is not derivable at model grain.
            $billingModel = 'CCU'
        }
        elseif ($price) {
            $billingModel = 'Derived'
            $cost = [math]::Round(
                ($in          / 1000000 * $price.InputPer1M) +
                ($billableOut / 1000000 * $price.OutputPer1M), 6)
        }

        [pscustomobject]@{
            Deployment     = $dep
            Model          = $model
            InputTokens    = $in
            OutputTokens   = $billableOut   # reasoning-inclusive, the billable figure
            ReportedOutput = $out           # raw metric; lower than billable on xAI
            TotalTokens    = $tot
            EstCostUSD     = $cost          # $null for both CCU and NoMeter
            BillingModel   = $billingModel  # tells you WHY it is null
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

# Resolve deployments with their publishers. The publisher is required for
# inline metering; a hardcoded name or an assumed publisher is the most likely
# first-run failure on someone else's subscription.
$deployments = Get-FoundryDeployments -AccountName $AccountName -ResourceGroup $ResourceGroup

Write-Host "`n=== 0. INLINE METERING (per-tenant attribution only) ===" -ForegroundColor Green
Write-Host "Azure Monitor (section 3) is the preferred source for totals." -ForegroundColor DarkGray
Write-Host "Inline metering exists because Monitor has no tenant dimension.`n" -ForegroundColor DarkGray

if (-not $deployments) {
    Write-Warning "No model deployments found on '$AccountName'. Skipping inline metering."
}
else {
    # Exercise ONE deployment per publisher so provider-specific handling is
    # actually covered rather than assumed. A single-provider smoke test is how
    # the Anthropic and xAI defects survived in the first place.
    $targets = if ($Deployment) {
        $deployments | Where-Object { $_.Deployment -eq $Deployment }
    } else {
        # Exclude non-chat deployments before picking. Embedding, audio and image
        # models carry format='OpenAI' too, so an unfiltered Group[0] can hand a
        # chat-completions payload to an embedding deployment purely on ARM
        # ordering - a confusing first-run failure that looks like a bug here.
        $deployments |
            Where-Object { $_.Model -notmatch 'embedding|whisper|tts|dall-e|sora|image|audio|realtime|moderation' } |
            Group-Object Publisher | ForEach-Object { $_.Group[0] }
    }

    if (-not $targets) { Write-Warning "Deployment '$Deployment' not found on '$AccountName'." }

    # Illustrative rates so this section runs standalone. Build the real table
    # with Build-FoundryPriceTable.ps1 - do not hardcode prices in production.
    $inlinePrices = @{}
    foreach ($t in $targets) {
        $inlinePrices[$t.Deployment] = @{ InputPer1M = 2.00; CachedInputPer1M = 0.50; CacheWritePer1M = 2.50; OutputPer1M = 8.00 }
    }

    # services.ai.azure.com serves BOTH /openai and /anthropic. The older
    # <account>.openai.azure.com host does not route /anthropic, so a gateway
    # fronting mixed publishers must use the services.ai hostname.
    $endpoint = "https://$AccountName.services.ai.azure.com"
    $msgs     = @(@{ role = "user"; content = "Reply with exactly: ok" })

    $inlineResults = foreach ($t in $targets) {
        Invoke-MeteredCompletion -Endpoint $endpoint -Deployment $t.Deployment -Publisher $t.Publisher `
            -Messages $msgs -PriceTable $inlinePrices -MaxTokens 16 -TenantTag "tenant-$($t.Publisher)"
        Invoke-MeteredCompletion -Endpoint $endpoint -Deployment $t.Deployment -Publisher $t.Publisher `
            -Messages $msgs -PriceTable $inlinePrices -MaxTokens 16 -TenantTag "tenant-$($t.Publisher)" -Stream
    }

    $inlineResults | Where-Object { $_ } |
        Format-Table Provider, Deployment, Streamed, InputTokens, CachedTokens, OutputTokens, Reasoning, TotalTokens, CostUSD, TtftMs -AutoSize
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

Write-Host "=== 3. TOKEN USAGE - AZURE MONITOR (preferred source, all publishers) ===" -ForegroundColor Cyan
$usage = Get-TokenUsage -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
                        -AccountName $AccountName -Token $token -LookbackMins $LookbackMins
Write-Host "$($usage.Count) datapoints in the last $LookbackMins min"

# Group by publisher as well as deployment. This is the view that proves the
# point: one query, one schema, every publisher - including Anthropic, which has
# no per-model cost meter anywhere else.
$pubByDeployment = @{}
foreach ($d in $deployments) { $pubByDeployment[$d.Deployment] = $d.Publisher }

$usage | Group-Object Deployment |
    Select-Object @{n='Deployment';e={$_.Name}},
                  @{n='Publisher';e={ if ($pubByDeployment[$_.Name]) { $pubByDeployment[$_.Name] } else { 'unknown' } }},
                  @{n='Datapoints';e={$_.Count}},
                  @{n='InputTokens';e={($_.Group | Where-Object Metric -eq 'InputTokens'  | Measure-Object Total -Sum).Sum}},
                  @{n='OutputTokens';e={($_.Group | Where-Object Metric -eq 'OutputTokens' | Measure-Object Total -Sum).Sum}},
                  @{n='TotalTokens';e={($_.Group | Where-Object Metric -eq 'TotalTokens'  | Measure-Object Total -Sum).Sum}} |
    Sort-Object TotalTokens -Descending | Select-Object -First 12 | Format-Table -AutoSize

$publishersSeen = $usage | ForEach-Object { $pubByDeployment[$_.Deployment] } |
                  Where-Object { $_ } | Sort-Object -Unique
if ($publishersSeen) {
    Write-Host ("Publishers covered by this single Monitor query: {0}" -f ($publishersSeen -join ', ')) -ForegroundColor DarkGray
}

Write-Host "=== 4. NEAR-REAL-TIME COST (Monitor tokens x cached price) ===" -ForegroundColor Cyan
# Derive rates from the real price table rather than hardcoding them. Hardcoded
# rates in a cost path are the thing this repo exists to argue against, so the
# demo should not do it either.
$builder = Join-Path $PSScriptRoot 'Build-FoundryPriceTable.ps1'
$priceTable = @{}
$ccuModels  = @{}
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
    # The live deployment list is more authoritative than the regional catalog
    # for models actually in use, and it is the only source that covers a model
    # the catalog has already rotated out.
    foreach ($d in $deployments) {
        if ($d.Model -and -not $pubOf.ContainsKey($d.Model)) {
            $pubOf[$d.Model] = $d.Publisher
            $verOf[$d.Model] = $d.Version
        }
    }

    foreach ($m in ($usage | Select-Object -ExpandProperty Model -Unique | Where-Object { $_ })) {
        $pub = $pubOf[$m]
        if (-not $pub) { Write-Warning "Model '$m' not in the $Region catalog; cannot resolve publisher. Skipping."; continue }

        # Anthropic is absent from the Retail Prices API BY DESIGN - Claude bills
        # through Azure Marketplace in Claude Consumption Units, and Cost
        # Management exposes a single CCU meter with no per-model dimension.
        # Derived cost is therefore impossible for Claude, not merely missing.
        # Say so explicitly instead of emitting a generic "no price" warning that
        # looks like a bug to fix.
        if ($pub -eq 'Anthropic') {
            $ccuModels[$m] = $true
            Write-Host ("  {0} [Anthropic] bills in CCU via Azure Marketplace - per-model cost is not derivable. Tokens are still exact. See https://aka.ms/ccu-pricing" -f $m) -ForegroundColor DarkYellow
            continue
        }

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
Get-NearRealTimeCost -Usage $usage -PriceTable $priceTable -CcuModels $ccuModels |
    Sort-Object InputTokens -Descending | Select-Object -First 12 | Format-Table -AutoSize

if ($IncludeCost) {
    Write-Host "=== 5. BILLED COST (hours lag, throttled) ===" -ForegroundColor Cyan
    Write-Host "Anthropic appears here only as an aggregate CCU meter, never per Claude model." -ForegroundColor DarkGray
    Get-BilledCost -SubscriptionId $SubscriptionId -Token $token -Days 5 | Format-Table -AutoSize
}


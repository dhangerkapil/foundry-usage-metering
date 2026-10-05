# Foundry Usage Metering

Measure token usage and cost for Microsoft Foundry — in real time, from the right API.

There are four Azure APIs that expose model pricing, usage and cost. They are not
interchangeable: they differ by orders of magnitude in freshness, and the fastest one is not
an API call at all. This repo shows which to use for what, with measured latency figures
rather than documentation claims.

Written for teams building an **AI gateway** in front of Foundry who need to show their own
users what they are consuming and what it costs.

## The short version

| Source | Auth | Measured lag | Use it for |
|---|---|---|---|
| `usage` block on the inference response | — (already in path) | **Zero** | What users see |
| ARM model catalog | Entra | Real time | Model inventory and lifecycle |
| Azure Retail Prices API | **None** | Real time (cache daily) | Unit prices |
| Azure Monitor metrics | Entra | **~3 minutes** | Cross-check, bypass detection |
| Cost Management Query | Entra | Hours, throttled | Nightly reconciliation only |

**Do not poll Cost Management for near-real-time cost.** It lags by hours and throttles hard —
four consecutive HTTP 429s before a single query succeeded during testing. Compute cost from
token counts and a cached price table instead, and use Cost Management only to reconcile.

## The thing most gateways get wrong

Your gateway already sits in the response path. Every Foundry inference response carries an
exact `usage` block — there is nothing to poll:

```json
"usage": {
  "prompt_tokens": 12,
  "completion_tokens": 1,
  "total_tokens": 13,
  "prompt_tokens_details": { "cached_tokens": 0 },
  "latency_checkpoint": {
    "engine_ttft_ms": 37, "engine_tbt_ms": 9, "engine_ttlt_ms": 48
  }
}
```

Multiply by a cached unit price and you have per-request, per-tenant cost at zero lag. The
`latency_checkpoint` block gives you TTFT and total latency for free.

### ⚠️ Streaming silently omits `usage`

Verified both ways:

| Request | `usage` returned? |
|---|---|
| `"stream": true` alone | **No** |
| `"stream": true` + `"stream_options": { "include_usage": true }` | **Yes** (final SSE chunk) |

For a chat workload most traffic is streamed. A gateway that does not set this **loses token
counts on the majority of requests and under-bills**, with no error surfacing anywhere.

**Fix:** inject `stream_options.include_usage = true` into every upstream streaming call
regardless of what the caller sent, then strip the final usage chunk before relaying if you
don't want clients to see it. `Invoke-MeteredCompletion` in this repo does exactly that.

One caveat: on streamed responses the `latency_checkpoint` block does **not** ride inside the
final usage chunk. Token counts are there; latency is not. Measure TTFT at the proxy for
streamed traffic.

## Quick start

```powershell
az login

# All five tiers against your own Foundry account
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account

# Narrow the window, pick a region, include the throttled cost query
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account `
    -Region eastus2 -LookbackMins 60 -IncludeCost
```

`-ResourceGroup` and `-SubscriptionId` are resolved from your `az` context when omitted.

## Parameters

| Parameter | Description |
|---|---|
| `-AccountName` | **Required.** Your Foundry / Azure OpenAI account name |
| `-SubscriptionId` | Defaults to the current `az` subscription |
| `-ResourceGroup` | Resolved from the account name when omitted |
| `-Region` | Region for the catalog and pricing lookups. Default `eastus2` |
| `-LookbackMins` | Window for the Azure Monitor query. Default `60` |
| `-IncludeCost` | Also run the Cost Management query. Off by default because it is slow and throttled |

## What's in here

| Function | Tier | Purpose |
|---|---|---|
| `Invoke-MeteredCompletion` | 0 | The metering wrapper — includes the `include_usage` injection |
| `Get-FoundryModelCatalog` | 1 | Model inventory, de-duplicated across SKUs |
| `Get-AzureRetailPrices` | 2 | Unit prices with correct `serviceName` and per-row unit normalisation |
| `Get-TokenUsage` | 3 | Token metrics split by deployment and model |
| `Get-BilledCost` | 4 | Cost Management with 429 backoff |
| `Get-NearRealTimeCost` | — | The join: tokens × cached price |
| `Invoke-ArmWithRetry` | — | Shared throttle-aware ARM caller |
| `Get-ArmToken` | — | Entra token acquisition |

## Measured latency

Not estimates. A 17-token inference call was timed end to end:

| Event | Time (UTC) |
|---|---|
| Inference call | 18:07:32 |
| First visible in Azure Monitor | 18:10:23 |
| **End-to-end lag** | **≈ 2 min 51 s** |

Minimum grain is `PT1M`, and **token counts are exact, not sampled** — the probe reported
exactly 17.

## Why use Azure Monitor when inline metering is faster

**Azure Monitor sees all traffic. Your gateway only sees what went through it.**

Reconciliation over one window during testing:

| Source | Input tokens |
|---|---|
| Gateway-side inline metering | 75 |
| Azure Monitor | 122 |

The difference was traffic generated outside the metering wrapper. In production that delta is
**someone calling the Foundry endpoint directly, bypassing the gateway** — unmetered,
unattributed usage.

Gateway total should equal Monitor total. A persistent gap is a leak. That is the argument for
running tier 3 even though tier 0 is faster.

Useful dimensions on `ModelRequests`: `StatusCode`, `StreamType`, `IsSpillover`,
`ServiceTierRequest` and `ServiceTierResponse`. The last pair lets you confirm a request
actually *got* the service tier it asked for — a request for an unsupported tier can succeed
silently at the standard rate, so comparing these two is the only way to detect it.

## Azure Retail Prices API — four gotchas

Each of these silently returns wrong or empty data rather than an error.

**1. `serviceName` is `'Foundry Models'`, not `'Cognitive Services'`.**

The old value returns **HTTP 200 with zero rows** — a silent failure. Code written against it
looks exactly like "no pricing exists for anything".

```
serviceName eq 'Cognitive Services'  ->  Count = 0     (silent)
serviceName eq 'Foundry Models'      ->  1,585 token meters in eastus2
```

**2. `unitOfMeasure` is mixed within the same product family.**

Token meters are `1K`, PTU meters are `1/Hour`, reservations are `1/Month` — all three observed
in one family. A blanket multiplier misreports the non-token meters by 1000×. Normalise per row:

```
'1K' -> per-1M = retailPrice * 1000
'1M' -> per-1M = retailPrice
else -> not token-denominated; do not convert
```

**3. `meterName` uses abbreviations, not model IDs.**

`Inp`/`Outp` for input/output, `glbl` for Global Standard, `DZone` for Data Zone. Searching for
`gpt-4.1` never matches `gpt 4.1 Inp glbl Tokens`. Conventions differ between families, too —
`gpt-oss-120B Inp glbl Tokens` carries the full name, `4.3 Inp Glbl Tokens` carries only a
version.

**4. `productName` spelling is inconsistent.**

`Azure Deepseek Models` has a lowercase `s`, so `contains(productName,'DeepSeek')` returns
nothing.

### Worked example

```
Filter:  serviceName eq 'Foundry Models'
     and armRegionName eq 'eastus2'
     and contains(meterName,'gpt-oss-120B')

  gpt-oss-120B Inp glbl Tokens    retailPrice 0.00015   unit 1K  ->  USD 0.15 / 1M
  gpt-oss-120B Outp glbl Tokens   retailPrice 0.00060   unit 1K  ->  USD 0.60 / 1M
```

### Coverage is incomplete

**Some models are deployable, GA, consuming quota, and have no published price meter at all.**
Handle a null price explicitly — do not treat it as zero.

Note also that **Anthropic / Claude has no family in this API**. Claude bills through
Marketplace / committed consumption, so its absence is correct rather than a coverage gap. A
gateway that reads "no meter" as "free" would get this badly wrong.

The Retail Prices API is **anonymous** — no auth, no subscription context. Prices returned are
**list prices, not negotiated rates**.

## Recommended architecture

```
                 ┌──────────────────────────────────────────┐
  user request   │              Your AI Gateway             │
  ───────────────▶                                          │
                 │  ① inject stream_options.include_usage   │
                 │  ② forward to Foundry                    │
                 │  ③ read usage{} off the response         │
                 │  ④ cost = tokens × cached unit price     │
                 │  ⑤ emit per-tenant metric  ── ZERO LAG ──┼──▶ user dashboard
                 └───────────────┬──────────────────────────┘
                                 │
                                 ▼
                         Microsoft Foundry
                                 │
       ┌─────────────────────────┼──────────────────────────┐
       ▼                         ▼                          ▼
  Retail Prices           Azure Monitor              Cost Management
  (cache daily,           (~3 min, 1-min grain)      (hours, throttled)
   anonymous)                    │                          │
       │                         ▼                          ▼
       └──────────▶ unit price   reconcile: gateway    nightly: computed
                    table        vs Monitor =          vs billed = drift
                                 bypass detection      alarm
```

## Implementation checklist

- [ ] Inject `stream_options.include_usage = true` into every upstream streaming request
- [ ] Read `prompt_tokens`, `completion_tokens` and **`prompt_tokens_details.cached_tokens`**
      separately — cached input bills at a lower rate
- [ ] Build the price table nightly using `serviceName eq 'Foundry Models'`
- [ ] **Normalise price per row by `unitOfMeasure`** — never a blanket multiplier
- [ ] Treat a missing meter as **null, not zero**; alert rather than silently billing nothing
- [ ] Poll Azure Monitor every 1–5 minutes and alert when
      `monitor_tokens − gateway_tokens` exceeds a threshold
- [ ] Run Cost Management **once nightly**, with 429 backoff, and alert on drift
- [ ] Capture `ServiceTierRequest` vs `ServiceTierResponse` to detect silent tier downgrades

## Requirements

- PowerShell 7+
- Azure CLI, signed in (`az login`)
- `curl.exe` (ships with Windows 10+ and most Linux distributions)

### RBAC

| API | Role | Scope |
|---|---|---|
| Azure Monitor metrics | **Monitoring Reader** | Foundry account |
| Cost Management query | **Cost Management Reader** | Subscription |
| Model catalog | **Reader** | Subscription |
| Retail Prices | *none* | — |

## Verified behaviour

| Scenario | Result |
|---|---|
| Non-streaming call | `usage` present, cost computed, TTFT 37 ms / TTLT 48 ms |
| Streaming without `include_usage` | **No usage block** |
| Streaming with `include_usage` | Usage present in final chunk; no `latency_checkpoint` |
| Model catalog, one region | 136 distinct models |
| Retail Prices, one region | 1,585 token meters |
| Azure Monitor lag | ≈ 2 min 51 s, exact counts |
| Cost Management | Succeeded on the 5th attempt after 4× HTTP 429 |
| Reconciliation | Gateway 75 tokens vs Monitor 122 — delta correctly identified as out-of-band traffic |

## Source documentation

- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Azure Monitor — Metrics: List](https://learn.microsoft.com/en-us/rest/api/monitor/metrics/list)
- [Cost Management — Query: Usage](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage)
- [Monitor Azure OpenAI](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/monitor-openai)
- [Models — List (Foundry catalog)](https://learn.microsoft.com/en-us/rest/api/aiservices/accountmanagement/models/list)
- [Deployment types](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/deployment-types)

## Related

[foundry-model-catalog-watcher](https://github.com/dhangerkapil/foundry-model-catalog-watcher) —
polls the Foundry model catalog and alerts on new models, with a `-IncludePricing` mode that
flags models which are deployable but have no published price meter.

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer

This is a personal project, provided as-is. It is not an official Microsoft product, is not
supported by Microsoft, and carries no warranty. The Azure API surface it depends on may change —
the measured figures above were taken in October 2026 and should be re-verified before you rely
on them.

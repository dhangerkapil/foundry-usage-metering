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

## Building the cached price table

Inline metering needs a unit price. This repo builds that table properly, because a naive one is
worse than none — it produces confident, plausible, wrong invoices.

```powershell
. .\Build-FoundryPriceTable.ps1

# Build once (daily is plenty - prices change rarely). Cached to disk.
$prices = Build-FoundryPriceTable -Region eastus2 -CachePath .\prices.json

# Look up a rate
$p = Get-TokenPrice -Table $prices -ModelName 'gpt-oss-120b' `
        -Publisher 'OpenAI-OSS' -Sku GlobalStandard -Kind Input
#   Status = Priced, PricePer1M = 0.15

# Cost a request
Measure-RequestCost -Table $prices -ModelName 'gpt-oss-120b' -Publisher 'OpenAI-OSS' `
    -Sku GlobalStandard -InputTokens 10000 -CachedTokens 4000 -OutputTokens 2000
#   CostUSD = 0.0027
```

### One model has many prices

This is the part that catches people. `gpt-oss-120B` in **one region** has seven meters:

```
gpt-oss-120B Inp glbl           0.15  /1M    Global Standard, input
gpt-oss-120B Outp glbl          0.60  /1M    Global Standard, output
gpt-oss-120B Inp DZone          0.165 /1M    Data Zone, input   (+10%)
gpt-oss-120B Outp DZone         0.66  /1M    Data Zone, output  (+10%)
FW GPT OSS 120B Inp DZ          0.165 /1M    Fireworks-hosted
FW GPT OSS 120B Outp DZ         0.66  /1M
FW GPT OSS 120B Cache Inp DZ    0.082 /1M    cached input
```

A cache keyed on model name alone is ambiguous. Pick Data Zone when the deployment is actually
Global and **every cost figure is 10% high** — not obviously broken, just steadily wrong.

So the key is **model + scope + token kind + context tier + deployment type**, and the gateway
must pass the deployment's actual SKU.

### Variant disambiguation is not optional

The version token alone is not enough. `gpt-5.4` appears as a substring in the meters for
`5.4 pro`, `5.4 mini` and `5.4 nano`:

| Model | Resolved meter | USD / 1M in |
|---|---|---|
| `gpt-5.4` | `5.4 inp Gl 1M Tokens` | **2.50** |
| `gpt-5.4-pro` | `5.4 pro inp Gl 1M Tokens` | **30.00** |
| `gpt-5.4-mini` | `5.4 mini Inp Gl 1M Tokens` | 0.75 |
| `gpt-5.4-nano` | `5.4 nano Inp Gl 1M Tokens` | 0.20 |

A substring match would bill `gpt-5.4` at the `pro` rate — **12× over**. `Get-TokenPrice` requires
the variant suffix to match on both sides, and returns `Ambiguous` rather than guessing when it
cannot decide.

### Verified price relationships

Observations from live data, not contracts — the table always reads actual meters:

| Relationship | Evidence |
|---|---|
| Data Zone = Global × 1.10 | Grok 4.3 input: 1.25 → 1.375 |
| Long context = base × 2.00 | Grok 4.3 input: 1.25 → 2.50 |
| Batch = base × 0.50 | GPT 5.4 pro input: 30 → 15 |
| Cached input ≈ 16% of input | Grok 4.3: 1.25 → 0.20 (varies by model) |

### Never return zero for unknown

`Get-TokenPrice` returns a `Status` and a **null** price, never `0`. Treating "no meter" as "free"
is the single most expensive mistake available here — it bills nothing for real usage.

| Status | Meaning | What to do |
|---|---|---|
| `Priced` | Usable rate found | Use it |
| `NoMeter` | **Coverage gap.** Model is deployable with no published price | Alert. Do not bill as zero |
| `BilledOutsideRetailAPI` | Publisher bills via Marketplace (Anthropic) | Correct, not a gap. Source cost from Cost Management |
| `UnknownPublisher` | Not in the family map | No verdict claimed. Add the mapping |
| `Ambiguous` | Several meters, different prices | Narrow by context tier or modality |

Verified live:

```
claude-opus-4-6      -> BilledOutsideRetailAPI   price = <null>
DeepSeek-V4.1-Flash  -> NoMeter                  price = <null>    (real GA model)
DeepSeek-V3.2        -> Priced                   price = 0.58
Measure-RequestCost on an unpriced model -> CostUSD = <null>, not 0
```

**Anthropic deserves a specific note.** Claude has no family in the Retail Prices API at all
because it bills through Marketplace / committed consumption. Its absence is *correct*. A gateway
that reads "no meter" as "free" would bill nothing for all Claude traffic — which at Opus rates
is a large hole.

### List prices, not your prices

The Retail Prices API is anonymous — no auth, no subscription context. It therefore returns
**list prices**. EA, MACC and negotiated discounts are not reflected.

The table carries `IsListPrice = $true` and a `PriceBasis` string in the structure itself, and
every `Get-TokenPrice` result repeats the flag, so downstream code cannot quietly forget. For
internal chargeback a consistent list-price rate card is usually fine; for anything
invoice-facing, reconcile against Cost Management.

### Cache behaviour

`-CachePath` persists to JSON and serves from it while fresh (`-MaxAgeHours`, default 24).
Measured: cache hit **62 ms** vs a full paged API fetch. `-Force` rebuilds.

If the API fails mid-fetch the builder **throws rather than returning a partial table** — a
half-built cache looks exactly like genuine missing coverage and would under-bill silently.

## Complete gotcha list

Every one of these was hit in practice. Most fail *open* — HTTP 200 with wrong or empty data
rather than an error.

| # | Gotcha | Symptom | Handling |
|---|---|---|---|
| 1 | `serviceName` is `'Foundry Models'`, not `'Cognitive Services'` | HTTP 200, **zero rows** | Builder throws with a pointed message if zero rows come back |
| 2 | `unitOfMeasure` mixed: `1K`, `1M`, `1/Hour`, `1/Month` | Blanket multiplier off by 1000× | Normalised per row; non-token meters excluded |
| 3 | `meterName` uses abbreviations, not model IDs | `gpt-4.1` never matches `gpt 4.1 Inp glbl Tokens` | Vocabulary table maps the abbreviations |
| 4 | **`opt` means output**, not "optional" | Output mis-keyed, under-bills 4–6× | Explicit in the kind vocabulary |
| 5 | `productName` inconsistent — `Azure Deepseek Models` (lowercase s) | `contains(…,'DeepSeek')` returns nothing | Exact family strings in the map |
| 6 | One model has many meters (scope × kind × tier × type × host) | Wrong-but-plausible price | Composite cache key |
| 7 | Version token is a substring of variants | `gpt-5.4` billed at `pro` rate, 12× over | Variant must match on both sides |
| 8 | Deployable GA models with no meter | Cost silently 0 | `NoMeter` + null, never 0 |
| 9 | Anthropic has no family at all | "Free" Claude traffic | `BilledOutsideRetailAPI` status |
| 10 | List prices only | Over-reports spend vs invoice | `IsListPrice` on table and every result |
| 11 | Paginated via `NextPageLink` | Silent truncation | Full pagination |
| 12 | API throttles | Partial table | Backoff; throws rather than returning partial |
| 13 | `Format-Table` rounds to 2dp | Per-token prices render `0.00` | Normalise to per-1M before display |
| 14 | Streaming omits `usage` without `include_usage` | Token counts lost on most chat traffic | Injected by `Invoke-MeteredCompletion` |
| 15 | Streamed responses carry no `latency_checkpoint` in the usage chunk | Missing TTFT on streamed calls | Documented; measure at the proxy |
| 16 | Cost Management `timePeriod` ignored unless `timeframe="Custom"` | HTTP 400 | Set correctly in `Get-BilledCost` |
| 17 | Cost Management throttles hard (4× 429 observed) | Apparent failure | 6 attempts, ~40 s backoff |
| 18 | Model catalog returns one entry per SKU | Inflated model counts | De-duplicated on name + version |
| 19 | Catalog is per-region | Model present in one region, absent in another | Region is a required parameter |
| 20 | Unsupported service tier succeeds silently at standard rate | Expected discount never applied | Compare `ServiceTierRequest` vs `ServiceTierResponse` |

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

**`Get-FoundryUsageTelemetry.ps1`** — the five telemetry tiers:

| Function | Tier | Purpose |
|---|---|---|
| `Invoke-MeteredCompletion` | 0 | The metering wrapper — includes the `include_usage` injection |
| `Get-FoundryModelCatalog` | 1 | Model inventory, de-duplicated across SKUs |
| `Get-AzureRetailPrices` | 2 | Raw price rows with per-row unit normalisation |
| `Get-TokenUsage` | 3 | Token metrics split by deployment and model |
| `Get-BilledCost` | 4 | Cost Management with 429 backoff |
| `Get-NearRealTimeCost` | — | The join: tokens × cached price |
| `Invoke-ArmWithRetry` | — | Shared throttle-aware ARM caller |
| `Get-ArmToken` | — | Entra token acquisition |

**`Build-FoundryPriceTable.ps1`** — the cached price table:

| Function | Purpose |
|---|---|
| `Build-FoundryPriceTable` | Fetch, classify and cache every token meter for a region |
| `Get-TokenPrice` | Look up one rate by model + SKU + kind. Returns a `Status`, never a bare zero |
| `Measure-RequestCost` | Cost one request. Returns null cost — never 0 — when any price is unknown |
| `Get-UnpricedModels` | List models that are deployable but have no usable price |
| `ConvertTo-MeterAttributes` | Parse an abbreviated `meterName` into structured attributes |

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
| Price table build | 1,410 token meters classified from 1,585 raw rows (eastus2) |
| Scope awareness | `gpt-oss-120b` Global 0.15/0.60 vs Data Zone 0.165/0.66 — both resolved correctly |
| Variant disambiguation | `gpt-5.4` → 2.50, `-pro` → 30, `-mini` → 0.75, `-nano` → 0.20 |
| Batch discount | `GlobalBatch` resolved to exactly 50% of `GlobalStandard` |
| Null safety | Anthropic → `BilledOutsideRetailAPI` / null; `Measure-RequestCost` → null, not 0 |
| Coverage gap | `DeepSeek-V4.1-Flash` → `NoMeter`; sibling `V3.2` → Priced 0.58 |
| Cost arithmetic | 10k in / 4k cached / 2k out on gpt-oss-120b = $0.0027, matches hand calculation |
| Cache hit | 62 ms vs a full paged fetch |

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

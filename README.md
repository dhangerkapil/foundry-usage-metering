# Foundry Usage Metering

Measure token usage and cost for Microsoft Foundry — in real time, across **every model
publisher**, from the right API.

There are **five** Azure surfaces that expose model pricing, usage and cost. They are not
interchangeable: they differ by orders of magnitude in freshness and grain, and only one of them
reports every publisher the same way. This repo shows which to use for what, with measured
figures rather than documentation claims.

Written for teams building an **AI gateway** in front of Foundry who need to show their own
users what they are consuming and what it costs.

Verified live against one Foundry account running **four publishers side by side** — OpenAI,
Anthropic, xAI and DeepSeek.

## The short version

| Source | Auth | Measured lag | Covers all publishers? | Use it for |
|---|---|---|---|---|
| **Azure Monitor metrics** | Entra | **113–119 s** | **Yes — identical schema** | **Totals, reconciliation, bypass detection** |
| `usage` on the inference response | — (already in path) | Zero | No — provider-shaped | Per-tenant attribution only |
| **`AzureOpenAIRequestUsage` log** | Entra | ~2 min | **No — OpenAI only** | Per-request settlement, joined on `apim-request-id` |
| ARM model catalog | Entra | Real time | Yes | Model inventory and lifecycle |
| Azure Retail Prices API | **None** | Real time (cache daily) | **No — Anthropic absent** | Unit prices |
| Cost Management Query | Entra | Hours, throttled | Aggregate only for Marketplace | Nightly reconciliation |

**Prefer Azure Monitor.** It is the only surface where `InputTokens` / `OutputTokens` /
`TotalTokens` carry the same names and dimensions for every publisher. One query covers an
account running OpenAI, Anthropic, xAI and DeepSeek at once.

**But the schema being uniform does not make the semantics uniform** — see
[Monitor inherits the reasoning-token quirk](#-monitor-inherits-the-reasoning-token-quirk-too).
Bill `TotalTokens − InputTokens`, never `OutputTokens`.

**And Monitor cannot replace inline metering.** Its dimensions are `ApiName`, `Region`,
`ModelDeploymentName`, `ModelName`, `ModelVersion` — there is **no tenant dimension**. Monitor
can tell you a deployment burned 40k tokens; it cannot tell you which of your tenants burned
them. Per-tenant attribution only exists in the request path.

So: **Monitor for truth, inline for attribution** — and the inline path has to be
provider-aware, which is most of what this repo is about.

**Do not poll Cost Management for near-real-time cost.** It lags by hours and throttles hard —
four consecutive HTTP 429s before a single query succeeded during testing.

## Inline metering is provider-shaped

An OpenAI-shaped parser does not gracefully degrade on other publishers. It **hard-fails** on
Anthropic and **silently under-bills** xAI. Every row below was verified live:

| | OpenAI | Anthropic | xAI | DeepSeek |
|---|---|---|---|---|
| Endpoint | `/openai/v1/chat/completions` | **`/anthropic/v1/messages`** | `/openai/v1/…` | `/openai/v1/…` |
| Extra header | — | **`anthropic-version`** (required) | — | — |
| Input field | `prompt_tokens` | **`input_tokens`** | `prompt_tokens` | `prompt_tokens` |
| Output field | `completion_tokens` | **`output_tokens`** | `completion_tokens` | `completion_tokens` |
| `total_tokens` | yes | **absent** | yes (disagrees) | yes |
| Input includes cache reads | **yes** → subtract | **no** → don't subtract | yes → subtract | n/a |
| Cache-write counter | — | `cache_creation_input_tokens` | — | — |
| Reasoning in `completion_tokens` | **yes** | n/a | **no** | n/a |
| Streaming usage | needs `include_usage` | automatic; **rejects** `include_usage` | needs `include_usage` | needs `include_usage` |
| `latency_checkpoint` | yes (non-streamed only) | no | no | no |

`Get-ProviderProfile` encodes this table; `ConvertTo-NormalizedUsage` collapses all four into
one schema.

### ⚠️ Anthropic is a different API, not a dialect

```
POST /openai/v1/chat/completions   with claude-haiku-4-5
  -> {"error":{"code":"api_not_supported","message":"Requested API is currently not supported"}}

POST /anthropic/v1/messages        without anthropic-version
  -> 400 "anthropic-version: header is required"
```

A gateway routing Claude to the OpenAI path doesn't under-report — it fails the request
outright. Note also that `<account>.openai.azure.com` does **not** route `/anthropic`; use
`<account>.services.ai.azure.com`, which serves both.

### ⚠️ xAI excludes reasoning tokens from `completion_tokens`

This is the most expensive defect in the set, because it is silent and the error grows with
reasoning effort. Measured on the same prompt:

| Model | `prompt` | `completion` | `reasoning` | `total` | `prompt + completion` |
|---|---|---|---|---|---|
| **grok-4.3** | 13 | 81 | 451 | **545** | 94 ❌ |
| o4-mini | 15 | 174 | 128 | 189 | 189 ✅ |

On xAI, `reasoning_tokens` are billed, **excluded** from `completion_tokens`, and **included**
in `total_tokens`. A gateway billing `completion_tokens` charges for 81 output tokens instead
of 532 — an **85% under-bill on a single request**.

On OpenAI the same tokens are already inside `completion_tokens`, so adding them there would
**double-count**. The two cannot share a code path:

```powershell
# xAI
$out = $completion_tokens + $reasoning_tokens
# OpenAI
$out = $completion_tokens
```

### ⚠️ The cache asymmetry inverts the arithmetic

```
OpenAI     prompt_tokens INCLUDES cached   ->  billable = prompt_tokens - cached_tokens
Anthropic  input_tokens  EXCLUDES cached   ->  billable = input_tokens   (no subtraction)
```

`cache_read_input_tokens` and `cache_creation_input_tokens` are **siblings** of
`input_tokens` on Anthropic, not components of it. Subtracting there double-discounts;
not subtracting on OpenAI over-bills. This is confirmed in the Foundry docs — only uncached
input counts toward Claude's ITPM quota.

### ⚠️ Streaming differs three ways

| Request | `usage` returned? |
|---|---|
| OpenAI/xAI `"stream": true` alone | **No** |
| OpenAI/xAI + `stream_options.include_usage` | **Yes** (final chunk) |
| Anthropic `"stream": true` alone | **Yes** (always) |
| Anthropic + `stream_options` | **HTTP 400** — `"Extra inputs are not permitted"` |

So the common advice "always inject `include_usage`" **breaks every streamed Claude request**.
Inject it per provider.

Worse, Anthropic emits `usage` **twice**:

```
event: message_start   usage: { input_tokens: 10, output_tokens: 1  }   <- PARTIAL
event: message_delta   usage: { input_tokens: 10, output_tokens: 13 }   <- FINAL
```

A `[regex]::Match` that takes the **first** hit records 1 output token instead of 13. Take the
**last** usage object on an Anthropic stream.

### ⚠️ Every current OpenAI flagship rejects `max_tokens`

| Parameter | Models |
|---|---|
| `max_tokens` | gpt-4.1, gpt-4o, model-router, grok-4.3, DeepSeek |
| **`max_completion_tokens`** | o4-mini, gpt-5-mini, gpt-5.1, gpt-5.4, gpt-5.6-sol, gpt-6-sol |

Sending the wrong one is HTTP 400, not a warning. A sample hardcoding `max_tokens` cannot call
any current reasoning model. Model-name lists rot, so `Invoke-MeteredCompletion` detects the
error and retries once with the other spelling.

## Anthropic bills in CCU — per-model cost is not derivable

Claude in Foundry bills through **Azure Marketplace in Claude Consumption Units (CCU)**:

- Token usage → priced at Anthropic's per-model rates → discounts → converted to CCU
- Azure Cost Management shows **one CCU line with no per-model dimension**
- The CCU meter is MACC-eligible and metered hourly, invoiced monthly in arrears

Three consequences for a metering system:

1. **Anthropic has no Retail Prices meter.** Its absence is correct, not a coverage gap. A
   gateway reading "no meter" as "free" bills nothing for Claude.
2. **Derived cost (`billed ÷ tokens`) is impossible for Claude.** Not hard — impossible. The
   billed figure has no model grain.
3. **Token counts are still exact.** Azure Monitor and the `usage` block both report Claude
   tokens precisely. Only the per-model *dollar* figure is unavailable.

`Get-TokenPrice` returns `BilledOutsideRetailAPI` for Anthropic, and `Get-NearRealTimeCost`
tags those rows `BillingModel = CCU` so a null cost is distinguishable from a real coverage
gap (`NoMeter`). Those two must never be conflated — one is by design, the other is an alert.

Rates: <https://aka.ms/ccu-pricing>

## Measured latency

Not estimates. Isolated probes, one per publisher, emit timestamp vs first visibility in Azure
Monitor (15 s poll granularity):

| Publisher | Deployment | Monitor lag |
|---|---|---|
| xAI | grok-4.3 | **115 s** |
| Anthropic | claude-haiku-4-5 | **116 s** |
| OpenAI | gpt-4.1-nano | **119 s** |
| DeepSeek | DeepSeek-V4.1-Flash | **113 s** |

**Lag is uniform across publishers — roughly two minutes.** Minimum grain is `PT1M`, and token
counts are exact, not sampled.

Other documented delays, for contrast:

| Surface | Delay |
|---|---|
| Azure Monitor metrics | ~2 min (measured above) |
| Diagnostic logs → Log Analytics | up to 15 min |
| Cost Management | ~5 hours from billing event |
| CCU metering | hourly meter, monthly invoice |

### Transient empty responses

In 60 rapid back-to-back streamed calls, **2 returned a completely empty body** — 2 bytes, no
SSE frames, no error JSON — with `include_usage` correctly set. A separate non-streamed
DeepSeek call did the same.

Azure Monitor recorded **zero tokens** for that DeepSeek call, which confirms these are genuine
failed requests rather than silently-billed-but-unreported traffic. The caller gets nothing
either, so it surfaces as an error, not a silent leak.

Still: **never record zero tokens from a missing usage block.** Treat it as unknown and let the
Monitor reconciliation tier settle the window.

## Why run Azure Monitor when inline metering is faster

**Azure Monitor sees all traffic. Your gateway only sees what went through it.**

Reconciliation over one window during testing:

| Source | Input tokens |
|---|---|
| Gateway-side inline metering | 75 |
| Azure Monitor | 122 |

The difference was traffic generated outside the metering wrapper. In production that delta is
**someone calling the Foundry endpoint directly, bypassing the gateway** — unmetered,
unattributed usage.

Gateway total should equal Monitor total. A persistent gap is a leak. Add the empty-response
case above and the provider-parsing defects, and Monitor is the only number you can defend.

Useful dimensions on `ModelRequests`: `StatusCode`, `StreamType`, `IsSpillover`,
`ServiceTierRequest` and `ServiceTierResponse`. The last pair lets you confirm a request
actually *got* the service tier it asked for — a request for an unsupported tier can succeed
silently at the standard rate, so comparing these two is the only way to detect it.

### What Monitor cannot do

- **No tenant dimension.** Hence inline metering.
- **`TokensCacheMatchRate` and `ProvisionedConsumedTokens` are PTU-only.** Claude runs Global
  Standard / Data Zone Standard, so there is no cache hit-rate metric for it.
- **No project-level cost attribution for Marketplace models.** Chargeback by project does not
  cover Claude.

### ⚠️ Monitor inherits the reasoning-token quirk too

The uniform schema is not uniform semantics. Azure Monitor's `OutputTokens` carries the **same
xAI exclusion as the inference API** — reasoning tokens are missing from `OutputTokens` but
present in `TotalTokens`.

Measured on `grok-4.3` from Monitor:

```
InputTokens  =  34
OutputTokens =  99
TotalTokens  = 998

InputTokens + OutputTokens  =  133   ← what a naive dashboard shows
TotalTokens − InputTokens   =  964   ← actual billable output
```

A **7× under-report of output** on a reasoning workload, straight from the "source of truth".

**Use `TotalTokens − InputTokens` as billable output.** It is correct for every publisher
measured, because it equals `OutputTokens` wherever the publisher is consistent and recovers
the missing tokens wherever it is not:

| Deployment | `In` | `Out` | `Total` | `Total − In` | Matches `Out`? |
|---|---|---|---|---|---|
| claude-opus-5-5 | 6,803 | 322,316 | 329,119 | 322,316 | ✅ |
| gpt-4.1-mini | 1,639 | 739 | 2,378 | 739 | ✅ |
| **grok-4.3** | 34 | 99 | 998 | **964** | ❌ — reasoning recovered |

`Get-NearRealTimeCost` does this automatically and reports the raw metric alongside it as
`ReportedOutput`, so the divergence stays visible rather than being silently papered over.

## Per-request records: the fourth surface

Monitor aggregates to a 1-minute bucket. If you need to settle **one request** — join a token
count to a request ID and explain a line on an invoice — aggregates cannot do it.

Foundry has a diagnostic log category for exactly this: **`AzureOpenAIRequestUsage`**. It is
off by default, it is not in the portal Metrics blade, and it covers one publisher.

### Surface coverage by publisher

| Surface | Grain | Lag | OpenAI | Anthropic | xAI | DeepSeek |
|---|---|---|---|---|---|---|
| **Azure Monitor metrics** | 1 min, per deployment | ~2 min | ✅ | ✅ | ⚠️ ¹ | ✅ |
| **`AzureOpenAIRequestUsage`** — per-request tokens | **Per request** | ~2 min ² | ✅ | ❌ ³ | ❌ ³ | ❌ ³ |
| **`RequestResponse`** — per-request access log | Per request | ~2 min ² | ✅ | ⚠️ ⁴ | ⚠️ ⁴ | ⚠️ ⁴ |
| Inline `usage` on the response | Per request | Zero | ✅ | ⚠️ ⁵ | ⚠️ ⁵ | ⚠️ ⁵ |
| Azure Retail Prices | Per meter | n/a | ✅ | ❌ ⁶ | ✅ | ⚠️ ⁷ |
| Cost Management | Daily, per meter | Hours | ✅ | ⚠️ ⁸ | ✅ | ✅ |

- **¹** `OutputTokens` excludes reasoning tokens. Bill `TotalTokens − InputTokens`.
- **²** Log Analytics ingestion; documented as up to 15 min, observed ~2 min.
- **³** **Zero rows.** Verified over 30 days / 35,114 records on an account actively serving all
  four publishers: 17 distinct model names, every one OpenAI.
- **⁴** Logged, but with **no token counts** — only byte lengths and timing.
- **⁵** Different field names, different cache semantics, different streaming rules. This is what
  `Get-ProviderProfile` and `ConvertTo-NormalizedUsage` exist to absorb.
- **⁶** Anthropic has no retail meter at all — billed in CCU.
- **⁷** Present for some DeepSeek versions, absent for others (`V4.1-Flash` → `NoMeter`).
- **⁸** A single aggregate CCU meter with no per-model dimension.

### Enable it first — it is off by default

The category exists on every Foundry account but emits nothing until a diagnostic setting
routes it somewhere. Without one, the table is simply empty and looks like the feature does not
exist.

```powershell
az monitor diagnostic-settings create `
  --name foundry-usage `
  --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>" `
  --workspace "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>" `
  --logs '[{"category":"AzureOpenAIRequestUsage","enabled":true}]'
```

Portal equivalent: **Foundry account → Monitoring → Diagnostic settings → Add diagnostic
setting**, tick **Azure OpenAI Request Usage**, destination **Send to Log Analytics workspace**.
The `allLogs` category group also includes it.

Available categories on `Microsoft.CognitiveServices/accounts`:

| Category | Contents |
|---|---|
| `AzureOpenAIRequestUsage` | **Per-request token counts** — the one that matters here |
| `RequestResponse` | Access log: operation, status, duration, byte counts. No tokens |
| `Audit` | Control-plane access |
| `Trace` | Agent/tool execution traces |
| `ManagedNetworkEvent` | Managed VNet events |
| `AllMetrics` | Metric export — *not* needed for Monitor queries, which read the metrics API directly |

Two cautions. A setting may already exist because **Azure Policy** created one — all three
accounts checked here were configured by governance policy, not by hand, so an enterprise
tenant may already be emitting this without the platform team knowing. And Log Analytics
ingestion is **billed by volume**; `allLogs` on a busy account is expensive, so scope the
setting to the categories you actually query.

### What a row contains

```json
{
  "modelDeploymentName": "gpt-5.4",
  "modelName":           "gpt-5.4",
  "modelVersion":        "2026-03-05",
  "streamType":          "Non-Streaming",
  "promptTokens":        [21777],
  "cachedTokens":        [21120],
  "generatedTokens":     [317],
  "timeToFirstTokenMs":  2198.361,
  "timeToLastTokenMs":   4232.136
}
```

Plus `CorrelationId`, `TimeGenerated` and `_ResourceId` on the envelope.

- `promptTokens` **includes** `cachedTokens` — same semantics as the inline OpenAI block, so
  billable input is `promptTokens − cachedTokens`.
- There is **no reasoning-token field**. Zero rows in 35,114 mention one. For OpenAI that is
  harmless because `generatedTokens` already includes reasoning, but it means this log cannot
  be used to separate reasoning from completion.
- `streamType` distinguishes `Streaming` from `Non-Streaming`, and TTFT is populated on both —
  which the inline path cannot give you on a streamed call.

### The join key is `apim-request-id`

`CorrelationId` on the log row equals the **`apim-request-id`** response header. That is the
field to persist in your gateway if you want per-request settlement.

Verified on two live calls — header captured at call time, row read back afterwards:

| Call | `apim-request-id` → `CorrelationId` | Inline `usage` | Logged |
|---|---|---|---|
| 1 | `2d5522fd-…` ✅ match | 18 / 12 | 18 / 12 — identical |
| 2 | `7f8669a9-…` ✅ match | 8 / 4 | 8 / 4 — identical |

Two headers that look like they should work, and do not:

- **`x-request-id`** — returned on every response, appears **nowhere** in any log.
- **`x-ms-client-request-id`** — a caller-supplied value, accepted and echoed back verbatim, but
  **not persisted**. You cannot stamp your own tenant ID on a call and read it back out of the
  log. Attribution still has to be held gateway-side, keyed on `apim-request-id`.

### What this means

For an **OpenAI-only** gateway, per-request settlement is available today: persist
`apim-request-id` alongside your tenant ID, then join to this table.

For **any other publisher** there is no per-request token record on any surface. The gateway's
own inline measurement is the only per-request number that exists — which is precisely why it
has to be provider-aware and correct.

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

# Models that are priced only in context bands need the band
Measure-RequestCost -Table $prices -ModelName 'gpt-6-astra' -Publisher 'OpenAI' `
    -Sku GlobalStandard -ContextTier Short `
    -InputTokens 10000 -CachedTokens 4000 -CacheWriteTokens 2000 -OutputTokens 1000
#   CostUSD = 0.139

# Models that ship several dated versions need the version
Get-TokenPrice -Table $prices -ModelName 'gpt-4o' -Publisher 'OpenAI' `
    -Sku GlobalStandard -Kind Input -ModelVersion '2024-11-20'
#   Status = Priced, PricePer1M = 2.50   (2024-05-13 would be 5.00)
```

### Resolving the publisher

`Get-TokenPrice -Publisher` expects values like `OpenAI`, `OpenAI-OSS`, `DeepSeek`, `Mistral AI`.
Those come from the ARM model catalog — but **not** from the field you would expect:

```
model.publisher  ->  empty on all 328 catalog entries in eastus2
model.format     ->  'OpenAI', 'OpenAI-OSS', 'DeepSeek', 'Anthropic', ...
```

Reading `publisher` returns a silent null, so every lookup fails as `UnknownPublisher` and the
whole catalog looks unpriceable. `Get-FoundryModelCatalog` coalesces `publisher` ← `format`.

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

So the key is **model + scope + token kind + context tier + deployment type + host + purpose**,
and the gateway must pass the deployment's actual SKU.

Three further splits are easy to miss, and each is a large error:

| Split | Example | Delta |
|---|---|---|
| Cache **read** vs cache **write** | `gpt-5.6-sol` Long: `Cd Inp` 1.60 vs `Cd Wr` 20.00 | **12.5×** |
| Service tier `Std` / `Flex` / `PP` | `gpt-5.6-sol` Short input: Std 4.00 vs PP 8.00 | **2×** |
| Context band on newer models | `gpt-6-astra` input: Short 10.00 vs Long 20.00 | **2×** |

`PP` is **Priority Processing**, not Provisioned — PTU is capacity billed per hour and never
appears as a per-token meter. `-Sku ProvisionedManaged` returns `BilledAsCapacity`.

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
the variant to match on both sides, and returns `NoMeter` rather than guessing when nothing
matches the model's own variant (or `Ambiguous` when several meters match at different prices).

Two subtleties that cost real money, both found by review rather than by testing:

- **The filter must be unconditional.** An earlier version skipped it when it matched nothing,
  which let a base model fall back onto a variant's meter — `gpt-5.3` was priced from
  `5.3 codex`. An empty result means `NoMeter`, not permission to keep the unfiltered set.
- **The version token must be anchored.** `20` is a substring of `120`, and `4` is a token of
  `gpt-4-turbo128K`. Unanchored, `gpt-oss-20b` priced from the `120B` meter and `gpt-4o` priced
  from `gpt-4-turbo128K` — 4× and 3.2× over, both reported as a confident `Priced`.

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
| `NoMeter` | **No usable match.** Either a real coverage gap, or the model name cannot be mapped to an abbreviated meter without guessing | Alert. Do not bill as zero. The note names the near-miss meters so you can pin an explicit override |
| `BilledOutsideRetailAPI` | Publisher bills via Marketplace (Anthropic) | Correct, not a gap. Source cost from Cost Management |
| `UnknownPublisher` | Not in the family map | No verdict claimed. Add the mapping |
| `Ambiguous` | Several meters, different prices | Narrow by context tier, modality or `-ModelVersion` |
| `BilledAsCapacity` | SKU is provisioned throughput (PTU) | Billed per PTU per hour, not per token. Token counts still useful for utilisation; cost comes from the reservation |

### Refusing to answer is a feature

Run against the full eastus2 catalog, this resolves **56 of 136** models to a price:

```
Priced                  56
NoMeter                 57      <- refuses rather than guesses
BilledOutsideRetailAPI  14      <- Anthropic, correctly out of scope
Ambiguous                5
UnknownPublisher         4      <- Black Forest Labs (image models, not token-billed)
```

A looser matcher reaches a far higher "coverage" number — earlier drafts of this code did, and
every point of that extra coverage was wrong:

| Model | Loose match resolved to | Error |
|---|---|---|
| `gpt-4o` | `gpt-4-turbo128K` | 3.2× over |
| `gpt-oss-20b` | `gpt-oss-120B` | 4× over |
| `DeepSeek-R1` | `V3.1` | 9% under |
| `whisper`, `gpt-realtime`, `model-router` | `5.5 ShortCo` | unrelated model |
| `mistral-medium-3-5` | `Mistral Large 3` | wrong product |
| `Phi-4-multimodal` | `Phi-4` | 56% over |

All of those returned `Status = Priced` with no warning. **A billing system that is wrong 20% of
the time and never says so is worse than one that answers 40% of the time and flags the rest.**
Where a model genuinely cannot be mapped, the `NoMeter` note lists the near-miss meters so you
can add an explicit override rather than inherit a silent error.

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

## Quick start

```powershell
az login

# All tiers against your own Foundry account.
# Exercises ONE deployment per publisher automatically.
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account

# Narrow the window, pick a region, include the throttled cost query
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account `
    -Region eastus2 -LookbackMins 60 -IncludeCost

# Target a single deployment
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account -Deployment claude-sonnet-5
```

`-ResourceGroup` and `-SubscriptionId` are resolved from your `az` context when omitted.

With no `-Deployment`, the inline-metering section picks one deployment **per publisher** and
calls each one streamed and non-streamed. A single-provider smoke test is exactly how the
Anthropic and xAI defects survived the first pass.

## Parameters

| Parameter | Description |
|---|---|
| `-AccountName` | **Required.** Your Foundry / Azure OpenAI account name |
| `-SubscriptionId` | Defaults to the current `az` subscription |
| `-ResourceGroup` | Resolved from the account name when omitted |
| `-Region` | Region for the catalog and pricing lookups. Default `eastus2` |
| `-LookbackMins` | Window for the Azure Monitor query. Default `60` |
| `-Deployment` | Meter one specific deployment instead of one per publisher |
| `-IncludeCost` | Also run the Cost Management query. Off by default because it is slow and throttled |

## What's in here

**`Get-FoundryUsageTelemetry.ps1`** — the telemetry tiers:

| Function | Tier | Purpose |
|---|---|---|
| `Get-ProviderProfile` | 0 | Maps a publisher to endpoint, headers, field names and cache/reasoning semantics |
| `ConvertTo-NormalizedUsage` | 0 | Collapses every publisher's usage block into one schema; recomputes totals |
| `Invoke-MeteredCompletion` | 0 | Provider-aware metering wrapper — routing, conditional `include_usage`, `max_completion_tokens` retry |
| `Get-FoundryModelCatalog` | 1 | Model inventory, de-duplicated across SKUs |
| `Get-AzureRetailPrices` | 2 | Raw price rows with per-row unit normalisation |
| `Get-FoundryDeployments` | 2b | Deployment → publisher join, from `properties.model.format` |
| `Get-TokenUsage` | **3** | **Azure Monitor token metrics — the preferred, cross-publisher source** |
| `Get-BilledCost` | 4 | Cost Management with 429 backoff |
| `Get-NearRealTimeCost` | — | The join: tokens × cached price, tagged `Derived` / `CCU` / `NoMeter` |
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

Note also that **Anthropic / Claude has no family in this API**. Claude bills through Azure
Marketplace in Claude Consumption Units, so its absence is correct rather than a coverage gap —
see [Anthropic bills in CCU](#anthropic-bills-in-ccu--per-model-cost-is-not-derivable). A
gateway that reads "no meter" as "free" would get this badly wrong.

The Retail Prices API is **anonymous** — no auth, no subscription context. Prices returned are
**list prices, not negotiated rates**.

## Recommended architecture

```
                ┌──────────────────────────────────────────────────────────────────┐
 user request   │                        Your AI Gateway                           │
 ──────────────▶│                                                                  │
 + tenant id    │  ① publisher  ← ARM properties.model.format, never the name      │
                │  ② endpoint   → /openai/v1/chat/completions                      │
                │                 /anthropic/v1/messages        ← Anthropic *      │
                │  ③ limit param  max_tokens                                       │
                │                 max_completion_tokens         ← OpenAI o/5/6 *   │
                │  ④ streaming    stream_options.include_usage                     │
                │                 omit entirely                 ← Anthropic * 400  │
                │  ⑤ forward, capture usage + apim-request-id                      │
                │  ⑥ normalise    + reasoning → output          ← xAI *            │
                │                 no cache subtraction          ← Anthropic *      │
                │                 recompute total               ← Anthropic * none │
                │  ⑦ cost = tokens × cached unit price                             │
                │                 null, not zero                ← Anthropic * CCU  │
                │  ⑧ emit per-TENANT metric ── ZERO LAG ───────────────────────────┼──▶ dashboard
                └───────────────────────────────┬──────────────────────────────────┘
                                                ▼
                                       Microsoft Foundry
                                                │
      ┌──────────────────┬──────────────────────┼──────────────────────┐
      ▼                  ▼                      ▼                      ▼
 Retail Prices    ★ AZURE MONITOR ★     AzureOpenAIRequestUsage   Cost Management
 anonymous        PREFERRED SOURCE      diagnostic log            hours, throttled
 cache daily      ~2 min · 1-min grain  ~2 min · PER REQUEST      daily grain
 no Anthropic *   ALL publishers        OpenAI ONLY *             aggregate CCU
                  one schema            OFF BY DEFAULT            for Anthropic *
                  no tenant dimension   join: apim-request-id
      │                  │                      │                      │
      ▼                  ▼                      ▼                      ▼
 unit price       reconcile gateway      per-request            nightly computed
 table            vs Monitor =           settlement             vs billed = drift
                  bypass detection       (OpenAI only *)
```

`*` marks a point where a publisher diverges from the OpenAI-shaped default. Every one of them
fails *open* — HTTP 200 with wrong or missing numbers — except the three that return HTTP 400.

| `*` | Divergence | If you ignore it |
|---|---|---|
| Anthropic endpoint | `/anthropic/v1/messages`, `anthropic-version` header required | `api_not_supported` — no Claude metering at all |
| Anthropic streaming | `stream_options` rejected; usage streams unconditionally and **twice** | HTTP 400, or the partial `message_start` count |
| Anthropic fields | `input_tokens` / `output_tokens`, no `total_tokens` | Silent **0** — Claude billed as free |
| Anthropic cache | `input_tokens` already **excludes** cache reads | Double-discounted input |
| Anthropic cost | CCU via Marketplace, no per-model meter | A null that looks like a coverage gap |
| xAI reasoning | `reasoning_tokens` excluded from `completion_tokens` | **85% output under-bill** |
| xAI in Monitor | `OutputTokens` carries the same exclusion | **7× under-report** from the "source of truth" |
| OpenAI o/5/6 | `max_tokens` rejected, needs `max_completion_tokens` | HTTP 400 on every reasoning model |
| Per-request log | `AzureOpenAIRequestUsage` is OpenAI-only and off by default | No per-request record exists for anyone else |

**Read the bottom tier as independent loops.** Monitor is the system of record for *how many
tokens*; the gateway is the system of record for *whose tokens*; the per-request log settles
*which request* — for OpenAI only. Any persistent gap between gateway and Monitor is a bypass
or a parsing defect.

## Implementation checklist

**Provider handling — do this first**

- [ ] Resolve the publisher from `properties.model.format` on the ARM deployment; never infer
      it from the deployment name
- [ ] Route Anthropic to `/anthropic/v1/messages` with an `anthropic-version` header
- [ ] Use the `<account>.services.ai.azure.com` host — `.openai.azure.com` does not route
      `/anthropic`
- [ ] Parse `input_tokens`/`output_tokens` for Anthropic, `prompt_tokens`/`completion_tokens`
      otherwise
- [ ] **Do not subtract cached tokens on Anthropic** — `input_tokens` already excludes them
- [ ] **Add `reasoning_tokens` to output on xAI**, and do *not* add them on OpenAI
- [ ] Recompute `total_tokens` yourself; Anthropic has none and xAI's disagrees
- [ ] Retry once with `max_completion_tokens` when a model rejects `max_tokens`

**Streaming**

- [ ] Inject `stream_options.include_usage` on the OpenAI-compatible path **only**
- [ ] Never send `stream_options` to Anthropic — it is HTTP 400
- [ ] Take the **last** `usage` object on an Anthropic stream, not the first
- [ ] Measure TTFT at the proxy for Anthropic and for all streamed traffic

**Pricing and cost**

- [ ] Build the price table nightly using `serviceName eq 'Foundry Models'`
- [ ] **Normalise price per row by `unitOfMeasure`** — never a blanket multiplier
- [ ] Treat a missing meter as **null, not zero**; alert rather than silently billing nothing
- [ ] Distinguish `CCU` (Anthropic, null by design) from `NoMeter` (a real gap worth alerting)
- [ ] Do not attempt per-model cost reconciliation for Claude — the CCU meter has no model grain

**Per-request settlement (OpenAI only)**

- [ ] Enable the `AzureOpenAIRequestUsage` diagnostic category — it emits nothing by default
- [ ] Check whether Azure Policy has already created a diagnostic setting before adding one
- [ ] Scope the setting to the categories you query; `allLogs` on a busy account is costly
- [ ] Persist **`apim-request-id`** with your tenant ID — it is the `CorrelationId` join key
- [ ] Do **not** rely on `x-request-id` or `x-ms-client-request-id`; neither reaches the log
- [ ] Billable input from the log is `promptTokens − cachedTokens`
- [ ] Expect no per-request record for Anthropic, xAI or DeepSeek — the gateway's own inline
      number is the only one that exists

**Reconciliation**

- [ ] Poll Azure Monitor every 1–5 minutes as the cross-publisher source of truth
- [ ] **Bill `TotalTokens − InputTokens`, never `OutputTokens`** — Monitor carries the same xAI
      reasoning exclusion as the inference API
- [ ] Alert when `monitor_tokens − gateway_tokens` exceeds a threshold
- [ ] Never record zero tokens from a missing usage block — mark the window unknown and let
      Monitor settle it
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
| `AzureOpenAIRequestUsage` log | **Log Analytics Reader** | Workspace |
| Create the diagnostic setting | **Monitoring Contributor** | Foundry account + workspace |
| Cost Management query | **Cost Management Reader** | Subscription |
| Model catalog | **Reader** | Subscription |
| Retail Prices | *none* | — |

## Source documentation

- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Azure Monitor — Metrics: List](https://learn.microsoft.com/en-us/rest/api/monitor/metrics/list)
- [Monitor model deployments in Microsoft Foundry Models](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/monitor-models)
- [Monitoring data reference for Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry/openai/monitor-openai-reference) — metric and log category schemas
- [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings) — how to route `AzureOpenAIRequestUsage` to a workspace
- [Microsoft Foundry SDKs and endpoints](https://learn.microsoft.com/en-us/azure/foundry/how-to/develop/sdk-overview) — including the Anthropic SDK against `/anthropic`
- [Cost Management — Query: Usage](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage)
- [Plan and manage costs for Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/concepts/manage-costs)
- [Claude models in Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models)
- [Claude Consumption Units (CCU) billing](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-billing)
- [Claude model quotas and rate limits](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-quotas-limits)
- [Foundry SDKs and endpoints (Anthropic SDK)](https://learn.microsoft.com/en-us/azure/foundry/how-to/develop/sdk-overview)
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

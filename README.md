# Foundry Usage Metering

Measure token usage and cost for Microsoft Foundry — in real time, across **every model
publisher**, from the right API.

There are four Azure APIs that expose model pricing, usage and cost. They are not
interchangeable: they differ by orders of magnitude in freshness, and only one of them reports
every publisher the same way. This repo shows which to use for what, with measured figures
rather than documentation claims.

Written for teams building an **AI gateway** in front of Foundry who need to show their own
users what they are consuming and what it costs.

Verified live against one Foundry account running **four publishers side by side** — OpenAI,
Anthropic, xAI and DeepSeek.

## The short version

| Source | Auth | Measured lag | Covers all publishers? | Use it for |
|---|---|---|---|---|
| **Azure Monitor metrics** | Entra | **113–119 s** | **Yes — identical schema** | **Totals, reconciliation, bypass detection** |
| `usage` on the inference response | — (already in path) | Zero | No — provider-shaped | Per-tenant attribution only |
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

## Complete gotcha list

Every one of these was hit in practice. Most fail *open* — HTTP 200 with wrong or empty data
rather than an error.

| # | Gotcha | Symptom | Handling |
|---|---|---|---|
| 1 | `serviceName` is `'Foundry Models'`, not `'Cognitive Services'` | HTTP 200, **zero rows** | Builder throws with a pointed message if zero rows come back |
| 2 | `unitOfMeasure` mixed: `1K`, `1M`, `1/Hour`, `1/Month` | Blanket multiplier off by 1000× | Normalised per row; non-token meters excluded |
| 3 | `meterName` uses abbreviations, not model IDs | `gpt-4.1` never matches `gpt 4.1 Inp glbl Tokens` | Regex vocabulary maps the abbreviations |
| 4 | **`opt` means output**, not "optional" | Output mis-keyed, under-bills 4–6× | Explicit in the kind vocabulary |
| 5 | Scope has **five** spellings: `DZ`, `DZn`, `DZone`, `DataZone`, `Data Zone` (two words) | Any missed form falls through to the Global default — a 10% under-bill (gpt-4.1 Global $2.00 vs Data Zone $2.20) | Regex covers all five |
| 6 | Kind markers appear concatenated and hyphenated: `BatchOutp`, `txt-out-glbl`, `inpt`, bare `In` | 175 real meters dropped as unclassifiable | Pattern matching on the normalised name, not token equality |
| 7 | **Cache *write* is a different meter from cache *read*** — `Cd Wr` vs `Cd Inp` | Verified 12.5× apart (gpt-5.6-sol long: write $20.00 vs read $1.60/1M). One `Cached` kind makes the key collide and the winner arbitrary | Separate `CacheWrite` kind, tested **before** `CachedInput` |
| 8 | "Cached" has four spellings: `cach`, `cchd`, `cched`, `cd` | `cched` meters silently classified as plain Input | All four in the vocabulary |
| 9 | Context tier also abbreviates to `LoCo` / `ShCo` | Long context is exactly 2× base, so a miss is a 50% under-bill | `loco`/`shco` added |
| 10 | `PP` is **Priority Processing**, not Provisioned | Verified exactly 2× standard across all four kinds. PTU is capacity billed `1/Hour` and never appears as a per-token meter, so labelling `PP` "Provisioned" is simply wrong | Distinct `Priority` tier; `Provisioned`/`PTU` SKUs return `BilledAsCapacity` |
| 11 | `Flex` / `Fl` is a third service tier | Collided with `Standard`, so a Flex meter could answer a Standard lookup | Distinct `Flex` tier |
| 12 | Audio meters carry a date suffix: `aud1217`, `aud 0828` | A bare `\baud\b` misses them, so an $11/1M **audio** meter defaults to `Text` and becomes a candidate for a chat lookup | `aud\d*`; realtime-audio split from realtime-text |
| 13 | Fine-tuning **grader** meters sit beside inference meters for the same model | A grader rate can answer an ordinary chat lookup | `Purpose` field; lookups default to `Inference` |
| 14 | `productName` inconsistent — `Azure Deepseek Models` (lowercase s) | `contains(…,'DeepSeek')` returns nothing | Exact family strings in the map |
| 15 | One model has many meters (scope × kind × tier × type × host × purpose) | Wrong-but-plausible price | Composite cache key |
| 16 | Version token is a substring of variants | `gpt-5.4` billed at `pro` rate, 12× over | Variant must match on both sides |
| 17 | Meters abbreviate variants too (`mini` → `mn`) | Variant match fails, lookup falls back to the base rate | Variant aliases are regex alternations |
| 18 | Deployable GA models with no meter | Cost silently 0 | `NoMeter` + null, never 0 |
| 19 | Anthropic has no family at all | "Free" Claude traffic | `BilledOutsideRetailAPI` status |
| 20 | List prices only | Over-reports spend vs invoice | `IsListPrice` on table and every result |
| 21 | Paginated via `NextPageLink` | Silent truncation | Full pagination |
| 22 | API throttles | Partial table | Backoff; throws rather than returning partial |
| 23 | `Format-Table` rounds to 2dp | Per-token prices render `0.00` | Normalise to per-1M before display |
| 24 | Streaming omits `usage` without `include_usage` | Token counts lost on most chat traffic | Injected by `Invoke-MeteredCompletion` |
| 25 | Streamed responses carry no `latency_checkpoint` in the usage chunk | Missing TTFT on streamed calls | Documented; measure at the proxy |
| 26 | Cost Management `timePeriod` ignored unless `timeframe="Custom"` | HTTP 400 | Set correctly in `Get-BilledCost` |
| 27 | Cost Management throttles hard (4× 429 observed) | Apparent failure | 6 attempts, ~40 s backoff |
| 28 | Model catalog returns one entry per SKU and per version | Inflated model counts | De-duplicated on name; SKUs and versions unioned across entries |
| 29 | Catalog is per-region | Model present in one region, absent in another | Region is a required parameter |
| 30 | Unsupported service tier succeeds silently at standard rate | Expected discount never applied | Compare `ServiceTierRequest` vs `ServiceTierResponse` |
| 31 | **The ARM catalog's `publisher` field is empty on every entry** — verified 328/328 null in eastus2. The publisher key lives in `format` | Reading `publisher` yields a silent null, so every price lookup fails with "unknown publisher" and looks like missing coverage | `Get-FoundryModelCatalog` coalesces `publisher` ← `format` |
| 32 | A version token is a substring of a longer one: `20` ⊂ `120`, `4` ⊂ `gpt-4-turbo128K` | `gpt-oss-20b` priced from the `120B` meter (4× over); `gpt-4o` priced from `gpt-4-turbo128K` (3.2× over) | Token keeps trailing letters (`4o`, `20b`) and is anchored with `(?<![0-9A-Za-z]) … (?![0-9A-Za-z])` |
| 33 | Dated model versions have different prices: `gpt-4o` ships as `0513` / `0806` / `1120` at **$5.00 vs $2.50** | The model name alone cannot choose; picking the first is a coin flip | `-ModelVersion` maps `2024-11-20` → `1120`; without it the result is `Ambiguous`, not a guess |
| 34 | A variant filter that is skipped when it matches nothing is worse than no filter | `gpt-5.3` priced from `5.3 codex`; `gpt-4o-mini` from `gpt-4-turbo128K` | The filter is unconditional; an empty result is `NoMeter`, not a licence to keep the unfiltered set |
| 35 | The newest models have **no Standard context tier** — 9 model families are priced only in Short/Long bands that differ 2× | A caller defaulting to `Standard` sees `NoMeter` and reads it as a coverage gap | `NoMeter` now names the tiers that *do* exist; `Measure-RequestCost` accepts `-ContextTier` |
| 36 | The version token often carries a **letter prefix** — `R1`, `V3.2`, `K2`, `o3` | Stripping it leaves `1`, which then matches *inside* `V3.1`: `DeepSeek-R1` priced at 1.23 instead of 1.35, while its own `R1` meter was excluded | The token keeps the glued letter, and anchoring excludes `.` so it cannot match a version fragment |
| 37 | **Flex meters drop the dot** from the version — `54 inp Flex Gl` for `gpt-5.4` | A dotted token can never reach them; all 42 Flex meters were unreachable | A dot-stripped form is tried as an anchored fallback |
| 38 | Some models have **no digits at all** — `whisper`, `gpt-realtime`, `model-router`, `codex-mini` | Nothing is left to match on, so they silently resolved to an unrelated meter (`5.5 ShortCo inp Gl`, $5.00) | No version token ⇒ `NoMeter`. These must be mapped explicitly |
| 39 | A name can carry **two** variant markers — `Phi-4-Mini MM` is both `mini` and `mm` | Stopping at the first marker discards the right meter: `Phi-4-multimodal` took the plain `Phi-4` rate, 56% over | Variant markers are collected as a set and compared as a set |
| 40 | Catalog versions are not uniform — `2024-11-20`, `turbo-2024-04-09`, `001`, `latest` | An unparsed `-ModelVersion` was silently ignored while the error still said "pass `-ModelVersion`" | MMDD is extracted from anywhere in the string; unusable values warn |
| 41 | **Anthropic is a different API, not a dialect** — `/openai/v1/chat/completions` returns `api_not_supported` | Every Claude call fails outright; an OpenAI-only gateway cannot meter Claude at all | `Get-ProviderProfile` routes Anthropic to `/anthropic/v1/messages` |
| 42 | `anthropic-version` header is mandatory | HTTP 400 on every Claude request | Sent automatically for the Anthropic profile |
| 43 | `<account>.openai.azure.com` does not route `/anthropic` | 404 even with correct path and headers | Samples use `<account>.services.ai.azure.com`, which serves both |
| 44 | Anthropic field names differ: `input_tokens` / `output_tokens` | An OpenAI parser reads `prompt_tokens` and records **0**, not an error — silent total loss of Claude billing | `ConvertTo-NormalizedUsage` branches per provider |
| 45 | Anthropic reports **no `total_tokens`** | `[int]$null` → 0; totals silently collapse | Total is always recomputed, never read |
| 46 | **Anthropic `input_tokens` EXCLUDES cache reads; OpenAI `prompt_tokens` INCLUDES them** | Subtracting cached tokens on Anthropic double-discounts input | Subtraction applied only when `InputIncludesCache` |
| 47 | **xAI excludes `reasoning_tokens` from `completion_tokens` but includes them in `total_tokens`** | grok-4.3 measured 13 + 81 ≠ 545. Billing `completion_tokens` under-bills output by **85%** on one request | Reasoning added to output only when `OutputIncludesReasoning` is false |
| 48 | Anthropic **rejects** `stream_options` with HTTP 400 | "Always inject include_usage" breaks every streamed Claude call | Injected only on the OpenAI-compatible path |
| 49 | **Anthropic emits `usage` twice on a stream** — `message_start` is partial, `message_delta` is final | First-match regex recorded 1 output token instead of 13 | `UseLastUsageMatch` takes the final object |
| 50 | **Every current OpenAI flagship rejects `max_tokens`** — o4-mini, gpt-5.x, gpt-6.x need `max_completion_tokens` | HTTP 400; a sample hardcoding `max_tokens` cannot call any reasoning model | Detected from the error and retried once |
| 51 | DeepSeek omits `prompt_tokens_details` entirely | A cached-token lookup yields null, not 0 | `[int]$null` coalesces to 0, which is correct here |
| 52 | Anthropic has no `latency_checkpoint` | TTFT silently null for Claude | `HasLatencyBlock` gates the fields; measure at the proxy |
| 53 | Occasional **completely empty response body** (2 bytes, no SSE, no error) under rapid sequential load — 2 in 60 streamed calls | Looks identical to "no usage" | Monitor confirmed **zero tokens** for such a call, so it is a failed request, not a silent under-bill. Never record 0; reconcile the window |
| 54 | **Azure Monitor's `OutputTokens` inherits the xAI reasoning exclusion** — `TotalTokens` includes reasoning, `OutputTokens` does not | grok-4.3 from Monitor: in 34, out 99, total 998. A dashboard summing in+out shows 133 against a real 964 — a **7× under-report** from the "source of truth" | `Get-NearRealTimeCost` bills `TotalTokens − InputTokens` and surfaces the raw metric as `ReportedOutput` |

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
                 ┌──────────────────────────────────────────────┐
  user request   │               Your AI Gateway                │
  ───────────────▶                                              │
                 │  ① resolve publisher from model.format       │
                 │  ② pick endpoint:  /openai  or  /anthropic   │
                 │  ③ inject include_usage ONLY if not Anthropic│
                 │  ④ forward to Foundry                        │
                 │  ⑤ parse usage per provider, then normalise  │
                 │  ⑥ cost = tokens × cached unit price         │
                 │     (null for Anthropic — CCU, no model rate)│
                 │  ⑦ emit per-TENANT metric ─── ZERO LAG ──────┼──▶ user dashboard
                 └───────────────┬──────────────────────────────┘
                                 │
                                ▼
                        Microsoft Foundry
                                │
       ┌─────────────────────────┼──────────────────────────┐
       ▼                         ▼                          ▼
  Retail Prices        ★ AZURE MONITOR ★            Cost Management
  (cache daily,         PREFERRED SOURCE             (hours, throttled)
   anonymous,           ~2 min, 1-min grain                 │
   NO Anthropic)        ALL publishers, one schema          │
       │                 NO tenant dimension                │
       │                         │                          ▼
       └──────────▶ unit price   │                   nightly: computed
                    table        ▼                   vs billed = drift
                                reconcile:          (Anthropic only
                                gateway vs Monitor   reconciles at the
                                = bypass detection   aggregate CCU meter)
```

**Read it as two independent loops.** Monitor is the system of record for *how many tokens*;
the gateway is the system of record for *whose tokens*. Neither replaces the other, and any
persistent gap between them is a bypass or a parsing defect.

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
| Cost Management query | **Cost Management Reader** | Subscription |
| Model catalog | **Reader** | Subscription |
| Retail Prices | *none* | — |

## Verified behaviour

| Scenario | Result |
|---|---|
| **Four publishers, one account** | OpenAI, Anthropic, xAI and DeepSeek all metered through one normalised schema |
| **Anthropic on the OpenAI path** | `api_not_supported` — correctly surfaced as a failed call, not as "no usage" |
| **Anthropic on `/anthropic/v1/messages`** | Usage present, streamed and non-streamed, output token counts identical (54 / 54) |
| **Anthropic without `anthropic-version`** | HTTP 400 — header confirmed mandatory |
| **Anthropic + `stream_options`** | HTTP 400 `"Extra inputs are not permitted"` — confirms it must not be injected |
| **Anthropic streamed usage, first vs last** | `message_start` 1 token vs `message_delta` 13 — last-match selection verified |
| **xAI reasoning tokens** | grok-4.3 output 327 captured (reasoning 326) where `completion_tokens` alone reports 1 |
| **xAI total reconciliation** | computed `in + cache + out` equals reported `total_tokens` with reasoning added |
| **OpenAI reasoning tokens** | o4-mini output 174 with reasoning 128 **not** double-counted; total matches exactly |
| **`max_completion_tokens` retry** | o4-mini, gpt-6-sol succeed after automatic retry; gpt-4.1-mini unaffected |
| **DeepSeek minimal usage block** | No `prompt_tokens_details`; cached coalesces to 0, totals correct |
| Non-streaming call | `usage` present, cost computed, TTFT 26–168 ms depending on model |
| Streaming without `include_usage` (OpenAI) | **No usage block** |
| Streaming with `include_usage` (OpenAI) | Usage present in final chunk; no `latency_checkpoint` |
| **Azure Monitor lag, per publisher** | xAI 115 s, Anthropic 116 s, OpenAI 119 s, DeepSeek 113 s — **uniform ≈ 2 min** |
| **Monitor cross-publisher query** | One query returned all four publishers with identical schema and dimensions |
| **Monitor reasoning-token quirk** | grok-4.3 from Monitor: in 34 / out 99 / total 998 — `total − in` = 964 recovers reasoning that `in + out` (133) loses |
| **`Total − In` is universally correct** | Equals `OutputTokens` exactly for claude-opus-5-5 (322,316) and gpt-4.1-mini (739); recovers 964 for grok-4.3 |
| **Empty-response transient** | 2 in 60 streamed calls returned a 2-byte body; Monitor confirmed **zero tokens**, so a failed request rather than a silent under-bill |
| Model catalog, one region | 136 distinct models |
| Retail Prices, one region | 1,585 token meters |
| Cost Management | Succeeded on the 5th attempt after 4× HTTP 429 |
| Reconciliation | Gateway 75 tokens vs Monitor 122 — delta correctly identified as out-of-band traffic |
| Price table build | 1,528 token meters classified from 1,585 raw rows (eastus2) |
| Scope awareness | `gpt-oss-120b` Global 0.15/0.60 vs Data Zone 0.165/0.66 — both resolved correctly |
| Scope spelling variants | `gpt-4.1` Global 2.00/8.00 vs Data Zone 2.20/8.80 — the two-word `Data Zone` form resolves correctly |
| Variant disambiguation | `gpt-5.4` → 2.50, `-pro` → 30, `-mini` → 0.75, `-nano` → 0.20 |
| Variant filter is unconditional | `gpt-5.3` → `NoMeter` rather than silently taking the `5.3 codex` rate |
| Version-token anchoring | `gpt-oss-20b` → `NoMeter` (not the `120B` rate); `gpt-4o` → `Ambiguous` (not the `gpt-4-turbo128K` rate) |
| Dated versions | `gpt-4o` `-ModelVersion 2024-05-13` → 5.00, `2024-08-06` → 2.50, `2024-11-20` → 2.50 |
| Cache read vs write | `gpt-5.6-sol` Long: read 1.60 vs **write 20.00** — separate kinds, no key collision |
| Service tiers | `PP` (Priority) resolved at exactly 2× Standard; `Flex` separated; `ProvisionedManaged` → `BilledAsCapacity` |
| Banded-only models | `gpt-6-astra` has no Standard tier; Short → 10/50, Long → 20/75, both resolved |
| Publisher resolution | ARM `publisher` empty 328/328; coalescing from `format` resolves all 136 models |
| Batch discount | `GlobalBatch` resolved to exactly 50% of `GlobalStandard` |
| Null safety | Anthropic → `BilledOutsideRetailAPI` / null; unknown model → `NoMeter` / null; `Measure-RequestCost` → null, not 0 |
| **CCU vs NoMeter** | Claude rows tagged `BillingModel = CCU` (null by design); genuine gaps stay `NoMeter` (alertable) |
| Coverage gap | `DeepSeek-V4.1-Flash` → `NoMeter`; sibling `V3.2` → Priced 0.58 |
| Cost arithmetic | 10k in / 4k cached / 2k out on gpt-oss-120b = $0.0027, matches hand calculation |
| Cost arithmetic, banded + cache write | `gpt-6-astra` Short, 10k in / 4k cached / 2k write / 1k out = $0.139, matches hand calculation |
| End-to-end | Live run priced `gpt-6-astra` at $293.51 (28.6M in @ $10 + 146k out @ $50) while correctly returning null for Claude |
| Cache hit | 62 ms vs a full paged fetch |
| Fresh clone | Clones and runs in a clean `pwsh -NoProfile` session with no manual setup |
| Regression suite | 18 meter-parsing cases plus live lookup checks across 6 model families, 3 scopes, 4 kinds and 5 service tiers — all pass |
| Independent review | Full source reviewed twice by a separate agent against live data; 15 defects found and fixed before publication |
| Full-catalog sweep | All 136 catalogued models priced in one pass: 56 `Priced`, 57 `NoMeter`, 14 `BilledOutsideRetailAPI`, 5 `Ambiguous`, 4 `UnknownPublisher` — and **zero** resolved to another model's meter |

## Source documentation

- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Azure Monitor — Metrics: List](https://learn.microsoft.com/en-us/rest/api/monitor/metrics/list)
- [Monitor model deployments in Microsoft Foundry Models](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/monitor-models)
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

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
- [Cost Management — Query: Usage](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage)
- [Monitor Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry-classic/openai/how-to/monitor-openai)
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

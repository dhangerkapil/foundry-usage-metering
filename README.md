# Foundry Usage Metering

Measure token usage and cost for Microsoft Foundry — in real time, across **every model
publisher**, from the right API.

Seven Azure surfaces expose model pricing, usage or cost. They are not interchangeable: they
differ by orders of magnitude in freshness and grain, they disagree with each other in ways
that are invisible unless you look, and only one of them reports every publisher the same way.
This repo shows which to use for what, with measured figures rather than documentation claims.

Written for teams building an **AI gateway** in front of Foundry who need to show their own
users what they are consuming and what it costs.

> **All figures here were measured on 2026-10-06 / 2026-10-07** against one Foundry (AIServices)
> account in `eastus2` running **29 deployments across five publishers** — OpenAI, Anthropic,
> xAI, DeepSeek and a model-router. Azure changes; re-measure before you rely on any number
> below. Where something is observed rather than documented by Microsoft, it says so.

## The short version

| Source | Auth | Measured lag | All publishers? | Use it for |
|---|---|---|---|---|
| **Azure Monitor metrics** | Entra | ~1 min | **Yes — one schema** | **Totals, reconciliation, bypass detection** |
| `usage` on the inference response | — (already in path) | Zero | Yes, but provider-shaped | **Per-tenant attribution — the only surface that can do it** |
| `AzureOpenAIRequestUsage` log | Entra | **p50 5 s** | No — OpenAI only | Per-request settlement, joined on `apim-request-id` |
| `RequestResponse` log | Entra | **p50 120 s** | Yes, with caveats | Per-request tokens for non-OpenAI publishers |
| ARM model catalog | Entra | Real time | Yes | Model inventory and lifecycle |
| Azure Retail Prices API | **None** | Real time (cache daily) | No — Anthropic absent | Unit **list** prices |
| Cost Management Query | Entra | Hours, throttled | Aggregate only for Anthropic | **The invoice.** Nightly reconciliation |

**Prefer Azure Monitor for token totals.** It is the only surface where `InputTokens` /
`OutputTokens` / `TotalTokens` carry the same names and dimensions for every publisher. One
query covers an account running all five at once.

**Use Cost Management for money.** Monitor is close to the bill, not equal to it: over 124
deployment-days of OpenAI-path traffic, billed quantities matched `InputTokens` and
`OutputTokens` exactly on **86**. Busy days landed within ~5%; quiet days were billed in part
or not at all.

**Monitor cannot replace inline metering.** Its dimensions are `ApiName`, `Region`,
`ModelDeploymentName`, `ModelName`, `ModelVersion` — there is **no tenant dimension**. Monitor
can tell you a deployment burned 40k tokens; it cannot tell you which of your tenants burned
them. Per-tenant attribution exists only in the request path.

So: **Monitor for totals, Cost Management for money, inline for attribution** — and the inline
path has to be provider-aware, which is most of what this repo is about.

---

## The three mistakes that cost the most

Each of these produces a confident, plausible, wrong number. None of them raises an error.

### 1. Do not bill `TotalTokens − InputTokens`

This is advice you will find in a lot of places, including earlier drafts of this README. It is
wrong, and on a reasoning workload it is wrong by an order of magnitude.

`grok-4.3` puts reasoning tokens **inside** `TotalTokens` and **outside** `OutputTokens`. That
looks like `OutputTokens` is under-reporting. It is not — **Azure does not bill those reasoning
tokens.** Measured on 2026-10-06, Azure Monitor against Cost Management for the same UTC day:

| Deployment | Monitor `In` | Monitor `Out` | Monitor `Total` | Residual | **Billed input** | **Billed output** |
|---|---|---|---|---|---|---|
| **grok-4.3** | 366 | 443 | 9,126 | **8,317** | 0.37 × 1K = **370** | 0.44 × 1K = **440** |
| o4-mini | 77 | 560 | 637 | 0 | 0.08 × 1K = **80** | 0.56 × 1K = **560** |

Meters: `4.3 Inp Glbl Tokens` / `4.3 Outp Glbl Tokens`, `o4-mini 0416 Inp glbl Tokens` /
`o4-mini 0416 Outp glbl Tokens`. Cost Management reports `UsageQuantity` in the meter's own
unit, here `1K`.

Azure billed **443 output tokens, not 8,760**. Billing `Total − In` would have charged **19×**
the real amount. On o4-mini, where reasoning is already inside `completion_tokens`, the residual
is zero and both rules agree.

> **Price `InputTokens` and `OutputTokens`. Never `TotalTokens − InputTokens`.**

`TotalTokens` is still useful as a *signal* — a large residual tells you a model is doing
hidden reasoning work, which matters for latency and quota even though it is not billed.

### 2. Cache tokens move in opposite directions by publisher

| | OpenAI path | Anthropic path |
|---|---|---|
| Inline `prompt`/`input` field | **includes** cache reads and writes | **excludes** both |
| Monitor `InputTokens` | **includes** them | **excludes** them |
| Monitor `cacheReadInputTokens` | `0` — not populated | populated |
| Billable input | `prompt_tokens − cached_tokens` | `input_tokens`, **no subtraction** |

The scale of the Anthropic omission, measured on 2026-10-06:

| Deployment | `InputTokens` | `cacheReadInputTokens` | `ephemeral5mInputTokens` | `ephemeral1hInputTokens` |
|---|---|---|---|---|
| claude-opus-5-5 | 556,470 | **293,446,436** | 19,758,480 | 0 |
| claude-opus-5 | 173,497 | **1,553,073** | 320,898 | 0 |
| claude-haiku-4-5 | 373 | 23,244 | 11,684 | **11,560** |
| claude-sonnet-5 | 165,287 | 0 | 0 | 0 |

For `claude-opus-5-5` the cache traffic is **527× the reported input**, and it sits entirely
outside `InputTokens` **and** outside `TotalTokens`. An invoice built from input + output alone
misses almost the entire bill. You need four metrics, not two: `InputTokens`,
`cacheReadInputTokens`, and `ephemeral5mInputTokens` + `ephemeral1hInputTokens` (cache writes,
split by TTL — writes price at a **premium**, not a discount).

On the OpenAI path the error runs the other way: cache is folded into `InputTokens` and the
cache metric stays `0`, so billing all of it at the full input rate overcharges the cached
portion. Only the inline `prompt_tokens_details.cached_tokens` or the `AzureOpenAIRequestUsage`
log can separate it.

### 3. `Get-TokenPrice` must never return `0` for an unknown model

Treating "no meter" as "free" bills nothing for real usage. Every lookup returns a `Status` and
a **null** price:

| Status | Meaning | What to do |
|---|---|---|
| `Priced` | Usable rate found | Use it |
| `NoMeter` | No usable match — a real gap, or a name that cannot be mapped to an abbreviated meter without guessing | **Alert.** The note names near-miss meters so you can pin an override |
| `BilledOutsideRetailAPI` | Publisher bills via Marketplace (Anthropic) | Correct, not a gap. Source cost from Cost Management |
| `UnknownPublisher` | Not in the family map | No verdict claimed. Add the mapping |
| `Ambiguous` | Several meters, different prices | Narrow by `-ModelVersion`, `-ContextTier` or `-Modality` |
| `BilledAsCapacity` | SKU is provisioned throughput (PTU) | Billed per PTU-hour, not per token |

`BilledOutsideRetailAPI` and `NoMeter` must never be conflated — one is by design, the other is
an alert.

---

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
| Input includes cache | **yes** → subtract | **no** → don't subtract | yes → subtract | n/a |
| Cache-write counter | `cache_write_tokens` | `cache_creation_input_tokens` | — | — |
| Reasoning in `completion_tokens` | **yes** | n/a | **no** | n/a |
| Streaming usage | needs `include_usage` | automatic; **rejects** `stream_options` | **always sent** | **always sent** |
| `latency_checkpoint` | yes | no | no | no |
| `service_tier` on the response | yes | `standard` | **omitted when non-streamed** | yes |

`Get-ProviderProfile` encodes this table; `ConvertTo-NormalizedUsage` collapses all of it into
one schema.

### Anthropic is a different API, not a dialect

```
POST /openai/v1/chat/completions   with claude-haiku-4-5
  -> {"error":{"code":"api_not_supported","message":"Requested API is currently not supported"}}

POST /anthropic/v1/messages        without anthropic-version
  -> 400 "anthropic-version: header is required"
```

A gateway routing Claude to the OpenAI path doesn't under-report — it fails the request
outright.

**On the host name:** all three of `<account>.services.ai.azure.com`,
`<account>.openai.azure.com` and `<account>.cognitiveservices.azure.com` route **both**
`/openai/v1/chat/completions` and `/anthropic/v1/messages` (tested 2026-10-07). An earlier
version of this document claimed `.openai.azure.com` does not route `/anthropic`; that is not
true on this account. Use `.services.ai.azure.com` as the canonical host anyway — it is the one
Microsoft documents for the unified surface.

### xAI excludes reasoning tokens from `completion_tokens`

Measured on the same prompt:

| Model | `prompt` | `completion` | `reasoning` | `total` | `prompt + completion` |
|---|---|---|---|---|---|
| **grok-4.3** | 13 | 81 | 451 | **545** | 94 |
| o4-mini | 15 | 174 | 128 | 189 | 189 |

On xAI, `reasoning_tokens` are **excluded** from `completion_tokens` and **included** in
`total_tokens`. On OpenAI the same tokens are already inside `completion_tokens`, so adding
them would double-count. The two cannot share a code path:

```powershell
# xAI   - reasoning is a sibling of completion
$out = $completion_tokens + $reasoning_tokens
# OpenAI - reasoning is already inside completion
$out = $completion_tokens
```

**But see mistake #1 above before you price that number.** On the one day measured, Azure
billed grok-4.3's `OutputTokens` (which excludes reasoning), not the reasoning-inclusive total.
Normalise reasoning into your *reported* output so dashboards are honest about the work done,
and reconcile the *billed* figure against Cost Management rather than assuming either rule.

### Streaming differs three ways

| Request | `usage` returned? |
|---|---|
| OpenAI `"stream": true` alone | **No** |
| OpenAI + `stream_options.include_usage` | **Yes** (final chunk) |
| xAI / DeepSeek `"stream": true` alone | **Yes** — sent regardless |
| Anthropic `"stream": true` alone | **Yes** (always) |
| Anthropic + `stream_options` | **HTTP 400** — `"Extra inputs are not permitted"` |

So the common advice "always inject `include_usage`" **breaks every streamed Claude request**.
Inject it per provider.

Anthropic also emits `usage` **twice**:

```
event: message_start   usage: { input_tokens: 12, output_tokens: 1 }   <- PARTIAL
event: message_delta   usage: { input_tokens: 12, output_tokens: 4 }   <- FINAL
```

A `[regex]::Match` that takes the **first** hit records 1 output token instead of 4. Take the
**last** usage object on any stream.

**`latency_checkpoint` moves.** On a non-streamed OpenAI response it sits *inside* the `usage`
object; on a streamed one it is *top-level* in a chunk. A parser that only looks inside `usage`
loses it on exactly the calls where TTFT matters most.

### Every current OpenAI reasoning flagship rejects `max_tokens`

Tested against all 14 OpenAI-path deployments on the account (2026-10-07):

| Parameter | Result |
|---|---|
| **`max_completion_tokens`** | Accepted by **all 14** |
| `max_tokens` | **Rejected by 8**: o4-mini, gpt-5-mini, gpt-5.1, gpt-5.4, gpt-5.4-mini, gpt-5.6-sol, gpt-6-sol, gpt-6-astra |
| `max_tokens` (Anthropic path) | **Required** — `max_completion_tokens` is not accepted |

Sending the wrong one is HTTP 400, not a warning. Model-name lists rot, so
`Invoke-MeteredCompletion` detects the error and retries once with the other spelling.

### Service tier: only the response is authoritative

`ServiceTierRequest` and `ServiceTierResponse` are both dimensions on `ModelRequests`, and
comparing them is the only way to catch a **silent downgrade** — a request for an unsupported
tier can succeed at the standard rate without any error. Note that `grok-4.3` **omits**
`service_tier` from a non-streamed response entirely, so absence is not the same as `standard`.

---

## Anthropic bills through Azure Marketplace

Claude is **not billed on the Foundry account at all.** Its charges land on Marketplace SaaS
resources (`MeterCategory` = `SaaS`), so a Cost Management query scoped to the account shows
**zero** Claude spend. This is the single most surprising thing in the whole system.

- New deployments bill in **Claude Consumption Units (CCU)** — the meter names the plan and the
  hosting (`Azure hosted` / `Anthropic hosted`), **never the model**.
- Deployments created before CCU billing went GA keep a per-model token plan, with meters like
  `Claude Sonnet 4.6 - msft-sonnet-4-6-flat-100 - paygo-inference-input-tokens`. On
  `claude-sonnet-4-6` that plan reconciled to **within 0.2%** of Azure Monitor.
- The rows carry **no deployment tag**, so they cannot be joined to `ModelDeploymentName`.
- Every Claude SaaS resource observed was named
  `<Claude name, cut to 15 chars>-<first 15 chars of the account internalId>-<32 hex digits>`.
  The middle segment ties a resource to its account. **The Claude name does not identify the
  deployment** — `claude-opus-5`'s usage was billed on a resource named `claude-opus-5-5-…`.
- These SaaS resources are **absent from ARM and from Resource Graph**. You can only see them
  through Cost Management.

Three consequences for a metering system:

1. **Anthropic has no Retail Prices meter.** Its absence is correct, not a coverage gap.
2. **Derived cost (`billed ÷ tokens`) is impossible for Claude.** Not hard — impossible. The
   billed figure has no model grain.
3. **Token counts are still exact.** Monitor and the inline `usage` block both report Claude
   tokens precisely. Only the per-model *dollar* figure is unavailable.

`Get-TokenPrice` returns `BilledOutsideRetailAPI` for Anthropic, and `Get-NearRealTimeCost`
tags those rows `BillingModel = CCU`.

CCU rates: <https://aka.ms/ccu-pricing> (resolves to
`platform.claude.com/docs/en/about-claude/pricing`, verified 2026-10-07).

---

## Azure Monitor

### Measured freshness

Azure Monitor publishes a token value **48–60 s** after the request. Minimum grain is `PT1M`
and counts are exact, not sampled.

Log Analytics is a different story, and the two diagnostic categories differ by **25×**.
Measured as `ingestion_time() − TimeGenerated` over 7 days ending 2026-10-07:

| Category | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| `AzureOpenAIRequestUsage` | 20,393 | **5 s** | 8 s | 27 s | 174 s |
| `Audit` | 1,560 | 81 s | 113 s | 130 s | 169 s |
| `RequestResponse` | 129,201 | **120 s** | 167 s | 220 s | **13,522 s** |

`AzureOpenAIRequestUsage` is the freshest per-request surface on the platform — faster than
Azure Monitor. `RequestResponse` has a long tail: one row arrived **3h 45m** late. Any
settlement job reading it needs a re-scan window, not a single pass.

Other delays, for contrast:

| Surface | Delay |
|---|---|
| Azure Monitor metrics | ~1 min (measured) |
| Cost Management | **> 5 hours** observed from billing event |
| CCU metering | hourly meter, monthly invoice in arrears |

### ⚠️ Your clock is not Azure's clock

The local machine ran **21.5–22.1 s behind** Azure's `Date` header across three samples against
`management.azure.com` (2026-10-07). A metering job that builds a `timespan` from local
`UtcNow` and queries "the last 60 seconds" will routinely query a window Azure considers to be
in the future and get an empty result. **Always lag your query window by at least a minute**,
or take the time from a server response header.

### ⚠️ Monitor is missing Claude's Responses-API tokens

**Observed, not documented. Verify on your own account.**

On 2026-10-06, `RequestResponse` rows for Claude carried a `modelVersion` of either `1` or `2`
(neither is a real model version). Rows with `modelVersion = 2` are requests served through the
**Responses API** (`OperationName = create_response`); rows with `1` came through the Anthropic
Messages path. They are **distinct requests**, not duplicates — every `CorrelationId` appears
exactly once.

Azure Monitor's `InputTokens` equals the version-`1` sum **exactly**, and omits the version-`2`
traffic entirely:

| Deployment | Monitor `InputTokens` | RR `modelVersion = 1` | RR `modelVersion = 2` | Monitor `ModelRequests` | RR rows, both versions |
|---|---|---|---|---|---|
| claude-opus-5 | 173,497 | **173,497** ✔ | 161,001 (not counted) | 76 | 57 + 19 = **76** ✔ |
| claude-sonnet-5 | 165,287 | **165,287** ✔ | 69,367 (not counted) | 32 | 18 + 14 = **32** ✔ |

So `ModelRequests` counts the Responses-API calls but `InputTokens` / `OutputTokens` do not.
For `claude-opus-5` that is **48% of the day's input tokens invisible to the metric** you were
told was the source of truth. The same is *not* true on the OpenAI path: `gpt-5.4` served 32 of
its 40 requests through `create_response` and Monitor's `InputTokens` is the **largest** of the
three surfaces, so it is clearly counting them.

If you serve Claude through the Responses API, cross-check Monitor against `RequestResponse`.

### What Monitor cannot do

- **No tenant dimension.** Hence inline metering. The diagnostic logs carry the caller's object
  ID, which behind a gateway is the gateway's own identity.
- **A metrics request covers at most 31 days.** A longer `timespan` is **silently shortened** to
  its last 31 days and still returns HTTP 200. Query long periods in pieces.
- **`$filter` has no prefix wildcards**, and `top` defaults to **10** — on an account with 29
  deployments the default silently truncates. `PT1M` over 7 days returns HTTP 400.
- **`FoundryModelEstimatedCost` is not a billing source.** Over one reconciliation window it
  reported **$147.62** against **$4,072.34** actually billed — 3.6% of the real figure. Treat it
  as a portal convenience.
- **No `ProvisionedConsumedTokens`** on a non-PTU account. The cache hit-rate metric is called
  **`AzureOpenAIContextTokensCacheMatchRate`** (Percent / Average), not `TokensCacheMatchRate`.

### Useful metrics beyond the obvious three

The account exposes **94 metric definitions**. The ones that matter for metering:

| Metric | Dimensions | Note |
|---|---|---|
| `InputTokens`, `OutputTokens`, `TotalTokens` | `ApiName, Region, ModelDeploymentName, ModelName, ModelVersion` | The core three |
| `ModelRequests` | + `OperationName, StreamType, StatusCode, IsSpillover, ServiceTierRequest, ServiceTierResponse` | **Includes failures** — 400/404/408/429/499 all counted |
| `ProcessedPromptTokens`, `GeneratedTokens` | `ApiName, ModelDeploymentName, FeatureName, UsageChannel, Region, ModelVersion, ServiceTier*` | **No `ModelName` dimension** — cannot be joined by model |
| `cacheReadInputTokens`, `ephemeral5mInputTokens`, `ephemeral1hInputTokens` | + **`ContextLength`** | The Anthropic cache metrics |
| `ModelRouterRequests`, `ModelRouterSuccessfulRequests` | `ModelDeploymentName, ModelName, Region, **RouterMode**` | Per-served-model router attribution |
| `FoundryModelEstimatedCost` | `ProjectId, ModelDeploymentName, ModelName, ModelVersion, Region` | See the warning above |

**`ModelRequests` counts failures.** `claude-opus-5` logged over 3,000 HTTP 429s in 30 days; a
dashboard dividing cost by `ModelRequests` will understate cost-per-request badly. Filter on
`StatusCode`.

### Version dimensions are not trustworthy on their own

- On `model-router`, the token metrics carry the **router's** version (`2025-11-18`) while
  `ModelRequests` carries the **served model's** version.
- `__Empty` appears as a `ModelVersion` value.
- Claude failures are recorded at version `1`, Responses-API Claude traffic at version `2`.

---

## Per-request records

Monitor aggregates to a 1-minute bucket. If you need to settle **one request** — join a token
count to a request ID and explain a line on an invoice — aggregates cannot do it.

There are two diagnostic log categories, and the commonly-cited one is the narrower of the two.

| | `AzureOpenAIRequestUsage` | `RequestResponse` |
|---|---|---|
| Publishers | **OpenAI only** | **All of them** |
| Token fields | `promptTokens`, `cachedTokens`, `generatedTokens` | `promptTokens`, `completionTokens` |
| Cache fields | **yes** | **no** |
| Timing | `timeToFirstTokenMs`, `timeToLastTokenMs` | `DurationMs` |
| Ingestion lag | p50 **5 s** | p50 **120 s** |
| Rows per request | 1 | **2** — see below |
| Join key | `CorrelationId` = `apim-request-id` | same |

### ⚠️ The token fields are JSON **arrays**, not numbers

This one silently returns zero from every KQL query you would naturally write.

```json
{
  "modelDeploymentName": "gpt-6-astra",
  "modelName":           "gpt-6-astra",
  "modelVersion":        "2026-09-03",
  "streamType":          "Streaming",
  "promptTokens":        [138652],
  "cachedTokens":        [134605],
  "generatedTokens":     [622],
  "timeToFirstTokenMs":  3801.132,
  "timeToLastTokenMs":   18085.207
}
```

`promptTokens` is `[138652]`, not `138652`. Checked across **20,399 rows**: `gettype()` returns
`array` on every one, and the array length is always `1`. The timing fields are plain `double`.
In `RequestResponse` the same concepts are scalars (`long`).

```kusto
// Returns an empty sum. tolong() on an array yields null, and so do
// tolong(p['promptTokens']), toreal(...) and tolong(tostring(...)).
| summarize sum(tolong(p.promptTokens))

// Correct.
| summarize sum(tolong(p.promptTokens[0]))
```

`promptTokens` **includes** `cachedTokens`, matching the inline OpenAI block, so billable input
is `promptTokens[0] − cachedTokens[0]`. There is **no reasoning-token field** in either log.

### ⚠️ `RequestResponse` emits two rows per request

Grouping `create_response` rows by `CorrelationId`:

| Rows per CorrelationId | With tokens | Correlation IDs |
|---|---|---|
| 2 | 1 | **5,183** |
| 2 | 0 | 1,267 |
| 1 | 1 | 68 |
| 3 | 1 | 6 |

The dominant shape is **two rows per request, exactly one of which carries tokens**. Counting
rows double-counts requests. Deduplicate on `CorrelationId` and keep the token-bearing row.
Across 7 days, 43,525 correlation IDs had exactly one token-bearing row and only 21 had two, so
the token row itself is reliable.

### ⚠️ Two thirds of `RequestResponse` is not inference

Over 7 days on this account, by `apiName`:

| `apiName` | Rows | Rows with tokens | Deployments |
|---|---|---|---|
| `AIServices` | 47,268 | 19,624 | 16 |
| *(blank)* | 28,049 | 23,946 | 13 |
| `Anthropic API` | 27,120 | **0** | 1 |
| `OpenAI Language Model Instance API` | 14,794 | **0** | 1 |
| `Azure AI Projects API` | 10,501 | **0** | 1 |
| `Azure OpenAI API version 2024-12-01-preview` | 283 | 0 | 1 |
| `Voice Live Capabilities API 2026-04-01` | 33 | 0 | 1 |

Only about **34%** of rows carry tokens at all. `Models_List`, `Projects_Wildcard_Get`,
`Evaluators_ListLatestVersions`, dataset uploads and Voice Live capability probes are all in
there. Note too that the token-bearing Claude rows have a **blank** `apiName` — the rows labelled
`Anthropic API` carry none.

### ⚠️ Neither log is a complete ledger

Even the token-bearing rows do not cover every request. Same account, 2026-10-06:

| Deployment | `ModelRequests` | RR token rows | Usage-log rows |
|---|---|---|---|
| gpt-5.4-mini | 24 | **8** | 8 |
| gpt-5.1 | 23 | **13** | 13 |
| o4-mini | 11 | **5** | 5 |
| gpt-5-mini | 15 | **11** | 11 |
| gpt-6-astra | 6,467 | 5,202 | 5,201 |

Use the logs for per-request *settlement* of the requests they cover; use Monitor for *totals*.

### Three-way reconciliation

Azure Monitor vs `RequestResponse` vs `AzureOpenAIRequestUsage`, same UTC day (2026-10-06),
input tokens:

| Deployment | Monitor | `RequestResponse` | Usage log | RR vs Monitor |
|---|---|---|---|---|
| gpt-4.1 | 126 | 126 | 126 | **0%** |
| gpt-4.1-mini | 19,568 | 19,568 | 19,568 | **0%** |
| gpt-5-mini | 12,588 | 12,588 | 12,588 | **0%** |
| gpt-5.4-mini | 303,286 | 303,286 | 303,286 | **0%** |
| gpt-6-astra | 782,889,646 | 782,569,082 | 782,504,266 | −0.04% |
| **gpt-5.4** | **407,570** | **371,852** | **361,709** | **−8.76%** |
| claude-opus-5 | 173,497 | 334,498 | *(n/a)* | **+92.8%** |
| claude-sonnet-5 | 165,287 | 234,654 | *(n/a)* | **+42.0%** |
| claude-opus-5-5 | 556,470 | 548,670 | *(n/a)* | −1.4% |

**Eleven of fourteen OpenAI deployments agree to the token.** The Claude divergences are the
Responses-API gap described earlier. `gpt-5.4` is unexplained — all three surfaces disagree, and
Monitor reports the largest figure; a request straddling the UTC day boundary is the most likely
cause, since the three surfaces timestamp differently. Prefer Monitor, and reconcile over
windows with idle edges.

### The join key is `apim-request-id`

> **Observed, not documented.** Microsoft publishes no schema for `AzureOpenAIRequestUsage` and
> no statement that `CorrelationId` equals any response header. Re-verify it rather than
> building an unmonitored billing pipeline on it.

`CorrelationId` on the log row equals the **`apim-request-id`** response header. That is the
field to persist in your gateway.

Three headers that look like they should work, and do not:

- **`x-request-id`** — returned on every OpenAI-path response, appears **nowhere** in any log.
- **`x-ms-client-request-id`** — caller-supplied, accepted and echoed back verbatim, but **not
  persisted**. You cannot stamp your own tenant ID on a call and read it back out.
- **`Request-Id`** (Anthropic path) — not persisted either.

Attribution has to be held gateway-side, keyed on `apim-request-id`.

### model-router files its rows under the served model

Per routed request, `RequestResponse` writes a token-bearing row naming the **served** model
(e.g. `gpt-5.6-luna`), a zero row for that model, and a zero row for `model-router` itself. The
`AzureOpenAIRequestUsage` row is likewise filed under the **served** model. Requests arriving on
the Responses API (`create_response`) are the exception — those carry tokens under
`model-router`.

`ModelRouterRequests` gives you the clean version of this (2026-10-01 → 2026-10-07):

```
model-router -> gpt-5.6-luna   balanced   8
model-router -> gpt-5-nano     balanced   1
model-router -> gpt-5.6-sol    balanced   1
```

Billing-wise, model-router charges a **router fee plus the served model's meters**, all tagged
with the router's deployment name. The fee meters live under `serviceName = 'Foundry Tools'`:

```
Model Routers GL 1M Tokens   $0.14 / 1M    (Global)
Model Routers DZ 1M Tokens   $0.15 / 1M    (Data Zone)
```

### Enable the logs first — they are off by default

```powershell
az monitor diagnostic-settings create `
  --name foundry-usage `
  --resource "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>" `
  --workspace "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws>" `
  --logs '[{"category":"AzureOpenAIRequestUsage","enabled":true},{"category":"RequestResponse","enabled":true}]'
```

Available categories on `Microsoft.CognitiveServices/accounts`:

| Category | Contents |
|---|---|
| `AzureOpenAIRequestUsage` | Per-request token counts, OpenAI only, with cache split |
| `RequestResponse` | Per-request access log, all publishers, tokens but no cache split |
| `Audit` | Control-plane access |
| `Trace` | Agent/tool execution traces |
| `ManagedNetworkEvent` | Managed VNet events |
| `AllMetrics` | Metric export — *not* needed for Monitor queries, which read the metrics API |

**Check whether a setting already exists.** All four Cognitive Services accounts in the test
subscription were configured by **Azure Policy**, not by hand — an enterprise tenant may
already be emitting these without the platform team knowing. Both settings on each account used
`categoryGroup: allLogs` with an empty `logAnalyticsDestinationType`, which means **Azure
diagnostics mode**: everything lands in the `AzureDiagnostics` table, not in resource-specific
tables. Your KQL has to match. (That governance pattern is specific to this tenant; yours may
differ.)

Also: the subscription-wide Cognitive Services account list returns an **empty first page with a
`nextLink`**. Code that stops at the first page sees zero accounts. Always follow `nextLink`.

And Log Analytics ingestion is **billed by volume** — `allLogs` on a busy account is expensive.
Scope the setting to the categories you query.

---

## Building the cached price table

Inline metering needs a unit price. A naive price table is worse than none.

```powershell
. .\Build-FoundryPriceTable.ps1

# Build once (daily is plenty). Cached to disk.
$prices = Build-FoundryPriceTable -Region eastus2 -CachePath .\prices.json

# Look up a rate
Get-TokenPrice -Table $prices -ModelName 'gpt-oss-120b' `
        -Publisher 'OpenAI-OSS' -Sku GlobalStandard -Kind Input
#   Status = Priced, PricePer1M = 0.15, MeterName = 'gpt-oss-120B Inp glbl Tokens'

# Cost a request
Measure-RequestCost -Table $prices -ModelName 'gpt-oss-120b' -Publisher 'OpenAI-OSS' `
    -Sku GlobalStandard -InputTokens 10000 -CachedTokens 4000 -OutputTokens 2000
#   CostUSD = 0.0027  BUT CachedRateIsFallback = True

# Models priced only in context bands need the band
Measure-RequestCost -Table $prices -ModelName 'gpt-6-astra' -Publisher 'OpenAI' `
    -Sku GlobalStandard -ContextTier Short `
    -InputTokens 10000 -CachedTokens 4000 -CacheWriteTokens 2000 -OutputTokens 1000
#   CostUSD = 0.119
#   (4000 uncached x $10 + 4000 cached x $1 + 2000 write x $12.50 + 1000 out x $50) / 1M

# Models shipping several dated versions need the version
Get-TokenPrice -Table $prices -ModelName 'gpt-4o' -Publisher 'OpenAI' `
    -Sku GlobalStandard -Kind Input -ModelVersion '2024-11-20'
#   Status = Priced, PricePer1M = 2.50   (2024-05-13 is 5.00; omitting the
#                                         version returns Ambiguous, not a guess)
```

**Watch `CachedRateIsFallback`.** `gpt-oss-120b` has no Global cached-input meter, so the cached
rate falls back to the full input rate and the cost is an **upper bound**, not an exact figure.
The flag is on every `Measure-RequestCost` result for exactly this reason.

### Resolving the publisher

`-Publisher` expects values like `OpenAI`, `OpenAI-OSS`, `DeepSeek`, `Mistral AI`,
`MoonshotAI` (no space). Those come from the ARM model catalog — but **not** from the field you
would expect:

```
model.format     ->  present on all 338 entries   'OpenAI', 'OpenAI-OSS', 'Anthropic', ...
model.publisher  ->  present on only 182 of 338
```

Measured in `eastus2` on 2026-10-07: `publisher` is populated on **every** entry whose `format`
is something other than `OpenAI` — Anthropic, Cohere, DeepSeek, Meta, Microsoft, Mistral AI,
MoonshotAI, xAI, Alibaba, Black Forest Labs, OpenAI-OSS — and on **none** of the 156
`OpenAI`-format entries. 338 − 156 = 182, which is exactly the count above.

So reading `publisher` works fine until you hit an OpenAI model, at which point it returns a
silent null and the lookup fails as `UnknownPublisher`. `Get-FoundryModelCatalog` reads
`format` outright. (For `gpt-oss`, `publisher` says `OpenAI` where `format` says `OpenAI-OSS` —
a second reason to prefer `format`, since the meters are under the OSS family.)

### One model has many prices

`gpt-oss-120B` in **one region** has seven meters (all with `unitOfMeasure = 1K`):

```
gpt-oss-120B Inp glbl Tokens          0.15  /1M    Global Standard, input
gpt-oss-120B Outp glbl Tokens         0.60  /1M    Global Standard, output
gpt-oss-120B Inp DZone Tokens         0.165 /1M    Data Zone, input   (+10%)
gpt-oss-120B Outp DZone Tokens        0.66  /1M    Data Zone, output  (+10%)
FW GPT OSS 120B Inp DZ Tokens         0.165 /1M    Fireworks-hosted
FW GPT OSS 120B Outp DZ Tokens        0.66  /1M
FW GPT OSS 120B Cache Inp DZ Tokens   0.082 /1M    cached input (Fireworks only)
```

Pick Data Zone when the deployment is actually Global and **every cost figure is 10% high** —
not obviously broken, just steadily wrong. The key must be **model + scope + token kind +
context tier + deployment type + host + purpose**, and the gateway must pass the deployment's
actual SKU.

Three further splits are easy to miss, and each is a large error:

| Split | Example (`eastus2` list, 2026-10-07) | Delta |
|---|---|---|
| Cache **read** vs cache **write** | `gpt-5.6-sol` Long Standard Global: `Cd Inp` **0.80** vs `Cd Wr` **10.00** | **12.5×** |
| Service tier | `gpt-5.6-sol` Short input Global: Flex **2.00** / Std **4.00** / PP **8.00** | **4×** end to end |
| Context band | `gpt-6-astra` Global: input Short **10.00** vs Long **20.00**; output Short **50.00** vs Long **75.00** | 2× / 1.5× |

`PP` is **Priority Processing**, not Provisioned — PTU is capacity billed per hour and never
appears as a per-token meter. `-Sku ProvisionedManaged` returns `BilledAsCapacity`.

### Variant disambiguation is not optional

`gpt-5.4` appears as a substring in the meters for `5.4 pro`, `5.4 mini` and `5.4 nano`:

| Model | Resolved meter | USD / 1M in |
|---|---|---|
| `gpt-5.4` | `5.4 inp Gl 1M Tokens` | **2.50** |
| `gpt-5.4-pro` | `5.4 pro inp Gl 1M Tokens` | **30.00** |
| `gpt-5.4-mini` | `5.4 mini Inp Gl 1M Tokens` | 0.75 |
| `gpt-5.4-nano` | `5.4 nano Inp Gl 1M Tokens` | 0.20 |

A substring match would bill `gpt-5.4` at the `pro` rate — **12× over**.

Two subtleties that cost real money, both found by review rather than testing:

- **The filter must be unconditional.** An earlier version skipped it when it matched nothing,
  letting a base model fall back onto a variant's meter — `gpt-5.3` was priced from `5.3 codex`.
  An empty result means `NoMeter`, not permission to keep the unfiltered set.
- **The version token must be anchored.** `20` is a substring of `120`, and `4` is a token of
  `gpt-4-turbo128K`. Unanchored, `gpt-oss-20b` priced from the `120B` meter and `gpt-4o` from
  `gpt-4-turbo128K` — 4× and 3.2× over, both reported as a confident `Priced`.

### Measured price relationships

Pairing meters that differ in exactly one attribute, across all **1,543** classified meters in
`eastus2` (2026-10-07):

| Relationship | Clean pairs | Exact ratio | Exceptions |
|---|---|---|---|
| Data Zone / Global | 536 | **×1.10** on 502 | Kimi K2.7 Code output ×1.25; ~30 at ×1.07–×1.12 from rounding |
| Batch / Standard | 121 | **×0.50** on 118 | gpt-5.4 cached input 0.275 → 0.143 (×0.52, rounding) |
| Priority / Standard | 88 | **×2.00** on 82 | gpt-5.5 ×2.50; gpt-4.1 ×1.75; gpt-5-mini ×1.80 |
| Long / Short, **input** | 28 | **×2.00** on 28 | none |
| Long / Short, **output** | 27 | **×1.50** on 27 | Grok 4.3 has no Short band; its Long is ×2.00 of Standard |
| Cache write / input | 46 | **×1.25** on 46 | none |
| Cached input / input | 308 | **no single ratio** | ×0.10 on 168 pairs, ×0.25 on 53, ×0.50 on 27 (fine-tuned), down to ×0.0125 |

Flex produced **zero** clean pairs, because every Flex meter uses the abbreviated spelling
(`56sol ShCo Inp Fl Gl`) while its Standard twin uses the spaced one
(`5.6 sol ShortCo Inp Std Gl`) — no mechanical pairing can see them as the same model. Checked
by hand on all eight `gpt-5.6-sol` pairs, Flex is **×0.50** of Standard.

**These are observations, not contracts.** The table always reads actual meters. Two meter
families are internally inconsistent and must not be used to infer anything: the unnamed
placeholder products `Model 6` and `Model 7` publish **transposed** Global and Data Zone rates —
`Model 7 Inp glbl` is 3.30 against `Model 7 Inp DZ` at 0.30, and the output meters are 0.33
against 16.50.

### Coverage: refusing to answer is a feature

Run against the full `eastus2` catalog on 2026-10-07 — **141 models**:

```
Priced                  86
NoMeter                 37      <- refuses rather than guesses
BilledOutsideRetailAPI  14      <- Anthropic, correctly out of scope
UnknownPublisher         4      <- Black Forest Labs (FLUX) - image models, not token-billed
Ambiguous                0
```

`UnknownPublisher` is **only** Black Forest Labs. The family map covers OpenAI, OpenAI-OSS,
Anthropic, xAI, DeepSeek, Mistral AI, Microsoft, Meta, Cohere, Alibaba and MoonshotAI. Not
covered: Black Forest Labs, AI21 Labs, Core42, NTT DATA, Nixtla, Stability AI.

A looser matcher reaches a far higher "coverage" number — earlier drafts did, and every point of
that extra coverage was wrong. Several of those historical loose matches now resolve correctly
with the strict matcher; the point is the failure mode, not the specific models:

| Model | Loose match resolved to | Error | Strict matcher today |
|---|---|---|---|
| `gpt-4o` | `gpt-4-turbo128K` | 3.2× over | `Ambiguous` — needs `-ModelVersion` |
| `gpt-oss-20b` | `gpt-oss-120B` | 4× over | `NoMeter` (only fine-tuning meters exist) |
| `DeepSeek-R1` | `V3.1` | 9% under | `Priced` 1.35 from `R1 Inp glbl Tokens` |
| `mistral-medium-3-5` | `Mistral Large 3` | wrong product | `Priced` 1.50 from `MM3.5 Inp glbl Tokens` |
| `Phi-4-multimodal` | `Phi-4` | wrong product | `Ambiguous` — several modalities, different prices |
| `whisper`, `model-router` | `5.5 ShortCo` | unrelated model | `NoMeter` |

All of those returned `Status = Priced` with no warning. **A billing system that is wrong 20% of
the time and never says so is worse than one that answers 60% of the time and flags the rest.**

Verified live (2026-10-07):

```
claude-opus-4-6      -> BilledOutsideRetailAPI   price = <null>
DeepSeek-V4.1-Flash  -> NoMeter                  price = <null>    (real GA model)
DeepSeek-V3.2        -> Priced                   price = 0.58
gpt-4o               -> Ambiguous                price = <null>    (3 meters, 2 prices)
Measure-RequestCost on an unpriced model -> CostUSD = <null>, not 0
```

**Six of the 29 live deployments on the test account return `NoMeter` at the default context
tier** — `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-6-astra`, `gpt-6-sol` and
`model-router`. The first five are priced **only** in Short/Long bands, so `-ContextTier` is
mandatory for them. This is the most likely thing to surprise you on a modern account.

### Input validation

| Input | Result |
|---|---|
| Negative token count | `InvalidInput` |
| `CachedTokens` > `InputTokens` | `InvalidInput` |
| `CachedTokens + CacheWriteTokens` > `InputTokens` | `InvalidInput` |
| All token counts zero | `CostUSD = 0`, `Status = Priced` |

### List prices, not your prices

The Retail Prices API is anonymous — no auth, no subscription context — so it returns **list
prices**. EA, MACC and negotiated discounts are not reflected.

The table carries `IsListPrice = $true` and a `PriceBasis` string, and every `Get-TokenPrice`
result repeats the flag, so downstream code cannot quietly forget:

```
PriceBasis = Azure Retail Prices API (anonymous). LIST prices only - no EA,
             MACC or negotiated discount is reflected. Reconcile against Cost
             Management before using for external billing.
```

### Cache behaviour

`-CachePath` persists to JSON and serves from it while fresh (`-MaxAgeHours`, default 24).
Measured on 2026-10-07:

| Operation | Time |
|---|---|
| Cold build (full paged fetch, 1,585 rows → 1,543 classified meters) | **5.4–5.7 s** |
| Warm cache read | **92–108 ms** |
| `-Force` rebuild | 5.4 s |

If the API fails mid-fetch the builder **throws rather than returning a partial table**, and a
cache file whose entry count disagrees with its own `MeterCount` is rejected and refetched:

```
WARNING: Price cache is incomplete (MeterCount 1543 vs 10 entries) - rebuilding
         rather than serving a partial table.
```

A half-built cache looks exactly like genuine missing coverage and would under-bill silently.

---

## Quick start

```powershell
az login

# All tiers against your own Foundry account.
# Exercises ONE chat deployment per publisher automatically.
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account

# Narrow the window and include the throttled cost query
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account `
    -LookbackMins 60 -IncludeCost

# Exercise router pricing (model-router is excluded from the default pick)
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account -Deployment model-router

# Read-only: no tokens spent, for an identity without data-plane access
.\Get-FoundryUsageTelemetry.ps1 -AccountName my-foundry-account -SkipInference
```

`-ResourceGroup` and `-SubscriptionId` are resolved from your `az` context when omitted.

With no `-Deployment`, the inline-metering section picks one chat deployment **per publisher**
and calls each one streamed and non-streamed. A single-provider smoke test is exactly how the
Anthropic and xAI defects survived the first pass.

## Parameters

| Parameter | Description |
|---|---|
| `-AccountName` | **Required.** Your Foundry / Azure OpenAI account name |
| `-SubscriptionId` | Defaults to the current `az` subscription |
| `-ResourceGroup` | Resolved from the account name when omitted |
| `-Region` | Region for the catalog and price table. **Defaults to the account's own location** |
| `-Deployment` | The deployment **section 3** calls. Default: one chat deployment per publisher, excluding `model-router`. Does not filter the other sections |
| `-LookbackMins` | Azure Monitor window for sections 4 and 5. **1 to 44640** (31 days, the most one metrics request covers). Default `60` |
| `-IncludeCost` | Also run section 6 — billed cost for the last 5 UTC days plus today. Slow and throttled |
| `-SkipInference` | Skip section 3 entirely, so no tokens are spent |

## What's in here

**`Get-FoundryUsageTelemetry.ps1`** — the telemetry tiers:

| Function | Purpose |
|---|---|
| `Get-EntraToken` | Entra token acquisition, per audience |
| `Invoke-ArmWithRetry` | Shared throttle-aware ARM caller |
| `Get-ArmCollection` | Paged ARM reader — **follows `nextLink` even from an empty first page** |
| `ConvertTo-DateText` | Keeps ISO strings as strings; see the date-coercion gotcha below |
| `Format-Number` | Formatting that does not silently round large token counts |
| `Get-FoundryModelCatalog` | Model inventory, de-duplicated across SKUs, publisher from `format` |
| `Get-FoundryDeployments` | Deployment → publisher join, from `properties.model.format` |
| `Get-AzureRetailPrices` | Raw price rows with per-row unit normalisation |
| `Resolve-ModelPrice` | Deployment → meter resolution |
| `Get-RoutedPrice` | model-router: router fee plus the served model's meters |
| `Measure-TokenCost` | Tokens × unit price for one usage record |
| `Get-ProviderProfile` | Publisher → endpoint, headers, field names, cache/reasoning semantics |
| `ConvertTo-NormalizedUsage` | Collapses every publisher's usage block into one schema |
| `Invoke-MeteredCompletion` | Provider-aware metering wrapper — routing, conditional `include_usage`, `max_completion_tokens` retry |
| `Get-TokenUsage` | **Azure Monitor token metrics — the preferred cross-publisher source** |
| `Get-NearRealTimeCost` | The join: tokens × cached price, tagged `Derived` / `CCU` / `NoMeter` |
| `Get-BilledCost` | Cost Management with 429 backoff |

**`Build-FoundryPriceTable.ps1`** — the cached price table:

| Function | Purpose |
|---|---|
| `Build-FoundryPriceTable` | Fetch, classify and cache every token meter for a region |
| `ConvertTo-MeterAttributes` | Parse an abbreviated `meterName` into structured attributes |
| `ConvertTo-MatchName` / `Get-VariantSet` | Model-name normalisation and variant extraction |
| `Get-MediaAttributes` | Modality and media-kind classification |
| `Get-TokenPrice` | Look up one rate. Returns a `Status`, never a bare zero |
| `Measure-RequestCost` | Cost one request. Returns null cost — never 0 — when any price is unknown |
| `Get-UnpricedModels` | List models that are deployable but have no usable price |

## Azure Retail Prices API — five gotchas

Each of these silently returns wrong or empty data rather than an error.

**1. `serviceName` is `'Foundry Models'`, not `'Cognitive Services'`.**

```
serviceName eq 'Cognitive Services'  ->  Count = 0     (HTTP 200, silent)
serviceName eq 'Foundry Models'      ->  1,585 token meters in eastus2
```

**2. Token meters exist outside `'Foundry Models'`.**

Filtering on `contains(meterName,'Tokens')` across **all** services in `eastus2` returns 1,646
rows (2026-10-07):

| `serviceName` | Rows | Example |
|---|---|---|
| `Foundry Models` | 1,585 | `5.4 opt Dz 1M Tokens` |
| `Foundry Tools` | 49 | `Voice Live API Std- LLM Audio Cached Tokens`, `Model Routers GL 1M Tokens` |
| `Azure Cognitive Search` | 6 | `Free Agentic Retrieval Low Reasoning Tokens` |
| `Azure Machine Learning` | 6 | `Llama-4-Scout-17B-16E-In Tokens` |

The builder scopes to `Foundry Models` deliberately, but if you meter Voice Live or the model
router fee you need `Foundry Tools` too.

**3. `unitOfMeasure` is mixed within the same product family — in two spellings.**

Across the `Foundry Models` / `eastus2` slice:

```
1K  966    1M  649    1/Hour  58    1 Hour  41    1 Second  30
1    18    100   4    1/Day    2    1/Month  2
```

**`1/Hour` and `1 Hour` both occur.** A blanket multiplier misreports non-token meters by
1000×. Normalise per row:

```
'1K' -> per-1M = retailPrice * 1000
'1M' -> per-1M = retailPrice
else -> not token-denominated; do not convert
```

**4. `meterName` uses abbreviations, not model IDs.**

Searching for `gpt-4.1` never matches `gpt 4.1 Inp glbl Tokens`. Conventions differ between
families: `gpt-oss-120B Inp glbl Tokens` carries the full name, `4.3 Inp Glbl Tokens` carries
only a version. The abbreviations actually in use:

| Concept | Spellings seen |
|---|---|
| Input | `Inp`, `Inpt`, `Input` |
| Output | `Outp`, `outpt`, `Opt`, `Output` |
| Cached | `cd`, `cchd`, `Cached`, `Cache` |
| Cache write | `Cd Wr`, `Cache Inp` |
| Global | `glbl`, `Gl`, `global` |
| Data Zone | `DZ`, `DZone`, `DZn`, `Data Zone`, `DataZone` |
| Regional | `regnl`, `rgnl`, `regional`, `regn` |
| Context band | `LongCo`, `LoCo`, bare `l`; `ShortCo`, `ShCo` |
| Deployment type | `PP` (Priority), `Flex`/`Fl`, `Batch`, `FT` (fine-tuned) |

**5. `productName` spelling is inconsistent, and the price-type field is `type`.**

`Azure Deepseek Models` has a lowercase `s`, so `contains(productName,'DeepSeek')` returns
nothing (59 rows under the correct spelling). And the field naming the price type is **`type`**,
not `priceType` — all 1,646 token rows are `Consumption`. The full row schema:

```
armRegionName, armSkuName, currencyCode, effectiveStartDate, isPrimaryMeterRegion,
location, meterId, meterName, productId, productName, retailPrice, serviceFamily,
serviceId, serviceName, skuId, skuName, tierMinimumUnits, type, unitOfMeasure, unitPrice
```

### Coverage is incomplete, by design and by gap

Some models are deployable, GA, consuming quota, and have **no published price meter at all** —
`DeepSeek-V4.1-Flash` bills on `DS30 1M Tokens` and `DS31 1M Tokens`, meters that only Cost
Management shows. Handle a null price explicitly.

Anthropic has no family in this API at all; see
[Anthropic bills through Azure Marketplace](#anthropic-bills-through-azure-marketplace).

---

## Two PowerShell/KQL traps worth naming

**`ConvertFrom-Json` turns version strings into dates.** `Invoke-RestMethod` and
`ConvertFrom-Json` coerce anything ISO-shaped into `[datetime]` with `Kind = Utc` — including a
model version like `"2025-08-07"`, which then renders as `2025-08-07T00:00:00.0000000Z` and no
longer matches the catalog. Worse, `[datetime]::Parse($x).ToUniversalTime()` then shifts it by
your local offset. On PowerShell 7.5+ use `ConvertFrom-Json -DateKind String`; below that, guard
with a capability check, because the parameter does not exist:

```powershell
$jsonArgs = @{}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
    $jsonArgs = @{ DateKind = 'String' }
}
$obj = $raw | ConvertFrom-Json @jsonArgs
```

**`requestTime` uses two different epochs** in the diagnostic logs. Envelope rows carry .NET
ticks; model rows carry 100-nanosecond ticks since the **Unix** epoch. Decoding both the same
way puts half your data in the year 1601.

---

## Recommended architecture

```
                ┌──────────────────────────────────────────────────────────────────┐
 user request   │                        Your AI Gateway                           │
 ──────────────▶│                                                                  │
 + tenant id    │  ① publisher  ← ARM properties.model.format, never the name      │
                │  ② endpoint   → /openai/v1/chat/completions                      │
                │                 /anthropic/v1/messages        ← Anthropic *      │
                │  ③ limit param  max_completion_tokens                            │
                │                 max_tokens                    ← Anthropic * only │
                │  ④ streaming    stream_options.include_usage   ← OpenAI only     │
                │                 omit entirely                 ← Anthropic * 400  │
                │  ⑤ forward, capture usage + apim-request-id                      │
                │  ⑥ normalise    + reasoning → reported output ← xAI *            │
                │                 no cache subtraction          ← Anthropic *      │
                │                 recompute total               ← Anthropic * none │
                │  ⑦ cost = tokens × cached unit price                             │
                │                 null, not zero                ← Anthropic * CCU  │
                │  ⑧ emit per-TENANT metric ── ZERO LAG ───────────────────────────┼──▶ dashboard
                └───────────────────────────────┬──────────────────────────────────┘
                                                ▼
                                       Microsoft Foundry
                                                │
    ┌───────────────┬───────────────┬───────────┴───────┬──────────────────┐
    ▼               ▼               ▼                   ▼                  ▼
 Retail Prices  ★ AZURE MONITOR ★  AzureOpenAI      RequestResponse   Cost Management
 anonymous      TOKEN TOTALS       RequestUsage     log               THE INVOICE
 cache daily    ~1 min · 1-min     p50 5 s          p50 120 s         > 5 h, throttled
 list prices    ALL publishers     PER REQUEST      PER REQUEST       daily grain
 no Anthropic * one schema         OpenAI ONLY *    all publishers    Anthropic = SaaS,
                no tenant dim      OFF BY DEFAULT   2 rows/request    off-account *
                missing Claude     cache split      no cache split
                Responses API *    join: apim-request-id
    │               │                   │                 │                 │
    ▼               ▼                   ▼                 ▼                 ▼
 unit price     reconcile gateway   per-request      per-request       nightly computed
 table          vs Monitor =        settlement       settlement for    vs billed = drift
                bypass detection    (OpenAI)         everyone else
```

`*` marks a point where a publisher diverges from the OpenAI-shaped default. Every one of them
fails *open* — HTTP 200 with wrong or missing numbers — except the three that return HTTP 400.

| `*` | Divergence | If you ignore it |
|---|---|---|
| Anthropic endpoint | `/anthropic/v1/messages`, `anthropic-version` header required | `api_not_supported` — no Claude metering at all |
| Anthropic streaming | `stream_options` rejected; usage streams unconditionally and **twice** | HTTP 400, or the partial `message_start` count |
| Anthropic fields | `input_tokens` / `output_tokens`, no `total_tokens` | Silent **0** — Claude billed as free |
| Anthropic cache | `input_tokens` **excludes** cache; the real volume is in four separate metrics | Under-bill by **100×+** on a cache-heavy workload |
| Anthropic cost | SaaS/CCU via Marketplace, off the Foundry account entirely | A null that looks like a coverage gap, and an account query that shows no Claude spend |
| Anthropic + Responses API | Monitor's token metrics omit it; `ModelRequests` counts it | Up to **48%** of input tokens invisible |
| xAI reasoning | `reasoning_tokens` excluded from `completion_tokens`, included in `total_tokens`, and **not billed** | Under-report the work, or **19× over-bill** if you use `Total − In` |
| OpenAI o/5/6 | `max_tokens` rejected, needs `max_completion_tokens` | HTTP 400 on every reasoning model |
| Context-banded models | `gpt-5.6-*`, `gpt-6-*` have **no** Standard-tier meter | `NoMeter` on six live deployments |
| Per-request log | `AzureOpenAIRequestUsage` is OpenAI-only, off by default, and array-encoded | Zero from every KQL sum you write |

**Read the bottom tier as independent loops.** Monitor is the system of record for *how many
tokens*; Cost Management is the system of record for *how many dollars*; the gateway is the
system of record for *whose tokens*; the per-request logs settle *which request*. Any persistent
gap between gateway and Monitor is a bypass or a parsing defect.

## Implementation checklist

**Provider handling — do this first**

- [ ] Resolve the publisher from `properties.model.format` on the ARM deployment; never infer it
      from the deployment name, and never read `model.publisher` (null on every OpenAI entry)
- [ ] Route Anthropic to `/anthropic/v1/messages` with an `anthropic-version` header
- [ ] Parse `input_tokens`/`output_tokens` for Anthropic, `prompt_tokens`/`completion_tokens`
      otherwise
- [ ] **Do not subtract cached tokens on Anthropic** — `input_tokens` already excludes them
- [ ] **Add `reasoning_tokens` to reported output on xAI**, and do *not* add them on OpenAI
- [ ] Recompute `total_tokens` yourself; Anthropic has none and xAI's disagrees
- [ ] Send `max_completion_tokens` on the OpenAI path and `max_tokens` on the Anthropic path;
      retry once with the other spelling on HTTP 400

**Streaming**

- [ ] Inject `stream_options.include_usage` on the **OpenAI** path only — xAI and DeepSeek send
      usage regardless, and Anthropic returns HTTP 400
- [ ] Take the **last** `usage` object on any stream, not the first
- [ ] Look for `latency_checkpoint` both inside `usage` (non-streamed) and top-level in a chunk
      (streamed)
- [ ] Measure TTFT at the proxy for Anthropic, which has no latency block at all

**Pricing and cost**

- [ ] Build the price table nightly using `serviceName eq 'Foundry Models'`
- [ ] **Normalise price per row by `unitOfMeasure`** — never a blanket multiplier, and handle
      both `1/Hour` and `1 Hour`
- [ ] Pass `-ContextTier` for `gpt-5.6-*` / `gpt-6-*`; they have no Standard-tier meter
- [ ] Treat a missing meter as **null, not zero**; alert rather than silently billing nothing
- [ ] Distinguish `BilledOutsideRetailAPI` (Anthropic, null by design) from `NoMeter` (a real gap)
- [ ] Surface `CachedRateIsFallback` — a fallback cached rate makes the cost an upper bound
- [ ] Carry `IsListPrice` through to anything invoice-facing

**Per-request settlement**

- [ ] Enable `AzureOpenAIRequestUsage` **and** `RequestResponse` — neither emits by default
- [ ] Check whether Azure Policy already created a diagnostic setting before adding one
- [ ] Index the token fields: `tolong(p.promptTokens[0])`, not `tolong(p.promptTokens)`
- [ ] **Deduplicate `RequestResponse` on `CorrelationId`** — two rows per request, one with tokens
- [ ] Filter `RequestResponse` to rows that actually carry tokens; ~66% are not inference
- [ ] Persist **`apim-request-id`** with your tenant ID — it is the `CorrelationId` join key
- [ ] Do **not** rely on `x-request-id`, `x-ms-client-request-id` or Anthropic's `Request-Id`;
      none reaches any log
- [ ] Billable input from the usage log is `promptTokens[0] − cachedTokens[0]`
- [ ] Re-scan a late window: `RequestResponse` p99 is 220 s but the observed max was 3h 45m

**Reconciliation**

- [ ] Poll Azure Monitor every 1–5 minutes as the cross-publisher token source
- [ ] **Price `InputTokens` and `OutputTokens`. Never `TotalTokens − InputTokens`** — on xAI the
      residual is unbilled reasoning, and charging it over-bills by ~19×
- [ ] **Add the cache metrics for Anthropic** — `cacheReadInputTokens` plus
      `ephemeral5mInputTokens` + `ephemeral1hInputTokens`. They sit outside `TotalTokens`
- [ ] **Do not bill OpenAI `InputTokens` at the full input rate** — it already includes cache
      reads, which Monitor does not break out
- [ ] Lag your query window: the local clock ran ~22 s behind Azure
- [ ] Split any lookback longer than 31 days; a longer `timespan` is silently truncated
- [ ] Set `top` explicitly on metrics queries — it defaults to 10
- [ ] Filter `ModelRequests` by `StatusCode`; it counts 429s and 400s
- [ ] Reconcile over windows with idle edges
- [ ] Alert when `monitor_tokens − gateway_tokens` exceeds a threshold
- [ ] Never record zero tokens from a missing usage block — mark the window unknown
- [ ] Run Cost Management **once nightly**, with 429 backoff, and alert on drift
- [ ] Remember Claude spend is **not on the account** — query Marketplace SaaS resources
- [ ] Capture `ServiceTierRequest` vs `ServiceTierResponse` to detect silent tier downgrades

## Requirements

- PowerShell **7.0+** (`-DateKind String` needs 7.5+; the code degrades gracefully below it)
- Azure CLI, signed in (`az login`)
- `Build-FoundryPriceTable.ps1` in the same folder as `Get-FoundryUsageTelemetry.ps1`

No API keys — every call uses an Entra token:

| Call | Token audience |
|---|---|
| ARM, Azure Monitor, Cost Management | `https://management.azure.com` |
| Inference | `https://cognitiveservices.azure.com` |
| Log Analytics | `https://api.loganalytics.io` |
| Retail Prices API | **anonymous** |

### RBAC

These come from the role definitions and the Cost Management docs. **Least privilege was not
tested** — the test identity held Owner, Foundry User, Cognitive Services User and Cognitive
Services OpenAI User.

| What | Role | Scope |
|---|---|---|
| Model catalog, deployments, Azure Monitor metrics | **Reader** | Subscription (the catalog is a subscription-scope call) |
| Inference (section 3) | **Foundry User** or equivalent data-plane role | Account — or use `-SkipInference` |
| Retail Prices | *none* | — |
| Cost Management query | **Reader** or **Cost Management Reader** | Subscription. On an EA the *AO view charges* setting must be on; on CSP the partner must enable cost visibility |
| Reading the diagnostic logs | **Log Analytics Reader** | Workspace |
| Creating a diagnostic setting | **Monitoring Contributor** | Account **and** workspace |

## Source documentation

- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Azure Monitor — Metrics: List](https://learn.microsoft.com/en-us/rest/api/monitor/metrics/list)
- [Monitor model deployments in Microsoft Foundry Models](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/monitor-models)
- [Monitoring data reference for Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry/openai/monitor-openai-reference) — metric and log category schemas
- [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)
- [Microsoft Foundry SDKs and endpoints](https://learn.microsoft.com/en-us/azure/foundry/how-to/develop/sdk-overview) — including the Anthropic SDK against `/anthropic`
- [Cost Management — Query: Usage](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage)
- [Plan and manage costs for Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/concepts/manage-costs)
- [Claude models in Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models)
- [Claude Consumption Units (CCU) billing](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-billing)
- [Claude model quotas and rate limits](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-quotas-limits)
- [Models — List (Foundry catalog)](https://learn.microsoft.com/en-us/rest/api/aiservices/accountmanagement/models/list)
- [Deployment types](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/deployment-types)

## Related

[foundry-model-catalog-watcher](https://github.com/dhangerkapil/foundry-model-catalog-watcher) —
polls the Foundry model catalog and alerts on new models, with an `-IncludePricing` mode that
flags models which are deployable but have no published price meter.

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer

This is a personal project, provided as-is. It is not an official Microsoft product, is not
supported by Microsoft, and carries no warranty. The Azure API surface it depends on may change.
Several behaviours documented here — the `apim-request-id` join, the array encoding of the
usage-log token fields, the Claude Responses-API gap in Azure Monitor, and the xAI reasoning
exclusion — are **observed, not published contracts**. The measured figures were taken on
**2026-10-06 and 2026-10-07** against a single account and should be re-verified before you rely
on them.

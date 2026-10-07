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

    VERIFIED PRICE RELATIONSHIPS (eastus2 list prices, Oct 2026, USD per 1M)

        Data Zone     = Global x 1.10    Grok 4.3 input:        1.25 -> 1.375
                        x 1.25           Kimi K2.6 output:      4.00 -> 5.00
        Long context  = input  x 2.00    Grok 4.3 input:        1.25 -> 2.50
                        output x 1.5     GPT 5.6 sol output:   20.00 -> 30.00
                        (x 2.00 on Grok) Grok 4.3 output:       2.50 -> 5.00
        Batch         = base   x 0.50    GPT 5.4 pro input:    30.00 -> 15.00
        Flex          = base   x 0.50    GPT 5.4 input:         2.50 -> 1.25
        Priority (PP) = base   x 2.00    GPT 5.6 sol input:     4.00 -> 8.00
                        x 1.75           gpt-4.1 input:         2.00 -> 3.50
                        x 1.80           GPT 5 mini input:      0.25 -> 0.45
                        x 2.50           GPT 5.5 short input:   5.00 -> 12.50
        Cache write   = input  x 1.25    GPT 5.6 terra input:   2.00 -> 2.50
        Cached input  = 3% to 50% of input, by model:
                        DeepSeek V4 Flash 0731 3%, GPT 5.x 10%, Grok 4.3 16%,
                        gpt-4.1 25%, gpt-4o-mini 50%

    These are observations, not contracts. Priority alone runs from x 1.75
    to x 2.50 depending on the model, and only some models have Flex meters
    at all. The table reads actual meters; the ratios are here to explain
    why the key needs five parts, not to be computed from.

    Measured over the whole eastus2 table (1543 meters, 2026-10-07), pairing
    meters that differ in exactly one attribute:

        Data Zone / Global          502 of 536 pairs are exactly x 1.10
        Batch / Standard            118 of 121 pairs are exactly x 0.50
        Priority / Standard          82 of  88 pairs are exactly x 2.00
        Long / Short, input          28 of  28 pairs are exactly x 2.00
        Long / Short, output         27 of  27 pairs are exactly x 1.50
        Cache write / input          46 of  46 pairs are exactly x 1.25

    The exceptions are what make a lookup table necessary. Data Zone: Kimi
    K2.7 Code output is x 1.25, and roughly 30 pairs land between x 1.07 and
    x 1.12 because the published rate is rounded (DeepSeek, and small
    cached-input rates). Batch: gpt-5.4 cached input is 0.275 -> 0.143
    (x 0.52, rounding). Priority: gpt-5.5 is x 2.50, gpt-4.1 x 1.75,
    gpt-5-mini x 1.80.

    Long context output is x 1.50 on every Short/Long pair, but Grok 4.3 has
    no Short band - its Long meters are x 2.00 on the Standard rate, which is
    why the range above reads x 1.5 to x 2.

    Flex produced no clean pairs: every Flex meter uses the abbreviated
    spelling ('56sol ShCo Inp Fl Gl') while its Standard twin uses the
    spaced one ('5.6 sol ShortCo Inp Std Gl'), so no mechanical pairing can
    see them as the same model. Checked by hand on all eight gpt-5.6-sol
    pairs, Flex is x 0.50 of Standard.

    Two meter families in the feed are internally inconsistent and must not
    be used to infer anything: 'Model 6' and 'Model 7' (unnamed placeholder
    products) publish Global and Data Zone rates that are transposed -
    'Model 7 Inp glbl' is 3.30 against 'Model 7 Inp DZ' at 0.30, and the
    output meters are 0.33 against 16.50.

    MEDIA MODELS PRICE EACH TOKEN TYPE SEPARATELY

    Realtime, audio, transcription, text-to-speech and image models bill
    text, audio and image tokens at different rates, and the meter name says
    which:

        gpt rt 1.5 txt inp Gl    4.00 /1M   <- gpt-realtime-1.5, text input
        gpt rt 1.5 aud inp Gl   32.00 /1M   <- same model, audio input (8x)
        gpt rt 1.5 img inp Gl    5.00 /1M   <- same model, image input

    Their usage reports each type separately, so a lookup for one of these
    models must name the type (Get-TokenPrice -Modality). A media model must
    also never match a chat model's meters: gpt-4o-mini-transcribe once
    priced from the gpt-4o-mini chat meter at $0.15/1M, against its own
    audio rate of $3.00.

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
# A parser that guesses will mis-key output tokens and silently under-bill,
# because output is typically 4-6x the input rate.
#
# The naming is NOT tokenised consistently, so matching on whitespace-split
# tokens is too brittle. All four of these appear in one region:
#
#     ... Inp DZone Tokens          single token
#     ... Inp Data Zone Tokens      TWO words
#     ... BatchOutp DataZone Tokens concatenated, and one-word DataZone
#     ... txt-out-glbl Tokens       hyphen separated, 'out' not 'outp'
#
# So matching is regex-based against the whole normalised name, with word
# boundaries where a short token could otherwise match inside another word.
# ---------------------------------------------------------------------------

# Order matters, first match wins.
#   CacheWrite before CachedInput: a cache-write meter reads 'Cd Wr', which also
#     contains the cached marker. These are NOT the same price - verified on
#     gpt-5.6-sol Global Standard, short context: Cd Wr = $5.00/1M,
#     Cd Inp = $0.40/1M. 12.5x apart, and the same ratio holds in every tier.
#     Collapsing them into one Kind makes the cache key collide and the winner
#     arbitrary, so cache reads can be billed at 12.5x or writes at 1/12.5x.
#   CachedInput before Input: a cached-input meter also contains 'Inp'.
# Cached has four spellings in the wild: cach, cchd, cched, cd.
$script:KindPatterns = [ordered]@{
    'CacheWrite'  = 'cache\s*write|\bwr\b|\bcw\b'
    'CachedInput' = 'cach|cchd|cched|\bcd\b'
    'Output'      = 'outp|output|\bout\b|\bopt\b'
    'Input'       = 'inp|input|\bin\b'
}

# Data Zone has FIVE spellings: 'Data Zone', 'DataZone', 'DZone', 'DZn', 'DZ'.
# Any one missed silently falls through to the Global default, a 10% under-bill
# (verified: gpt-4.1 Global $2.00 vs Data Zone $2.20). Regional has four:
# 'regnl', 'regional', 'rgnl' and 'regn' - the last only on the gpt-4o
# realtime-preview meters, which otherwise read as Global and sat beside the
# real Global meter at a 10% higher price.
$script:ScopePatterns = [ordered]@{
    'DataZone' = 'data\s*zone|dzone|\bdzn\b|\bdz\b'
    'Regional' = 'regnl|regional|\brgnl\b|\bregn\b'
    'Global'   = 'glbl|global|\bgl\b'
}

# Media kind and token type. See "MEDIA MODELS" in the header.
#
# MediaKind is the kind of model a meter belongs to, read from the EARLIEST
# media word in the name: 'gpt rt aud 0828 Inp' is a realtime meter for audio
# tokens, not an audio-model meter. '' means an ordinary text model.
# Modality is the token type: a type word in the rest of the name, otherwise
# the kind's native type ('gpt aud 0828 Inp glbl' is the audio-token meter of
# gpt-audio; its text meter says 'txt'). Realtime and speech meters always
# carry a type word, so neither has a native type - one without a type word
# is left unclassified rather than guessed.
$script:MediaKindPatterns = [ordered]@{
    'Embedding'  = '\bembed(ding)?\b'
    'Realtime'   = '\brt\b|realtime|\brtime\b'
    'Transcribe' = 'transcribe|\btrscb\b|\btcrb\b'
    'Speech'     = '\btts\b'
    'Audio'      = '\baud\d*\b|\baudio\b'      # 'aud1217': date glued on
    'Image'      = '\bimg\b|\bimage\b'
}
$script:TokenTypePatterns = [ordered]@{
    'Text'  = '\btxt\d*\b|\btext\b'            # 'txt1217': date glued on
    'Audio' = '\baud\d*\b|\baudio\b'
    'Image' = '\bimg\b|\bimage\b'
}
$script:NativeTokenType = @{
    '' = 'Text'; 'Embedding' = 'Text'; 'Transcribe' = 'Audio'; 'Audio' = 'Audio'; 'Image' = 'Image'
}
# Media kinds whose usage splits across token types. There is no safe default
# type for these, so a lookup must name one.
$script:PerTokenTypeMediaKinds = @('Realtime', 'Transcribe', 'Speech', 'Audio', 'Image')

# Publishers that do not bill through the Retail Prices API at all.
# Anthropic / Claude bills through Azure Marketplace, so a missing meter is
# CORRECT for these - not a coverage gap. A gateway that reads "no meter" as
# "free" would bill nothing for Claude traffic.
#
# Current deployments bill in Claude Consumption Units (CCU); deployments made
# before CCU billing can still sit on a per-model, per-token Marketplace plan.
# Either way, Cost Management books the charge under MeterCategory 'SaaS' on a
# Marketplace (Microsoft.SaaS) resource created per deployment - NOT on the
# Foundry account - so a cost query scoped to the account shows no Claude spend
# at all (verified). The CCU meter name carries the plan and hosting
# ('Azure hosted' / 'Anthropic hosted'), never the model; only that
# per-deployment resource tells the models apart. Token counts are
# exact (Azure Monitor or the inference response); a per-REQUEST dollar figure
# can only be estimated. See:
#   https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing
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

# ---------------------------------------------------------------------------
# Model-to-meter matching (Get-TokenPrice).
#
# A model name never appears verbatim in its meter names: 'gpt-5.4-mini'
# bills as '5.4 mini inp Gl', 'Llama-4-Maverick-17B-128E-Instruct-FP8' as
# 'Llama 4 Maverick 17B Inp glbl'. So a meter is tied to a model by three
# checks - the version token, the variant set and the remaining words of the
# model name - and models whose meters share none of that are mapped
# explicitly in $script:MeterAliases.
# ---------------------------------------------------------------------------

# Variant markers, compared as SETS on both sides. The version token alone is
# not enough: 'gpt-5.4' matches the meters for 5.4, 5.4 pro, 5.4 mini and
# 5.4 nano, whose prices differ by an order of magnitude.
#
# 'opt' must NOT appear here: it is the OUTPUT marker, not a variant.
# Listing it gave every output meter a phantom variant that could never
# match a model name, so $exact was always empty and disambiguation
# silently disabled itself for every output lookup - reopening the trap.
# Values are regex alternations because meters abbreviate ('mini' -> 'mn';
# 'diarize' -> 'd', as in 'gpt 4o tcrb d aud inp glbl').
# Without 'max', 'plus' and 'diarize' a model matched its sibling's meters:
# gpt-5.1-codex priced from '5.1 codex max', Phi-4-reasoning from
# 'Phi-4-reasoning-plus', and gpt-4o-transcribe's text tokens from the
# diarize model's meters. 'preview' is deliberately NOT a variant: it is a
# lifecycle stage, and a preview model's meters rarely say so.
$script:VariantAliases = [ordered]@{
    'pro'   = 'pro';   'mini' = 'mini|mn'; 'nano'  = 'nano'
    'codex' = 'codex'; 'flash'= 'flash';   'lite'  = 'lite'
    'turbo' = 'turbo'; 'sol'  = 'sol';     'luna'  = 'luna'
    'terra' = 'terra'; 'astra'= 'astra';   'chat'  = 'chat'
    'reasoning' = 'reasoning'; 'mm' = 'mm|multimodal'
    'research'  = 'research|deep research'
    'medium' = 'medium'; 'large' = 'large'; 'small' = 'small'
    'max'    = 'max';    'plus'  = 'plus';  'diarize' = 'diarize|d'
}

# Meters glue on what model names keep apart:
#   '56sol ShCo Inp Fl Gl'       variant on version  (gpt-5.6-sol, Flex)
#   'gpt4o mn trscb aud in gl'   family on version   (gpt-4o-mini-transcribe)
#   'gpt4omini-aud1217 Inp glbl' both                (gpt-4o-mini-audio-preview)
# Left glued, the version token is invisible and each of these came back
# NoMeter, so split them. Only the variant KEYS are split off a digit: the
# abbreviation 'mn' never appears glued to one, and splitting it would be a
# guess. Results are cached; the same few thousand names recur on every
# lookup.
$script:GluedVariant   = '(?<=\d)(' + (@($script:VariantAliases.Keys) -join '|') + ')(?![a-z])'
$script:MatchNameCache = @{}
function ConvertTo-MatchName([string] $Name) {
    $hit = $script:MatchNameCache[$Name]
    if ($null -ne $hit) { return $hit }
    $n = $Name.ToLowerInvariant() -replace '[\-_]', ' ' -replace '\bgpt(?=\d)', 'gpt ' -replace '(?<=\d)o(?=mini)', 'o '
    $n = $n -replace $script:GluedVariant, ' $1'
    $script:MatchNameCache[$Name] = $n
    $n
}

# Collect ALL variant markers on each side and compare as sets, so a name
# carrying two markers ('Phi-4-Mini MM-Input' is both 'mini' AND 'mm') is
# never confused with a name carrying one. 'Phi-4-multimodal-instruct' ({mm})
# therefore does not match that {mini+mm} meter on its own - it is mapped in
# $script:MeterAliases - rather than falling to the plain Phi-4 meter at
# $0.125 it was once priced from.
$script:VariantSetCache = @{}
function Get-VariantSet([string] $Text) {
    $hit = $script:VariantSetCache[$Text]
    if ($null -ne $hit) { return $hit }
    $t = ConvertTo-MatchName $Text
    $found = [System.Collections.Generic.SortedSet[string]]::new()
    foreach ($v in $script:VariantAliases.Keys) {
        # Trailing boundary is (?![a-z]) rather than (\s|$) because meter
        # names GLUE the variant to what follows: 'gpt-4-turbo128K' has no
        # separator between 'turbo' and '128K'. Requiring whitespace made
        # that meter report variant '' - identical to base 'gpt-4' - so
        # plain gpt-4 (its own meter: $30/$60) resolved to the turbo meter
        # at $10/$30, two-thirds under on input and half on output, while
        # real 'gpt-4-turbo' got NoMeter. Leading boundary stays (^|\s) so
        # a variant glued to the END of a preceding word cannot match
        # spuriously; ConvertTo-MatchName has already split the one
        # legitimate glued form, digits followed by a variant.
        if ($t -match "(^|\s)($($script:VariantAliases[$v]))(?![a-z])") { [void]$found.Add($v) }
    }
    $set = $found -join '+'
    $script:VariantSetCache[$Text] = $set
    $set
}

# Every other word of the model name must appear in the meter name too.
# Version and variant alone agree for 'Llama-4-Scout-17B-16E-Instruct' and
# 'Llama 4 Maverick 17B Inp glbl', and for 'DeepSeek-V3.2-Speciale' and
# 'V3.2 Inp glbl' - both models were priced from the other model's meter.
# Exempt: variant words (compared as sets above), media and token-type words
# (compared as attributes) and these, which meter names leave out.
$script:NoiseWords = @('gpt', 'deepseek', 'kimi', 'grok', 'mistral', 'cohere', 'instruct', 'preview')

# Models whose meters cannot be tied to the model name: there is no version
# token ('gpt-realtime', 'codex-mini'), the meter spells the model
# differently ('mistral-medium-3-5' bills as 'MM3.5'), or a later release
# shares the name and only its meters carry a date ('V4 Flash' and
# 'V4 Flash 0731' both match DeepSeek-V4-Flash). Each value is a regex
# over the normalised meter name (lower case, '-' and '_' as spaces). Every
# other filter - publisher family, kind, scope, context tier, service tier,
# token type - still applies, so one pattern covers all of a model's meters.
# Basis: Retail Prices API meter names and list prices, eastus2, October 2026
# (USD per 1M tokens, Global). Extend this rather than guessing, and check a
# new entry against Cost Management once the model has billed.
$script:MeterAliases = @{
    'text-embedding-ada-002'        = '^embedding ada\b'                    # $0.10 ('glbl' and 'glbl-new' meters, same price)
    'embed-v-4-0'                   = '^embed v4\b'                         # text $0.12, image $0.47
    'Codestral-2501'                = '^codestral\b'                        # $0.30 in, $0.90 out
    'codex-mini'                    = '^codex mini\b'                       # $1.50 in, $6.00 out, $0.375 cached
    'cohere-command-a'              = '^command a\b(?! plus)'               # $2.50 in, $10.00 out
    'Cohere-command-a-plus-05-2026' = '^command a plus\b'                   # $0.80 in, $3.20 out
    'mistral-medium-3-5'            = '^mm3\.5\b'                           # $1.50 in, $7.50 out
    'DeepSeek-V3.2-Speciale'        = '^v3\.2 sp\b'                         # $0.58 in, $1.68 out, as V3.2; the Azure pricing page lists 'DeepSeek V3.2 SP' as V3.2's only variant
    'DeepSeek-V4-Flash'             = '^v4 flash (?!\d)'                    # $0.19 in, $0.51 out, $0.028 cached - not the '0731' meters
    'DeepSeek-V4-Flash-0731'        = '^v4 flash 0731\b'                    # $0.44 in, $1.32 out, $0.014 cached
    'gpt-chat-latest'               = '^chat latest\b'                      # one meter set per release (MMDDYYYY), all $5 / $30 / $0.50 cached
    'Phi-4-multimodal-instruct'     = '^phi 4 mini mm\b'                    # text $0.08 in, $0.32 out; audio in $4
    'gpt-audio'                     = '^gpt aud \d{4}\b'                    # '0828': audio $40 / $80, text $2.50 / $10
    'gpt-audio-mini'                = '^gpt aud (mini|mn)\b'                # audio $10 / $20, text $0.60 / $2.40
    'gpt-realtime'                  = '^gpt rt (aud|img|txt) \d{4}\b'       # '0828': text $4 / $16, audio $32 / $64, image in $5
    'gpt-realtime-mini'             = '^gpt rt (aud|img|txt) (mini|mn)\b'   # text $0.60 / $2.40, audio $10 / $20, image in $0.80
}

# The meter name as -MeterPattern and $script:MeterAliases see it.
function ConvertTo-NormalizedMeterName([string] $MeterName) {
    ($MeterName -replace '[\-_]', ' ' -replace '\s+', ' ').Trim().ToLowerInvariant()
}

function Get-MediaAttributes {
    <#
    .SYNOPSIS
        Media kind and token type of a meter or model name. See
        $script:MediaKindPatterns.
    #>
    param([string] $Name)

    # camelCase is split first: one meter reads 'gpt4o realtimePrvwAudInp'.
    $n = ($Name -creplace '(?<=[a-z])(?=[A-Z])', ' ') -replace '[\-_]', ' ' -replace '\s+', ' '
    $n = $n.Trim().ToLowerInvariant()

    $mediaKind = ''; $at = -1; $len = 0
    foreach ($k in $script:MediaKindPatterns.Keys) {
        $m = [regex]::Match($n, $script:MediaKindPatterns[$k])
        if ($m.Success -and ($at -lt 0 -or $m.Index -lt $at)) { $mediaKind = $k; $at = $m.Index; $len = $m.Length }
    }

    $rest = if ($at -ge 0) { $n.Remove($at, $len) } else { $n }
    $tokenType = $null; $tat = -1
    foreach ($t in $script:TokenTypePatterns.Keys) {
        $m = [regex]::Match($rest, $script:TokenTypePatterns[$t])
        if ($m.Success -and ($tat -lt 0 -or $m.Index -lt $tat)) { $tokenType = $t; $tat = $m.Index }
    }
    if (-not $tokenType) { $tokenType = $script:NativeTokenType[$mediaKind] }   # $null for Realtime, Speech

    @{ MediaKind = $mediaKind; Modality = $tokenType }
}


function ConvertTo-MeterAttributes {
    <#
    .SYNOPSIS
        Parse one meterName into structured pricing attributes.
    #>
    param([string] $MeterName, [string] $UnitOfMeasure, [double] $RetailPrice)

    # Normalise separators so hyphenated and concatenated forms behave the same.
    $n = ConvertTo-NormalizedMeterName $MeterName

    $scope = 'Global'      # meters carrying no scope marker are Global in practice
    foreach ($s in $script:ScopePatterns.Keys) {
        if ($n -match $script:ScopePatterns[$s]) { $scope = $s; break }
    }

    $kind = $null
    foreach ($k in $script:KindPatterns.Keys) {
        if ($n -match $script:KindPatterns[$k]) { $kind = $k; break }
    }
    # Embedding meters carry no input/output marker at all
    # ('text-embedding-3-small-glbl Tokens', 'Embed v4 Txt Glbl Tokens'), so
    # they were dropped as unclassifiable and every embedding model read as
    # NoMeter. Embeddings bill input tokens only, so classify them as Input.
    if (-not $kind -and $n -match '\bembed(ding)?\b') { $kind = 'Input' }

    # Context tier. Abbreviated as LoCo / ShCo as well as LongCo / ShortCo, and
    # a bare 'l'. Long-context input is verified at exactly 2x base and output
    # at 1.5x-2x, so a missed marker under-bills by a third to a half.
    $contextTier = 'Standard'
    if     ($n -match 'longco|\bloco\b|\blong\b|\bl\b')  { $contextTier = 'Long' }
    elseif ($n -match 'shortco|\bshco\b|\bshort\b')      { $contextTier = 'Short' }

    # Service / deployment tier. Batch is 50% of standard on every pair checked
    # but one (gpt-5.4 cached input: $0.13 against $0.25).
    # 'PP' is Priority Processing: 2x standard on most models, but 1.75x on
    # gpt-4.1 and gpt-4.1-mini, 1.8x on gpt-5-mini and 2.5x on gpt-5.5 (eastus2
    # list prices, Oct 2026). It is NOT Provisioned/PTU. PTU is capacity billed
    # hourly ('1/Hour'), so it never appears as a per-token meter at all.
    # 'Flex' / 'Fl' is a third tier, verified at exactly 50% of standard, and
    # must not collide with Standard. Neither Priority nor Flex is a deployment
    # SKU - both run on a Standard deployment and are chosen per request
    # (Priority can also be a deployment setting) - so the caller has to say
    # which tier was billed: see Get-TokenPrice -ServiceTier.
    # Fine-tuning meters also come as 'dev ft' and 'dev RFT' (Developer tier,
    # reinforcement fine-tuning). 'o4 mini dev RFT cd inp glb' has no 'ft'
    # word, so it read as Standard inference and was returned as o4-mini's
    # own cached-input meter.
    $deploymentType = 'Standard'
    if     ($n -match 'batch')                       { $deploymentType = 'Batch' }
    elseif ($n -match '\bflex\b|\bfl\b')             { $deploymentType = 'Flex' }
    elseif ($n -match '\bpp\b')                      { $deploymentType = 'Priority' }
    elseif ($n -match '\bft\b|finetuned|fine tuned|\brft\b|\bdev\b') { $deploymentType = 'FineTuned' }

    # Host: Fireworks-hosted meters are prefixed FW and are a different SKU
    # from the Azure-direct model of the same name.
    $host_ = if ($n -match '^fw\b|\bfw\b') { 'Fireworks' } else { 'AzureDirect' }

    # Purpose. Fine-tuning *grader* meters price evaluation runs, not inference.
    # They sit alongside real inference meters for the same model and would
    # otherwise be a candidate for an ordinary chat lookup.
    $purpose = if ($n -match '\bgrdr\b|\bgrader\b') { 'Grader' } else { 'Inference' }

    # Media kind and token type - non-text meters must not be used for chat
    # token maths. Audio meters carry a date suffix ('aud1217', 'aud 0828');
    # a bare \baud\b once missed them, and an $11/1M audio meter became a
    # candidate for a text chat lookup.
    $media = Get-MediaAttributes $MeterName

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
        MediaKind      = $media.MediaKind
        Modality       = $media.Modality
        Purpose        = $purpose
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
    # Schema version. Bump this whenever parsing or lookup logic changes, so a
    # cache written by an older build is rebuilt rather than served. Without it,
    # a bug fixed today keeps returning wrong prices from yesterday's cache for
    # up to -MaxAgeHours.
    $script:PriceTableSchema = 4

    if ($CachePath -and -not $Force -and (Test-Path $CachePath)) {
        try {
            $cached = Get-Content $CachePath -Raw | ConvertFrom-Json
            # PowerShell 7's ConvertFrom-Json returns BuiltAtUtc as a UTC
            # DateTime; Windows PowerShell 5.1 returns the string. Feeding the
            # DateTime back through [datetime]::Parse dropped its Kind, so
            # ToUniversalTime() shifted it by the local offset: west of UTC the
            # cache read hours younger than it was and was served past
            # -MaxAgeHours. Handle both forms without the lossy round trip.
            $built    = $cached.BuiltAtUtc
            $builtUtc = if ($built -is [datetime]) { $built.ToUniversalTime() }
                        else { [datetimeoffset]::Parse([string]$built, [cultureinfo]::InvariantCulture).UtcDateTime }
            $age = [datetime]::UtcNow - $builtUtc
            # Validate completeness as well as freshness. A partial write that
            # still parses as JSON would otherwise be served as a complete
            # table, silently turning priced models into NoMeter.
            $complete = ($null -ne $cached.Entries) -and
                        ($cached.MeterCount -eq @($cached.Entries).Count)
            $sameSchema = ($cached.Schema -eq $script:PriceTableSchema)
            if ($age.TotalHours -lt $MaxAgeHours -and $cached.Region -eq $Region -and $complete -and $sameSchema) {
                Write-Verbose "Price cache hit ($([math]::Round($age.TotalHours,1))h old)"
                return $cached
            }
            if (-not $complete) {
                Write-Warning "Price cache is incomplete (MeterCount $($cached.MeterCount) vs $(@($cached.Entries).Count) entries) - rebuilding rather than serving a partial table."
            }
            elseif (-not $sameSchema) {
                Write-Verbose "Price cache schema $($cached.Schema) != $($script:PriceTableSchema); rebuilding."
            }
        } catch { Write-Warning "Price cache unreadable, rebuilding: $($_.Exception.Message)" }
    }

    # GOTCHA 1: serviceName is 'Foundry Models'. The old 'Cognitive Services'
    # value returns HTTP 200 with zero rows - a silent failure, not an error.
    $filter = "serviceName eq 'Foundry Models' and armRegionName eq '$Region' and contains(meterName,'Tokens')"
    # Pin the API version so the response shape cannot change under this
    # parser without a code change. NextPageLink carries it to later pages.
    $uri    = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&`$filter=" + [uri]::EscapeDataString($filter)

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
            MediaKind      = $attr.MediaKind
            Modality       = $attr.Modality
            Purpose        = $attr.Purpose
            UnitOfMeasure  = $item.unitOfMeasure
            RetailPrice    = $item.retailPrice
            PricePer1M     = $attr.PricePer1M
        })
    }

    $table = [pscustomobject]@{
        Region       = $Region
        BuiltAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        Schema       = $script:PriceTableSchema
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
          NoMeter                 no usable meter. The Note says which case:
                                  the model has meters at another scope or
                                  tier (a query mismatch); it has only
                                  fine-tuning meters; its version matched a
                                  sibling model's meters only; or nothing
                                  matched at all (a coverage gap, or a meter
                                  name that cannot be tied to the model)
          BilledOutsideRetailAPI  publisher bills via Marketplace (e.g. Anthropic).
                                  Absence is correct. Do NOT treat as free.
          BilledAsCapacity        provisioned (PTU) SKU, billed per hour, not
                                  per token
          UnknownPublisher        not in the family map; no verdict claimed
          Ambiguous               several candidate meters, none decisive. A
                                  lookup without -Modality for a model that
                                  prices token types separately is Ambiguous
                                  too, and the Note lists each type's price.

        A meter belongs to the model when it carries the model's version
        token ('5.4', '4o', 'V3.2'), the same variant markers ('mini', 'pro',
        'codex' ...) and every other word of the model name ('Maverick',
        'oss', 'flare'). Models whose meters share none of that are mapped in
        $script:MeterAliases, or can be pinned with -MeterPattern.

        Fine-tuned models ('<base>.ft-<id>') are not priced: they bill on
        their own meters, not their base model's.

    .PARAMETER Modality
        The token type being priced: Text, Audio or Image. Realtime, audio,
        transcription, text-to-speech and image models - and some multimodal
        and embedding models - bill each type at its own rate
        (gpt-realtime-1.5 input: text $4, audio $32, image $5 per 1M), and
        their usage reports the types separately. Omit it and Text is priced,
        unless the model also has meters for another type: then the result
        is Ambiguous, with each type's price in the Note. Price each type's
        tokens in its own call.

    .PARAMETER MeterPattern
        A regex over the normalised meter name (lower case, '-' and '_' as
        spaces, runs of spaces collapsed) that ties this model to its meters
        when the meter names cannot be derived from the model name. It
        replaces the version, variant and word checks; the publisher family,
        kind, scope, context tier, service tier and token type filters still
        apply. Overrides $script:MeterAliases. Example: 'codex-mini' bills as
        'codex mini inp glbl', so its pattern is '^codex mini\b'.

    .PARAMETER ServiceTier
        The tier the request was actually processed at: the service_tier field
        of the RESPONSE ('default', 'priority' or 'flex'). Priority and Flex
        are not deployment SKUs - they run on a Standard deployment and are
        chosen per request (Priority can also be a deployment setting) - so
        only the response says which one was billed. Each tier has its own
        meters. Flex is half the Standard rate where a Flex meter exists;
        Priority is double on most models, but 1.75x on gpt-4.1 and
        gpt-4.1-mini, 1.8x on gpt-5-mini and 2.5x on gpt-5.5 (eastus2 list
        prices, Oct 2026). So read the tier's own meter rather than scaling
        the Standard rate; a model with no meter for the tier is NoMeter.
        Omit it and the SKU decides (Standard, or Batch for a Batch SKU).

    .EXAMPLE
        $p = Get-TokenPrice -Table $t -ModelName 'gpt-oss-120b' `
                 -Publisher 'OpenAI-OSS' -Sku 'GlobalStandard' -Kind Input
        if ($p.Status -ne 'Priced') { ... handle, do not assume zero ... }

    .EXAMPLE
        # Audio input tokens of a realtime model. Without -Modality this is
        # Ambiguous: text, audio and image input are three different rates.
        Get-TokenPrice -Table $t -ModelName 'gpt-realtime-1.5' `
            -Publisher 'OpenAI' -Kind Input -Modality Audio
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][string] $ModelName,
        [string] $Publisher,
        [string] $Sku = 'GlobalStandard',
        [string] $ModelVersion,
        [Parameter(Mandatory)][ValidateSet('Input','Output','CachedInput','CacheWrite')][string] $Kind,
        [ValidateSet('Standard','Long','Short')][string] $ContextTier = 'Standard',
        [ValidateSet('Text','Audio','Image')][string] $Modality,
        [ValidateSet('Inference','Grader')][string] $Purpose = 'Inference',
        [ValidateSet('Standard','Default','Priority','Flex')][string] $ServiceTier,
        [string] $MeterPattern
    )

    # The token type actually priced, reported on every result. It stays
    # empty until resolved, and on a result that needs -Modality.
    $tokenType = if ($Modality) { $Modality } else { $null }

    function New-Result($status, $price, $meter, $note) {
        [pscustomobject]@{
            ModelName   = $ModelName
            Kind        = $Kind
            Modality    = $tokenType
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
            "$Publisher models bill through Azure Marketplace, not the Retail Prices API, so the missing meter is correct - do NOT bill this as zero. New deployments bill in Claude Consumption Units (CCU); deployments created before CCU billing became generally available keep their per-model token plan. Cost Management books the charge under MeterCategory 'SaaS' on Azure Marketplace resources, not on the Foundry account, and the CCU meter name identifies the plan, not the model. Token counts are exact from Azure Monitor or the response; a per-request dollar figure can only be estimated, from Anthropic's per-model token rates: https://aka.ms/ccu-pricing"
    }

    # Derive scope and deployment type from the deployment SKU.
    $scope = switch -Regex ($Sku) {
        'DataZone'  { 'DataZone'; break }
        'Global'    { 'Global';   break }
        default     { 'Regional' }
    }
    # Provisioned (PTU) is capacity billed per hour, not per token. There is no
    # per-token retail meter to find, so searching for one and returning NoMeter
    # would read as a coverage gap. Say what it actually is.
    if ($Sku -match 'Provisioned|PTU') {
        return New-Result 'BilledAsCapacity' $null $null `
            "SKU '$Sku' is provisioned throughput: billed per PTU per hour ('1/Hour'), not per token. Token counts are still useful for utilisation, but cost comes from the PTU reservation - not from this table."
    }

    $depType = switch -Regex ($Sku) {
        'Batch'    { 'Batch';     break }
        'Flex'     { 'Flex';      break }
        'Priority' { 'Priority';  break }
        default    { 'Standard' }
    }
    # The SKU cannot express Priority or Flex - both run on a Standard
    # deployment - so the response's service_tier overrides it. Without this a
    # Flex request is priced at twice its real rate and a Priority one too low
    # (Priority is 1.75x to 2.5x the Standard rate, depending on the model).
    switch ($ServiceTier) {
        'Priority' { $depType = 'Priority' }
        'Flex'     { $depType = 'Flex' }
    }

    # A fine-tuned model ('gpt-4.1-mini-2025-04-14.ft-<id>', or 'ft:<base>:...'
    # in OpenAI's own spelling) is not priced here. Left to the matcher it
    # resolves to its BASE model's meter - the version, variant and words are
    # all there - and comes back Priced, but it bills on separate fine-tuning
    # meters and, on Standard and Global Standard deployments, an hourly
    # hosting fee that accrues whether or not the deployment serves traffic.
    if ($ModelName -match '\.ft-|^ft:') {
        return New-Result 'NoMeter' $null $null `
            "'$ModelName' is a fine-tuned model, which this lookup does not price. Its tokens bill on separate fine-tuning meters - documented at the base model's per-token rate, which most Retail fine-tuning meters match but not all (the gpt-4o and gpt-4o-mini Developer-tier meters do not) - and Standard and Global Standard deployments also pay an hourly hosting fee whether or not they serve traffic (Developer tier does not). Take its cost from Cost Management. Do NOT bill this as zero."
    }

    # model-router has no rate of its own. Each request bills on the meters of
    # the model it was routed to, plus a router fee on every input token
    # ('Model Routers GL 1M Tokens', 'DZ' on Data Zone), which the Retail
    # Prices API publishes under serviceName 'Foundry Tools', so this table
    # does not carry it. Verified on a day's Cost Management records: the
    # router fee quantity equalled the router's total input tokens, and each
    # routed model billed on its own Global meters under the router deployment.
    if ($ModelName -eq 'model-router') {
        return New-Result 'NoMeter' $null $null `
            "model-router has no rate of its own. Each request bills on the meters of the model it was routed to - the 'model' field of the response, or the ModelName dimension of the Azure Monitor token metrics - plus a router fee on all of its input tokens ('Model Routers GL 1M Tokens', or 'DZ' on a Data Zone deployment), which the Retail Prices API publishes under serviceName 'Foundry Tools', not 'Foundry Models'. Price the routed model with this function and add the router fee. Do NOT bill this as zero."
    }

    # Narrow to this publisher's product family first. Version tokens collide
    # across vendors: a bare '3' (as in 'qwen3-32b') also appears in
    # 'o3 mini ... Tokens', which would produce a confident wrong price.
    if (-not $Publisher) {
        # An ABSENT publisher must refuse exactly like an unknown one. Matching
        # with no family filter lets a version token collide across
        # publishers and return a confident price from the wrong vendor:
        # 'MM3.5' (Mistral) matched 'GPT 5 Inpt Glbl' and was priced at $1.25
        # instead of its own $1.50. The publisher is always available from the
        # ARM deployment's properties.model.format - pass it.
        return New-Result 'UnknownPublisher' $null $null `
            "No -Publisher supplied. Version tokens collide across vendors (Mistral 'MM3.5' matches a GPT-5 meter), so no price is claimed. Resolve the publisher from the ARM deployment's properties.model.format and pass it."
    }
    if (-not $script:FamilyMap.ContainsKey($Publisher)) {
        return New-Result 'UnknownPublisher' $null $null `
            "Publisher '$Publisher' is not in the family map. No verdict claimed - add it rather than assuming a price."
    }

    # Models whose meter names cannot be derived from the model name are tied
    # to them by pattern: -MeterPattern, else $script:MeterAliases. A bad
    # pattern is a configuration error, not a pricing answer, so it throws.
    $pattern = if ($MeterPattern) { $MeterPattern } else { $script:MeterAliases[$ModelName] }
    if ($pattern) {
        try { [void][regex]::new($pattern) }
        catch {
            $source = if ($MeterPattern) { '-MeterPattern' } else { "`$script:MeterAliases['$ModelName']" }
            throw "$source '$pattern' is not a valid regular expression: $($_.Exception.GetBaseException().Message)"
        }
    }

    # Without a pattern the model is matched on its version token. A model
    # with none ('whisper') leaves nothing to discriminate
    # on: the variant filter alone would happily match any no-variant meter,
    # which is how such models were once priced from '5.5 ShortCo inp Gl' at
    # $5.00. Refuse instead.
    $verMatch = $null
    if (-not $pattern) {
        $verMatch = [regex]::Match($ModelName, '(?<![A-Za-z])([A-Za-z]?\d+(?:\.\d+)*[A-Za-z]*)')
        if (-not $verMatch.Success) {
            return New-Result 'NoMeter' $null $null `
                "Model '$ModelName' carries no version token, so it cannot be tied to its abbreviated meter names without guessing. If it has token meters, map them with -MeterPattern or in `$script:MeterAliases; models billed per audio minute, image, page or search have none. Do NOT bill this as zero."
        }
    }

    # Fireworks-hosted meters are a separate SKU with their own rates, so the
    # host must match the publisher rather than being hardcoded. Pinning this to
    # 'AzureDirect' made every model in the Fireworks family unreachable -
    # advertised in the family map but permanently NoMeter.
    $wantHost = if ($Publisher -eq 'Fireworks') { 'Fireworks' } else { 'AzureDirect' }
    $famRx = '^(?:' + (@($script:FamilyMap[$Publisher] | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
    $famEntries = $Table.Entries.Where({
        $_.ProductName -match $famRx -and $_.Host -eq $wantHost -and $_.Purpose -eq $Purpose
    })

    # A pattern names the model's meters outright. Otherwise keep the meters
    # of the model's own media kind: a transcription model must never match a
    # chat model's meters, or the reverse - gpt-4o-mini-transcribe was once
    # priced from the gpt-4o-mini chat meter at $0.15/1M, against its own
    # audio rate of $3.00.
    if ($pattern) {
        $famEntries = $famEntries.Where({ (ConvertTo-NormalizedMeterName $_.MeterName) -match $pattern })
    }
    else {
        $modelMedia = (Get-MediaAttributes $ModelName).MediaKind
        $famEntries = $famEntries.Where({ $_.MediaKind -eq $modelMedia })
    }

    # Token type. Without -Modality, Text is priced - unless meters of this
    # kind exist for another type. Then each type is looked up, and if the
    # model itself has a non-text meter the answer depends on which type the
    # tokens were: Ambiguous, with every type's price in the Note.
    if (-not $Modality) {
        if ($famEntries.Where({ $_.Kind -eq $Kind -and $_.Modality -and $_.Modality -ne 'Text' }, 'First').Count -gt 0) {
            $per = [ordered]@{}
            foreach ($t in 'Text', 'Audio', 'Image') { $per[$t] = Get-TokenPrice @PSBoundParameters -Modality $t }
            $found = @(foreach ($t in $per.Keys) { if ($per[$t].Status -ne 'NoMeter') { $t } })
            if ($found.Count -eq 0 -or ($found.Count -eq 1 -and $found[0] -eq 'Text')) { return $per['Text'] }
            $byType = @(foreach ($t in $per.Keys) {
                $r = $per[$t]
                if ($r.Status -eq 'Priced') { "$t `$$($r.PricePer1M)/1M ('$($r.MeterName)')" } else { "$t $($r.Status)" }
            }) -join '; '
            return New-Result 'Ambiguous' $null $null `
                "'$ModelName' bills $Kind tokens at a different rate per token type: $byType. Pass -Modality Text, Audio or Image, and price each type's tokens - reported separately in the usage object - in its own call."
        }
        $tokenType = 'Text'
    }

    $candidates = $famEntries.Where({
        $_.Kind           -eq $Kind        -and
        $_.Scope          -eq $scope       -and
        $_.ContextTier    -eq $ContextTier -and
        $_.DeploymentType -eq $depType     -and
        $_.Modality       -eq $tokenType
    })

    $tok = $null; $modelVariant = $null; $residual = @(); $narrowed = @(); $exact = @()
    if ($pattern) {
        $final       = @($candidates)
        $isThisModel = { param($e) $true }
    }
    else {
        # Narrow to this model. meterName carries abbreviations, not model IDs,
        # so match on the distinctive version token rather than the whole name.
        #
        # Substring matching is NOT safe here, in both directions:
        #   '20' from gpt-oss-20b is a substring of 'gpt-oss-120B'   -> a price
        #        for a model that has no inference meter at all
        #   '4'  from gpt-4o      is a token of    'gpt-4-turbo128K' -> 4x input,
        #        3x output
        #   '1'  from DeepSeek-R1 sits inside      'V3.1 Inp glbl'   -> 9% wrong
        #
        # So the token keeps BOTH a glued letter prefix and any trailing letters -
        # 'R1', 'V3.2', 'K2', 'o3', '4o', '20b' - because for these publishers the
        # letter is part of the version spelling, not a separate word. The match is
        # then anchored on both sides against digits, letters AND '.', so a token
        # can never match a fragment of a longer version.
        $tok      = $verMatch.Value
        $mkAnchor = { param($s) '(?<![0-9A-Za-z.])' + [regex]::Escape($s) + '(?![0-9A-Za-z.])' }
        $anchored = & $mkAnchor $tok
        # Flex-tier meters drop the dot from the version ('54 inp Flex Gl' for
        # gpt-5.4), so a dotted token can never reach them. Try the dot-stripped
        # form as a fallback - still anchored, so it cannot match a fragment.
        $alt = if ($tok -match '\.') { & $mkAnchor ($tok -replace '\.', '') } else { $null }

        # The variant sets must be equal: see $script:VariantAliases.
        $modelVariant = Get-VariantSet $ModelName

        # The model name's remaining words, each of which the meter name must
        # carry too: see $script:NoiseWords.
        $exempt = [System.Collections.Generic.HashSet[string]]::new([string[]] $script:NoiseWords)
        foreach ($v in $script:VariantAliases.Keys) {
            [void] $exempt.Add($v)
            foreach ($a in ($script:VariantAliases[$v] -split '[|\s]+')) { [void] $exempt.Add($a) }
        }
        $mediaWords = (@($script:MediaKindPatterns.Values) + @($script:TokenTypePatterns.Values)) -join '|'
        $residual = @((ConvertTo-MatchName $ModelName) -split '\s+' | Where-Object {
            $_ -match '^[a-z]+$' -and -not $exempt.Contains($_) -and $_ -notmatch $mediaWords
        })

        $isVersion = { param($e)
            $mn = ConvertTo-MatchName $e.MeterName
            ($mn -match $anchored) -or ($alt -and $mn -match $alt)
        }
        $isVariant = { param($e) (Get-VariantSet $e.MeterName) -eq $modelVariant }
        $missing   = { param($e)
            $mn = ConvertTo-MatchName $e.MeterName
            foreach ($w in $residual) { if ($mn -notmatch "(?<![a-z])$w(?![a-z])") { $w } }
        }
        $isThisModel = { param($e) (& $isVersion $e) -and (& $isVariant $e) -and @(& $missing $e).Count -eq 0 }

        # Each filter applies unconditionally. An earlier version did
        # `if ($exact) { $candidates = $exact }`, so an EMPTY result silently
        # bypassed the filter and left every variant meter in play - and a
        # base model could be priced from a variant's meter:
        #   gpt-5.3 -> '5.3 codex inp Gl'        (model has no variant, meter does)
        #   gpt-4o-mini -> 'gpt-4-turbo128K Inp' (model has a variant, meter does not)
        # An empty set means "no meter for this model", which is a NoMeter
        # answer, not a licence to guess.
        $narrowed = @($candidates.Where({ & $isVersion $_ }))
        $exact    = @($narrowed.Where({ & $isVariant $_ }))
        $final    = @($exact.Where({ @(& $missing $_).Count -eq 0 }))
    }

    if ($final.Count -eq 0) {
        $where = "scope=$scope tier=$ContextTier type=$depType kind=$Kind modality=$tokenType"

        # Distinguish a coverage gap from a query mismatch. If THIS model has
        # meters at a different scope, context tier or service tier, say so:
        # the newest models (5.5, 5.6, 6.x) have no Standard-context meter at
        # all and are priced only in Short/Long bands.
        $elsewhere = @($famEntries.Where({ $_.Kind -eq $Kind -and $_.Modality -eq $tokenType -and (& $isThisModel $_) }))
        $inference = @($elsewhere.Where({ $_.DeploymentType -ne 'FineTuned' }))
        if ($inference.Count -gt 0) {
            $scopes = ($inference.Scope          | Sort-Object -Unique) -join '/'
            $tiers  = ($inference.ContextTier    | Sort-Object -Unique) -join '/'
            $types  = ($inference.DeploymentType | Sort-Object -Unique) -join '/'
            return New-Result 'NoMeter' $null $null `
                "No meter for model=$ModelName at $where, but $($inference.Count) meters DO exist for it at scope=$scopes tier=$tiers type=$types. If the request ran at one of those, this is a query mismatch: pass the matching -ContextTier, -ServiceTier or -Sku (the newest models have no Standard context tier and must be priced as Short or Long). If it really ran as requested, this is a coverage gap. Do NOT bill this as zero."
        }
        # Some models are listed only for fine-tuning (gpt-oss-20b, qwen3-32b,
        # Ministral-3B): their base model has no inference price at all.
        if ($elsewhere.Count -gt 0) {
            return New-Result 'NoMeter' $null $null `
                "Only fine-tuning meters exist for model=$ModelName ($($elsewhere.Count), e.g. '$($elsewhere[0].MeterName)'): the base model has no published per-token $Kind price, and fine-tuned deployments are not priced by this lookup. Do NOT bill this as zero."
        }
        if (-not $pattern -and $exact.Count -gt 0) {
            $absent = @(foreach ($w in $residual) {
                $rx = "(?<![a-z])$w(?![a-z])"
                if ($exact.Where({ (ConvertTo-MatchName $_.MeterName) -match $rx }, 'First').Count -eq 0) { $w }
            })
            if ($absent.Count -eq 0) { $absent = $residual }
            $examples = @($exact | Select-Object -First 3 -ExpandProperty MeterName) -join ' | '
            return New-Result 'NoMeter' $null $null `
                "Version token '$tok' and the variant matched $($exact.Count) meter(s) at $where, but none carries '$($absent -join "', '")' from the model name: $examples. Those belong to another model of the same family (as Llama-4-Maverick's meters do to Llama-4-Scout), so no price is claimed. If one of them really is this model's, pin it with -MeterPattern. Do NOT bill this as zero."
        }
        if (-not $pattern -and $narrowed.Count -gt 0) {
            $offered = @($narrowed | Select-Object -First 4 -ExpandProperty MeterName) -join ' | '
            $want = if ($modelVariant) { "variant '$modelVariant'" } else { 'the base model (no variant)' }
            return New-Result 'NoMeter' $null $null `
                "Version token '$tok' matched $($narrowed.Count) meter(s) at $where, but none is for $want - closest were: $offered. Billing from a different variant can be an order of magnitude out, so no price is claimed. If one of them really is this model's, pin it with -MeterPattern. Do NOT bill this as zero."
        }
        if ($pattern) {
            $seen = if ($famEntries.Count -eq 0) { "It matches no $Publisher meter at all - check it against the Retail Prices API meter names." }
                    else { "It matches $($famEntries.Count) $Publisher meter(s), none a $tokenType $Kind meter; cached-input and cache-write meters are often missing." }
            return New-Result 'NoMeter' $null $null `
                "No meter for model=$ModelName matches meter pattern '$pattern' at $where. $seen Do NOT bill this as zero."
        }
        return New-Result 'NoMeter' $null $null `
            "No $Kind meter for model=$ModelName (version token '$tok') at $where. Models can be deployable and GA with no published price - cached-input and cache-write meters are the most often missing - or have meters whose names cannot be tied to the model name. Check the Retail Prices API; if the meters exist, pin them with -MeterPattern or add the model to `$script:MeterAliases. Models billed per audio minute, image, page or search have no token meter at all. Do NOT bill this as zero."
    }
    $candidates = $final

    if ($candidates.Count -gt 1 -and $ModelVersion) {
        # Dated meters: gpt-4o ships as 0513 / 0806 / 1120 and those prices
        # differ 2x ($5.00 vs $2.50). The model NAME cannot tell them apart, so
        # if the caller knows the deployed version, use it. Azure Monitor exposes
        # this as the ModelVersion dimension and the ARM catalog as Version.
        #
        # Catalog version strings are not uniform: '2024-11-20',
        # 'turbo-2024-04-09', '2024-08-06-preview', '001', 'latest'.
        # Pull the date from anywhere in the string rather than anchoring, and
        # say so when it cannot be used - the caller supplied disambiguating
        # information and deserves to know it was ignored.
        # Match the full yyyy-MM-dd. An unanchored (\d{2})-(\d{2}) scans
        # left to right and matches the WRONG pair: '2024-11-20' yields
        # '24-11' -> '2411', which matches no meter, so a caller who
        # correctly supplied the version silently got Ambiguous. gpt-4o
        # 0513 and 1120 differ 2x ($5.00 vs $2.50), so this is exactly the
        # case -ModelVersion exists to resolve.
        $mmdd = $null; $yyyy = $null
        if     ($ModelVersion -match '(\d{4})-(\d{2})-(\d{2})(?!\d)') { $yyyy = $Matches[1]; $mmdd = $Matches[2] + $Matches[3] }
        elseif ($ModelVersion -match '^\d{4}$')                       { $mmdd = $ModelVersion }
        if ($mmdd) {
            # Most dated meters carry MMDD ('0806'); 'chat latest' meters carry
            # MMDDYYYY ('08072025'), so the year may follow.
            $rx = if ($yyyy) { "(?<![0-9])$mmdd(?:$yyyy)?(?![0-9])" } else { "(?<![0-9])$mmdd(?![0-9])" }
            $dated = @($candidates.Where({ (ConvertTo-MatchName $_.MeterName) -match $rx }))
            if ($dated.Count -gt 0) { $candidates = $dated }
            else { Write-Verbose "ModelVersion '$ModelVersion' parsed to '$mmdd' but matched no meter; ignoring." }
        }
        else {
            Write-Warning "ModelVersion '$ModelVersion' is not in a form this lookup can use (expects YYYY-MM-DD or MMDD). Ignoring it - the result may be Ambiguous."
        }
    }

    if ($candidates.Count -gt 1) {
        $distinct = @($candidates.PricePer1M | Sort-Object -Unique)
        if ($distinct.Count -eq 1) {
            return New-Result 'Priced' $distinct[0] $candidates[0].MeterName `
                "$($candidates.Count) meters matched, all at the same price."
        }
        $hint = if (-not $ModelVersion) { ' If these are version-dated meters (e.g. 0513 / 0806 / 1120), pass -ModelVersion to pick one.' } else { '' }
        return New-Result 'Ambiguous' $null ($candidates.MeterName -join ' | ') `
            "$($candidates.Count) meters matched with $($distinct.Count) different prices: $($distinct -join ', '). Pin the right one with -MeterPattern rather than guessing.$hint"
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

        Each model is looked up the way it can actually be deployed: at the
        first of GlobalStandard, DataZoneStandard or Standard that it offers,
        and at the Standard context tier, then Short, then Long - the newest
        models are priced only in Short/Long bands, and checking Standard alone
        reported them as unpriced. A model that is Ambiguous across its dated
        meters is retried per catalog version, and only the versions that stay
        unresolved are listed.

        Only input is checked. A model that prices token types separately
        (realtime, audio, transcription, text-to-speech) counts as priced when
        any one of its types is; a type with no meter of its own is not listed
        here, and Get-TokenPrice -Modality refuses it. The catalog lists base
        models only, so fine-tuned models never appear: Get-TokenPrice does not
        price them.

        Statuses: NoMeter (no price - read the Note), BilledOutsideRetailAPI
        (Marketplace billing, e.g. Anthropic - expected), UnknownPublisher,
        Ambiguous. Treat the output as an operational alert, not a report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)] $Catalog   # from Get-FoundryModelCatalog
    )

    foreach ($m in $Catalog) {
        $skus = @(([string]$m.Skus) -split '\s*,\s*' | Where-Object { $_ })
        $sku  = @('GlobalStandard', 'DataZoneStandard', 'Standard' | Where-Object { $_ -in $skus })[0]
        if (-not $sku) { $sku = 'GlobalStandard' }

        $q = @{
            Table = $Table; ModelName = $m.Name; Publisher = $m.Publisher
            Sku = $sku; Kind = 'Input'
            ErrorAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue'
        }

        # Without -Modality, a model that prices token types separately is
        # Ambiguous. Take the first type that is priced, else the first that
        # has any meter.
        $lookup = {
            param($ct)
            $a = Get-TokenPrice @q -ContextTier $ct
            if ($a.Status -eq 'Ambiguous' -and -not $a.Modality) {
                $typed = foreach ($t in 'Text', 'Audio', 'Image') { Get-TokenPrice @q -ContextTier $ct -Modality $t }
                $a = $typed | Where-Object Status -eq 'Priced' | Select-Object -First 1
                if (-not $a) { $a = $typed | Where-Object Status -ne 'NoMeter' | Select-Object -First 1 }
            }
            $a
        }

        # Keep the first answer unless a later tier finds something better than
        # NoMeter - the Standard-tier note is the one that explains a real gap.
        $r = $null; $tier = $null
        foreach ($ct in 'Standard', 'Short', 'Long') {
            $try = & $lookup $ct
            if (-not $r -or $try.Status -ne 'NoMeter') { $r = $try; $tier = $ct }
            if ($try.Status -ne 'NoMeter') { break }
        }
        if ($r.Status -eq 'Priced') { continue }

        $results = @(
            if ($r.Status -eq 'Ambiguous') {
                $versions = @(([string]$m.Versions) -split '\s*,\s*' | Where-Object { $_ })
                if (-not $versions) { $versions = @($m.Version) }
                $vq = @{ ContextTier = $tier }
                if ($r.Modality) { $vq.Modality = $r.Modality }
                foreach ($v in $versions) {
                    $rv = Get-TokenPrice @q @vq -ModelVersion $v
                    if ($rv.Status -ne 'Priced') { @{ Version = $v; R = $rv } }
                }
            }
            else { @{ Version = $m.Version; R = $r } }
        )
        foreach ($x in $results) {
            [pscustomobject]@{
                Model     = $m.Name
                Version   = $x.Version
                Publisher = $m.Publisher
                Sku       = $sku
                Lifecycle = $m.Lifecycle
                Status    = $x.R.Status
                Note      = $x.R.Note
            }
        }
    }
}


function Measure-RequestCost {
    <#
    .SYNOPSIS
        Cost one metered request. Returns $null cost - never 0 - when any
        required price is unavailable.

    .DESCRIPTION
        Token counts follow the OpenAI usage object, where the prompt total
        INCLUDES its cached and cache-write parts:

            -InputTokens      usage.prompt_tokens
            -CachedTokens     usage.prompt_tokens_details.cached_tokens
            -CacheWriteTokens usage.prompt_tokens_details.cache_write_tokens
            -OutputTokens     usage.completion_tokens. OpenAI counts reasoning
                              inside it; grok-4.3 reports reasoning outside
                              it, and Azure billed completion_tokens alone
                              (verified against Cost Management, Oct 2026).

        Verified on gpt-6-astra against Cost Management: billed input + cached
        + cache-write quantities equal the summed prompt tokens exactly, so the
        standard-rate remainder is prompt - cached - write. A provider that
        reports the parts separately must be summed into -InputTokens first.

        Take -CachedTokens from the response, not from the Log Analytics usage
        log. For gpt-4.1-mini, gpt-5-mini, gpt-5.1, gpt-5.4 and gpt-5.4-mini
        the log records the raw cache hit, but only whole 128-token blocks of
        a hit of at least 1,024 tokens are billed at the cached rate; the
        response already reports that billed figure (verified).

        Pass the response's service_tier as -ServiceTier. Priority and Flex
        bill on their own meters - Priority at 1.75x to 2.5x the Standard
        rate depending on the model, Flex at half - and neither shows in the
        deployment SKU.

        Models that bill each token type at its own rate (realtime, audio,
        transcription, text-to-speech, image) are costed one type per call:
        pass -Modality with that type's counts, which their usage reports
        separately, and add the calls up. A kind with no tokens is not looked
        up, so a text-to-speech request is -Modality Text -InputTokens n plus
        -Modality Audio -OutputTokens m. Fine-tuned models are not priced:
        see Get-TokenPrice.

    .EXAMPLE
        Measure-RequestCost -Table $t -ModelName 'gpt-oss-120b' `
            -Publisher 'OpenAI-OSS' -Sku GlobalStandard `
            -InputTokens 1500 -OutputTokens 300

    .EXAMPLE
        # The newest models (5.5, 5.6, 6.x) have NO Standard-tier meter - they
        # are priced only in Short/Long context bands, which differ by 2x. You
        # must say which band the request fell into.
        Measure-RequestCost -Table $t -ModelName 'gpt-6-astra' `
            -Publisher 'OpenAI' -Sku GlobalStandard -ContextTier Short `
            -InputTokens 4000 -CacheWriteTokens 3800 -OutputTokens 500

    .EXAMPLE
        # Flex is chosen per request on a Standard deployment; only the
        # response's service_tier says it was applied.
        Measure-RequestCost -Table $t -ModelName 'gpt-5.6-sol' `
            -Publisher 'OpenAI' -Sku GlobalStandard -ContextTier Short `
            -ServiceTier Flex -InputTokens 1000 -OutputTokens 500

    .EXAMPLE
        # Embeddings bill input only.
        Measure-RequestCost -Table $t -ModelName 'text-embedding-3-small' `
            -Publisher 'OpenAI' -Sku GlobalStandard -InputTokens 2000

    .EXAMPLE
        # The audio tokens of a realtime response; its text tokens are a
        # second call with -Modality Text.
        Measure-RequestCost -Table $t -ModelName 'gpt-realtime-1.5' `
            -Publisher 'OpenAI' -Sku GlobalStandard -Modality Audio `
            -InputTokens 1200 -OutputTokens 800
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)][string] $ModelName,
        [string] $Publisher,
        [string] $Sku = 'GlobalStandard',
        [string] $ModelVersion,
        [ValidateSet('Standard','Long','Short')][string] $ContextTier = 'Standard',
        [ValidateSet('Text','Audio','Image')][string] $Modality,
        [ValidateSet('Standard','Default','Priority','Flex')][string] $ServiceTier,
        [string] $MeterPattern,
        # [long]: a day's or month's total for one deployment can pass the
        # 2.1 billion an [int] holds, and the binding then throws.
        [long] $InputTokens      = 0,
        [long] $CachedTokens     = 0,
        [long] $CacheWriteTokens = 0,
        [long] $OutputTokens     = 0
    )

    function New-Unpriced($status, $note) {
        [pscustomobject]@{
            ModelName   = $ModelName
            CostUSD     = $null          # explicitly null, never 0
            Status      = $status
            Note        = $note
            IsListPrice = $Table.IsListPrice
        }
    }

    # Validate before pricing, so bad counts are reported as bad counts rather
    # than hidden behind a price-lookup failure. An upstream parse bug or a -1
    # sentinel would otherwise emit a NEGATIVE invoice line reported as
    # 'Priced' - a credit nobody authorised.
    foreach ($leg in @(
        @{ n='InputTokens'; v=$InputTokens }, @{ n='OutputTokens'; v=$OutputTokens },
        @{ n='CachedTokens'; v=$CachedTokens }, @{ n='CacheWriteTokens'; v=$CacheWriteTokens })) {
        if ($leg.v -lt 0) {
            return New-Unpriced 'InvalidInput' `
                "$($leg.n) is negative ($($leg.v)). Token counts cannot be negative; this indicates an upstream parsing fault. No cost claimed."
        }
    }
    # Parts larger than the whole mean the caller passed an EXCLUSIVE input
    # count (cache already subtracted, or Anthropic-style input_tokens). Billing
    # it would charge the cached tokens twice, so refuse instead of clamping.
    if ($CachedTokens + $CacheWriteTokens -gt $InputTokens) {
        return New-Unpriced 'InvalidInput' `
            "CachedTokens ($CachedTokens) + CacheWriteTokens ($CacheWriteTokens) exceed InputTokens ($InputTokens). InputTokens must be the full prompt total INCLUDING its cached and cache-write parts (usage.prompt_tokens), not the remainder. No cost claimed."
    }

    $common = @{
        Table = $Table; ModelName = $ModelName; Publisher = $Publisher
        Sku = $Sku; ContextTier = $ContextTier
    }
    if ($ModelVersion) { $common.ModelVersion = $ModelVersion }
    if ($ServiceTier)  { $common.ServiceTier  = $ServiceTier }
    if ($Modality)     { $common.Modality     = $Modality }
    if ($MeterPattern) { $common.MeterPattern = $MeterPattern }

    # A kind is looked up only when there are tokens of it to bill: embedding
    # models have no output meter at all, and a text-to-speech model no audio
    # input meter, and requiring one made every such request Unpriced. Input
    # is still looked up when there are no tokens at all, so an unknown model
    # is never costed at 0.
    $inP  = if ($InputTokens -gt 0 -or $OutputTokens -eq 0) { Get-TokenPrice @common -Kind Input } else { $null }
    $outP = if ($OutputTokens -gt 0) { Get-TokenPrice @common -Kind Output } else { $null }

    # Cached input is optional. With no cached meter, cached tokens are billed
    # at the full input rate below - an upper bound, flagged by
    # CachedRateIsFallback, not a known price.
    $cacP = $null
    if ($CachedTokens -gt 0) {
        $cacP = Get-TokenPrice @common -Kind CachedInput
    }

    # Cache WRITE is a separate, far more expensive meter (verified 12.5x the
    # cache-read rate). If the caller reports write tokens we must not bill them
    # at the read rate, and we must not silently drop them either.
    $cwP = $null
    if ($CacheWriteTokens -gt 0) {
        $cwP = Get-TokenPrice @common -Kind CacheWrite
        if ($cwP.Status -ne 'Priced') {
            return New-Unpriced "Unpriced: cacheWrite=$($cwP.Status)" `
                "CacheWriteTokens were supplied but no cache-write meter resolved. Billing them at the read rate would understate cost by roughly 12x, so no cost is claimed. $($cwP.Note)"
        }
    }

    if (($inP -and $inP.Status -ne 'Priced') -or ($outP -and $outP.Status -ne 'Priced')) {
        $inStatus  = if ($inP)  { $inP.Status }  else { 'n/a' }
        $outStatus = if ($outP) { $outP.Status } else { 'n/a' }
        return New-Unpriced "Unpriced: input=$inStatus output=$outStatus" `
            (($inP.Note, $outP.Note | Where-Object { $_ } | Select-Object -Unique) -join ' / ')
    }

    # The standard-rate remainder excludes BOTH the cache reads and the cache
    # writes, which prompt_tokens includes. Subtracting only the reads billed
    # every written token twice: once at the input rate, again at the write
    # rate. Integer division is not a risk: PowerShell's / on integer operands
    # yields a double whenever the quotient is not whole, so 1000/1000000 is
    # 0.001 and not 0.
    $billableIn = $InputTokens - $CachedTokens - $CacheWriteTokens
    $cachedFallback = $CachedTokens -gt 0 -and $cacP.Status -ne 'Priced'
    $cachedRate = if ($CachedTokens -eq 0) { $null }
                  elseif ($cachedFallback) { $inP.PricePer1M }
                  else { $cacP.PricePer1M }
    $inRate     = if ($inP)  { $inP.PricePer1M }  else { $null }
    $cwRate     = if ($cwP)  { $cwP.PricePer1M }  else { $null }
    $outRate    = if ($outP) { $outP.PricePer1M } else { $null }

    $cost = 0.0
    if ($inP)                    { $cost += ($billableIn / 1000000 * $inRate) }
    if ($CachedTokens -gt 0)     { $cost += ($CachedTokens / 1000000 * $cachedRate) }
    if ($OutputTokens -gt 0)     { $cost += ($OutputTokens / 1000000 * $outRate) }
    if ($CacheWriteTokens -gt 0) { $cost += ($CacheWriteTokens / 1000000 * $cwRate) }

    $note = if ($cachedFallback) {
        "No cached-input meter resolved ($($cacP.Status)); cached tokens were billed at the full input rate, so CostUSD is an upper bound."
    }

    [pscustomobject]@{
        ModelName    = $ModelName
        CostUSD      = [math]::Round($cost, 8)
        Status       = 'Priced'
        ContextTier  = $ContextTier
        ServiceTier  = $(if ($ServiceTier) { $ServiceTier })
        Modality     = $(if ($inP) { $inP.Modality } else { $outP.Modality })
        InputRate1M  = $inRate
        CachedRate1M = $cachedRate
        CacheWriteRate1M = $cwRate
        OutputRate1M = $outRate
        CachedRateIsFallback = $cachedFallback
        Note         = $note
        IsListPrice  = $Table.IsListPrice
    }
}

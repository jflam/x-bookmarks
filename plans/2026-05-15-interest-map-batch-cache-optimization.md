# Interest Map Batch And Cache Optimization

Date: 2026-05-15
Status: proposed
Depends on:

- `plans/2026-05-15-interest-map-hardening-before-phase-two.md`
- `.nanoboss/procedures/xbookmarks/wiki-baseline-replay.ts`

## Purpose

Reduce repeated interest-map context cost during replay and future ingestion
without letting the map drift too far between decisions.

The immediate target is not a sharded interest map or long-lived unconstrained
agent session. The immediate target is a measurable efficiency pass:

- process sources in batches of 5;
- refresh the interest map between batches;
- make prompt prefixes cache-friendly;
- count tokens exactly with the OpenAI tokenizer instead of estimating from
  character counts;
- use a deterministic context-budget gate before each batch request;
- compact the rendered interest-map language;
- compare token, latency, and decision-drift results against the existing
  100-source replay.

## Baseline Evidence

The full replay artifacts from 2026-05-15 show the current bottleneck:

```text
.nanoboss/xbookmarks/runs/run-2026-05-15T15-14-36-070Z/baseline-replay-decisions.jsonl
.nanoboss/xbookmarks/runs/run-2026-05-15T15-14-36-070Z/baseline-replay-comparison.json
.nanoboss/xbookmarks/runs/run-2026-05-15T15-14-36-070Z/baseline-replay-comparison.md
```

Observed replay summary:

- sources replayed: 100;
- material differences: 85;
- matched-interest changes: 81;
- confidence changes: 4;
- deferral/status changes: 55;
- action changes: 40.

Approximate prompt composition from reconstructed prompts:

- total prompt text: about 5.7M chars;
- interest map per prompt: about 39k chars;
- repeated interest-map text over 100 sources: about 3.9M chars;
- rough repeated-map token cost: about 1M input tokens.

This means the current procedure repeatedly sends the same map for every source.
Even before larger map scaling, this is the dominant avoidable cost.

These are character-based estimates. The optimization pass should replace them
with exact local counts using a TypeScript/Bun-compatible OpenAI tokenizer with
the configured encoding for the active model.

## Design Goals

- Reduce repeated interest-map input tokens by at least 5x in replay mode.
- Keep map drift bounded by refreshing after every 5 decisions.
- Preserve dry-run non-mutating replay semantics.
- Preserve per-source comparison artifacts.
- Preserve enough isolation that one source's replay decision does not
  contaminate later decisions.
- Keep each batch request below a deterministic context-budget threshold.
- Measure the actual improvement rather than assuming batching helped.

## Non-Goals

- Do not implement interest-map shards in this pass.
- Do not change original `kb_ingest_decisions` rows.
- Do not replace the human-readable `wiki/meta/interest-map.md`.
- Do not run phase-two foundation or holdout ingestion.
- Do not make one 100-source mega-prompt.
- Do not rely on character-count approximations for implementation-time
  truncation or session-reset decisions.
- Do not use persistent conversation sessions in this pass.

## Workstream 1: Cache-Friendly Prompt Layout

Reorder sensemaking prompts so stable content appears in the prefix and
source-specific content appears after it.

Current effective shape:

```text
instructions
current source metadata
interest-map.md
prior-decisions.md
candidate-pages.json
source.md
```

Target shape:

```text
instructions
output contract / schema notes
interest-map.md
current source metadata
prior-decisions.md
candidate-pages.json
source.md
```

Reason:

Many provider prompt caches work on stable prefixes. If variable source metadata
appears before the interest map, the prefix changes on every call before the map
is reached, so the map is less likely to be cacheable. Putting stable
instructions and the stable map first makes the largest repeated block part of
the shared prefix.

This is different from a persistent session:

- cache-friendly requests still send the map, but provider-side prompt caching
  may reuse or discount the stable prefix;
- persistent sessions avoid resending the map, but the conversation grows and
  previous decisions can contaminate later decisions.

This pass will use cache-friendly fresh requests per batch, not persistent
sessions. That is the correct fit for refresh-after-each-batch ingestion:

```text
request 1: instructions + map A + sources 1-5
apply batch 1
refresh map -> map B
request 2: instructions + map B + sources 6-10
```

A persistent session would retain old maps in conversation history after refresh,
which is both wasteful and semantically risky.

Acceptance:

- `buildSensemakingPrompt` places `interest-map.md` before source-specific
  metadata and source markdown.
- Tests assert prompt ordering.
- Replay measurement records prompt-prefix size and estimated repeated-prefix
  savings.

## Workstream 2: Exact Token Counting And Context Budget

Use a TypeScript/Bun-compatible tokenizer package. Do not introduce a Python
runtime dependency for token counting.

Configuration should be explicit:

```text
model_context_window_tokens = 258400
tokenizer_encoding = o200k_base
```

The values should be configurable, but the initial default should match the
current OpenAI/Codex model environment.

Count these components separately:

```text
static_prefix_tokens =
  instructions
  + output contract / schema notes
  + interest-map snapshot

batch_payload_tokens =
  current source metadata
  + prior decisions
  + candidate pages
  + source markdown

output_reserve_tokens =
  output_reserve_per_source * source_count
```

Default budget policy:

```text
batch_size = 5
max_context_ratio = 0.50
output_reserve_per_source = 1200
safety_margin_ratio = 0.05
effective_context_budget =
  model_context_window * (max_context_ratio - safety_margin_ratio)
```

Before every batch request:

```text
next_request_tokens =
  static_prefix_tokens
  + batch_payload_tokens
  + output_reserve_tokens

if next_request_tokens > effective_context_budget:
  throw a budget error and stop
```

Do not auto-split, auto-truncate, or start a persistent-session reset path in
this pass. A budget error should include:

- batch source IDs;
- static prefix tokens;
- batch payload tokens;
- output reserve tokens;
- total request tokens;
- configured context window;
- effective budget.

Measured baseline payload from the 100-source replay, excluding the map:

```text
avg payload/source: ~4.2k estimated tokens
p90 payload/source: ~4.7k estimated tokens
max payload/source: ~8.4k estimated tokens
avg batch-size-5 payload: ~21k estimated tokens
max batch-size-5 payload: ~26k estimated tokens
```

These values must be recomputed with the tokenizer before enforcing limits.

Acceptance:

- Add a token-counting helper used by replay prompt construction.
- Replay artifacts include token counts for static prefix, each batch payload,
  output reserve, and total request estimate.
- Tests cover throw-on-over-budget behavior.
- Character-count fallback is allowed only for diagnostics, not enforcement.

## Workstream 3: Batch Size 5 Replay

Add a replay mode that asks for 5 source decisions per model call.

New command shape:

```bash
nanoboss xbookmarks/wiki-baseline-replay \
  --split wiki/meta/corpus-split.json \
  --limit 100 \
  --map wiki/meta/interest-map.md \
  --batch-size 5 \
  --dry-run \
  --write-comparison-report
```

Batch prompt shape:

```text
instructions
output contract / schema notes
interest-map.md
batch policy
sources[5]:
  - source metadata
  - prior decisions
  - candidate pages
  - source markdown
```

Model output shape:

```json
{
  "decisions": [
    {
      "source_id": "...",
      "decision": { "...": "KbSensemakingDecision" }
    }
  ]
}
```

Rules:

- require exactly one decision per selected source;
- normalize each decision independently;
- keep prior decisions attached per source for this pass, preserving existing
  behavior and keeping the comparison clean;
- compare each replayed decision with the original stored decision;
- write the same JSONL and comparison artifacts as the single-source replay;
- never write source pages or `kb_ingest_decisions` in replay mode.
- throw a detailed budget error if exact token counting shows a batch request
  would exceed the effective context budget.

Acceptance:

- Batch replay writes 100 JSONL lines for `--limit 100 --batch-size 5`.
- Comparison JSON has 100 records.
- SQLite `kb_ingest_decisions` count and status distribution remain unchanged.
- Tests cover batch output validation and non-mutation.
- Tests cover exact token-budget enforcement and the budget error shape.

## Workstream 4: Map Refresh Between Batches

For apply-mode ingestion, use fresh requests and refresh the interest map after
each 5-source batch.

For dry-run replay, do not mutate the map. Instead:

- use the current hardened map as the fixed replay context;
- record `map_revision_label` or map content hash in replay artifacts;
- report that map refresh would occur between apply batches, but was skipped
  because replay is non-mutating.

For future apply-mode ingestion:

```text
select next 5
load current map
count exact tokens
run batch sensemaking
apply decisions
refresh map
verify map
repeat
```

Acceptance:

- Batch replay remains non-mutating.
- Apply-mode procedures have an explicit `batchSize` option.
- Map refresh happens between applied batches, not after every source and not
  after the whole run.
- Each applied batch uses the latest verified map snapshot.

## Workstream 5: Compact Interest Map Rendering

Remove repeated filler from interest-map signals.

Current examples often repeat:

```text
John likely saved this because ...
John likely saved this as ...
The save may reflect interest in ...
```

Target signal style:

```text
early product signal around AI-native hardware: Rabbit/Vercel example links
dedicated assistant hardware to frontend/cloud infrastructure.
```

Rules:

- Signals should be noun-phrase or claim-first.
- Avoid repeated "John likely saved..." framing inside every signal.
- Keep source-grounded meaning; do not over-compress into vague labels.
- Keep descriptions concise enough for routing.
- Prefer compact fields over prose when possible.

Acceptance:

- New map renderer compacts generated text with deterministic cleanup rules.
- Existing phase-one decisions are not rewritten.
- Refreshed `interest-map.md` is shorter.
- Measurement reports exact map-token reduction before and after.

## Workstream 6: Measurement Harness

Add a deterministic measurement script or procedure output section for replay
cost estimates using exact tokenizer counts.

Measure before and after:

- number of model calls;
- sources per call;
- prompt chars total;
- interest-map chars sent total;
- exact static-prefix tokens;
- exact batch-payload tokens;
- output reserve tokens;
- actual output chars and exact output tokens where possible;
- provider-reported cached-token counts when available;
- wall-clock duration;
- material-difference count;
- status/confidence/action change counts.

Nanoboss telemetry research:

- `AgentTokenSnapshot` and `AgentTokenUsage` already include `cacheReadTokens`
  and `cacheWriteTokens`.
- `ctx.agent.run(...)` can return `tokenUsage` when the downstream ACP agent
  supplies a token snapshot.
- For Codex, Nanoboss merges ACP `usage_update` with ACP prompt-response usage.
  `usage_update` carries context-window size and used-context tokens; prompt
  response usage can carry `cachedReadTokens` and `cachedWriteTokens`.
- Therefore, replay measurement should record provider-reported
  `result.tokenUsage.cacheReadTokens` and `cacheWriteTokens` when present, but
  must not depend on those fields being present.
- Exact local tokenizer counts remain authoritative for budget checks because
  they are deterministic and available before the request is sent.

Target comparison:

```text
single-source replay: 100 calls, map repeated 100x
batch-size-5 replay: 20 calls, map repeated 20x
```

Expected result:

- repeated map context reduced about 5x from batching alone;
- additional savings from compact map rendering;
- possible further cache savings from stable prompt prefixes.

Acceptance:

- A post-run report states actual measured reduction.
- Report includes enough numbers to decide whether batch size should remain 5 or
  move to 10.
- Report distinguishes exact local token counts from provider-reported billing
  or cached-token counts.

## Open Questions

No blocking open questions remain before implementation.

Resolved decisions:

- Use fresh requests per batch, not persistent sessions.
- Use a fixed map snapshot for dry-run replay.
- Refresh and verify the map after every applied batch of 5.
- Keep batch size fixed at 5 for this pass.
- Throw and stop if a batch exceeds the exact token budget.
- Use a TypeScript/Bun tokenizer package, not Python.
- Configure context window and tokenizer encoding explicitly.
- Keep prior decisions per source for this pass.
- Record Nanoboss/provider cached-token telemetry when available, but use exact
  local tokenizer counts for all deterministic budget decisions.

## Initial Recommendation

Implement in this order:

1. Reorder prompt content so static map context appears before source-specific
   blocks.
2. Add exact token counting and the 50% context-budget policy.
3. Add `--batch-size 5` to baseline replay with typed batch output.
4. Add measurement fields to replay artifacts.
5. Compact interest-map signal rendering.
6. Re-run full 100-source dry-run replay and compare against
   `run-2026-05-15T15-14-36-070Z`.

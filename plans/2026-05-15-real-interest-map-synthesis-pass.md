# Real Interest Map Synthesis Pass

Date: 2026-05-15
Status: proposed
Depends on:

- `plans/2026-05-15-interest-map-batch-cache-optimization.md`
- `.nanoboss/procedures/xbookmarks/lib/interest-map.ts`
- `.nanoboss/procedures/xbookmarks/wiki-interest-map.ts`

## Purpose

Produce a qualitatively better `wiki/meta/interest-map.md`, not just a shorter
one.

The batch/cache optimization pass made replay more measurable and removed some
repeated filler from `Signals`. It did not meaningfully synthesize the map. In
particular, many `Description` fields still inherit first-source phrasing like
`John likely saved this because...` because the deterministic renderer currently
chooses:

```text
existingEntry.description
  OR first matched-interest evidence
  OR first why_saved
  OR "Inferred from baseline sources."
```

That is useful for source grounding, but it is not a real interest-map
synthesis. The next pass should rewrite entries into stable, compact routing
concepts using multiple source decisions per interest.

## Goals

- Rewrite interest descriptions as durable interest concepts, not source-level
  explanations.
- Improve interest names where current names are verbose, question-shaped, or
  accidental.
- Merge obvious duplicates and near-duplicates.
- Preserve source grounding through example source IDs and source-backed signal
  bullets.
- Preserve existing stable IDs where possible.
- Produce a reviewable preview before changing the live map.
- Keep the process deterministic around IO, validation, and reconciliation even
  though synthesis uses an LLM.

## Non-Goals

- Do not rewrite `kb_ingest_decisions`.
- Do not mutate raw source files.
- Do not blindly overwrite manually curated map fields.
- Do not infer interests from raw tweet text directly in this pass. Use stored
  decisions as the source of truth, with raw source links only for audit.
- Do not create a large free-form essay map. The output must remain structured
  and machine-parseable.

## Current Problem

The current map renderer groups stored decisions by matched interest and renders
each group mostly mechanically:

```text
interest_id -> name/status/description/signals/example_sources/confidence
```

This creates several quality issues:

- `Description` often reads like a single-source `why_saved` explanation.
- `Signals` repeat source-level framing.
- Some interests are too broad, such as `tools-and-technical-stacks`.
- Some interests are too verbose, such as long question-shaped names.
- Adjacent single-source interests are not consolidated.
- Related-interest edges are mostly empty.
- Parent/child hierarchy is mostly absent.

## Proposed Command

Add a synthesis mode to the interest-map procedure:

```bash
nanoboss xbookmarks/wiki-interest-map "synthesize --dry-run"
nanoboss xbookmarks/wiki-interest-map "synthesize --yes"
```

Options:

```text
--map wiki/meta/interest-map.md
--min-source-count 1
--max-entries 80
--chunk-size 12
--preserve-manual yes
--write-preview
```

Default behavior should be dry-run preview only.

## Output Artifacts

Dry run writes:

```text
.nanoboss/xbookmarks/runs/<run-id>/interest-map-synthesis-input.json
.nanoboss/xbookmarks/runs/<run-id>/interest-map-synthesis-plan.json
.nanoboss/xbookmarks/runs/<run-id>/interest-map-synthesis-preview.md
.nanoboss/xbookmarks/runs/<run-id>/interest-map-synthesis-diff.md
.nanoboss/xbookmarks/runs/<run-id>/interest-map-synthesis-verify.json
.nanoboss/xbookmarks/runs/<run-id>/interest-map-synthesis-report.md
```

Apply mode writes the live map only after validation passes.

## Data Model

Introduce a typed synthesis output separate from the final rendered map:

```ts
interface InterestMapSynthesisPlan {
  summary: string;
  entries: SynthesizedInterestEntry[];
  merges: Array<{
    from_interest_id: string;
    to_interest_id: string;
    rationale: string;
  }>;
  deprecated_interest_ids: Array<{
    interest_id: string;
    replacement_interest_id?: string;
    rationale: string;
  }>;
  open_questions: string[];
}

interface SynthesizedInterestEntry {
  interest_id: string;
  name: string;
  status: "active" | "emerging" | "deprecated";
  description: string;
  aliases: string[];
  parent_interest_id?: string;
  related_interest_ids: string[];
  source_ids: string[];
  representative_source_ids: string[];
  routing_signals: string[];
  boundaries: {
    include: string[];
    exclude: string[];
  };
  confidence: Record<"low" | "medium" | "high", number>;
  change_rationale: string;
}
```

The final renderer can convert this into the existing `InterestMapEntry` shape,
but the synthesis plan should keep richer review metadata.

## Algorithm

### Step 1: Build Evidence Packets

Read from SQLite:

```sql
SELECT source_id, raw_path, status, why_saved, matched_interests_json,
       non_obvious_connections_json, actions_json, confidence, defer_reason
FROM kb_ingest_decisions
ORDER BY source_id;
```

For each stored decision, derive a compact evidence packet:

```ts
interface SourceEvidencePacket {
  source_id: string;
  raw_path: string;
  status: string;
  why_saved: string;
  matched_interests: Array<{ interest: string; evidence: string; confidence: string }>;
  non_obvious_connections: string[];
  action_targets: string[];
  confidence: string;
  defer_reason?: string;
}
```

Do not include full raw source markdown in the default synthesis prompt. The map
should synthesize from the reviewed phase-one decisions, not redo source
understanding.

### Step 2: Normalize Candidate Interest IDs

Create initial candidate clusters from:

- existing map entries by `interest_id`;
- matched interests from stored decisions;
- action page/title targets where matched interests are missing;
- aliases and manual entries from the existing map.

Normalize with deterministic helpers:

```text
lowercase
trim
replace punctuation with spaces
collapse whitespace
slugify
map aliases to existing IDs
```

Keep a provenance table:

```ts
candidate_interest_id -> source_ids -> evidence packets
```

### Step 3: Compute Similarity Hints

Before using an LLM, compute deterministic hints:

- lexical overlap between names/descriptions/signals;
- shared source IDs;
- shared action target pages;
- shared non-obvious connection terms;
- parent/child candidates based on repeated prefixes or narrower terms.

This produces a `merge_candidates` list for the prompt. The LLM may propose
additional merges, but deterministic hints make the request more constrained.

### Step 4: Chunk Synthesis By Candidate Clusters

Use chunks of around 12 candidate interests. Each chunk includes:

- current entries for those interests;
- evidence packets for sources in those interests;
- candidate merge hints within the chunk;
- global list of existing stable IDs and names to avoid accidental duplicates;
- manual/seeded field markers.

Prompt each chunk to produce improved entries for that subset only.

Chunking keeps prompts smaller and makes review easier. It also avoids one giant
map rewrite where a single bad model response can damage the whole map.

### Step 5: Global Reconciliation Pass

After chunk-level synthesis, run one smaller global pass over compact synthesized
entries only:

```text
interest_id
name
description
source_count
routing_signals
aliases
related_interest_ids
parent_interest_id
```

Ask the model only to:

- detect cross-chunk duplicates;
- suggest merges;
- suggest missing parent/related edges;
- flag overly broad or overly narrow entries;
- flag names that are still source-specific or question-shaped.

Do not allow this pass to rewrite all prose freely. It should output a typed
patch list.

### Step 6: Deterministic Apply Of Synthesis Plan

Apply the typed plan deterministically:

1. Validate IDs are stable lowercase slugs.
2. Preserve manually seeded entries unless explicitly allowed.
3. Apply merges by moving source IDs and aliases to the target entry.
4. Deduplicate `source_ids`, `representative_source_ids`, aliases, and related
   IDs.
5. Ensure every non-deprecated entry has at least one source ID or is manually
   seeded.
6. Render `interest-map-synthesis-preview.md`.
7. Run the existing verifier against the preview content.
8. Write a human-readable diff report.

### Step 7: Apply Mode

Only after dry-run review:

```bash
nanoboss xbookmarks/wiki-interest-map "synthesize --yes"
```

Apply mode should:

- write `wiki/meta/interest-map.md`;
- upsert `kb_interest_map_entries`;
- insert `kb_interest_map_revisions`;
- run verifier;
- abort and restore the previous map if verifier fails.

## Prompt Design

### Chunk Synthesis Prompt

The chunk prompt should be strict and schema-first.

```text
You are synthesizing a durable personal interest map from reviewed X bookmark
sensemaking decisions.

Your task is not to summarize individual sources. Your task is to turn repeated
source-level evidence into stable routing concepts that help future ingestion
decide where a new source belongs.

Rewrite only the candidate interests in this chunk.

Rules:
- Descriptions must describe the user's durable interest, not why a single item
  was saved.
- Do not use phrases like "John likely saved this", "the save may reflect", or
  "this bookmark".
- Prefer noun phrases and product/research themes over questions.
- Keep existing stable interest_id values unless a merge or rename is clearly
  justified.
- Preserve manually seeded entries unless the input explicitly says they may be
  changed.
- Use source IDs only from the provided evidence.
- Representative sources should be the 3-5 most diagnostic examples, not just
  the first examples.
- Routing signals should be short claim-first bullets.
- Boundaries must say what belongs in the interest and what should not be routed
  there.
- Related interests are lateral links, not duplicates.
- Parent interests are broader categories.
- If evidence is weak or single-source, mark status "emerging".
- Return only typed JSON.
```

Input sections:

```text
## Existing Map Entries
<current entries in chunk>

## Evidence Packets
<source evidence packets grouped by candidate interest>

## Deterministic Merge Hints
<candidate duplicate pairs with overlap reasons>

## Global Interest ID Registry
<all existing interest_id/name pairs>

## Output Schema
<InterestMapSynthesisPlan chunk schema>
```

### Global Reconciliation Prompt

```text
You are reviewing synthesized interest-map entries for duplicate concepts,
missing hierarchy, and weak routing labels.

Do not rewrite every entry. Return a typed patch list only.

Look for:
- duplicates across chunks;
- entries that are too broad and should become parent interests;
- entries that are too narrow and should merge;
- descriptions that still sound like source summaries;
- missing related_interest_ids;
- name/alias improvements that preserve stable IDs.

Return only JSON patches against interest_id.
```

Patch shape:

```ts
interface InterestMapSynthesisPatch {
  merge?: Array<{ from_interest_id: string; to_interest_id: string; rationale: string }>;
  update?: Array<{
    interest_id: string;
    name?: string;
    description?: string;
    aliases?: string[];
    parent_interest_id?: string;
    related_interest_ids?: string[];
    routing_signals?: string[];
    boundaries?: { include: string[]; exclude: string[] };
    rationale: string;
  }>;
  warnings: string[];
}
```

## Validation Rules

Add synthesis-specific validation before rendering:

- `description` must not match:

```regex
/John likely saved|likely saved this|the save may reflect|this bookmark/i
```

- `routing_signals` must not match the same banned phrases.
- `description` should be 12-45 words.
- each `routing_signal` should be under 28 words where possible.
- every source ID must exist in `kb_ingest_decisions`.
- every representative source must be included in `source_ids`.
- every related/parent interest must exist or be deprecated with replacement.
- no duplicate aliases across active entries unless explicitly justified.
- no active entry can have zero evidence unless `manuallySeeded`.

If validation fails, write the invalid plan and fail without applying.

## Review Report

The dry-run report should lead with qualitative review data:

```text
Entries before/after
Merged entries
Renamed entries
Descriptions rewritten
Entries still failing banned-phrase validation
New parent/related edges
Broad entries left unchanged
Single-source emerging entries
Token count before/after
Verifier result
```

Also include a small before/after sample for each changed entry:

```text
### ai-coding-agent-context-management

Old description:
John likely saved this because...

New description:
Product and workflow patterns for managing planning, execution context, memory,
and resumption in AI coding agents.

Representative sources:
2012663636465254662, 2013111020466942198

Routing boundaries:
Include: coding-agent context windows, session resumption, plan handoff.
Exclude: generic AI productivity claims without agent workflow mechanics.
```

## Acceptance Criteria

- Dry run writes `interest-map-synthesis-preview.md` and does not mutate the live
  map.
- Preview contains no `John likely saved this`, `likely saved this`, or
  `the save may reflect` in `Description` or `Signals`.
- Preview has fewer vague entries such as `tools-and-technical-stacks` without
  routing boundaries.
- Report lists every merge, rename, description rewrite, and relationship change.
- Verifier passes against the preview.
- Apply mode only writes the live map after validation and verifier success.
- Existing `kb_ingest_decisions` rows are unchanged.

## Implementation Order

1. Add synthesis descriptors and validators.
2. Build evidence-packet extraction from SQLite.
3. Build deterministic candidate clustering and merge hints.
4. Add chunk synthesis prompt and typed output.
5. Add global reconciliation prompt and typed patch output.
6. Render preview map and diff report.
7. Add dry-run tests for banned phrase removal, merge application, and
   non-mutation.
8. Add apply-mode write path guarded by verifier success.

## Open Design Choice

The first implementation should use conservative chunk-level synthesis plus a
global patch pass. It should not ask one model call to rewrite the whole map.

The whole-map approach is simpler, but it makes failures harder to localize and
review. Chunked synthesis gives better auditability and lets us rerun only weak
chunks after review.

# Interest Map Hardening Before Phase Two

Date: 2026-05-15
Status: proposed
Depends on:

- `plans/2026-05-14-interest-aware-bookmark-sensemaking.md`
- `docs/interest-map-ingestion-flow.md`

## Purpose

Phase one produced a useful baseline:

- `wiki/meta/interest-map.md`;
- `kb_ingest_decisions` records in SQLite;
- rendered `## Ingest Decision` sections in 100 source pages;
- a baseline run report.

Before starting phase two foundation or holdout ingestion, harden the interest
map so it is a reliable routing artifact rather than a loose generated summary.

The goal is not to process more bookmarks. The goal is to make future ingestion
more stable, inspectable, deterministic, and responsive to human edits.

## Problem

The current map is good enough for phase-one inspection, but several weaknesses
will compound during phase two:

- interest headings are plain strings and can drift or duplicate;
- manual edits to `interest-map.md` are not parsed back into machine-readable
  state;
- SQLite stores decision records and revision metadata, but not normalized map
  entries;
- prior ingest decisions influence future ingestion mostly through the generated
  map, not through targeted retrieval;
- link correctness and map/source consistency are not enforced by a verifier;
- broad or weakly inferred clusters can become routing anchors for many future
  sources.

Phase two should not begin until these are addressed.

## Non-Goals

Do not process the remaining older corpus in this plan.

Do not run the most-recent-100 holdout experiment in this plan.

Do not implement daily ingestion in this plan.

Do not perform broad semantic-page synthesis in this plan.

Do not replace Markdown as the human-facing source of truth.

Do not change the meaning or schema of phase-one ingest decisions.

Do not rewrite existing `kb_ingest_decisions` rows or source-page
`## Ingest Decision` sections as part of normal map hardening.

The phase-one ingest decisions are input evidence for this plan. The hardening
work builds better map, verification, reconciliation, and retrieval layers on
top of those decisions.

## Desired End State

After this hardening pass:

- the interest map has stable interest IDs;
- example source links are valid Markdown links from `wiki/meta/interest-map.md`;
- a verifier checks map/source/SQLite consistency;
- map revision metadata contains a useful compact JSON summary;
- a normalized SQLite representation exists for interest map entries;
- manual map edits can be parsed and reconciled into machine-readable state;
- prior-decision retrieval is deterministic and testable;
- the current baseline map has been cleaned up enough to guide phase-two
  batches.

## Design Principle

Keep ownership split clearly:

```text
interest-map.md = human-editable routing artifact
kb_ingest_decisions = durable per-source decision log
kb_interest_map_entries = machine-readable map entry state
kb_interest_map_revisions = refresh metadata and compact summaries
```

The Markdown map should remain pleasant to read and edit. SQLite should make the
map testable, queryable, and useful for deterministic retrieval.

## Workstream 1: Stable Interest IDs

Add stable IDs for interests.

Current map shape:

```markdown
### Agentic Coding Workflows

- Description: ...
- Example sources: ...
```

Target map shape:

```markdown
### agentic-coding-workflows

- Name: Agentic Coding Workflows
- Status: active
- Description: ...
- Aliases: coding agents, AI coding workflows
- Example sources: [2013164033726120070](../../raw/x/ingested/2013164033726120070.md)
```

Rules:

- IDs are lowercase slugs.
- IDs should not change when display names improve.
- Merged/deprecated interests should retain redirect/alias metadata.
- Agent prompts should prefer IDs plus names, not names alone.

## Workstream 2: Normalized SQLite Map Entries

Add a normalized table for machine-readable interest map entries.

Suggested schema:

```sql
CREATE TABLE IF NOT EXISTS kb_interest_map_entries (
  interest_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL,
  aliases_json TEXT,
  parent_interest_id TEXT,
  example_sources_json TEXT,
  source_count INTEGER NOT NULL DEFAULT 0,
  confidence_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

The table should be refreshed from the Markdown map and/or generated decision
summary. It should not replace the Markdown file as the human-facing artifact.

## Workstream 3: Manual Edit Reconciliation

Support manual edits to `wiki/meta/interest-map.md`.

Add a parser that can read:

- interest IDs;
- display names;
- descriptions;
- aliases;
- statuses;
- parent/related interests;
- example sources;
- deprecated/merged entries.

Add a reconciliation command:

```bash
x-bookmarks kb interest-map reconcile --dry-run
x-bookmarks kb interest-map reconcile --yes
```

The dry run should show:

- new interest entries;
- renamed interests;
- alias changes;
- deprecated or merged interests;
- invalid source links;
- entries that cannot be parsed safely.

Manual edits should influence future ingestion through SQLite entry state and
through the Markdown map loaded into prompt context.

## Workstream 4: Map Verifier

Add a deterministic verifier:

```bash
x-bookmarks kb interest-map verify
```

Checks:

- every example source link resolves from `wiki/meta/interest-map.md`;
- every example source has a `kb_ingest_decisions` row;
- source counts in map entries match SQLite-derived counts;
- deferred-media counts match `kb_ingest_decisions`;
- recurring questions are deduped;
- no placeholder headings like `No strong match` appear as core interests;
- every interest has an ID, name, status, and description;
- every active interest has at least one example source or is explicitly marked
  as manually seeded.

Verifier output should be both human-readable and JSON:

```text
.nanoboss/xbookmarks/runs/<run-id>/interest-map-verify.md
.nanoboss/xbookmarks/runs/<run-id>/interest-map-verify.json
```

## Workstream 5: Prior-Decision Retrieval Policy

Add deterministic prior-decision retrieval before each future ingest.

Today prior decisions mostly influence ingestion indirectly through the generated
interest map. Phase two needs a more explicit retrieval step.

Add a helper:

```bash
x-bookmarks kb prior-decisions --source raw/x/ingested/ID.md --limit 12
```

And a Nanoboss/context function:

```ts
buildPriorDecisionContext(source, interestMap, limit)
```

Retrieval triggers:

- source keywords overlap with interest IDs, names, or aliases;
- source author has prior saved sources;
- source domains overlap with prior matched interests;
- current source appears media-primary or low-signal;
- proposed action would create a new interest similar to an existing one;
- candidate related pages imply a known interest;
- a batch has high low-confidence or high new-interest rate.

Retrieved context should include:

```text
source_id
raw_path
status
why_saved
matched_interests
non_obvious_connections
confidence
defer_reason
```

Constraints:

- cap retrieved decisions per source;
- prefer diversity across interests;
- keep examples short;
- include Markdown links to raw source pages;
- never let prior decisions override source-grounded understanding;
- record which prior decisions were included in run artifacts for auditability.

## Workstream 6: Interest Map Refresh Contract

Make `refreshInterestMap` explicitly deterministic and testable.

Rules:

- read `kb_ingest_decisions` in stable order;
- group by stable interest IDs where available;
- use Markdown links relative to `wiki/meta/interest-map.md`;
- preserve manual descriptions and names where possible;
- dedupe recurring questions;
- record a rich `summary_json` in `kb_interest_map_revisions`;
- run verifier after refresh.

Suggested revision summary shape:

```json
{
  "source_count": 100,
  "interest_count": 22,
  "deferred_media_inspection_count": 37,
  "recurring_question_count": 9,
  "interests": [
    {
      "interest_id": "agentic-coding-workflows",
      "name": "Agentic Coding Workflows",
      "source_count": 6,
      "example_sources": ["2013164033726120070"]
    }
  ]
}
```

## Workstream 7: Baseline Map Cleanup

Perform a human-inspectable cleanup of the current baseline map.

Use the hardened implementation from Workstreams 1-6 to regenerate the baseline
interest map from the existing 100 phase-one decisions. Do not rerun the 100
sources through the agent as the default cleanup path.

Input evidence:

- existing `kb_ingest_decisions` rows for the 100 baseline sources;
- existing source pages with `## Ingest Decision`;
- `wiki/meta/corpus-split.json`;
- current `wiki/meta/interest-map.md`.

Output:

- regenerated `wiki/meta/interest-map.md`;
- populated `kb_interest_map_entries`;
- updated `kb_interest_map_revisions`;
- verifier report;
- optional manual edits reconciled back into machine-readable state.

Tasks:

- merge duplicate or near-duplicate interests;
- rename broad generated labels;
- move open questions out of core interests;
- mark one-off or uncertain interests as `emerging`;
- keep media-primary deferrals separate;
- choose which baseline interests are strong enough to guide phase-two routing.

This should be done before processing the foundation corpus. Bad labels will
compound if they become routing anchors for hundreds of additional bookmarks.

## Workstream 8: Baseline Replay Experiment

Do not rerun phase-one ingestion by default. First, regenerate and clean the map
from existing decisions.

If it is unclear whether the hardened interest-map representation materially
changes ingest behavior, run a controlled replay experiment against the same 100
baseline sources.

A small shadow replay is required before this hardening plan can exit. Use 10-20
baseline sources selected from the existing `baseline_100` cohort. The sample
should include:

- at least a few clearly processed sources;
- at least a few `deferred_media_inspection` sources;
- at least one `ignored_low_signal` source if available;
- at least a few sources whose original decisions matched high-volume interests.

The shadow replay must be dry-run and comparative. It must not overwrite source
pages or `kb_ingest_decisions`.

Purpose:

- measure whether the hardened map changes matched interests;
- measure whether prior-decision retrieval improves or distorts `why_saved`;
- detect whether stable IDs reduce duplicate interest creation;
- compare deferral and low-signal behavior;
- evaluate whether richer map context changes semantic action proposals.

Replay mode must be non-destructive by default:

```bash
nanoboss xbookmarks/wiki-baseline-replay \
  --split wiki/meta/corpus-split.json \
  --limit 100 \
  --map wiki/meta/interest-map.md \
  --dry-run \
  --write-comparison-report
```

Replay output should be written to artifacts, not applied to source pages or
`kb_ingest_decisions`:

```text
.nanoboss/xbookmarks/runs/<run-id>/baseline-replay-decisions.jsonl
.nanoboss/xbookmarks/runs/<run-id>/baseline-replay-comparison.md
.nanoboss/xbookmarks/runs/<run-id>/baseline-replay-comparison.json
```

Compare each replayed decision with the original phase-one decision:

- `why_saved` semantic similarity and material differences;
- matched interest IDs and names;
- new/removed non-obvious connections;
- action kind changes;
- confidence changes;
- status changes, especially `deferred_media_inspection` and
  `ignored_low_signal`;
- whether prior-decision context was used and which rows were included.

Only after human review should any replayed decision replace an original
decision. Replacement should be a separate explicit migration, not part of map
hardening.

Experiment interpretation:

- If replay mostly changes labels while preserving `why_saved`, keep original
  decisions and only update map entries.
- If replay significantly improves source understanding or catches bad
  deferrals, consider a targeted migration for those sources.
- If replay creates new drift or overfits to the hardened map, keep the original
  decisions and tune retrieval/context limits before phase two.

## Workstream 9: Documentation

Update or add docs covering:

- interest map ingestion flow;
- SQLite/map ownership boundaries;
- manual-edit workflow;
- verifier usage;
- prior-decision retrieval policy;
- how phase-two procedures should use the hardened map.

Primary doc:

```text
docs/interest-map-ingestion-flow.md
```

## Suggested Implementation Order

1. Add Markdown-link verifier for `wiki/meta/interest-map.md`.
2. Add stable interest ID schema to the Markdown map.
3. Add `kb_interest_map_entries`.
4. Add map parser and reconcile dry run.
5. Update `refreshInterestMap` to preserve/reuse stable IDs.
6. Add prior-decision retrieval helper and context builder.
7. Add verifier enforcement after map refresh.
8. Clean up the baseline map.
9. Run the required 10-20 source shadow replay in dry-run mode.
10. Optionally run the full 100-source baseline replay in dry-run mode if the
   shadow replay shows material differences.
11. Re-run verifier and write a hardening report.

## Acceptance Criteria

This hardening plan is complete when:

- `wiki/meta/interest-map.md` has stable interest IDs;
- all example source links resolve;
- `kb_interest_map_entries` exists and is populated;
- `kb_interest_map_revisions.summary_json` contains useful structured summary
  data;
- manual edits can be parsed in dry-run mode;
- prior-decision retrieval can produce compact context for a given source;
- verifier passes on the current baseline map;
- a 10-20 source shadow replay has run in dry-run mode against the hardened map;
- the shadow replay produces comparison artifacts rather than mutating original
  decisions;
- the hardening report summarizes whether the hardened map materially changed
  matched interests, confidence, deferrals, ignored status, or proposed actions;
- if the shadow replay shows material differences, the plan records whether a
  full 100-source dry-run replay is recommended before phase two;
- tests cover map rendering, source-link validation, SQLite entry refresh, and
  prior-decision retrieval;
- no phase-two corpus or holdout ingestion has been started.

## Open Questions

- Should manually seeded interests be allowed before any source evidence exists?
- Should interest IDs be generated from names or assigned by a separate review
  step?
- Should deprecated interests remain visible in Markdown or only in SQLite?
- Should prior-decision retrieval be lexical only at first, or include embedding
  search later?
- How large should prior-decision context be for 5-source and 10-source batches?

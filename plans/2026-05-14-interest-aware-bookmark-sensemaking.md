# Phase One: Interest-Aware Bookmark Sensemaking Baseline

Date: 2026-05-14
Status: proposed
Owner: `x-bookmarks` CLI + `xbookmarks` Nanoboss procedure

## Implementation Principle

This phase must be implemented in small, inspectable slices. The core risk is
not whether the CLI can move files or store decisions. The core risk is whether
the system can reliably answer:

```text
Why did John save this, and what does it connect to?
```

That behavior cannot be designed perfectly upfront. It must be tuned against
real bookmarks. Therefore this phase must support:

- dry runs;
- small batches;
- visible decision previews;
- repeatable baseline runs;
- clear stopping points.

Do not build the full foundation build, holdout workflow, daily workflow, or
deep synthesis loop in this phase. Those belong in the phase-two plan.

## Hard Stop

The implementing agent must stop after this milestone:

1. Build the phase-one plumbing.
2. Reset the generated semantic wiki layer from the old implementation.
3. Select a deterministic baseline cohort of 100 bookmarks.
4. Run the new sensemaking ingestion over those 100 bookmarks.
5. Generate an initial `wiki/meta/interest-map.md`.
6. Render ingest decisions into source pages.
7. Store ingest decisions in SQLite.
8. Produce a concise run report.

After that, stop. Do not continue into full-corpus ingestion, held-out recent
bookmark experiments, daily ingestion, or deep synthesis. The next step is human
inspection of the baseline map and decisions.

## Problem

The current pipeline preserves X bookmarks well, but it does not reliably answer
the product question:

> Why did John think this bookmark was interesting?

Today the system is strongest at archival operations:

- sync bookmarks;
- expand threads;
- export raw Markdown;
- preserve media and provenance;
- move raw sources from inbox to ingested;
- update or create wiki pages.

That is necessary foundation, but it is not the desired experience. Ingestion
should be an act of sensemaking. For each new bookmark, the agent should infer:

- what the source is really saying;
- why it likely mattered to John;
- which existing interest areas it maps to;
- what non-obvious associations appear when compared with the existing wiki;
- what durable claim, example, caveat, question, or synthesis should be saved.

## Phase-One Goal

Build the smallest useful baseline system that can process 100 real bookmarks
and produce an inspectable first interest map.

The output of this phase is not a finished product. It is a baseline artifact
that lets us tune the sensemaking algorithm, prompts, retrieval policy, and
model behavior.

## Non-Goals

Do not ingest the full corpus in this phase.

Do not process the most recent 100 bookmarks as holdout experiments in this
phase.

Do not implement daily ingestion.

Do not implement deep synthesis, page merging, or broad wiki rewrites.

Do not build a negative-interest model. Assume that if John bookmarked
something, it was intentional.

Do not remove raw sources, media, SQLite bookmark state, thread expansion data,
or provenance notes.

## Semantic Reset

Start the semantic wiki over from scratch.

The existing generated wiki content should not be treated as valuable training
context for the new system. It was produced by the older archival/file-by-topic
workflow and is not aligned with the "why was this interesting?" product goal.

Scrub generated semantic content:

- `wiki/concepts`;
- `wiki/people`;
- `wiki/projects`;
- `wiki/tools`;
- `wiki/papers`;
- `wiki/companies`;
- `wiki/questions`;
- `wiki/syntheses`;
- generated indexes and logs that describe the old semantic wiki.

Preserve source and provenance content:

- raw X source Markdown under `raw/x`;
- downloaded media and asset metadata;
- SQLite bookmark, tweet, thread, and asset state;
- thread-expanded `## Source Text`;
- Obsidian bookmark/source notes as provenance.

## Baseline Cohort

Select a deterministic cohort of 100 bookmarks for the first baseline run.

The cohort should not be the most recent 100 bookmarks. Keep the most recent
100 available for later phase-two holdout experiments. The phase-one baseline
should use 100 older active bookmarks so the initial map can be inspected before
recent-bookmark evaluation.

Suggested split:

- `reserved_recent_holdout`: most recent 100 active bookmarks;
- `baseline_100`: 100 active bookmarks selected from the remaining older
  corpus;
- future `foundation_corpus`: the remaining older corpus not used in the first
  baseline, reserved for phase two.

Use a deterministic ordering and record it in a manifest:

```text
wiki/meta/corpus-split.json
```

The manifest should include:

- generated_at;
- total active bookmark count;
- reserved recent holdout IDs;
- baseline 100 IDs;
- ordering rule;
- any skipped/deferred IDs and reasons.

Open implementation choice for baseline selection:

- simplest: oldest 100 active bookmarks excluding recent holdout;
- better: deterministic spread sample across the older corpus.

Pick the simplest option unless there is an obvious local helper for a spread
sample.

## Source Processing Contract

Each source should pass through the same staged contract that future
incremental ingestion will use:

```text
source capture -> source understanding -> interest matching -> wiki action -> audit/render
```

### Source Capture

Use the existing raw X Markdown and `## Source Text` sections. Thread-expanded
bookmarks should provide the concatenated thread source text. Single-post
bookmarks should provide the root post text.

For image-primary bookmarks, if the text alone is insufficient and media has not
been inspected, mark the source:

```text
deferred_media_inspection
```

Do not create weak semantic pages from tweet text alone when the real claim is
inside an image, video, chart, or screenshot.

### Source Understanding

Produce a typed source understanding grounded only in the source:

```json
{
  "source_id": "2043828130960625958",
  "source_kind": "x_thread",
  "main_claims": ["..."],
  "examples": ["..."],
  "people_or_orgs": ["..."],
  "domains": ["housing", "architecture", "development finance"],
  "uncertainties": ["..."],
  "requires_media_inspection": false
}
```

### Interest Matching

Compare the source understanding against the current interest map. During the
first baseline batch, the map may be empty or skeletal. The agent should still
record inferred interests so the map can grow batch by batch.

Output:

```json
{
  "why_john_likely_saved_it": "...",
  "matched_interests": [
    {
      "interest": "housing supply and development constraints",
      "evidence": "The source explains why five-over-one apartment buildings converge on similar designs.",
      "confidence": "high"
    }
  ],
  "non_obvious_connections": [
    {
      "connection": "Design sameness is framed as finance/risk optimization, not merely bad taste or code compliance.",
      "related_pages": []
    }
  ]
}
```

### Wiki Action

Allowed phase-one actions:

- `create_new_page`;
- `add_evidence_to_page`;
- `create_or_update_open_question`;
- `defer_for_media_inspection`;
- `ignore_low_signal`.

Avoid broad rewrites. Prefer narrow, grounded pages over large synthesis pages.

### Audit And Render

Every processed source must get a visible decision section rendered back into
the source page:

```markdown
## Ingest Decision

- Why likely saved: ...
- Matched interests: [[...]], [[...]]
- Non-obvious connections: ...
- Actions taken: ...
- Confidence: ...
```

This source page section is part of the product. It is where a human or agent
should be able to answer:

```text
Why did John save this, and what does it connect to?
```

## Interest Map

Default ownership: agent-maintained.

Manual edits must be supported. John should be able to edit the interest map
directly when the agent gets it wrong, misses a recurring theme, or names an
interest poorly.

Canonical human-facing file:

```text
wiki/meta/interest-map.md
```

Markdown is the right phase-one default because:

- it is easy to inspect and manually edit;
- it fits the Obsidian/wiki workflow;
- agents can read it naturally;
- it can include compact explanations, examples, and links.

Use a stable section schema:

```markdown
# Interest Map

## Core Interests

### Housing Supply And Built Environment

- Description: ...
- Signals: ...
- Related pages: [[...]], [[...]]
- Example sources: [[../raw/x/ingested/...]]

## Recurring Questions

## People And Organizations

## Tools And Technical Stacks

## Aesthetic And Product Preferences

## Recently Emerging Interests
```

SQLite can store revision metadata and compact JSON summaries for retrieval,
but Markdown remains the editable source of truth for the map content.

## SQLite Data Model

Add machine-readable ingest state to SQLite.

```sql
CREATE TABLE IF NOT EXISTS kb_ingest_decisions (
  source_id TEXT PRIMARY KEY,
  raw_path TEXT NOT NULL,
  status TEXT NOT NULL,
  why_saved TEXT,
  matched_interests_json TEXT,
  non_obvious_connections_json TEXT,
  candidate_pages_json TEXT,
  actions_json TEXT,
  confidence TEXT,
  defer_reason TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

Add interest-map revision metadata:

```sql
CREATE TABLE IF NOT EXISTS kb_interest_map_revisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  revision_label TEXT,
  markdown_path TEXT NOT NULL,
  summary_json TEXT,
  source_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
```

## CLI And Procedure Surface

Add phase-one CLI helpers:

```bash
x-bookmarks kb corpus-split --baseline 100 --reserve-recent 100 --write wiki/meta/corpus-split.json
x-bookmarks kb reset-semantic-wiki --dry-run
x-bookmarks kb reset-semantic-wiki --yes
x-bookmarks kb source-status --source raw/x/inbox/ID.md
x-bookmarks kb sensemaking-context --source raw/x/inbox/ID.md
```

Add phase-one Nanoboss procedures:

```bash
nanoboss xbookmarks/wiki-sensemake-source --source raw/x/inbox/ID.md --dry-run
nanoboss xbookmarks/wiki-baseline-build --split wiki/meta/corpus-split.json --limit 100 --dry-run
nanoboss xbookmarks/wiki-baseline-build --split wiki/meta/corpus-split.json --limit 100 --yes
```

`wiki-baseline-build` should:

1. process only `baseline_100`;
2. run in small internal batches;
3. render decision previews;
4. apply decisions only in explicit `--yes` mode;
5. refresh `wiki/meta/interest-map.md` after each batch or batch group;
6. write a final run report;
7. stop.

## Prompt Contract

The sensemaking prompt should require these visible sections:

```markdown
## Source Understanding

## Why John Likely Saved This

## Existing Interest Matches

## Non-Obvious Connections

## Durable Takeaways

## Proposed Actions

## Confidence And Deferrals
```

The typed output should require:

- `source_understanding`;
- `why_saved`;
- `matched_interests`;
- `non_obvious_connections`;
- `durable_takeaways`;
- `actions`;
- `confidence`;
- `defer_reason` when applicable.

The prompt should explicitly allow:

- "I do not know why this was saved";
- "This appears low-signal";
- "This requires media inspection";
- "This should wait for a later synthesis pass."

## Phase-One Evaluation

After the baseline run, inspect:

- Is `wiki/meta/interest-map.md` recognizable as John's interests?
- Are interest names useful, stable, and not overfit to one source?
- Do source-page decisions answer why the bookmark was saved?
- Are non-obvious connections useful rather than forced?
- Did the system defer media-primary sources instead of hallucinating from weak
  text?
- Did it create too many pages?
- Did it create pages that are too broad?
- Are citations and backlinks correct?

The baseline run report should include:

- sources selected;
- sources processed;
- semantic pages created;
- semantic pages updated;
- decisions stored;
- sources ignored;
- sources deferred for media inspection;
- average confidence;
- prompt/model configuration used.

## Implementation Steps

1. Add the SQLite tables.
2. Add `corpus-split` generation for `baseline_100` and
   `reserved_recent_holdout`.
3. Add `reset-semantic-wiki` with `--dry-run` and `--yes`.
4. Add source status/context helpers.
5. Define the typed decision schema.
6. Implement source-page `## Ingest Decision` rendering.
7. Implement `wiki-sensemake-source` dry-run.
8. Implement `wiki-baseline-build` for 100 sources.
9. Run the baseline build.
10. Stop for human inspection.

## Success Criteria

This phase is successful when the 100-bookmark baseline produces:

- an initial editable interest map;
- source pages with useful ingest decisions;
- SQLite decision records;
- a clear run report;
- enough observable output to tune the next iteration.

It is not required to solve daily ingestion, full-corpus ingestion, or deep
synthesis in this phase.

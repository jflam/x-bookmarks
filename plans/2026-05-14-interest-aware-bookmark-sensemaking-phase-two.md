# Phase Two: Interest-Aware Bookmark Sensemaking Expansion

Date: 2026-05-14
Status: speculative
Depends on: `plans/2026-05-14-interest-aware-bookmark-sensemaking.md`

## Purpose

This plan covers work after the phase-one 100-bookmark baseline has been run
and inspected.

Do not implement this plan until phase one has produced:

- an initial `wiki/meta/interest-map.md`;
- SQLite ingest decision records;
- source pages with `## Ingest Decision`;
- a baseline run report;
- human feedback on the quality of the generated map and decisions.

The details below are intentionally tentative. They should be revised based on
what the baseline run teaches us.

## Phase-Two Goals

After baseline inspection, expand the system from a 100-bookmark pilot to a
durable ingestion workflow:

1. Process the remaining older foundation corpus.
2. Preserve the most recent 100 bookmarks as a holdout experiment set.
3. Run holdout ingestion in batches of 5 or 10 to tune quality and speed.
4. Promote the tuned workflow into daily incremental ingestion.
5. Add deep synthesis for deferred or cross-cutting work.

## Full Foundation Build

Process the remaining older corpus that was not part of the 100-bookmark
baseline and is not part of the most-recent-100 holdout.

Inputs:

- `wiki/meta/corpus-split.json`;
- the baseline interest map;
- baseline ingest decisions;
- remaining older raw sources;
- thread/media/source readiness status.

Behavior:

1. Process sources in deterministic batches.
2. Use the same decision schema as phase one.
3. Apply only justified semantic wiki actions.
4. Store decisions in SQLite.
5. Render decisions into source pages.
6. Refresh the interest map after each batch group.
7. Report quality and drift after each batch group.

The full foundation build may be slow and expensive. That is acceptable if the
decisions remain inspectable and resumable.

## Holdout Experiment Workflow

Use the most recent 100 bookmarks as the primary live evaluation set.

Run them in batches:

```bash
nanoboss xbookmarks/wiki-holdout-ingest --batch-size 5 --dry-run
nanoboss xbookmarks/wiki-holdout-ingest --batch-size 5 --yes
nanoboss xbookmarks/wiki-holdout-ingest --batch-size 10 --dry-run
```

Each batch should show:

- source IDs;
- why-saved decisions;
- matched interests;
- non-obvious connections;
- proposed actions;
- ignored/deferred sources;
- confidence distribution;
- estimated runtime/cost.

Use these batches to tune:

- prompt wording;
- retrieval scope;
- model choice;
- interest-map schema;
- non-obvious inference level;
- page creation vs page update policy;
- media-primary deferral behavior.

## Daily Ingestion

Only after holdout batches feel good should the system become a daily workflow.

Daily ingestion should:

- sync new bookmarks;
- expand threads where needed;
- export source Markdown;
- run sensemaking on new sources;
- update the interest map when appropriate;
- store decisions in SQLite;
- render source-page decisions;
- update review pages;
- report processed/ignored/deferred counts.

Daily mode should be bounded:

- small source count;
- limited candidate page reads;
- visible run report;
- no broad synthesis unless explicitly requested.

## Deep Synthesis

Deep mode handles work that should not happen during daily ingestion:

- revisit deferred media-primary sources;
- merge narrow pages;
- rewrite broad synthesis pages;
- refresh the interest map across many decisions;
- identify cross-source themes;
- consolidate repeated open questions;
- audit low-confidence decisions.

Deep mode may be slow and agent-heavy. It should still write durable decision
records and run reports.

## Future CLI And Procedure Surface

Potential commands and procedures:

```bash
nanoboss xbookmarks/wiki-foundation-build --resume
nanoboss xbookmarks/wiki-holdout-ingest --batch-size 5 --offset 0 --dry-run
nanoboss xbookmarks/wiki-daily-ingest --yes
nanoboss xbookmarks/wiki-interest-map-refresh --deep
nanoboss xbookmarks/wiki-deep-synthesis --topic TOPIC
```

Potential CLI helpers:

```bash
x-bookmarks kb decision-status
x-bookmarks kb decision-export --format jsonl
x-bookmarks kb deferred list
x-bookmarks kb deferred retry --reason media_inspection
```

## Open Questions For Phase Two

Answer after phase-one inspection:

- Is the interest-map Markdown schema good enough?
- Are source-page ingest decisions too verbose or too compact?
- How aggressive should non-obvious inference be?
- What batch size gives the best quality/speed tradeoff?
- How often should the interest map refresh?
- Should daily ingestion require review before apply?
- What media inspection path is good enough for visual sources?

## Success Criteria

Phase two is successful when:

- the full older corpus has been processed or explicitly deferred;
- the held-out most recent 100 bookmarks improve rather than degrade the map;
- daily ingestion is fast enough to run routinely;
- the interest map remains human-editable and recognizable;
- source-page decisions remain useful and auditable.


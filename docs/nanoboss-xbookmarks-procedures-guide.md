# Nanoboss X Bookmarks Procedures Guide

This guide is the detailed review and usage reference for the Nanoboss
procedures under:

```text
.nanoboss/procedures/xbookmarks/
```

The procedures maintain the managed Obsidian vault at:

```text
/Users/jflam/src/brain2/X Bookmarks
```

They are designed as an incremental self-improving system. New bookmark ingest,
weekly review generation, linting, and topic synthesis are separate operations
so each part can improve without forcing a full end-to-end rerun.

## Procedure Catalog

| Procedure | Purpose | Mutates vault? |
| --- | --- | --- |
| `xbookmarks/wiki-refresh` | Ingest raw inbox bookmarks into wiki pages with agent synthesis. | Apply mode only |
| `xbookmarks/wiki-topic-synthesis-refresh` | Improve existing topic pages from their cited evidence. | Apply mode only |
| `xbookmarks/wiki-build-reviews` | Generate deterministic source-date weekly review pages. | Apply mode only |
| `xbookmarks/wiki-lint` | Check wiki structure, links, citations, summaries, notes, and review pages. | No |
| `xbookmarks/wiki-select-batch` | Preview which raw inbox bookmarks would be processed. | No |
| `xbookmarks/wiki-apply` | Apply a saved `WikiIngestPlan` JSON payload. | Yes |

## Configuration

Run Nanoboss from the repo:

```bash
cd /Users/jflam/src/x-bookmarks
nanoboss cli
```

The procedure config lives at:

```text
.nanoboss/xbookmarks/config.json
```

Expected shape:

```json
{
  "workspaceRoot": "/Users/jflam/src/x-bookmarks",
  "managedRoot": "/Users/jflam/src/brain2/X Bookmarks",
  "xBookmarksBinary": "/Users/jflam/src/x-bookmarks/zig-out/bin/x-bookmarks",
  "xBookmarksHome": "/Users/jflam/src/x-bookmarks/data",
  "artifactRoot": ".nanoboss/xbookmarks/runs"
}
```

Normal procedure prompts should not repeat those paths. They are configuration,
not user input.

## Shared Concepts

`managedRoot` is the Obsidian vault subtree managed by the pipeline.

`artifactRoot` is where procedure context bundles, plans, dry-run previews, and
lint reports are written.

`WikiIngestPlan` is the typed intermediate representation returned by the agent:

```ts
{
  summary: string;
  operations: WikiOperation[];
  followUpSources: string[];
  relationshipCandidates: string[];
  spacedRepetitionCandidates: string[];
}
```

The agent proposes this JSON. Deterministic TypeScript validates and applies it.

Allowed operation kinds:

```text
create_page
update_page
update_review
update_map
ignore_source
append_log
```

Raw-source citations must preserve the audit trail:

```markdown
![](https://x.com/example/status/123)
[[../../raw/x/ingested/123|26-05-10 @example: readable source alias]] ^x-123
```

Review-page source entries intentionally use a different compact format:

```markdown
![](https://x.com/example/status/123)

[[../../raw/x/ingested/123|Captured bookmark]]

Wiki entries:
- [[../concepts/example-topic#^x-123|Example Topic]]
```

## `wiki-refresh`

Use `wiki-refresh` to turn new raw inbox bookmarks into durable wiki updates.

Entry point:

```text
/xbookmarks/wiki-refresh <natural-language request>
```

What it does:

1. Extracts typed intent from the user request.
2. Optionally runs the X sync/export binary.
3. Selects raw files from `raw/x/inbox`.
4. Builds an agent context bundle with raw sources, media paths, schema, index,
   maps, and related-page candidates.
5. Asks the agent for a `WikiIngestPlan`.
6. Previews or applies the plan.
7. Runs lint.
8. Optionally asks for a narrow repair plan.

Use it when:

- there are new raw bookmarks in `raw/x/inbox`;
- you want an agent to decide which durable pages to create or update;
- raw sources should move to `raw/x/ingested` or `raw/x/ignored` after success.

Do not use it when:

- you only want to improve already-created topic pages;
- you only want to rebuild weekly review pages;
- you only want to check the wiki.

Examples:

```text
/xbookmarks/wiki-refresh Dry run the next 5 exported bookmarks. Do not sync.
```

```text
/xbookmarks/wiki-refresh Process the next 5 exported bookmarks from the inbox.
```

```text
/xbookmarks/wiki-refresh Sync first, then dry run about 10 bookmarks.
```

```text
/xbookmarks/wiki-refresh Full sync first, then process 25 bookmarks.
```

```text
/xbookmarks/wiki-refresh Process the next 3 bookmarks without auto-repair.
```

Programmatic intent example:

```json
{
  "mode": "dry-run",
  "syncMode": "none",
  "limit": 5,
  "repair": true,
  "maxRepairAttempts": 1,
  "batchId": "manual-review",
  "rationale": "preview a small already-exported batch",
  "confidence": "high"
}
```

Expected output includes:

- selected source IDs;
- context bundle path;
- created/updated pages;
- updated maps and reviews;
- ingested, ignored, and unresolved source IDs;
- lint result;
- follow-up lists.

Main artifacts:

```text
.nanoboss/xbookmarks/runs/<run-id>/context/
.nanoboss/xbookmarks/runs/<run-id>/wiki-plan.json
.nanoboss/xbookmarks/runs/<run-id>/dry-run-operations.md
.nanoboss/xbookmarks/runs/<run-id>/lint.json
.nanoboss/xbookmarks/runs/<run-id>/lint.md
```

Review focus:

- confirm the selected raw sources are the intended batch;
- inspect `selected-media.md` for image-driven posts;
- inspect the proposed `WikiIngestPlan` before applying;
- check that new page summaries are synthesis, not source dumps;
- confirm raw sources moved only after lint passed.

## `wiki-topic-synthesis-refresh`

Use `wiki-topic-synthesis-refresh` to improve existing topic pages. This is the
stepping stone toward a self-improving wiki: once a weak topic page is noticed,
the system can rerun synthesis for that page without reingesting bookmarks.

Entry point:

```text
/xbookmarks/wiki-topic-synthesis-refresh <natural-language request>
```

What it does:

1. Extracts typed topic-refresh intent.
2. Selects explicit topic paths, or chooses high-priority mechanically repaired
   topic pages when no paths are provided.
3. If all-mode is requested, enumerates all durable topic pages and chunks them
   deterministically.
4. Builds one topic context bundle per chunk containing:
   - selected topic page Markdown;
   - all raw sources cited by those pages;
   - downloaded media references from those raw sources;
   - the wiki index.
5. Asks the agent for `update_page` operations for that chunk.
6. Applies or previews those updates.
7. Runs the same wiki linter after the chunk.
8. Writes per-chunk progress artifacts and continues to the next chunk if lint
   passes.

The procedure currently considers durable topic pages under:

```text
wiki/concepts/
wiki/tools/
wiki/projects/
wiki/questions/
```

It does not ingest new raw sources, does not move raw files, and does not update
weekly review pages.

Use it when:

- a topic page has a generic or mechanically repaired summary;
- a topic page has many evidence cards but weak analysis;
- an image-driven topic needs media-aware synthesis;
- review of a weekly page surfaces a bad or shallow linked topic.

Examples:

```text
/xbookmarks/wiki-topic-synthesis-refresh Dry run synthesis refresh for wiki/concepts/autonomous-driving-perception.md.
```

```text
/xbookmarks/wiki-topic-synthesis-refresh Apply synthesis refresh for wiki/concepts/agentic-coding-productivity-curve.md.
```

```text
/xbookmarks/wiki-topic-synthesis-refresh Dry run synthesis refresh for the next 3 topics.
```

```text
/xbookmarks/wiki-topic-synthesis-refresh Apply synthesis refresh for the next 2 mechanically repaired topics.
```

```text
/xbookmarks/wiki-topic-synthesis-refresh Dry run synthesis refresh for all topic pages in chunks of 5.
```

```text
/xbookmarks/wiki-topic-synthesis-refresh Apply synthesis refresh for all topic pages in chunks of 5.
```

Programmatic intent example:

```json
{
  "mode": "dry-run",
  "paths": [
    "wiki/concepts/autonomous-driving-perception.md"
  ],
  "limit": 1,
  "repair": true,
  "maxRepairAttempts": 1,
  "batchId": "topic-review-autonomous-driving",
  "rationale": "refresh one linked topic from its source trail",
  "confidence": "high"
}
```

Programmatic all-mode example:

```json
{
  "mode": "apply",
  "all": true,
  "chunkSize": 5,
  "repair": true,
  "maxRepairAttempts": 1,
  "batchId": "all-topic-synthesis-2026-05-14",
  "rationale": "stress test deterministic topic refresh over the whole wiki",
  "confidence": "high"
}
```

Expected page contract after refresh:

```markdown
# Topic Name

## Summary

Narrative synthesis that explains what this topic is about and why the evidence
belongs together.

## Notes

- Interpretive claims, caveats, review questions, or synthesis notes.
- No raw source cards here.

## Examples / Evidence

![](https://x.com/example/status/123)
[[../../raw/x/ingested/123|26-05-10 @example: readable source alias]] ^x-123
```

Review focus:

- verify the summary says something useful beyond naming the sources;
- check that media claims were grounded in `selected-media.md`;
- confirm all source cards and `^x-<tweet_id>` block IDs survived;
- check that `Notes` are interpretive, not merely another citation section;
- confirm lint passed after the rewrite.

All-mode review focus:

- confirm `all mode: yes` and the expected chunk size in the result display;
- inspect each chunk context under `.nanoboss/xbookmarks/runs/<batch>-chunk-NNN/`;
- confirm the number of agent calls equals the number of chunks;
- if a chunk fails lint, inspect that chunk's `wiki-plan.json`, `lint.md`, and
  `topic-synthesis-progress.json`;
- resume by running explicit paths for the remaining pages or by rerunning
  all-mode after fixing the failure.

## `wiki-build-reviews`

Use `wiki-build-reviews` to regenerate weekly review pages from processed raw
sources. It is deterministic and does not call an agent.

Entry point:

```text
/xbookmarks/wiki-build-reviews <natural-language request>
```

What it does:

1. Scans `raw/x/ingested` and `raw/x/ignored`.
2. Parses each source's original `created_at`.
3. Assigns each source to an ISO week.
4. Finds current wiki backlinks by source block ID.
5. Writes `wiki/reviews/YYYY-Www.md`.

Weekly review semantics are source-date based. For example:

```text
2026-W20 = May 11-17, 2026
```

That page should contain posts authored during that week, regardless of when the
agent processed them.

Examples:

```text
/xbookmarks/wiki-build-reviews Build dry-run review pages for the latest 8 weeks.
```

```text
/xbookmarks/wiki-build-reviews Regenerate all weekly review pages.
```

```text
/xbookmarks/wiki-build-reviews Rebuild 2026-W20 and overwrite existing pages.
```

Review focus:

- visible date range appears below the title;
- embedded posts are not bullet items;
- each source has a compact `Captured bookmark` or `Ignored bookmark` link;
- `Wiki entries:` is one linked page per bullet;
- linked wiki entries deep-link to the source block anchor;
- no out-of-range source dates appear.

## `wiki-lint`

Use `wiki-lint` before and after meaningful changes. It is deterministic and
does not mutate the vault.

Entry point:

```text
/xbookmarks/wiki-lint <natural-language request>
```

Example:

```text
/xbookmarks/wiki-lint Check the X bookmarks wiki for broken links and citation issues.
```

Important checks:

- raw-source links have readable aliases;
- raw-source targets resolve;
- source citations are standalone embed/link blocks;
- durable citations include `^x-<tweet_id>` block IDs;
- summaries are narrative and do not contain source cards;
- notes do not contain source cards;
- review source entries use the compact review format;
- weekly review pages contain only sources authored during their date range;
- plans update required index, map, and log surfaces.

Artifacts:

```text
.nanoboss/xbookmarks/runs/<run-id>/lint.json
.nanoboss/xbookmarks/runs/<run-id>/lint.md
```

Review focus:

- treat any error as blocking apply mode;
- warnings are review prompts, not necessarily blockers;
- when adding a new page shape, add a lint rule once the desired invariant is
  clear.

## `wiki-select-batch`

Use `wiki-select-batch` to see which raw inbox sources would be selected by
`wiki-refresh`.

Entry point:

```text
/xbookmarks/wiki-select-batch <natural-language request>
```

Examples:

```text
/xbookmarks/wiki-select-batch Show me the next 5 exported bookmarks that would be processed.
```

```text
/xbookmarks/wiki-select-batch Preview the next 10 inbox sources.
```

Selection order:

1. newest original post date;
2. exported metadata date;
3. tweet ID tie-breaker.

Review focus:

- use this when you want to confirm batch membership before a synthesis run;
- this does not sync X and does not move raw files.

## `wiki-apply`

Use `wiki-apply` to apply a saved JSON `WikiIngestPlan`. This is lower-level
than normal usage and should be used carefully.

Entry point:

```text
/xbookmarks/wiki-apply <JSON plan request>
```

Use it when:

- an agent or another procedure produced a plan artifact;
- you want deterministic application without rerunning synthesis;
- you understand which selected sources the plan references.

Avoid it when:

- you want natural-language topic refresh;
- you want normal inbox ingest;
- the plan has not been reviewed.

Review focus:

- validate the plan references only intended sources;
- check that raw-source paths and aliases match the target state;
- run `wiki-lint` after applying.

## Recommended Review Loops

Daily bookmark ingest:

```text
/xbookmarks/wiki-refresh Sync first, then dry run about 5 bookmarks.
/xbookmarks/wiki-refresh Process the next 5 exported bookmarks from the inbox.
/xbookmarks/wiki-build-reviews Regenerate affected weekly review pages.
/xbookmarks/wiki-lint Check the X bookmarks wiki.
```

Weekly human curation:

```text
/xbookmarks/wiki-build-reviews Regenerate all weekly review pages.
/xbookmarks/wiki-topic-synthesis-refresh Dry run synthesis refresh for wiki/concepts/<topic>.md.
/xbookmarks/wiki-topic-synthesis-refresh Apply synthesis refresh for wiki/concepts/<topic>.md.
/xbookmarks/wiki-lint Check the X bookmarks wiki.
```

Self-improvement after discovering a bad pattern:

```text
1. Capture the bad output shape in a doc or issue.
2. Update the prompt contract.
3. Add or tighten a lint rule.
4. Add a test.
5. Repair or refresh affected pages.
6. Regenerate review pages if backlinks or source formatting changed.
7. Run lint and tests.
```

This is the intended ratchet. The system should get stricter and more useful as
review discovers gaps.

## Current Known Gaps

The daily fast path is still a plan, not implemented command code. The current
`wiki-refresh` path is still agent-backed and can be too slow for frequent small
syncs.

Topic synthesis is bounded but still model-dependent. It improves one or a few
pages at a time, which is useful for review, but it is not yet an automatic
background quality scheduler.

Media inspection is represented in the context bundle through paths. The
procedure prompt requires media-aware analysis, but human review should still
check image-primary pages.

The linter is line-oriented. It enforces the page contracts discovered so far,
but it is not a full Markdown parser.

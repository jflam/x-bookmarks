# Nanoboss X Bookmarks Wiki Pipeline Narrative

This document is the code-review map for the Nanoboss X Bookmarks wiki pipeline
as it exists after the May 14 review fixes. It explains what the implementation
does, why the pieces are shaped this way, what changed during validation, and
where to focus review attention.

The shorter command-oriented reference and architecture diagram are in
[`docs/nanoboss-xbookmarks-wiki-procedure.md`](nanoboss-xbookmarks-wiki-procedure.md).
That diagram is still valid for the heavyweight `wiki-refresh` procedure:
Nanoboss extracts typed intent, optionally syncs/exports bookmarks, selects raw
sources, builds a context bundle, asks an agent for a typed plan, applies it
deterministically, lints, and optionally repairs.

The complete procedure guide, including examples for each procedure, is in
[`docs/nanoboss-xbookmarks-procedures-guide.md`](nanoboss-xbookmarks-procedures-guide.md).

The newest design work adds a separate plan for a faster daily path:
[`plans/2026-05-14-daily-incremental-bookmark-ingestion.md`](../plans/2026-05-14-daily-incremental-bookmark-ingestion.md).
That daily path is not implemented yet. It exists because the heavyweight
agent-synthesis path was too slow for a common "sync today's bookmarks" workflow.

## Executive Summary

The implementation turns exported X bookmarks in the real
`~/src/brain2/X Bookmarks` vault into an agent-maintained Obsidian wiki.

The core package lives under:

```text
.nanoboss/procedures/xbookmarks/
```

The main design choice is separation of duties:

- Nanoboss owns orchestration.
- The Zig binary owns X OAuth, sync, SQLite, media, and raw Markdown export.
- The agent owns synthesis only by returning typed JSON plans.
- Deterministic TypeScript owns file writes, raw-source moves, review-page
  generation, and lint checks.

That means the model can propose wiki changes, but it does not directly edit the
vault. The dangerous operations are normal code paths with validation and test
coverage.

## Current Size And Shape

Current implementation and test footprint:

- Procedure package files: 24
- Procedure/helper/prompt lines: 3,529
- Test file: 1
- Test lines: 634
- Daily optimization plan: 326 lines
- Command/reference doc: 277 lines
- Detailed procedures guide: 561 lines

Procedure entrypoints:

- `.nanoboss/procedures/xbookmarks/wiki-refresh.ts` - heavyweight agent-backed
  refresh flow.
- `.nanoboss/procedures/xbookmarks/wiki-select-batch.ts` - inspect selected raw
  inbox sources.
- `.nanoboss/procedures/xbookmarks/wiki-lint.ts` - run deterministic wiki checks.
- `.nanoboss/procedures/xbookmarks/wiki-apply.ts` - apply a saved JSON plan.
- `.nanoboss/procedures/xbookmarks/wiki-build-reviews.ts` - generate source-date
  review pages from processed raw sources and wiki backlinks.
- `.nanoboss/procedures/xbookmarks/wiki-topic-synthesis-refresh.ts` - refresh
  existing topic pages from their already-cited raw sources and media.

Most important helper modules:

- `lib/wiki-link-linter.ts` - citation, backlink, source-status, and review-page
  consistency checks.
- `lib/review-builder.ts` - deterministic source-date weekly review page
  generation.
- `lib/wiki-operations.ts` - validates and applies `WikiIngestPlan` operations.
- `lib/context-bundle.ts` - builds bounded agent context.
- `lib/topic-synthesis.ts` - selects topic pages and builds topic-level
  synthesis context bundles.
- `lib/config.ts` and `lib/xbookmarks-zig-adapter.ts` - connect Nanoboss to the
  local Zig importer and real vault paths.

## What Changed Recently

The first version produced useful wiki output, but review exposed several
semantic and UX problems. The recent work focused on making review pages useful
as curation surfaces.

The important changes:

- Weekly review pages now mean "posts authored during that week."
- `2026-W20` now means May 11-17, 2026, not "the batch processed during W20."
- Old broad backlog synthesis was moved out of the weekly namespace into
  `wiki/reviews/backlog-final-inbox-pass.md`.
- Review pages now show visible date ranges under the title.
- Review source entries use a cleaner Markdown format:
  - standalone X embed;
  - compact `Captured bookmark` or `Ignored bookmark` link;
  - one `Wiki entries:` bullet per backlink;
  - deep links to source anchors in durable wiki pages.
- Durable wiki pages now cite full source blocks with `^x-<tweet_id>` anchors
  instead of bulleted truncated source summaries.
- The linter now rejects weekly pages whose source dates fall outside the page's
  `period_start` and `period_end`.
- The linter now understands source-date review pages versus intentional backlog
  review pages.
- The real vault was regenerated so W19 contains May 10 posts and W20 contains
  May 11-12 posts from the newest sync.

This matters because your stated review model is chronological: human memory and
bookmark clusters are strongly time-correlated. The wiki should let you review
what you saw in that week, not what an agent happened to process in that week.

## Runtime Story

The heavyweight procedure is `/xbookmarks/wiki-refresh`.

For a prompt like:

```text
/xbookmarks/wiki-refresh Process the next 5 exported bookmarks from the inbox.
```

the flow is:

1. Nanoboss loads the repo-scoped procedure.
2. The procedure asks the downstream agent for a typed `RefreshIntent`.
3. Deterministic code normalizes that into `RefreshOptions`.
4. The procedure resolves the repo, vault, artifact root, Zig binary, and
   importer home.
5. Optional sync/export runs only if requested.
6. The next raw inbox files are selected deterministically.
7. A context bundle is written under `.nanoboss/xbookmarks/runs/<run>/context/`.
8. The downstream agent receives that bounded context and returns a typed
   `WikiIngestPlan`.
9. Deterministic code previews or applies the plan.
10. The linter checks links, citations, source status, plan completeness, and
    weekly review date consistency.
11. In apply mode, a bounded repair loop can ask for a replacement plan and
    rerun lint.
12. Nanoboss returns typed data, display text, artifact paths, and child-agent
    lineage.

The procedure is natural-language friendly at the front door, but strict after
intent extraction.

## Intent Extraction

Intent extraction is intentionally small. The first agent call does not see the
bookmark contents and does not write wiki prose. It only maps the human prompt
into a typed request:

```ts
{
  mode: "dry-run" | "apply",
  syncMode: "none" | "incremental" | "full",
  limit?: number,
  repair?: boolean,
  maxRepairAttempts?: number,
  batchId?: string,
  rationale: string,
  confidence: "low" | "medium" | "high"
}
```

Conservative defaults:

- Dry-run unless the request clearly asks to apply/process.
- No sync unless the request clearly asks to sync/fetch.
- Limit defaults to 5.
- Repair is off in dry-run and on in apply mode.
- Repair attempts are capped.

This is why ambiguous prompts should not mutate the vault.

## Configuration And Zig Adapter

The procedure resolves local configuration through `lib/config.ts`.

On this machine the working importer config is repo-local:

```text
/Users/jflam/src/x-bookmarks/data/config.json
```

The procedure passes:

```text
--home /Users/jflam/src/x-bookmarks/data
```

to the Zig binary because the global config is not the source of truth here.

The Zig adapter deliberately remains thin. It shells out to the existing binary
for:

- X bookmark sync;
- media download/reuse;
- folder sync;
- raw Markdown export;
- KB status.

That avoids reimplementing OAuth, SQLite state, media handling, quote-post
expansion, and raw-source export in the Nanoboss package.

## Batch Selection

`lib/raw-source.ts` reads:

```text
<managedRoot>/raw/x/inbox/*.md
```

and returns metadata-only `SelectedBookmark` records:

```ts
{
  sourceId,
  rawPath,
  tweetId,
  title,
  contentHash,
  authorHandle?,
  postedAt?,
  exportedAt?,
  canonicalUrl?
}
```

Selection order is deterministic:

1. newest original post date;
2. exported metadata date;
3. tweet ID as a tie-breaker.

This ordering is only for picking the next raw inbox batch. Weekly review pages
use each source's original `created_at` date to decide which week owns it.

## Context Bundle

`lib/context-bundle.ts` writes a bounded snapshot for the synthesis agent:

```text
<artifactRoot>/<run-id>/context/
  run.json
  selected-bookmarks.json
  selected-raw-sources.md
  selected-media.md
  wiki-index.md
  schema.md
  home.md
  this-week.md
  relevant-maps/
  candidate-related-pages.json
```

This is the main audit artifact for the model-facing part of the procedure. It
lets you inspect exactly what the agent saw before it proposed a plan.

The related-page search is simple local text matching. That is intentional. It
keeps the current procedure dependency-light and reviewable before adding
semantic retrieval.

Recent media fix: the bundle now also writes `selected-media.md`, a compact list
of downloaded media paths per selected source. The ingest prompt now explicitly
requires image inspection for image-driven posts, low-text posts, or sources
whose raw Markdown says `Media present`. If required media cannot be inspected,
the plan should say so in caveats instead of inventing the image's meaning.

## Agent Synthesis

The synthesis agent returns a `WikiIngestPlan`:

```ts
{
  summary,
  operations,
  followUpSources,
  relationshipCandidates,
  spacedRepetitionCandidates
}
```

Allowed operations:

- `create_page`
- `update_page`
- `update_review`
- `update_map`
- `ignore_source`
- `append_log`

The model decides content and relationships. It does not move raw files or write
directly to disk.

The recent performance issue was in this stage. For the 2026-05-14 incremental
batch, the agent selected the correct 5 sources and then idled during synthesis.
The raw files did not move and no plan was applied. That is why the new daily
optimization plan proposes a deterministic non-agent fast path for frequent
small imports.

## Apply And Raw Source Moves

`lib/wiki-operations.ts` validates and applies plans.

Rules:

- Every operation must use a known kind.
- Every referenced source ID must be from the selected batch.
- A source cannot be both ignored and cited.
- Ignored sources need a non-empty reason.
- Apply mode refuses unresolved selected sources.
- Wiki writes must stay under `managedRoot`.
- Run artifacts must stay under `artifactRoot`.

Raw-source moves are inferred from the plan:

- `ignore_source` moves a selected source to `raw/x/ignored/`.
- cited selected sources move to `raw/x/ingested/`.
- unresolved sources remain in inbox in dry-run, but fail apply mode.

Before moving, the applier updates raw frontmatter status to `ingested` or
`ignored`.

## Source-Date Review Pages

`lib/review-builder.ts` is now the deterministic source-trail generator.

It scans processed raw sources from:

```text
raw/x/ingested/
raw/x/ignored/
```

It parses each source's `created_at`, assigns the source to an ISO week, finds
current wiki backlinks by looking for source anchors such as:

```text
^x-2054229595977662649
```

and writes review pages such as:

```text
wiki/reviews/2026-W20.md
```

The page frontmatter includes:

```yaml
week: 2026-W20
period_start: 2026-05-11
period_end: 2026-05-17
source_count: 3
```

The visible page includes the human-readable range:

```markdown
# 2026-W20 Review

May 11-17, 2026
```

Each source renders like this:

```markdown
![](https://x.com/TasonJorres/status/2054229595977662649)

[[../../raw/x/ingested/2054229595977662649|Captured bookmark]]

Wiki entries:
- [[../concepts/ai-learning-friction#^x-2054229595977662649|AI Learning Friction]]
```

This format intentionally avoids bullets around the embedded post. The bullet
list is reserved for the thing that benefits from scanning: wiki backlinks.

## Linting

`lib/wiki-link-linter.ts` is the safety net.

It checks:

- raw-source links have readable aliases;
- raw-source targets resolve to real files;
- durable wiki source citations are standalone X embed/source-link blocks;
- durable source citations include `^x-<tweet_id>` anchors;
- durable topic summaries contain narrative prose and do not contain raw source
  cards;
- durable topic notes do not contain raw source cards;
- processed sources are not left in inbox;
- moved sources have correct raw frontmatter status;
- generated review pages use compact source-entry formatting;
- review wiki-entry bullets deep-link to source anchors;
- weekly source-date pages do not contain out-of-range sources;
- backlog review pages are allowed only when explicitly marked as backlog
  review pages;
- plans update `wiki/index.md` and `wiki/log.md` when durable pages are touched;
- plans update at least one map when durable pages are touched.

The linter is custom and line-oriented. That is a deliberate tradeoff for the
current rule set. If future checks need real Markdown block semantics, this is
one of the first files to revisit.

## Manual Validation Story

Validation was done against:

```text
/Users/jflam/src/brain2/X Bookmarks
```

Before the latest sync, the KB had:

```text
active bookmarks: 634
raw x inbox: 0
raw x ingested: 484
raw x ignored: 150
wiki pages: 170
```

The latest incremental sync found 5 new bookmarks:

- `2054229595977662649` - May 12, 2026, Jason Torres.
- `2053954791668367563` - May 11, 2026, Rhys Sullivan.
- `2053807198870880743` - May 11, 2026, Chris Hayduk.
- `2053570549725753799` - May 10, 2026, Nick Gerli.
- `2053504547847344449` - May 10, 2026, Brian Cardarella.

The X sync itself was fast:

```text
sync succeeded: pages=1 tweets=5 new_bookmarks=5 early_stop=true
```

Raw export wrote 5 files:

```text
kb raw X export: total=639 written=5 skipped=0 processed=634
```

The heavyweight Nanoboss refresh path then stalled in agent synthesis. I killed
that stuck dispatch and applied a bounded deterministic ingest for those 5
sources so the vault would be in the correct state for review.

The bounded ingest created:

- `wiki/concepts/ai-learning-friction.md`
- `wiki/concepts/codex-goal-mode-loop-design.md`
- `wiki/concepts/seattle-housing-inventory-shock.md`
- `wiki/concepts/agentic-coding-productivity-curve.md`

It updated:

- `wiki/concepts/agentic-supply-chain-security.md`
- `wiki/maps/agentic-software.md`
- `wiki/maps/policy-culture-and-society.md`
- `wiki/index.md`
- `wiki/log.md`

After review, `agentic-coding-productivity-curve.md` was corrected because the
initial manual recovery note had not inspected the downloaded image. The image
shows an exponentially decaying "Agentic Coding" productivity curve, so the page
now describes the visual claim directly instead of merely saying the post is
image-driven.

Then all source-date review pages were regenerated. The important result:

- `2026-W19` now includes the two May 10 posts.
- `2026-W20` now includes only the three May 11-12 posts.

Current KB state after the run:

```text
active bookmarks: 639
raw x inbox: 0
raw x ingested: 489
raw x ignored: 150
wiki pages: 174
```

Validation commands:

```bash
bun test
```

Result:

```text
9 pass
0 fail
```

Full wiki lint result:

```text
ok: true
errorCount: 0
warningCount: 0
```

## Performance Finding

The end-to-end run was too slow for daily use, but the cause was specific.

Observed timing:

- X sync: about 4.4 seconds.
- Raw export: effectively instant.
- Deterministic review rebuild: about 2.9 seconds.
- Wiki lint: about 0.1 seconds.
- Tests: about 0.7 seconds.
- Agent-backed `wiki-refresh`: stalled after selecting the 5 sources.

There are two conclusions:

1. The X API sync path is already reasonably fast, but the default
   `max_results=100` over-fetches for daily use.
2. The agent synthesis path is not acceptable as the default daily incremental
   ingest path.

The plan in
[`plans/2026-05-14-daily-incremental-bookmark-ingestion.md`](../plans/2026-05-14-daily-incremental-bookmark-ingestion.md)
proposes:

- `x-bookmarks daily`;
- default `--limit-pages 1 --max-results 25`;
- explicit estimated X read cost reporting;
- deterministic non-agent daily wiki ingest;
- affected-week-only review rebuild;
- stage timing output;
- under-60-second acceptance criteria.

That plan is pending review and implementation.

## Complexity Map For Code Review

Start with contracts:

```text
.nanoboss/procedures/xbookmarks/lib/types.ts
.nanoboss/procedures/xbookmarks/lib/descriptors.ts
```

Then review the heavyweight spine:

```text
.nanoboss/procedures/xbookmarks/wiki-refresh.ts
```

Read this as a finite-state workflow:

```text
intent -> config -> optional sync -> select -> context -> synthesis -> apply -> lint -> repair -> result
```

Then review deterministic safety and output code:

```text
.nanoboss/procedures/xbookmarks/lib/wiki-operations.ts
.nanoboss/procedures/xbookmarks/lib/wiki-link-linter.ts
.nanoboss/procedures/xbookmarks/lib/review-builder.ts
```

These files are the highest leverage and highest risk. They decide what gets
written, what gets rejected, and whether review pages match the intended
chronological semantics.

Medium-complexity files:

```text
.nanoboss/procedures/xbookmarks/lib/context-bundle.ts
.nanoboss/procedures/xbookmarks/lib/config.ts
.nanoboss/procedures/xbookmarks/lib/intent.ts
.nanoboss/procedures/xbookmarks/lib/prompts.ts
```

Lower-complexity files:

```text
.nanoboss/procedures/xbookmarks/wiki-select-batch.ts
.nanoboss/procedures/xbookmarks/wiki-lint.ts
.nanoboss/procedures/xbookmarks/wiki-apply.ts
.nanoboss/procedures/xbookmarks/wiki-build-reviews.ts
.nanoboss/procedures/xbookmarks/lib/raw-source.ts
.nanoboss/procedures/xbookmarks/lib/frontmatter.ts
.nanoboss/procedures/xbookmarks/lib/fs.ts
.nanoboss/procedures/xbookmarks/lib/xbookmarks-zig-adapter.ts
.nanoboss/procedures/xbookmarks/prompts/*.md
```

Finally read:

```text
tests/xbookmarks-procedure.test.ts
```

The tests now cover:

- selection, preview, lint, apply, and raw-source moves;
- rejection of unaliased raw-source links;
- rejection of source-only wiki summaries and source-only notes;
- compact review pages with wiki backlinks;
- explicit empty source-date weekly pages;
- `wiki-refresh` dry-run orchestration through fake typed agents;
- repair loop behavior.

## May 14 Narrative-Quality Pass

The latest review found another important gap: many older durable wiki pages
used `## Summary` and `## Notes` as places to dump raw tweet source blocks.
That technically preserved provenance, but it made the pages hard to review
because the summary did not explain what the sources meant.

I changed the pipeline contract in three places:

- the generation prompt now says `## Summary` must be narrative synthesis, not
  a citation dump;
- `## Notes` is reserved for interpretation, caveats, open questions, or review
  guidance;
- raw tweet/bookmark blocks belong in an evidence/source section where review
  pages can still deep-link to durable block IDs.

I then added linter rules for the concrete failure mode:

- `wiki-summary-source-block` rejects raw source cards in summaries;
- `wiki-summary-narrative-missing` rejects a summary that contains only raw
  source citation blocks;
- `wiki-notes-source-block` rejects raw source cards in notes;
- `wiki-notes-source-dump` rejects notes that are only unannotated source
  blocks.

The pre-repair lint found 209 errors across 108 durable wiki pages. I repaired
those pages by replacing source-only summaries with narrative text derived from
the current index descriptions, moving or preserving raw source cards in
evidence sections, and replacing source-only notes with review guidance. I also
cleaned up truncated summary prose inherited from the index catalog. A final
tightening pass removed the remaining raw source cards from summaries and notes
even when those sections also had explanatory text.

After the repair, I regenerated all 34 weekly review pages and reran the full
wiki lint. The final result was 0 errors and 0 warnings.

This is the pattern for pipeline self-improvement: when review discovers a
bad page shape, encode it in the prompt, add a deterministic lint rule, add a
test, repair the existing vault, and rerun the review builders. The next ingest
inherits the improved contract instead of relying on memory of the bug.

## Topic Synthesis Refresh Procedure

The next stepping stone is a separate topic-level procedure:

```text
xbookmarks/wiki-topic-synthesis-refresh
```

This procedure exists because the weekly review pages are only the curation
entry point. The durable topic pages are where the wiki should accumulate better
analysis over time.

The new procedure does not ingest new raw bookmarks. Instead it selects existing
durable pages under `wiki/concepts`, `wiki/tools`, `wiki/projects`, and
`wiki/questions`, bundles each page with the raw sources it already cites, adds
downloaded media references when present, and asks the agent to return typed
`update_page` operations. It then applies those updates through the same
`WikiIngestPlan` writer and lints the result.

The procedure now has an explicit all-mode loop. When the request says to
refresh all topic pages, deterministic code enumerates the durable topic set,
splits it into chunks, builds a separate context bundle per chunk, calls the
agent once per chunk, applies the result, runs lint, records progress, and then
continues. The agent never owns the outer loop; it only rewrites the bounded
chunk it is given.

This keeps self-improvement incremental:

- review finds a weak topic page;
- the topic path is passed to `wiki-topic-synthesis-refresh`;
- the agent rewrites only that page from its existing evidence trail;
- source cards, block IDs, and raw-source links are preserved;
- lint enforces the improved page contract;
- future review pages deep-link into better topic analysis.

The procedure can also run without explicit paths. In that mode it prioritizes
pages that still look mechanically repaired, such as pages containing generic
review guidance from the earlier bulk repair pass.

The automated tests verify both the one-page path and the all-mode chunk loop:
one test updates an existing topic page without moving raw sources, and another
creates three fixture topics, runs all-mode with chunk size two, and verifies
two agent calls, two context bundles, aggregate page updates, and a passing
lint result. The test count is now 9 passing tests.

## Areas To Be Skeptical About

The linter is line-oriented. It catches the failures seen so far, but it is not a
complete Markdown parser.

The related-page search is simple. It gives the synthesis agent useful local
context but is not semantic retrieval.

The heavyweight synthesis path is structurally bounded, but not latency-bound.
It can still stall or spend too much time on small batches. That is the main
reason the daily fast path is now planned separately.

The deterministic bounded ingest used for the May 14 live batch was a manual
recovery action, not yet a reusable command. Code review should treat the daily
plan as the next implementation step rather than assuming daily ingest is solved
in code.

Media analysis needs special review. Raw Markdown includes downloaded media
paths, and the context bundle now surfaces them separately, but reviewers should
check that image-primary sources produce claims grounded in the actual image.

The source-date review semantics are now enforced by lint, but review-builder
output should still be inspected carefully. This is a user-facing curation
surface, not just a generated report.

## What Changed Outside This Repo

Earlier validation also involved sibling workspaces:

1. Nanoboss source:

   ```text
   /Users/jflam/agentboss/workspaces/nanoboss/packages/app-support/src/disk-build-workspace.ts
   ```

   This fixed a concurrent disk-procedure build symlink race by treating
   `EEXIST` during overlay symlink creation as benign.

2. Brain2 vault:

   ```text
   /Users/jflam/src/brain2/X Bookmarks/
   ```

   The generated wiki and raw-source directories were updated during validation.
   Notable generated outputs include new source-date review pages, the current
   W19/W20 pages, and the four concept pages from the newest 5-bookmark ingest.

## Mental Model

Think of the implemented pipeline as a compiler:

- Raw X Markdown files are source files.
- The context bundle is the compiler input snapshot.
- The agent is the planner that proposes an intermediate representation.
- `WikiIngestPlan` is that intermediate representation.
- The applier is the code generator.
- The linter is the type checker.
- The Nanoboss run record is the build log.

The new daily plan adds a second mode to that mental model: a fast incremental
compiler pass. It should do the minimum deterministic work needed to keep the
wiki current each day, leaving deeper synthesis and refactoring to the heavier
agent-backed procedure.

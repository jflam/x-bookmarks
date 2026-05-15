# Daily Incremental Bookmark Ingestion Plan

Date: 2026-05-14

## Goal

Make the common daily workflow fast, cheap, and predictable:

```bash
x-bookmarks daily
```

The daily path should sync newly bookmarked X posts, export the changed raw Markdown sources, ingest them into the managed Obsidian wiki, rebuild affected source-date review pages, and run consistency checks in well under one minute for the normal case of 1-25 new bookmarks.

The daily path should not use the heavyweight Nanoboss agent synthesis loop by default. That loop remains useful for backlog processing and deep concept synthesis, but it is the wrong default for frequent incremental maintenance.

## Root Cause From 2026-05-14 Run

The slow end-to-end run was not caused by X sync or review generation.

Observed timing:

- X bookmark sync: about 4.4 seconds.
- Raw export: effectively instant; 5 changed bookmarks written.
- Deterministic review rebuild: about 2.9 seconds.
- Wiki lint: about 0.1 seconds.
- Test suite: about 0.7 seconds.
- Nanoboss `xbookmarks/wiki-refresh`: started, selected the 5 sources, spawned a child Codex agent, then idled before returning a typed plan. The raw files were not moved and no wiki changes were applied.

The root cause is that the frequent daily path currently depends on an open-ended agent-planning step with a large context bundle. For small batches, the agent can spend minutes reading large existing pages and still fail to return a plan. This makes runtime unpredictable and makes a simple daily ingest feel like a backlog curation job.

There is also a cost issue in sync defaults: `sync.max_results` is currently `100`, so a daily run with 3-5 new bookmarks still retrieves up to 100 posts from the X API before early-stop. At 0.1 cents per retrieved post, this is still small, but it is unnecessary daily spend.

## Product Decisions

- Add a dedicated daily incremental path instead of trying to make the backlog synthesis path do everything.
- Keep the existing full sync and Nanoboss wiki refresh commands for complete scans, backlog processing, and high-quality thematic synthesis.
- Default daily sync should fetch a small first page, not 100 posts.
- Daily ingest should be deterministic and bounded:
  - no open-ended agent child process;
  - no broad rewrite of large hub pages;
  - no full-vault concept synthesis;
  - no full review rebuild if only one or two week pages are affected.
- Every processed source must still get a durable wiki backlink so review pages can show:
  - embedded post;
  - captured or ignored raw bookmark;
  - one wiki entry per line, deep-linked to the source anchor.
- The weekly review semantics remain source-date based: a page such as `2026-W20` reviews posts authored during that week, not posts processed during that week.

## Non-Goals

- Do not solve perfect semantic clustering in the fast path.
- Do not make the fast path create polished narrative weekly briefs.
- Do not replace the deeper Nanoboss synthesis procedure.
- Do not call external web search or X APIs beyond the authenticated bookmark sync.
- Do not rewrite old concept pages unless a new source directly maps to an existing stable page.

## Proposed CLI

Add a top-level command:

```bash
x-bookmarks daily
```

Equivalent explicit form:

```bash
x-bookmarks sync --yolo --limit-pages 1 --max-results 25 --download-media
x-bookmarks kb export-raw-x --changed
nanoboss xbookmarks/wiki-daily-ingest
nanoboss xbookmarks/wiki-build-reviews --weeks affected --overwrite
nanoboss xbookmarks/wiki-lint
```

Useful options:

```bash
x-bookmarks daily --max-results 25
x-bookmarks daily --max-results 50
x-bookmarks daily --no-media
x-bookmarks daily --full-fallback
x-bookmarks daily --dry-run
x-bookmarks daily --no-lint
```

Suggested defaults:

- `--limit-pages 1`
- `--max-results 25`
- media policy follows config, currently images-only for Obsidian
- run lint
- rebuild only affected source-date weeks
- do not run tests by default

Fallback behavior:

- If page 1 contains no already-complete bookmark, report that the daily bounded sync may be incomplete.
- With `--full-fallback`, continue paging until early-stop or the configured full-sync cap.
- Without `--full-fallback`, stop after the bounded page and print the exact command to run for deeper sync.

## X API Cost Policy

Daily defaults should optimize for the common case: the user has bookmarked a handful of posts since the previous run.

With `max_results=25`, the common daily X bookmark read cost is capped at 25 retrieved posts per run unless fallback is enabled.

Approximate cost at 0.1 cents per retrieved post:

- `max_results=10`: up to 1 cent per daily run.
- `max_results=25`: up to 2.5 cents per daily run.
- `max_results=50`: up to 5 cents per daily run.
- current `max_results=100`: up to 10 cents per daily run.

Implementation should record and print:

- pages fetched;
- posts retrieved;
- new bookmarks found;
- early-stop used;
- estimated read cost;
- whether the run was complete or bounded.

Example output:

```text
daily sync: pages=1 posts_retrieved=25 new_bookmarks=5 early_stop=true estimated_x_read_cost=$0.025
```

## Fast Wiki Ingest Design

Add a new procedure or library entrypoint:

```text
xbookmarks/wiki-daily-ingest
```

This should be deterministic and programmatic, not agent-synthesized.

Inputs:

- raw sources from `raw/x/inbox`;
- existing wiki index;
- existing source anchors and backlinks;
- a small local routing table.

Outputs:

- created lightweight concept pages when no clear existing page exists;
- appended source blocks to existing concept pages when the route is obvious;
- updated maps only when a new page needs navigation;
- moved raw files from `raw/x/inbox` to `raw/x/ingested` or `raw/x/ignored`;
- a compact ingest log entry;
- affected source-date week IDs for review rebuild.

The fast path should prefer creating narrow pages over rewriting large hubs. A narrow page is acceptable if it gives the source a stable home and can be merged or resynthesized later by the heavier procedure.

Image-primary sources are an exception to the "create a narrow page" bias. If a
source's meaning depends on an attached image, the daily path must have an
explicit media-inspection result before creating or updating semantic wiki
content for that source. Without that result, defer the source instead of
writing a weak page.

Example narrow pages from the 2026-05-14 batch:

- `concepts/ai-learning-friction.md`
- `concepts/codex-goal-mode-loop-design.md`
- `concepts/seattle-housing-inventory-shock.md`
- `concepts/agentic-coding-productivity-curve.md`

The last example is also the cautionary example: the tweet text alone did not
contain the actual claim. The image showed an exponentially decaying productivity
curve titled "Agentic Coding." Future ingestion must inspect that image before
writing the page.

## Routing Rules

Start with a small deterministic router.

Inputs per source:

- author handle;
- full post text;
- article title and preview text when present;
- extracted URLs;
- media presence and downloaded image paths;
- existing wiki page titles and aliases.

Routing outputs:

- `ingest` with target page(s);
- `create_page` with suggested slug and title;
- `ignore` with reason;
- `needs_review` if no safe route exists or required media was not inspected.

Image-driven sources must be visually inspected before semantic routing when a
downloaded image is available. If the fast path cannot inspect the image, it
must leave the source in `needs_review`. It should not infer the meaning of an
image-only or image-primary post from tweet text alone.

The media-inspection result should be structured and persisted in the run
artifact, for example:

```json
{
  "sourceId": "2053504547847344449",
  "mediaKey": "3_2053504145206738949",
  "path": "/Users/jflam/src/x-bookmarks/data/assets/image/...",
  "status": "inspected",
  "summary": "Chart titled Agentic Coding. Productivity decays exponentially over time.",
  "textObserved": ["Agentic Coding", "productivity", "time"]
}
```

Daily ingest can use that structured result for routing and page text. If
`status` is `missing`, `unavailable`, or `not_inspected`, the source cannot be
semantically ingested by the fast path.

Initial deterministic rules:

- Package manager release-age/cooldown/security terms map to `agentic-supply-chain-security`.
- Codex goal-mode or `/goal` article terms map to `codex-goal-mode-loop-design`, creating it if absent.
- AI learning, feeling dumb, docs, debugging, and skill acquisition terms map to `ai-learning-friction`, creating it if absent.
- Seattle housing inventory terms map to `seattle-housing-inventory-shock`, creating it if absent.
- Agentic coding productivity curve terms map to `agentic-coding-productivity-curve`, creating it if absent.
- Pure memes, low-context media, or posts with unavailable core content can be ignored with a specific reason.

The router should be easy to extend with more rules after observing daily batches.

## Review Page Rebuild

Do not rebuild every review page by default.

The daily ingest can compute affected weeks from processed source `created_at` values:

- May 10, 2026 sources affect `2026-W19`.
- May 11-12, 2026 sources affect `2026-W20`.

Then call the review builder for only those weeks:

```text
buildReviewPages({ weeks: affectedWeeks, overwriteExisting: true })
```

The full rebuild remains available for migrations and validation.

Review page acceptance rules:

- Frontmatter has `week`, `period_start`, and `period_end`.
- Visible title includes both ISO week and date range.
- Every source belongs inside the page date range.
- Embedded post is standalone, not a bullet.
- Captured or ignored bookmark line is compact.
- Wiki entries are one-per-line bullets.
- Wiki-entry links deep-link to the source anchor, for example:

```markdown
- [[../concepts/ai-learning-friction#^x-2054229595977662649|AI Learning Friction]]
```

## Performance Targets

Normal daily case: 1-25 new bookmarks, early-stop on first page.

Target timing:

- Sync: under 10 seconds.
- Raw export: under 2 seconds.
- Fast ingest: under 15 seconds.
- Affected review rebuild: under 5 seconds.
- Wiki lint: under 5 seconds.
- Total: under 30 seconds.

Hard ceiling:

- Daily bounded run should warn if it exceeds 60 seconds.
- Any stage over 15 seconds should be shown in the timing summary.
- No child agent call is allowed in the default daily path.

## Telemetry And Diagnostics

Every daily run should print a stage timing table:

```text
daily summary:
  sync                 4.4s  pages=1 posts=25 new=5 early_stop=true
  export               0.1s  written=5
  ingest               3.8s  ingested=5 ignored=0 created_pages=4 updated_pages=1
  reviews              2.9s  weeks=2026-W19,2026-W20
  lint                 0.1s  errors=0 warnings=0
  total               11.3s
```

Also write a JSON run artifact under `.nanoboss/xbookmarks/runs/<run-id>/daily-summary.json` with the same fields.

## Implementation Plan

1. Add sync-cost and timing instrumentation.
   - Record `posts_retrieved` separately from `tweets_seen` and `new_bookmarks`.
   - Print estimated X read cost when a cost-per-post config value is present.
   - Include stage duration in daily output.

2. Add a bounded daily sync command.
   - Implement `x-bookmarks daily` or `x-bookmarks kb daily`.
   - Use `--limit-pages 1 --max-results 25` behavior by default.
   - Add `--full-fallback` for days with more bookmarks than fit on the first page.

3. Add deterministic daily wiki ingest.
   - Create a non-agent `xbookmarks/wiki-daily-ingest` procedure or direct library command.
   - Select all current `raw/x/inbox` sources, capped by a daily limit such as 50.
   - Build a per-source media manifest from raw Markdown `## Media` sections.
   - Run an image-inspection step for image-primary sources before routing.
   - Route sources using deterministic rules and existing wiki index data.
   - Defer image-primary sources to `needs_review` when media inspection is
     unavailable or inconclusive.
   - Apply changes through the existing `applyWikiPlan` machinery so raw moves and artifacts remain consistent.

4. Rebuild only affected weeks.
   - Compute week IDs from processed source `created_at`.
   - Call `buildReviewPages` with only those week IDs.
   - Preserve the existing full rebuild command for migrations.

5. Add tests.
   - Daily sync option parsing defaults to `max_results=25`, `limit_pages=1`.
   - Daily ingest creates narrow pages and source anchors without agent calls.
   - Daily ingest appends to an obvious existing page.
   - Image-primary daily ingest refuses semantic page creation without an
     inspected-media result.
   - Image-primary daily ingest can use an inspected-media result to create a
     grounded page summary.
   - Affected-week rebuild sends May 10 to W19 and May 11 to W20.
   - Linter rejects daily review pages with out-of-range source dates.

6. Update docs.
   - Document `x-bookmarks daily` as the normal daily workflow.
   - Document full sync/backlog synthesis as separate maintenance workflows.
   - Include API cost examples.

## Acceptance Criteria

- A daily run with 5 new bookmarks completes in under 60 seconds on the current machine.
- The default daily run fetches at most 25 X bookmark posts unless fallback is explicitly enabled.
- The command reports X pages fetched, posts retrieved, new bookmarks, early-stop status, and estimated cost.
- Raw inbox is empty after successful daily ingest.
- Image-primary sources are not semantically ingested unless downloaded image
  media was inspected and the inspection result is recorded.
- Image-primary sources without inspected media remain in a review/deferred
  state instead of becoming weak concept pages.
- New sources appear in the correct source-date review pages.
- No post outside a weekly page's date range appears on that weekly page.
- Review pages show compact captured/ignored bookmark links and one wiki entry per line.
- Wiki lint passes with zero errors.
- The normal daily path does not spawn a child agent.

## Open Questions

- Should daily default `max_results` be 10, 25, or 50?
- Should uncertain sources become narrow `needs-review` pages or move to `raw/x/ignored` with a low-confidence reason?
- Should the routing table live in code, config, or a wiki-managed YAML/Markdown file?
- Should the daily command be part of the Zig binary only, Nanoboss only, or both?
- Should `--download-media` remain enabled by default for daily runs, or should daily runs sync metadata first and lazily download media only for rendered posts?

## Recommended First Cut

Implement both surfaces:

- `x-bookmarks daily` as the user-facing command.
- `xbookmarks/wiki-daily-ingest` as the reusable Nanoboss procedure behind the wiki step.

Use `max_results=25` by default. This gives a reasonable daily buffer while cutting default X API retrieval by 75% compared with the current 100-post page.

Keep the fast path intentionally conservative: create narrow pages when unsure, preserve source anchors, and let the heavier backlog synthesis procedure periodically merge or refine pages when the user wants deeper curation.

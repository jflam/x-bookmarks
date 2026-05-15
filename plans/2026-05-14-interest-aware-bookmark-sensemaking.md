# Interest-Aware Bookmark Sensemaking Plan

Date: 2026-05-14
Status: proposed
Owner: `x-bookmarks` CLI + `xbookmarks` Nanoboss procedure

## Implementation Principle

This project must be implemented in slices that let us tune the sensemaking
algorithm, prompts, retrieval strategy, and model behavior incrementally.

The core risk is not whether the CLI can move files or store decisions. The
core risk is whether the system can reliably answer:

```text
Why did John save this, and what does it connect to?
```

That behavior cannot be designed perfectly upfront. It must be tuned against
real bookmarks, especially the held-out most recent 100. Therefore every major
piece should support dry runs, small batches, visible decision previews, and
repeatable evaluation.

Do not implement the whole foundation build, holdout ingest, interest-map
refresh, and wiki-apply loop as one opaque pipeline. Build the machinery so we
can inspect and adjust each step:

1. source understanding;
2. interest matching;
3. non-obvious association;
4. proposed wiki actions;
5. source-page decision rendering;
6. interest-map refresh.

The first implementation slice should focus on stable plumbing and observable
artifacts:

- corpus split manifest;
- clean-slate semantic wiki reset;
- SQLite decision tables;
- source-page `## Ingest Decision` rendering;
- typed decision schema;
- dry-run single-source sensemaking scaffold;
- tests for split/reset/schema/rendering.

Only after those pieces are inspectable should we scale to foundation batches,
interest-map refresh, holdout batches, and daily ingestion.

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

The current implementation can still produce shallow or mechanical updates
because it asks "where do I file this?" too early, before asking "why is this
interesting in the context of this person's accumulated interests?"

## Goal

Redesign bookmark ingestion around an explicit interest-aware sensemaking pass.

The target behavior:

1. Read the source faithfully, including thread-expanded `## Source Text`.
2. Compare it against a compact model of John's existing interests.
3. Retrieve a small, relevant set of wiki pages.
4. Produce a concise ingest decision explaining why the source matters.
5. Apply only the wiki changes justified by that decision.
6. Log the decision so failures are auditable and future agents learn from it.

The agent should behave less like a filing clerk and more like a research
analyst with memory.

## Reset Strategy

Start the semantic wiki over from scratch.

The existing generated wiki content should not be treated as valuable training
context for the new system. It was produced by the older archival/file-by-topic
workflow and is not yet aligned with the "why was this interesting?" product
goal.

Scrub:

- `wiki/concepts`;
- `wiki/people`;
- `wiki/projects`;
- `wiki/tools`;
- `wiki/papers`;
- `wiki/companies`;
- `wiki/questions`;
- `wiki/syntheses`;
- generated indexes and logs that describe the old semantic wiki.

Preserve:

- raw X source Markdown under `raw/x`;
- source status where useful, though sources may need to be marked ready for
  semantic reprocessing;
- downloaded media and asset metadata;
- SQLite bookmark, tweet, thread, and asset state;
- thread-expanded `## Source Text`;
- Obsidian bookmark/source notes as provenance.

The point is to rebuild the semantic layer, not to throw away the captured
source archive.

## Backlog And Holdout Split

Use the full existing bookmark corpus to bootstrap the system, but reserve the
most recent 100 bookmarks as a holdout set.

Suggested split:

- `foundation_corpus`: all active bookmarks except the most recent 100;
- `holdout_corpus`: the most recent 100 active bookmarks by bookmark order;
- `experiment_batches`: 5-10 bookmarks at a time drawn from the holdout corpus,
  oldest-to-newest within the holdout unless we explicitly want a different
  evaluation order.

The exact "most recent" ordering should be deterministic and should match the
bookmark ingestion order used elsewhere:

```sql
ORDER BY b.import_position IS NULL,
         b.import_position,
         b.last_seen_at DESC,
         b.tweet_id DESC
```

If this ordering proves counterintuitive, add an explicit `bookmarked_at` or
`last_seen_at` based split command and record the chosen split in a manifest.

Example manifest:

```text
wiki/meta/corpus-split.json
```

It should include:

- generated_at;
- total active bookmark count;
- foundation count;
- holdout count;
- ordered source IDs for both sets;
- the SQL/order rule used to create the split.

The holdout is important because it gives us a known set of real bookmarks to
use for iterative quality checks after the initial map exists.

## Non-Goals

Do not remove the raw-source archive or provenance sections. Those are still
needed for auditability.

Do not make every bookmark create a wiki page. Ignoring, deferring, or only
logging a source is acceptable when the interest signal is weak.

Do not force a polished synthesis on every daily ingest. The daily path should
remain bounded, but it must still produce a useful sensemaking decision.

Do not expose hidden chain-of-thought. The durable artifact should be a concise
decision record, not private reasoning.

Do not rely on external web search for normal ingestion. The core value should
come from the source plus John's wiki.

## Product Principle

Every processed bookmark should leave behind an answer to:

```text
Why was this worth saving, given what John already seems to care about?
```

If the system cannot answer that, it should say so explicitly and defer or
classify the source as low-signal instead of fabricating a weak wiki update.

## Proposed Architecture

Split ingestion into five explicit stages:

```text
source capture -> source understanding -> interest matching -> wiki action -> audit log
```

The initial foundation build and later incremental ingestion should use the
same stages and the same decision schema. The difference is operating mode, not
meaning:

- foundation mode can be slow, expensive, and iterative;
- incremental mode must be bounded and observable;
- both modes should produce comparable source-understanding records, interest
  matches, proposed actions, and audit entries.

### 1. Source Capture

This is mostly implemented.

Inputs:

- raw X bookmark Markdown;
- `## Source Text`;
- thread expansion status and provenance;
- media metadata;
- quote post sections;
- source URLs and author metadata.

Required improvement:

- For image-primary bookmarks, require a media-inspection result before
  semantic ingestion. If image content is missing, defer with a clear reason.

### 2. Source Understanding

For each source, produce a small structured summary:

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

This stage should be grounded only in the source text and attached source
context. It should not decide wiki edits yet.

### 3. Interest Matching

Introduce an explicit interest model:

```text
wiki/meta/interest-map.md
```

The interest map should summarize John's recurring:

- domains;
- projects;
- people and organizations;
- tools and technical stacks;
- questions;
- aesthetic preferences;
- repeated tensions or tradeoffs;
- high-signal pages in the wiki.

This should be compact enough to load on every ingest. It is a routing and
sensemaking aid, not a complete index.

For each source, the agent should compare the source understanding to:

- `wiki/meta/interest-map.md`;
- `wiki/index.md`;
- the recent ingest log;
- a bounded set of candidate wiki pages.

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
  "candidate_pages": [
    {
      "path": "wiki/concepts/housing-supply.md",
      "reason": "Existing page covers constraints on housing production."
    }
  ],
  "non_obvious_connections": [
    {
      "connection": "Design sameness is framed as finance/risk optimization, not merely bad taste or code compliance.",
      "related_pages": ["wiki/concepts/local-regulatory-friction.md"]
    }
  ]
}
```

### 4. Wiki Action

Only after the sensemaking output exists should the agent propose edits.

Allowed actions:

- `update_existing_page`
- `create_new_page`
- `add_evidence_to_page`
- `add_caveat_or_counterexample`
- `create_or_update_open_question`
- `defer_for_media_inspection`
- `ignore_low_signal`

Each proposed action needs:

- target path;
- short rationale;
- source citation;
- confidence;
- whether it is safe for daily ingest or should wait for deep synthesis.

Example:

```json
{
  "actions": [
    {
      "type": "add_evidence_to_page",
      "path": "wiki/concepts/housing-development-finance.md",
      "rationale": "Adds a concrete practitioner explanation of why apartment design converges around simple wood-over-podium forms.",
      "confidence": "high"
    },
    {
      "type": "create_or_update_open_question",
      "path": "wiki/questions/when-do-small-scale-development-models-improve-design-quality.md",
      "rationale": "The final post suggests alternative development models as an incentive solution, which connects to existing housing-supply interests.",
      "confidence": "medium"
    }
  ]
}
```

### 5. Audit Log

Add a durable ingest decision record.

Preferred location:

```text
wiki/log.md
```

or, if the log becomes too large:

```text
wiki/outputs/ingest-decisions/YYYY-MM-DD.md
```

Suggested format:

```markdown
## [2026-05-14] ingest | X bookmark 2043828130960625958

- Source: [[../raw/x/ingested/2043828130960625958]]
- Why likely saved: A practitioner explanation of why new apartment buildings converge aesthetically, framed through development finance, construction risk, and building-code constraints.
- Matched interests: housing supply, local regulatory friction, development economics, design quality tradeoffs.
- Existing pages considered: [[concepts/housing-supply]], [[concepts/local-regulatory-friction]]
- Non-obvious connection: The source reframes "ugly apartments" as a risk-management and financing outcome rather than only a design-culture failure.
- Action: updated [[concepts/housing-development-finance]]; created [[questions/when-do-small-scale-development-models-improve-design-quality]]
- Confidence: high
```

This gives humans and later agents a compact explanation of why the source was
handled the way it was.

## Procedure Changes

### New Procedure: `xbookmarks/wiki-sensemake-source`

Purpose:

- Given one raw source, produce source understanding, interest matches, and
  proposed actions.

Inputs:

- raw source path;
- `wiki/meta/interest-map.md`;
- `wiki/index.md`;
- recent `wiki/log.md` entries;
- optional bounded candidate page bundle.

Output:

- typed JSON decision object;
- no filesystem writes except optional dry-run report.

### Update Procedure: `xbookmarks/wiki-refresh`

Current behavior should become a coordinator:

1. Select sources.
2. For each source, call sensemaking.
3. Retrieve candidate pages named by sensemaking.
4. Ask the apply step to implement only approved actions.
5. Append decision records.
6. Move raw files to ingested/ignored/deferred.

### New or Updated Procedure: `xbookmarks/wiki-interest-map-refresh`

Purpose:

- Build or refresh `wiki/meta/interest-map.md` from accumulated ingest
  decisions and semantic wiki pages.

Inputs:

- source-understanding records;
- ingest decisions;
- high-level concept/question pages generated from those decisions;
- `wiki/index.md`;
- optional previous interest map during refreshes.

Frequency:

- during the initial foundation build;
- after each foundation batch or group of batches;
- after holdout experiment batches;
- on demand;
- as part of weekly or backlog synthesis.

Important constraint:

- The initial interest map should not be built by asking an agent to summarize
  all raw bookmarks in one pass. It should emerge from the same per-source or
  small-batch sensemaking records that incremental ingestion uses.

### New Procedure: `xbookmarks/wiki-foundation-build`

Purpose:

- Rebuild the semantic wiki and initial interest map from the foundation
  corpus.

Inputs:

- `wiki/meta/corpus-split.json`;
- all source files in the foundation corpus;
- thread/media/source readiness status;
- empty or seed `wiki/meta/interest-map.md`.

Behavior:

1. Start from an empty semantic wiki.
2. Process foundation sources in deterministic batches.
3. Run the same source understanding and sensemaking contract used for
   incremental ingestion.
4. Apply justified wiki actions.
5. Append ingest decision records.
6. Refresh the interest map after each batch group.
7. Continue until the foundation corpus has been processed or deferred.

The foundation build may be slow and may use larger context windows than daily
ingestion. It should still write auditable decisions rather than only final
pages.

### New Procedure: `xbookmarks/wiki-holdout-ingest`

Purpose:

- Process the held-out most recent 100 bookmarks in small batches after the
  foundation map exists.

Inputs:

- `wiki/meta/corpus-split.json`;
- `wiki/meta/interest-map.md`;
- batch size, default 5 or 10;
- optional starting offset.

Behavior:

- process holdout bookmarks in batches;
- show the sensemaking decision for each source;
- apply changes only after review or in an explicit `--yes` mode;
- report quality signals after each batch:
  - pages updated;
  - new pages created;
  - ignored sources;
  - deferred sources;
  - average confidence;
  - missing media/thread context.

## CLI Changes

Add a command to generate the context bundle for a single source:

```bash
x-bookmarks kb sensemaking-context --source raw/x/inbox/ID.md
```

This can output JSON containing:

- source metadata;
- source text;
- thread status;
- media availability;
- candidate pages from deterministic search;
- recent log snippets;
- interest map content.

This keeps Nanoboss focused on reasoning while the CLI handles deterministic
file and SQLite lookups.

Potential follow-up:

```bash
x-bookmarks kb source-status --source raw/x/inbox/ID.md
```

to show whether a source has enough text/media/thread context for semantic
ingestion.

Add corpus split and rebuild helpers:

```bash
x-bookmarks kb corpus-split --holdout 100 --write wiki/meta/corpus-split.json
x-bookmarks kb reset-semantic-wiki --dry-run
x-bookmarks kb reset-semantic-wiki --yes
```

The reset command should only remove generated semantic wiki content. It should
not remove raw sources, assets, SQLite state, thread expansion data, or bookmark
notes used as provenance.

Nanoboss procedures then consume the split:

```bash
nanoboss xbookmarks/wiki-foundation-build --split wiki/meta/corpus-split.json
nanoboss xbookmarks/wiki-holdout-ingest --batch-size 5 --dry-run
nanoboss xbookmarks/wiki-holdout-ingest --batch-size 10 --yes
```

## Retrieval Strategy

Use a bounded two-pass retrieval model.

### Pass 1: Cheap Routing

Inputs:

- source title/author/text;
- tags/frontmatter;
- `wiki/index.md`;
- `wiki/meta/interest-map.md`.

Output:

- 3-10 candidate pages;
- likely interests;
- whether deeper retrieval is needed.

### Pass 2: Focused Reading

Read only:

- candidate pages;
- pages linked from candidate pages when directly relevant;
- recent ingest decisions with overlapping interests.

Hard limits:

- avoid loading the whole wiki during daily ingest;
- cap candidate page count;
- cap total bytes in context bundle;
- defer to deep synthesis if the source appears broad or ambiguous.

## Daily vs Deep Modes

### Foundation Mode

Foundation mode is the initial clean-slate rebuild.

It should:

- use the foundation corpus only, excluding the most recent 100 bookmarks;
- process sources in deterministic batches;
- use the same source-understanding, interest-matching, action, and audit
  schema as incremental ingestion;
- tolerate longer runtime and higher agent/API cost;
- refresh the interest map repeatedly as evidence accumulates;
- create the first useful semantic wiki from scratch.

Foundation mode should not optimize for speed. It should optimize for producing
a credible interest map and high-quality initial pages.

### Holdout Experiment Mode

Holdout experiment mode is how we evaluate the new experience.

It should:

- process the most recent 100 bookmarks only after the foundation map exists;
- run in batches of 5 or 10;
- expose the proposed sensemaking decisions before applying them;
- make it easy to compare batch quality over time;
- allow us to tune prompts, retrieval, and page-update policy without poisoning
  the foundation build.

The holdout set is not a permanent test fixture. It is a realistic staged
rollout set: real recent bookmarks that the system has not seen while building
its initial interest map.

### Daily Mode

Daily mode should be bounded and useful:

- process a small number of new sources;
- produce an ingest decision for each source;
- apply obvious page updates;
- create narrow pages only when justified;
- defer broad synthesis;
- refresh affected review pages.

Daily mode should not rewrite large hub pages unless the action is a small
evidence append.

### Deep Mode

Deep mode can be slower:

- revisit deferred foundation, holdout, or daily sources;
- merge narrow pages;
- refresh the interest map;
- rewrite synthesis pages;
- discover cross-source themes;
- prune or consolidate low-quality pages.

## Data Model

Add SQLite tables for ingest decisions and interest-map revisions. SQLite is
already the authoritative local store for bookmarks, tweets, threads, and asset
state, so it should also own machine-readable ingestion state.

```sql
CREATE TABLE IF NOT EXISTS kb_ingest_decisions (
  source_id TEXT PRIMARY KEY,
  raw_path TEXT NOT NULL,
  status TEXT NOT NULL,
  why_saved TEXT,
  matched_interests_json TEXT,
  candidate_pages_json TEXT,
  actions_json TEXT,
  confidence TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

Consider an interest-map table:

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

Benefits:

- makes decisions queryable;
- avoids reprocessing already-decided sources;
- lets review pages include decision summaries;
- helps evaluate ingestion quality over time.

The Markdown log and source pages remain the human-facing audit trail.

## Resolved Product Decisions

### Interest Map Ownership And Format

Default ownership: agent-maintained.

Manual edits must be supported. John should be able to edit the interest map
directly when the agent gets it wrong, misses a recurring theme, or names an
interest poorly.

Canonical human-facing format:

```text
wiki/meta/interest-map.md
```

Markdown is the right default because:

- it is easy to inspect and manually edit;
- it fits the Obsidian/wiki workflow;
- agents can read it naturally;
- it can include compact explanations, examples, and links.

To keep it reliable, use a stable section schema rather than free-form prose
only:

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
but Markdown should remain the editable source of truth for the map content.

### Ingest Decisions

Store ingest decisions in SQLite.

Also render the current decision back into the source page because, in the new
workflow, the source page is no longer just provenance. It is the place a human
or agent should be able to answer:

```text
Why did John save this, and what does it connect to?
```

Raw/source pages should therefore include a generated section like:

```markdown
## Ingest Decision

- Why likely saved: ...
- Matched interests: [[...]], [[...]]
- Non-obvious connections: ...
- Actions taken: ...
- Confidence: ...
```

The source text and raw metadata remain below or near this section for
verification.

### Non-Obvious Inference

The amount of non-obvious inference is a tuning parameter.

Initial policy:

- allow useful associations that are grounded in the source and existing wiki;
- label confidence clearly;
- avoid presenting speculative associations as facts;
- prefer one good non-obvious connection over several forced ones;
- evaluate this on holdout batches and adjust.

### Negative Interests

Do not build a negative-interest model.

Assume that if John bookmarked something, it was not a mistake. The system can
still mark a source low-signal or defer it for missing context, but it should
not try to infer categories of things John does not care about.

### Media-Primary Deferrals

"Deferred media-primary source" means:

- the bookmark appears to depend on an attached image, video, chart, screenshot,
  or visual joke;
- the text alone is insufficient to understand why it was saved;
- the system has not yet extracted or inspected the media content well enough
  to make a grounded ingest decision.

Example: a post whose text says only "this is the chart" and the real claim is
inside the image.

In that case, the system should not create a weak semantic page from the tweet
text alone. It should set a status such as:

```text
deferred_media_inspection
```

and render a source-page decision like:

```markdown
## Ingest Decision

- Status: deferred media inspection
- Reason: The source text does not contain the main claim; attached media must
  be inspected before semantic ingestion.
- Next step: run media inspection for asset ...
```

Once media inspection exists, the same source can re-enter the normal
sensemaking pipeline.

## Prompt Contract

The sensemaking prompt should require these sections:

```markdown
## Source Understanding

## Why John Likely Saved This

## Existing Wiki Matches

## Non-Obvious Connections

## Durable Takeaways

## Proposed Actions

## Confidence And Deferrals
```

The typed output should require:

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
- "This should wait for deep synthesis."

## Evaluation Plan

Use the held-out most recent 100 bookmarks as the primary live evaluation set.

Process them in batches of 5 or 10 and review:

- whether the interest map helped explain why the source was likely saved;
- whether existing interest matches feel right;
- whether non-obvious connections are useful rather than forced;
- whether the agent writes too much, too little, or the wrong kind of page;
- whether the process is fast enough for incremental use;
- whether the decision log is readable enough to audit.

Also build a small fixed fixture set of 20-40 bookmarked sources for regression
tests:

- single short posts;
- long posts;
- expanded threads;
- image-primary posts;
- quote posts;
- low-signal jokes or ephemera;
- sources that map clearly to existing pages;
- sources that require non-obvious association.

For each fixture, write expected review criteria:

- Does the decision explain why John likely saved it?
- Does it map to plausible existing interests?
- Does it avoid hallucinating unsupported claims?
- Does it make at least one useful non-obvious connection when available?
- Does it avoid unnecessary page creation?
- Does it defer when media/context is missing?
- Are citations/backlinks correct?

Add a test harness that can run sensemaking in dry-run mode and snapshot:

- typed decision JSON;
- proposed file operations;
- log entry preview.

## Implementation Phases

### Phase 1: Design The Decision Artifact And Split

- Define the typed ingest decision schema.
- Add sample decisions for 5 representative bookmarks.
- Update prompt docs to require the sensemaking sections.
- Define `corpus-split.json`.
- Add the holdout split rule: most recent 100 active bookmarks.
- No filesystem mutations yet.

### Phase 2: Add Clean-Slate Semantic Reset

- Add a dry-run reset command for generated semantic wiki content.
- Preserve raw sources, media, SQLite state, thread expansion data, and
  provenance notes.
- Make the reset explicit and hard to run accidentally.
- Document exactly which directories are scrubbed.

### Phase 3: Build Single-Source Sensemaking

- Implement `xbookmarks/wiki-sensemake-source`.
- Add deterministic context-bundle assembly.
- Return typed decision JSON and Markdown preview.
- Add tests with fixture raw sources.

### Phase 4: Add Foundation Interest Map Build

- Generate `wiki/meta/corpus-split.json`.
- Process the foundation corpus in deterministic batches.
- Use the same sensemaking contract as incremental ingestion.
- Create or update semantic pages from approved decisions.
- Store decision records in SQLite.
- Render ingest decisions into source pages.
- Refresh `wiki/meta/interest-map.md` after each batch group.
- Continue until all foundation sources are processed, ignored, or deferred.

### Phase 5: Integrate With Apply Flow

- Update `wiki-refresh` to require a decision before edits.
- Apply only actions from the decision object.
- Append decision records to the log.
- Store decision status in SQLite.
- Add it to context bundles.
- Add a refresh procedure for periodic maintenance.

### Phase 6: Holdout Batch Experiments

- Process the held-out 100 bookmarks in batches of 5 or 10.
- Review sensemaking decisions before applying.
- Track quality and speed per batch.
- Tune prompts, retrieval, and action policy based on observed failures.

### Phase 7: Daily Workflow

- Make daily ingest run sensemaking for new sources.
- Keep hard limits on source count, candidate pages, and context bytes.
- Defer broad or ambiguous sources.
- Report processed, updated, ignored, and deferred counts.

### Phase 8: Deep Synthesis

- Add backlog/deep mode for deferred sources and cross-source themes.
- Refresh interest map.
- Merge narrow pages and update synthesis pages.

## Open Questions

- What is the exact Markdown schema for `wiki/meta/interest-map.md`?
- Should `interest-map.md` be the only editable artifact, or should manual
  edits also be captured as SQLite revision metadata?
- What confidence labels and review UX best tune non-obvious inference?
- Should deferred media inspection be implemented with local vision tooling,
  an agent-visible rendered image bundle, or both?
- Should source pages show the full ingest decision or a compact decision with
  a link to SQLite/log detail?

## Success Criteria

This project is successful when a new bookmark produces a decision that a human
can read and say:

- yes, that is probably why I saved it;
- yes, those are the right existing interests;
- that connection is useful and not obvious from the source alone;
- the wiki update is justified by the source;
- the system knew when not to overreach.

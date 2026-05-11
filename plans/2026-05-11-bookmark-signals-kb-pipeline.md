# Bookmark Signals To LLM Wiki Plan

Date: 2026-05-11

## Goal

Use X bookmarks as signals into an LLM-maintained personal knowledge base, following the "LLM Wiki" pattern:

- raw sources are immutable inputs;
- the wiki is a persistent, compounding Markdown artifact;
- an LLM agent owns the wiki maintenance work;
- Obsidian is the IDE for reading, navigation, graph view, and rendered outputs.

The important shift: this phase should not primarily build another application or UI. It should create the working surface and operating instructions that let an agent reason over bookmarked posts and decide what wiki entries to create, update, connect, challenge, or ignore.

Bookmarks are a source of intent: "I was interested in this." The pipeline should turn that intent into wiki growth.

## Product Decision

Treat each bookmarked post as an uncompiled raw source until an agent ingests it into the wiki.

The bookmark export should not decide the final concept model. The agent should read raw bookmarked posts, inspect links/quotes/media/context, compare them against the existing wiki, and then make judgment calls:

- create a new concept page;
- update an existing concept page;
- add an example to a technique or pattern page;
- create or update a person, project, paper, company, tool, or question page;
- add a contradiction or caveat to an existing page;
- mark the source as low-signal/no-op;
- propose a follow-up web clip, paper fetch, repo clone, or question.

The tool's role is to prepare high-quality raw materials and a disciplined schema. The agent's role is synthesis.

## Architecture

Use three layers, matching the LLM Wiki pattern.

### 1. Raw Sources

Immutable or append-only files the LLM reads but does not rewrite as synthesis.

For this project, the first raw source type is a bookmarked X post.

```text
X Bookmarks/
  raw/
    x/
      inbox/
        <tweet_id>.md
      ingested/
        <tweet_id>.md
      ignored/
        <tweet_id>.md
    web/
    papers/
    repos/
    images/
```

Interpretation:

- `raw/x/inbox/`: bookmarked posts waiting for agent ingestion.
- `raw/x/ingested/`: bookmarked posts already incorporated into the wiki.
- `raw/x/ignored/`: posts reviewed by the agent and intentionally not incorporated.
- `raw/web/`, `raw/papers/`, `raw/repos/`, `raw/images/`: follow-up sources collected manually, by Obsidian Web Clipper, or by an agent.

Moving a raw X file from `inbox` to `ingested` is a bookkeeping action after wiki updates are made. The post content itself should stay intact.

### 2. Wiki

LLM-owned Markdown pages. The user reads these, but normally does not edit them directly.

```text
X Bookmarks/
  wiki/
    index.md
    log.md
    schema.md
    concepts/
    people/
    projects/
    tools/
    papers/
    companies/
    questions/
    syntheses/
    outputs/
```

The wiki is the persistent compiled artifact. It should accumulate structure over time.

Examples of pages the agent might create from bookmarks:

```text
wiki/concepts/context-engineering.md
wiki/concepts/local-first-ai-tools.md
wiki/concepts/llm-agent-memory.md
wiki/tools/qmd.md
wiki/people/andrej-karpathy.md
wiki/questions/how-should-agent-maintained-wikis-handle-contradictions.md
wiki/syntheses/2026-05-llm-knowledge-base-patterns.md
```

### 3. Schema

The operating instructions for the agent.

```text
X Bookmarks/
  wiki/
    schema.md
```

This file matters more than most code in this phase. It tells the agent how to ingest sources, how to write pages, how to cite raw files, how to maintain indexes, and how to log changes.

## First Deliverable

The first implementation should generate a raw bookmark inbox and a starter wiki schema.

Command:

```bash
x-bookmarks kb init
x-bookmarks kb export-raw-x --changed
```

Output:

```text
X Bookmarks/
  raw/
    x/
      inbox/
        <tweet_id>.md
  wiki/
    schema.md
    index.md
    log.md
```

This is enough for an agent to begin doing real wiki maintenance.

## Raw Bookmark File Format

Each bookmarked post should become a Markdown source file.

Path:

```text
raw/x/inbox/<tweet_id>.md
```

Content:

```markdown
---
source_type: x_bookmark
tweet_id: "2052423637500571963"
canonical_url: "https://x.com/mronge/status/2052423637500571963"
author_username: "mronge"
author_name: "..."
created_at: "2026-05-07T..."
bookmarked_at: "..."
folders: []
status: inbox
---

# X Bookmark: @mronge / 2052423637500571963

## Post

Full post text, including note_tweet expansion if present.

## Why This May Matter

Generated deterministic hints, not final synthesis:

- has external link: ...
- quote-post: ...
- repeated author/domain in bookmark corpus: ...
- folder: ...
- media present: ...

## Links

- X: ...
- Extracted URL: ...

## Quote Post

Quoted post text and URL, if locally available.

## Media

Local image/preview/avatar references, if available.

## Raw Metadata

Short JSON block or sidecar path.
```

The "Why This May Matter" section is not the wiki. It is a prompt for the future agent. It should be factual and lightweight.

## Agent Ingestion Workflow

The core workflow is not a CLI command that "builds the wiki". It is an agent routine documented in `wiki/schema.md`.

Suggested user instruction:

```text
Ingest the next 10 raw X bookmarks into the wiki.
Follow X Bookmarks/wiki/schema.md.
Read each raw source, decide what wiki pages need to be created or updated, make the edits, update index.md, append to log.md, then move each processed raw source to raw/x/ingested or raw/x/ignored.
```

Agent steps:

1. Read `wiki/schema.md`.
2. Read `wiki/index.md` to understand existing pages.
3. Select one or more files from `raw/x/inbox/`.
4. For each raw bookmark, determine the core subject.
5. Search the wiki for related pages.
6. Decide one of:
   - create new page;
   - update existing page;
   - add source citation only;
   - file as example/evidence;
   - mark as ignored with reason;
   - request follow-up source collection.
7. Update all relevant wiki pages.
8. Add backlinks from wiki pages to raw source files.
9. Update `wiki/index.md`.
10. Append a structured entry to `wiki/log.md`.
11. Move the raw X file from `raw/x/inbox/` to `raw/x/ingested/` or `raw/x/ignored/`.

The agent may touch 10-15 wiki pages for a single high-signal source.

## Wiki Schema Requirements

`wiki/schema.md` should include conventions like:

### Page Types

- Concept page
- Person page
- Project/tool page
- Paper/source page
- Company/org page
- Open question page
- Synthesis page
- Output page

### Frontmatter

Example:

```yaml
---
type: concept
status: active
created: 2026-05-11
updated: 2026-05-11
source_count: 4
tags:
  - llm-wiki
---
```

### Citation Style

Every factual claim should cite raw files or wiki pages:

```markdown
This pattern treats the wiki as a compiled artifact rather than a retrieval index. Sources: [[../raw/x/ingested/2052423637500571963]], [[../raw/web/llm-wiki.md]].
```

### Maintenance Rules

- Update `index.md` on every ingest.
- Append to `log.md` on every ingest/query/lint pass.
- Prefer updating existing pages over creating duplicates.
- When a new source contradicts an old page, add a "Contradictions / Caveats" section rather than silently overwriting.
- Keep raw sources immutable except for frontmatter status/move bookkeeping.
- Never delete wiki pages during ingestion; propose cleanup in a lint pass.

## `index.md`

Content-oriented catalog for the agent and user.

It should include:

- page path;
- one-line summary;
- page type;
- source count;
- last updated date.

Example:

```markdown
# Wiki Index

## Concepts

- [[concepts/llm-agent-memory]] - How agents preserve and use state across tasks. Sources: 6. Updated: 2026-05-11.
- [[concepts/local-first-ai-tools]] - Tools where user data and workflows remain local-first. Sources: 4. Updated: 2026-05-11.

## Open Questions

- [[questions/how-should-agent-maintained-wikis-handle-contradictions]] - Tracks unresolved design choices around stale or conflicting claims.
```

## `log.md`

Append-only chronological record.

Example:

```markdown
# Wiki Log

## [2026-05-11] ingest | X bookmark 2052423637500571963

- Raw source: [[../raw/x/ingested/2052423637500571963]]
- Updated: [[concepts/llm-agent-memory]], [[concepts/llm-knowledge-bases]]
- Created: [[questions/how-should-agent-maintained-wikis-handle-contradictions]]
- Notes: Added distinction between RAG retrieval and compiled persistent wiki.
```

The heading format should be stable so agents and shell tools can parse recent activity.

## Query Workflow

Queries should operate against the compiled wiki first, then raw sources if needed.

Suggested user instruction:

```text
Using the wiki, answer: "How do local-first AI tools relate to LLM-maintained knowledge bases?"
Write the answer as a new synthesis page if it is worth preserving.
Update index.md and log.md.
```

Agent steps:

1. Read `wiki/index.md`.
2. Identify relevant wiki pages.
3. Read those pages and cited raw sources if needed.
4. Produce answer as:
   - direct response only, or
   - new `wiki/syntheses/<slug>.md`, or
   - output artifact under `wiki/outputs/`.
5. File useful answers back into the wiki.
6. Update index/log.

## Lint Workflow

Linting should be an agent routine, not a big deterministic checker at first.

Suggested user instruction:

```text
Run a health check over the wiki. Look for duplicate pages, missing backlinks, stale claims, contradictions, orphan pages, and high-signal raw bookmarks still unprocessed. Write findings to wiki/outputs/wiki-health-YYYY-MM-DD.md and update log.md.
```

Agent checks:

- raw files in `raw/x/inbox` older than N days;
- pages not listed in `index.md`;
- pages with no inbound links;
- pages with no raw source citations;
- duplicated concept pages;
- claims contradicted by newer sources;
- repeated topics in raw bookmarks with no concept page;
- strong sources that only got a shallow summary.

## Tooling Scope

Keep the binary's role intentionally small:

```bash
x-bookmarks kb init
x-bookmarks kb export-raw-x --changed
x-bookmarks kb status
```

Optional later:

```bash
x-bookmarks kb next --limit 10
x-bookmarks kb mark-ingested <tweet_id>
x-bookmarks kb mark-ignored <tweet_id> --reason "..."
```

Avoid building a full wiki compiler into Zig. The compiler is the agent plus `schema.md`.

## Why This Fits The Bookmark Use Case

Bookmarks are sparse, human-curated signals. A single post may imply many possible wiki actions:

- The post itself might be the source.
- The linked article might be the source.
- The quoted post might be more important than the bookmarked post.
- The author might be a recurring expert worth a person page.
- The post might be an example for an existing concept.
- The post might be low value alone but high value as part of a cluster.

This judgment is exactly what the agent should do. The deterministic tool should not prematurely classify the knowledge graph.

## Implementation Phases

### Phase 1: Raw Bookmark Inbox

Deliver:

- `kb init`
- `kb export-raw-x --changed`
- raw X Markdown files in `raw/x/inbox`
- starter `wiki/schema.md`
- starter `wiki/index.md`
- starter `wiki/log.md`

Success criteria:

- after a bookmark sync, an agent can ingest raw bookmark files into the wiki without reading SQLite;
- raw files are stable and cite canonical X URLs;
- changed-only export does not rewrite unchanged raw files.

### Phase 2: Agent Schema Hardening

Deliver:

- detailed ingestion instructions in `wiki/schema.md`;
- page type templates;
- citation conventions;
- index/log update rules;
- examples of before/after ingestion.

Success criteria:

- a fresh agent session can read `schema.md` and correctly maintain the wiki;
- multiple ingestion sessions produce consistent page structure.

### Phase 3: Human-Guided Ingest Runs

Deliver:

- manually run agent ingests over small batches;
- review diffs after each batch;
- revise `schema.md` based on failures.

Success criteria:

- raw bookmarks produce useful concept/entity/synthesis pages;
- agent updates existing pages instead of creating scattered duplicates;
- index/log remain useful at navigation time.

### Phase 4: Follow-Up Source Collection

Deliver:

- agent identifies links/articles/repos/papers that should be clipped into `raw/web`, `raw/repos`, or `raw/papers`;
- user or agent collects those sources with Obsidian Web Clipper or other tools;
- agent ingests those richer sources back into the wiki.

Success criteria:

- bookmarked posts lead to deeper source collection;
- wiki pages cite both the original bookmark signal and the fuller source document.

### Phase 5: Query And Lint Routines

Deliver:

- documented query workflow;
- documented lint workflow;
- preserved synthesis outputs under `wiki/syntheses` or `wiki/outputs`;
- periodic health reports.

Success criteria:

- questions asked against the wiki improve the wiki;
- health checks find concrete maintenance work;
- the knowledge base compounds instead of becoming chat history.

## Non-Goals

- Do not build a bookmark management UI.
- Do not build a full RAG service.
- Do not auto-generate the entire wiki from bookmarks without human/agent review.
- Do not let the binary decide the final taxonomy.
- Do not auto-delete raw sources.
- Do not auto-delete or mutate X bookmarks.
- Do not require web fetching for the first raw bookmark inbox.

## Validation Plan

Use a copied data directory and temporary vault:

```bash
rm -rf /tmp/x-bookmarks-kb-wiki
mkdir -p /tmp/x-bookmarks-kb-wiki
cp -R data /tmp/x-bookmarks-kb-wiki/data
mkdir -p /tmp/x-bookmarks-kb-wiki/TestVault
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-kb-wiki/data obsidian init --vault /tmp/x-bookmarks-kb-wiki/TestVault
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-kb-wiki/data kb init
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-kb-wiki/data kb export-raw-x --changed
```

Then run an agent prompt:

```text
Read X Bookmarks/wiki/schema.md.
Ingest 5 raw bookmark files from X Bookmarks/raw/x/inbox.
Create or update wiki pages as needed.
Update X Bookmarks/wiki/index.md and X Bookmarks/wiki/log.md.
Move processed raw files to raw/x/ingested or raw/x/ignored.
Show me the diff.
```

Expected:

- raw bookmark files are generated but not synthesized by the binary;
- the agent creates or updates actual wiki entries;
- index/log are updated;
- processed raw files are moved out of inbox;
- wiki pages cite raw bookmark files;
- the resulting diff is reviewable in Obsidian and Git.

## Success Criteria

- Bookmarks become an inbox of research signals.
- The raw layer is simple enough for any agent to inspect.
- The wiki layer is maintained by the LLM, not by bespoke app logic.
- The schema gives the agent enough discipline to avoid generic summaries and duplicate pages.
- Ingestion runs create durable wiki value: new pages, updated pages, citations, backlinks, log entries, and follow-up questions.

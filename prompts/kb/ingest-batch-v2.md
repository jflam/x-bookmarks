# Ingest X Bookmark Batch v2

You are maintaining my X Bookmarks personal knowledge base.

The knowledge base is viewed in Obsidian. The vault is located at:

```text
~/src/brain2
```

The managed root inside that vault is:

```text
~/src/brain2/X Bookmarks
```

Read these first:

1. `~/src/brain2/X Bookmarks/wiki/schema.md`
2. `~/src/brain2/X Bookmarks/wiki/home.md`
3. `~/src/brain2/X Bookmarks/wiki/reviews/this-week.md`
4. The relevant map under `~/src/brain2/X Bookmarks/wiki/maps/`

Task: ingest the next batch of raw X bookmark files from:

```text
~/src/brain2/X Bookmarks/raw/x/inbox/
```

Default batch size is 25 unless the caller gives a different size. Process bookmarks in reverse chronological order.

## Goals

Maintain two layers:

1. A compiled wiki of durable pages with citations.
2. A human review surface organized by time and theme.

The wiki should not feel like an ingestion trace. It should feel like an Obsidian review system.

## Ingestion Rules

For each raw bookmark:

1. Read the full raw source, including article metadata, quote posts, links, and media descriptions.
2. Identify the durable subject, if any.
3. Search `~/src/brain2/X Bookmarks/wiki/` for related existing pages before creating new ones.
4. Decide one of:
   - update an existing page;
   - create a durable page;
   - add the source as evidence/example/caveat to an existing page;
   - add the source to a review queue only, if it is worth reviewing but not yet durable;
   - move the source to ignored if it is low-signal.
5. Prefer updating existing pages over creating one-source fragments.
6. If a source complicates an existing claim, add a `Contradictions / Caveats` note instead of overwriting the earlier claim.
7. Cite raw sources from any page you update, using an inline X embed plus a dated aliased Obsidian wikilink so the rendered text is readable and the wiki graph still has a markdown source link.

## Page Quality

Use frontmatter from `wiki/schema.md`.

Use this maturity judgment:

- `seed`: one-source page, uncertain durability, needs later merge or follow-up.
- `active`: durable page with clear ongoing value.
- `synthesis`: compiled higher-level answer or essay.

Do not promote every bookmark into spaced repetition. Only add `review:` frontmatter when the page is genuinely worth revisiting.

## Review Queues

Always update the temporal review surface:

- Update `wiki/reviews/this-week.md` if the current week pointer changes or if the focus list changes.
- Update the current weekly queue, e.g. `wiki/reviews/YYYY-Www.md`, with:
  - a compelling weekly brief;
  - `Review First` as a study guide over dated source cards, not just a list of hub pages;
  - `Secondary Review`;
  - `Non-Agent Threads` when relevant;
  - `Promote To Spaced Repetition Candidates`;
  - `Follow-Up Source Collection`;
  - `Source Trail` with every raw post processed for that review period.

### Weekly Brief Quality

The weekly brief should make the batch feel worth reviewing. Do not write a taxonomy paragraph that merely lists clusters. The reader bookmarked these sources because they were among the most interesting things they saw; the brief should honor that.

Write the brief as a short narrative with tension and release:

- Open with a hook, puzzle, or contradiction that emerged from the batch.
- Build tension by showing what is breaking, changing, or becoming newly possible.
- Connect the main clusters into one story instead of naming them as categories.
- End with the payoff: why this week changes how the reader should think or what they should inspect next.

Avoid phrases like "this week is dominated by" or "the strongest cluster is." Those are labels, not storytelling. A good brief should pull the reader into the `Review First` list.

### Weekly Review Study Guide

The weekly review page is for reviewing new information, not for dumping the reader into giant accumulated hub pages.

For `Review First`, write a study guide with a small number of thematic blocks. Each block should include:

- the review question or tension;
- why the source group matters now;
- dated raw-source cards using `![](canonical_x_url) [[raw-source-path|YY-MM-DD @username: short title]]`;
- links to stable hub pages for deeper context.

Do not make `Review First` only a list of wiki pages. Hub pages are gathering points and should stay stable, but they can grow large. The review page must preserve the new-post context that explains why a hub is relevant this week.

### Source Trail

At the bottom of every weekly queue, include a `Source Trail` section with every raw post processed for that review period. Each entry should include:

- the canonical X post embed and raw source link on the same line;
- a short excerpt or post summary;
- related wiki pages when relevant.

Sort the source trail newest to oldest by the original post date. This gives the reader a scrollable reconstruction of what was actually bookmarked while keeping durable page paths stable.

Spaced repetition should be programmatic. Obsidian is the review surface; a future program should read page frontmatter and generate due queues. For now, only add review metadata to high-value pages:

```yaml
review:
  status: candidate
  priority: high
  next: 2026-05-18
  interval_days: 7
  ease: 2.5
  last_reviewed:
```

## Maps

Always update at least one map under `wiki/maps/`.

Use maps as the main human browsing layer:

- `maps/agentic-software.md`
- `maps/model-behavior-and-evaluation.md`
- `maps/ai-infrastructure.md`
- `maps/knowledge-systems.md`
- `maps/health-life-and-learning.md`
- `maps/policy-culture-and-society.md`

Add a page to the map where a human would naturally look first. Do not add every page to every map.

All wiki links that a human will see must use readable Obsidian aliases. This includes raw-source citations, maps, review queues, `wiki/index.md`, and `wiki/log.md`. Raw-source aliases should include the post date and describe the source, not just repeat an opaque tweet ID. For X posts, put the canonical X URL embed immediately before the raw markdown link, on the same line.

```markdown
- [[../concepts/agentic-development-workflows|Agentic Development Workflows]]
Sources: ![](https://x.com/mronge/status/2052423637500571963) [[../../raw/x/ingested/2052423637500571963|26-05-07 @mattronge: headless Mac mini agent host]]
```

Do not leave rendered links as path-like text such as `../concepts/agentic-development-workflows` or `../../raw/x/ingested/2052423637500571963`.

## Catalog And Log

Update `wiki/index.md` as a catalog for agents and search, not as the human home page. Use aliased wikilinks there too, so the rendered catalog shows readable titles instead of paths.

## Citation Link Text

Raw-source citations must keep their target path but hide it behind a readable source label. For X bookmarks, always render the post itself first with Obsidian's URL embed syntax, then include the markdown source link for agents:

```markdown
![](canonical_x_url) [[RAW_SOURCE_PATH|YY-MM-DD @username: short source title or claim]]
```

Use article titles when available. Otherwise use the author handle plus a compact summary of the post's durable claim.

```markdown
Sources: ![](https://x.com/demian_ai/status/2053520242479919204) [[../../raw/x/ingested/2053520242479919204|26-05-10 @demian_ai: AI factory bottleneck dashboard]]
Sources: ![](https://x.com/tbpn/status/2049255025483104275) [[../../raw/x/ingested/2049255025483104275|26-04-28 @tbpn: Intel advanced packaging thesis]]
Sources: ![](https://x.com/elonmusk/status/2051923983902323064) [[../../raw/x/ignored/2051923983902323064|Ignored 26-05-06 @elonmusk: Moon image with no durable claim]]
```

Use the correct relative path from the page being edited. For most wiki concept/tool/project pages, raw-source links need `../../raw/x/...`; from `wiki/log.md`, they need `../raw/x/...`.

Avoid aliases that are still opaque, such as `X 2052423637500571963`, unless no author, title, or topic can be recovered.

Raw source dates should use two-digit year, month, and day, for example `26-05-10`.

Do not write unaliased raw citations such as this pattern:

```markdown
[[RAW_SOURCE_PATH_WITHOUT_ALIAS]]
```

Do not replace the raw markdown link with only the X URL embed. Humans need the embed; agents need the raw markdown link for graph traversal and source reasoning.

Append a structured entry to `wiki/log.md` with:

- raw sources;
- pages updated;
- pages created;
- ignored sources;
- review queues updated;
- maps updated;
- follow-up source collection.

## Raw File Bookkeeping

After processing all selected files:

1. Move each incorporated raw file from `raw/x/inbox/` to `raw/x/ingested/`.
2. Move each intentionally skipped raw file to `raw/x/ignored/`.
3. Update raw frontmatter status to `ingested` or `ignored`.
4. Ensure wiki citations point to the final raw folder and use readable aliases.

## Final Report

Show a concise summary:

- files ingested;
- files ignored;
- wiki pages created;
- wiki pages updated;
- maps updated;
- review queues updated;
- spaced repetition candidates added;
- follow-up sources worth collecting.

Show the diff or summarize the changed files.

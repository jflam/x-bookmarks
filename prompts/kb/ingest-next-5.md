# Ingest Next 5 X Bookmarks

You are maintaining my X Bookmarks personal knowledge base.

The knowledge base is viewed in Obsidian. The vault is located at:

```text
~/src/brain2
```

The managed root inside that vault is:

```text
~/src/brain2/X Bookmarks
```

Read `~/src/brain2/X Bookmarks/wiki/schema.md` first and follow it as the source of truth.

Task: ingest the next 5 raw X bookmark files from:

```text
~/src/brain2/X Bookmarks/raw/x/inbox/
```

For each raw bookmark:

1. Read the full raw source.
2. Identify the core subject, if any.
3. Search `~/src/brain2/X Bookmarks/wiki/` for related existing pages before creating new ones.
4. Decide one of:
   - create a new wiki page;
   - update an existing wiki page;
   - add the source as evidence or an example to an existing page;
   - create or update a person, project, tool, company, paper, or question page;
   - move the source to ignored if it is low-signal.
5. Cite the raw source from any wiki page you update, using an inline X embed plus a dated aliased Obsidian wikilink so rendered text is readable and the wiki graph still has a markdown source link.
6. Prefer updating existing pages over creating duplicates.
7. If a source contradicts or complicates an existing page, add a `Contradictions / Caveats` note instead of overwriting the earlier claim.

Obsidian conventions:

- Use Obsidian wikilinks for internal links.
- Every human-visible wikilink must use a readable alias, including raw-source citations, maps, review queues, `wiki/index.md`, and `wiki/log.md`. Raw-source aliases should include the post date and describe the source, not just repeat an opaque tweet ID.
- For X posts, put the canonical X URL embed immediately before the raw markdown link, on the same line: `![](canonical_x_url) [[raw-source-path|YY-MM-DD @username: short title]]`.
- Keep page paths stable and lowercase slug-style.
- Maintain page frontmatter according to `wiki/schema.md`.
- Use relative links to raw sources that will keep working after the raw file is moved to `raw/x/ingested/` or `raw/x/ignored/`, but hide the path behind an alias.
- Do not create decorative or temporary pages outside `wiki/outputs/`.

Weekly review conventions:

- Update `wiki/reviews/this-week.md` if the active week pointer or focus list changes.
- Update the active weekly queue with a compelling weekly brief, `Review First`, `Secondary Review`, `Non-Agent Threads` when relevant, spaced-repetition candidates, follow-up source collection, and `Source Trail`.
- Write the weekly brief as narrative orientation, not a taxonomy of clusters. Open with tension or a puzzle, show what is changing, connect the sources into one story, and end with why the batch is worth reviewing.
- Write `Review First` as a study guide over dated raw-source cards. Each card should include the X embed and raw markdown link on one line. Do not make it only a list of hub pages.
- Link from each review block to stable hub pages for deeper context, but keep the new-post context on the weekly page.
- End the weekly queue with `Source Trail`: every raw post processed for the period, sorted newest to oldest by original post date, with the X embed plus dated raw-source link, short excerpt or summary, and related wiki pages when useful.

Raw-source citation examples:

```markdown
Sources: ![](https://x.com/demian_ai/status/2053520242479919204) [[../../raw/x/ingested/2053520242479919204|26-05-10 @demian_ai: AI factory bottleneck dashboard]]
Sources: ![](https://x.com/tbpn/status/2049255025483104275) [[../../raw/x/ingested/2049255025483104275|26-04-28 @tbpn: Intel advanced packaging thesis]]
Sources: ![](https://x.com/elonmusk/status/2051923983902323064) [[../../raw/x/ignored/2051923983902323064|Ignored 26-05-06 @elonmusk: Moon image with no durable claim]]
```

Prefer `YY-MM-DD @username: short source title or claim`; use article titles when available. Avoid aliases that are still opaque, such as `X 2052423637500571963`, unless no author, title, or topic can be recovered.

Do not write unaliased citations like `[[RAW_SOURCE_PATH_WITHOUT_ALIAS]]`, because Obsidian renders the path as link text.

Do not replace the raw markdown link with only the X URL embed. Humans need the embed; agents need the raw markdown link for graph traversal and source reasoning.

After processing all 5:

1. Update `~/src/brain2/X Bookmarks/wiki/index.md`.
2. Append structured entries to `~/src/brain2/X Bookmarks/wiki/log.md`.
3. Move each processed raw file from `raw/x/inbox/` to either:
   - `raw/x/ingested/`, if incorporated into the wiki;
   - `raw/x/ignored/`, if intentionally skipped.
4. Show a concise summary of:
   - files ingested;
   - files ignored;
   - wiki pages created;
   - wiki pages updated;
   - any follow-up sources worth collecting.
5. Show the diff.

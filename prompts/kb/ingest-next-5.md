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
5. Cite the raw source from any wiki page you update.
6. Prefer updating existing pages over creating duplicates.
7. If a source contradicts or complicates an existing page, add a `Contradictions / Caveats` note instead of overwriting the earlier claim.

Obsidian conventions:

- Use Obsidian wikilinks for internal links.
- Keep page paths stable and lowercase slug-style.
- Maintain page frontmatter according to `wiki/schema.md`.
- Use relative links to raw sources that will keep working after the raw file is moved to `raw/x/ingested/` or `raw/x/ignored/`.
- Do not create decorative or temporary pages outside `wiki/outputs/`.

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


# Obsidian Link Discipline

All human-visible Obsidian wikilinks must be readable.

Raw X source citations must render the X post and preserve the raw Markdown
source link on the same line:

```markdown
![](https://x.com/user/status/123) [[../../raw/x/ingested/123|26-05-10 @user: short readable source label]]
```

Weekly review pages are curation surfaces. On review pages, do not repeat the
tweet text after the raw-source link. Prefer a compact link alias and put the
current wiki backlinks underneath:

```markdown
![](https://x.com/user/status/123)

[[../../raw/x/ingested/123|Captured bookmark]]

Wiki entries:
- [[../concepts/example#^x-123|Example]]
```

Durable wiki pages should also use standalone source blocks, not bulleted
truncated tweet summaries:

```markdown
![](https://x.com/user/status/123) [[../../raw/x/ingested/123|26-05-10 @user: short readable source label]] ^x-123
```

Use final raw paths in planned wiki markdown:

- `../../raw/x/ingested/<tweet_id>` from most wiki pages;
- `../raw/x/ingested/<tweet_id>` from `wiki/log.md`;
- `../../raw/x/ignored/<tweet_id>` or `../raw/x/ignored/<tweet_id>` for
  ignored sources.

Do not leave raw links unaliased. Do not use aliases such as `X 123` or path
text such as `../../raw/x/ingested/123`. Raw-source aliases should match:

```text
tweet
ignored tweet
YY-MM-DD @username: summary
Ignored YY-MM-DD @username: summary
```

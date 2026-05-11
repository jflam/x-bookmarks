# x-bookmarks viewer

Local validation UI for exported X/Twitter bookmark data.

```bash
bun install
bun run dev
bun run build
```

The app reads the importer export files from `data/bookmarks.json`,
`data/tweets.json`, `data/folders.json`, `data/folder-items.json`,
`data/media-assets.json`, `data/tweet-media.json`,
`data/missing-references.json`, and `data/sync-summary.json`.
For static validation output, run:

```bash
x-bookmarks viewer export
x-bookmarks viewer serve
```

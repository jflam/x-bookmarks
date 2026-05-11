# Obsidian Timeline Simplification Plan

Date: 2026-05-11

## Goal

Simplify Obsidian export around the workflow that actually matters now: generated year/month timeline notes containing one X embed per bookmark.

The default Obsidian export should be cheap, predictable, and easy to reason about:

```markdown
# 2026-05

## 2026-05-07

![](https://x.com/mronge/status/2052423637500571963)
```

SQLite plus the canonical `storage.assets_dir` remain the source of truth for local sync and media state. The Obsidian vault is a generated human viewing layer.

## Current Problem

The implementation zigged and zagged into a larger export system than the current product needs:

- `obsidian export` always materializes image/avatar/preview assets.
- `obsidian export` always writes one detailed Markdown note per bookmark.
- Timeline files are now URL-embed only, but they still sit beside older rich Markdown/index paths.
- The browser viewer briefly learned to render generated Markdown, then that was removed.
- Config includes fields that are either unused or overly flexible for the current desired layout.
- Asset materialization logic exists in more than one export path.
- `obsidian init` mutates JSON config with string scanning.

This creates accidental complexity and makes it unclear which output is primary.

## Product Decision

Make the Obsidian timeline the primary export surface.

Default export mode:

```text
timeline-only
```

Optional export mode:

```text
full
```

`timeline-only` writes only:

```text
X Bookmarks/
  timeline/
    <year>/
      <year-month>.md
  indexes/
    timeline.md
  data/
    export-summary.json
```

`full` may additionally write:

```text
X Bookmarks/
  bookmarks/
    <tweet_id>.md
  assets/
    images/
    previews/
    avatars/
  indexes/
    all-bookmarks.md
    incomplete.md
    failed-assets.md
  data/
    bookmarks-index.json
    media-assets-index.json
```

## Export Modes

### `timeline-only`

Default behavior for:

```bash
x-bookmarks obsidian export
```

Behavior:

1. Read active bookmarks from SQLite.
2. Group by tweet `created_at` year/month.
3. Write `timeline/<year>/<year-month>.md`.
4. Write one day heading per day.
5. Write one embed line per bookmark:

   ```markdown
   ![](https://x.com/<username>/status/<tweet_id>)
   ```

6. Write `indexes/timeline.md` linking to every generated month note.
7. Write minimal `data/export-summary.json`.
8. Do not copy media assets.
9. Do not write per-tweet detail notes.
10. Do not mutate or delete user-authored content outside generated timeline/index/data files.

### `full`

Explicit behavior for:

```bash
x-bookmarks obsidian export --mode full
```

or config:

```json
{
  "obsidian": {
    "export_mode": "full"
  }
}
```

Behavior:

1. Run the `timeline-only` export.
2. Materialize image-class assets.
3. Write per-tweet detail notes with generated block plus preserved notes.
4. Write diagnostic and JSON sidecar indexes.

## CLI Changes

Update help and command parsing:

```bash
x-bookmarks obsidian export
x-bookmarks obsidian export --mode timeline-only
x-bookmarks obsidian export --mode full
x-bookmarks obsidian export --changed
x-bookmarks obsidian export --dry-run
```

Rules:

- `--mode timeline-only` is default.
- `--changed` in timeline mode should skip rewriting unchanged month files and `indexes/timeline.md`.
- `--dry-run` should print planned month/index writes without changing the vault.
- `--clean-stale` should apply only to generated detail notes in `full` mode, or be rejected in timeline-only mode with an actionable message.

## Config Changes

Add:

```json
{
  "obsidian": {
    "export_mode": "timeline-only",
    "timeline_dir": "timeline"
  }
}
```

Reconsider or remove:

- `preserve_user_notes`: only meaningful in `full` mode. Either remove it or document that it is ignored in `timeline-only`.
- `note_dir`: only meaningful in `full` mode.
- `asset_dir`: only meaningful in `full` mode.

Keep:

- `vault_path`
- `root_dir`
- `index_dir`
- `data_dir`
- `media_policy`

## Code Refactor Plan

### 1. Introduce Export Mode Type

Add a small enum-like helper:

```zig
const ObsidianExportMode = enum {
    timeline_only,
    full,
};
```

Parse from config and CLI.

Store it in `Config` as `obsidian_export_mode`.

### 2. Split Export Orchestration

Replace the current single `obsidianExport` flow with:

```zig
fn obsidianExport(...) !void {
    switch (mode) {
        .timeline_only => try obsidianExportTimelineOnly(...),
        .full => try obsidianExportFull(...),
    }
}
```

`obsidianExportTimelineOnly` should call only:

- `resolveObsidianPaths`
- `makeObsidianTimelineDirs`
- `writeObsidianTimeline`
- `writeObsidianTimelineSummary`

`obsidianExportFull` should call:

- `obsidianExportTimelineOnly`
- `materializeObsidianAssets`
- `writeObsidianNotes`
- `writeObsidianIndexes`
- `writeObsidianSidecars`

### 3. Reduce `ObsidianPaths`

Current `ObsidianPaths` includes detail/full-mode paths unconditionally.

Either:

- Keep one struct but document which fields are full-mode only, or
- Split into:

```zig
const ObsidianBasePaths = struct {
    vault: []const u8,
    root: []const u8,
    timeline: []const u8,
    indexes: []const u8,
    data: []const u8,
};

const ObsidianFullPaths = struct {
    base: ObsidianBasePaths,
    notes: []const u8,
    assets: []const u8,
    images: []const u8,
    previews: []const u8,
    avatars: []const u8,
};
```

Prefer the split if it makes call sites simpler.

### 4. Make Timeline Writer Independent

`writeObsidianTimeline` should not know about assets or detail notes.

Inputs:

- database
- allocator
- timeline path
- index path
- dry-run flag
- changed-only flag

Output:

- month files written
- month files skipped
- index written/skipped

### 5. Consolidate Asset Materialization

The current code has two separate export-copy patterns:

- viewer export media assets
- Obsidian full export assets

Extract a helper that takes:

- source asset row
- destination root
- naming policy
- validation policy

This can happen after timeline-only is split out, because timeline-only should not depend on asset materialization at all.

### 6. Replace JSON String Surgery

`writeObsidianConfig` currently replaces JSON object text manually.

Replace with one of:

1. Parse config JSON, modify object tree, stringify.
2. Write a separate small state file under the home dir, such as `obsidian.json`.
3. Stop mutating config in `obsidian init`; print the config stanza the user can add.

Preferred: parse and stringify the config object because the project already depends on Zig JSON parsing.

### 7. Delete or Gate Old Indexes

In timeline-only mode, do not write:

- `all-bookmarks.md`
- `incomplete.md`
- `failed-assets.md`
- `bookmarks-index.json`
- `media-assets-index.json`

In full mode, keep them for diagnostics.

### 8. Update Browser Viewer Boundaries

Keep the browser viewer independent from Obsidian Markdown.

Do not reintroduce generated Markdown rendering in the React app unless there is a separate explicit product decision.

## Migration Behavior

Existing vaults may already contain:

- `bookmarks/`
- `assets/`
- `indexes/all-bookmarks.md`
- `indexes/incomplete.md`
- `indexes/failed-assets.md`
- `data/bookmarks-index.json`
- `data/media-assets-index.json`

Default `timeline-only` export should not delete these immediately. It should:

- overwrite generated timeline files;
- overwrite `indexes/timeline.md`;
- overwrite minimal `data/export-summary.json`;
- leave old full-mode generated files alone unless `--clean-full-output` or similar is added later.

Optional later cleanup command:

```bash
x-bookmarks obsidian clean-full-output --dry-run
x-bookmarks obsidian clean-full-output
```

This avoids surprise deletion of preserved notes in `bookmarks/`.

## Validation Plan

Use a copied data directory and temporary vault first:

```bash
rm -rf /tmp/x-bookmarks-obsidian-simplification
mkdir -p /tmp/x-bookmarks-obsidian-simplification
cp -R data /tmp/x-bookmarks-obsidian-simplification/data
mkdir -p /tmp/x-bookmarks-obsidian-simplification/TestVault
```

Initialize:

```bash
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-obsidian-simplification/data obsidian init --vault /tmp/x-bookmarks-obsidian-simplification/TestVault
```

Dry run:

```bash
find /tmp/x-bookmarks-obsidian-simplification/TestVault -type f | sort > /tmp/before.txt
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-obsidian-simplification/data obsidian export --dry-run
find /tmp/x-bookmarks-obsidian-simplification/TestVault -type f | sort > /tmp/after.txt
diff -u /tmp/before.txt /tmp/after.txt
```

Expected:

- diff is empty;
- output lists planned month/index writes;
- no media assets are copied.

Export:

```bash
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-obsidian-simplification/data obsidian export
```

Expected:

- `timeline/<year>/<year-month>.md` files exist.
- `indexes/timeline.md` exists.
- Month files contain day headings and `![](https://x.com/...)` lines.
- Month files do not contain tweet text excerpts, local image paths, detail links, or generated author headings.
- Default export does not create new `assets/` files.
- Default export does not create/update `bookmarks/<tweet_id>.md`.

Full mode:

```bash
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-obsidian-simplification/data obsidian export --mode full
```

Expected:

- timeline output still exists;
- detail notes exist;
- image-class assets exist;
- failed-assets index exists.

Changed mode:

```bash
./zig-out/bin/x-bookmarks --home /tmp/x-bookmarks-obsidian-simplification/data obsidian export --changed
```

Expected:

- immediately after export, zero month files are rewritten;
- after changing one source row in a copied DB, only the affected month and timeline index are rewritten if necessary.

## Success Criteria

- Default Obsidian export is timeline-only and writes only URL embed timeline files plus minimal navigation/summary.
- Full note and asset export is explicitly opt-in.
- The browser viewer no longer depends on generated Markdown.
- Config no longer has unused or misleading Obsidian fields in the default path.
- Timeline export can be understood without reading the media/detail-note renderer.
- Existing vault content is not surprise-deleted by the simplification.


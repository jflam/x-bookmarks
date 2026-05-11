# Obsidian Markdown Export And Media Policy Plan

Date: 2026-05-11

## Goal

Add an Obsidian-first export mode to `x-bookmarks` that writes one Markdown note per bookmarked tweet into a tool-owned directory inside an Obsidian vault, while preserving the existing SQLite database as the source of truth and avoiding any need to refetch already-ingested bookmarks.

The export should make the Obsidian vault usable as the primary human viewer. The existing browser viewer can then evolve to render the same generated Markdown, rather than maintaining a separate HTML rendering model directly from tweet JSON.

## Current State

The current importer has already synced a substantial local bookmark dataset. After the first full run, the local store contained:

- 634 active bookmarks.
- 779 stored tweets, including quote-post expansion records.
- 1,171 media asset records.
- 622 complete bookmarks and 12 incomplete bookmarks.
- 3 bookmark folders.
- No missing database references.

The existing asset policy downloads images, preview images, avatars, selected MP4 video variants, and animated GIF variants. The full sync showed that MP4 downloads are too large for the intended Obsidian-backed workflow. Future runs should not download video/GIF variants by default.

## Product Decisions

- SQLite remains the canonical local source of truth for sync state, raw JSON, normalized tweets, users, folders, media metadata, retrieval status, and errors.
- Obsidian Markdown files are a generated projection of the SQLite state.
- The tool owns a dedicated subtree inside the vault and must not write outside that subtree.
- The first Markdown format uses a generated region plus a preserved user notes region in the same file.
- Images remain normal files for Obsidian rendering.
- Videos are not downloaded by default. Store remote video variant URLs and render local preview images that link to X or the remote media URL.
- Existing local video/GIF downloads may be removed after migration because the new default viewer path no longer needs local MP4/GIF assets.
- Existing downloaded images, previews, avatars, tweet JSON, folders, and bookmark rows must be reused. Do not require a new full X API sync to adopt this feature.

## Vault Layout

The tool should manage a root directory under the configured Obsidian vault.

Default layout:

```text
<vault>/
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
      export-summary.json
```

Ownership boundary:

- `X Bookmarks/bookmarks/`: tool may create files and update managed regions inside files.
- `X Bookmarks/assets/`: tool may create, replace, dedupe, and delete materialized generated assets.
- `X Bookmarks/indexes/`: tool may rewrite generated index notes.
- `X Bookmarks/data/`: tool may rewrite generated JSON sidecar indexes.
- The tool must not modify files outside `X Bookmarks/`.
- The tool must not delete user-owned content outside managed generated blocks.

## Configuration

Extend the config file with an `obsidian` object.

Example:

```json
{
  "obsidian": {
    "vault_path": "/Users/jflam/Obsidian/Main",
    "root_dir": "X Bookmarks",
    "note_dir": "bookmarks",
    "asset_dir": "assets",
    "index_dir": "indexes",
    "data_dir": "data",
    "preserve_user_notes": true,
    "media_policy": "images-only"
  }
}
```

Path rules:

- `vault_path` is absolute.
- `root_dir`, `note_dir`, `asset_dir`, `index_dir`, and `data_dir` are relative to the vault or the managed root.
- Reject path traversal such as `../`.
- Reject an `obsidian.root_dir` that resolves outside the vault.
- If `vault_path` is not configured, `obsidian export` should fail with an actionable error unless `--vault PATH` is provided.

## CLI Design

Add an `obsidian` command group.

```bash
x-bookmarks obsidian init --vault /path/to/vault
x-bookmarks obsidian status
x-bookmarks obsidian export
x-bookmarks obsidian export --changed
x-bookmarks obsidian export --dry-run
x-bookmarks obsidian export --clean-stale
x-bookmarks obsidian migrate-media --dry-run
x-bookmarks obsidian migrate-media --remove-local-videos
```

Command behavior:

- `obsidian init` writes config, creates the managed root directories, and writes a short README note inside `X Bookmarks/`.
- `obsidian status` prints resolved paths, bookmark counts, exported note counts, failed media counts, and stale note counts.
- `obsidian export` writes or updates Markdown notes, materializes image-class assets, and writes index notes.
- `obsidian export --changed` exports only notes whose source tweet/bookmark/media state changed since the last successful export.
- `obsidian export --dry-run` prints planned note writes, asset writes, stale notes, and cleanup candidates without changing the vault.
- `obsidian export --clean-stale` moves notes for inactive/deleted bookmarks to an archive area or marks them inactive; it should not hard-delete user notes in the first implementation.
- `obsidian migrate-media --dry-run` reports local video/GIF assets that are no longer needed under the new `images-only` policy.
- `obsidian migrate-media --remove-local-videos` removes local files for video/GIF variant assets and updates their database rows to a non-downloaded status that preserves source URL, byte size, hash, and removal reason.

## Markdown File Format

Each active bookmarked tweet gets one Markdown file:

```text
X Bookmarks/bookmarks/<tweet_id>.md
```

Initial filename rule:

- Use `<tweet_id>.md` for stability.
- Do not include author names or tweet text in filenames in the first version; those change and create rename churn.

Each note contains YAML frontmatter, a managed generated block, and a preserved notes section.

Example:

```markdown
---
x_bookmarks_schema: 1
tweet_id: "2053123843531981217"
author_id: "123"
author_username: "ashleevance"
author_name: "Ashlee Vance"
created_at: "2026-05-01T12:34:56.000Z"
bookmarked_at: "2026-05-10T20:00:00Z"
canonical_url: "https://x.com/ashleevance/status/2053123843531981217"
twitter_url: "https://twitter.com/ashleevance/status/2053123843531981217"
folders:
  - "AI"
complete_for_offline_render: false
media_status: "partial"
asset_error_count: 1
tags:
  - x-bookmark
  - x-bookmark/incomplete
---

<!-- x-bookmarks:generated:start -->
# @ashleevance

Full tweet text from the stored JSON or normalized tweet text.

> Quoted tweet text, if present.

![Video preview](../assets/previews/13_2053123843531981217.jpg)

[Open on X](https://x.com/ashleevance/status/2053123843531981217)

Media retrieval:

| Kind | Status | Detail |
| --- | --- | --- |
| preview_image | downloaded | `../assets/previews/13_2053123843531981217.jpg` |
| video_variant | remote_only | Local video download skipped by images-only policy. |
<!-- x-bookmarks:generated:end -->

## Notes

<!-- User notes below this line are preserved by x-bookmarks. -->
```

Generated block rules:

- The exporter may replace everything between `<!-- x-bookmarks:generated:start -->` and `<!-- x-bookmarks:generated:end -->`.
- The exporter must preserve everything outside the generated block.
- If an existing file lacks markers, the exporter must not overwrite it by default. It should write a conflict file or fail with instructions.
- Frontmatter should be treated as tool-managed in the first version. If users need custom YAML later, add a dedicated preserved custom frontmatter block or companion note.

## Media Policy

Add an explicit media policy for future syncs and exports.

Policies:

- `images-only`: default. Download images, preview images, and avatars. Do not download video/GIF variants. Store remote video metadata and source URLs.
- `all-local`: current archival behavior. Download images, previews, avatars, and selected video/GIF variants.
- `metadata-only`: store tweet/media metadata and retrieval status, but do not download image/video bytes.

Recommended default:

```text
images-only
```

Rationale:

- Obsidian renders normal image files well.
- MP4 variants are large and made the full sync slow.
- Remote video playback is acceptable for the human viewer, with canonical tweet links as fallback.
- Downstream agents can use structured media status fields rather than assuming every remote video is locally available.

## Database Changes

The existing `media_assets` table already has the essential fields:

- `asset_kind`
- `source_url`
- `local_path`
- `content_type`
- `byte_size`
- `sha256`
- `status`
- `error_json`

Add migrations only where they make downstream behavior clearer.

Recommended additions:

```sql
ALTER TABLE media_assets ADD COLUMN retrieval_policy TEXT;
ALTER TABLE media_assets ADD COLUMN retry_class TEXT;
ALTER TABLE media_assets ADD COLUMN attempts INTEGER DEFAULT 0;
ALTER TABLE media_assets ADD COLUMN last_error_at TEXT;
ALTER TABLE media_assets ADD COLUMN removed_at TEXT;
ALTER TABLE media_assets ADD COLUMN removal_reason TEXT;
```

Status vocabulary:

- `downloaded`: bytes exist locally and passed validation.
- `failed`: retrieval attempted and failed.
- `skipped`: retrieval intentionally skipped because no usable asset exists or policy excludes it.
- `remote_only`: remote URL is retained and local bytes are intentionally absent.
- `removed`: local bytes were previously downloaded but were intentionally removed after migration.

Retry classification:

- `transient`: retry may succeed later. Examples: DNS failure, timeout, HTTP 429, HTTP 5xx.
- `permanent`: retry is unlikely to succeed. Examples: HTTP 403, HTTP 404, malformed URL.
- `policy`: local retrieval is intentionally disabled by media policy.
- `unknown`: not classified yet.

## Migration Strategy

The migration must use existing local data. It must not require refetching bookmarks or media metadata from X.

### Phase 1: Schema Migration

1. Add new nullable columns to `media_assets`.
2. Backfill `retrieval_policy`:
   - `image`, `preview_image`, and `author_avatar`: `images-only`.
   - `video_variant` and `animated_gif_variant`: `all-local` for rows that already downloaded local files.
   - Existing failed video/GIF rows: `images-only` if future default policy would skip local download.
3. Backfill `retry_class`:
   - `status='failed'` and `error_json` contains HTTP 5xx, `UnknownHostName`, timeout, or connection reset: `transient`.
   - `status='failed'` and `error_json` contains HTTP 403 or 404: `permanent`.
   - `status='skipped'`: `policy` or `permanent`, depending on reason.
   - `status='downloaded'`: null.

### Phase 2: Export Asset Materialization

1. Use existing `media_assets.local_path` for downloaded image-class assets.
2. Copy or hard-link image-class assets into the vault under `X Bookmarks/assets/`.
3. Preserve deterministic asset names:
   - `assets/images/<media_key>-<sha256>.<ext>`
   - `assets/previews/<media_key>-<sha256>.<ext>`
   - `assets/avatars/<user_id>-<sha256>.<ext>`
4. Record generated viewer/vault paths in sidecar JSON. Do not need to store Obsidian paths in the canonical database unless incremental export requires it.

### Phase 3: Video/GIF Local File Cleanup

The cleanup step is opt-in.

Dry run:

```bash
x-bookmarks obsidian migrate-media --dry-run
```

Expected output:

```text
video/GIF local assets eligible for removal: N
bytes recoverable: X
database rows to mark removed: N
files missing already: M
```

Apply:

```bash
x-bookmarks obsidian migrate-media --remove-local-videos
```

Behavior:

1. Select rows where `asset_kind IN ('video_variant', 'animated_gif_variant')` and `status='downloaded'`.
2. Validate that the row still has `source_url`, `byte_size`, and `sha256` metadata.
3. Delete the local file if it exists under the configured `assets_dir`.
4. Update the row:
   - `status='removed'`
   - `removed_at=<now>`
   - `removal_reason='images-only media policy; remote playback retained'`
   - keep `source_url`, `content_type`, `byte_size`, and `sha256`
   - clear or preserve `local_path` based on implementation preference, but exported code must not treat it as locally usable unless `status='downloaded'`
5. Recompute `bookmark_items.complete_for_offline_render` under the new policy so bookmarks are not incomplete merely because local MP4 bytes were intentionally removed.

Safety:

- Only delete files whose resolved path is under configured `assets_dir`.
- Never delete image, preview image, or avatar assets.
- Never delete files during normal `obsidian export`.
- Never delete files during `--dry-run`.
- Print every deletion in verbose mode.

### Phase 4: No-Refetch Validation

After migration, run export from the existing database:

```bash
x-bookmarks obsidian export --dry-run
x-bookmarks obsidian export
```

This must not call X API endpoints. It should only read SQLite and local image files.

## Sync Changes For Future Runs

Update the importer so future syncs honor media policy.

For `images-only`:

- Download tweet `url` images.
- Download `preview_image_url`.
- Download author avatars, unless avatar downloads are later made optional.
- Do not download `variants[].url` for `video` or `animated_gif`.
- Record a `media_assets` row for each video/GIF variant decision:
  - `asset_kind='video_variant'` or `animated_gif_variant`
  - `source_url=<selected remote URL>`
  - `status='remote_only'`
  - `retrieval_policy='images-only'`
  - `error_json='{"reason":"local_video_disabled_by_policy"}'`

For `all-local`:

- Preserve existing behavior, but keep progress output and retry classification.

## Failed Asset Retry Mode

Add a separate retry path for transient image/avatar/preview failures.

```bash
x-bookmarks assets retry
x-bookmarks assets retry --only-transient
x-bookmarks assets retry --kind image
x-bookmarks assets retry --kind preview_image
x-bookmarks assets retry --kind author_avatar
x-bookmarks assets retry --max-attempts 3
x-bookmarks assets retry --dry-run
```

Default behavior:

- Retry `status='failed'` rows where `retry_class='transient'`.
- Exclude `video_variant` and `animated_gif_variant` when media policy is `images-only`.
- On success, update the row to `downloaded` and write local bytes.
- On failure, increment `attempts`, update `error_json`, `last_error_at`, and `retry_class`.

This command is independent from `obsidian export`. Export should not unexpectedly hit the network.

## Browser Viewer Changes

The browser viewer should eventually render the generated Markdown files.

Near-term approach:

- Keep JSON sidecar indexes for filtering, sorting, folder selection, and search.
- Load the generated Markdown note for the selected bookmark.
- Render Markdown to HTML in the viewer.
- Use the same asset paths that Obsidian uses when the viewer is served from the exported vault subtree.

Video rendering:

- Render the local preview image.
- Add a play/open affordance that links to:
  1. remote selected MP4 URL if present and usable by the browser, or
  2. canonical X tweet URL as fallback.
- If remote playback fails, show an inline diagnostic and keep the X link visible.

## Markdown Rendering Details

Tweet text:

- Use the full stored tweet text, not card preview text.
- Preserve line breaks.
- Escape Markdown control characters where needed.
- Use normal Markdown links for URLs when expansion metadata is unavailable.

Quote posts:

- Render direct quoted tweets as blockquotes or a nested callout.
- Include quoted author, text, canonical URL, and preview assets where available.
- Do not recursively expand beyond direct quote posts in the first version.

Media:

- Render downloaded image assets with relative paths.
- Render video preview images as linked images.
- Render failed/skipped/remote-only media in a compact diagnostic table.

Folders and tags:

- Mirror bookmark folders into YAML frontmatter.
- Add stable tags such as:
  - `x-bookmark`
  - `x-bookmark/incomplete`
  - `x-bookmark/media-partial`

## Index Notes

Generate index notes for Obsidian navigation.

`indexes/all-bookmarks.md`:

- List every active bookmark in reverse bookmark/import order.
- Include author, date, short text excerpt, and wikilink to note.

`indexes/incomplete.md`:

- List bookmarks with failed, missing, skipped, or remote-only media.
- Include status counts and links to notes.

`indexes/failed-assets.md`:

- Group failed assets by retry class and asset kind.
- Include retry command examples.

Optional later indexes:

- Per-folder notes.
- Per-author notes.
- Per-tag/topic notes generated by downstream agents.

## Manual Validation

Perform these steps after implementation. Use a copy of the current `data/` directory first.

### 1. Prepare A Safe Test Copy

From the repo root:

```bash
rm -rf /tmp/x-bookmarks-obsidian-validation
mkdir -p /tmp/x-bookmarks-obsidian-validation
cp -R data /tmp/x-bookmarks-obsidian-validation/data
mkdir -p /tmp/x-bookmarks-obsidian-validation/TestVault
```

Use the copied state for validation:

```bash
export XB_HOME=/tmp/x-bookmarks-obsidian-validation/data
export XB_VAULT=/tmp/x-bookmarks-obsidian-validation/TestVault
```

Confirm the copied database has the expected existing data:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" bookmarks stats
```

Expected:

- Bookmark count is nonzero.
- No OAuth login or X API call is required.
- Counts match or are close to the source dataset being migrated.

### 2. Initialize Obsidian Export

Run:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian init --vault "$XB_VAULT"
```

Verify:

```bash
find "$XB_VAULT/X Bookmarks" -maxdepth 2 -type d | sort
```

Expected directories:

- `X Bookmarks/bookmarks`
- `X Bookmarks/assets`
- `X Bookmarks/indexes`
- `X Bookmarks/data`

Run:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian status
```

Expected:

- Resolved vault path is under `$XB_VAULT`.
- Managed root is `$XB_VAULT/X Bookmarks`.
- Bookmark counts are printed.
- Media policy is `images-only` unless explicitly configured otherwise.

### 3. Validate Dry Run Does Not Write

Capture state before dry run:

```bash
find "$XB_VAULT" -type f | sort > /tmp/x-bookmarks-before-dry-run.txt
```

Run:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian export --dry-run
```

Capture state after dry run:

```bash
find "$XB_VAULT" -type f | sort > /tmp/x-bookmarks-after-dry-run.txt
diff -u /tmp/x-bookmarks-before-dry-run.txt /tmp/x-bookmarks-after-dry-run.txt
```

Expected:

- The dry run prints planned note writes and asset materialization.
- The diff is empty.
- No X API progress output appears.
- No network authentication prompt appears.

### 4. Export Markdown Notes

Run:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian export
```

Verify note count:

```bash
find "$XB_VAULT/X Bookmarks/bookmarks" -name '*.md' | wc -l
```

Expected:

- Count equals active bookmarks from `bookmarks stats`.

Inspect a known note:

```bash
sed -n '1,120p' "$XB_VAULT/X Bookmarks/bookmarks/2053123843531981217.md"
```

Expected:

- YAML frontmatter exists.
- `tweet_id` matches filename.
- `canonical_url` points to X.
- Generated markers exist.
- Full tweet text is present.
- Preview image is referenced if available.
- Video is represented as remote-only or linked preview, not as a local MP4.
- `## Notes` section exists.

### 5. Validate User Notes Preservation

Append user text below the notes marker:

```bash
cat >> "$XB_VAULT/X Bookmarks/bookmarks/2053123843531981217.md" <<'EOF'

Manual validation note: preserve this line.
EOF
```

Run export again:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian export
```

Verify:

```bash
rg -n "Manual validation note: preserve this line" "$XB_VAULT/X Bookmarks/bookmarks/2053123843531981217.md"
```

Expected:

- The line remains.
- The generated block may change.
- Content outside the generated block is preserved.

### 6. Validate Existing Data Was Reused

Run export with network disabled if practical, or inspect output for network activity.

Expected:

- No `sync: requesting bookmark page` output appears.
- No OAuth browser opens.
- No X API request is needed.
- Notes and image assets are generated from SQLite and existing asset files only.

Database spot check:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" bookmarks stats
```

Expected:

- Bookmark count is unchanged after export.
- Export does not insert duplicate bookmarks.
- Export does not create new tweet rows.

### 7. Validate Image Asset Materialization

List materialized assets:

```bash
find "$XB_VAULT/X Bookmarks/assets" -type f | head -50
```

Expected:

- Image, preview, and avatar files exist when source assets were downloaded.
- No `.mp4` files are created by default under the vault.

Check Markdown references:

```bash
rg -n "assets/.*\\.(jpg|jpeg|png|webp|gif)" "$XB_VAULT/X Bookmarks/bookmarks" | head -20
```

Expected:

- Referenced image paths resolve relative to the Markdown file.
- Obsidian can display the images.

### 8. Validate Video Policy

Search for local video references in generated Markdown:

```bash
rg -n "\\.(mp4|mov|m3u8)" "$XB_VAULT/X Bookmarks/bookmarks" "$XB_VAULT/X Bookmarks/assets" || true
```

Expected:

- No local asset path points to a generated `.mp4` file.
- Markdown may contain remote video URLs only if the implementation intentionally exposes them.
- Each video note includes a canonical X link fallback.

Open a video-containing note in Obsidian.

Expected:

- A preview image renders.
- A visible link or play affordance opens the X tweet or remote media.
- If remote playback is unavailable, the note still explains the media status.

### 9. Validate Failed Asset Diagnostics

Open the failed-assets index:

```bash
sed -n '1,160p' "$XB_VAULT/X Bookmarks/indexes/failed-assets.md"
```

Expected:

- Failed assets are grouped by kind and retry class.
- Transient errors such as HTTP 503 or DNS failures are clearly labeled.
- Suggested retry command is shown.

Inspect a note with incomplete media:

```bash
rg -n "media_status: \"partial\"|asset_error_count: [1-9]" "$XB_VAULT/X Bookmarks/bookmarks" | head
```

Expected:

- The note has frontmatter identifying partial media.
- The generated block includes a media retrieval table.
- Downstream agents can determine that media is unavailable without attempting to infer from missing files.

### 10. Validate Retry Command Dry Run

Run:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" assets retry --dry-run
```

Expected:

- Only transient failed image/avatar/preview assets are listed by default.
- Video/GIF assets are excluded under `images-only`.
- No files or database rows are changed.

If network retry is safe to test, run:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" assets retry --only-transient --max-attempts 1
```

Expected:

- Successful retries become `downloaded`.
- Failed retries increment attempts and preserve updated error details.
- `obsidian export` after retry updates affected notes and indexes.

### 11. Validate Video Cleanup Dry Run

Run:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian migrate-media --dry-run
```

Expected:

- Prints number of local video/GIF variant files eligible for removal.
- Prints recoverable bytes.
- Does not delete files.
- Does not modify database rows.

Capture current video file count:

```bash
find "$XB_HOME/assets" -type f \\( -name '*.mp4' -o -name '*.m3u8' \\) | wc -l
```

### 12. Validate Video Cleanup Apply

Only run this against the copied validation home first:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian migrate-media --remove-local-videos
```

Verify:

```bash
find "$XB_HOME/assets" -type f \\( -name '*.mp4' -o -name '*.m3u8' \\) | wc -l
./zig-out/bin/x-bookmarks --home "$XB_HOME" bookmarks stats
```

Expected:

- Local video/GIF files selected by dry run are removed.
- Image, preview, and avatar files remain.
- Media asset rows retain source URL and metadata.
- Rows for removed video/GIF assets are marked `removed` or `remote_only`.
- Bookmarks are not marked incomplete solely because local video bytes were intentionally removed under `images-only`.

Run export again:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian export
```

Expected:

- Export succeeds.
- Notes still render image previews.
- Video notes still contain canonical tweet links or remote playback links.

### 13. Validate Path Safety

Attempt invalid paths:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" obsidian init --vault "$XB_VAULT" --root-dir "../Outside"
```

Expected:

- Command fails.
- No files are created outside `$XB_VAULT`.

Verify:

```bash
test ! -e /tmp/x-bookmarks-obsidian-validation/Outside
```

### 14. Validate Obsidian Rendering

Open `$XB_VAULT` in Obsidian.

Verify:

- `X Bookmarks/indexes/all-bookmarks.md` is visible.
- Links from index notes open tweet notes.
- Tweet notes render Markdown without raw HTML unless intentionally used.
- Images render inline.
- User notes area is editable.
- Re-running export does not erase user edits below the generated block.
- Search for `tag:#x-bookmark` finds generated notes.
- Folder frontmatter is visible and useful to Obsidian properties.

### 15. Validate Browser Viewer Compatibility

If the browser viewer has been updated to render Markdown:

```bash
./zig-out/bin/x-bookmarks --home "$XB_HOME" viewer export
./zig-out/bin/x-bookmarks --home "$XB_HOME" viewer serve
```

Open the served URL.

Expected:

- Bookmark list loads.
- Selecting a bookmark renders the same generated Markdown content.
- Folder filters still work from JSON sidecar indexes.
- Failed media placeholders match the Obsidian note content.
- Video preview links behave consistently with Obsidian.

### 16. Validate Production Migration

After the copied validation home passes:

1. Back up the real `data/` directory.
2. Back up the target Obsidian vault.
3. Run `obsidian init` against the real vault.
4. Run `obsidian export --dry-run`.
5. Run `obsidian export`.
6. Inspect the vault in Obsidian.
7. Run `obsidian migrate-media --dry-run`.
8. Only then run `obsidian migrate-media --remove-local-videos` if the dry-run output is expected.

Production commands:

```bash
cp -R data "data.backup.$(date +%Y%m%d-%H%M%S)"
./zig-out/bin/x-bookmarks --home data obsidian init --vault /path/to/real/vault
./zig-out/bin/x-bookmarks --home data obsidian export --dry-run
./zig-out/bin/x-bookmarks --home data obsidian export
./zig-out/bin/x-bookmarks --home data obsidian migrate-media --dry-run
```

Do not run destructive cleanup on the real data until the copied validation home has passed all checks.

## Implementation Order

1. Add config parsing and `obsidian init/status` commands.
2. Add schema migration for media policy and retry metadata.
3. Add Markdown generation with managed block preservation.
4. Add image asset materialization into the vault.
5. Add index note generation.
6. Update sync media policy so future runs default to images-only.
7. Add `assets retry`.
8. Add video/GIF cleanup dry-run.
9. Add video/GIF cleanup apply.
10. Update browser viewer to render generated Markdown.
11. Update README and quickstart docs.

## Open Questions

- Should avatars be materialized in Obsidian notes by default, or only included in sidecar indexes?
- Should generated note filenames remain bare tweet IDs forever, or should a later optional mode use date and author slugs?
- Should frontmatter be fully tool-managed, or should users get a preserved custom YAML section?
- Should `obsidian export --clean-stale` archive inactive bookmarks or mark them inactive in-place?
- Should remote video links prefer selected MP4 variant URLs or canonical tweet URLs by default?

## Success Criteria

- A user can point `x-bookmarks` at an Obsidian vault and generate one Markdown note per existing bookmark without refetching from X.
- Re-running export updates generated tweet content and preserves user notes.
- Images render in Obsidian from normal files.
- Videos no longer consume local disk by default and still have useful preview/link behavior.
- Failed and skipped media are explicit in frontmatter, generated Markdown, sidecar JSON, and indexes.
- Existing downloaded video files can be safely removed through an opt-in migration command.
- The current browser viewer can eventually use the same Markdown content, eliminating a separate rendering path.

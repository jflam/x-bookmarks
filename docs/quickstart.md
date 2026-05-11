# x-bookmarks Quickstart

This guide covers the common bookmark sync flows after OAuth and database setup are already working.

For repo-local development state, include `--home data` in every command:

```sh
./zig-out/bin/x-bookmarks --home data ...
```

For the normal installed state, omit `--home data`:

```sh
./zig-out/bin/x-bookmarks ...
```

## Authenticate With X

Configure the X OAuth client ID and the exact localhost redirect URI registered in the X Developer Console:

```sh
./zig-out/bin/x-bookmarks --home data config init --client-id YOUR_CLIENT_ID --redirect-uri http://127.0.0.1:8765/callback
```

If your app is configured as a confidential web app, add `x.client_secret` to the generated config file before logging in. Keep that file local and out of git.

Run the browser-based OAuth flow with one command:

```sh
./zig-out/bin/x-bookmarks --home data auth login
```

The command starts a temporary local web server for the configured redirect URI, opens the X authorization URL in your default browser when possible, captures the callback, exchanges the authorization code, writes the token file, and records the authenticated account locally.

If browser auto-open is not available:

```sh
./zig-out/bin/x-bookmarks --home data auth login --no-open
```

Then open the printed URL manually in a browser. The local callback is still captured automatically.

Confirm the token:

```sh
./zig-out/bin/x-bookmarks --home data auth status
```

`auth status` should report both access and refresh tokens as present.

## Check Current Local State

Use local stats to see how many bookmarks are currently stored:

```sh
./zig-out/bin/x-bookmarks --home data bookmarks stats
```

The key fields are:

- `bookmarks`: active bookmarks stored locally.
- `complete`: bookmarks with enough local tweet, author, quote, folder, and media state for offline rendering.
- `incomplete`: bookmarks that are known locally but still need some referenced state or media.
- `media assets`: local media/avatar asset records.

Use the list command to inspect the newest locally stored bookmarks in API/import order:

```sh
./zig-out/bin/x-bookmarks --home data bookmarks list --limit 50
```

The X bookmark API response used by this tool exposes page counts and pagination tokens, not a single reliable "total bookmarks in account" value. The practical way to know the total exposed to this importer is to run a full sync and then check `bookmarks stats`.

## Download All Bookmarks

For a first-time import, run a full sync:

```sh
./zig-out/bin/x-bookmarks --home data sync --full --yolo
```

`--full` follows X pagination until the API stops returning `meta.next_token`. It does not stop when it reaches a bookmark that already exists locally.

By default:

- `max_results` is `100`, the page size used for each bookmark API request.
- media download is enabled.
- folder metadata and folder membership are synced after bookmark pages.

You can make the page size explicit:

```sh
./zig-out/bin/x-bookmarks --home data sync --full --yolo --max-results 100
```

Use `--wait-rate-limit` if you want the command to sleep until X's reset time instead of failing immediately on rate limits:

```sh
./zig-out/bin/x-bookmarks --home data sync --full --yolo --wait-rate-limit
```

For metadata-only testing, use `--no-media`; this is faster but does not produce a complete offline viewer for media posts:

```sh
./zig-out/bin/x-bookmarks --home data sync --full --yolo --no-media
```

Do not use `--limit-pages` for the real first import. It intentionally caps pagination and is meant for validation or debugging.

## Incremental Sync

Normal sync is incremental:

```sh
./zig-out/bin/x-bookmarks --home data sync --yolo
```

The sync starts at the newest bookmark page returned by X. In normal mode, the importer stops when it reaches the first bookmark already marked `complete_for_offline_render = 1`.

Expected output looks like:

```text
sync succeeded: pages=1 tweets=1 new_bookmarks=1 early_stop=true
```

Interpretation:

- `pages`: bookmark pages fetched from X.
- `tweets`: bookmark rows actually processed before stopping.
- `new_bookmarks`: bookmark rows inserted for the first time.
- `early_stop=true`: the run found an already-complete local bookmark and stopped early.

If you previously had 50 local bookmarks, then bookmark one new post and run a normal sync, the expected successful incremental result is `new_bookmarks=1`. The command still has to fetch at least the first page from X to discover where the new bookmark list meets local state.

Important caveat: media download is page-level. If the first API page contains one new bookmark plus 49 existing bookmarks, the importer inserts only the new bookmark before early stop, and valid existing assets are reused rather than redownloaded. However, if older bookmarks on that fetched page have missing media/avatar assets, the run may repair those missing assets too.

## Validate Incremental Downloading

Use this flow to validate that a new bookmark is picked up incrementally:

1. Confirm the current local baseline:

   ```sh
   ./zig-out/bin/x-bookmarks --home data bookmarks stats
   ./zig-out/bin/x-bookmarks --home data bookmarks list --limit 5
   ```

2. Bookmark one new post in X.

3. Run a normal incremental sync:

   ```sh
   ./zig-out/bin/x-bookmarks --home data sync --yolo
   ```

4. Check the sync summary line. For exactly one new bookmark, expect:

   ```text
   new_bookmarks=1
   ```

   In the common case, expect `early_stop=true` because the importer found the first already-complete local bookmark and stopped.

5. Confirm local state increased by one:

   ```sh
   ./zig-out/bin/x-bookmarks --home data bookmarks stats
   ./zig-out/bin/x-bookmarks --home data bookmarks list --limit 5
   ```

6. Re-export and inspect the viewer:

   ```sh
   ./zig-out/bin/x-bookmarks --home data viewer export
   ./zig-out/bin/x-bookmarks --home data viewer serve
   ```

   Open:

   ```text
   http://127.0.0.1:8766/
   ```

## Export to Obsidian

Initialize a tool-owned subtree inside an Obsidian vault:

```sh
./zig-out/bin/x-bookmarks --home data obsidian init --vault /absolute/path/to/ObsidianVault
```

This creates the generated timeline/index/data directories under `X Bookmarks/` and records the vault path in config. SQLite plus `storage.assets_dir` remain the source of truth; the Obsidian vault is a generated viewing layer.

Preview the export without changing the vault:

```sh
./zig-out/bin/x-bookmarks --home data obsidian export --dry-run
```

Generate or update the default timeline export:

```sh
./zig-out/bin/x-bookmarks --home data obsidian export
```

The default export writes:

```text
X Bookmarks/timeline/<year>/<year-month>.md
X Bookmarks/indexes/timeline.md
X Bookmarks/data/export-summary.json
```

Monthly timeline notes group bookmarks by tweet creation month and contain one `![](https://x.com/...)` embed line per bookmark, so Obsidian embed plugins can render the tweets directly.

Generate the larger Markdown note and local image export explicitly:

```sh
./zig-out/bin/x-bookmarks --home data obsidian export --mode full
```

Full mode adds `bookmarks/<tweet_id>.md`, `assets/`, diagnostic indexes, and JSON sidecars. Re-export replaces each generated note block while preserving text below the `## Notes` area.

Check export status:

```sh
./zig-out/bin/x-bookmarks --home data obsidian status
```

Retry transient image/avatar/preview failures independently from export:

```sh
./zig-out/bin/x-bookmarks --home data assets retry --dry-run
./zig-out/bin/x-bookmarks --home data assets retry --only-transient --max-attempts 1
```

After validating a copied data directory first, inspect local video/GIF files that can be removed under the images-only policy:

```sh
./zig-out/bin/x-bookmarks --home data obsidian migrate-media --dry-run
```

Apply cleanup only after the dry-run output is expected:

```sh
./zig-out/bin/x-bookmarks --home data obsidian migrate-media --remove-local-videos
```

## Validate a Limited Page Fetch

Use `--limit-pages` only when you want a bounded test:

```sh
./zig-out/bin/x-bookmarks --home data sync --yolo --limit-pages 1 --max-results 50
```

This fetches at most one bookmark page with up to 50 results. It is useful for smoke testing progress and API shape, but it is not a full import.

If there is one new bookmark since the previous complete sync, this command should report `new_bookmarks=1`. It may also report `early_stop=true` if the first page includes an already-complete local bookmark after the new item.

## When To Use `--full`

Use normal incremental sync for day-to-day updates:

```sh
./zig-out/bin/x-bookmarks --home data sync --yolo
```

Use full sync when:

- this is the first real import;
- you want to reconcile the whole exposed bookmark collection;
- the tool warns that bookmark ordering shifted unexpectedly;
- you suspect older local state is incomplete and want to rescan all pages.

Full sync command:

```sh
./zig-out/bin/x-bookmarks --home data sync --full --yolo
```

After a successful uncapped full sync, bookmarks not seen in that run are marked inactive locally. If you combine `--full` with `--limit-pages`, the tool does not deactivate unseen bookmarks because the run was intentionally incomplete.

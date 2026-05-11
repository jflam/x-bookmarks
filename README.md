# x-bookmarks

`x-bookmarks` is a local CLI for importing an authenticated user's X/Twitter bookmarks into SQLite for offline use.

The goal is deterministic, agent-runnable ingestion:

- read all bookmarks exposed by the X API
- incrementally fetch newly saved bookmarks by stopping at the first already-complete local bookmark
- download post media for later offline rendering
- store post, author, media, quote-post, and folder metadata locally
- export and serve a local viewer for manual validation
- expose the data for downstream interest-graph and wiki-style pipelines

The importer is implemented in Zig as a single native executable with zero runtime dependencies. SQLite is embedded by compiling the vendored SQLite amalgamation into the binary, while data files live in the user's profile directories:

- config: `~/.config/x-bookmarks/config.json`
- database: `~/.local/share/x-bookmarks/x_bookmarks.sqlite`
- OAuth token: `~/.local/share/x-bookmarks/oauth-token.json`
- media assets: `~/.local/share/x-bookmarks/assets/`

For common first-import, incremental-sync, and viewer validation workflows, see [docs/quickstart.md](docs/quickstart.md).

See [plans/2026-05-10-x-bookmarks-importer.md](plans/2026-05-10-x-bookmarks-importer.md) for the implementation plan and X API research notes.

## Build

```bash
zig build
zig build test
zig build -Doptimize=ReleaseSafe
```

The binary is installed to:

```text
zig-out/bin/x-bookmarks
```

The visual validation app is separate from the importer runtime:

```bash
cd viewer
bun install
bun run dev
bun run build
```

## CLI

```bash
x-bookmarks config init --client-id YOUR_CLIENT_ID
x-bookmarks config status
x-bookmarks auth login
x-bookmarks auth login --no-open
x-bookmarks auth login --manual
x-bookmarks auth login --code RETURNED_CODE
x-bookmarks auth login --callback-url 'http://127.0.0.1:8765/callback?code=...&state=...'
x-bookmarks auth refresh
x-bookmarks db init
x-bookmarks db status
x-bookmarks sync --yolo
x-bookmarks sync --full --yolo
x-bookmarks sync --yolo --max-results 25 --no-media
x-bookmarks sync --yolo --download-media
x-bookmarks sync --yolo --wait-rate-limit
x-bookmarks export --format jsonl
x-bookmarks viewer export
x-bookmarks viewer serve
x-bookmarks assets verify
x-bookmarks assets retry --dry-run
x-bookmarks obsidian init --vault /path/to/vault
x-bookmarks obsidian status
x-bookmarks obsidian export --dry-run
x-bookmarks obsidian export
x-bookmarks obsidian export --mode full
x-bookmarks obsidian migrate-media --dry-run
x-bookmarks bookmarks stats
x-bookmarks bookmarks list --limit 50
x-bookmarks integration test --live --limit-pages 1
```

Common sync modes:

- `x-bookmarks sync --full --yolo`: first-time or reconciliation import; follows bookmark pagination until X stops returning `meta.next_token`.
- `x-bookmarks sync --yolo`: normal incremental sync; starts at the newest bookmark page and stops at the first bookmark already complete locally.
- `x-bookmarks sync --yolo --limit-pages 1 --max-results 50`: bounded smoke test; useful for validation, not a full import.
- `x-bookmarks bookmarks stats`: local active/complete/incomplete bookmark counts.

Use `--home data` for repo-local development state:

```bash
zig-out/bin/x-bookmarks --home data config init --force --client-id test-client
zig-out/bin/x-bookmarks --home data db init
zig-out/bin/x-bookmarks --home data viewer export
```

Exit codes are stable for automation: `2` command/argument errors, `3` config errors, `4` auth required, `5` rate limit, `6` HTTP/API error, `7` SQLite error.

## Live OAuth Validation

Live sync requires an X developer Project/App with OAuth 2.0 user-context access and the configured redirect URI.

```bash
zig-out/bin/x-bookmarks config init --client-id YOUR_CLIENT_ID --redirect-uri http://127.0.0.1:8765/callback
zig-out/bin/x-bookmarks auth login
zig-out/bin/x-bookmarks auth status
zig-out/bin/x-bookmarks integration test --live --limit-pages 1
```

`auth login` starts a temporary local web server for the configured redirect URI, opens the X authorization URL in the default browser when possible, captures the callback, exchanges the code, stores the OAuth token, and records the authenticated account locally. Use `--no-open` if you want the command to print the URL without launching a browser. Use `--manual`, `--code`, or `--callback-url` only as fallback flows.

The token file is intentionally separate from config. `auth status` should report both access and refresh tokens as present before running live integration tests.

## Current Scope

Implemented:

- config discovery/init/status with XDG paths and repo-local `--home` support
- SQLite migrations and local state for accounts, sync runs, raw pages, tweets, users, media, assets, bookmarks, folders, folder membership, and sync warnings
- OAuth 2.0 PKCE login with local callback capture, confidential-client token exchange/refresh, token persistence, and `/2/users/me`
- bookmark pagination sync with `--full`, normal incremental early-stop behavior, `--limit-pages`, `--max-results`, `--no-media`, `--download-media`, and `--wait-rate-limit`
- progress output during sync page fetch/store/commit, asset download/reuse/failure, and folder sync
- media/avatar downloads with idempotent source/hash reuse, preview-sized MP4 variant selection, missing-asset reconciliation, and asset verification
- quote-post ingestion, missing quote-reference records, full `note_tweet` text rendering, deterministic X/Twitter post URIs, and JSONL export
- static viewer export with local JSON manifests, copied media assets, folder filters, quote posts, media galleries, playable MP4 video previews, and byte-range streaming in `viewer serve`
- Obsidian export under a tool-owned vault subtree, defaulting to generated year/month timeline notes with one X embed per bookmark; full Markdown notes, image asset materialization, and diagnostic sidecars are opt-in with `--mode full`
- bookmark stats/list inspection and a gated live integration-test command

Known limitations:

- OAuth local callback capture requires an `http://127.0.0.1:PORT/path` or `http://localhost:PORT/path` redirect URI registered exactly in the X Developer Console.
- The X bookmark API response used here exposes pagination, not a reliable account-wide total count before syncing. Run `sync --full` and then `bookmarks stats` to see the total imported/exposed locally.
- Real X API integration tests require user credentials and are not enabled by default. Use `x-bookmarks integration test --live --limit-pages 1` only after configuring a real X developer app and OAuth token.

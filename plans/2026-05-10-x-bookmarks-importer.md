# X Bookmarks Importer Plan

Date: 2026-05-10

## Goal

Build a deterministic agent-runnable tool that incrementally reads the authenticated user's X/Twitter bookmarks, stores retrieved posts in a local SQLite database under the user profile data directory, and exposes the stored data for downstream interest graph and wiki-style knowledge map pipelines.

The importer must retrieve enough data for later full offline rendering of each bookmarked post. That includes the bookmarked post JSON, author metadata, referenced quote-post metadata, media metadata, and downloaded media assets such as images, preview images, animated GIF/video variants, and author avatars where available.

## Confirmed API Research

Official X API docs confirm:

- Bookmark lookup endpoint: `GET https://api.x.com/2/users/{id}/bookmarks`
- The `{id}` path parameter must be the authenticated user's own X user ID.
- OAuth 2.0 user-context authorization is required.
- Required read scopes are:
  - `tweet.read`
  - `users.read`
  - `bookmark.read`
- We should request `offline.access` during OAuth setup so refresh tokens can support non-interactive future syncs.
- `max_results` supports `1` through `100`; use `100` for deterministic page size.
- Pagination uses `pagination_token` and response `meta.next_token`.
- Current documented rate limit for `GET /2/users/:id/bookmarks` is `180 requests / 15 minutes / user`.
- Current documented rate limits for bookmark folders are `50 requests / 15 minutes / user` for both listing folders and fetching posts in a folder.
- `/2/users/me` can be used after OAuth login to discover the authenticated user ID.
- X bookmark folders are available through API endpoints:
  - `GET /2/users/{id}/bookmarks/folders`
  - `GET /2/users/{id}/bookmarks/folders/{folder_id}`
- The bookmark overview says X's bookmark endpoints require an approved developer account, a Project, an App, and user access tokens through OAuth 2.0 PKCE or 3-legged OAuth.
- The current X API uses pay-per-use pricing. "Owned Reads" apply to `GET /2/users/{id}/bookmarks` when `{id}` is the authenticated user and that user owns the developer app.
- Media fields available from bookmark lookup include `url`, `preview_image_url`, `variants`, `alt_text`, `height`, `width`, `type`, and `duration_ms`.
- The bookmark lookup expansion list supports direct referenced-post expansion via `referenced_tweets.id`, `referenced_tweets.id.author_id`, and `referenced_tweets.id.attachments.media_keys`.

Primary docs:

- https://docs.x.com/x-api/users/get-bookmarks
- https://docs.x.com/x-api/users/get-bookmark-folders
- https://docs.x.com/x-api/users/get-bookmarks-by-folder-id
- https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code
- https://docs.x.com/fundamentals/authentication/guides/v2-authentication-mapping
- https://docs.x.com/x-api/posts/bookmarks/introduction
- https://docs.x.com/x-api/fundamentals/rate-limits
- https://docs.x.com/x-api/getting-started/getting-access
- https://docs.x.com/x-api/getting-started/pricing
- Legacy bookmark introduction that mentions a possible 800-most-recent result behavior: https://developer.x.com/en/docs/x-api/tweets/bookmarks/introduction

## Resolved Research Conclusions

- Bookmark ordering is not documented in the current `GET /2/users/{id}/bookmarks` API reference. The importer must not depend on reverse chronological ordering for correctness. The default sync must scan until no `meta.next_token` is returned. Early-stop optimization can only be enabled explicitly after local empirical validation.
- Current docs do not document a hard total-result cap for bookmark lookup. Older developer docs mention returning the 800 most recent bookmarks. Because this may still be an account/tier/API behavior, the implementation must record total pages/results per run and warn if the API appears capped. The tool can only guarantee "all bookmarks exposed by the X API."
- API access requires an approved developer account, a Project, an App, OAuth 2.0 user-context credentials, and purchased/available X API pay-per-use credits if required by the developer account. The user should verify access in the Developer Console before running a full import.
- Bookmark folders/buckets are real API resources and should be supported as metadata. They are not required to discover the complete bookmark set because the main bookmarks endpoint returns all bookmarks exposed by the API, but folder membership should be synced when the folder endpoints are available.
- Media URLs are exposed as fields on Media objects. The current docs show `url`, `preview_image_url`, and video/GIF `variants[].url`, but they do not state a permanence or expiry guarantee for those URLs. The importer must download media during ingestion, store local files, keep source URLs for audit/debugging, and record download failures explicitly.
- Quote-post data needed for offline rendering should be requested through bookmark lookup expansions when possible. Only referenced tweets with `referenced_tweets.type == "quoted"` should be treated as quote posts for rendering. Do not recursively hydrate referenced posts beyond the direct quote.

## Proposed Runtime

Use Zig for the first implementation.

Reasons:

- This project is explicitly an experiment in using Zig for a practical local data-ingestion CLI.
- Zig can produce a small native executable that is easy for an agent or pipeline to run deterministically.
- The released CLI should have zero runtime dependencies: download the binary, place it in a directory, and run it.
- The tool should not depend on a Python/Node/Ruby runtime, virtual environment, package manager, or shell-specific setup.
- SQLite can be included by compiling the SQLite amalgamation into the binary, avoiding a runtime dependency on a system SQLite library.
- HTTP, JSON parsing, filesystem access, and command-line parsing should use Zig standard library facilities unless we hit a hard blocker.

Dependency policy:

- The `x-bookmarks` CLI must have zero runtime dependencies.
- Prefer zero third-party Zig package dependencies for the initial implementation.
- If SQLite is needed through C integration, vendor the SQLite amalgamation source in the repo and statically compile it into the executable.
- Do not require users or agents to install `sqlite3`, `curl`, Python, Node, or any OAuth helper tool to run the CLI.
- Build-time dependencies are limited to Zig and the source tree.

## Build Plan

Build the project as a Zig executable named `x-bookmarks`.

Developer build:

```bash
zig build
```

Release build:

```bash
zig build -Doptimize=ReleaseSafe
```

Test build:

```bash
zig build test
```

The binary should be installed by Zig into the normal build prefix:

```text
zig-out/bin/x-bookmarks
```

SQLite embedding:

- Vendor the official SQLite amalgamation into `vendor/sqlite/sqlite3.c` and `vendor/sqlite/sqlite3.h`.
- Compile `sqlite3.c` directly into the `x-bookmarks` executable from `build.zig`.
- Include `vendor/sqlite` as a C include path.
- Call `linkLibC()` because SQLite is C code.
- The SQLite database file remains external at `~/.local/share/x-bookmarks/x_bookmarks.sqlite`, but the SQLite engine is embedded in the binary.
- Record the vendored SQLite version in `vendor/sqlite/VERSION.txt` or a short README.

Proposed `build.zig` behavior:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "x-bookmarks",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
        },
    });
    exe.addIncludePath(b.path("vendor/sqlite"));
    exe.linkLibC();

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
        },
    });
    unit_tests.addIncludePath(b.path("vendor/sqlite"));
    unit_tests.linkLibC();

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

Recommended SQLite compile flags:

- `SQLITE_THREADSAFE=0`: single-process CLI usage; avoids mutex overhead.
- `SQLITE_OMIT_LOAD_EXTENSION`: reduces attack surface and avoids dynamic extension loading.
- `SQLITE_DQS=0`: disables double-quoted string literal compatibility.

Keep the first build simple. Add more SQLite flags only after measuring binary size or discovering a concrete requirement.

Proposed package layout:

```text
.
├── build.zig
├── build.zig.zon
├── config.example.json
├── data/
│   ├── config.json
│   └── x_bookmarks.sqlite
├── plans/
│   └── 2026-05-10-x-bookmarks-importer.md
├── src/
│   ├── main.zig
│   ├── auth.zig
│   ├── cli.zig
│   ├── config.zig
│   ├── db.zig
│   ├── migrations.zig
│   ├── sync.zig
│   └── x_api.zig
├── vendor/
│   └── sqlite/
│       ├── sqlite3.c
│       └── sqlite3.h
├── tests/
├── .gitignore
└── README.md
```

The CLI should use normal per-user config and data locations by default. The repo-local `data/` directory remains useful for tests, fixtures, and explicit `--home data` development runs, but it should not be the default location for real credentials or token state.

## Configuration Plan

Avoid a collection of environment variables for normal configuration. Use one user-level config file with deterministic discovery.

Configuration should be created and inspected by the CLI, not hand-assembled from scattered shell state.

Default config path:

```text
~/.config/x-bookmarks/config.json
```

Explicit override:

```bash
x-bookmarks --config path/to/config.json sync
```

Optional home override:

```bash
x-bookmarks --home path/to/state-dir sync
```

When `--home` is provided, default paths become:

```text
{home}/config.json
{home}/oauth-token.json
{home}/x_bookmarks.sqlite
```

Default state paths without `--home`:

```text
~/.config/x-bookmarks/config.json
~/.local/share/x-bookmarks/oauth-token.json
~/.local/share/x-bookmarks/x_bookmarks.sqlite
~/.local/share/x-bookmarks/assets/
```

On macOS, prefer the same XDG-style paths above for this project unless a future requirement says otherwise. This keeps the CLI behavior consistent across developer machines, agents, and Unix-like pipeline environments.

Initial `~/.config/x-bookmarks/config.json` shape:

```json
{
  "x": {
    "client_id": "your-client-id",
    "client_secret": null,
    "redirect_uri": "http://127.0.0.1:8765/callback",
    "scopes": ["tweet.read", "users.read", "bookmark.read", "offline.access"]
  },
  "storage": {
    "database_path": "~/.local/share/x-bookmarks/x_bookmarks.sqlite",
    "token_path": "~/.local/share/x-bookmarks/oauth-token.json",
    "assets_dir": "~/.local/share/x-bookmarks/assets"
  },
  "sync": {
    "max_results": 100,
    "store_raw_pages": true,
    "conservative_full_scan": true,
    "download_media": true,
    "quote_post_depth": 1,
    "require_approval": true
  }
}
```

Config rules:

- `x-bookmarks config init` creates `~/.config/x-bookmarks/config.json` from defaults and refuses to overwrite it unless `--force` is passed.
- `x-bookmarks config init --client-id VALUE --redirect-uri VALUE` can fill in the two common required settings without requiring a text editor.
- `x-bookmarks config status` validates that required fields are present, prints the resolved database path, token path, assets directory, redirect URI, scopes, and whether an OAuth token file exists.
- `~` must be expanded in config paths.
- If `XDG_CONFIG_HOME` is set, use `$XDG_CONFIG_HOME/x-bookmarks/config.json` instead of `~/.config/x-bookmarks/config.json`.
- If `XDG_DATA_HOME` is set, use `$XDG_DATA_HOME/x-bookmarks/` instead of `~/.local/share/x-bookmarks/`.
- `data/config.json` is still supported when explicitly selected through `--config` or `--home data`, and should be ignored by git.
- Commit `config.example.json` as the template.
- Do not require env vars for routine operation.
- Do not log client secrets, access tokens, refresh tokens, authorization codes, or full callback URLs.
- CLI flags can override config values for one command, but the normal path should be config-file driven.
- The tool should print the resolved config path in `x-bookmarks config status`.
- Relative paths inside config are resolved relative to the directory containing the config file. If `--home PATH` is provided, relative storage paths are resolved relative to that home directory.
- Missing parent directories should be created by commands that write local state.
- `sync.require_approval` defaults to `true` for interactive use.
- Agentic or scheduled invocations can pass `--yolo` to bypass confirmation prompts.

OAuth token location:

- Store OAuth token state at `~/.local/share/x-bookmarks/oauth-token.json` by default, as specified by `storage.token_path`.
- Keep token storage separate from general config so the user can review config without exposing live tokens.
- Restrict token file permissions to the current user when the platform supports it.
- Store account metadata in SQLite as well, but treat `oauth-token.json` as the canonical source for refresh/access token state.
- Add `data/config.json`, `data/oauth-token.json`, and `data/*.sqlite*` to `.gitignore`.

## OAuth Setup Plan

Add an interactive one-time auth flow:

```bash
x-bookmarks auth login
```

Required user-provided values:

- `client_id` in `~/.config/x-bookmarks/config.json`
- `client_secret` in `~/.config/x-bookmarks/config.json`, only if using a confidential client
- `redirect_uri` in `~/.config/x-bookmarks/config.json`, exactly matching the URI registered in the X Developer Console

The login command should:

1. Generate a PKCE verifier and challenge.
2. Generate an authorization URL with scopes:
   - `tweet.read`
   - `users.read`
   - `bookmark.read`
   - `offline.access`
3. Print the URL, and optionally open it if allowed.
4. Receive the callback code either through a local callback server or pasted redirect URL.
5. Exchange the authorization code for access and refresh tokens.
6. Call `/2/users/me` to identify the authenticated account.
7. Persist token metadata to `~/.local/share/x-bookmarks/oauth-token.json`.
8. Persist account metadata to SQLite.

Token storage:

- Store refresh/access token metadata in `~/.local/share/x-bookmarks/oauth-token.json` by default.
- Keep client secrets in `~/.config/x-bookmarks/config.json`, never in git.
- Keep token state out of SQLite so it can be rotated, deleted, backed up, or permissioned independently of the tweet database.
- Add local config, token files, and SQLite files to `.gitignore`.
- A future hardening pass can add macOS Keychain support, but the first implementation should remain portable and zero-dependency.

## SQLite Schema Plan

Database path:

```text
~/.local/share/x-bookmarks/x_bookmarks.sqlite
```

Initial tables:

### `schema_migrations`

Tracks applied schema versions.

Columns:

- `version TEXT PRIMARY KEY`
- `applied_at TEXT NOT NULL`

### `accounts`

Authenticated X accounts.

Columns:

- `user_id TEXT PRIMARY KEY`
- `username TEXT`
- `name TEXT`
- `raw_json TEXT NOT NULL`
- `created_at TEXT`
- `updated_at TEXT NOT NULL`

### `oauth_token_observations`

Non-secret OAuth token metadata for audit/debugging. This table must not store access tokens or refresh tokens.

Columns:

- `account_user_id TEXT PRIMARY KEY`
- `token_type TEXT`
- `scope TEXT`
- `expires_at TEXT`
- `token_file_path TEXT`
- `created_at TEXT NOT NULL`
- `updated_at TEXT NOT NULL`

### `sync_runs`

One row per sync attempt.

Columns:

- `id INTEGER PRIMARY KEY AUTOINCREMENT`
- `account_user_id TEXT NOT NULL`
- `mode TEXT NOT NULL`
- `status TEXT NOT NULL`
- `started_at TEXT NOT NULL`
- `finished_at TEXT`
- `request_params_json TEXT NOT NULL`
- `pages_requested INTEGER NOT NULL DEFAULT 0`
- `tweets_seen INTEGER NOT NULL DEFAULT 0`
- `new_bookmarks INTEGER NOT NULL DEFAULT 0`
- `error_json TEXT`

### `tweets`

Canonical stored tweet/post records.

Columns:

- `tweet_id TEXT PRIMARY KEY`
- `author_id TEXT`
- `conversation_id TEXT`
- `created_at TEXT`
- `text TEXT`
- `lang TEXT`
- `possibly_sensitive INTEGER`
- `raw_json TEXT NOT NULL`
- `first_seen_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`

### `users`

Users included by API expansions, especially tweet authors.

Columns:

- `user_id TEXT PRIMARY KEY`
- `username TEXT`
- `name TEXT`
- `description TEXT`
- `raw_json TEXT NOT NULL`
- `first_seen_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`

### `media`

Media included by API expansions.

Columns:

- `media_key TEXT PRIMARY KEY`
- `type TEXT`
- `url TEXT`
- `preview_image_url TEXT`
- `raw_json TEXT NOT NULL`
- `first_seen_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`

### `media_assets`

Downloaded media files needed for offline rendering.

Columns:

- `id INTEGER PRIMARY KEY AUTOINCREMENT`
- `media_key TEXT`
- `asset_kind TEXT NOT NULL`
- `source_url TEXT NOT NULL`
- `local_path TEXT NOT NULL`
- `content_type TEXT`
- `byte_size INTEGER`
- `sha256 TEXT`
- `width INTEGER`
- `height INTEGER`
- `status TEXT NOT NULL`
- `error_json TEXT`
- `first_seen_at TEXT NOT NULL`
- `last_checked_at TEXT NOT NULL`

Notes:

- `asset_kind` examples: `image`, `preview_image`, `video_variant`, `animated_gif_variant`, `author_avatar`.
- Use content hashing to avoid duplicate downloads when possible.
- Store files under `~/.local/share/x-bookmarks/assets/`.
- Prefer stable deterministic paths, for example `assets/media/{media_key}/{sha256-or-filename}`.

### `tweet_media`

Links tweets to media records and downloaded assets.

Columns:

- `tweet_id TEXT NOT NULL`
- `media_key TEXT NOT NULL`
- `position INTEGER`
- `PRIMARY KEY (tweet_id, media_key)`

### `bookmark_items`

Represents the user's bookmark collection.

Columns:

- `account_user_id TEXT NOT NULL`
- `tweet_id TEXT NOT NULL`
- `active INTEGER NOT NULL DEFAULT 1`
- `first_seen_run_id INTEGER NOT NULL`
- `last_seen_run_id INTEGER NOT NULL`
- `first_seen_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`
- `PRIMARY KEY (account_user_id, tweet_id)`

Notes:

- `active` can eventually support detecting removals after full scans.
- Do not use tweet ID as an incremental cursor. A user can newly bookmark an old tweet.

### `bookmark_folders`

Named bookmark buckets/collections from the X UI, if available through the account's API tier.

Columns:

- `account_user_id TEXT NOT NULL`
- `folder_id TEXT NOT NULL`
- `name TEXT`
- `raw_json TEXT NOT NULL`
- `first_seen_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`
- `PRIMARY KEY (account_user_id, folder_id)`

### `bookmark_folder_items`

Folder membership for bookmarked tweets, if available.

Columns:

- `account_user_id TEXT NOT NULL`
- `folder_id TEXT NOT NULL`
- `tweet_id TEXT NOT NULL`
- `first_seen_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`
- `PRIMARY KEY (account_user_id, folder_id, tweet_id)`

### `raw_pages`

Optional but useful for reproducibility and debugging.

Columns:

- `id INTEGER PRIMARY KEY AUTOINCREMENT`
- `sync_run_id INTEGER NOT NULL`
- `page_number INTEGER NOT NULL`
- `pagination_token TEXT`
- `next_token TEXT`
- `result_count INTEGER`
- `response_json TEXT NOT NULL`
- `fetched_at TEXT NOT NULL`

## API Request Shape

Use a stable field list for deterministic ingestion.

Proposed query params:

```text
max_results=100
tweet.fields=id,text,author_id,created_at,conversation_id,display_text_range,entities,context_annotations,attachments,referenced_tweets,public_metrics,lang,possibly_sensitive,source,note_tweet,card_uri,article
expansions=author_id,attachments.media_keys,attachments.poll_ids,referenced_tweets.id,referenced_tweets.id.author_id,referenced_tweets.id.attachments.media_keys
user.fields=id,name,username,description,created_at,verified,verified_type,profile_image_url,profile_banner_url,public_metrics,url,location,protected
media.fields=media_key,type,url,preview_image_url,width,height,alt_text,duration_ms,public_metrics,variants
poll.fields=id,options,duration_minutes,end_datetime,voting_status
```

This may need adjustment if the current X API rejects any fields for the account's access tier.

Referenced post policy:

- Request direct referenced posts through `referenced_tweets.id` expansions on the bookmark request whenever possible.
- Treat only `referenced_tweets` entries with `type == "quoted"` as quote posts required for offline rendering.
- Fetch directly referenced quote posts because offline rendering of the bookmarked post may otherwise be confusing or incomplete.
- Do not recursively hydrate quote posts beyond depth `1`.
- Do not recursively follow replies, retweets/reposts, quoted posts inside quoted posts, or arbitrary conversation threads by default.
- Store unavailable/deleted/protected quote-post references as structured missing-reference records so renderers can show a faithful offline placeholder.

Media download policy:

- Download media assets by default when ingesting newly discovered bookmarks.
- Download image URLs and preview images where available.
- For videos and animated GIFs, choose one deterministic preferred variant by default, such as the highest bitrate MP4 variant under configured size limits.
- Record skipped media with a reason, rather than silently ignoring it.
- Add future config for maximum media bytes per asset and allowed media kinds if real usage shows the need.

## Sync Algorithm

Command:

```bash
x-bookmarks sync
```

Default conservative sync:

1. Load account and token state.
2. Refresh the access token if expired or close to expiry.
3. Discover new bookmark candidates by requesting bookmark pages with fixed query params.
4. Print a summary before downloading or writing new heavy assets when approval is required, for example: `Found 100 new bookmarks and 238 media assets. Download now? [y/N]`.
5. If the user declines, exit without ingesting new bookmark records or downloading assets.
6. If `--yolo` is passed, bypass approval and continue.
7. Create a `sync_runs` row with status `running`.
8. For each approved page/bookmark:
   - Store raw page JSON.
   - Upsert tweets from `data`.
   - Upsert expanded users/media from `includes`.
   - Upsert direct quote-post data from `includes.tweets` to depth `1` when needed for rendering.
   - Insert unseen `(account_user_id, tweet_id)` records in `bookmark_items`.
   - Update `last_seen_*` fields for existing bookmarks.
   - Download media assets required for offline rendering.
   - Follow `meta.next_token` until absent.
9. If bookmark folders are available, sync folder metadata and folder membership.
10. Mark run `succeeded`.

Failure behavior:

- On rate limit, honor `x-rate-limit-reset` and either wait or exit with a distinct rate-limit code depending on CLI flags.
- On auth failure, attempt token refresh once.
- On persistent failure, mark run `failed` with structured error JSON.
- Partial page writes should be committed page-by-page so reruns can proceed safely.

## Incremental Strategy

Phase 1:

- Always scan all pages.
- Only insert bookmarks and tweets that are not already present.
- Only download media assets that are not already present and valid by local path/hash.
- This is simplest and safest because it does not depend on undocumented ordering.

Phase 2 optimization:

- Add `--stop-after-existing-pages N`.
- If bookmark ordering is verified as newest-bookmark-first, stop after `N` consecutive pages with no new bookmark IDs.
- Keep full scan available via `--full`.

## CLI Plan

Initial commands:

```bash
x-bookmarks config init
x-bookmarks config status
x-bookmarks auth login
x-bookmarks auth status
x-bookmarks db init
x-bookmarks db status
x-bookmarks sync
x-bookmarks sync --yolo
x-bookmarks sync --full
x-bookmarks sync --limit-pages N
x-bookmarks export --format jsonl
```

Useful later commands:

```bash
x-bookmarks bookmarks list
x-bookmarks bookmarks stats
x-bookmarks assets verify
x-bookmarks auth refresh
```

Approval behavior:

- `x-bookmarks sync` prompts before ingesting newly discovered bookmarks and downloading media assets when `sync.require_approval` is true.
- `x-bookmarks sync --yes` can be a polite alias for approving the current run.
- `x-bookmarks sync --yolo` bypasses all confirmation prompts and is the intended flag for agentic/scheduled invocation.
- `--yolo` should still fail fast on missing config, missing auth, API errors, or database migration failures.

## Determinism Requirements

- The binary should run without external runtime dependencies.
- Normal operation should use file-based configuration, not a loose set of environment variables.
- Default local paths should be stable:
  - `~/.config/x-bookmarks/config.json`
  - `~/.local/share/x-bookmarks/oauth-token.json`
  - `~/.local/share/x-bookmarks/x_bookmarks.sqlite`
  - `~/.local/share/x-bookmarks/assets/`
- Fixed query params and field lists are recorded in every sync run.
- SQLite schema migrations are explicit and versioned.
- Writes are idempotent using stable primary keys.
- Sync output should not depend on wall-clock time except metadata fields like `fetched_at`.
- Exit codes should be documented and stable.
- Raw API responses can be preserved for auditability.
- Quote-post hydration depth is fixed at `1` by default to avoid unpredictable API and media download expansion.
- Interactive approval is the default before new bookmark/media downloads; `--yolo` is the deterministic non-interactive bypass.

## Testing Plan

Unit tests:

- Config file parsing and default path resolution.
- OAuth authorization URL construction.
- PKCE verifier/challenge generation.
- Token refresh behavior.
- API pagination.
- SQLite migrations.
- Tweet/user/media/bookmark upserts.
- Direct quote-post hydration with no recursive expansion.
- Media asset planning and idempotent downloads.
- Approval prompt behavior and `--yolo` bypass.
- Incremental detection of new versus existing bookmarks.

Fixture tests:

- Use saved bookmark API JSON fixtures.
- Test multi-page ingestion.
- Test empty page handling.
- Test partial errors with `errors` plus `data`.
- Test bookmarked post with quote post and media.
- Test skipped or failed media download recording.

Integration tests:

- Gated behind real credentials and disabled by default.
- Validate `/2/users/me`.
- Validate one-page bookmark fetch.
- Validate one quote-post fetch if present.
- Validate one media download if present.
- Validate DB write path against a temporary SQLite file.

## Milestones

### Milestone 1: Project Bootstrap

- Create Zig package.
- Add `build.zig`.
- Add CLI entrypoint.
- Add config loading from `~/.config/x-bookmarks/config.json`, with XDG env support.
- Add `config init` to create config from `config.example.json`.
- Add `data/` and `.gitignore`.

### Milestone 2: Database Foundation

- Implement schema migrations.
- Implement `db init` and `db status`.
- Add tests for migrations and idempotent init.

### Milestone 3: OAuth

- Implement PKCE login.
- Implement token persistence to `~/.local/share/x-bookmarks/oauth-token.json`.
- Implement token refresh.
- Implement `auth status`.

### Milestone 4: Bookmark Sync

- Implement X API client.
- Implement conservative full pagination sync.
- Upsert tweets, users, media, and bookmark items.
- Hydrate direct quote posts to depth `1`.
- Add approval prompt and `--yolo` bypass.
- Store raw pages.

### Milestone 5: Offline Assets

- Implement deterministic media asset planner.
- Download post images, media previews, selected video/GIF variants, and author avatars.
- Store asset metadata, local paths, hashes, and failures.
- Add `assets verify`.

### Milestone 6: Pipeline Exports

- Implement JSONL export.
- Define stable export shape for downstream interest graph generation.
- Include local asset paths and quote-post data required for offline rendering.

### Milestone 7: Hardening

- Add rate-limit handling.
- Add structured exit codes.
- Add integration test mode.
- Validate real API behavior around bookmark ordering and decide whether optimized incremental stopping is safe.

## Review Questions

1. Should the first version include X bookmark folder/bucket metadata, or should folder membership be deferred until basic bookmark and media ingestion works?
2. Is `~/.config/x-bookmarks/config.json` plus `~/.local/share/x-bookmarks/oauth-token.json` the right split, or should OAuth token state live in SQLite despite being secret-bearing?
3. Should we use these XDG-style paths on macOS too, or switch macOS defaults to `~/Library/Application Support/x-bookmarks/` later?
4. Should the conservative default always scan all bookmark pages, or should we prioritize newest-first early stopping once verified?
5. Should media downloads include video/GIF assets immediately, or should the first version handle still images and previews first?

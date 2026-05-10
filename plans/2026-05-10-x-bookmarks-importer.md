# X Bookmarks Importer Plan

Date: 2026-05-10

## Goal

Build a deterministic agent-runnable tool that incrementally reads the authenticated user's X/Twitter bookmarks, stores retrieved posts in a local SQLite database under `data/`, and exposes the stored data for downstream interest graph and wiki-style knowledge map pipelines.

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
- `/2/users/me` can be used after OAuth login to discover the authenticated user ID.

Primary docs:

- https://docs.x.com/x-api/users/get-bookmarks
- https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code
- https://docs.x.com/fundamentals/authentication/guides/v2-authentication-mapping
- https://docs.x.com/x-api/posts/bookmarks/introduction
- https://docs.x.com/x-api/fundamentals/rate-limits

## Important Open Research Questions

- Confirm whether bookmark lookup returns bookmarks in reverse bookmark-created order. If undocumented, the initial importer should scan every page to avoid missing old tweets that were bookmarked recently.
- Confirm API plan/access requirements for the target developer account, because X API access and endpoint availability can vary by product tier.
- Confirm whether bookmark folders matter for the initial data model or should be deferred.

## Proposed Runtime

Use Python for the first implementation unless there is a repo-level preference added later.

Reasons:

- SQLite support is built in.
- OAuth and HTTP client libraries are mature.
- Easy to run deterministically from agents and data pipelines.
- Straightforward JSONL export for downstream graph/wiki processing.

Proposed package layout:

```text
.
├── data/
│   └── x_bookmarks.sqlite
├── plans/
│   └── 2026-05-10-x-bookmarks-importer.md
├── src/
│   └── x_bookmarks/
│       ├── __init__.py
│       ├── auth.py
│       ├── cli.py
│       ├── config.py
│       ├── db.py
│       ├── models.py
│       ├── sync.py
│       └── x_api.py
├── tests/
├── .env.example
├── .gitignore
├── README.md
└── pyproject.toml
```

## OAuth Setup Plan

Add an interactive one-time auth flow:

```bash
x-bookmarks auth login
```

Required user-provided values:

- `X_CLIENT_ID`
- `X_CLIENT_SECRET`, only if using a confidential client
- `X_REDIRECT_URI`, exactly matching the URI registered in the X Developer Console

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
7. Persist token metadata and account metadata locally.

Token storage:

- Prefer storing refresh/access token metadata in `data/x_bookmarks.sqlite` with local filesystem permissions restricting access to the current user.
- Keep client secrets in `.env` or environment variables, never in git.
- Add `.env`, token dumps, and local DB files to `.gitignore`.

## SQLite Schema Plan

Database path:

```text
data/x_bookmarks.sqlite
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

### `oauth_tokens`

Local OAuth token state.

Columns:

- `account_user_id TEXT PRIMARY KEY`
- `access_token TEXT NOT NULL`
- `refresh_token TEXT`
- `token_type TEXT`
- `scope TEXT`
- `expires_at TEXT`
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
tweet.fields=id,text,author_id,created_at,conversation_id,entities,context_annotations,attachments,referenced_tweets,public_metrics,lang,possibly_sensitive,source,note_tweet
expansions=author_id,attachments.media_keys,referenced_tweets.id,referenced_tweets.id.author_id
user.fields=id,name,username,description,created_at,verified,verified_type,profile_image_url,public_metrics,url,location
media.fields=media_key,type,url,preview_image_url,width,height,alt_text,duration_ms,public_metrics,variants
```

This may need adjustment if the current X API rejects any fields for the account's access tier.

## Sync Algorithm

Command:

```bash
x-bookmarks sync
```

Default conservative sync:

1. Load account and token state.
2. Refresh the access token if expired or close to expiry.
3. Create a `sync_runs` row with status `running`.
4. Request `GET /2/users/{id}/bookmarks` with fixed query params.
5. For each page:
   - Store raw page JSON.
   - Upsert tweets from `data`.
   - Upsert expanded users/media from `includes`.
   - Insert unseen `(account_user_id, tweet_id)` records in `bookmark_items`.
   - Update `last_seen_*` fields for existing bookmarks.
   - Follow `meta.next_token` until absent.
6. Mark run `succeeded`.

Failure behavior:

- On rate limit, honor `x-rate-limit-reset` and either wait or exit with a distinct rate-limit code depending on CLI flags.
- On auth failure, attempt token refresh once.
- On persistent failure, mark run `failed` with structured error JSON.
- Partial page writes should be committed page-by-page so reruns can proceed safely.

## Incremental Strategy

Phase 1:

- Always scan all pages.
- Only insert bookmarks and tweets that are not already present.
- This is simplest and safest because it does not depend on undocumented ordering.

Phase 2 optimization:

- Add `--stop-after-existing-pages N`.
- If bookmark ordering is verified as newest-bookmark-first, stop after `N` consecutive pages with no new bookmark IDs.
- Keep full scan available via `--full`.

## CLI Plan

Initial commands:

```bash
x-bookmarks auth login
x-bookmarks auth status
x-bookmarks db init
x-bookmarks db status
x-bookmarks sync
x-bookmarks sync --full
x-bookmarks sync --limit-pages N
x-bookmarks export --format jsonl
```

Useful later commands:

```bash
x-bookmarks bookmarks list
x-bookmarks bookmarks stats
x-bookmarks auth refresh
```

## Determinism Requirements

- Fixed query params and field lists are recorded in every sync run.
- SQLite schema migrations are explicit and versioned.
- Writes are idempotent using stable primary keys.
- Sync output should not depend on wall-clock time except metadata fields like `fetched_at`.
- Exit codes should be documented and stable.
- Raw API responses can be preserved for auditability.

## Testing Plan

Unit tests:

- OAuth authorization URL construction.
- PKCE verifier/challenge generation.
- Token refresh behavior.
- API pagination.
- SQLite migrations.
- Tweet/user/media/bookmark upserts.
- Incremental detection of new versus existing bookmarks.

Fixture tests:

- Use saved bookmark API JSON fixtures.
- Test multi-page ingestion.
- Test empty page handling.
- Test partial errors with `errors` plus `data`.

Integration tests:

- Gated behind real credentials and disabled by default.
- Validate `/2/users/me`.
- Validate one-page bookmark fetch.
- Validate DB write path against a temporary SQLite file.

## Milestones

### Milestone 1: Project Bootstrap

- Create Python package.
- Add CLI entrypoint.
- Add config loading from env.
- Add `data/` and `.gitignore`.

### Milestone 2: Database Foundation

- Implement schema migrations.
- Implement `db init` and `db status`.
- Add tests for migrations and idempotent init.

### Milestone 3: OAuth

- Implement PKCE login.
- Implement token persistence.
- Implement token refresh.
- Implement `auth status`.

### Milestone 4: Bookmark Sync

- Implement X API client.
- Implement conservative full pagination sync.
- Upsert tweets, users, media, and bookmark items.
- Store raw pages.

### Milestone 5: Pipeline Exports

- Implement JSONL export.
- Define stable export shape for downstream interest graph generation.

### Milestone 6: Hardening

- Add rate-limit handling.
- Add structured exit codes.
- Add integration test mode.
- Validate real API behavior around bookmark ordering and decide whether optimized incremental stopping is safe.

## Review Questions

1. Should the first version include bookmark folders, or should folders be deferred until basic bookmark ingestion works?
2. Do you prefer tokens in SQLite, a separate ignored token file, or macOS Keychain integration?
3. Is Python acceptable for the tool, or do you want this in another runtime?
4. Should the conservative default always scan all bookmark pages, or should we prioritize newest-first early stopping once verified?

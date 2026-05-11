# Manual Verification and OAuth Handoff

Date: 2026-05-10

This runbook explains how to complete the X/Twitter OAuth handshake for the repo-local `x-bookmarks` development state and how to verify the importer manually after credentials are available.

The current local development home is:

```bash
--home data
```

That means the CLI reads:

```text
data/config.json
data/oauth-token.json
data/x_bookmarks.sqlite
data/assets/
data/viewer-export/
```

Do not paste access tokens or refresh tokens into chat. The useful handoff is to complete the OAuth flow so `data/oauth-token.json` contains the token state on this machine, then tell Codex to rerun live verification.

## Current Blocker

Live X API validation is currently blocked because the repo-local token file is still a pending OAuth login file:

```text
token path: /Users/jflam/src/x-bookmarks/data/oauth-token.json
token: pending OAuth login
access token: missing
refresh token: missing
account: unknown
expires_at: unknown
redirect uri: http://127.0.0.1:8765/callback
```

The live integration command fails before it can call X:

```bash
./zig-out/bin/x-bookmarks --home data integration test --live --limit-pages 1
```

Expected blocked output:

```text
token file does not contain access_token: /Users/jflam/src/x-bookmarks/data/oauth-token.json
error: error.AuthRequired
```

Expected blocked exit code:

```text
4
```

## X Developer App Prerequisites

You need an X Developer account with a Project and App that can call bookmark endpoints.

In the X Developer Console:

1. Open your Project/App.
2. Enable OAuth 2.0 user-context authentication.
3. Set the app type according to your X app setup:
   - Public/native client: no client secret is needed.
   - Confidential/web client: the CLI can use `x.client_secret` from `data/config.json`.
4. Add this exact callback/redirect URI:

```text
http://127.0.0.1:8765/callback
```

5. Grant or request these OAuth scopes:

```text
tweet.read
users.read
bookmark.read
offline.access
```

`offline.access` is required so X issues a refresh token. Without it, the importer may receive only a short-lived access token and non-interactive future sync will not work.

6. Make sure the X account you authorize is the same account whose bookmarks you want to import.
7. Make sure the app/account has API access and spend/credit settings that allow bookmark reads.

## Configure the Repo-Local CLI

From the repo root:

```bash
cd /Users/jflam/src/x-bookmarks
```

If `data/config.json` already exists and has your real client ID, do not overwrite it. Check it first:

```bash
./zig-out/bin/x-bookmarks --home data config status
```

If you need to initialize or replace the repo-local config:

```bash
./zig-out/bin/x-bookmarks --home data config init --force \
  --client-id YOUR_X_CLIENT_ID \
  --redirect-uri http://127.0.0.1:8765/callback
```

If your X app is confidential and requires a client secret, edit `data/config.json` and set:

```json
"client_secret": "YOUR_X_CLIENT_SECRET"
```

Keep `data/config.json` local. It is ignored by git.

Verify config after editing:

```bash
./zig-out/bin/x-bookmarks --home data config status
```

Expected important lines:

```text
client id: configured
redirect uri: http://127.0.0.1:8765/callback
scopes: tweet.read users.read bookmark.read offline.access
```

## Start the OAuth Login

Run:

```bash
./zig-out/bin/x-bookmarks --home data auth login
```

Expected behavior:

1. The command writes pending PKCE state to `data/oauth-token.json`.
2. It starts a temporary local web server for the configured redirect URI.
3. It opens the X authorization URL in the default browser when possible.
4. It captures the redirect callback, validates state, exchanges the code, writes the token file, and records the authenticated account.

Expected output shape:

```text
listening for OAuth callback at http://127.0.0.1:8765/callback
opened authorization URL in the default browser
authenticated account: @USERNAME (USER_ID)
```

If browser auto-open is not available, run `auth login --no-open` and open the printed URL manually. The local callback is still captured automatically.

## Complete the Browser Authorization

In the browser:

1. Sign in to the X account whose bookmarks should be imported.
2. Review the requested scopes.
3. Approve/authorize the app.
4. X redirects to:

```text
http://127.0.0.1:8765/callback?state=...&code=...
```

The local callback page should say the callback was received. Return to the terminal for the final success output:

```text
authenticated account: @USERNAME (USER_ID)
```

If the command says the code is expired or auth is required, restart from:

```bash
./zig-out/bin/x-bookmarks --home data auth login
```

Then authorize again and exchange the new callback URL quickly.

## Verify Token State

Run:

```bash
./zig-out/bin/x-bookmarks --home data auth status
```

Expected success output shape:

```text
token path: /Users/jflam/src/x-bookmarks/data/oauth-token.json
token: present
access token: present
refresh token: present
account: USER_ID
expires_at: 17...
```

The refresh token should be present. If `refresh token: missing`, check that the X app requested and was granted `offline.access`, then repeat the OAuth flow.

Do not paste the token file contents into chat. Just tell Codex that `auth status` reports access and refresh tokens present.

## Live Integration Verification

After `auth status` reports access and refresh tokens present, ask Codex to continue, or run this yourself:

```bash
./zig-out/bin/x-bookmarks --home data integration test --live --limit-pages 1
```

Expected success output shape:

```text
integration test passed: account=@USERNAME pages=1 tweets=N db=.zig-cache/integration/.../x_bookmarks.sqlite viewer=.zig-cache/integration/.../viewer-export
```

This command validates:

- `/2/users/me`
- one limited bookmark sync page
- folder sync if available to the account/app
- temporary SQLite write path
- viewer export generation
- required viewer export files
- local asset verification

If the account has no bookmarks, `tweets=0` can still be acceptable as long as the command exits successfully and generates the temporary DB/viewer export.

## Optional Manual Sync Smoke

After live integration passes, you can do a small repo-local sync without media downloads:

```bash
./zig-out/bin/x-bookmarks --home data sync --yolo --limit-pages 1 --max-results 5 --no-media
```

Then inspect:

```bash
./zig-out/bin/x-bookmarks --home data db status
./zig-out/bin/x-bookmarks --home data bookmarks stats
./zig-out/bin/x-bookmarks --home data viewer export
./zig-out/bin/x-bookmarks --home data viewer serve
```

Open:

```text
http://127.0.0.1:8766
```

Stop the server with `Ctrl-C`.

## Run the Viewer

The viewer is a static local web UI generated from the SQLite database and local asset files. It does not call the X API while rendering.

From the repo root:

```bash
cd /Users/jflam/src/x-bookmarks
```

Build the React/Vite viewer assets:

```bash
cd viewer
bun run build
cd ..
```

Export the latest local database state into `data/viewer-export/`:

```bash
./zig-out/bin/x-bookmarks --home data viewer export
```

Expected output shape:

```text
assets checked: N
asset failures: 0
exported viewer: /Users/jflam/src/x-bookmarks/data/viewer-export
```

Serve the exported viewer:

```bash
./zig-out/bin/x-bookmarks --home data viewer serve
```

Expected output:

```text
serving /Users/jflam/src/x-bookmarks/data/viewer-export at http://127.0.0.1:8766/
```

Open this URL in a browser:

```text
http://127.0.0.1:8766/
```

Manual checks in the browser:

- The page loads without a blank screen.
- Summary counts appear at the top.
- The bookmark list renders local text and author information.
- The completeness, failed-assets, and folder filters are available.
- X URI and Twitter URI links are visible on bookmark cards.
- Media renders from local exported assets when downloaded assets exist.
- Quote posts or missing quote placeholders appear when present.
- Raw JSON can be expanded for debugging.

Stop the viewer server with `Ctrl-C` in the terminal where `viewer serve` is running.

If `viewer serve` fails with a missing export error, regenerate the export:

```bash
./zig-out/bin/x-bookmarks --home data viewer export
./zig-out/bin/x-bookmarks --home data viewer serve
```

If the browser shows old data, stop the server, rerun `viewer export`, restart `viewer serve`, and refresh the page.

## Full Manual Verification Checklist

Run these from the repo root:

```bash
zig fmt --check build.zig src/main.zig
zig build test
zig build
zig build -Doptimize=ReleaseSafe
cd viewer && bun run build && cd ..
./zig-out/bin/x-bookmarks --home data config status
./zig-out/bin/x-bookmarks --home data auth status
./zig-out/bin/x-bookmarks --home data integration test --live --limit-pages 1
./zig-out/bin/x-bookmarks --home data viewer export
./zig-out/bin/x-bookmarks --home data assets verify
```

Expected result:

- Formatting passes.
- Zig unit tests pass.
- Debug and ReleaseSafe builds pass.
- Viewer build passes.
- Config status shows a configured client ID and required scopes.
- Auth status shows access and refresh tokens present.
- Live integration exits 0.
- Viewer export exits 0.
- Asset verification exits 0.

## Common Failures

### `error.AuthRequired` during live integration

Run:

```bash
./zig-out/bin/x-bookmarks --home data auth status
```

If access token is missing, complete the OAuth callback exchange.

If refresh token is missing, repeat OAuth after confirming `offline.access` is configured.

### Browser shows "site cannot be reached"

This usually means `auth login` was not still running, the redirect URI in X does not exactly match config, or the local port was blocked. Restart the login flow and make sure the terminal says it is listening before approving in the browser.

As a fallback, use the manual flow:

```bash
./zig-out/bin/x-bookmarks --home data auth login --manual
./zig-out/bin/x-bookmarks --home data auth login --callback-url 'FULL_URL'
```

### Callback state mismatch

Restart the login flow. The callback URL must come from the most recent `auth login` command because the pending token file stores the expected `state`.

### Authorization code expired

Run `auth login` again, authorize again, and exchange the new callback URL immediately.

### X returns an access or tier error

Confirm the app has OAuth 2.0 user-context enabled, the bookmark scopes are granted, the redirect URI exactly matches, and the developer account has access/credits for bookmark reads.

## Handoff Back to Codex

After successful OAuth exchange, send a short message like:

```text
OAuth is complete. auth status shows access and refresh tokens present. Continue live verification.
```

Codex can then run:

```bash
./zig-out/bin/x-bookmarks --home data integration test --live --limit-pages 1
```

If that passes, Codex can perform the final completion audit and mark the goal complete.

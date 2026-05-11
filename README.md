# x-bookmarks

`x-bookmarks` is a planned local CLI for importing an authenticated user's X/Twitter bookmarks into SQLite for offline use.

The goal is deterministic, agent-runnable ingestion:

- read all bookmarks exposed by the X API
- incrementally fetch only new bookmark records and missing assets
- download post media for later offline rendering
- store post, author, media, quote-post, and folder metadata locally
- expose the data for downstream interest-graph and wiki-style pipelines

The implementation is planned in Zig as a single native executable with zero runtime dependencies. SQLite will be embedded by compiling the SQLite amalgamation into the binary, while data files live in the user's profile directories:

- config: `~/.config/x-bookmarks/config.json`
- database: `~/.local/share/x-bookmarks/x_bookmarks.sqlite`
- OAuth token: `~/.local/share/x-bookmarks/oauth-token.json`
- media assets: `~/.local/share/x-bookmarks/assets/`

See [plans/2026-05-10-x-bookmarks-importer.md](plans/2026-05-10-x-bookmarks-importer.md) for the current implementation plan and X API research notes.

# X Thread Expansion For Bookmark Ingestion

Date: 2026-05-14
Status: proposed
Owner: `x-bookmarks` Zig CLI

## Problem

Some bookmarked X posts are thread starters. The bookmark itself may contain
only the hook or first post, while the actual value lives in the following
same-author posts.

Example:

```text
X Bookmarks/raw/x/ingested/2043828130960625958.md
```

This source is a thread starter:

```text
tweet_id: 2043828130960625958
author_username: kl_klpoa
author_id: 1983900555929120768
conversation_id: 2043828130960625958
text includes: 🧵🧵🧵 1/N
```

The local database currently has only one tweet for that conversation:

```sql
select count(*)
from tweets
where conversation_id = '2043828130960625958';
-- 1
```

So the wiki agent can only analyze `1/N`. It cannot recover the remaining
posts from local context.

## Goal

Add a durable thread-expansion path to the Zig CLI so bookmark ingestion can
optionally fetch, store, export, and analyze same-author thread context.

The system should:

- detect likely thread starters;
- fetch same-author posts from the same conversation;
- avoid importing comments from other users;
- cache fetched thread context permanently;
- expose thread context in raw Markdown exports;
- make API cost explicit;
- keep Nanoboss focused on orchestration and synthesis, not X API fetching.

## Non-Goals

Do not build this in Nanoboss. Nanoboss should consume expanded raw Markdown, not
own X API calls or storage.

Do not import entire public conversations by default.

Do not treat every reply as part of the thread. Same-author side replies should
be filtered conservatively.

Do not make full-archive search mandatory for normal daily ingestion. It may be
unavailable or more expensive depending on X API access.

## Ownership Boundary

This belongs in `src/main.zig`.

The Zig CLI already owns:

- OAuth and token refresh;
- X API request construction;
- rate-limit handling;
- SQLite persistence;
- media download and reuse;
- raw Markdown export;
- Obsidian export data;
- sync timing and status reporting.

Nanoboss should only see the result through exported raw Markdown sections such
as `## Thread Context`.

## API Strategy

### Preferred Query

Fetch by conversation and author:

```text
conversation_id:<root_tweet_id> from:<author_username>
```

For the example:

```text
conversation_id:2043828130960625958 from:kl_klpoa
```

Request fields should match the bookmark sync shape as closely as possible:

```text
tweet.fields=id,text,author_id,created_at,conversation_id,display_text_range,entities,context_annotations,attachments,referenced_tweets,public_metrics,lang,possibly_sensitive,source,note_tweet,card_uri,article
expansions=author_id,attachments.media_keys,attachments.poll_ids,referenced_tweets.id,referenced_tweets.id.author_id,referenced_tweets.id.attachments.media_keys
user.fields=id,name,username,description,created_at,verified,verified_type,profile_image_url,profile_banner_url,public_metrics,url,location,protected
media.fields=media_key,type,url,preview_image_url,width,height,alt_text,duration_ms,public_metrics,variants
poll.fields=id,options,duration_minutes,end_datetime,voting_status
```

### Endpoint Order

1. Use `search/recent` for recent threads when the root is inside the recent
   search window.
2. Use `search/all` for older threads when full-archive access is configured and
   explicitly enabled.
3. Optionally add a user-timeline fallback later if full-archive search is not
   available.

### Why Not Conversation Only

This is too broad:

```text
conversation_id:<root_tweet_id>
```

It can return comments and replies from everyone.

The first filter must be author constrained:

```text
conversation_id:<root_tweet_id> from:<author_username>
```

Then the CLI should still post-filter locally.

## Local Filtering

After API results are fetched, keep only candidates that satisfy:

1. `conversation_id == root_tweet_id`.
2. `author_id == root_author_id`.
3. `created_at >= root.created_at`.
4. The root post is included.

Then build the probable thread:

1. Sort by `created_at`, then tweet ID.
2. Keep the root.
3. Keep same-author posts whose `referenced_tweets` includes:
   - `type: "replied_to"` and `id` is already in the kept chain; or
   - missing/ambiguous reply metadata but the post contains thread-numbering
     signals and is near the prior kept post.
4. Use numbering signals only as confidence hints, not as the only proof:
   - `1/N`, `2/N`, `3/N`;
   - `1/`, `2/`, `3/`;
   - `1.`, `2.`, `3.`;
   - thread markers such as `🧵`.
5. Drop same-author posts that are clearly replies to other users unless they
   link back into the kept chain.

The output should record a confidence value:

```text
high      reply-chain metadata forms a connected chain
medium    mostly connected but some posts inferred by sequence/numbering
low       weak signals; export as partial and mark for review
```

## Detection

During sync or raw export, mark likely thread candidates if any of these are
true:

- text or `note_tweet.text` contains `1/N`;
- text or `note_tweet.text` contains a standalone `1/`;
- text contains `🧵`;
- text contains phrases like:
  - `thread below`;
  - `in the thread below`;
  - `some thoughts`;
  - `here are my thoughts`;
  - `a thread`;
  - `1 of`;
- `conversation_id == tweet_id` and public metrics show nonzero replies, with a
  thread marker in the text.

Add frontmatter to raw exports:

```yaml
thread_candidate: true
thread_expansion_status: missing
```

If expansion is complete:

```yaml
thread_candidate: true
thread_expansion_status: complete
thread_post_count: 12
thread_expansion_method: search_all
thread_expansion_confidence: high
```

## CLI Surface

Add explicit commands:

```text
x-bookmarks threads detect [--changed]
x-bookmarks threads expand --tweet-id TWEET_ID [--dry-run] [--search-recent|--search-all|--auto] [--max-results N]
x-bookmarks threads expand --changed [--dry-run] [--limit N] [--search-recent|--search-all|--auto]
x-bookmarks threads status
```

Add optional sync integration:

```text
x-bookmarks sync --expand-threads
x-bookmarks sync --expand-threads --thread-search-all
```

Default behavior should be conservative:

- daily sync does not expand threads unless requested;
- detected candidates are marked but not fetched;
- expansion reports estimated cost before fetching unless `--yes` or `--yolo`
  is passed.

## Storage Schema

Reuse the existing `tweets` table for every fetched thread post. This keeps
media, users, references, and exports aligned with existing sync behavior.

Add a root-level table:

```sql
create table thread_expansions (
  root_tweet_id text primary key,
  root_author_id text not null,
  root_author_username text,
  conversation_id text not null,
  status text not null,
  method text,
  confidence text,
  post_count integer not null default 0,
  fetched_at text,
  api_endpoint text,
  query text,
  max_results integer,
  result_count integer,
  estimated_cost_micros integer,
  error_json text,
  first_seen_at text not null,
  last_seen_at text not null
);
```

Add a membership table:

```sql
create table thread_posts (
  root_tweet_id text not null,
  tweet_id text not null,
  position integer not null,
  include_reason text not null,
  confidence text not null,
  primary key (root_tweet_id, tweet_id)
);
```

Optional diagnostic table:

```sql
create table thread_candidates (
  tweet_id text primary key,
  detected_at text not null,
  reason_json text not null,
  status text not null
);
```

Statuses:

```text
missing       candidate detected but not fetched
complete      fetched and high/medium confidence chain built
partial       fetched but likely incomplete
unavailable   endpoint/access cannot fetch this thread
failed        transient or permanent fetch error
ignored       user or policy chose not to expand
```

## Raw Markdown Export

Update `kb export-raw-x` so expanded threads render directly in raw source
Markdown.

For missing candidates:

```markdown
## Thread Context

- Thread candidate: yes
- Expansion status: missing
- Detection reason: text contains `1/N`
- Suggested command: `x-bookmarks --home ... threads expand --tweet-id 2043828130960625958`
```

For complete expansions:

```markdown
## Thread Context

- Thread candidate: yes
- Expansion status: complete
- Method: search_all
- Confidence: high
- Posts: 12
- Estimated X API cost: $0.012

### Thread Post 1

![](https://x.com/kl_klpoa/status/2043828130960625958)

Why do all new apartment buildings look the same...

### Thread Post 2

![](https://x.com/kl_klpoa/status/<id>)

...
```

Each post should include:

- X embed URL;
- author handle;
- created_at;
- full `note_tweet.text` when present;
- media references if present;
- raw tweet ID.

The original bookmarked tweet remains the primary captured source. Thread posts
are context for that source, not separate bookmarks unless the user explicitly
bookmarked them.

## Obsidian Export

The human-facing bookmark note should also show thread context when present, but
more compactly than raw export.

Suggested format:

```markdown
## Thread

Expansion: complete, 12 posts, high confidence.

1. Why do all new apartment buildings look the same...
2. The reason is mostly building code and financing...
3. ...
```

For long threads, collapse after a configurable number of posts or include a
link to the raw source file.

## Nanoboss Integration

Nanoboss should not call the X API directly.

`wiki-refresh` should benefit automatically because `selected-raw-sources.md`
will include the exported `## Thread Context` section.

Add prompt guidance:

- when `Thread Context` exists, analyze the whole thread, not only the root
  post;
- cite the captured bookmark source block, and mention that the thread context
  is part of the raw source;
- if `thread_expansion_status: missing`, add a follow-up source task instead of
  pretending the thread was inspected.

Potential follow-up task format:

```text
Expand thread for 2043828130960625958 before final synthesis; root post is 1/N.
```

## Cost And Rate-Limit Controls

Thread expansion has real API cost. The CLI should report:

- number of candidates;
- number already cached;
- number that require API fetch;
- endpoint to be used;
- estimated posts requested;
- estimated cost;
- expected rate-limit impact.

Dry-run example:

```text
thread expansion dry run:
  candidates: 8
  cached: 2
  fetch_required: 6
  endpoint: search/all
  max_results_per_thread: 100
  estimated_posts_requested: 600
  estimated_cost: $0.60
```

Use configured cost constants. If X pricing changes, keep it centralized.

## Incremental Behavior

Thread expansion should be cache-first:

1. If `thread_expansions.status = complete`, do nothing by default.
2. If `partial`, retry only when explicitly requested or when `--retry-partial`
   is passed.
3. If `failed`, retry only transient failures by default.
4. If root raw JSON changed, mark stale and allow refresh.
5. If full-archive access is unavailable, mark older threads as `unavailable`
   with a clear reason.

This keeps daily ingest fast and predictable.

## Implementation Steps

1. Add database migrations for `thread_expansions`, `thread_posts`, and optional
   `thread_candidates`.
2. Add thread-candidate detection over existing tweets and newly synced tweets.
3. Add command parser branches for `threads detect`, `threads expand`, and
   `threads status`.
4. Add X search request builder for `conversation_id:<id> from:<username>`.
5. Add endpoint selection:
   - recent;
   - full archive;
   - auto.
6. Store returned tweets through the existing tweet/user/media persistence path.
7. Build and persist filtered thread membership.
8. Download/reuse media for kept thread posts according to the existing media
   policy.
9. Update `kb export-raw-x` with `## Thread Context`.
10. Update Obsidian export with compact thread display.
11. Update Nanoboss prompt/context behavior to pay attention to thread context.
12. Add tests.

## Tests

Unit tests:

- detects `1/N`;
- detects `🧵`;
- does not detect ordinary single posts;
- filters same conversation but different author comments;
- keeps a connected same-author reply chain;
- marks ambiguous same-author posts as partial/medium confidence;
- emits missing thread context in raw Markdown;
- emits complete thread context in raw Markdown.

Integration-style tests with mocked API:

- `threads expand --tweet-id` writes tweets and thread membership;
- `threads expand --changed` processes only candidates;
- cached complete thread is not refetched;
- full-archive unavailable produces `unavailable`;
- dry-run reports estimated cost and writes nothing.

Regression test using fixture modeled on:

```text
2043828130960625958
```

Expected:

- root detected as thread candidate;
- expansion query is `conversation_id:2043828130960625958 from:kl_klpoa`;
- same-author posts are included;
- other-author comments are excluded;
- raw export contains `## Thread Context`.

## Open Questions

Do we have X API access for `search/all`, or only recent search?

Should thread expansion be opt-in per source, opt-in per sync, or enabled for
high-confidence candidates by default with a low cost ceiling?

How should the CLI represent deleted, protected, or unavailable posts inside an
otherwise complete thread?

Should thread context posts be eligible for media download by default, or should
media be skipped until a thread is promoted into wiki analysis?

Should a very long thread be truncated in raw Markdown with a pointer to a JSON
artifact, or should raw Markdown always contain the full thread?

## Acceptance Criteria

- The example root `2043828130960625958` is detected as a thread candidate.
- A dry run shows the query, endpoint, expected max results, and estimated cost.
- An expansion run stores same-author conversation posts and excludes comments.
- `kb export-raw-x --changed` adds `## Thread Context`.
- Nanoboss ingest sees the thread context in `selected-raw-sources.md`.
- Existing non-thread bookmark sync behavior is unchanged.
- Cached complete threads are not refetched by default.
- Tests cover detection, filtering, raw export, and cache behavior.


# Interest Map Ingestion Flow

This document explains how `wiki/meta/interest-map.md` is intended to guide
interest-aware X bookmark ingestion, how it relates to SQLite state, and what
should be improved before expanding into phase-two workflows.

## Short Version

Yes: during additional bookmark ingestion, the current interest map is read into
the agent's prompt context and used as the routing layer for sensemaking.

For each source, the agent receives:

- the raw X bookmark Markdown;
- the current `wiki/meta/interest-map.md`;
- candidate related wiki pages or prior context where available.

The agent then answers:

```text
Why did John save this, and what does it connect to?
```

The output is a typed ingest decision. Deterministic procedure code renders that
decision into the source page, stores it in SQLite, and refreshes the interest
map from stored decisions.

## Key Artifacts

### Raw Source Page

Raw bookmark files live under:

```text
raw/x/inbox/
raw/x/ingested/
raw/x/ignored/
```

Each source page contains the captured post/thread text, links, media metadata,
raw JSON, and after sensemaking, a rendered section:

```markdown
## Ingest Decision

- Why likely saved: ...
- Matched interests: ...
- Non-obvious connections: ...
- Actions taken: ...
- Confidence: ...
```

This section is the human-auditable answer for a single bookmark.

### Interest Map Markdown

The human-facing map lives at:

```text
wiki/meta/interest-map.md
```

It is intended to be:

- readable in Obsidian or any Markdown viewer;
- editable by John when names, clusters, or framing are wrong;
- compact enough to include in future ingest prompts;
- source-linked so examples can be inspected quickly.

The map is not meant to be a final ontology. It is a working routing surface.

### SQLite Decision Records

The durable machine-readable decision log is:

```sql
kb_ingest_decisions
```

Each row stores one source's decision:

```text
source_id
raw_path
status
why_saved
matched_interests_json
non_obvious_connections_json
candidate_pages_json
actions_json
confidence
defer_reason
created_at
updated_at
```

These rows are the canonical machine-readable basis for deterministic interest
map refreshes.

### SQLite Interest Map Revisions

The revision metadata table is:

```sql
kb_interest_map_revisions
```

It stores:

```text
revision_label
markdown_path
summary_json
source_count
created_at
```

It does not currently store the full Markdown map. The Markdown file remains the
human-editable artifact. SQLite stores compact metadata and a JSON summary for
inspection and future retrieval.

## Current Flow

```mermaid
sequenceDiagram
    participant Raw as Raw X Source Page
    participant Proc as Nanoboss Procedure
    participant Map as wiki/meta/interest-map.md
    participant DB as SQLite
    participant Agent as Sensemaking Agent
    participant Source as Source Page
    participant NewMap as Refreshed Interest Map

    Proc->>Raw: Read source Markdown
    Proc->>Map: Read current interest map
    Proc->>DB: Optionally inspect prior decisions / metadata
    Proc->>Agent: Send source + interest map + candidates

    Agent->>Agent: Understand source from source text
    Agent->>Agent: Compare source to existing interests
    Agent->>Agent: Infer why John likely saved it
    Agent->>Agent: Identify connections, actions, confidence, deferrals

    Agent-->>Proc: Return typed ingest decision

    Proc->>Source: Render ## Ingest Decision
    Proc->>DB: Upsert kb_ingest_decisions
    Proc->>DB: Read all stored decisions in stable order
    Proc->>NewMap: Regenerate wiki/meta/interest-map.md
    Proc->>DB: Insert kb_interest_map_revisions row
```

## What The Agent Uses The Map For

The interest map should help the agent decide whether a new bookmark is:

- a clear match for an existing interest;
- evidence for an adjacent or emerging interest;
- a low-signal source that should be ignored;
- a media-primary source that should be deferred;
- a source that raises a recurring open question;
- a source that warrants a new semantic page or later synthesis.

The map is especially useful for phase two because it gives the agent continuity
across batches. Without it, each bookmark is judged mostly in isolation. With it,
the agent can ask:

```text
Does this support, refine, contradict, or extend something already visible in
John's saved-bookmark patterns?
```

## Deterministic Refresh

The current refresh path is deterministic in the narrow sense that it reads
`kb_ingest_decisions` in stable `source_id` order, groups matched interests,
dedupes recurring questions, renders Markdown source links, and inserts a
revision metadata row.

The map currently uses generated Markdown links like:

```markdown
[2011562190286045552](../../raw/x/ingested/2011562190286045552.md)
```

Because `interest-map.md` lives in `wiki/meta/`, the `../../raw/...` path points
back to the raw source tree.

## What SQLite Does And Does Not Store

SQLite stores the ingest decisions and interest-map revision metadata.

SQLite does not currently store a normalized interest-map ontology such as:

```text
interest_id
interest_name
description
parent_interest_id
status
source_count
example_sources
manual_aliases
```

That means the current map can be regenerated from decisions, but it is not yet a
fully queryable or manually reconciled interest graph.

The practical current model is:

```text
kb_ingest_decisions -> deterministic map renderer -> interest-map.md
```

Manual edits to `interest-map.md` are not yet parsed back into SQLite.

## How This Supports Phase Two

Phase two plans to process the remaining older foundation corpus, preserve the
most recent 100 bookmarks as a holdout, and later support daily ingestion.

The interest map helps phase two by providing:

- a compact summary of known interest clusters;
- examples linked to raw sources for human and agent inspection;
- a place to see emerging themes before creating permanent semantic pages;
- a routing guide for deciding whether a source matches, extends, or diverges
  from known interests;
- continuity across batches.

The current map is good enough as a phase-one baseline, but it should be hardened
before large-scale phase-two ingestion.

## Recommended Improvements Before Phase Two

### 1. Add Stable Interest IDs

Interest headings are currently strings. Similar names can drift or duplicate.

Before phase two, add stable IDs in the map and summary JSON:

```markdown
### agentic-coding-workflows

- Name: Agentic Coding Workflows
- Description: ...
- Example sources: ...
```

This makes future matching less sensitive to wording changes.

### 2. Parse Manual Map Edits

The map is human-editable, but edits are not currently ingested back into SQLite.

Phase two should support a refresh step that reads the Markdown map and extracts:

- interest IDs;
- preferred names;
- descriptions;
- aliases;
- manual merges or splits;
- deprecated interests.

Without this, human corrections can guide prompts but not reliably update the
machine-readable state.

### 3. Store A Richer Map Representation In SQLite

Add a normalized table or richer JSON summary for interest-map entries.

Possible table:

```sql
CREATE TABLE IF NOT EXISTS kb_interest_map_entries (
  interest_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL,
  aliases_json TEXT,
  example_sources_json TEXT,
  source_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
```

This would make the interest map easier to query, diff, test, and use for
retrieval.

### 4. Add A Map Verifier

Before phase two, add a verifier that checks:

- every example source link resolves;
- every example source has a decision row;
- source counts match SQLite;
- deferred counts match SQLite;
- recurring questions are deduped;
- no obvious placeholder headings such as "No strong match" appear as core
  interests.

This should run after every interest-map refresh.

### 5. Improve Interest Clustering

The current map has useful signals, but it still includes overly broad or
mechanically inferred labels.

Before foundation ingestion, run a deliberate map review pass:

- merge duplicate or near-duplicate interests;
- rename weak generated labels;
- split overly broad clusters;
- move open questions out of core interests;
- mark uncertain or one-off interests as emerging rather than core.

This matters because phase two will use the map to route many more sources.
Weak clusters will compound if they are left as the primary routing surface.

### 6. Keep Media Deferrals First-Class

The baseline correctly deferred many media-primary sources. Phase two should not
collapse these into normal interests until media has been inspected.

The map should continue to expose:

```markdown
## Deferred Media Inspection
```

and SQLite should keep those rows queryable by `status = deferred_media_inspection`.

## Practical Phase-Two Ingest Loop

```mermaid
sequenceDiagram
    participant Split as corpus-split.json
    participant Proc as Foundation/Holdout Procedure
    participant Map as Interest Map
    participant Source as Raw Source
    participant Agent as Agent
    participant DB as SQLite
    participant Report as Batch Report

    Proc->>Split: Select deterministic source batch
    Proc->>Map: Load current reviewed map

    loop For each source in batch
        Proc->>Source: Load source Markdown
        Proc->>Agent: Prompt with source + map + candidates
        Agent-->>Proc: Typed decision
        Proc->>Source: Render Ingest Decision
        Proc->>DB: Store decision
    end

    Proc->>DB: Regenerate map inputs from decisions
    Proc->>Map: Refresh interest-map.md
    Proc->>DB: Store revision summary
    Proc->>Report: Write batch quality/drift report
```

## Bottom Line

The intended design is:

```text
interest-map.md guides the agent;
kb_ingest_decisions preserves every source-level decision;
refreshInterestMap deterministically regenerates the map;
kb_interest_map_revisions records map refresh metadata.
```

Before phase two, the most important improvement is to make the interest map a
more reliable routing artifact: stable IDs, valid Markdown links, verifier
checks, richer SQLite summaries, and a path for manual edits to influence future
machine-readable state.

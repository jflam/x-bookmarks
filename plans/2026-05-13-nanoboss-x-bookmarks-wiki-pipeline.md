# Nanoboss X Bookmarks Wiki Pipeline Plan

Date: 2026-05-13

## Goal

Concretize X/Twitter bookmark ingestion into the first real implementation
substrate for the Personal AI OS.

The near-term product is not a general Personal OS platform. It is a repeatable
pipeline that turns X bookmarks into the Obsidian wiki signal the user actually
wants:

- durable wiki pages;
- maps;
- weekly finite review queues;
- source trails;
- follow-up source tasks;
- relationship-card candidates;
- spaced-repetition candidates;
- readable aliased Obsidian links;
- raw-source provenance.

The pipeline should be deterministic in control flow and validation, while using
agents for the synthesis work that cannot be made deterministic without losing
the point of the system.

## Read Context

This plan builds on:

- `plans/2026-05-12-personal-ai-os-product-spec.md`
- `plans/2026-05-12-personal-ai-os-agent-operating-manual.md`
- `plans/2026-05-11-bookmark-signals-kb-pipeline.md`
- `prompts/kb/ingest-batch-v2.md`
- the current Zig `x-bookmarks` CLI described in `README.md`

The Personal OS plans say the system should be local-first, agent-readable,
finite rather than engagement-maximizing, source-backed, and able to launch
agentic sessions from rich context. The bookmark pipeline is the first place to
make that concrete.

## Current Problem

The current X bookmarks system has a good raw material layer:

- OAuth bookmark sync;
- local SQLite storage;
- media and quote-post capture;
- Obsidian raw export;
- `raw/x/inbox`, `raw/x/ingested`, and `raw/x/ignored`;
- starter wiki schema, index, and log;
- mature ingestion prompts under `prompts/kb/`.

The missing layer is orchestration.

Right now, wiki ingestion is effectively:

```text
run Zig tool
  -> manually invoke a long prompt
  -> agent edits files
  -> human notices broken links/citations later
```

That does not satisfy the Personal OS requirement. The system needs a concrete,
agent-invokable pipeline that also invokes agents internally.

## Nanoboss Grounding

This plan should be implemented as a Nanoboss procedure workflow, not as a new
agent runtime or orchestration framework.

Relevant Nanoboss primitives:

- repo-scoped disk procedures loaded from `.nanoboss/procedures`;
- `ctx.agent.run(...)` for bounded downstream model calls;
- typed model outputs through `jsonType(...)`;
- `ctx.procedures.run(...)` for explicit procedure composition;
- durable run/ref lineage for top-level, procedure, and agent calls;
- cancellation and resumable procedure semantics;
- async dispatch if a later version needs background execution;
- existing `kb/*` procedures as a reference for manifest, compile, link, health,
  and refresh workflows.

The core design rule is simple: Nanoboss owns the procedure substrate. Agents
produce bounded typed synthesis. Deterministic code validates and applies
changes.

## Nanoboss Fit Review

This is a good candidate for a Nanoboss procedure, but only if the procedure
owns the deterministic control plane and the agent is treated as a bounded
synthesis worker.

It is a good fit because:

- the workflow is procedural and finite;
- inputs are local files and SQLite state;
- outputs are local Markdown files and raw-source moves;
- validation can be deterministic;
- every run benefits from durable run records, refs, child-agent traces,
  cancellation, recovery, and summaries;
- the user may want to launch it from an agent through Nanoboss MCP;
- the process should become self-improving through tested procedure changes,
  not through unbounded prompt drift.

It is a risky fit if implemented as a large monolithic procedure that directly
lets an agent edit the vault. That would import the worst part of the current
workflow into Nanoboss and add runtime complexity without enough extra safety.

The viable Nanoboss shape is:

```text
Nanoboss procedure
  -> deterministic sync/export/select/context/lint/finalize steps
  -> typed agent calls for triage and synthesis
  -> deterministic operation application
  -> child run/ref lineage captured by Nanoboss
```

The less viable shape is:

```text
Nanoboss procedure
  -> start one broad agent session
  -> let it edit the vault
  -> lint after the fact
```

That second design is better than manually pasting prompts, but it is not a
strong enough self-improving substrate.

## Architecture Decision

Make Nanoboss the deterministic procedure substrate. Use the configured
Nanoboss downstream agent for synthesis, not as the substrate itself.

The first implementation should be a repo-scoped Nanoboss procedure package
loaded from this repository. It should depend on Nanoboss public procedure APIs,
not on Nanoboss internals.

```text
X API / SQLite / raw bookmark export
  -> Nanoboss xbookmarks/wiki-refresh procedure
  -> deterministic batch/context builder
  -> typed downstream-agent synthesis
  -> deterministic operation applier
  -> deterministic lint and repair loop
  -> Nanoboss run/ref lineage
```

Do not start by rewriting the working Zig importer. Instead:

1. Keep the Zig CLI as the initial deterministic X API adapter.
2. Build repo-scoped Nanoboss procedures around the current raw export
   contract.
3. Use `ctx.agent.run(...)` for bounded model calls so Nanoboss records child
   runs and typed outputs.
4. Once the procedure pipeline is proven, decide whether to port the X API
   importer, SQLite schema, and Obsidian raw export to TypeScript.

This avoids blocking the agentic pipeline on a full importer rewrite and avoids
creating a second orchestration system next to Nanoboss.

## Proposed Package Shape

Prefer a repo-scoped Nanoboss procedure package under this repository:

```text
.nanoboss/
  procedures/
    xbookmarks/
      wiki-refresh.ts
      wiki-lint.ts
      wiki-select-batch.ts
      wiki-apply.ts
      lib/
        config.ts
        xbookmarks-zig-adapter.ts
        raw-source.ts
        context-bundle.ts
        wiki-search.ts
        wiki-operations.ts
        wiki-link-linter.ts
        frontmatter.ts
        obsidian-links.ts
        prompts.ts
        types.ts
      prompts/
        x-bookmarks-wiki.md
        obsidian-link-discipline.md
```

Nanoboss can discover repo-scoped disk procedures from
`.nanoboss/procedures`. That makes X-bookmarks ingestion a local procedure
without forcing the `x-bookmarks` repo to become the Nanoboss monorepo.

Initial commands:

```text
/xbookmarks/wiki-refresh limit=5 noSync=true
/xbookmarks/wiki-lint
/xbookmarks/wiki-select-batch limit=25
```

The implementation should keep most logic in plain TypeScript helper modules
with direct unit tests. The procedure entrypoints should be thin orchestration
wrappers over those helpers.

Avoid adding these in the first slice:

- a separate `agent/` CLI;
- a second run-manifest database;
- a new UI;
- async dispatch unless a run is long enough to require it;
- direct imports from Nanoboss package internals.

## Git Tracking Policy

The Nanoboss procedure implementation is source code for this repository and
must be checked in.

Track:

```text
.nanoboss/procedures/xbookmarks/**
```

Do not ignore `.nanoboss/` as a whole in this repo.

Generated procedure artifacts should not be committed by default:

```text
.nanoboss/xbookmarks/runs/
```

If a run artifact is useful as a fixture or regression test, copy a reduced,
sanitized version into an explicit test fixture path rather than committing the
live run directory.

## Invocation

Run these procedures from a Nanoboss session started in the `x-bookmarks`
workspace:

```bash
cd /Users/jflam/src/x-bookmarks
nanoboss cli
```

Then invoke slash commands in the Nanoboss CLI.

### Main Procedure

```text
/xbookmarks/wiki-refresh [options]
```

`wiki-refresh` is the end-to-end pipeline. It can sync/export bookmarks, select
a batch, build the context bundle, ask the configured downstream agent for a
typed `WikiIngestPlan`, apply or dry-run the plan, lint the result, optionally
repair lint failures, and return a typed procedure result.

### Supporting Procedures

```text
/xbookmarks/wiki-lint [options]
/xbookmarks/wiki-select-batch [options]
/xbookmarks/wiki-apply [options]
```

Supporting procedures are mostly for debugging and test development:

- `wiki-lint`: run deterministic wiki/raw-source checks without invoking an
  agent.
- `wiki-select-batch`: show the deterministic raw bookmark batch that would be
  processed.
- `wiki-apply`: apply a previously generated operation plan from an artifact
  path. This should be considered an implementation helper, not the normal user
  entrypoint.

### Parameter Reference

All parameters can be supplied as `key=value` tokens in the procedure prompt.
Paths containing spaces should be quoted if the Nanoboss prompt parser requires
it; examples below escape spaces with `\`.

| Parameter | Applies to | Default | Meaning |
| --- | --- | --- | --- |
| `limit` | `wiki-refresh`, `wiki-select-batch` | `5` for refresh, `25` for select | Maximum raw inbox files to process. |
| `noSync` | `wiki-refresh` | `false` | When `true`, skip X API sync and raw export; use existing inbox files. |
| `dryRun` | `wiki-refresh`, `wiki-apply` | `false` | Build and validate changes without writing wiki/raw-source mutations. Artifacts may still be written under `artifactRoot`. |
| `managedRoot` | all | config/env required | Managed Obsidian subtree, e.g. `/Users/jflam/src/brain2/X Bookmarks`. |
| `workspaceRoot` | all | Nanoboss `ctx.cwd` | Procedure workspace and default base for relative artifact paths. |
| `artifactRoot` | all | `.nanoboss/xbookmarks/runs` | Run artifact root, relative to `workspaceRoot` unless absolute. |
| `xBookmarksBinary` | `wiki-refresh` when `noSync=false` | `zig-out/bin/x-bookmarks` under `workspaceRoot` | Importer binary to shell out to for sync/export. |
| `batchId` | `wiki-refresh`, `wiki-select-batch` | generated from run ID | Stable label for selected batch and artifacts. |
| `agent` | `wiki-refresh` | Nanoboss session default | Optional downstream agent selection, if Nanoboss supports parsing it in procedure options. |
| `repair` | `wiki-refresh` | `true` in apply mode, `false` in dry-run mode | Whether to ask the agent for a repair plan after lint failure. |
| `maxRepairAttempts` | `wiki-refresh` | `1` initially, cap at `2` | Maximum bounded repair loops. |
| `planPath` | `wiki-apply` | none | Path to a previously generated `WikiIngestPlan` JSON artifact. |
| `changedOnly` | `wiki-refresh` sync/export step | `true` | Pass changed-only behavior to raw export when supported. |
| `fullSync` | `wiki-refresh` sync step | `false` | Ask the importer to do a full sync instead of normal incremental sync. |

Boolean parameters should accept `true` or `false`. Unknown parameters should
fail fast with a clear error so typos do not silently change run behavior.

### Configuration Defaults

For repeated use, prefer a repo-local config:

```json
{
  "workspaceRoot": "/Users/jflam/src/x-bookmarks",
  "managedRoot": "/Users/jflam/src/brain2/X Bookmarks",
  "xBookmarksBinary": "/Users/jflam/src/x-bookmarks/zig-out/bin/x-bookmarks",
  "artifactRoot": ".nanoboss/xbookmarks/runs"
}
```

Store it at:

```text
.nanoboss/xbookmarks/config.json
```

After that, normal invocations should not need `managedRoot=...`.

### Example Usage

Inspect the next batch without syncing or writing wiki changes:

```text
/xbookmarks/wiki-select-batch limit=5 managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Run the first safe end-to-end dry run:

```text
/xbookmarks/wiki-refresh limit=5 noSync=true dryRun=true managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Apply a small already-exported inbox batch:

```text
/xbookmarks/wiki-refresh limit=5 noSync=true managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Sync/export first, then process the next 10 raw sources:

```text
/xbookmarks/wiki-refresh limit=10 noSync=false managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Use repo-local config and only pass the behavior flags:

```text
/xbookmarks/wiki-refresh limit=10 noSync=true dryRun=true
```

Run lint only:

```text
/xbookmarks/wiki-lint managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Write artifacts to a temporary directory:

```text
/xbookmarks/wiki-refresh limit=5 noSync=true dryRun=true artifactRoot=/tmp/xbookmarks-runs managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Run without repair so failures are exposed directly:

```text
/xbookmarks/wiki-refresh limit=5 noSync=true repair=false managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Full sync before processing should be explicit because it may be slower and may
hit X API limits:

```text
/xbookmarks/wiki-refresh limit=25 noSync=false fullSync=true managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

### Expected Output

`wiki-refresh` should display:

- resolved `workspaceRoot`, `managedRoot`, and `artifactRoot`;
- selected source IDs and count;
- context bundle path;
- whether the run is dry-run or apply mode;
- pages that would be created or updated;
- raw sources that would be ingested or ignored;
- lint status;
- repair attempts, if any;
- follow-up sources, relationship candidates, and spaced-repetition candidates.

The typed procedure result should include the same data in machine-readable
form so a later Nanoboss procedure or agent can inspect the run without parsing
display text.

## Configuration

The procedure must not hard-code `~/src/brain2` or assume the Nanoboss current
working directory is the Obsidian vault.

Define two separate roots:

- `workspaceRoot`: the repository where the Nanoboss procedure is running,
  normally this `x-bookmarks` repo.
- `managedRoot`: the managed Obsidian subtree for the X bookmark knowledge base,
  normally `~/src/brain2/X Bookmarks`.

Resolve configuration in this order:

1. procedure prompt options, e.g. `managedRoot=...` and `workspaceRoot=...`;
2. environment variables, e.g. `XBOOKMARKS_MANAGED_ROOT` and
   `XBOOKMARKS_WORKSPACE_ROOT`;
3. a repo-local config file, e.g. `.nanoboss/xbookmarks/config.json`;
4. the existing `x-bookmarks` config if it contains enough Obsidian root
   information;
5. fail with an actionable error.

Suggested config shape:

```json
{
  "workspaceRoot": "/Users/jflam/src/x-bookmarks",
  "managedRoot": "/Users/jflam/src/brain2/X Bookmarks",
  "xBookmarksBinary": "/Users/jflam/src/x-bookmarks/zig-out/bin/x-bookmarks",
  "artifactRoot": ".nanoboss/xbookmarks/runs"
}
```

`artifactRoot` is relative to `workspaceRoot` unless absolute. The default
should be inside the `x-bookmarks` repo, not inside the Obsidian vault:

```text
<workspaceRoot>/.nanoboss/xbookmarks/runs/<run-id>/
```

This keeps procedure artifacts, context snapshots, dry-run diffs, and lint JSON
out of the human-facing Obsidian knowledge base. The agent can still receive
those files as context, and the final wiki output remains under `managedRoot`.

Only write under `managedRoot` for actual wiki/raw-source changes. Only write
under `artifactRoot` for run artifacts. Reject any operation that escapes those
two roots.

## End-To-End Procedure Pipeline

### 1. Sync And Raw Export

Initial implementation shells out to the current Zig binary from a Nanoboss
procedure:

```bash
zig-out/bin/x-bookmarks sync --yolo
zig-out/bin/x-bookmarks kb export-raw-x --changed
```

The procedure records command, exit code, stdout, stderr, and resolved vault
paths in the Nanoboss run output. If the command output is large, persist it as a
ref instead of inventing a parallel run log.

### 2. Select Stable Batch

The pipeline selects raw files from the configured managed root:

```text
<managedRoot>/raw/x/inbox/
```

Selection rules:

- newest first by original post date when available;
- otherwise by exported file metadata;
- stable tie-break by tweet ID;
- fixed `limit`;
- return typed `SelectedBookmark[]` data from the selection helper.

This gives the agent a fixed batch and makes retries understandable.

### 3. Build Context Bundle

Before calling the agent, build a deterministic context bundle:

```text
<artifactRoot>/<run-id>/context/
  run.json
  selected-bookmarks.json
  wiki-index.md
  schema.md
  home.md
  this-week.md
  relevant-maps/
  candidate-related-pages.json
```

The first version can find related pages using fast text search over wiki page
titles, aliases, source authors, extracted domains, hashtags, and simple
keywords. Embeddings can wait.

The context bundle path should also be returned as a Nanoboss ref or stored in
the procedure result so later runs can inspect the exact input snapshot.

### 4. Invoke Agent For Typed Operations

Use `ctx.agent.run(...)` with a typed descriptor for the first version. The
agent should return a structured operation plan, not edit files directly.

The core typed output should be close to:

```ts
type WikiOperation =
  | { kind: "create_page"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "update_page"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "update_review"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "update_map"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "ignore_source"; sourceId: string; reason: string }
  | { kind: "append_log"; markdown: string };

interface WikiIngestPlan {
  summary: string;
  operations: WikiOperation[];
  followUpSources: string[];
  relationshipCandidates: string[];
  spacedRepetitionCandidates: string[];
}
```

The agent call should use the Nanoboss-configured downstream agent unless the
caller explicitly overrides the agent selection. The pipeline should not depend
on a provider-specific API.

### 5. Agent Synthesis Responsibilities

The agent should decide:

- read each selected raw source;
- decide whether it is durable, review-only, follow-up-only, or ignored;
- update existing wiki pages before creating new fragments;
- update maps;
- update weekly review pages and source trail;
- update `wiki/index.md`;
- append to `wiki/log.md`;
- explain ignored sources with explicit `ignore_source` operations.

But the first candidate should ask the agent to return a plan. Deterministic
code should apply the plan.

Logical agent roles, even if implemented as a single typed prompt at first:

- `bookmark-triage`: decides durable subject, existing page candidates, ignore
  reason, and follow-up needs.
- `wiki-writer`: drafts Markdown operations for the managed wiki.
- `review-curator`: maintains weekly queue, finite review surface, source trail,
  relationship candidates, and spaced-repetition candidates.
- `lint-repair`: proposes narrow operation-level fixes for deterministic lint
  failures.

Avoid relying on autonomous sub-agent selection in the first version. Explicit
procedure steps are easier to reason about and test.

### 6. Deterministic Apply

Apply the `WikiIngestPlan` with deterministic code:

- reject writes outside the managed root;
- reject unsupported operation kinds;
- reject page paths that violate wiki path policy;
- write to a staging area or dry-run diff first;
- apply page writes atomically;
- infer raw-source moves only after page writes succeed;
- update raw frontmatter status during the move;
- preserve pre-run backups or rely on Git diff review.

The applier should be idempotent where practical. Re-running a failed run should
either reuse the selected batch and operation plan or fail clearly because the
underlying files moved.

Raw-source move policy is deterministic and not model-owned:

- Move a selected source to `raw/x/ignored` if the accepted plan contains an
  `ignore_source` operation for that source.
- Move a selected source to `raw/x/ingested` if it is referenced by an accepted
  page, review, map, or log operation.
- Leave a selected source in `raw/x/inbox` if neither condition is true, report
  it as unresolved, and fail apply mode unless the caller explicitly allows
  partial processing in a later version.
- Reject any plan that both ignores and cites the same source.
- Reject any `ignore_source` without a non-empty reason.

### 7. Deterministic Lint

After applying the plan, run a TypeScript linter over the changed wiki and
selected raw sources.

Required checks:

- every raw-source wikilink has a readable alias;
- raw X citations include the X embed and the raw Markdown link on the same
  line;
- no human-visible link renders as a path such as
  `../../raw/x/ingested/<id>`;
- no processed source remains cited under `raw/x/inbox`;
- every raw-source citation resolves to an existing file;
- every moved raw source has frontmatter `status: ingested` or
  `status: ignored`;
- every updated page has valid frontmatter according to the local schema;
- changed durable pages are listed in `wiki/index.md`;
- `wiki/log.md` has a structured entry for the run;
- weekly review `Source Trail` contains every selected source, newest to oldest;
- maps are updated for new durable pages;
- ignored sources include an explicit reason.

The linter should return typed Nanoboss procedure data and optionally write
human-readable artifacts:

```text
<artifactRoot>/<run-id>/lint.json
<artifactRoot>/<run-id>/lint.md
```

### 8. Repair Loop

If lint fails:

1. call the agent with `lint.json` and the previous `WikiIngestPlan`;
2. rerun the deterministic linter;
3. repeat up to a small fixed limit, probably 2;
4. fail the run if lint still fails.

The procedure controls the loop. Agents do not decide when validation is good
enough.

### 9. Finalize

Finalization returns typed procedure data and a concise display summary:

The result includes:

- files ingested;
- files ignored;
- pages created;
- pages updated;
- maps updated;
- review queues updated;
- linter status;
- follow-up sources;
- relationship-card candidates;
- spaced-repetition candidates.

Nanoboss already records run lineage, child agent calls, summaries, refs, and
streamed UI updates. Do not duplicate that with a second run store unless there
is a concrete missing capability.

## Nanoboss Procedure Sketch

This is not final code, but it demonstrates the intended control shape.

```ts
import typia from "typia";
import {
  expectData,
  jsonType,
  type Procedure,
} from "@nanoboss/procedure-sdk";
import {
  applyWikiPlan,
  buildContextBundle,
  buildRepairPrompt,
  buildWikiIngestPrompt,
  lintWiki,
  parseRefreshOptions,
  resolveXBookmarksConfig,
  selectBatch,
  syncAndExportRawX,
} from "./lib";
import type { WikiIngestPlan, XBookmarksRefreshData } from "./lib/types";

const WikiIngestPlanType = jsonType<WikiIngestPlan>(
  typia.json.schema<WikiIngestPlan>(),
  typia.createValidate<WikiIngestPlan>(),
);

export default {
  name: "xbookmarks/wiki-refresh",
  description: "Compile X bookmark raw sources into the Obsidian wiki",
  inputHint: "limit=5 noSync=true managedRoot=/path/to/X Bookmarks",
  async execute(prompt, ctx) {
    const options = parseRefreshOptions(prompt);
    const config = await resolveXBookmarksConfig({
      cwd: ctx.cwd,
      options,
    });

    if (!options.noSync) {
      ctx.ui.status({ phase: "sync", message: "Syncing X bookmarks" });
      await syncAndExportRawX({ config, ctx });
    }

    ctx.ui.status({ phase: "select", message: "Selecting raw bookmark batch" });
    const selected = await selectBatch({
      managedRoot: config.managedRoot,
      limit: options.limit ?? 5,
    });

    const context = await buildContextBundle({
      managedRoot: config.managedRoot,
      artifactRoot: config.artifactRoot,
      selected,
    });

    ctx.ui.status({ phase: "synthesis", message: "Asking agent for wiki operations" });
    const planResult = await ctx.agent.run(
      buildWikiIngestPrompt({ selected, context }),
      WikiIngestPlanType,
      {
        stream: false,
        agent: options.agent,
      },
    );
    const plan = expectData(planResult, "Agent returned no wiki ingest plan");

    ctx.ui.status({ phase: "apply", message: "Applying wiki operations" });
    const applied = await applyWikiPlan({
      managedRoot: config.managedRoot,
      artifactRoot: config.artifactRoot,
      selected,
      plan,
      dryRun: options.dryRun,
    });

    ctx.ui.status({ phase: "lint", message: "Linting wiki citations and links" });
    let lint = await lintWiki({
      managedRoot: config.managedRoot,
      artifactRoot: config.artifactRoot,
      selected,
    });

    if (!lint.ok && !options.dryRun) {
      const repair = await ctx.agent.run(
        buildRepairPrompt({ plan, lint }),
        WikiIngestPlanType,
        { stream: false, agent: options.agent },
      );
      const repairPlan = expectData(repair, "Agent returned no repair plan");
      await applyWikiPlan({
        managedRoot: config.managedRoot,
        artifactRoot: config.artifactRoot,
        selected,
        plan: repairPlan,
        dryRun: false,
      });
      lint = await lintWiki({
        managedRoot: config.managedRoot,
        artifactRoot: config.artifactRoot,
        selected,
      });
    }

    if (!lint.ok) {
      throw new Error(`xbookmarks/wiki-refresh failed lint: ${lint.errorCount} error(s)`);
    }

    const data: XBookmarksRefreshData = {
      selectedSourceIds: selected.map((item) => item.sourceId),
      applied,
      lint,
      followUpSources: plan.followUpSources,
      relationshipCandidates: plan.relationshipCandidates,
      spacedRepetitionCandidates: plan.spacedRepetitionCandidates,
    };

    return {
      data,
      display: [
        `Processed ${selected.length} X bookmark source(s).`,
        `Created ${applied.createdPages.length} page(s).`,
        `Updated ${applied.updatedPages.length} page(s).`,
        `Ignored ${applied.ignoredSourceIds.length} source(s).`,
        `Lint passed with ${lint.warningCount} warning(s).`,
      ].join("\n"),
      summary: `xbookmarks/wiki-refresh: ${selected.length} source(s)`,
    };
  },
} satisfies Procedure;
```

The exact typed schemas should live in `lib/types.ts`. The important property is
that the procedure receives typed model output, deterministic code applies it,
and Nanoboss records the child agent call as part of the run tree.

## Prompt Modules

Use reusable prompt modules, but do not depend on prompts for correctness.

Initial prompt modules:

```text
.nanoboss/procedures/xbookmarks/prompts/x-bookmarks-wiki.md
.nanoboss/procedures/xbookmarks/prompts/obsidian-link-discipline.md
```

`x-bookmarks-wiki` should absorb the durable parts of
`prompts/kb/ingest-batch-v2.md`:

- page maturity rules;
- review queue structure;
- weekly brief quality;
- map update requirements;
- index/log rules;
- raw-source bookkeeping.

`obsidian-link-discipline` should focus only on links and citations:

- aliased wikilinks;
- raw-source citation format;
- correct relative paths;
- X embed plus raw Markdown link;
- no rendered path-like link text.

The rule remains: prompt modules guide the agent, deterministic procedures and
linters enforce the rules.

### Policy Split

Keep `wiki/schema.md` as the durable, user-visible operating policy for the
knowledge base. Keep repo-scoped prompt modules focused on procedure execution
scaffolding.

The procedure should always include the current `wiki/schema.md` in the context
bundle and tell the agent that it is the source of truth for wiki policy.
Procedure prompt modules may summarize or quote relevant parts, but they should
not fork durable wiki rules.

Examples of what belongs in `wiki/schema.md`:

- page types and frontmatter expectations;
- citation format for raw X sources;
- when to create pages versus update existing pages;
- map and index maintenance policy;
- weekly review page shape;
- source trail requirements;
- spaced-repetition candidate criteria;
- maturity levels such as `seed`, `active`, and `synthesis`;
- policies for contradictions, caveats, ignored sources, and follow-up sources.

Examples of what belongs in repo-scoped procedure prompt modules:

- request a typed `WikiIngestPlan` and no prose outside the JSON result;
- list the selected source IDs for this run;
- explain the operation schema the model must fill;
- tell the agent that deterministic code, not the model, moves raw files;
- bound the batch to `limit` and the current context bundle;
- ask for concise operation summaries suitable for the Nanoboss run display;
- instruct repair prompts to fix only provided lint findings.

If a rule should still apply when a human or another agent edits the wiki
outside this procedure, it belongs in `wiki/schema.md`. If a rule exists only to
make this Nanoboss procedure return the right typed payload, it belongs in the
procedure prompt module.

## Procedure Helpers And Tools

Start with a small deterministic helper surface inside the procedure package:

- `selected_bookmarks`: returns selected raw-source paths and metadata.
- `wiki_search`: deterministic grep/title/alias search over the wiki.
- `related_pages`: returns likely existing pages for the selected batch.
- `lint_obsidian_wiki`: runs deterministic checks and returns JSON findings.
- `apply_wiki_plan`: validates and applies typed operations.
- `resolve_xbookmarks_config`: resolves `workspaceRoot`, `managedRoot`,
  `artifactRoot`, and the importer binary path.

Expose these as procedure helper functions. The agent receives the selected
batch and context bundle in the prompt and returns typed data. Deterministic
procedure code calls the helper functions.

Avoid giving agents direct authority to delete raw sources or durable wiki
pages. Moves from inbox to ingested/ignored should be staged, validated, and
finalized by deterministic code.

## Link Linter Design

The linter is a first-class product component because broken Obsidian links were
a real failure mode.

Implementation details:

- Use a small custom parser for v1 instead of a general Markdown AST parser.
  This keeps the dependency surface small and improves the security posture.
  The first required checks are line-oriented and Obsidian-specific, so a
  general Markdown parser would not remove much complexity.
- Parse Markdown files line by line for Obsidian wikilinks:
  `[[target|alias]]` and `[[target]]`.
- Resolve relative wiki targets from the containing file.
- Classify raw-source links by target path containing `/raw/x/`.
- Require raw-source aliases matching:
  `YY-MM-DD @username: summary` or `Ignored YY-MM-DD @username: summary`.
- Require an X URL embed before the raw-source link on the same line.
- Flag raw-source links without aliases.
- Flag aliases that are still opaque, such as `X <tweet_id>`.
- Flag citations that point to missing files.
- Flag citations pointing at inbox after finalization.
- Parse YAML frontmatter with a real parser.
- Emit machine-readable findings with file, line, rule ID, severity, and
  suggested fix where safe.

Autofix should be conservative. It can fix simple alias/path mistakes only when
the raw file metadata contains the needed date, username, and canonical URL.

Add a Markdown AST parser later only if there is a concrete check that cannot be
implemented clearly with the custom parser.

## Determinism Model

The agent's prose and synthesis will vary. The pipeline should make everything
around that deterministic:

- fixed batch selection;
- Nanoboss run ID and child-run lineage;
- context bundle snapshot;
- stable prompts generated from versioned local prompt modules;
- typed agent output schemas;
- deterministic operation applier;
- bounded repair loop;
- deterministic linter;
- explicit success/failure state;
- no silent mutation outside the managed root;
- durable Nanoboss result data, display summary, refs, and logs.

Success is not bit-for-bit identical wiki prose. Success is repeatable,
auditable, bounded operation.

## Nanoboss Complexity Guardrails

The main risk is overusing Nanoboss. This workflow should prove the procedure
substrate, not exercise every runtime feature.

Use:

- repo-scoped disk procedures;
- `@nanoboss/procedure-sdk` public APIs only;
- `ctx.agent.run(...)` for model calls;
- typed descriptors for model outputs;
- plain TypeScript helper functions for deterministic work;
- `ctx.ui.status(...)` and concise display summaries;
- direct foreground execution for the first slice.

Avoid in the first slice:

- background dispatch;
- custom TUI extensions;
- direct `@nanoboss/*` internal imports;
- custom tool servers;
- parallel child procedures;
- provider-specific agent process management;
- a second run/ref/artifact store;
- self-modifying procedure code.

Dependency posture:

- Do not add a root `package.json`, root `bun.lock`, or repo-level third-party
  runtime dependencies to `x-bookmarks` for v1.
- Use Nanoboss' existing disk-procedure build path and runtime dependencies.
- Use Nanoboss' standard `typia` + `jsonType(...)` pattern for typed agent
  schemas, because Nanoboss already builds disk procedures with Typia support.
- Keep X-bookmarks-specific helpers dependency-light and prefer small local
  parsers where the logic is narrow and security-sensitive.

The procedure becomes a better self-improvement substrate after the first slice
has tests and fixtures. At that point, an agent can propose procedure changes,
but promotion should require deterministic validation.

Self-improvement promotion path:

```text
agent proposes procedure/prompt/linter change
  -> write to branch or staging area
  -> run unit tests
  -> run fixture wiki ingestion
  -> run wiki lint
  -> compare run summary against expectations
  -> human approval or explicit auto-approval policy
  -> promote
```

## Zig To TypeScript Migration

The Zig implementation is useful but awkward for fast iteration on procedure
helpers. That is not urgent while Nanoboss can shell out to the working CLI.

Recommended migration path:

### Phase A: Wrap Zig

The Nanoboss procedure shells out to:

```bash
x-bookmarks sync
x-bookmarks kb export-raw-x --changed
x-bookmarks kb status
```

This proves the procedure pipeline without reimplementing OAuth, X API paging,
SQLite migrations, or media handling.

### Phase B: Extract Contracts

Write TypeScript interfaces for:

- config;
- bookmark metadata;
- raw source Markdown frontmatter;
- lint findings;
- wiki operation summaries.

These contracts should match the existing raw export format so the importer can
be swapped later.

### Phase C: Port Only If Needed

Reimplement the importer in Bun/TypeScript when one of these becomes true:

- Zig blocks useful procedure-level integration or error handling;
- maintaining two CLIs becomes more expensive than a port;
- X API schema evolution requires faster iteration;
- agent-authored changes need to span importer and procedure helpers frequently;
- TypeScript libraries materially reduce OAuth, Markdown, YAML, SQLite, or MCP
  complexity.

If porting happens, preserve the current SQLite data or provide a migration
command. Do not strand the existing local archive.

## First Thin Vertical Slice

Build the smallest useful run:

```text
/xbookmarks/wiki-refresh limit=5 noSync=true dryRun=true managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

It should:

1. read existing raw files from `raw/x/inbox`;
2. select 5 files deterministically;
3. build a context bundle;
4. call `ctx.agent.run(...)` for a typed `WikiIngestPlan`;
5. apply the plan in dry-run mode;
6. run the link/citation linter;
7. return typed procedure data and a concise summary.

Do not include X API sync in the first slice. Use already-exported raw files.
Do not move raw files in the first dry-run slice.

Second slice:

```text
/xbookmarks/wiki-refresh limit=5 noSync=true managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

That run may apply writes and raw-source moves after lint succeeds.

## Validation

Local validation:

```bash
zig build test
bun test
nanoboss cli
# then run /xbookmarks/wiki-lint
# then run /xbookmarks/wiki-refresh limit=5 noSync=true dryRun=true managedRoot=/Users/jflam/src/brain2/X\ Bookmarks
```

Acceptance criteria:

- Nanoboss run exists with child agent run;
- resolved `workspaceRoot`, `managedRoot`, and `artifactRoot` are shown in the
  procedure output;
- selected batch is stable;
- agent output validates against the typed `WikiIngestPlan` schema;
- dry run reports at least one real wiki page or review page operation from raw
  sources;
- apply mode updates `wiki/index.md` and `wiki/log.md`;
- apply mode moves or stages processed raw files correctly;
- all raw citations use X embed plus aliased raw link;
- linter exits nonzero on intentionally broken links;
- repair loop fixes a simple raw-link alias failure in apply mode;
- run summary is readable without inspecting raw agent logs.

## Non-Goals

- Do not build the full Personal OS yet.
- Do not build a general RAG service.
- Do not replace Obsidian as the reading surface.
- Do not build a bookmark viewer in this phase.
- Do not auto-delete raw sources or durable wiki pages.
- Do not make agents perform financial, legal, medical, publishing, or external
  actions.
- Do not make the LLM responsible for deciding whether validation passed.
- Do not build a second Nanoboss-like run system inside `x-bookmarks`.

## Resolved Implementation Decisions

- The procedure lives under `.nanoboss/procedures/xbookmarks/` and is checked
  into this repo.
- The default model is the current Nanoboss session default. The procedure may
  accept an optional `agent` override, but it should not define a provider
  default.
- Context bundles and lint artifacts live under
  `.nanoboss/xbookmarks/runs/<run-id>/` by default, not in the Obsidian vault.
- Raw-source moves are inferred deterministically from accepted citations and
  `ignore_source` operations.
- The v1 linter uses a small custom parser to minimize third-party dependency
  and security risk.
- `wiki/schema.md` remains the durable wiki policy source of truth. Procedure
  prompt modules contain only execution scaffolding for typed Nanoboss runs.

## Recommended Next Step

Implement the first thin vertical slice as a repo-scoped Nanoboss procedure:

```text
.nanoboss/procedures/xbookmarks/wiki-refresh.ts
.nanoboss/procedures/xbookmarks/wiki-lint.ts
.nanoboss/procedures/xbookmarks/lib/...
```

Start with `dryRun=true`, use `ctx.agent.run(...)` with the configured Nanoboss
downstream agent, and require typed `WikiIngestPlan` output.

The highest-leverage first component is the linter. It makes the agentic layer
trustworthy enough to iterate on the pipeline without repeatedly breaking the
wiki's navigability.

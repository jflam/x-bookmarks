# Concretize X Bookmarks Into A Nanoboss Wiki Pipeline

You are planning the next implementation phase for `x-bookmarks` and the user's
Personal AI Operating System.

Read these local files first:

1. `plans/2026-05-12-personal-ai-os-product-spec.md`
2. `plans/2026-05-12-personal-ai-os-agent-operating-manual.md`
3. `plans/2026-05-11-bookmark-signals-kb-pipeline.md`
4. `prompts/kb/ingest-batch-v2.md`
5. `README.md`

The immediate problem is that the Personal OS plans describe rich agentic
behavior, but the current X bookmark wiki process does not yet have a real
implementation substrate. Today, the workflow is mostly:

- run the Zig `x-bookmarks` tool to sync/export raw X bookmarks;
- hand a long Markdown prompt to an agent;
- let the agent edit the Obsidian wiki;
- manually inspect whether citations, aliases, maps, reviews, and raw-source
  moves came out correctly.

That is too ad hoc for the first critical Personal OS signal source. The user
wants the X/Twitter bookmark ingestion pipeline to become a concrete,
repeatable, end-to-end system that can be invoked by an agent and that also
invokes agents internally to perform synthesis.

Plan around Nanoboss as the deterministic procedure substrate. Inspect the
Nanoboss repository at:

```text
~/agentboss/workspaces/nanoboss
```

Review whether this is a good candidate for a Nanoboss procedure. Pay special
attention to:

- repo-scoped disk procedures;
- `ctx.agent.run(...)` typed agent calls;
- `ctx.procedures.run(...)` procedure composition;
- durable run/ref lineage;
- cancellation and dispatch semantics;
- existing `kb/*` procedures;
- whether adding this workflow to Nanoboss creates useful structure or excess
  runtime complexity.

The preferred implementation direction is a Bun + TypeScript Nanoboss procedure
package, not a separate orchestration CLI. Nanoboss should own deterministic
control flow, typed outputs, validation, recovery, and run lineage. The existing
Zig importer can remain as a compatibility adapter at first, but the plan should
explicitly address whether and when to reimplement `x-bookmarks` in TypeScript.

Make the repo and managed wiki roots configurable. Do not hard-code
`~/src/brain2`. Distinguish:

- `workspaceRoot`: the repo where the Nanoboss procedure and run artifacts live,
  normally `~/src/x-bookmarks`;
- `managedRoot`: the managed Obsidian subtree for the knowledge base, normally
  `~/src/brain2/X Bookmarks`;
- `artifactRoot`: procedure artifacts such as context bundles, dry-run diffs,
  and lint JSON, preferably under `<workspaceRoot>/.nanoboss/xbookmarks/runs`.

The plan should state where context bundles live and why they should not be
written into the human-facing Obsidian wiki by default.

The target pipeline should be deterministic in its control flow even though the
wiki synthesis is agentic:

1. sync bookmarks;
2. export/update raw bookmark inbox;
3. select a stable batch;
4. build a context bundle;
5. invoke the configured downstream agent from a Nanoboss procedure;
6. require typed operation summaries rather than direct agent file edits;
7. apply operations with deterministic code;
8. run a deterministic linter over wiki links, citations, frontmatter, maps,
   review queues, logs, and raw-source bookkeeping;
9. optionally invoke a repair agent when lint fails;
10. finalize raw-source moves and return a durable Nanoboss procedure result.

The plan must make the wiki-generation goal concrete. The signal the user wants
is not a bookmark viewer. It is a compiled personal knowledge base in Obsidian:

- durable wiki pages;
- maps;
- weekly finite review pages;
- source trails;
- follow-up source collection;
- relationship-card candidates;
- spaced-repetition candidates;
- readable aliased Obsidian links;
- raw-source provenance.

Include a small TypeScript code fragment showing the Nanoboss procedure shape:
`Procedure`, typed `jsonType(...)` output, `ctx.agent.run(...)`, deterministic
apply, lint, and repair.

Call out the link/citation linter as a first-class deterministic component. It
should catch the known failure mode where Obsidian links render as raw paths or
where raw-source citations lose either the X embed or the aliased Markdown link.

Write the output as a first-draft implementation plan in `plans/`, dated today.
Keep the plan pragmatic: identify the first thin vertical slice, validation
criteria, migration strategy from Zig, open questions, and non-goals.

import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  applyWikiPlan,
  applySensemakingDecision,
  buildReviewPages,
  buildContextBundle,
  lintWiki,
  refreshInterestMap,
  selectBatch,
} from "../.nanoboss/procedures/xbookmarks/lib/index.ts";
import wikiRefresh from "../.nanoboss/procedures/xbookmarks/wiki-refresh.ts";
import wikiBaselineBuild from "../.nanoboss/procedures/xbookmarks/wiki-baseline-build.ts";
import wikiTopicSynthesisRefresh from "../.nanoboss/procedures/xbookmarks/wiki-topic-synthesis-refresh.ts";
import type { KbSensemakingDecision, WikiIngestPlan, XBookmarksConfig } from "../.nanoboss/procedures/xbookmarks/lib/types.ts";

test("selects, previews, lints, and applies a raw X bookmark plan", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  const selected = await selectBatch({ managedRoot, limit: 5 });
  expect(selected.map((item) => item.sourceId)).toEqual(["123"]);

  const context = await buildContextBundle({ config, selected, batchId: "fixture" });
  expect(await readFile(context.selectedMediaPath, "utf8")).toContain("Downloaded media:");
  expect(await readFile(context.selectedMediaPath, "utf8")).toContain("/tmp/agent-harness-chart.jpg");
  const plan = fixturePlan();
  const dry = await applyWikiPlan({ config, selected, plan, dryRun: true, runId: context.runId });
  expect(dry.createdPages).toContain("wiki/concepts/agent-harness-eval-loops.md");
  expect(dry.ingestedSourceIds).toEqual(["123"]);

  const dryLint = await lintWiki({ config, selected, plan, runId: context.runId });
  expect(dryLint.ok).toBe(true);

  const applied = await applyWikiPlan({ config, selected, plan, dryRun: false, runId: context.runId });
  expect(applied.ingestedSourceIds).toEqual(["123"]);
  const moved = await readFile(join(managedRoot, "raw", "x", "ingested", "123.md"), "utf8");
  expect(moved).toContain('status: "ingested"');
});

test("linter rejects unaliased raw-source wikilinks", async () => {
  const { config } = await createFixtureWiki();
  await writeFile(
    join(config.managedRoot, "wiki", "concepts", "broken.md"),
    [
      "---",
      "type: concept",
      "status: active",
      "created: 2026-05-14",
      "updated: 2026-05-14",
      "source_count: 1",
      "tags: []",
      "---",
      "",
      "# Broken",
      "",
      "Sources: ![](https://x.com/alice/status/123) [[../../raw/x/inbox/123]]",
      "",
    ].join("\n"),
    "utf8",
  );

  const lint = await lintWiki({ config });
  expect(lint.ok).toBe(false);
  expect(lint.findings.some((finding) => finding.ruleId === "raw-link-alias")).toBe(true);
});

test("linter rejects source-only wiki summaries and notes", async () => {
  const { config } = await createFixtureWiki();
  await writeFile(
    join(config.managedRoot, "wiki", "concepts", "source-dump.md"),
    [
      "---",
      "type: concept",
      "status: active",
      "created: 2026-05-14",
      "updated: 2026-05-14",
      "source_count: 1",
      "tags: []",
      "---",
      "",
      "# Source Dump",
      "",
      "## Summary",
      "",
      "![](https://x.com/alice/status/123) [[../../raw/x/inbox/123|26-05-10 @alice: durable eval loops for agent harnesses]] ^x-123",
      "",
      "## Notes",
      "",
      "![](https://x.com/alice/status/123) [[../../raw/x/inbox/123|26-05-10 @alice: durable eval loops for agent harnesses]] ^x-123",
      "",
    ].join("\n"),
    "utf8",
  );

  const lint = await lintWiki({ config });
  expect(lint.ok).toBe(false);
  expect(lint.findings.some((finding) => finding.ruleId === "wiki-summary-narrative-missing")).toBe(true);
  expect(lint.findings.some((finding) => finding.ruleId === "wiki-notes-source-dump")).toBe(true);
});

test("builds weekly review pages with compact tweet links and wiki backlinks", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  const selected = await selectBatch({ managedRoot, limit: 1 });
  const context = await buildContextBundle({ config, selected, batchId: "fixture" });
  await applyWikiPlan({ config, selected, plan: fixturePlan(), dryRun: false, runId: context.runId });

  const result = await buildReviewPages({
    config,
    dryRun: false,
    weeks: ["2026-W19"],
    overwriteExisting: true,
    runId: "fixture-review",
  });

  expect(result.createdPages).toEqual(["wiki/reviews/2026-W19.md"]);
  const review = await readFile(join(managedRoot, "wiki", "reviews", "2026-W19.md"), "utf8");
  expect(review).toContain("# 2026-W19 Review\n\nMay 4-10, 2026");
  expect(review).toContain("![](https://x.com/alice/status/123)\n\n[[../../raw/x/ingested/123|Captured bookmark]]");
  expect(review).toContain("Wiki entries:\n- [[../concepts/agent-harness-eval-loops#^x-123|Agent Harness Eval Loops]]");

  const lint = await lintWiki({ config });
  expect(lint.ok).toBe(true);
});

test("builds an explicit empty source-date weekly review page", async () => {
  const { config } = await createFixtureWiki();
  const result = await buildReviewPages({
    config,
    dryRun: false,
    weeks: ["2026-W20"],
    overwriteExisting: true,
    runId: "fixture-empty-review",
  });

  expect(result.createdPages).toEqual(["wiki/reviews/2026-W20.md"]);
  const review = await readFile(join(config.managedRoot, "wiki", "reviews", "2026-W20.md"), "utf8");
  expect(review).toContain("# 2026-W20 Review\n\nMay 11-17, 2026");
  expect(review).toContain("No captured X bookmarks in the current processed archive were authored during this week yet.");
});

test("wiki-refresh orchestrates a non-empty dry run through typed agent output", async () => {
  const { config } = await createFixtureWiki();
  const calls: string[] = [];
  const result = await wikiRefresh.execute("Dry run the next 1 exported bookmark. Do not sync.", {
    cwd: config.workspaceRoot,
    assertNotCancelled() {},
    ui: { status() {} },
    agent: {
      async run(prompt, descriptor) {
        calls.push(prompt);
        const data = calls.length === 1
          ? {
            mode: "dry-run",
            syncMode: "none",
            limit: 1,
            rationale: "fixture",
            confidence: "high",
          }
          : fixturePlan();
        if (!descriptor.validate(data)) throw new Error("fixture agent returned invalid typed data");
        return { data };
      },
    },
  });

  expect(typeof result).toBe("object");
  if (!result || typeof result !== "object" || !("data" in result)) throw new Error("missing procedure data");
  const data = result.data as { selectedSourceIds: string[]; applied: { createdPages: string[] }; lint: { ok: boolean } };
  expect(data.selectedSourceIds).toEqual(["123"]);
  expect(data.applied.createdPages).toContain("wiki/concepts/agent-harness-eval-loops.md");
  expect(data.lint.ok).toBe(true);
  expect(calls.length).toBe(2);
});

test("wiki-refresh repair loop fixes a raw-link alias failure in apply mode", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  const brokenPlan = fixturePlan();
  brokenPlan.operations = brokenPlan.operations.map((operation) => {
    if (operation.kind !== "create_page") return operation;
    return {
      ...operation,
      markdown: operation.markdown.replace(
        "[[../../raw/x/ingested/123|26-05-10 @alice: durable eval loops for agent harnesses]]",
        "[[../../raw/x/ingested/123]]",
      ),
    };
  });

  const calls: string[] = [];
  const result = await wikiRefresh.execute("Process the next 1 exported bookmark from the inbox.", {
    cwd: config.workspaceRoot,
    assertNotCancelled() {},
    ui: { status() {} },
    agent: {
      async run(prompt, descriptor) {
        calls.push(prompt);
        const data = calls.length === 1
          ? {
            mode: "apply",
            syncMode: "none",
            limit: 1,
            repair: true,
            maxRepairAttempts: 1,
            rationale: "fixture",
            confidence: "high",
          }
          : calls.length === 2
            ? brokenPlan
            : fixturePlan();
        if (!descriptor.validate(data)) throw new Error("fixture agent returned invalid typed data");
        return { data };
      },
    },
  });

  expect(typeof result).toBe("object");
  if (!result || typeof result !== "object" || !("data" in result)) throw new Error("missing procedure data");
  const data = result.data as { applied: { ingestedSourceIds: string[] }; lint: { ok: boolean } };
  expect(data.applied.ingestedSourceIds).toEqual(["123"]);
  expect(data.lint.ok).toBe(true);
  expect(calls.length).toBe(3);
  expect(await readFile(join(managedRoot, "raw", "x", "ingested", "123.md"), "utf8")).toContain('status: "ingested"');
});

test("topic synthesis refresh updates existing topic pages without moving raw sources", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  await writeFile(
    join(managedRoot, "raw", "x", "ingested", "123.md"),
    rawBookmark().replace('status: "inbox"', 'status: "ingested"'),
    "utf8",
  );
  await writeFile(
    join(managedRoot, "wiki", "concepts", "agent-harness-eval-loops.md"),
    [
      "---",
      "type: concept",
      "status: active",
      "created: 2026-05-14",
      "updated: 2026-05-14",
      "source_count: 1",
      "tags: []",
      "---",
      "",
      "# Agent Harness Eval Loops",
      "",
      "## Summary",
      "",
      "Agent harnesses need durable eval loops. The evidence below is the current source trail for reviewing this topic and improving the synthesis over time.",
      "",
      "## Notes",
      "",
      "- Revisit this page during future ingest runs to turn repeated source patterns into sharper claims, caveats, and review questions.",
      "",
      "## Examples / Evidence",
      "",
      "![](https://x.com/alice/status/123) [[../../raw/x/ingested/123|26-05-10 @alice: durable eval loops for agent harnesses]] ^x-123",
      "",
    ].join("\n"),
    "utf8",
  );

  const calls: string[] = [];
  const result = await wikiTopicSynthesisRefresh.execute(JSON.stringify({
    mode: "apply",
    paths: ["wiki/concepts/agent-harness-eval-loops.md"],
    limit: 1,
    rationale: "fixture",
    confidence: "high",
  }), {
    cwd: config.workspaceRoot,
    assertNotCancelled() {},
    ui: { status() {} },
    agent: {
      async run(prompt, descriptor) {
        calls.push(prompt);
        const data = {
          summary: "Refresh one topic page",
          operations: [
            {
              kind: "update_page",
              path: "wiki/concepts/agent-harness-eval-loops.md",
              sourceIds: [],
              markdown: [
                "---",
                "type: concept",
                "status: active",
                "created: 2026-05-14",
                "updated: 2026-05-14",
                "source_count: 1",
                "tags: []",
                "---",
                "",
                "# Agent Harness Eval Loops",
                "",
                "## Summary",
                "",
                "Agent harness evaluation is a workflow discipline: agents need repeatable checks that turn their large output volume into reviewable, trustworthy changes.",
                "",
                "## Notes",
                "",
                "- Treat eval loops as the control layer around agentic implementation work.",
                "- Review the source card below before promoting this into a broader quality-gates page.",
                "",
                "## Examples / Evidence",
                "",
                "![](https://x.com/alice/status/123) [[../../raw/x/ingested/123|26-05-10 @alice: durable eval loops for agent harnesses]] ^x-123",
                "",
              ].join("\n"),
            },
            {
              kind: "append_log",
              sourceIds: [],
              markdown: [
                "## [2026-05-14] topic synthesis refresh | Agent Harness Eval Loops",
                "",
                "- Refreshed [[concepts/agent-harness-eval-loops|Agent Harness Eval Loops]].",
                "",
              ].join("\n"),
            },
          ],
          followUpSources: [],
          relationshipCandidates: [],
          spacedRepetitionCandidates: [],
        };
        if (!descriptor.validate(data)) throw new Error("fixture agent returned invalid typed data");
        return { data };
      },
    },
  });

  expect(typeof result).toBe("object");
  if (!result || typeof result !== "object" || !("data" in result)) throw new Error("missing procedure data");
  const data = result.data as { selectedTopicPaths: string[]; applied: { updatedPages: string[] }; lint: { ok: boolean } };
  expect(data.selectedTopicPaths).toEqual(["wiki/concepts/agent-harness-eval-loops.md"]);
  expect(data.applied.updatedPages).toContain("wiki/concepts/agent-harness-eval-loops.md");
  expect(data.lint.ok).toBe(true);
  expect(calls.length).toBe(1);
  expect(await readFile(join(managedRoot, "raw", "x", "inbox", "123.md"), "utf8")).toContain('status: "inbox"');
  expect(await readFile(join(managedRoot, "wiki", "concepts", "agent-harness-eval-loops.md"), "utf8")).toContain("workflow discipline");
});

test("topic synthesis refresh all mode chunks topics under procedure control", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  await writeFile(
    join(managedRoot, "raw", "x", "ingested", "123.md"),
    rawBookmark().replace('status: "inbox"', 'status: "ingested"'),
    "utf8",
  );
  for (const slug of ["agent-harness-a", "agent-harness-b", "agent-harness-c"]) {
    await writeFile(
      join(managedRoot, "wiki", "concepts", `${slug}.md`),
      topicPage(slug),
      "utf8",
    );
  }

  const calls: string[] = [];
  const result = await wikiTopicSynthesisRefresh.execute(JSON.stringify({
    mode: "dry-run",
    all: true,
    chunkSize: 2,
    rationale: "fixture all mode",
    confidence: "high",
  }), {
    cwd: config.workspaceRoot,
    assertNotCancelled() {},
    ui: { status() {} },
    agent: {
      async run(prompt, descriptor) {
        calls.push(prompt);
        const paths = [...new Set([...prompt.matchAll(/"path": "([^"]+)"/g)].map((match) => match[1]))]
          .filter((path) => path.startsWith("wiki/concepts/agent-harness-"));
        const data = {
          summary: `Refresh ${paths.length} topic page(s)`,
          operations: [
            ...paths.map((path) => ({
              kind: "update_page",
              path,
              sourceIds: [],
              markdown: refreshedTopicPage(path),
            })),
            {
              kind: "append_log",
              sourceIds: [],
              markdown: [
                "## [2026-05-14] topic synthesis refresh | fixture all mode",
                "",
                ...paths.map((path) => `- Refreshed [[${path.replace(/^wiki\//, "").replace(/\.md$/, "")}|${path}]].`),
                "",
              ].join("\n"),
            },
          ],
          followUpSources: [],
          relationshipCandidates: [],
          spacedRepetitionCandidates: [],
        };
        if (!descriptor.validate(data)) throw new Error("fixture agent returned invalid typed data");
        return { data };
      },
    },
  });

  expect(typeof result).toBe("object");
  if (!result || typeof result !== "object" || !("data" in result)) throw new Error("missing procedure data");
  const data = result.data as {
    selectedTopicPaths: string[];
    contextBundlePaths: string[];
    chunkResults: Array<{ selectedTopicPaths: string[] }>;
    applied: { updatedPages: string[] };
    lint: { ok: boolean };
  };
  expect(data.selectedTopicPaths).toEqual([
    "wiki/concepts/agent-harness-a.md",
    "wiki/concepts/agent-harness-b.md",
    "wiki/concepts/agent-harness-c.md",
  ]);
  expect(data.contextBundlePaths.length).toBe(2);
  expect(data.chunkResults.map((chunk) => chunk.selectedTopicPaths.length)).toEqual([2, 1]);
  expect(data.applied.updatedPages).toEqual([
    "wiki/concepts/agent-harness-a.md",
    "wiki/concepts/agent-harness-b.md",
    "wiki/concepts/agent-harness-c.md",
  ]);
  expect(data.lint.ok).toBe(true);
  expect(calls.length).toBe(2);
});

test("sensemaking decision renders into source file and stores SQLite state", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  const selected = (await selectBatch({ managedRoot, limit: 1 }))[0];
  const result = await applySensemakingDecision({
    config,
    selected,
    decision: fixtureDecision(),
    dryRun: false,
    runId: "fixture-sensemaking",
  });

  expect(result.stored).toBe(true);
  const raw = await readFile(join(managedRoot, "raw", "x", "inbox", "123.md"), "utf8");
  expect(raw).toContain("## Ingest Decision");
  expect(raw).toContain("Why likely saved: John likely saved this because it names eval loops");

  const db = new Database(config.databasePath!);
  const row = db.query("SELECT status, why_saved, confidence FROM kb_ingest_decisions WHERE source_id = '123'").get() as Record<string, string>;
  expect(row.status).toBe("processed");
  expect(row.confidence).toBe("high");
  db.close();
});

test("interest map refresh groups matched interests from stored decisions", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  const selected = (await selectBatch({ managedRoot, limit: 1 }))[0];
  await applySensemakingDecision({
    config,
    selected,
    decision: fixtureDecision(),
    dryRun: false,
    runId: "fixture-map",
  });

  const mapPath = await refreshInterestMap(config, "fixture");
  const map = await readFile(mapPath, "utf8");
  expect(map).toContain("### Agent Harness Evaluation");
  expect(map).toContain("[123](../../raw/x/inbox/123.md)");
});

test("baseline build previews selected split sources without storing decisions", async () => {
  const { config, managedRoot } = await createFixtureWiki();
  const splitPath = join(managedRoot, "wiki", "meta", "corpus-split.json");
  await mkdir(join(managedRoot, "wiki", "meta"), { recursive: true });
  await writeFile(splitPath, JSON.stringify({
    baseline_100: ["123"],
    baseline_100_sources: [{ source_id: "123", raw_path: "raw/x/inbox/123.md" }],
  }), "utf8");

  const calls: string[] = [];
  const result = await wikiBaselineBuild.execute("--split wiki/meta/corpus-split.json --limit 1 --dry-run", {
    cwd: config.workspaceRoot,
    assertNotCancelled() {},
    ui: { status() {} },
    agent: {
      async run(prompt, descriptor) {
        calls.push(prompt);
        const data = fixtureDecision();
        if (!descriptor.validate(data)) throw new Error("fixture agent returned invalid typed data");
        return { data };
      },
    },
  });

  expect(typeof result).toBe("object");
  if (!result || typeof result !== "object" || !("data" in result)) throw new Error("missing procedure data");
  const data = result.data as { processedSourceIds: string[]; decisionsStored: number; runReportPath: string };
  expect(data.processedSourceIds).toEqual(["123"]);
  expect(data.decisionsStored).toBe(0);
  expect(await readFile(data.runReportPath, "utf8")).toContain("Sources processed: 1");
  expect(calls.length).toBe(1);
});


async function createFixtureWiki(): Promise<{ config: XBookmarksConfig; managedRoot: string }> {
  const root = await mkdtemp(join(tmpdir(), "xbookmarks-procedure-"));
  const managedRoot = join(root, "X Bookmarks");
  const config = {
    workspaceRoot: root,
    managedRoot,
    artifactRoot: join(root, ".nanoboss", "xbookmarks", "runs"),
    xBookmarksBinary: join(root, "x-bookmarks"),
    databasePath: join(root, "x_bookmarks.sqlite"),
  };

  await mkdir(join(managedRoot, "raw", "x", "inbox"), { recursive: true });
  await mkdir(join(managedRoot, "raw", "x", "ingested"), { recursive: true });
  await mkdir(join(managedRoot, "raw", "x", "ignored"), { recursive: true });
  await mkdir(join(managedRoot, "wiki", "concepts"), { recursive: true });
  await mkdir(join(managedRoot, "wiki", "maps"), { recursive: true });
  await mkdir(join(managedRoot, "wiki", "reviews"), { recursive: true });
  await mkdir(join(root, ".nanoboss", "xbookmarks"), { recursive: true });
  await writeFile(join(root, ".nanoboss", "xbookmarks", "config.json"), JSON.stringify(config, null, 2), "utf8");
  await writeFile(join(managedRoot, "wiki", "schema.md"), "# Schema\n", "utf8");
  await writeFile(join(managedRoot, "wiki", "index.md"), "# Index\n", "utf8");
  await writeFile(join(managedRoot, "wiki", "log.md"), "# Log\n", "utf8");
  await writeFile(join(managedRoot, "wiki", "home.md"), "# Home\n", "utf8");
  await writeFile(join(managedRoot, "wiki", "reviews", "this-week.md"), "# This Week\n", "utf8");
  await writeFile(join(managedRoot, "wiki", "maps", "agentic-software.md"), "# Agentic Software\n", "utf8");
  await writeFile(join(managedRoot, "raw", "x", "inbox", "123.md"), rawBookmark(), "utf8");

  return { config, managedRoot };
}

function topicPage(slug: string): string {
  const title = slug.split("-").map((part) => `${part[0].toUpperCase()}${part.slice(1)}`).join(" ");
  return [
    "---",
    "type: concept",
    "status: active",
    "created: 2026-05-14",
    "updated: 2026-05-14",
    "source_count: 1",
    "tags: []",
    "---",
    "",
    `# ${title}`,
    "",
    "## Summary",
    "",
    "Agent harnesses need durable eval loops. The evidence below is the current source trail for reviewing this topic and improving the synthesis over time.",
    "",
    "## Notes",
    "",
    "- Revisit this page during future ingest runs to turn repeated source patterns into sharper claims, caveats, and review questions.",
    "",
    "## Examples / Evidence",
    "",
    "![](https://x.com/alice/status/123) [[../../raw/x/ingested/123|26-05-10 @alice: durable eval loops for agent harnesses]] ^x-123",
    "",
  ].join("\n");
}

function refreshedTopicPage(path: string): string {
  const title = path.split("/").pop()?.replace(/\.md$/, "").split("-").map((part) => `${part[0].toUpperCase()}${part.slice(1)}`).join(" ") ?? "Topic";
  return [
    "---",
    "type: concept",
    "status: active",
    "created: 2026-05-14",
    "updated: 2026-05-14",
    "source_count: 1",
    "tags: []",
    "---",
    "",
    `# ${title}`,
    "",
    "## Summary",
    "",
    "Agent harness refreshes are controlled synthesis passes over existing evidence, keeping the source trail stable while improving the topic narrative.",
    "",
    "## Notes",
    "",
    "- The procedural loop owns chunking and progress; the agent only rewrites the selected page batch.",
    "",
    "## Examples / Evidence",
    "",
    "![](https://x.com/alice/status/123) [[../../raw/x/ingested/123|26-05-10 @alice: durable eval loops for agent harnesses]] ^x-123",
    "",
  ].join("\n");
}

function rawBookmark(): string {
  return [
    "---",
    'source_type: "x_bookmark"',
    'tweet_id: "123"',
    'canonical_url: "https://x.com/alice/status/123"',
    'author_username: "alice"',
    'created_at: "2026-05-10T12:00:00.000Z"',
    'bookmarked_at: "2026-05-11T12:00:00.000Z"',
    'status: "inbox"',
    "---",
    "",
    "# X Bookmark: @alice / 123",
    "",
    "## Post",
    "",
    "![](https://x.com/alice/status/123)",
    "",
    "Agent harnesses need durable eval loops.",
    "",
    "## Media",
    "",
    "- 3_123 (photo): `/tmp/agent-harness-chart.jpg` (image, downloaded)",
    "",
  ].join("\n");
}

function fixtureDecision(): KbSensemakingDecision {
  return {
    source_understanding: {
      source_id: "123",
      source_kind: "x_post",
      main_claims: ["Agent harnesses need durable eval loops."],
      examples: ["A short X post about agent harness design."],
      people_or_orgs: ["alice"],
      domains: ["agentic software", "evaluation"],
      uncertainties: [],
      requires_media_inspection: false,
    },
    why_saved: "John likely saved this because it names eval loops as the control layer around agentic coding.",
    matched_interests: [
      {
        interest: "agent harness evaluation",
        evidence: "The source argues for durable eval loops in agent harnesses.",
        confidence: "high",
      },
    ],
    non_obvious_connections: [
      {
        connection: "The bookmark treats evals as operational harness design, not only model benchmarking.",
        related_pages: ["wiki/concepts/agent-harness-eval-loops.md"],
      },
    ],
    durable_takeaways: ["Agent tools need repeatable review loops around their output."],
    candidate_pages: ["wiki/concepts/agent-harness-eval-loops.md"],
    actions: [
      {
        kind: "add_evidence_to_page",
        page: "wiki/concepts/agent-harness-eval-loops.md",
        title: "Agent Harness Eval Loops",
        evidence: "Agent harnesses need durable eval loops.",
      },
    ],
    confidence: "high",
  };
}

function fixturePlan(): WikiIngestPlan {
  return {
    summary: "Fixture plan",
    operations: [
      {
        kind: "create_page",
        path: "wiki/concepts/agent-harness-eval-loops.md",
        sourceIds: ["123"],
        markdown: [
          "---",
          "type: concept",
          "status: active",
          "created: 2026-05-14",
          "updated: 2026-05-14",
          'source_count: "1"',
          "tags: []",
          "---",
          "",
          "# Agent Harness Eval Loops",
          "",
          "## Summary",
          "",
          "Agent harnesses need durable eval loops.",
          "",
          "## Examples / Evidence",
          "",
          "![](https://x.com/alice/status/123) [[../../raw/x/ingested/123|26-05-10 @alice: durable eval loops for agent harnesses]] ^x-123",
          "",
        ].join("\n"),
      },
      {
        kind: "update_page",
        path: "wiki/index.md",
        sourceIds: ["123"],
        markdown: [
          "# Wiki Index",
          "",
          "## Concepts",
          "",
          "- [[concepts/agent-harness-eval-loops|Agent Harness Eval Loops]] - concept - source_count: 1 - updated 2026-05-14",
          "",
        ].join("\n"),
      },
      {
        kind: "update_map",
        path: "wiki/maps/agentic-software.md",
        sourceIds: ["123"],
        markdown: [
          "# Agentic Software",
          "",
          "- [[../concepts/agent-harness-eval-loops|Agent Harness Eval Loops]]",
          "",
        ].join("\n"),
      },
      {
        kind: "update_review",
        path: "wiki/reviews/2026-W20.md",
        sourceIds: ["123"],
        markdown: [
          "# 2026-W20",
          "",
          "## Review First",
          "",
          "- What makes agent harness evaluation durable?",
          "",
          "## Source Trail",
          "",
          "![](https://x.com/alice/status/123)",
          "",
          "[[../../raw/x/ingested/123|Captured bookmark]]",
          "",
          "Wiki entries:",
          "- [[../concepts/agent-harness-eval-loops#^x-123|Agent Harness Eval Loops]]",
          "",
        ].join("\n"),
      },
      {
        kind: "append_log",
        sourceIds: ["123"],
        markdown: [
          "## [2026-05-14] ingest | X bookmark 123",
          "",
          "- Raw source: ![](https://x.com/alice/status/123) [[../raw/x/ingested/123|26-05-10 @alice: durable eval loops for agent harnesses]]",
          "- Created: [[concepts/agent-harness-eval-loops|Agent Harness Eval Loops]]",
          "",
        ].join("\n"),
      },
    ],
    followUpSources: [],
    relationshipCandidates: ["Agent Harness Eval Loops"],
    spacedRepetitionCandidates: [],
  };
}

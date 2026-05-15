import { readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";

import { expectData, type Procedure } from "./lib/nanoboss.ts";
import { WikiIngestPlanType } from "./lib/descriptors.ts";
import { applyWikiPlan, defaultRunId, lintWiki, resolveXBookmarksConfig, selectBatch } from "./lib/index.ts";

export default {
  name: "xbookmarks/wiki-apply",
  description: "Apply a previously generated X bookmarks WikiIngestPlan",
  inputHint: "JSON: {\"planPath\":\".nanoboss/xbookmarks/runs/.../wiki-plan.json\",\"dryRun\":true}",
  async execute(prompt, ctx) {
    const request = parseApplyRequest(prompt);
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    const planPath = isAbsolute(request.planPath) ? request.planPath : resolve(config.workspaceRoot, request.planPath);
    const plan = expectData({ data: JSON.parse(await readFile(planPath, "utf8")) }, "Missing plan data");
    if (!WikiIngestPlanType.validate(plan)) {
      throw new Error(`Plan at ${planPath} does not match WikiIngestPlan.`);
    }
    const selected = await selectBatch({ managedRoot: config.managedRoot, limit: request.limit });
    const runId = defaultRunId();
    const applied = await applyWikiPlan({
      config,
      selected,
      plan,
      dryRun: request.dryRun,
      runId,
    });
    const lint = await lintWiki({
      config,
      selected,
      plan,
      runId,
      finalizationMode: request.dryRun ? "pre-move" : "post-move",
    });

    if (!lint.ok && !request.dryRun) {
      throw new Error(`xbookmarks/wiki-apply failed lint: ${lint.errorCount} error(s)`);
    }

    return {
      data: { planPath, applied, lint },
      display: [
        `planPath: ${planPath}`,
        `mode: ${request.dryRun ? "dry-run" : "apply"}`,
        `created pages: ${applied.createdPages.length ? applied.createdPages.join(", ") : "none"}`,
        `updated pages: ${applied.updatedPages.length ? applied.updatedPages.join(", ") : "none"}`,
        `ingested sources: ${applied.ingestedSourceIds.length ? applied.ingestedSourceIds.join(", ") : "none"}`,
        `ignored sources: ${applied.ignoredSourceIds.length ? applied.ignoredSourceIds.join(", ") : "none"}`,
        `lint: ${lint.ok ? "ok" : "failed"} (${lint.errorCount} error(s), ${lint.warningCount} warning(s))`,
      ].join("\n"),
      summary: `xbookmarks/wiki-apply: lint ${lint.ok ? "ok" : "failed"}`,
    };
  },
} satisfies Procedure;

function parseApplyRequest(prompt: string): { planPath: string; dryRun: boolean; limit: number } {
  const parsed = JSON.parse(prompt);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("wiki-apply input must be a JSON object.");
  }
  const object = parsed as Record<string, unknown>;
  const unknown = Object.keys(object).filter((key) => !["planPath", "dryRun", "limit"].includes(key));
  if (unknown.length > 0) throw new Error(`Unknown field(s): ${unknown.join(", ")}`);
  if (typeof object.planPath !== "string" || !object.planPath.trim()) {
    throw new Error("wiki-apply requires planPath.");
  }
  if (object.dryRun !== undefined && typeof object.dryRun !== "boolean") {
    throw new Error("dryRun must be a boolean.");
  }
  if (object.limit !== undefined && (!Number.isInteger(object.limit) || object.limit < 1 || object.limit > 100)) {
    throw new Error("limit must be an integer from 1 to 100.");
  }
  return {
    planPath: object.planPath,
    dryRun: object.dryRun ?? true,
    limit: object.limit ?? 25,
  };
}

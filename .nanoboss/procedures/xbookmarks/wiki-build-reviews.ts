import type { Procedure } from "./lib/nanoboss.ts";

import { buildReviewPages, resolveXBookmarksConfig } from "./lib/index.ts";

export default {
  name: "xbookmarks/wiki-build-reviews",
  description: "Build weekly X bookmark review source-trail pages from processed raw sources and wiki backlinks",
  inputHint: "Example: Build dry-run review pages for the latest 8 weeks.",
  async execute(prompt, ctx) {
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    const request = parseReviewBuildPrompt(prompt);
    const result = await buildReviewPages({
      config,
      dryRun: request.dryRun,
      weeks: request.weeks,
      limitWeeks: request.limitWeeks,
      overwriteExisting: request.overwriteExisting,
    });

    return {
      data: {
        config: {
          workspaceRoot: config.workspaceRoot,
          managedRoot: config.managedRoot,
          artifactRoot: config.artifactRoot,
        },
        result,
      },
      display: [
        `workspaceRoot: ${config.workspaceRoot}`,
        `managedRoot: ${config.managedRoot}`,
        `artifactRoot: ${config.artifactRoot}`,
        `mode: ${result.dryRun ? "dry-run" : "apply"}`,
        `weeks: ${result.reviewedWeeks.length ? result.reviewedWeeks.join(", ") : "none"}`,
        `created: ${result.createdPages.length ? result.createdPages.join(", ") : "none"}`,
        `updated: ${result.updatedPages.length ? result.updatedPages.join(", ") : "none"}`,
        `skipped: ${result.skippedPages.length ? result.skippedPages.join(", ") : "none"}`,
        `artifacts: ${result.artifactPaths.join(", ")}`,
      ].join("\n"),
      summary: `xbookmarks/wiki-build-reviews: ${result.reviewedWeeks.length} week(s), ${result.dryRun ? "dry-run" : "apply"}`,
    };
  },
} satisfies Procedure;

function parseReviewBuildPrompt(prompt: string): {
  dryRun: boolean;
  overwriteExisting: boolean;
  weeks: string[];
  limitWeeks?: number;
} {
  const lower = prompt.toLowerCase();
  const dryRun = /\b(dry run|dry-run|preview|simulate|show me)\b/.test(lower);
  const overwriteExisting = /\b(overwrite|update existing|replace existing)\b/.test(lower);
  const weeks = [...prompt.matchAll(/\b\d{4}-W\d{2}\b/g)].map((match) => match[0]);
  const latestMatch = /\b(?:latest|last|recent)\s+(\d+)\s+weeks?\b/i.exec(prompt);
  const firstNumber = /\b(\d+)\b/.exec(prompt);
  const limitWeeks = weeks.length > 0
    ? undefined
    : latestMatch
      ? Number(latestMatch[1])
      : /\b(all|every)\s+weeks?\b/i.test(prompt)
        ? undefined
        : firstNumber
          ? Number(firstNumber[1])
          : 8;
  return { dryRun, overwriteExisting, weeks, limitWeeks };
}

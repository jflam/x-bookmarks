import type { Procedure } from "./lib/nanoboss.ts";

import { defaultRunId, lintWiki, resolveXBookmarksConfig } from "./lib/index.ts";

export default {
  name: "xbookmarks/wiki-lint",
  description: "Check the X bookmarks wiki for broken links and citation issues",
  inputHint: "Example: Check the X bookmarks wiki for broken links and citation issues.",
  async execute(_prompt, ctx) {
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    const runId = defaultRunId();
    const lint = await lintWiki({ config, runId });

    return {
      data: {
        config: {
          workspaceRoot: config.workspaceRoot,
          managedRoot: config.managedRoot,
          artifactRoot: config.artifactRoot,
        },
        lint,
      },
      display: [
        `workspaceRoot: ${config.workspaceRoot}`,
        `managedRoot: ${config.managedRoot}`,
        `artifactRoot: ${config.artifactRoot}`,
        `lint: ${lint.ok ? "ok" : "failed"} (${lint.errorCount} error(s), ${lint.warningCount} warning(s))`,
        lint.artifactPaths.length ? `artifacts: ${lint.artifactPaths.join(", ")}` : "artifacts: none",
        "",
        ...lint.findings.slice(0, 25).map((finding) => (
          `${finding.severity.toUpperCase()} ${finding.ruleId} ${finding.file}${finding.line ? `:${finding.line}` : ""} - ${finding.message}`
        )),
        lint.findings.length > 25 ? `... ${lint.findings.length - 25} more finding(s)` : "",
      ].filter(Boolean).join("\n"),
      summary: `xbookmarks/wiki-lint: ${lint.errorCount} error(s), ${lint.warningCount} warning(s)`,
    };
  },
} satisfies Procedure;

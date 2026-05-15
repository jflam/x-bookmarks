import { expectData, type Procedure } from "./lib/nanoboss.ts";
import { KbSensemakingDecisionType } from "./lib/descriptors.ts";
import {
  applySensemakingDecision,
  buildSensemakingPrompt,
  buildSensemakingPromptContext,
  defaultRunId,
  normalizeSensemakingDecision,
  readSourceForSensemaking,
  refreshInterestMap,
  resolveXBookmarksConfig,
} from "./lib/index.ts";

export default {
  name: "xbookmarks/wiki-sensemake-source",
  description: "Preview or apply one interest-aware ingest decision for an X bookmark source",
  inputHint: "Example: --source raw/x/inbox/ID.md --dry-run",
  async execute(prompt, ctx) {
    const request = parseRequest(prompt);
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    const selected = await readSourceForSensemaking(config, request.source);
    const context = await buildSensemakingPromptContext(config, selected);
    const runId = defaultRunId();

    ctx.ui.status({ phase: "sensemaking", message: `Building ingest decision for ${selected.sourceId}...` });
    const decision = normalizeSensemakingDecision(expectData(
      await ctx.agent.run(
        buildSensemakingPrompt({
          sourceId: selected.sourceId,
          sourcePath: selected.rawPath,
          sourceMarkdown: context.sourceMarkdown,
          interestMapMarkdown: context.interestMapMarkdown,
          priorDecisionContext: context.priorDecisionContext,
          candidatePages: context.candidatePages,
        }),
        KbSensemakingDecisionType,
        { stream: false },
      ),
      "Agent returned no sensemaking decision",
    ), selected.sourceId);

    const applied = await applySensemakingDecision({
      config,
      selected,
      decision,
      dryRun: request.dryRun,
      runId,
    });
    const interestMapPath = request.dryRun ? undefined : await refreshInterestMap(config, `source-${selected.sourceId}`);

    return {
      data: { selected, decision, applied, interestMapPath },
      display: [
        `mode: ${request.dryRun ? "dry-run" : "apply"}`,
        `source: ${selected.sourceId}`,
        `preview: ${applied.previewPath}`,
        `rendered: ${applied.renderedPath ?? "not written"}`,
        `stored: ${applied.stored}`,
        `interest map: ${interestMapPath ?? "not written"}`,
      ].join("\n"),
      summary: `xbookmarks/wiki-sensemake-source: ${selected.sourceId} ${request.dryRun ? "previewed" : "applied"}`,
    };
  },
} satisfies Procedure;

function parseRequest(prompt: string): { source: string; dryRun: boolean } {
  const parts = prompt.trim().split(/\s+/).filter(Boolean);
  let source = "";
  let dryRun = true;
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part === "--source") {
      source = parts[++index] ?? "";
    } else if (part === "--dry-run") {
      dryRun = true;
    } else if (part === "--yes") {
      dryRun = false;
    }
  }
  if (!source) throw new Error("wiki-sensemake-source requires --source PATH.");
  return { source, dryRun };
}

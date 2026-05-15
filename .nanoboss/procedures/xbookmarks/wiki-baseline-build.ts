import { readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";

import { expectData, type Procedure } from "./lib/nanoboss.ts";
import { KbSensemakingDecisionType } from "./lib/descriptors.ts";
import {
  applySensemakingDecision,
  buildSensemakingPrompt,
  buildSensemakingPromptContext,
  defaultRunId,
  normalizeSensemakingDecision,
  readSelectedBookmarkAt,
  refreshInterestMap,
  resolveXBookmarksConfig,
  sourcePathForId,
  writeBaselineRunReport,
} from "./lib/index.ts";
import type { BaselineBuildResult, KbSensemakingDecision, SelectedBookmark } from "./lib/types.ts";

export default {
  name: "xbookmarks/wiki-baseline-build",
  description: "Run the phase-one interest-aware baseline over a deterministic corpus split",
  inputHint: "Example: --split wiki/meta/corpus-split.json --limit 100 --dry-run",
  async execute(prompt, ctx) {
    const request = parseRequest(prompt);
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    const splitPath = isAbsolute(request.split) ? request.split : resolve(config.managedRoot, request.split);
    const split = JSON.parse(await readFile(splitPath, "utf8")) as CorpusSplit;
    const ids = split.baseline_100.slice(0, request.limit);
    const runId = defaultRunId();

    const result: BaselineBuildResult = {
      dryRun: request.dryRun,
      splitPath,
      selectedSourceIds: ids,
      processedSourceIds: [],
      decisionsStored: 0,
      sourcesDeferredForMediaInspection: [],
      sourcesIgnored: [],
      averageConfidence: "n/a",
      runReportPath: "",
      artifactPaths: [],
    };
    const confidences: number[] = [];

    for (const [index, sourceId] of ids.entries()) {
      ctx.assertNotCancelled();
      ctx.ui.status({ phase: "sensemaking", message: `Processing baseline source ${index + 1}/${ids.length}: ${sourceId}` });
      const selected = await selectedFromSplit(config.managedRoot, split, sourceId);
      const context = await buildSensemakingPromptContext(config, selected);
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
        `Agent returned no sensemaking decision for ${sourceId}`,
      ), selected.sourceId);
      const applied = await applySensemakingDecision({ config, selected, decision, dryRun: request.dryRun, runId });
      result.processedSourceIds.push(sourceId);
      result.artifactPaths.push(applied.previewPath);
      if (applied.stored) result.decisionsStored += 1;
      if (isDeferred(decision)) result.sourcesDeferredForMediaInspection.push(sourceId);
      if (decision.actions.some((action) => action.kind === "ignore_low_signal")) result.sourcesIgnored.push(sourceId);
      confidences.push(confidenceScore(decision.confidence));

      if (!request.dryRun && ((index + 1) % request.batchSize === 0 || index === ids.length - 1)) {
        result.interestMapPath = await refreshInterestMap(config, `baseline-${index + 1}`);
      }
    }

    result.averageConfidence = averageConfidence(confidences);
    result.runReportPath = await writeBaselineRunReport({
      config,
      runId,
      result,
      modelConfiguration: "Nanoboss ctx.agent.run with KbSensemakingDecisionType; one source per prompt; interest map refreshed per batch in apply mode.",
    });
    result.artifactPaths.push(result.runReportPath);

    return {
      data: result,
      display: [
        `mode: ${request.dryRun ? "dry-run" : "apply"}`,
        `split: ${splitPath}`,
        `selected: ${result.selectedSourceIds.length}`,
        `processed: ${result.processedSourceIds.length}`,
        `decisions stored: ${result.decisionsStored}`,
        `deferred media: ${result.sourcesDeferredForMediaInspection.length}`,
        `ignored: ${result.sourcesIgnored.length}`,
        `average confidence: ${result.averageConfidence}`,
        `interest map: ${result.interestMapPath ?? "not written"}`,
        `run report: ${result.runReportPath}`,
      ].join("\n"),
      summary: `xbookmarks/wiki-baseline-build: ${result.processedSourceIds.length} source(s) ${request.dryRun ? "previewed" : "applied"}`,
    };
  },
} satisfies Procedure;

interface CorpusSplit {
  baseline_100: string[];
  baseline_100_sources?: Array<{ source_id: string; raw_path: string }>;
}

function parseRequest(prompt: string): { split: string; limit: number; dryRun: boolean; batchSize: number } {
  const parts = prompt.trim().split(/\s+/).filter(Boolean);
  let split = "";
  let limit = 100;
  let dryRun = true;
  let batchSize = 5;
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part === "--split") split = parts[++index] ?? "";
    else if (part === "--limit") limit = parsePositiveInt(parts[++index], "limit");
    else if (part === "--batch-size") batchSize = parsePositiveInt(parts[++index], "batch-size");
    else if (part === "--dry-run") dryRun = true;
    else if (part === "--yes") dryRun = false;
  }
  if (!split) throw new Error("wiki-baseline-build requires --split PATH.");
  return { split, limit, dryRun, batchSize };
}

async function selectedFromSplit(managedRoot: string, split: CorpusSplit, sourceId: string): Promise<SelectedBookmark> {
  const explicit = split.baseline_100_sources?.find((item) => item.source_id === sourceId)?.raw_path;
  return readSelectedBookmarkAt(explicit ? resolve(managedRoot, explicit) : await sourcePathForId(managedRoot, sourceId));
}

function isDeferred(decision: KbSensemakingDecision): boolean {
  return decision.source_understanding.requires_media_inspection || decision.actions.some((action) => action.kind === "defer_for_media_inspection");
}

function confidenceScore(confidence: "low" | "medium" | "high"): number {
  return confidence === "high" ? 3 : confidence === "medium" ? 2 : 1;
}

function averageConfidence(scores: number[]): string {
  if (scores.length === 0) return "n/a";
  const average = scores.reduce((sum, score) => sum + score, 0) / scores.length;
  if (average >= 2.5) return "high";
  if (average >= 1.5) return "medium";
  return "low";
}

function parsePositiveInt(value: string | undefined, label: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) throw new Error(`${label} must be a positive integer.`);
  return parsed;
}

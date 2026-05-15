import { readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { createHash } from "node:crypto";
import { Database } from "bun:sqlite";

import { expectData, type Procedure } from "./lib/nanoboss.ts";
import { KbSensemakingDecisionBatchType } from "./lib/descriptors.ts";
import {
  assertWithinTokenBudget,
  buildBatchSensemakingPrompt,
  buildSensemakingPromptContext,
  compactInterestMapSignal,
  countBatchRequestTokens,
  countExactTokens,
  defaultRunId,
  DEFAULT_TOKEN_BUDGET_CONFIG,
  normalizeSensemakingDecision,
  readSelectedBookmarkAt,
  resolveXBookmarksConfig,
  sourcePathForId,
} from "./lib/index.ts";
import { writeJson, writeTextAtomic } from "./lib/fs.ts";
import type { BatchTokenCounts, TokenBudgetConfig } from "./lib/token-budget.ts";
import type { KbSensemakingDecision, SelectedBookmark } from "./lib/types.ts";

export default {
  name: "xbookmarks/wiki-baseline-replay",
  description: "Run a non-destructive shadow replay against baseline sources and compare with stored phase-one decisions",
  inputHint: "Example: --split wiki/meta/corpus-split.json --limit 100 --map wiki/meta/interest-map.md --batch-size 5 --dry-run --write-comparison-report",
  async execute(prompt, ctx) {
    const request = parseRequest(prompt);
    if (!request.dryRun) throw new Error("wiki-baseline-replay is non-destructive and currently requires --dry-run.");
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    const splitPath = isAbsolute(request.split) ? request.split : resolve(config.managedRoot, request.split);
    const split = JSON.parse(await readFile(splitPath, "utf8")) as CorpusSplit;
    const ids = selectReplayIds(split.baseline_100, request.limit, config.databasePath);
    const mapPath = isAbsolute(request.map) ? request.map : resolve(config.managedRoot, request.map);
    const interestMapMarkdown = await readFile(mapPath, "utf8");
    const mapRevisionLabel = mapHash(interestMapMarkdown);
    const runId = defaultRunId();
    const runPath = `${config.artifactRoot}/${runId}`;
    const decisionsPath = `${runPath}/baseline-replay-decisions.jsonl`;
    const comparisonJsonPath = `${runPath}/baseline-replay-comparison.json`;
    const comparisonMdPath = `${runPath}/baseline-replay-comparison.md`;
    const records: ReplayRecord[] = [];
    const batches: ReplayBatchMeasurement[] = [];
    const statusDistributionBefore = statusDistribution(config.databasePath);
    const decisionCountBefore = decisionCount(config.databasePath);
    const startedAt = Date.now();

    for (const [batchIndex, batchIds] of chunks(ids, request.batchSize).entries()) {
      ctx.assertNotCancelled();
      ctx.ui.status({
        phase: "replay",
        message: `Shadow replay batch ${batchIndex + 1}/${Math.ceil(ids.length / request.batchSize)}: ${batchIds.join(", ")}`,
      });
      const selected = await Promise.all(batchIds.map((sourceId) => selectedFromSplit(config.managedRoot, split, sourceId)));
      const contexts = await Promise.all(selected.map(async (item) => ({
        selected: item,
        context: await buildSensemakingPromptContext(config, item, { interestMapMarkdown }),
      })));
      const prompt = buildBatchSensemakingPrompt({
        interestMapMarkdown,
        sources: contexts.map(({ selected, context }) => ({
          sourceId: selected.sourceId,
          sourcePath: selected.rawPath,
          sourceMarkdown: context.sourceMarkdown,
          priorDecisionContext: context.priorDecisionContext,
          candidatePages: context.candidatePages,
        })),
      });
      const tokenCounts = countBatchRequestTokens({
        staticPrefix: prompt.staticPrefix,
        batchPayload: prompt.batchPayload,
        batchSourceIds: batchIds,
        config: request.tokenBudgetConfig,
      });
      assertWithinTokenBudget(tokenCounts);
      const agentStartedAt = Date.now();
      const runResult = await ctx.agent.run(prompt.prompt, KbSensemakingDecisionBatchType, { stream: false });
      const elapsedMs = Date.now() - agentStartedAt;
      const output = expectData(runResult, `Agent returned no replay decision batch for ${batchIds.join(", ")}`);
      const decisionsBySource = validateBatchOutput(batchIds, output.decisions);

      batches.push({
        batchIndex: batchIndex + 1,
        sourceIds: batchIds,
        promptChars: prompt.prompt.length,
        staticPrefixChars: prompt.staticPrefix.length,
        batchPayloadChars: prompt.batchPayload.length,
        interestMapChars: interestMapMarkdown.length,
        tokenCounts,
        outputChars: JSON.stringify(output).length,
        outputTokens: countExactTokens(JSON.stringify(output), request.tokenBudgetConfig.tokenizerEncoding),
        elapsedMs,
        providerTokenUsage: providerTokenUsage(runResult),
        mapRefresh: "skipped: dry-run replay uses a fixed non-mutating map snapshot",
      });

      for (const { selected: item, context } of contexts) {
        const decision = normalizeSensemakingDecision(decisionsBySource.get(item.sourceId)!, item.sourceId);
        const original = await originalDecision(config.databasePath, item.sourceId);
        records.push(compareDecision(item, original, decision, context.priorDecisionContext?.items.map((prior) => prior.source_id) ?? []));
      }
    }

    await writeTextAtomic(decisionsPath, records.map((record) => JSON.stringify(record.replayDecision)).join("\n") + "\n");
    const summary = summarize(records);
    const measurement = buildMeasurement({
      selectedSourceIds: ids,
      batchSize: request.batchSize,
      batches,
      interestMapMarkdown,
      mapRevisionLabel,
      tokenBudgetConfig: request.tokenBudgetConfig,
      elapsedMs: Date.now() - startedAt,
    });
    const decisionCountAfter = decisionCount(config.databasePath);
    const statusDistributionAfter = statusDistribution(config.databasePath);
    await writeJson(comparisonJsonPath, {
      dryRun: true,
      splitPath,
      mapPath,
      mapRevisionLabel,
      selectedSourceIds: ids,
      summary,
      measurement,
      nonMutationCheck: {
        decisionCountBefore,
        decisionCountAfter,
        statusDistributionBefore,
        statusDistributionAfter,
        unchanged: decisionCountBefore === decisionCountAfter && JSON.stringify(statusDistributionBefore) === JSON.stringify(statusDistributionAfter),
      },
      records,
    });
    await writeTextAtomic(comparisonMdPath, renderComparisonReport(summary, records, measurement));

    return {
      data: {
        dryRun: true,
        selectedSourceIds: ids,
        decisionsPath,
        comparisonJsonPath,
        comparisonMdPath,
        mapRevisionLabel,
        summary,
        measurement,
      },
      display: [
        "mode: dry-run",
        `split: ${splitPath}`,
        `map: ${mapPath}`,
        `map revision: ${mapRevisionLabel}`,
        `selected: ${ids.length}`,
        `batch size: ${request.batchSize}`,
        `model calls: ${measurement.modelCalls}`,
        `decisions: ${decisionsPath}`,
        `comparison json: ${comparisonJsonPath}`,
        `comparison report: ${comparisonMdPath}`,
        `material differences: ${summary.materialDifferenceCount}`,
        `map token reduction vs single-source replay: ${measurement.mapTokenReductionFactor.toFixed(2)}x`,
        `recommend full replay: ${summary.recommendFullReplay ? "yes" : "no"}`,
      ].join("\n"),
      summary: `xbookmarks/wiki-baseline-replay: ${ids.length} source(s), ${summary.materialDifferenceCount} material difference(s)`,
    };
  },
} satisfies Procedure;

interface CorpusSplit {
  baseline_100: string[];
  baseline_100_sources?: Array<{ source_id: string; raw_path: string }>;
}

interface StoredDecision {
  source_id: string;
  status: string;
  why_saved: string;
  matched_interests_json: string;
  non_obvious_connections_json: string;
  actions_json: string;
  confidence: string;
  defer_reason?: string;
}

interface ReplayRecord {
  sourceId: string;
  priorDecisionSourceIds: string[];
  original: StoredDecision | undefined;
  replayDecision: KbSensemakingDecision;
  differences: {
    whySavedChanged: boolean;
    matchedInterestsAdded: string[];
    matchedInterestsRemoved: string[];
    statusChanged: boolean;
    confidenceChanged: boolean;
    actionKindChanged: boolean;
    deferralChanged: boolean;
  };
  materialDifference: boolean;
}

interface ReplayBatchMeasurement {
  batchIndex: number;
  sourceIds: string[];
  promptChars: number;
  staticPrefixChars: number;
  batchPayloadChars: number;
  interestMapChars: number;
  tokenCounts: BatchTokenCounts;
  outputChars: number;
  outputTokens: number;
  elapsedMs: number;
  providerTokenUsage?: Record<string, unknown>;
  mapRefresh: string;
}

interface ReplayMeasurement {
  tokenizer: {
    encoding: string;
    modelContextWindowTokens: number;
    effectiveContextBudgetTokens: number;
    maxContextRatio: number;
    safetyMarginRatio: number;
    outputReservePerSource: number;
  };
  mapRevisionLabel: string;
  batchSize: number;
  modelCalls: number;
  sourcesPerCall: number[];
  promptCharsTotal: number;
  interestMapCharsPerCall: number;
  interestMapCharsSentTotal: number;
  exactInterestMapTokens: number;
  exactInterestMapTokensSentTotal: number;
  singleSourceReplayModelCallsEstimate: number;
  singleSourceReplayMapTokensSentEstimate: number;
  mapTokenReductionFactor: number;
  exactStaticPrefixTokensTotal: number;
  exactStaticPrefixTokensPerCall: number[];
  estimatedRepeatedStaticPrefixTokenSavingsVsSingleSource: number;
  exactBatchPayloadTokensTotal: number;
  averageBatchPayloadTokens: number;
  maxBatchPayloadTokens: number;
  outputReserveTokensTotal: number;
  totalRequestTokens: number;
  interestMapCompaction: {
    beforeTokens: number;
    afterTokens: number;
    reductionTokens: number;
    reductionRatio: number;
  };
  actualOutputChars: number;
  exactOutputTokens: number;
  providerCacheReadTokens?: number;
  providerCacheWriteTokens?: number;
  wallClockMs: number;
  batches: ReplayBatchMeasurement[];
}

function parseRequest(prompt: string): { split: string; limit: number; dryRun: boolean; writeComparisonReport: boolean; map: string; batchSize: number; tokenBudgetConfig: TokenBudgetConfig } {
  const parts = prompt.trim().split(/\s+/).filter(Boolean);
  let split = "";
  let limit = 20;
  let dryRun = true;
  let writeComparisonReport = false;
  let map = "wiki/meta/interest-map.md";
  let batchSize = 5;
  const tokenBudgetConfig: TokenBudgetConfig = { ...DEFAULT_TOKEN_BUDGET_CONFIG };
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part === "--split") split = parts[++index] ?? "";
    else if (part === "--limit") limit = parsePositiveInt(parts[++index], "limit");
    else if (part === "--map") map = parts[++index] ?? "";
    else if (part === "--batch-size") batchSize = parsePositiveInt(parts[++index], "batch-size");
    else if (part === "--model-context-window-tokens") tokenBudgetConfig.modelContextWindowTokens = parsePositiveInt(parts[++index], "model-context-window-tokens");
    else if (part === "--tokenizer-encoding") tokenBudgetConfig.tokenizerEncoding = parts[++index] ?? tokenBudgetConfig.tokenizerEncoding;
    else if (part === "--max-context-ratio") tokenBudgetConfig.maxContextRatio = parsePositiveNumber(parts[++index], "max-context-ratio");
    else if (part === "--safety-margin-ratio") tokenBudgetConfig.safetyMarginRatio = parsePositiveNumber(parts[++index], "safety-margin-ratio");
    else if (part === "--output-reserve-per-source") tokenBudgetConfig.outputReservePerSource = parsePositiveInt(parts[++index], "output-reserve-per-source");
    else if (part === "--dry-run") dryRun = true;
    else if (part === "--write-comparison-report") writeComparisonReport = true;
  }
  if (!split) throw new Error("wiki-baseline-replay requires --split PATH.");
  if (!map) throw new Error("wiki-baseline-replay requires --map PATH.");
  if (!writeComparisonReport) throw new Error("wiki-baseline-replay requires --write-comparison-report.");
  return { split, limit, dryRun, writeComparisonReport, map, batchSize, tokenBudgetConfig };
}

function selectReplayIds(ids: string[], limit: number, databasePath: string | undefined): string[] {
  const capped = Math.min(Math.max(limit, 10), ids.length);
  if (!databasePath) return ids.slice(0, capped);
  const db = new Database(databasePath);
  const rows = db.query("SELECT source_id, status FROM kb_ingest_decisions").all() as Array<{ source_id: string; status: string }>;
  db.close();
  const statusById = new Map(rows.map((row) => [String(row.source_id), String(row.status)]));
  const selected: string[] = [];
  const addWhere = (status: string, targetCount: number) => {
    for (const id of ids) {
      if (selected.length >= capped || selected.filter((item) => statusById.get(item) === status).length >= targetCount) break;
      if (!selected.includes(id) && statusById.get(id) === status) selected.push(id);
    }
  };
  addWhere("processed", Math.min(4, capped));
  addWhere("deferred_media_inspection", Math.min(3, capped - selected.length));
  addWhere("ignored_low_signal", Math.min(1, capped - selected.length));
  for (const id of ids) {
    if (selected.length >= capped) break;
    if (!selected.includes(id)) selected.push(id);
  }
  return selected;
}

async function selectedFromSplit(managedRoot: string, split: CorpusSplit, sourceId: string): Promise<SelectedBookmark> {
  const explicit = split.baseline_100_sources?.find((item) => item.source_id === sourceId)?.raw_path;
  return readSelectedBookmarkAt(explicit ? resolve(managedRoot, explicit) : await sourcePathForId(managedRoot, sourceId));
}

async function originalDecision(databasePath: string | undefined, sourceId: string): Promise<StoredDecision | undefined> {
  if (!databasePath) return undefined;
  const db = new Database(databasePath);
  const row = db.query(`
    SELECT source_id, status, why_saved, matched_interests_json, non_obvious_connections_json, actions_json, confidence, defer_reason
    FROM kb_ingest_decisions
    WHERE source_id = ?
  `).get(sourceId) as StoredDecision | undefined;
  db.close();
  return row;
}

function compareDecision(selected: SelectedBookmark, original: StoredDecision | undefined, replay: KbSensemakingDecision, priorDecisionSourceIds: string[]): ReplayRecord {
  const originalInterests = parseJsonArray<{ interest: string }>(original?.matched_interests_json).map((item) => normalizeInterest(item.interest));
  const replayInterests = replay.matched_interests.map((item) => normalizeInterest(item.interest));
  const originalActions = parseJsonArray<{ kind: string }>(original?.actions_json).map((item) => item.kind).sort();
  const replayActions = replay.actions.map((item) => item.kind).sort();
  const originalStatus = original?.status;
  const replayStatus = decisionStatus(replay);
  const differences = {
    whySavedChanged: normalizedText(original?.why_saved ?? "") !== normalizedText(replay.why_saved),
    matchedInterestsAdded: replayInterests.filter((item) => !originalInterests.includes(item)),
    matchedInterestsRemoved: originalInterests.filter((item) => !replayInterests.includes(item)),
    statusChanged: Boolean(originalStatus && originalStatus !== replayStatus),
    confidenceChanged: Boolean(original?.confidence && original.confidence !== replay.confidence),
    actionKindChanged: JSON.stringify(originalActions) !== JSON.stringify(replayActions),
    deferralChanged: Boolean((original?.defer_reason ?? "") !== (replay.defer_reason ?? "")),
  };
  const materialDifference = differences.statusChanged
    || differences.confidenceChanged
    || differences.actionKindChanged
    || differences.matchedInterestsAdded.length > 0
    || differences.matchedInterestsRemoved.length > 0;
  return {
    sourceId: selected.sourceId,
    priorDecisionSourceIds,
    original,
    replayDecision: replay,
    differences,
    materialDifference,
  };
}

function summarize(records: ReplayRecord[]) {
  const materialDifferenceCount = records.filter((record) => record.materialDifference).length;
  return {
    sourceCount: records.length,
    materialDifferenceCount,
    matchedInterestChangedCount: records.filter((record) => record.differences.matchedInterestsAdded.length || record.differences.matchedInterestsRemoved.length).length,
    confidenceChangedCount: records.filter((record) => record.differences.confidenceChanged).length,
    deferralChangedCount: records.filter((record) => record.differences.deferralChanged || record.differences.statusChanged).length,
    actionChangedCount: records.filter((record) => record.differences.actionKindChanged).length,
    recommendFullReplay: records.length > 0 && materialDifferenceCount / records.length >= 0.25,
  };
}

function buildMeasurement(params: {
  selectedSourceIds: string[];
  batchSize: number;
  batches: ReplayBatchMeasurement[];
  interestMapMarkdown: string;
  mapRevisionLabel: string;
  tokenBudgetConfig: TokenBudgetConfig;
  elapsedMs: number;
}): ReplayMeasurement {
  const exactInterestMapTokens = countExactTokens(params.interestMapMarkdown, params.tokenBudgetConfig.tokenizerEncoding);
  const compactedMapMarkdown = compactRenderedInterestMapMarkdown(params.interestMapMarkdown);
  const compactedMapTokens = countExactTokens(compactedMapMarkdown, params.tokenBudgetConfig.tokenizerEncoding);
  const exactInterestMapTokensSentTotal = exactInterestMapTokens * params.batches.length;
  const singleSourceReplayMapTokensSentEstimate = exactInterestMapTokens * params.selectedSourceIds.length;
  const staticPrefixTokens = params.batches.map((batch) => batch.tokenCounts.staticPrefixTokens);
  const batchPayloadTokens = params.batches.map((batch) => batch.tokenCounts.batchPayloadTokens);
  const cacheRead = sumProviderUsage(params.batches, "cacheReadTokens");
  const cacheWrite = sumProviderUsage(params.batches, "cacheWriteTokens");
  return {
    tokenizer: {
      encoding: params.tokenBudgetConfig.tokenizerEncoding,
      modelContextWindowTokens: params.tokenBudgetConfig.modelContextWindowTokens,
      effectiveContextBudgetTokens: params.batches[0]?.tokenCounts.effectiveContextBudgetTokens ?? 0,
      maxContextRatio: params.tokenBudgetConfig.maxContextRatio,
      safetyMarginRatio: params.tokenBudgetConfig.safetyMarginRatio,
      outputReservePerSource: params.tokenBudgetConfig.outputReservePerSource,
    },
    mapRevisionLabel: params.mapRevisionLabel,
    batchSize: params.batchSize,
    modelCalls: params.batches.length,
    sourcesPerCall: params.batches.map((batch) => batch.sourceIds.length),
    promptCharsTotal: sum(params.batches.map((batch) => batch.promptChars)),
    interestMapCharsPerCall: params.interestMapMarkdown.length,
    interestMapCharsSentTotal: params.interestMapMarkdown.length * params.batches.length,
    exactInterestMapTokens,
    exactInterestMapTokensSentTotal,
    singleSourceReplayModelCallsEstimate: params.selectedSourceIds.length,
    singleSourceReplayMapTokensSentEstimate,
    mapTokenReductionFactor: exactInterestMapTokensSentTotal === 0 ? 0 : singleSourceReplayMapTokensSentEstimate / exactInterestMapTokensSentTotal,
    exactStaticPrefixTokensTotal: sum(staticPrefixTokens),
    exactStaticPrefixTokensPerCall: staticPrefixTokens,
    estimatedRepeatedStaticPrefixTokenSavingsVsSingleSource: Math.max(0, (exactInterestMapTokens * params.selectedSourceIds.length) - (exactInterestMapTokens * params.batches.length)),
    exactBatchPayloadTokensTotal: sum(batchPayloadTokens),
    averageBatchPayloadTokens: batchPayloadTokens.length ? Math.round(sum(batchPayloadTokens) / batchPayloadTokens.length) : 0,
    maxBatchPayloadTokens: Math.max(0, ...batchPayloadTokens),
    outputReserveTokensTotal: sum(params.batches.map((batch) => batch.tokenCounts.outputReserveTokens)),
    totalRequestTokens: sum(params.batches.map((batch) => batch.tokenCounts.totalRequestTokens)),
    interestMapCompaction: {
      beforeTokens: exactInterestMapTokens,
      afterTokens: compactedMapTokens,
      reductionTokens: Math.max(0, exactInterestMapTokens - compactedMapTokens),
      reductionRatio: exactInterestMapTokens === 0 ? 0 : (exactInterestMapTokens - compactedMapTokens) / exactInterestMapTokens,
    },
    actualOutputChars: sum(params.batches.map((batch) => batch.outputChars)),
    exactOutputTokens: sum(params.batches.map((batch) => batch.outputTokens)),
    providerCacheReadTokens: cacheRead === undefined ? undefined : cacheRead,
    providerCacheWriteTokens: cacheWrite === undefined ? undefined : cacheWrite,
    wallClockMs: params.elapsedMs,
    batches: params.batches,
  };
}

function renderComparisonReport(summary: ReturnType<typeof summarize>, records: ReplayRecord[], measurement: ReplayMeasurement): string {
  return [
    "# Baseline Replay Comparison",
    "",
    "Mode: dry-run",
    `Map revision: ${measurement.mapRevisionLabel}`,
    `Sources replayed: ${summary.sourceCount}`,
    `Model calls: ${measurement.modelCalls}`,
    `Batch size: ${measurement.batchSize}`,
    `Material differences: ${summary.materialDifferenceCount}`,
    `Matched-interest changes: ${summary.matchedInterestChangedCount}`,
    `Confidence changes: ${summary.confidenceChangedCount}`,
    `Deferral/status changes: ${summary.deferralChangedCount}`,
    `Action changes: ${summary.actionChangedCount}`,
    `Full 100-source replay recommended: ${summary.recommendFullReplay ? "yes" : "no"}`,
    "",
    "## Measurement",
    "",
    `Tokenizer: ${measurement.tokenizer.encoding}`,
    `Prompt chars total: ${measurement.promptCharsTotal}`,
    `Interest-map chars sent total: ${measurement.interestMapCharsSentTotal}`,
    `Exact static-prefix tokens total: ${measurement.exactStaticPrefixTokensTotal}`,
    `Estimated repeated-prefix token savings vs single-source replay: ${measurement.estimatedRepeatedStaticPrefixTokenSavingsVsSingleSource}`,
    `Exact batch-payload tokens total: ${measurement.exactBatchPayloadTokensTotal}`,
    `Average batch-payload tokens: ${measurement.averageBatchPayloadTokens}`,
    `Max batch-payload tokens: ${measurement.maxBatchPayloadTokens}`,
    `Output reserve tokens total: ${measurement.outputReserveTokensTotal}`,
    `Total request tokens: ${measurement.totalRequestTokens}`,
    `Exact interest-map tokens per call: ${measurement.exactInterestMapTokens}`,
    `Interest-map tokens after deterministic signal compaction: ${measurement.interestMapCompaction.afterTokens}`,
    `Interest-map compaction reduction: ${measurement.interestMapCompaction.reductionTokens} tokens (${(measurement.interestMapCompaction.reductionRatio * 100).toFixed(1)}%)`,
    `Single-source replay map-token estimate: ${measurement.singleSourceReplayMapTokensSentEstimate}`,
    `Batch replay map tokens sent: ${measurement.exactInterestMapTokensSentTotal}`,
    `Measured map-token reduction: ${measurement.mapTokenReductionFactor.toFixed(2)}x`,
    `Exact output tokens: ${measurement.exactOutputTokens}`,
    `Provider cache read tokens: ${measurement.providerCacheReadTokens ?? "not reported"}`,
    `Provider cache write tokens: ${measurement.providerCacheWriteTokens ?? "not reported"}`,
    `Wall-clock duration ms: ${measurement.wallClockMs}`,
    "Dry-run map refresh: skipped; apply-mode ingestion refreshes after each applied batch.",
    "",
    "## Source Comparisons",
    "",
    ...records.map((record) => [
      `### ${record.sourceId}`,
      "",
      `- Material difference: ${record.materialDifference ? "yes" : "no"}`,
      `- Prior decisions used: ${record.priorDecisionSourceIds.length ? record.priorDecisionSourceIds.join(", ") : "none"}`,
      `- Added interests: ${record.differences.matchedInterestsAdded.join(", ") || "none"}`,
      `- Removed interests: ${record.differences.matchedInterestsRemoved.join(", ") || "none"}`,
      `- Confidence changed: ${record.differences.confidenceChanged ? "yes" : "no"}`,
      `- Status changed: ${record.differences.statusChanged ? "yes" : "no"}`,
      `- Action kind changed: ${record.differences.actionKindChanged ? "yes" : "no"}`,
      "",
    ].join("\n")),
  ].join("\n");
}

function validateBatchOutput(sourceIds: string[], decisions: Array<{ source_id: string; decision: KbSensemakingDecision }>): Map<string, KbSensemakingDecision> {
  const expected = new Set(sourceIds);
  const bySource = new Map<string, KbSensemakingDecision>();
  for (const item of decisions) {
    if (!expected.has(item.source_id)) throw new Error(`Replay batch returned unexpected source_id: ${item.source_id}`);
    if (bySource.has(item.source_id)) throw new Error(`Replay batch returned duplicate decision for source_id: ${item.source_id}`);
    bySource.set(item.source_id, item.decision);
  }
  const missing = sourceIds.filter((sourceId) => !bySource.has(sourceId));
  if (missing.length > 0 || bySource.size !== sourceIds.length) {
    throw new Error(`Replay batch must return exactly one decision per selected source. Missing: ${missing.join(", ") || "none"}.`);
  }
  return bySource;
}

function compactRenderedInterestMapMarkdown(markdown: string): string {
  return markdown.replace(/^-\s+Signals:\s+(.+)$/gm, (_line, value: string) => {
    if (value.trim().toLowerCase() === "none") return "- Signals: none";
    const compacted = value.split(";").map((item) => compactInterestMapSignal(item)).filter(Boolean).join("; ");
    return `- Signals: ${compacted || "none"}`;
  });
}

function chunks<T>(items: T[], size: number): T[][] {
  const output: T[][] = [];
  for (let index = 0; index < items.length; index += size) output.push(items.slice(index, index + size));
  return output;
}

function mapHash(markdown: string): string {
  return `sha256:${createHash("sha256").update(markdown).digest("hex").slice(0, 16)}`;
}

function providerTokenUsage(result: unknown): Record<string, unknown> | undefined {
  if (!result || typeof result !== "object" || !("tokenUsage" in result)) return undefined;
  const usage = (result as { tokenUsage?: unknown }).tokenUsage;
  return usage && typeof usage === "object" && !Array.isArray(usage) ? usage as Record<string, unknown> : undefined;
}

function sumProviderUsage(batches: ReplayBatchMeasurement[], field: string): number | undefined {
  let sawValue = false;
  let total = 0;
  for (const batch of batches) {
    const value = batch.providerTokenUsage?.[field];
    if (typeof value !== "number") continue;
    sawValue = true;
    total += value;
  }
  return sawValue ? total : undefined;
}

function sum(values: number[]): number {
  return values.reduce((total, value) => total + value, 0);
}

function decisionCount(databasePath: string | undefined): number | undefined {
  if (!databasePath) return undefined;
  const db = new Database(databasePath);
  const row = db.query("SELECT count(*) AS count FROM kb_ingest_decisions").get() as { count: number } | undefined;
  db.close();
  return Number(row?.count ?? 0);
}

function statusDistribution(databasePath: string | undefined): Record<string, number> | undefined {
  if (!databasePath) return undefined;
  const db = new Database(databasePath);
  const rows = db.query("SELECT status, count(*) AS count FROM kb_ingest_decisions GROUP BY status ORDER BY status").all() as Array<{ status: string; count: number }>;
  db.close();
  return Object.fromEntries(rows.map((row) => [String(row.status), Number(row.count)]));
}

function parseJsonArray<T>(value: string | undefined): T[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed as T[] : [];
  } catch {
    return [];
  }
}

function normalizeInterest(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function normalizedText(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function decisionStatus(decision: KbSensemakingDecision): string {
  if (decision.source_understanding.requires_media_inspection || decision.actions.some((action) => action.kind === "defer_for_media_inspection")) return "deferred_media_inspection";
  if (decision.actions.some((action) => action.kind === "ignore_low_signal")) return "ignored_low_signal";
  return "processed";
}

function parsePositiveInt(value: string | undefined, label: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) throw new Error(`${label} must be a positive integer.`);
  return parsed;
}

function parsePositiveNumber(value: string | undefined, label: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`${label} must be a positive number.`);
  return parsed;
}

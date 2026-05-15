import { expectData, type Procedure } from "./lib/nanoboss.ts";
import { TopicSynthesisIntentType, WikiIngestPlanType } from "./lib/descriptors.ts";
import {
  applyWikiPlan,
  buildRepairPrompt,
  buildTopicSynthesisContext,
  buildTopicSynthesisIntentPrompt,
  buildTopicSynthesisPrompt,
  lintWiki,
  parseProgrammaticTopicSynthesisOptions,
  resolveXBookmarksConfig,
  selectTopicPages,
  validateAndDefaultTopicSynthesisIntent,
} from "./lib/index.ts";
import { writeJson } from "./lib/fs.ts";
import type { ApplyResult, LintResult, TopicSelection, TopicSynthesisChunkResult, TopicSynthesisRefreshData, XBookmarksConfig } from "./lib/types.ts";

export default {
  name: "xbookmarks/wiki-topic-synthesis-refresh",
  description: "Refresh existing X bookmark wiki topic pages using their cited sources and media",
  inputHint: "Example: Dry run synthesis refresh for wiki/concepts/autonomous-driving-perception.md.",
  async execute(prompt, ctx) {
    const request = prompt.trim() || "Dry run synthesis refresh for the next 3 topics that need deeper analysis.";

    ctx.ui.status({ phase: "intent", message: "Extracting topic synthesis intent..." });
    const options = request.startsWith("{")
      ? parseProgrammaticTopicSynthesisOptions(request)
      : validateAndDefaultTopicSynthesisIntent(expectData(
        await ctx.agent.run(
          buildTopicSynthesisIntentPrompt(request),
          TopicSynthesisIntentType,
          { stream: false },
        ),
        "Agent returned no topic synthesis intent",
      ));

    ctx.assertNotCancelled();
    ctx.ui.status({ phase: "config", message: "Resolving X bookmarks wiki roots..." });
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });

    ctx.assertNotCancelled();
    ctx.ui.status({
      phase: "select",
      message: options.all
        ? "Selecting all durable topic page(s)..."
        : `Selecting up to ${options.limit} topic page(s)...`,
    });
    const selected = await selectTopicPages({
      config,
      paths: options.paths,
      limit: options.limit,
    });

    if (selected.length === 0) {
      return {
        data: {
          intent: options,
          config: configData(config),
          selectedTopicPaths: [],
          contextBundlePath: "",
          contextBundlePaths: [],
          applied: emptyApplyResult(options.dryRun),
          lint: emptyLintResult(),
          chunkResults: [],
          stoppedEarly: false,
          followUpSources: [],
          relationshipCandidates: [],
          spacedRepetitionCandidates: [],
        } satisfies TopicSynthesisRefreshData,
        display: [
          `workspaceRoot: ${config.workspaceRoot}`,
          `managedRoot: ${config.managedRoot}`,
          `artifactRoot: ${config.artifactRoot}`,
          "No topic pages were selected for synthesis refresh.",
        ].join("\n"),
        summary: "xbookmarks/wiki-topic-synthesis-refresh: no topics selected",
      };
    }

    const chunks = chunkSelections(selected, options.all ? options.chunkSize : selected.length);
    const aggregateApplied = emptyApplyResult(options.dryRun);
    const aggregateLint = emptyLintResult();
    const chunkResults: TopicSynthesisChunkResult[] = [];
    const contextBundlePaths: string[] = [];
    const followUpSources: string[] = [];
    const relationshipCandidates: string[] = [];
    const spacedRepetitionCandidates: string[] = [];
    let stoppedEarly = false;

    for (let index = 0; index < chunks.length; index += 1) {
      const chunk = chunks[index];
      const chunkRunId = `${options.batchId}-chunk-${String(index + 1).padStart(3, "0")}`;

      ctx.assertNotCancelled();
      ctx.ui.status({
        phase: "context",
        message: `Building topic synthesis context bundle ${index + 1}/${chunks.length}...`,
      });
      const context = await buildTopicSynthesisContext({
        config,
        selected: chunk,
        batchId: options.batchId,
        runId: chunkRunId,
      });
      contextBundlePaths.push(context.rootPath);

      ctx.assertNotCancelled();
      ctx.ui.status({
        phase: "synthesis",
        message: `Asking agent for topic page rewrites ${index + 1}/${chunks.length}...`,
      });
      let plan = expectData(
        await ctx.agent.run(
          buildTopicSynthesisPrompt({ selected: chunk, context, intent: options }),
          WikiIngestPlanType,
          { stream: false },
        ),
        "Agent returned no topic synthesis plan",
      );

      ctx.assertNotCancelled();
      ctx.ui.status({
        phase: "apply",
        message: options.dryRun
          ? `Previewing topic updates ${index + 1}/${chunks.length}...`
          : `Applying topic updates ${index + 1}/${chunks.length}...`,
      });
      let applied = await applyWikiPlan({
        config,
        selected: [],
        plan,
        dryRun: options.dryRun,
        runId: context.runId,
      });

      ctx.ui.status({ phase: "lint", message: `Linting refreshed topic pages ${index + 1}/${chunks.length}...` });
      let lint = await lintWiki({
        config,
        selected: [],
        plan,
        runId: context.runId,
      });

      for (let attempt = 0; !lint.ok && !options.dryRun && options.repair && attempt < options.maxRepairAttempts; attempt += 1) {
        ctx.assertNotCancelled();
        ctx.ui.status({ phase: "repair", message: `Repairing lint findings for chunk ${index + 1}/${chunks.length} (${attempt + 1}/${options.maxRepairAttempts})...` });
        plan = expectData(
          await ctx.agent.run(
            buildRepairPrompt({ plan, lint }),
            WikiIngestPlanType,
            { stream: false },
          ),
          "Agent returned no repaired topic synthesis plan",
        );
        applied = await applyWikiPlan({
          config,
          selected: [],
          plan,
          dryRun: false,
          runId: context.runId,
        });
        lint = await lintWiki({
          config,
          selected: [],
          plan,
          runId: context.runId,
        });
      }

      mergeApplyResult(aggregateApplied, applied);
      mergeLintResult(aggregateLint, lint);
      addUniqueMany(followUpSources, plan.followUpSources);
      addUniqueMany(relationshipCandidates, plan.relationshipCandidates);
      addUniqueMany(spacedRepetitionCandidates, plan.spacedRepetitionCandidates);
      chunkResults.push({
        index: index + 1,
        total: chunks.length,
        selectedTopicPaths: chunk.map((item) => item.path),
        contextBundlePath: context.rootPath,
        applied,
        lint,
      });
      await writeJson(`${context.runPath}/topic-synthesis-progress.json`, {
        chunk: index + 1,
        totalChunks: chunks.length,
        selectedTopicPaths: selected.map((item) => item.path),
        completedChunkResults: chunkResults,
        lintOkSoFar: aggregateLint.ok,
      });

      if (!lint.ok) {
        stoppedEarly = index + 1 < chunks.length;
        if (!options.dryRun) {
          throw new Error(`xbookmarks/wiki-topic-synthesis-refresh failed lint in chunk ${index + 1}/${chunks.length}: ${lint.errorCount} error(s)`);
        }
        break;
      }
    }

    const data: TopicSynthesisRefreshData = {
      intent: options,
      config: configData(config),
      selectedTopicPaths: selected.map((item) => item.path),
      contextBundlePath: contextBundlePaths[0] ?? "",
      contextBundlePaths,
      applied: aggregateApplied,
      lint: aggregateLint,
      chunkResults,
      stoppedEarly,
      followUpSources,
      relationshipCandidates,
      spacedRepetitionCandidates,
    };

    return {
      data,
      display: [
        `workspaceRoot: ${config.workspaceRoot}`,
        `managedRoot: ${config.managedRoot}`,
        `artifactRoot: ${config.artifactRoot}`,
        `mode: ${options.dryRun ? "dry-run" : "apply"}`,
        `all mode: ${options.all ? "yes" : "no"}`,
        `chunk size: ${options.all ? options.chunkSize : selected.length}`,
        `chunks: ${chunkResults.length}/${chunks.length}`,
        `selected topics: ${selected.length} (${selected.map((item) => item.path).join(", ")})`,
        `contexts: ${contextBundlePaths.length ? contextBundlePaths.join(", ") : "none"}`,
        `updated pages: ${aggregateApplied.updatedPages.length ? aggregateApplied.updatedPages.join(", ") : "none"}`,
        `updated maps: ${aggregateApplied.updatedMaps.length ? aggregateApplied.updatedMaps.join(", ") : "none"}`,
        `updated reviews: ${aggregateApplied.updatedReviewPages.length ? aggregateApplied.updatedReviewPages.join(", ") : "none"}`,
        `lint: ${aggregateLint.ok ? "ok" : "failed"} (${aggregateLint.errorCount} error(s), ${aggregateLint.warningCount} warning(s))`,
        `stopped early: ${stoppedEarly ? "yes" : "no"}`,
        `follow-up sources: ${followUpSources.length ? followUpSources.join("; ") : "none"}`,
        `relationship candidates: ${relationshipCandidates.length ? relationshipCandidates.join("; ") : "none"}`,
        `spaced repetition candidates: ${spacedRepetitionCandidates.length ? spacedRepetitionCandidates.join("; ") : "none"}`,
      ].join("\n"),
      summary: `xbookmarks/wiki-topic-synthesis-refresh: ${selected.length} topic(s), ${chunkResults.length}/${chunks.length} chunk(s), lint ${aggregateLint.ok ? "ok" : "failed"}`,
    };
  },
} satisfies Procedure;

function configData(config: XBookmarksConfig) {
  return {
    workspaceRoot: config.workspaceRoot,
    managedRoot: config.managedRoot,
    artifactRoot: config.artifactRoot,
  };
}

function emptyApplyResult(dryRun: boolean): ApplyResult {
  return {
    dryRun,
    createdPages: [],
    updatedPages: [],
    updatedMaps: [],
    updatedReviewPages: [],
    ingestedSourceIds: [],
    ignoredSourceIds: [],
    unresolvedSourceIds: [],
    artifactPaths: [],
  };
}

function emptyLintResult(): LintResult {
  return {
    ok: true,
    errorCount: 0,
    warningCount: 0,
    findings: [],
    artifactPaths: [],
  };
}

function chunkSelections(items: TopicSelection[], chunkSize: number): TopicSelection[][] {
  const chunks: TopicSelection[][] = [];
  const size = Math.max(1, chunkSize);
  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }
  return chunks;
}

function mergeApplyResult(target: ApplyResult, source: ApplyResult): void {
  addUniqueMany(target.createdPages, source.createdPages);
  addUniqueMany(target.updatedPages, source.updatedPages);
  addUniqueMany(target.updatedMaps, source.updatedMaps);
  addUniqueMany(target.updatedReviewPages, source.updatedReviewPages);
  addUniqueMany(target.ingestedSourceIds, source.ingestedSourceIds);
  addUniqueMany(target.ignoredSourceIds, source.ignoredSourceIds);
  addUniqueMany(target.unresolvedSourceIds, source.unresolvedSourceIds);
  addUniqueMany(target.artifactPaths, source.artifactPaths);
}

function mergeLintResult(target: LintResult, source: LintResult): void {
  target.errorCount += source.errorCount;
  target.warningCount += source.warningCount;
  target.ok = target.errorCount === 0;
  target.findings.push(...source.findings);
  addUniqueMany(target.artifactPaths, source.artifactPaths);
}

function addUniqueMany(target: string[], source: string[]): void {
  for (const item of source) {
    if (!target.includes(item)) target.push(item);
  }
}

import { expectData, type Procedure } from "./lib/nanoboss.ts";
import { RefreshIntentType, WikiIngestPlanType } from "./lib/descriptors.ts";
import {
  applyWikiPlan,
  buildContextBundle,
  buildRefreshIntentPrompt,
  buildRepairPrompt,
  buildWikiIngestPrompt,
  parseProgrammaticRefreshOptions,
  resolveXBookmarksConfig,
  selectBatch,
  syncAndExportRawX,
  validateAndDefaultRefreshIntent,
  lintWiki,
} from "./lib/index.ts";
import type { XBookmarksRefreshData } from "./lib/types.ts";

export default {
  name: "xbookmarks/wiki-refresh",
  description: "Compile X bookmark raw sources into the Obsidian wiki",
  inputHint: "Example: Dry run the next 5 exported bookmarks. Do not sync.",
  async execute(prompt, ctx) {
    const request = prompt.trim() || "Dry run the next 5 exported bookmarks. Do not sync.";

    ctx.ui.status({ phase: "intent", message: "Extracting refresh intent..." });
    const options = request.startsWith("{")
      ? parseProgrammaticRefreshOptions(request)
      : validateAndDefaultRefreshIntent(expectData(
        await ctx.agent.run(
          buildRefreshIntentPrompt(request),
          RefreshIntentType,
          { stream: false },
        ),
        "Agent returned no refresh intent",
      ));

    ctx.assertNotCancelled();
    ctx.ui.status({ phase: "config", message: "Resolving X bookmarks wiki roots..." });
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });

    if (!options.noSync) {
      ctx.ui.status({ phase: "sync", message: "Syncing and exporting X bookmarks..." });
      await syncAndExportRawX({
        config,
        changedOnly: options.changedOnly,
        fullSync: options.fullSync,
      });
    }

    ctx.assertNotCancelled();
    ctx.ui.status({ phase: "select", message: `Selecting up to ${options.limit} raw source(s)...` });
    const selected = await selectBatch({ managedRoot: config.managedRoot, limit: options.limit });
    if (selected.length === 0) {
      return {
        data: {
          intent: options,
          config: configData(config),
          selectedSourceIds: [],
          contextBundlePath: "",
          applied: emptyApplyResult(options.dryRun),
          lint: emptyLintResult(),
          followUpSources: [],
          relationshipCandidates: [],
          spacedRepetitionCandidates: [],
        } satisfies XBookmarksRefreshData,
        display: [
          `workspaceRoot: ${config.workspaceRoot}`,
          `managedRoot: ${config.managedRoot}`,
          `artifactRoot: ${config.artifactRoot}`,
          "No raw X bookmark sources were selected from raw/x/inbox.",
        ].join("\n"),
        summary: "xbookmarks/wiki-refresh: no raw sources selected",
      };
    }

    ctx.ui.status({ phase: "context", message: "Building deterministic context bundle..." });
    const context = await buildContextBundle({
      config,
      selected,
      batchId: options.batchId,
    });

    ctx.assertNotCancelled();
    ctx.ui.status({ phase: "synthesis", message: "Asking agent for typed wiki operations..." });
    let plan = expectData(
      await ctx.agent.run(
        buildWikiIngestPrompt({ selected, context, intent: options }),
        WikiIngestPlanType,
        { stream: false },
      ),
      "Agent returned no wiki ingest plan",
    );

    ctx.assertNotCancelled();
    ctx.ui.status({ phase: "apply", message: options.dryRun ? "Previewing wiki operations..." : "Applying wiki operations..." });
    let applied = await applyWikiPlan({
      config,
      selected,
      plan,
      dryRun: options.dryRun,
      runId: context.runId,
    });

    ctx.ui.status({ phase: "lint", message: "Linting wiki citations and links..." });
    let lint = await lintWiki({
      config,
      selected,
      plan,
      runId: context.runId,
      finalizationMode: options.dryRun ? "pre-move" : "post-move",
    });

    for (let attempt = 0; !lint.ok && !options.dryRun && options.repair && attempt < options.maxRepairAttempts; attempt += 1) {
      ctx.assertNotCancelled();
      ctx.ui.status({ phase: "repair", message: `Repairing lint findings (${attempt + 1}/${options.maxRepairAttempts})...` });
      plan = expectData(
        await ctx.agent.run(
          buildRepairPrompt({ plan, lint }),
          WikiIngestPlanType,
          { stream: false },
        ),
        "Agent returned no repair plan",
      );
      applied = await applyWikiPlan({
        config,
        selected,
        plan,
        dryRun: false,
        runId: context.runId,
      });
      lint = await lintWiki({
        config,
        selected,
        plan,
        runId: context.runId,
        finalizationMode: "post-move",
      });
    }

    if (!lint.ok && !options.dryRun) {
      throw new Error(`xbookmarks/wiki-refresh failed lint: ${lint.errorCount} error(s)`);
    }

    const data: XBookmarksRefreshData = {
      intent: options,
      config: configData(config),
      selectedSourceIds: selected.map((item) => item.sourceId),
      contextBundlePath: context.rootPath,
      applied,
      lint,
      followUpSources: plan.followUpSources,
      relationshipCandidates: plan.relationshipCandidates,
      spacedRepetitionCandidates: plan.spacedRepetitionCandidates,
    };

    return {
      data,
      display: [
        `workspaceRoot: ${config.workspaceRoot}`,
        `managedRoot: ${config.managedRoot}`,
        `artifactRoot: ${config.artifactRoot}`,
        `mode: ${options.dryRun ? "dry-run" : "apply"}`,
        `selected: ${selected.length} (${selected.map((item) => item.sourceId).join(", ")})`,
        `context: ${context.rootPath}`,
        `created pages: ${applied.createdPages.length ? applied.createdPages.join(", ") : "none"}`,
        `updated pages: ${applied.updatedPages.length ? applied.updatedPages.join(", ") : "none"}`,
        `updated maps: ${applied.updatedMaps.length ? applied.updatedMaps.join(", ") : "none"}`,
        `updated reviews: ${applied.updatedReviewPages.length ? applied.updatedReviewPages.join(", ") : "none"}`,
        `ingested sources: ${applied.ingestedSourceIds.length ? applied.ingestedSourceIds.join(", ") : "none"}`,
        `ignored sources: ${applied.ignoredSourceIds.length ? applied.ignoredSourceIds.join(", ") : "none"}`,
        `unresolved sources: ${applied.unresolvedSourceIds.length ? applied.unresolvedSourceIds.join(", ") : "none"}`,
        `lint: ${lint.ok ? "ok" : "failed"} (${lint.errorCount} error(s), ${lint.warningCount} warning(s))`,
        `follow-up sources: ${plan.followUpSources.length ? plan.followUpSources.join("; ") : "none"}`,
        `relationship candidates: ${plan.relationshipCandidates.length ? plan.relationshipCandidates.join("; ") : "none"}`,
        `spaced repetition candidates: ${plan.spacedRepetitionCandidates.length ? plan.spacedRepetitionCandidates.join("; ") : "none"}`,
      ].join("\n"),
      summary: `xbookmarks/wiki-refresh: ${selected.length} source(s), lint ${lint.ok ? "ok" : "failed"}`,
    };
  },
} satisfies Procedure;

function configData(config: { workspaceRoot: string; managedRoot: string; artifactRoot: string }) {
  return {
    workspaceRoot: config.workspaceRoot,
    managedRoot: config.managedRoot,
    artifactRoot: config.artifactRoot,
  };
}

function emptyApplyResult(dryRun: boolean) {
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

function emptyLintResult() {
  return {
    ok: true,
    errorCount: 0,
    warningCount: 0,
    findings: [],
    artifactPaths: [],
  };
}

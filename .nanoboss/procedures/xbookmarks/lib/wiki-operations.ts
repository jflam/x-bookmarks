import { mkdir, readFile, rename } from "node:fs/promises";
import { basename, dirname, join, normalize, resolve } from "node:path";

import { parseFrontmatter, setFrontmatterValue } from "./frontmatter.ts";
import { appendTextAtomic, ensureInsideRoot, fileExists, toPosixRelative, writeJson, writeTextAtomic } from "./fs.ts";
import type { ApplyResult, ApplyWikiPlanOptions, SelectedBookmark, WikiIngestPlan, WikiOperation } from "./types.ts";

const PAGE_OPERATION_KINDS = new Set(["create_page", "update_page", "update_review", "update_map"]);

export async function applyWikiPlan(options: ApplyWikiPlanOptions): Promise<ApplyResult> {
  validatePlan(options.plan, options.selected);
  const artifactPaths: string[] = [];
  const previewPath = join(options.config.artifactRoot, options.runId, "wiki-plan.json");
  await writeJson(previewPath, options.plan);
  artifactPaths.push(previewPath);

  const result: ApplyResult = {
    dryRun: options.dryRun,
    createdPages: [],
    updatedPages: [],
    updatedMaps: [],
    updatedReviewPages: [],
    ingestedSourceIds: [],
    ignoredSourceIds: [],
    unresolvedSourceIds: [],
    artifactPaths,
  };

  const selectedIds = new Set(options.selected.map((item) => item.sourceId));
  const ignored = ignoredSourceIds(options.plan);
  const cited = citedSourceIds(options.plan);
  for (const sourceId of selectedIds) {
    if (ignored.has(sourceId)) result.ignoredSourceIds.push(sourceId);
    else if (cited.has(sourceId)) result.ingestedSourceIds.push(sourceId);
    else result.unresolvedSourceIds.push(sourceId);
  }

  if (options.dryRun) {
    const dryRunPath = join(options.config.artifactRoot, options.runId, "dry-run-operations.md");
    await writeTextAtomic(dryRunPath, renderDryRunOperations(options.config.managedRoot, options.plan));
    result.artifactPaths.push(dryRunPath);
    await classifyPlannedWrites(options, result);
    return result;
  }

  if (result.unresolvedSourceIds.length > 0) {
    throw new Error(`Apply mode refused unresolved source(s): ${result.unresolvedSourceIds.join(", ")}`);
  }

  for (const operation of options.plan.operations) {
    if (PAGE_OPERATION_KINDS.has(operation.kind)) {
      await applyPageOperation(options.config.managedRoot, operation, result);
    } else if (operation.kind === "append_log") {
      const logPath = join(options.config.managedRoot, "wiki", "log.md");
      ensureInsideRoot(options.config.managedRoot, logPath, "wiki log path");
      await appendTextAtomic(logPath, `\n${operation.markdown.trim()}\n`);
      addUnique(result.updatedPages, "wiki/log.md");
    }
  }

  await moveRawSources(options.config.managedRoot, options.selected, result);
  return result;
}

function validatePlan(plan: WikiIngestPlan, selected: SelectedBookmark[]): void {
  if (!plan.summary.trim()) throw new Error("WikiIngestPlan.summary must not be empty.");
  const selectedIds = new Set(selected.map((item) => item.sourceId));
  const ignored = new Set<string>();
  const cited = new Set<string>();
  for (const operation of plan.operations) {
    if (operation.kind === "ignore_source") {
      if (!operation.reason.trim()) throw new Error(`ignore_source ${operation.sourceId} requires a non-empty reason.`);
      if (!selectedIds.has(operation.sourceId)) throw new Error(`ignore_source references unselected source ${operation.sourceId}.`);
      ignored.add(operation.sourceId);
      continue;
    }
    if (operation.kind === "append_log") {
      if (!operation.markdown.trim()) throw new Error("append_log operation markdown must not be empty.");
      for (const sourceId of operation.sourceIds) cited.add(requireSelectedSource(sourceId, selectedIds));
      continue;
    }
    if (!PAGE_OPERATION_KINDS.has(operation.kind)) {
      throw new Error(`Unsupported operation kind: ${(operation as { kind: string }).kind}`);
    }
    if (!operation.markdown.trim()) throw new Error(`${operation.kind} ${operation.path} markdown must not be empty.`);
    if (!operation.path.trim()) throw new Error(`${operation.kind} requires path.`);
    for (const sourceId of operation.sourceIds) cited.add(requireSelectedSource(sourceId, selectedIds));
  }
  for (const sourceId of ignored) {
    if (cited.has(sourceId)) throw new Error(`Source ${sourceId} is both ignored and cited.`);
  }
}

function requireSelectedSource(sourceId: string, selectedIds: Set<string>): string {
  if (!selectedIds.has(sourceId)) throw new Error(`Operation references unselected source ${sourceId}.`);
  return sourceId;
}

async function classifyPlannedWrites(options: ApplyWikiPlanOptions, result: ApplyResult): Promise<void> {
  for (const operation of options.plan.operations) {
    if (!PAGE_OPERATION_KINDS.has(operation.kind)) continue;
    const rel = normalizeWikiOperationPath(operation);
    const existed = await fileExists(join(options.config.managedRoot, rel));
    if (!existed) addUnique(result.createdPages, rel);
    else if (operation.kind === "update_review") addUnique(result.updatedReviewPages, rel);
    else if (operation.kind === "update_map") addUnique(result.updatedMaps, rel);
    else addUnique(result.updatedPages, rel);
  }
}

async function applyPageOperation(managedRoot: string, operation: Extract<WikiOperation, { path: string; markdown: string }>, result: ApplyResult): Promise<void> {
  const rel = normalizeWikiOperationPath(operation);
  const destination = ensureInsideRoot(managedRoot, join(managedRoot, rel), "wiki operation path");
  if (!rel.startsWith("wiki/")) throw new Error(`Wiki operation path must be under wiki/: ${operation.path}`);
  const existed = await fileExists(destination);
  await writeTextAtomic(destination, operation.markdown.endsWith("\n") ? operation.markdown : `${operation.markdown}\n`);
  if (!existed) addUnique(result.createdPages, rel);
  else if (operation.kind === "update_review") addUnique(result.updatedReviewPages, rel);
  else if (operation.kind === "update_map") addUnique(result.updatedMaps, rel);
  else addUnique(result.updatedPages, rel);
}

async function moveRawSources(managedRoot: string, selected: SelectedBookmark[], result: ApplyResult): Promise<void> {
  const ignored = new Set(result.ignoredSourceIds);
  const ingested = new Set(result.ingestedSourceIds);
  for (const item of selected) {
    const targetDir = ignored.has(item.sourceId)
      ? join(managedRoot, "raw", "x", "ignored")
      : ingested.has(item.sourceId)
        ? join(managedRoot, "raw", "x", "ingested")
        : undefined;
    if (!targetDir) continue;
    const targetPath = ensureInsideRoot(managedRoot, join(targetDir, basename(item.rawPath)), "raw-source move target");
    const originalSourcePath = ensureInsideRoot(managedRoot, item.rawPath, "raw-source path");
    const sourcePath = await fileExists(originalSourcePath) ? originalSourcePath : targetPath;
    if (!(await fileExists(sourcePath))) {
      throw new Error(`Selected raw source is missing: ${item.rawPath}`);
    }
    await mkdir(dirname(targetPath), { recursive: true });
    const status = ignored.has(item.sourceId) ? "ignored" : "ingested";
    await writeTextAtomic(sourcePath, setFrontmatterValue(await readFile(sourcePath, "utf8"), "status", status));
    if (resolve(sourcePath) !== resolve(targetPath)) {
      await rename(sourcePath, targetPath);
    }
  }
}

function renderDryRunOperations(managedRoot: string, plan: WikiIngestPlan): string {
  return [
    `# Dry Run Operations`,
    "",
    plan.summary,
    "",
    ...plan.operations.map((operation, index) => renderOperation(managedRoot, operation, index + 1)),
  ].join("\n");
}

function renderOperation(managedRoot: string, operation: WikiOperation, index: number): string {
  if (operation.kind === "ignore_source") {
    return [`## ${index}. ignore_source ${operation.sourceId}`, "", operation.reason, ""].join("\n");
  }
  if (operation.kind === "append_log") {
    return [`## ${index}. append_log`, "", operation.markdown, ""].join("\n");
  }
  const rel = normalizeWikiOperationPath(operation);
  return [`## ${index}. ${operation.kind} ${rel}`, "", "```markdown", operation.markdown.trim(), "```", ""].join("\n");
}

export function normalizeWikiOperationPath(operation: Extract<WikiOperation, { path: string }>): string {
  const normalized = normalize(operation.path).replaceAll("\\", "/").replace(/^\.\//, "");
  if (normalized.startsWith("../") || normalized === ".." || normalized.startsWith("/") || normalized.includes("\0")) {
    throw new Error(`Unsafe wiki operation path: ${operation.path}`);
  }
  const withWiki = normalized.startsWith("wiki/") ? normalized : `wiki/${normalized}`;
  return withWiki.endsWith(".md") ? withWiki : `${withWiki}.md`;
}

export function operationMarkdownFiles(plan: WikiIngestPlan): Array<{ file: string; markdown: string }> {
  return plan.operations.flatMap((operation) => {
    if (PAGE_OPERATION_KINDS.has(operation.kind)) {
      const pageOperation = operation as Extract<WikiOperation, { path: string; markdown: string }>;
      return [{ file: normalizeWikiOperationPath(pageOperation), markdown: pageOperation.markdown }];
    }
    if (operation.kind === "append_log") return [{ file: "wiki/log.md", markdown: operation.markdown }];
    return [];
  });
}

export function citedSourceIds(plan: WikiIngestPlan): Set<string> {
  const ids = new Set<string>();
  for (const operation of plan.operations) {
    if ("sourceIds" in operation) {
      for (const sourceId of operation.sourceIds) ids.add(sourceId);
    }
  }
  return ids;
}

export function ignoredSourceIds(plan: WikiIngestPlan): Set<string> {
  return new Set(plan.operations.filter((operation) => operation.kind === "ignore_source").map((operation) => operation.sourceId));
}

function addUnique(items: string[], item: string): void {
  if (!items.includes(item)) items.push(item);
}

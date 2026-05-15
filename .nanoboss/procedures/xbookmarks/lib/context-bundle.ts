import { mkdir, readFile } from "node:fs/promises";
import { basename, join } from "node:path";

import { fileExists, listMarkdownFiles, readTextIfExists, toPosixRelative, writeJson, writeTextAtomic } from "./fs.ts";
import type { BuildContextBundleOptions, ContextBundle, SelectedBookmark } from "./types.ts";
import { defaultRunId } from "./intent.ts";

export async function buildContextBundle(options: BuildContextBundleOptions): Promise<ContextBundle> {
  const runId = options.runId ?? defaultRunId();
  const runPath = join(options.config.artifactRoot, runId);
  const contextRoot = join(runPath, "context");
  await mkdir(contextRoot, { recursive: true });

  const selectedBookmarksPath = join(contextRoot, "selected-bookmarks.json");
  const selectedRawSourcesPath = join(contextRoot, "selected-raw-sources.md");
  const selectedMediaPath = join(contextRoot, "selected-media.md");
  const schemaPath = join(contextRoot, "schema.md");
  const wikiIndexPath = join(contextRoot, "wiki-index.md");
  const homePath = join(contextRoot, "home.md");
  const thisWeekPath = join(contextRoot, "this-week.md");
  const candidateRelatedPagesPath = join(contextRoot, "candidate-related-pages.json");

  await writeJson(selectedBookmarksPath, options.selected);
  await writeTextAtomic(selectedRawSourcesPath, await concatenateRawSources(options.config.managedRoot, options.selected));
  await writeTextAtomic(selectedMediaPath, await summarizeSelectedMedia(options.config.managedRoot, options.selected));
  await copyIfExists(join(options.config.managedRoot, "wiki", "schema.md"), schemaPath);
  await copyIfExists(join(options.config.managedRoot, "wiki", "index.md"), wikiIndexPath);
  const copiedHomePath = await copyIfExists(join(options.config.managedRoot, "wiki", "home.md"), homePath);
  const copiedThisWeekPath = await copyIfExists(join(options.config.managedRoot, "wiki", "reviews", "this-week.md"), thisWeekPath);

  const relevantMapPaths = await copyRelevantMaps(options.config.managedRoot, contextRoot, options.selected);
  await writeJson(candidateRelatedPagesPath, await findCandidateRelatedPages(options.config.managedRoot, options.selected));
  await writeJson(join(contextRoot, "run.json"), {
    runId,
    batchId: options.batchId,
    generatedAt: new Date().toISOString(),
    workspaceRoot: options.config.workspaceRoot,
    managedRoot: options.config.managedRoot,
    selectedSourceIds: options.selected.map((item) => item.sourceId),
  });

  return {
    runId,
    batchId: options.batchId,
    rootPath: contextRoot,
    runPath,
    selectedBookmarksPath,
    selectedRawSourcesPath,
    selectedMediaPath,
    schemaPath,
    wikiIndexPath,
    homePath: copiedHomePath ? homePath : undefined,
    thisWeekPath: copiedThisWeekPath ? thisWeekPath : undefined,
    relevantMapPaths,
    candidateRelatedPagesPath,
  };
}

async function concatenateRawSources(managedRoot: string, selected: SelectedBookmark[]): Promise<string> {
  const blocks: string[] = [];
  for (const item of selected) {
    blocks.push([
      `# Source ${item.sourceId}`,
      "",
      `Raw path: ${toPosixRelative(managedRoot, item.rawPath)}`,
      `Canonical URL: ${item.canonicalUrl ?? ""}`,
      "",
      await readFile(item.rawPath, "utf8"),
    ].join("\n"));
  }
  return `${blocks.join("\n\n---\n\n")}\n`;
}

async function summarizeSelectedMedia(managedRoot: string, selected: SelectedBookmark[]): Promise<string> {
  const blocks: string[] = [];
  for (const item of selected) {
    const raw = await readFile(item.rawPath, "utf8");
    const mediaLines = extractMediaLines(raw);
    blocks.push([
      `# Source ${item.sourceId}`,
      "",
      `Raw path: ${toPosixRelative(managedRoot, item.rawPath)}`,
      `Canonical URL: ${item.canonicalUrl ?? ""}`,
      mediaLines.length > 0
        ? [
          "",
          "Downloaded media:",
          "",
          ...mediaLines,
        ].join("\n")
        : "",
      "",
    ].join("\n").trimEnd());
  }
  return `${blocks.join("\n\n---\n\n")}\n`;
}

function extractMediaLines(markdown: string): string[] {
  const lines = markdown.split(/\r?\n/);
  const mediaStart = lines.findIndex((line) => line.trim() === "## Media");
  if (mediaStart < 0) return [];
  const result: string[] = [];
  for (let index = mediaStart + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (/^##\s+/.test(line)) break;
    if (line.trim().startsWith("- ")) result.push(line.trim());
  }
  return result;
}

async function copyIfExists(source: string, destination: string): Promise<boolean> {
  if (!(await fileExists(source))) return false;
  await writeTextAtomic(destination, await readFile(source, "utf8"));
  return true;
}

async function copyRelevantMaps(managedRoot: string, contextRoot: string, selected: SelectedBookmark[]): Promise<string[]> {
  const mapsRoot = join(managedRoot, "wiki", "maps");
  if (!(await fileExists(mapsRoot))) return [];
  const destinationRoot = join(contextRoot, "relevant-maps");
  await mkdir(destinationRoot, { recursive: true });
  const files = (await listMarkdownFiles(mapsRoot)).slice(0, 12);
  const copied: string[] = [];
  for (const file of files) {
    const destination = join(destinationRoot, basename(file));
    await writeTextAtomic(destination, await readFile(file, "utf8"));
    copied.push(destination);
  }
  return copied;
}

async function findCandidateRelatedPages(managedRoot: string, selected: SelectedBookmark[]): Promise<Array<{ path: string; score: number; matches: string[] }>> {
  const wikiRoot = join(managedRoot, "wiki");
  const files = await listMarkdownFiles(wikiRoot);
  const terms = keywordSet(selected);
  const candidates: Array<{ path: string; score: number; matches: string[] }> = [];
  for (const file of files) {
    const rel = toPosixRelative(managedRoot, file);
    if (rel === "wiki/index.md" || rel === "wiki/log.md") continue;
    const content = (await readTextIfExists(file)).toLowerCase();
    const matches = [...terms].filter((term) => content.includes(term));
    if (matches.length > 0) candidates.push({ path: rel, score: matches.length, matches: matches.slice(0, 8) });
  }
  return candidates.sort((a, b) => b.score - a.score || a.path.localeCompare(b.path)).slice(0, 30);
}

function keywordSet(selected: SelectedBookmark[]): Set<string> {
  const terms = new Set<string>();
  for (const item of selected) {
    for (const value of [item.title, item.authorHandle, item.canonicalUrl]) {
      if (!value) continue;
      for (const term of value.toLowerCase().match(/[a-z0-9][a-z0-9_-]{3,}/g) ?? []) {
        if (!/^\d+$/.test(term)) terms.add(term);
      }
    }
  }
  return terms;
}

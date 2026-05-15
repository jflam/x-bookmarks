import { readFileSync } from "node:fs";
import { mkdir, readFile } from "node:fs/promises";
import { basename, dirname, join, normalize, resolve } from "node:path";

import { defaultRunId } from "./intent.ts";
import { ensureInsideRoot, fileExists, listMarkdownFiles, toPosixRelative, writeJson, writeTextAtomic } from "./fs.ts";
import type { TopicSelection, TopicSynthesisContext, TopicSynthesisIntent, TopicSynthesisOptions, XBookmarksConfig } from "./types.ts";

const RAW_WIKILINK_RE = /\[\[([^\]|]*raw\/x\/[^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]/g;
const DURABLE_TOPIC_PREFIXES = [
  "wiki/concepts/",
  "wiki/tools/",
  "wiki/projects/",
  "wiki/questions/",
];

export function validateAndDefaultTopicSynthesisIntent(intent: TopicSynthesisIntent): TopicSynthesisOptions {
  const all = intent.all ?? false;
  const chunkSize = Math.max(1, Math.min(Math.floor(intent.chunkSize ?? intent.limit ?? 3), 10));
  return {
    dryRun: (intent.mode ?? "dry-run") !== "apply",
    paths: (intent.paths ?? []).map(normalizeTopicPath).filter(Boolean),
    all,
    limit: all ? Number.MAX_SAFE_INTEGER : Math.max(1, Math.min(Math.floor(intent.limit ?? 3), 10)),
    chunkSize,
    repair: intent.repair ?? true,
    maxRepairAttempts: Math.max(0, Math.min(Math.floor(intent.maxRepairAttempts ?? 1), 3)),
    batchId: intent.batchId ?? `topic-synthesis-${new Date().toISOString().slice(0, 10)}`,
    intentRationale: intent.rationale,
    intentConfidence: intent.confidence,
  };
}

export function parseProgrammaticTopicSynthesisOptions(raw: string): TopicSynthesisOptions {
  const value = JSON.parse(raw) as TopicSynthesisIntent;
  return validateAndDefaultTopicSynthesisIntent({
    ...value,
    rationale: value.rationale ?? "programmatic topic synthesis refresh",
    confidence: value.confidence ?? "high",
  });
}

export async function selectTopicPages(options: {
  config: XBookmarksConfig;
  paths: string[];
  limit: number;
}): Promise<TopicSelection[]> {
  const explicit = options.paths.length > 0;
  const candidates = explicit
    ? options.paths
    : (await listMarkdownFiles(join(options.config.managedRoot, "wiki")))
      .map((file) => toPosixRelative(options.config.managedRoot, file))
      .filter(isDurableTopicPath);

  const scored: Array<TopicSelection & { score: number }> = [];
  for (const rel of candidates) {
    const path = normalizeTopicPath(rel);
    if (!path || !isDurableTopicPath(path)) continue;
    const abs = join(options.config.managedRoot, path);
    if (!(await fileExists(abs))) {
      if (explicit) throw new Error(`Topic page does not exist: ${path}`);
      continue;
    }
    const markdown = await readFile(abs, "utf8");
    const sources = rawSourceTargets(options.config.managedRoot, path, markdown);
    scored.push({
      path,
      title: markdown.match(/^#\s+(.+)$/m)?.[1]?.trim() ?? basename(path, ".md"),
      sourceIds: sources.map((source) => source.sourceId),
      sourcePaths: sources.map((source) => source.relPath),
      reason: explicit ? "explicitly requested" : topicRefreshReason(markdown, sources.length),
      score: topicRefreshScore(markdown, sources.length),
    });
  }

  return scored
    .sort((a, b) => explicit ? a.path.localeCompare(b.path) : b.score - a.score || a.path.localeCompare(b.path))
    .slice(0, options.limit)
    .map(({ score: _score, ...selection }) => selection);
}

export async function buildTopicSynthesisContext(options: {
  config: XBookmarksConfig;
  selected: TopicSelection[];
  batchId: string;
  runId?: string;
}): Promise<TopicSynthesisContext> {
  const runId = options.runId ?? defaultRunId();
  const runPath = join(options.config.artifactRoot, runId);
  const contextRoot = join(runPath, "context");
  await mkdir(contextRoot, { recursive: true });

  const selectedTopicsPath = join(contextRoot, "selected-topics.json");
  const selectedTopicPagesPath = join(contextRoot, "selected-topic-pages.md");
  const selectedRawSourcesPath = join(contextRoot, "selected-raw-sources.md");
  const selectedMediaPath = join(contextRoot, "selected-media.md");
  const wikiIndexPath = join(contextRoot, "wiki-index.md");

  await writeJson(selectedTopicsPath, options.selected);
  await writeTextAtomic(selectedTopicPagesPath, await concatenateTopicPages(options.config.managedRoot, options.selected));
  await writeTextAtomic(selectedRawSourcesPath, await concatenateRawSources(options.config.managedRoot, options.selected));
  await writeTextAtomic(selectedMediaPath, await summarizeTopicMedia(options.config.managedRoot, options.selected));
  if (await fileExists(join(options.config.managedRoot, "wiki", "index.md"))) {
    await writeTextAtomic(wikiIndexPath, await readFile(join(options.config.managedRoot, "wiki", "index.md"), "utf8"));
  } else {
    await writeTextAtomic(wikiIndexPath, "");
  }
  await writeJson(join(contextRoot, "run.json"), {
    runId,
    batchId: options.batchId,
    generatedAt: new Date().toISOString(),
    workspaceRoot: options.config.workspaceRoot,
    managedRoot: options.config.managedRoot,
    selectedTopicPaths: options.selected.map((item) => item.path),
  });

  return {
    runId,
    batchId: options.batchId,
    rootPath: contextRoot,
    runPath,
    selectedTopicsPath,
    selectedTopicPagesPath,
    selectedRawSourcesPath,
    selectedMediaPath,
    wikiIndexPath,
  };
}

export function buildTopicSynthesisIntentPrompt(prompt: string): string {
  return [
    "Extract execution intent for an X bookmarks topic synthesis refresh procedure.",
    "Return only typed JSON matching the provided schema.",
    "",
    "Rules:",
    "- dry run, preview, simulate, show me -> mode dry-run",
    "- apply, write changes, refresh topics, update wiki pages -> mode apply",
    "- all, everything, every topic, full wiki -> all true",
    "- explicit wiki paths, concept paths, tool paths, project paths, or question paths -> paths",
    "- chunks of N, chunk size N, batches of N -> chunkSize",
    "- next N topics -> limit",
    "- no repair, do not auto-fix -> repair false",
    "",
    `User request: ${prompt}`,
  ].join("\n");
}

export function buildTopicSynthesisPrompt(params: {
  selected: TopicSelection[];
  context: TopicSynthesisContext;
  intent: TopicSynthesisOptions;
}): string {
  return [
    "# X Bookmarks Topic Synthesis Refresh",
    "",
    "You improve existing durable topic pages in the user's managed X Bookmarks Obsidian wiki.",
    "Return a WikiIngestPlan JSON object with update_page operations only, plus an append_log operation.",
    "",
    "Purpose:",
    "- turn source-preserving topic pages into useful analysis pages;",
    "- preserve provenance, X embeds, raw-source wikilinks, and block IDs;",
    "- improve summaries, notes, caveats, relationships, and review questions;",
    "- keep evidence/source blocks as evidence, not as the summary or notes;",
    "- inspect and use downloaded media paths when the source claim is image-driven;",
    "- leave uncertainty explicit instead of inventing what sources or images mean.",
    "",
    "Hard rules:",
    "- update only selected topic pages listed below;",
    "- do not create new pages in this procedure;",
    "- do not update review pages;",
    "- do not move raw sources;",
    "- every update_page operation must use sourceIds: []; this is a topic rewrite, not a raw ingest;",
    "- preserve every existing raw-source citation block and block id unless it is an exact duplicate;",
    "- Summary must be narrative prose and must not contain raw source cards;",
    "- Notes must be interpretive bullets or review guidance and must not contain raw source cards;",
    "- raw source cards belong under Evidence, Examples / Evidence, Sources, or dated evidence sections.",
    "",
    "Current run:",
    JSON.stringify({
      intent: params.intent,
      selected: params.selected,
      contextBundle: params.context,
    }, null, 2),
    "",
    "Context bundle contents:",
    markdownBlock("wiki-index.md", readOptional(params.context.wikiIndexPath)),
    jsonBlock("selected-topics.json", readOptional(params.context.selectedTopicsPath)),
    markdownBlock("selected-topic-pages.md", readOptional(params.context.selectedTopicPagesPath)),
    markdownBlock("selected-media.md", readOptional(params.context.selectedMediaPath)),
    markdownBlock("selected-raw-sources.md", readOptional(params.context.selectedRawSourcesPath)),
    "",
    "Return only a WikiIngestPlan JSON object. Do not edit files directly.",
  ].join("\n");
}

function normalizeTopicPath(value: string): string {
  const normalized = value
    .replaceAll("\\", "/")
    .replace(/^.*\/X Bookmarks\//, "")
    .replace(/^\.\//, "")
    .replace(/^\/+/, "");
  const withWiki = normalized.startsWith("wiki/") ? normalized : `wiki/${normalized}`;
  const withExtension = withWiki.endsWith(".md") ? withWiki : `${withWiki}.md`;
  return normalize(withExtension).replaceAll("\\", "/");
}

function isDurableTopicPath(path: string): boolean {
  return DURABLE_TOPIC_PREFIXES.some((prefix) => path.startsWith(prefix)) && path.endsWith(".md");
}

function rawSourceTargets(managedRoot: string, topicRelPath: string, markdown: string): Array<{ sourceId: string; relPath: string; absPath: string }> {
  const results: Array<{ sourceId: string; relPath: string; absPath: string }> = [];
  RAW_WIKILINK_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = RAW_WIKILINK_RE.exec(markdown)) !== null) {
    const target = match[1].trim();
    const absPath = resolveRawTarget(managedRoot, topicRelPath, target);
    const relPath = toPosixRelative(managedRoot, absPath);
    const sourceId = basename(relPath, ".md");
    if (!results.some((item) => item.relPath === relPath)) results.push({ sourceId, relPath, absPath });
  }
  return results;
}

function resolveRawTarget(managedRoot: string, fromTopicRelPath: string, target: string): string {
  const withoutHeading = target.split("#")[0];
  const withExtension = withoutHeading.endsWith(".md") ? withoutHeading : `${withoutHeading}.md`;
  const base = join(managedRoot, fromTopicRelPath);
  return ensureInsideRoot(managedRoot, resolve(normalize(join(dirname(base), withExtension))), "topic raw-source target");
}

function topicRefreshScore(markdown: string, sourceCount: number): number {
  let score = sourceCount;
  if (/Revisit this page during future ingest runs/i.test(markdown)) score += 20;
  if (/evidence below is the current source trail/i.test(markdown)) score += 10;
  if (/## Contradictions \/ Caveats/i.test(markdown)) score += 2;
  if (/Media present|Downloaded media/i.test(markdown)) score += 2;
  return score;
}

function topicRefreshReason(markdown: string, sourceCount: number): string {
  if (/Revisit this page during future ingest runs/i.test(markdown)) return "contains mechanical review guidance from a previous repair pass";
  if (/evidence below is the current source trail/i.test(markdown)) return "summary was mechanically repaired and needs deeper synthesis";
  return `has ${sourceCount} cited raw source(s) available for synthesis`;
}

async function concatenateTopicPages(managedRoot: string, selected: TopicSelection[]): Promise<string> {
  const blocks: string[] = [];
  for (const item of selected) {
    blocks.push([
      `# Topic ${item.path}`,
      "",
      `Title: ${item.title}`,
      `Reason: ${item.reason}`,
      "",
      await readFile(join(managedRoot, item.path), "utf8"),
    ].join("\n"));
  }
  return `${blocks.join("\n\n---\n\n")}\n`;
}

async function concatenateRawSources(managedRoot: string, selected: TopicSelection[]): Promise<string> {
  const blocks: string[] = [];
  for (const item of selected) {
    for (const relPath of item.sourcePaths) {
      const absPath = join(managedRoot, relPath);
      if (!(await fileExists(absPath))) continue;
      blocks.push([
        `# Source ${basename(relPath, ".md")} for ${item.path}`,
        "",
        `Raw path: ${relPath}`,
        "",
        await readFile(absPath, "utf8"),
      ].join("\n"));
    }
  }
  return `${blocks.join("\n\n---\n\n")}\n`;
}

async function summarizeTopicMedia(managedRoot: string, selected: TopicSelection[]): Promise<string> {
  const blocks: string[] = [];
  for (const item of selected) {
    for (const relPath of item.sourcePaths) {
      const absPath = join(managedRoot, relPath);
      if (!(await fileExists(absPath))) continue;
      const raw = await readFile(absPath, "utf8");
      const mediaLines = extractMediaLines(raw);
      if (mediaLines.length === 0) continue;
      blocks.push([
        `# Source ${basename(relPath, ".md")} for ${item.path}`,
        "",
        `Raw path: ${relPath}`,
        "",
        "Downloaded media:",
        "",
        ...mediaLines,
      ].join("\n"));
    }
  }
  return blocks.length > 0 ? `${blocks.join("\n\n---\n\n")}\n` : "No downloaded media listed for selected topic sources.\n";
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

function readOptional(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function markdownBlock(label: string, content: string): string {
  return [`## ${label}`, "", "```markdown", truncate(content), "```", ""].join("\n");
}

function jsonBlock(label: string, content: string): string {
  return [`## ${label}`, "", "```json", truncate(content || "[]"), "```", ""].join("\n");
}

function truncate(content: string): string {
  const max = 100_000;
  return content.length <= max ? content : `${content.slice(0, max)}\n\n[truncated]`;
}

import { readFile } from "node:fs/promises";
import { basename, join, relative, sep } from "node:path";

import { fileExists, listMarkdownFiles, listMarkdownFilesShallow, toPosixRelative, writeJson, writeTextAtomic } from "./fs.ts";
import { defaultRunId } from "./intent.ts";
import { readSelectedBookmark } from "./raw-source.ts";
import type { BuildReviewPagesOptions, ReviewBuildResult, ReviewPageBuild, ReviewSourceEntry, XBookmarksConfig } from "./types.ts";

const REVIEW_EXCLUDED_WIKI_FILES = new Set([
  "wiki/home.md",
  "wiki/index.md",
  "wiki/log.md",
  "wiki/schema.md",
]);

export async function buildReviewPages(options: BuildReviewPagesOptions): Promise<ReviewBuildResult> {
  const runId = options.runId ?? defaultRunId();
  const allSources = await listReviewSources(options.config);
  const allWeeks = [...new Set(allSources.map((source) => source.week))].sort().reverse();
  const requestedWeeks = requestedWeekSet(allWeeks, options.weeks, options.limitWeeks);
  const includeEmptyWeeks = Boolean(options.weeks?.length);
  const backlinks = await findWikiBacklinks(options.config, allSources);
  const pages: ReviewPageBuild[] = [];

  for (const week of requestedWeeks) {
    const entries = allSources
      .filter((source) => source.week === week)
      .map((source) => ({
        ...source,
        wikiEntries: backlinks.get(source.sourceId) ?? [],
      }));
    if (entries.length === 0 && !includeEmptyWeeks) continue;
    pages.push(await renderReviewPage(options.config, week, entries));
  }

  const artifactPaths: string[] = [];
  const artifactPath = join(options.config.artifactRoot, runId, "review-pages.json");
  await writeJson(artifactPath, pages.map((page) => ({
    week: page.week,
    path: page.path,
    sourceCount: page.sourceCount,
    existed: page.existed,
  })));
  artifactPaths.push(artifactPath);

  const result: ReviewBuildResult = {
    dryRun: options.dryRun,
    reviewedWeeks: pages.map((page) => page.week),
    createdPages: [],
    updatedPages: [],
    skippedPages: [],
    artifactPaths,
    pages,
  };

  for (const page of pages) {
    if (options.dryRun) {
      const previewPath = join(options.config.artifactRoot, runId, page.path);
      await writeTextAtomic(previewPath, page.markdown);
      artifactPaths.push(previewPath);
      if (page.existed && !options.overwriteExisting) result.skippedPages.push(page.path);
      else if (page.existed) result.updatedPages.push(page.path);
      else result.createdPages.push(page.path);
      continue;
    }

    if (page.existed && !options.overwriteExisting) {
      result.skippedPages.push(page.path);
      continue;
    }

    const destination = join(options.config.managedRoot, page.path);
    await writeTextAtomic(destination, page.markdown);
    if (page.existed) result.updatedPages.push(page.path);
    else result.createdPages.push(page.path);
  }

  return result;
}

export async function listReviewSources(config: XBookmarksConfig): Promise<ReviewSourceEntry[]> {
  const roots = [
    { status: "ingested" as const, path: join(config.managedRoot, "raw", "x", "ingested") },
    { status: "ignored" as const, path: join(config.managedRoot, "raw", "x", "ignored") },
  ];
  const entries: ReviewSourceEntry[] = [];
  for (const root of roots) {
    for (const file of await listMarkdownFilesShallow(root.path)) {
      const selected = await readSelectedBookmark(file);
      const week = isoWeek(selected.postedAt ?? selected.exportedAt);
      if (!week) continue;
      entries.push({
        sourceId: selected.sourceId,
        week,
        status: root.status,
        rawPath: file,
        canonicalUrl: selected.canonicalUrl ?? `https://x.com/i/web/status/${selected.tweetId}`,
        authorHandle: selected.authorHandle,
        postedAt: selected.postedAt,
        wikiEntries: [],
      });
    }
  }
  return entries.sort(compareReviewSources);
}

async function findWikiBacklinks(
  config: XBookmarksConfig,
  sources: ReviewSourceEntry[],
): Promise<Map<string, Array<{ path: string; title: string; link: string }>>> {
  const wikiFiles = (await listMarkdownFiles(join(config.managedRoot, "wiki")))
    .map((file) => ({ absolute: file, relative: toPosixRelative(config.managedRoot, file) }))
    .filter((file) => shouldScanWikiFile(file.relative));
  const sourceIds = sources.map((source) => source.sourceId);
  const result = new Map<string, Array<{ path: string; title: string; link: string }>>();

  for (const file of wikiFiles) {
    const markdown = await readFile(file.absolute, "utf8");
    const matches = sourceIds.filter((sourceId) => citesSource(markdown, sourceId));
    if (matches.length === 0) continue;
    const title = extractPageTitle(markdown, file.relative);
    for (const sourceId of matches) {
      const entries = result.get(sourceId) ?? [];
      const blockId = findSourceBlockId(markdown, sourceId);
      entries.push({
        path: file.relative,
        title,
        link: linkFromReview(file.relative, title, blockId),
      });
      result.set(sourceId, entries);
    }
  }

  for (const entries of result.values()) {
    entries.sort((a, b) => a.path.localeCompare(b.path));
  }
  return result;
}

async function renderReviewPage(config: XBookmarksConfig, week: string, entries: ReviewSourceEntry[]): Promise<ReviewPageBuild> {
  const relPath = `wiki/reviews/${week}.md`;
  const destination = join(config.managedRoot, relPath);
  const existed = await fileExists(destination);
  const { start, end } = isoWeekBounds(week);
  const today = new Date().toISOString().slice(0, 10);
  const markdown = [
    "---",
    "type: output",
    "status: active",
    `created: ${today}`,
    `updated: ${today}`,
    `source_count: ${entries.length}`,
    `week: ${week}`,
    `period_start: ${start}`,
    `period_end: ${end}`,
    "tags:",
    "  - review",
    "  - weekly",
    "  - source-trail",
    "---",
    "",
    `# ${week} Review`,
    "",
    displayDateRange(start, end),
    "",
    "## How To Use This Week",
    "",
    "Use this page as a source-trail review surface. Each item embeds the original post, links to the raw source, and lists the current wiki entries that cite that source.",
    "",
    "## Source Trail",
    "",
    ...(entries.length > 0
      ? entries.flatMap(renderReviewSourceLine)
      : ["No captured X bookmarks in the current processed archive were authored during this week yet.", ""]),
  ].join("\n");
  return {
    week,
    path: relPath,
    sourceCount: entries.length,
    markdown: markdown.endsWith("\n") ? markdown : `${markdown}\n`,
    existed,
  };
}

function renderReviewSourceLine(entry: ReviewSourceEntry): string[] {
  const rawLink = relativeRawSourceLink(entry.rawPath);
  const alias = entry.status === "ignored" ? "Ignored bookmark" : "Captured bookmark";
  const wikiEntries = entry.wikiEntries.length > 0
    ? entry.wikiEntries.map((item) => `- ${item.link}`)
    : ["- none"];
  return [
    `![](${entry.canonicalUrl})`,
    "",
    `[[${rawLink}|${alias}]]`,
    "",
    "Wiki entries:",
    ...wikiEntries,
    "",
  ];
}

function relativeRawSourceLink(rawPath: string): string {
  const parts = rawPath.split(sep);
  const rawIndex = parts.lastIndexOf("raw");
  const rel = rawIndex >= 0 ? parts.slice(rawIndex).join("/") : rawPath.split(sep).join("/");
  return `../../${rel.replace(/\.md$/, "")}`;
}

function requestedWeekSet(allWeeks: string[], weeks: string[] | undefined, limitWeeks: number | undefined): string[] {
  const requested = weeks && weeks.length > 0
    ? [...new Set(weeks)].sort().reverse()
    : allWeeks;
  return typeof limitWeeks === "number" && limitWeeks > 0 ? requested.slice(0, limitWeeks) : requested;
}

function shouldScanWikiFile(path: string): boolean {
  return path.startsWith("wiki/")
    && !path.startsWith("wiki/reviews/")
    && !REVIEW_EXCLUDED_WIKI_FILES.has(path);
}

function citesSource(markdown: string, sourceId: string): boolean {
  const escaped = sourceId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`raw/x/(?:inbox|ingested|ignored)/${escaped}(?:\\.md)?(?:[\\|\\]#]|$)`).test(markdown);
}

function findSourceBlockId(markdown: string, sourceId: string): string | undefined {
  const escaped = sourceId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const sourcePattern = new RegExp(`raw/x/(?:inbox|ingested|ignored)/${escaped}(?:\\.md)?(?:[\\|\\]#]|$)`);
  for (const line of markdown.split(/\r?\n/)) {
    if (!sourcePattern.test(line)) continue;
    const block = /\s\^([A-Za-z0-9_-]+)\s*$/.exec(line)?.[1];
    if (block) return block;
  }
  return undefined;
}

function extractPageTitle(markdown: string, relPath: string): string {
  const heading = /^#\s+(.+)$/m.exec(markdown)?.[1]?.trim();
  if (heading) return heading;
  return basename(relPath, ".md")
    .replace(/[-_]+/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function linkFromReview(targetRelPath: string, title: string, blockId: string | undefined): string {
  const target = relative("wiki/reviews", targetRelPath).split(sep).join("/").replace(/\.md$/, "");
  return `[[${blockId ? `${target}#^${blockId}` : target}|${title}]]`;
}

function compareReviewSources(a: ReviewSourceEntry, b: ReviewSourceEntry): number {
  const aDate = Date.parse(a.postedAt ?? "");
  const bDate = Date.parse(b.postedAt ?? "");
  if (Number.isFinite(aDate) && Number.isFinite(bDate) && aDate !== bDate) return bDate - aDate;
  return b.sourceId.localeCompare(a.sourceId);
}

function isoWeek(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return undefined;
  const { year, week } = isoWeekParts(date);
  return `${year}-W${String(week).padStart(2, "0")}`;
}

function isoWeekBounds(weekValue: string): { start: string; end: string } {
  const match = /^(\d{4})-W(\d{2})$/.exec(weekValue);
  if (!match) return { start: "", end: "" };
  const year = Number(match[1]);
  const week = Number(match[2]);
  const jan4 = new Date(Date.UTC(year, 0, 4));
  const jan4Day = jan4.getUTCDay() || 7;
  const monday = new Date(jan4);
  monday.setUTCDate(jan4.getUTCDate() - jan4Day + 1 + (week - 1) * 7);
  const sunday = new Date(monday);
  sunday.setUTCDate(monday.getUTCDate() + 6);
  return { start: ymd(monday), end: ymd(sunday) };
}

function displayDateRange(start: string, end: string): string {
  if (!start || !end) return "";
  const startDate = new Date(`${start}T00:00:00.000Z`);
  const endDate = new Date(`${end}T00:00:00.000Z`);
  const startMonth = monthName(startDate);
  const endMonth = monthName(endDate);
  const startDay = startDate.getUTCDate();
  const endDay = endDate.getUTCDate();
  const startYear = startDate.getUTCFullYear();
  const year = endDate.getUTCFullYear();
  if (startYear !== year) return `${startMonth} ${startDay}, ${startYear}-${endMonth} ${endDay}, ${year}`;
  return startMonth === endMonth
    ? `${startMonth} ${startDay}-${endDay}, ${year}`
    : `${startMonth} ${startDay}-${endMonth} ${endDay}, ${year}`;
}

function monthName(date: Date): string {
  return [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
  ][date.getUTCMonth()];
}

function isoWeekParts(date: Date): { year: number; week: number } {
  const utc = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  const day = utc.getUTCDay() || 7;
  utc.setUTCDate(utc.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(utc.getUTCFullYear(), 0, 1));
  const week = Math.ceil((((utc.getTime() - yearStart.getTime()) / 86400000) + 1) / 7);
  return { year: utc.getUTCFullYear(), week };
}

function ymd(date: Date): string {
  return date.toISOString().slice(0, 10);
}

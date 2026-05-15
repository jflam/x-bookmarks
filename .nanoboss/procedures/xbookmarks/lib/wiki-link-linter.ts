import { readFile } from "node:fs/promises";
import { dirname, join, normalize, resolve } from "node:path";

import { frontmatterString, parseFrontmatter } from "./frontmatter.ts";
import { ensureInsideRoot, fileExists, listMarkdownFiles, toPosixRelative, writeJson, writeTextAtomic } from "./fs.ts";
import { ignoredSourceIds, operationMarkdownFiles } from "./wiki-operations.ts";
import type { LintFinding, LintResult, LintWikiOptions, SelectedBookmark, WikiIngestPlan } from "./types.ts";

const WIKILINK_RE = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g;
const RAW_ALIAS_RE = /^(Ignored )?\d{2}-\d{2}-\d{2} @[A-Za-z0-9_]+: .+$/;
const REVIEW_RAW_ALIAS_RE = /^(captured bookmark|ignored bookmark)$/i;

export async function lintWiki(options: LintWikiOptions): Promise<LintResult> {
  const findings: LintFinding[] = [];
  const wikiRoot = join(options.config.managedRoot, "wiki");
  for (const file of await listMarkdownFiles(wikiRoot)) {
    await lintMarkdownFile(options.config.managedRoot, file, await readFile(file, "utf8"), findings, false);
  }

  if (options.plan) {
    for (const virtual of operationMarkdownFiles(options.plan)) {
      await lintMarkdownFile(options.config.managedRoot, virtual.file, virtual.markdown, findings, true);
    }
    lintIgnoredSources(options.plan, findings);
    lintPlanCompleteness(options.plan, options.selected ?? [], findings);
  }

  await lintSelectedSources(options.config.managedRoot, options.selected ?? [], findings, options.finalizationMode ?? "pre-move");
  await lintIndexAndLog(options.config.managedRoot, options.plan ? operationMarkdownFiles(options.plan) : [], findings);

  const result = toLintResult(findings);
  if (options.runId) {
    const lintJsonPath = join(options.config.artifactRoot, options.runId, "lint.json");
    const lintMdPath = join(options.config.artifactRoot, options.runId, "lint.md");
    await writeJson(lintJsonPath, result);
    await writeTextAtomic(lintMdPath, renderLintMarkdown(result));
    result.artifactPaths.push(lintJsonPath, lintMdPath);
  }
  return result;
}

async function lintMarkdownFile(
  managedRoot: string,
  file: string,
  markdown: string,
  findings: LintFinding[],
  virtual: boolean,
): Promise<void> {
  const lines = markdown.split(/\r?\n/);
  const relFile = file.startsWith("wiki/") ? file : toPosixRelative(managedRoot, file);
  if (relFile === "wiki/schema.md") return;
  let inFence = false;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim().startsWith("```")) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    WIKILINK_RE.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = WIKILINK_RE.exec(line)) !== null) {
      const target = match[1].trim();
      const alias = match[2]?.trim();
      const rawTarget = target.includes("raw/x/") || target.startsWith("../raw/x/") || target.startsWith("../../raw/x/");
      if (!rawTarget) continue;
      if (!alias) {
        push(findings, "raw-link-alias", "error", relFile, "Raw-source wikilink must use a readable alias.", index + 1);
      } else if (!isReadableRawAlias(relFile, alias)) {
        push(findings, "raw-link-alias-format", "error", relFile, `Raw-source alias is not readable enough: ${alias}`, index + 1);
      }
      if (
        !line.includes("![](https://x.com/")
        && !line.includes("![](https://twitter.com/")
        && !(relFile.startsWith("wiki/reviews/") && previousNonEmptyLine(lines, index).startsWith("![](https://"))
      ) {
        push(findings, "raw-link-x-embed", "error", relFile, "Raw-source citation must include an X URL embed on the same line.", index + 1);
      }
      if (alias && alias.includes("../")) {
        push(findings, "path-like-link-text", "error", relFile, "Human-visible raw-source alias must not render as a path.", index + 1);
      }
      if (relFile.startsWith("wiki/reviews/")) {
        lintReviewSourceTrailLine(relFile, lines, line, match, index, findings);
      } else if (!["wiki/home.md", "wiki/index.md", "wiki/log.md", "wiki/schema.md"].includes(relFile)) {
        lintWikiSourceBlock(relFile, line, target, match.index, index, findings);
      }
      if (target.includes("/inbox/")) {
        push(findings, "processed-source-inbox-citation", "warning", relFile, "Raw-source citation still points at raw/x/inbox.", index + 1);
      }
      if (!virtual) {
        const resolved = safeResolveObsidianTarget(managedRoot, relFile, target);
        if (!resolved) {
          push(findings, "raw-link-unsafe-target", "error", relFile, `Raw-source citation escapes the managed root: ${target}`, index + 1);
          continue;
        }
        if (!(await fileExists(resolved))) {
          push(findings, "raw-link-missing-target", "error", relFile, `Raw-source citation does not resolve: ${target}`, index + 1);
        }
      }
    }
  }

  if (
    isDurableWikiContentPage(relFile)
  ) {
    lintWikiPageFrontmatter(relFile, markdown, findings);
    lintWikiNarrativeSections(relFile, markdown, findings);
  }
  if (relFile.startsWith("wiki/reviews/")) {
    lintReviewVisibleDateRange(relFile, markdown, findings);
    await lintReviewSourceDateAlignment(managedRoot, relFile, markdown, findings);
  }
}

function isReadableRawAlias(relFile: string, alias: string): boolean {
  if (relFile.startsWith("wiki/reviews/") && REVIEW_RAW_ALIAS_RE.test(alias)) return true;
  return RAW_ALIAS_RE.test(alias);
}

function lintReviewSourceTrailLine(
  relFile: string,
  lines: string[],
  line: string,
  match: RegExpExecArray,
  index: number,
  findings: LintFinding[],
): void {
  if (/^\s*-\s+/.test(line)) {
    push(findings, "review-source-bullet-noise", "error", relFile, "Review raw-source bookmark links should not be bullet items.", index + 1);
  }
  const prefix = line.slice(0, match.index).trim();
  if (prefix) {
    push(findings, "review-source-label", "error", relFile, "Review raw-source links should use Captured bookmark or Ignored bookmark as the link alias, without duplicate label text.", index + 1);
  }
  const previous = previousNonEmptyLine(lines, index);
  if (!previous.startsWith("![](https://x.com/") && !previous.startsWith("![](https://twitter.com/")) {
    push(findings, "review-source-embed-missing", "error", relFile, "Review raw-source links should follow a standalone X embed.", index + 1);
  }
  const trailing = line.slice(match.index + match[0].length).trim();
  if (trailing && trailing !== ".") {
    push(findings, "review-source-trailing-text", "error", relFile, "Review raw-source lines should not repeat tweet text after the source link.", index + 1);
  }
  const nextLine = nextNonEmptyLine(lines, index);
  if (nextLine !== "Wiki entries:") {
    push(findings, "review-source-backlinks-missing", "error", relFile, "Review raw-source links should be followed by a Wiki entries backlink list.", index + 1);
  } else {
    const firstEntry = nextNonEmptyLine(lines, index + distanceToNextNonEmptyLine(lines, index));
    if (!firstEntry.startsWith("- ")) {
      push(findings, "review-source-backlinks-empty", "error", relFile, "Review Wiki entries list should include one item per line or - none.", index + 1);
    }
  }
}

function previousNonEmptyLine(lines: string[], index: number): string {
  for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
    const line = lines[cursor].trim();
    if (line) return line;
  }
  return "";
}

function nextNonEmptyLine(lines: string[], index: number): string {
  const distance = distanceToNextNonEmptyLine(lines, index);
  return distance > 0 ? lines[index + distance].trim() : "";
}

function distanceToNextNonEmptyLine(lines: string[], index: number): number {
  for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
    if (lines[cursor].trim()) return cursor - index;
  }
  return 0;
}

function lintWikiSourceBlock(
  relFile: string,
  line: string,
  target: string,
  matchIndex: number,
  index: number,
  findings: LintFinding[],
): void {
  if (/^\s*-\s+/.test(line)) {
    push(findings, "wiki-source-bullet-noise", "error", relFile, "Wiki source citations should be standalone embed blocks, not bullet items.", index + 1);
  }
  const prefix = line.slice(0, matchIndex)
    .replace(/!\[\]\(https?:\/\/(?:x|twitter)\.com\/[^)]*\/status\/[^)]*\)/g, "")
    .trim();
  if (prefix) {
    push(findings, "wiki-source-prefix-text", "error", relFile, "Wiki source citations should not be preceded by truncated tweet text on the same line.", index + 1);
  }
  const sourceId = target.split("#")[0].split("/").pop()?.replace(/\.md$/, "");
  if (!sourceId) return;
  const expected = `^x-${sourceId}`;
  if (!line.includes(expected)) {
    push(findings, "wiki-source-block-id-missing", "error", relFile, `Wiki source citation should include block id ${expected}.`, index + 1);
  }
}

function isDurableWikiContentPage(relFile: string): boolean {
  return [
    "wiki/concepts/",
    "wiki/tools/",
    "wiki/projects/",
    "wiki/questions/",
  ].some((prefix) => relFile.startsWith(prefix));
}

function lintReviewVisibleDateRange(file: string, markdown: string, findings: LintFinding[]): void {
  const { data } = parseFrontmatter(markdown);
  const start = frontmatterString(data, "period_start");
  const end = frontmatterString(data, "period_end");
  if (!start || !end) return;
  const expected = displayDateRange(start, end);
  if (expected && !markdown.includes(expected)) {
    push(findings, "review-date-range-missing", "error", file, `Review page should visibly include date range: ${expected}.`);
  }
}

async function lintReviewSourceDateAlignment(
  managedRoot: string,
  file: string,
  markdown: string,
  findings: LintFinding[],
): Promise<void> {
  const { data } = parseFrontmatter(markdown);
  const reviewMode = frontmatterString(data, "review_mode");
  const start = frontmatterString(data, "period_start");
  const end = frontmatterString(data, "period_end");
  if (!start || !end) return;
  const weeklyReviewFile = /^wiki\/reviews\/\d{4}-W\d{2}\.md$/.test(file);

  if (weeklyReviewFile && reviewMode === "backlog") {
    push(findings, "weekly-review-backlog-mode", "error", file, "Weekly review pages must review posts from that calendar week; use a non-weekly filename for backlog syntheses.");
    return;
  }

  if (!weeklyReviewFile && reviewMode === "backlog") {
    const sourceStart = frontmatterString(data, "source_period_start");
    const sourceEnd = frontmatterString(data, "source_period_end");
    if (!sourceStart || !sourceEnd) {
      push(findings, "review-backlog-source-range-missing", "error", file, "Backlog review pages must include source_period_start and source_period_end.");
      return;
    }
    const expected = displayDateRange(sourceStart, sourceEnd);
    if (expected && !markdown.includes(`Source dates: ${expected}`)) {
      push(findings, "review-backlog-source-range-hidden", "error", file, `Backlog review page should visibly include source dates: ${expected}.`);
    }
    return;
  }

  if (!weeklyReviewFile) return;

  const lines = markdown.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    WIKILINK_RE.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = WIKILINK_RE.exec(lines[index])) !== null) {
      const target = match[1].trim();
      if (!target.includes("raw/x/")) continue;
      const resolved = safeResolveObsidianTarget(managedRoot, file, target);
      if (!resolved || !(await fileExists(resolved))) continue;
      const raw = await readFile(resolved, "utf8");
      const createdAt = frontmatterString(parseFrontmatter(raw).data, "created_at")?.slice(0, 10);
      if (!createdAt) continue;
      if (createdAt < start || createdAt > end) {
        push(
          findings,
          "review-source-date-out-of-range",
          "error",
          file,
          `Source ${target} was posted ${createdAt}, outside review range ${start} to ${end}. Weekly review pages must contain posts authored during that calendar week.`,
          index + 1,
        );
      }
    }
  }
}

function displayDateRange(start: string, end: string): string {
  const startDate = new Date(`${start}T00:00:00.000Z`);
  const endDate = new Date(`${end}T00:00:00.000Z`);
  if (!Number.isFinite(startDate.getTime()) || !Number.isFinite(endDate.getTime())) return "";
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

function lintWikiPageFrontmatter(file: string, markdown: string, findings: LintFinding[]): void {
  const { data } = parseFrontmatter(markdown);
  for (const key of ["type", "status", "created", "updated", "source_count"]) {
    if (frontmatterString(data, key) === undefined) {
      push(findings, "wiki-frontmatter", "warning", file, `Wiki page frontmatter is missing ${key}.`);
    }
  }
}

function lintWikiNarrativeSections(file: string, markdown: string, findings: LintFinding[]): void {
  const summary = extractSection(markdown, "Summary");
  if (!summary) {
    push(findings, "wiki-summary-missing", "warning", file, "Wiki page should include a narrative ## Summary section.");
  } else {
    if (sectionHasSourceCitation(summary.body)) {
      push(
        findings,
        "wiki-summary-source-block",
        "error",
        file,
        "Wiki page Summary should contain synthesis only; move raw-source citation blocks to an evidence section.",
        summary.line,
      );
    }
    if (!hasNarrativeProse(summary.body)) {
      push(
        findings,
        "wiki-summary-narrative-missing",
        "error",
        file,
        "Wiki page Summary must contain narrative synthesis, not only raw-source citation blocks.",
        summary.line,
      );
    }
  }

  const notes = extractSection(markdown, "Notes");
  if (notes && sectionHasSourceCitation(notes.body)) {
    if (!hasNarrativeProse(notes.body)) {
      push(
        findings,
        "wiki-notes-source-dump",
        "error",
        file,
        "Wiki page Notes should contain interpretation or review guidance, not only unannotated source blocks.",
        notes.line,
      );
    }
    push(
      findings,
      "wiki-notes-source-block",
      "error",
      file,
      "Wiki page Notes should not contain raw-source citation blocks; move them to an evidence section.",
      notes.line,
    );
  }
}

function extractSection(markdown: string, heading: string): { body: string; line: number } | undefined {
  const lines = markdown.split(/\r?\n/);
  const headingRe = new RegExp(`^##\\s+${escapeRegExp(heading)}\\s*$`, "i");
  for (let index = 0; index < lines.length; index += 1) {
    if (!headingRe.test(lines[index].trim())) continue;
    const body: string[] = [];
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      if (/^##\s+/.test(lines[cursor])) break;
      body.push(lines[cursor]);
    }
    return { body: body.join("\n"), line: index + 1 };
  }
  return undefined;
}

function hasNarrativeProse(sectionBody: string): boolean {
  const prose = sectionBody
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !isRawSourceOnlyLine(line))
    .map((line) => line
      .replace(/!\[\]\(https?:\/\/(?:x|twitter)\.com\/[^)]*\/status\/[^)]*\)/g, " ")
      .replace(/\[\[[^\]]+\]\]/g, " ")
      .replace(/\^[A-Za-z0-9_-]+/g, " ")
      .replace(/^[#>*\-\d.)\s]+/, " ")
      .trim())
    .filter(Boolean)
    .join(" ");
  return (prose.match(/[A-Za-z][A-Za-z'-]+/g) ?? []).length >= 5;
}

function sectionHasSourceCitation(sectionBody: string): boolean {
  return /!\[\]\(https?:\/\/(?:x|twitter)\.com\/[^)]*\/status\/[^)]*\)/.test(sectionBody)
    || /\[\[[^\]]*raw\/x\/[^\]]+\]\]/.test(sectionBody);
}

function isRawSourceOnlyLine(line: string): boolean {
  const withoutSourceSyntax = line
    .replace(/!\[\]\(https?:\/\/(?:x|twitter)\.com\/[^)]*\/status\/[^)]*\)/g, " ")
    .replace(/\[\[[^\]]*raw\/x\/[^\]]+\]\]/g, " ")
    .replace(/\^[A-Za-z0-9_-]+/g, " ")
    .replace(/^[>*\-\d.)\s]+/, " ")
    .trim();
  return sectionHasSourceCitation(line) && withoutSourceSyntax.length === 0;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function lintSelectedSources(
  managedRoot: string,
  selected: SelectedBookmark[],
  findings: LintFinding[],
  finalizationMode: "pre-move" | "post-move",
): Promise<void> {
  if (finalizationMode !== "post-move") return;
  for (const source of selected) {
    const inboxPath = join(managedRoot, "raw", "x", "inbox", `${source.sourceId}.md`);
    const ingestedPath = join(managedRoot, "raw", "x", "ingested", `${source.sourceId}.md`);
    const ignoredPath = join(managedRoot, "raw", "x", "ignored", `${source.sourceId}.md`);
    const path = (await fileExists(ingestedPath)) ? ingestedPath : (await fileExists(ignoredPath)) ? ignoredPath : inboxPath;
    if (await fileExists(inboxPath)) {
      push(findings, "processed-source-left-in-inbox", "error", toPosixRelative(managedRoot, inboxPath), "Processed source remains in raw/x/inbox.");
      continue;
    }
    if (!(await fileExists(path))) {
      push(findings, "processed-source-missing", "error", toPosixRelative(managedRoot, path), "Processed source was not found after finalization.");
      continue;
    }
    const status = frontmatterString(parseFrontmatter(await readFile(path, "utf8")).data, "status");
    if (status !== "ingested" && status !== "ignored") {
      push(findings, "processed-source-status", "error", toPosixRelative(managedRoot, path), "Moved raw source must have status ingested or ignored.");
    }
  }
}

function lintIgnoredSources(plan: WikiIngestPlan, findings: LintFinding[]): void {
  for (const operation of plan.operations) {
    if (operation.kind === "ignore_source" && !operation.reason?.trim()) {
      push(findings, "ignored-source-reason", "error", "wiki/log.md", `Ignored source ${operation.sourceId ?? ""} lacks a reason.`);
    }
  }
  for (const sourceId of ignoredSourceIds(plan)) {
    if (!sourceId.trim()) push(findings, "ignored-source-id", "error", "wiki/log.md", "Ignored source id is empty.");
  }
}

function lintPlanCompleteness(plan: WikiIngestPlan, selected: SelectedBookmark[], findings: LintFinding[]): void {
  if (selected.length === 0) return;
  const operations = plan.operations;
  const pageOps = operations.filter((operation) =>
    operation.kind === "create_page" || operation.kind === "update_page"
  );
  const durablePageOps = pageOps.filter((operation) => !operation.path.startsWith("wiki/index"));
  const selectedIds = new Set(selected.map((item) => item.sourceId));

  if (!operations.some((operation) => operation.kind === "append_log")) {
    push(findings, "wiki-log-entry-missing", "error", "wiki/log.md", "Plan must append a structured wiki/log.md entry.");
  }
  if (durablePageOps.length > 0 && !operations.some((operation) =>
    "path" in operation && operation.path.replace(/^\.\//, "").startsWith("wiki/index")
  )) {
    push(findings, "wiki-index-update-missing", "error", "wiki/index.md", "Durable page changes must update wiki/index.md.");
  }
  if (durablePageOps.length > 0 && !operations.some((operation) => operation.kind === "update_map")) {
    push(findings, "wiki-map-update-missing", "error", "wiki/maps", "Durable page changes must update at least one map.");
  }
  if (!operations.some((operation) => operation.kind === "update_review")) {
    push(findings, "weekly-review-update-missing", "error", "wiki/reviews", "Plan must update the weekly review surface.");
  }

  const logMarkdown = operations
    .filter((operation) => operation.kind === "append_log")
    .map((operation) => operation.markdown)
    .join("\n");
  for (const sourceId of selectedIds) {
    if (!logMarkdown.includes(sourceId)) {
      push(findings, "wiki-log-source-missing", "error", "wiki/log.md", `wiki/log.md entry must mention selected source ${sourceId}.`);
    }
  }

  const reviewMarkdown = operations
    .filter((operation) => operation.kind === "update_review")
    .map((operation) => operation.markdown)
    .join("\n");
  if (reviewMarkdown && !/Source Trail/i.test(reviewMarkdown)) {
    push(findings, "weekly-review-source-trail-missing", "error", "wiki/reviews", "Weekly review update must include a Source Trail section.");
  }
  for (const sourceId of selectedIds) {
    if (reviewMarkdown && !reviewMarkdown.includes(sourceId)) {
      push(findings, "weekly-review-source-missing", "error", "wiki/reviews", `Weekly review Source Trail must mention selected source ${sourceId}.`);
    }
  }
}

async function lintIndexAndLog(
  managedRoot: string,
  virtualFiles: Array<{ file: string; markdown: string }>,
  findings: LintFinding[],
): Promise<void> {
  const indexPath = join(managedRoot, "wiki", "index.md");
  const logPath = join(managedRoot, "wiki", "log.md");
  if (!(await fileExists(indexPath)) && !virtualFiles.some((file) => file.file === "wiki/index.md")) {
    push(findings, "wiki-index-missing", "error", "wiki/index.md", "wiki/index.md is missing.");
  }
  if (!(await fileExists(logPath)) && !virtualFiles.some((file) => file.file === "wiki/log.md")) {
    push(findings, "wiki-log-missing", "error", "wiki/log.md", "wiki/log.md is missing.");
  }
}

function resolveObsidianTarget(managedRoot: string, fromRelFile: string, target: string): string {
  const withoutHeading = target.split("#")[0];
  const withExtension = withoutHeading.endsWith(".md") ? withoutHeading : `${withoutHeading}.md`;
  const base = join(managedRoot, fromRelFile.startsWith("wiki/") ? fromRelFile : toPosixRelative(managedRoot, fromRelFile));
  const candidate = normalize(join(dirname(base), withExtension));
  return ensureInsideRoot(managedRoot, resolve(candidate), "wikilink target");
}

function safeResolveObsidianTarget(managedRoot: string, fromRelFile: string, target: string): string | undefined {
  try {
    return resolveObsidianTarget(managedRoot, fromRelFile, target);
  } catch {
    return undefined;
  }
}

function toLintResult(findings: LintFinding[]): LintResult {
  const errorCount = findings.filter((finding) => finding.severity === "error").length;
  const warningCount = findings.filter((finding) => finding.severity === "warning").length;
  return {
    ok: errorCount === 0,
    errorCount,
    warningCount,
    findings,
    artifactPaths: [],
  };
}

function renderLintMarkdown(result: LintResult): string {
  if (result.findings.length === 0) return "# X Bookmarks Wiki Lint\n\nNo findings.\n";
  return [
    "# X Bookmarks Wiki Lint",
    "",
    `Errors: ${result.errorCount}`,
    `Warnings: ${result.warningCount}`,
    "",
    ...result.findings.map((finding) => (
      `- ${finding.severity.toUpperCase()} ${finding.ruleId} ${finding.file}${finding.line ? `:${finding.line}` : ""} - ${finding.message}`
    )),
    "",
  ].join("\n");
}

function push(
  findings: LintFinding[],
  ruleId: string,
  severity: "error" | "warning",
  file: string,
  message: string,
  line?: number,
): void {
  findings.push({ ruleId, severity, file, message, line });
}

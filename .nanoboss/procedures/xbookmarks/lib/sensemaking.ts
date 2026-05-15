import { Database } from "bun:sqlite";
import { mkdir, readFile } from "node:fs/promises";
import { basename, isAbsolute, join, resolve } from "node:path";

import { parseFrontmatter } from "./frontmatter.ts";
import { ensureInsideRoot, fileExists, listMarkdownFiles, readTextIfExists, toPosixRelative, writeJson, writeTextAtomic } from "./fs.ts";
import {
  buildInterestMapEntries,
  buildPriorDecisionContext,
  cleanGeneratedText,
  ensureInterestMapTables,
  inferredInterestsFromActions,
  parseInterestMapMarkdown,
  parseJsonArray,
  renderInterestMap,
  upsertInterestMapEntries,
  verifyInterestMap,
  usefulInterestName,
} from "./interest-map.ts";
import type { BaselineBuildResult, KbSensemakingDecision, MatchedInterest, NonObviousConnection, SelectedBookmark, SensemakingAction, XBookmarksConfig } from "./types.ts";

const ACTION_KINDS = new Set([
  "create_new_page",
  "add_evidence_to_page",
  "create_or_update_open_question",
  "defer_for_media_inspection",
  "ignore_low_signal",
]);

export function normalizeSensemakingDecision(value: KbSensemakingDecision, sourceId: string): KbSensemakingDecision {
  const raw = value as unknown as Record<string, unknown>;
  const source = recordValue(raw.source_understanding);
  const actions = arrayValue(raw.actions).map(normalizeAction).filter((action): action is SensemakingAction => action !== undefined);
  const matched = arrayValue(raw.matched_interests).map(normalizeMatchedInterest).filter((item) => usefulInterestName(item.interest));
  return {
    source_understanding: {
      source_id: stringValue(source.source_id) ?? sourceId,
      source_kind: stringValue(source.source_kind) ?? "x_bookmark",
      main_claims: stringArrayValue(source.main_claims).map(cleanGeneratedText).filter(Boolean),
      examples: stringArrayValue(source.examples).map(cleanGeneratedText).filter(Boolean),
      people_or_orgs: stringArrayValue(source.people_or_orgs),
      domains: stringArrayValue(source.domains),
      uncertainties: stringArrayValue(source.uncertainties).map(cleanGeneratedText).filter(Boolean),
      requires_media_inspection: booleanValue(source.requires_media_inspection),
    },
    why_saved: cleanGeneratedText(stringValue(raw.why_saved) ?? "I do not know why this was saved."),
    matched_interests: matched.length > 0 ? matched : inferredInterestsFromActions(actions, stringValue(raw.why_saved)),
    non_obvious_connections: arrayValue(raw.non_obvious_connections).map(normalizeConnection).filter((item) => item.connection),
    durable_takeaways: stringArrayValue(raw.durable_takeaways).map(cleanGeneratedText).filter(Boolean),
    candidate_pages: stringArrayValue(raw.candidate_pages),
    actions,
    confidence: confidenceValue(raw.confidence),
    defer_reason: stringValue(raw.defer_reason),
  };
}

export async function readSourceForSensemaking(config: XBookmarksConfig, source: string): Promise<SelectedBookmark> {
  const rawPath = resolveSourcePath(config.managedRoot, source);
  return readSelectedBookmarkAt(rawPath);
}

export async function readSelectedBookmarkAt(rawPath: string): Promise<SelectedBookmark> {
  const markdown = await readFile(rawPath, "utf8");
  const { data, body } = parseFrontmatter(markdown);
  const tweetId = stringField(data, "tweet_id") ?? basename(rawPath, ".md");
  const author = stringField(data, "author_username");
  const title = /^#\s+(.+)$/m.exec(body)?.[1]?.trim() ?? `X Bookmark ${tweetId}`;
  return {
    sourceId: tweetId,
    rawPath,
    tweetId,
    title,
    contentHash: "",
    authorHandle: author || undefined,
    postedAt: stringField(data, "created_at"),
    exportedAt: stringField(data, "bookmarked_at"),
    canonicalUrl: stringField(data, "canonical_url") || stringField(data, "twitter_url"),
  };
}

export async function buildSensemakingPromptContext(config: XBookmarksConfig, selected: SelectedBookmark, options?: { interestMapMarkdown?: string }) {
  const sourceMarkdown = await readFile(selected.rawPath, "utf8");
  const interestMapPath = join(config.managedRoot, "wiki", "meta", "interest-map.md");
  const interestMapMarkdown = options?.interestMapMarkdown ?? await readTextIfExists(interestMapPath);
  const candidatePages = await candidatePagesForSource(config.managedRoot, selected, sourceMarkdown);
  const priorDecisionContext = config.databasePath
    ? await buildPriorDecisionContext(config, selected, interestMapMarkdown, 12)
    : undefined;
  return { sourceMarkdown, interestMapMarkdown, candidatePages, priorDecisionContext };
}

export async function applySensemakingDecision(params: {
  config: XBookmarksConfig;
  selected: SelectedBookmark;
  decision: KbSensemakingDecision;
  dryRun: boolean;
  runId: string;
}): Promise<{ previewPath: string; renderedPath?: string; stored: boolean }> {
  const runPath = join(params.config.artifactRoot, params.runId);
  await mkdir(runPath, { recursive: true });
  const previewPath = join(runPath, `${params.selected.sourceId}-sensemaking-decision.md`);
  const rendered = renderIngestDecision(params.selected, params.decision);
  await writeTextAtomic(previewPath, rendered);
  await writeJson(join(runPath, `${params.selected.sourceId}-sensemaking-decision.json`), params.decision);

  if (params.dryRun) return { previewPath, stored: false };

  const markdown = await readFile(params.selected.rawPath, "utf8");
  await writeTextAtomic(params.selected.rawPath, replaceIngestDecisionSection(markdown, rendered));
  storeDecision(params.config, params.selected, params.decision);
  return { previewPath, renderedPath: params.selected.rawPath, stored: true };
}

export function renderIngestDecision(selected: SelectedBookmark, decision: KbSensemakingDecision): string {
  const matched = decision.matched_interests.length
    ? decision.matched_interests.map((item) => `[[${item.interest}]] (${item.confidence})`).join(", ")
    : "none";
  const connections = decision.non_obvious_connections.length
    ? decision.non_obvious_connections.map((item) => item.connection).join("; ")
    : "none";
  const actions = decision.actions.length
    ? decision.actions.map(renderAction).join("; ")
    : "none";
  return [
    "## Ingest Decision",
    "",
    `- Why likely saved: ${decision.why_saved || "I do not know why this was saved."}`,
    `- Matched interests: ${matched}`,
    `- Non-obvious connections: ${connections}`,
    `- Actions taken: ${actions}`,
    `- Confidence: ${decision.confidence}`,
    decision.defer_reason ? `- Defer reason: ${decision.defer_reason}` : undefined,
    "",
    "### Source Understanding",
    "",
    ...decision.source_understanding.main_claims.map((claim) => `- ${claim}`),
    decision.source_understanding.uncertainties.length ? "" : undefined,
    ...decision.source_understanding.uncertainties.map((uncertainty) => `- Uncertainty: ${uncertainty}`),
    "",
    "### Durable Takeaways",
    "",
    ...(decision.durable_takeaways.length ? decision.durable_takeaways.map((takeaway) => `- ${takeaway}`) : ["- None recorded."]),
    "",
    `^x-${selected.sourceId}-ingest-decision`,
    "",
  ].filter((line): line is string => line !== undefined).join("\n");
}

export function replaceIngestDecisionSection(markdown: string, renderedDecision: string): string {
  const lines = markdown.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === "## Ingest Decision");
  if (start < 0) return `${markdown.trimEnd()}\n\n${renderedDecision}`;
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^##\s+/.test(lines[index])) {
      end = index;
      break;
    }
  }
  return `${[...lines.slice(0, start), renderedDecision.trimEnd(), ...lines.slice(end)].join("\n").trimEnd()}\n`;
}

export function storeDecision(config: XBookmarksConfig, selected: SelectedBookmark, decision: KbSensemakingDecision): void {
  if (!config.databasePath) throw new Error("Cannot store decision because databasePath is not configured.");
  const db = new Database(config.databasePath);
  db.run(`
    CREATE TABLE IF NOT EXISTS kb_ingest_decisions (
      source_id TEXT PRIMARY KEY,
      raw_path TEXT NOT NULL,
      status TEXT NOT NULL,
      why_saved TEXT,
      matched_interests_json TEXT,
      non_obvious_connections_json TEXT,
      candidate_pages_json TEXT,
      actions_json TEXT,
      confidence TEXT,
      defer_reason TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  `);
  const now = new Date().toISOString();
  db.query(`
    INSERT INTO kb_ingest_decisions (
      source_id, raw_path, status, why_saved, matched_interests_json,
      non_obvious_connections_json, candidate_pages_json, actions_json,
      confidence, defer_reason, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(source_id) DO UPDATE SET
      raw_path = excluded.raw_path,
      status = excluded.status,
      why_saved = excluded.why_saved,
      matched_interests_json = excluded.matched_interests_json,
      non_obvious_connections_json = excluded.non_obvious_connections_json,
      candidate_pages_json = excluded.candidate_pages_json,
      actions_json = excluded.actions_json,
      confidence = excluded.confidence,
      defer_reason = excluded.defer_reason,
      updated_at = excluded.updated_at
  `).run(
    selected.sourceId,
    toPosixRelative(config.managedRoot, selected.rawPath),
    decisionStatus(decision),
    decision.why_saved,
    JSON.stringify(decision.matched_interests),
    JSON.stringify(decision.non_obvious_connections),
    JSON.stringify(decision.candidate_pages),
    JSON.stringify(decision.actions),
    decision.confidence,
    decision.defer_reason ?? null,
    now,
    now,
  );
  db.close();
}

export async function refreshInterestMap(config: XBookmarksConfig, revisionLabel: string): Promise<string> {
  if (!config.databasePath) throw new Error("Cannot refresh interest map because databasePath is not configured.");
  const db = new Database(config.databasePath);
  const rows = db.query(`
    SELECT source_id, raw_path, status, why_saved, matched_interests_json, non_obvious_connections_json, actions_json, confidence, defer_reason
    FROM kb_ingest_decisions
    ORDER BY source_id
  `).all() as Array<Record<string, string | null>>;
  const mapPath = join(config.managedRoot, "wiki", "meta", "interest-map.md");
  const existing = parseInterestMapMarkdown(await readTextIfExists(mapPath));
  const rawPathBySourceId = new Map(rows.map((row) => [String(row.source_id), String(row.raw_path)]));
  const built = buildInterestMapEntries(rows.map((row) => ({
    source_id: String(row.source_id),
    raw_path: String(row.raw_path),
    status: String(row.status),
    why_saved: row.why_saved,
    matched_interests_json: row.matched_interests_json,
    non_obvious_connections_json: row.non_obvious_connections_json,
    actions_json: row.actions_json,
    confidence: row.confidence,
    defer_reason: row.defer_reason,
  })), existing);
  const markdown = renderInterestMap({
    generatedAt: new Date().toISOString(),
    revisionLabel,
    sourceCount: rows.length,
    entries: built.entries,
    recurringQuestions: built.recurringQuestions,
    deferredMediaInspection: built.deferredMediaInspection,
    rawPathBySourceId,
  });
  await writeTextAtomic(mapPath, markdown);
  ensureInterestMapTables(db);
  upsertInterestMapEntries(db, built.entries);
  db.query(`
    INSERT INTO kb_interest_map_revisions (revision_label, markdown_path, summary_json, source_count, created_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(revisionLabel, toPosixRelative(config.managedRoot, mapPath), JSON.stringify(built.summary), rows.length, new Date().toISOString());
  db.close();
  const verify = await verifyInterestMap(config, `interest-map-refresh-${revisionLabel}`);
  if (!verify.ok) throw new Error(`Interest map verifier failed after refresh: ${verify.errorCount} error(s). See ${verify.artifactPaths.join(", ")}`);
  return mapPath;
}

export async function writeBaselineRunReport(params: {
  config: XBookmarksConfig;
  runId: string;
  result: BaselineBuildResult;
  modelConfiguration: string;
}): Promise<string> {
  const path = join(params.config.artifactRoot, params.runId, "baseline-run-report.md");
  const result = params.result;
  await writeTextAtomic(path, [
    "# Interest-Aware Bookmark Sensemaking Baseline Report",
    "",
    `Generated: ${new Date().toISOString()}`,
    `Mode: ${result.dryRun ? "dry-run" : "apply"}`,
    `Split: ${result.splitPath}`,
    `Sources selected: ${result.selectedSourceIds.length}`,
    `Sources processed: ${result.processedSourceIds.length}`,
    "Semantic pages created: 0",
    "Semantic pages updated: 0",
    `Decisions stored: ${result.decisionsStored}`,
    `Sources ignored: ${result.sourcesIgnored.length}`,
    `Sources deferred for media inspection: ${result.sourcesDeferredForMediaInspection.length}`,
    `Average confidence: ${result.averageConfidence}`,
    `Interest map: ${result.interestMapPath ?? "not written"}`,
    `Prompt/model configuration: ${params.modelConfiguration}`,
    "",
    "## Selected Sources",
    "",
    ...result.selectedSourceIds.map((id) => `- ${id}`),
    "",
  ].join("\n"));
  return path;
}

export async function sourcePathForId(managedRoot: string, sourceId: string): Promise<string> {
  for (const bucket of ["inbox", "ingested", "ignored"]) {
    const path = join(managedRoot, "raw", "x", bucket, `${sourceId}.md`);
    if (await fileExists(path)) return path;
  }
  return join(managedRoot, "raw", "x", "inbox", `${sourceId}.md`);
}

function resolveSourcePath(managedRoot: string, source: string): string {
  const path = isAbsolute(source) ? resolve(source) : resolve(managedRoot, source);
  return ensureInsideRoot(managedRoot, path, "sensemaking source");
}

async function candidatePagesForSource(managedRoot: string, selected: SelectedBookmark, sourceMarkdown: string): Promise<Array<{ path: string; title?: string; excerpt?: string }>> {
  const wikiRoot = join(managedRoot, "wiki");
  const terms = new Set((`${selected.title} ${selected.authorHandle ?? ""} ${sourceMarkdown}`).toLowerCase().match(/[a-z0-9][a-z0-9_-]{4,}/g) ?? []);
  const pages: Array<{ path: string; score: number; title?: string; excerpt?: string }> = [];
  for (const file of await listMarkdownFiles(wikiRoot)) {
    const rel = toPosixRelative(managedRoot, file);
    if (rel === "wiki/index.md" || rel === "wiki/log.md" || rel.endsWith("/interest-map.md")) continue;
    const content = await readTextIfExists(file);
    const lower = content.toLowerCase();
    const matches = [...terms].filter((term) => lower.includes(term));
    if (matches.length === 0) continue;
    pages.push({
      path: rel,
      score: matches.length,
      title: /^#\s+(.+)$/m.exec(content)?.[1]?.trim(),
      excerpt: content.split(/\r?\n/).find((line) => line.trim() && !line.startsWith("---") && !line.startsWith("#"))?.slice(0, 240),
    });
  }
  return pages.sort((a, b) => b.score - a.score || a.path.localeCompare(b.path)).slice(0, 20).map(({ score: _score, ...page }) => page);
}

function renderAction(action: SensemakingAction): string {
  return [action.kind, action.page, action.title].filter(Boolean).join(" ");
}

function decisionStatus(decision: KbSensemakingDecision): string {
  if (decision.source_understanding.requires_media_inspection || decision.actions.some((action) => action.kind === "defer_for_media_inspection")) {
    return "deferred_media_inspection";
  }
  if (decision.actions.some((action) => action.kind === "ignore_low_signal")) return "ignored_low_signal";
  return "processed";
}

function normalizeMatchedInterest(value: unknown): MatchedInterest {
  const record = recordValue(value);
  return {
    interest: stringValue(record.interest) ?? "",
    evidence: cleanGeneratedText(stringValue(record.evidence) ?? ""),
    confidence: confidenceValue(record.confidence),
  };
}

function normalizeConnection(value: unknown): NonObviousConnection {
  const record = recordValue(value);
  return {
    connection: cleanGeneratedText(stringValue(record.connection) ?? ""),
    related_pages: stringArrayValue(record.related_pages),
  };
}

function normalizeAction(value: unknown): SensemakingAction | undefined {
  const record = recordValue(value);
  const kind = stringValue(record.kind);
  if (!kind || !ACTION_KINDS.has(kind)) return undefined;
  return {
    kind: kind as SensemakingAction["kind"],
    page: stringValue(record.page),
    title: stringValue(record.title),
    summary: cleanOptionalText(record.summary),
    evidence: cleanOptionalText(record.evidence),
  };
}

function recordValue(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringField(data: Record<string, unknown>, key: string): string | undefined {
  const value = data[key];
  return typeof value === "string" ? value : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function stringArrayValue(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

function booleanValue(value: unknown): boolean {
  return value === true;
}

function confidenceValue(value: unknown): "low" | "medium" | "high" {
  return value === "high" || value === "medium" || value === "low" ? value : "medium";
}

function cleanOptionalText(value: unknown): string | undefined {
  const text = stringValue(value);
  return text ? cleanGeneratedText(text) : undefined;
}

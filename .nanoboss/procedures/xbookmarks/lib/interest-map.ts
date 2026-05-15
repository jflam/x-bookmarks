import { Database } from "bun:sqlite";
import { mkdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

import { parseFrontmatter } from "./frontmatter.ts";
import { fileExists, readTextIfExists, writeJson, writeTextAtomic } from "./fs.ts";
import type { MatchedInterest, NonObviousConnection, SensemakingAction, SelectedBookmark, XBookmarksConfig } from "./types.ts";

export type InterestStatus = "active" | "emerging" | "deprecated";

export interface InterestMapEntry {
  interestId: string;
  name: string;
  status: InterestStatus;
  description: string;
  aliases: string[];
  parentInterestId?: string;
  relatedInterestIds: string[];
  exampleSources: string[];
  sourceCount: number;
  manuallySeeded: boolean;
  signals: string[];
  confidence: Record<string, number>;
}

export interface ParsedInterestMap {
  entries: InterestMapEntry[];
  recurringQuestions: string[];
  deferredMediaInspection: Array<{ sourceId: string; reason: string }>;
  errors: string[];
}

export interface DecisionRow {
  source_id: string;
  raw_path: string;
  status: string;
  why_saved: string | null;
  matched_interests_json: string | null;
  non_obvious_connections_json?: string | null;
  candidate_pages_json?: string | null;
  actions_json: string | null;
  confidence: string | null;
  defer_reason: string | null;
}

export interface InterestMapVerifyResult {
  ok: boolean;
  errorCount: number;
  warningCount: number;
  findings: Array<{ severity: "error" | "warning"; ruleId: string; message: string; interestId?: string; sourceId?: string }>;
  artifactPaths: string[];
  summary: {
    interestCount: number;
    sourceCount: number;
    deferredMediaInspectionCount: number;
    recurringQuestionCount: number;
  };
}

export interface ReconcileResult {
  dryRun: boolean;
  parsedEntries: number;
  newInterestIds: string[];
  renamedInterestIds: string[];
  aliasChangedInterestIds: string[];
  deprecatedInterestIds: string[];
  invalidSourceLinks: string[];
  unsafeEntries: string[];
  applied: boolean;
}

export interface PriorDecisionContextItem {
  source_id: string;
  raw_path: string;
  markdown_link: string;
  status: string;
  why_saved: string;
  matched_interests: MatchedInterest[];
  non_obvious_connections: NonObviousConnection[];
  confidence: string;
  defer_reason?: string;
  score: number;
  reasons: string[];
}

export interface PriorDecisionContext {
  sourceId: string;
  limit: number;
  items: PriorDecisionContextItem[];
  markdown: string;
}

export function ensureInterestMapTables(db: Database): void {
  db.run(`
    CREATE TABLE IF NOT EXISTS kb_interest_map_entries (
      interest_id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      status TEXT NOT NULL,
      aliases_json TEXT,
      parent_interest_id TEXT,
      example_sources_json TEXT,
      source_count INTEGER NOT NULL DEFAULT 0,
      confidence_json TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  `);
  db.run(`
    CREATE TABLE IF NOT EXISTS kb_interest_map_revisions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      revision_label TEXT,
      markdown_path TEXT NOT NULL,
      summary_json TEXT,
      source_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    );
  `);
}

export function parseInterestMapMarkdown(markdown: string): ParsedInterestMap {
  const lines = markdown.split(/\r?\n/);
  const entries: InterestMapEntry[] = [];
  const recurringQuestions: string[] = [];
  const deferredMediaInspection: Array<{ sourceId: string; reason: string }> = [];
  const errors: string[] = [];
  let section = "";
  let current: { heading: string; fields: Map<string, string>; line: number } | undefined;

  const finish = () => {
    if (!current) return;
    const parsed = entryFromFields(current.heading, current.fields, current.line, errors);
    if (parsed) entries.push(parsed);
    current = undefined;
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const sectionMatch = /^##\s+(.+?)\s*$/.exec(line);
    if (sectionMatch) {
      finish();
      section = sectionMatch[1].trim();
      continue;
    }
    const headingMatch = /^###\s+(.+?)\s*$/.exec(line);
    if (headingMatch && interestSection(section)) {
      finish();
      current = { heading: headingMatch[1].trim(), fields: new Map(), line: index + 1 };
      continue;
    }
    if (current) {
      const fieldMatch = /^-\s+([^:]+):\s*(.*)$/.exec(line);
      if (fieldMatch) current.fields.set(normalizeFieldName(fieldMatch[1]), fieldMatch[2].trim());
      continue;
    }
    if (section === "Recurring Questions") {
      const item = /^-\s+(.+?)\s*$/.exec(line)?.[1]?.trim();
      if (item && !item.startsWith("_")) recurringQuestions.push(item);
    }
    if (section === "Deferred Media Inspection") {
      const item = /^-\s+([0-9]+):\s*(.+?)\s*$/.exec(line);
      if (item) deferredMediaInspection.push({ sourceId: item[1], reason: item[2] });
    }
  }
  finish();

  return {
    entries,
    recurringQuestions,
    deferredMediaInspection,
    errors,
  };
}

export function buildInterestMapEntries(rows: DecisionRow[], existing: ParsedInterestMap | undefined): {
  entries: InterestMapEntry[];
  recurringQuestions: string[];
  deferredMediaInspection: Array<{ sourceId: string; reason: string }>;
  summary: Record<string, unknown>;
} {
  const existingById = new Map(existing?.entries.map((entry) => [entry.interestId, entry]) ?? []);
  const existingByName = new Map<string, InterestMapEntry>();
  for (const entry of existing?.entries ?? []) {
    existingByName.set(normalizeLookup(entry.name), entry);
    for (const alias of entry.aliases) existingByName.set(normalizeLookup(alias), entry);
  }

  const grouped = new Map<string, Array<{ sourceId: string; rawPath: string; why: string; match: MatchedInterest; confidence: string }>>();
  const recurringQuestions = new Set(existing?.recurringQuestions ?? []);
  const deferredMediaInspection: Array<{ sourceId: string; reason: string }> = [];

  for (const row of rows) {
    const actions = parseJsonArray<SensemakingAction>(row.actions_json);
    const storedMatches = parseJsonArray<MatchedInterest>(row.matched_interests_json).filter((item) => usefulInterestName(item.interest));
    const matches = storedMatches.length > 0 ? storedMatches : inferredInterestsFromActions(actions, String(row.why_saved ?? ""));
    for (const match of matches) {
      const existingEntry = existingByName.get(normalizeLookup(match.interest)) ?? existingById.get(slugifyInterest(match.interest));
      const interestId = existingEntry?.interestId ?? slugifyInterest(match.interest);
      const items = grouped.get(interestId) ?? [];
      items.push({
        sourceId: String(row.source_id),
        rawPath: String(row.raw_path),
        why: String(row.why_saved ?? ""),
        match,
        confidence: String(row.confidence ?? match.confidence ?? "medium"),
      });
      grouped.set(interestId, items);
    }
    for (const action of actions) {
      if (action.kind === "create_or_update_open_question" && action.title) recurringQuestions.add(action.title);
    }
    if (row.status === "deferred_media_inspection" && row.defer_reason) {
      deferredMediaInspection.push({ sourceId: String(row.source_id), reason: cleanGeneratedText(row.defer_reason) });
    }
  }

  const entries = [...grouped.entries()].map(([interestId, items]) => {
    const existingEntry = existingById.get(interestId);
    const first = items[0];
    const name = existingEntry?.name || titleCaseInterest(first?.match.interest ?? interestId);
    const confidence = countBy(items.map((item) => item.match.confidence || item.confidence || "medium"));
    const sourceCount = unique(items.map((item) => item.sourceId)).length;
    const status = existingEntry?.manuallySeeded
      ? existingEntry.status
      : sourceCount <= 1
        ? "emerging"
        : existingEntry?.status ?? "active";
    return {
      interestId,
      name,
      status,
      description: existingEntry?.description || cleanGeneratedText(first?.match.evidence || first?.why || "Inferred from baseline sources."),
      aliases: existingEntry?.aliases ?? [],
      parentInterestId: existingEntry?.parentInterestId,
      relatedInterestIds: existingEntry?.relatedInterestIds ?? [],
      exampleSources: unique(items.map((item) => item.sourceId)).slice(0, 5),
      sourceCount,
      manuallySeeded: existingEntry?.manuallySeeded ?? false,
      signals: unique(items.map((item) => compactInterestMapSignal(item.why || item.match.evidence)).filter(Boolean)).slice(0, 3),
      confidence,
    } satisfies InterestMapEntry;
  }).sort((a, b) => b.sourceCount - a.sourceCount || a.interestId.localeCompare(b.interestId));

  for (const entry of existing?.entries ?? []) {
    if (!grouped.has(entry.interestId) && entry.manuallySeeded) entries.push(entry);
  }

  return {
    entries,
    recurringQuestions: [...recurringQuestions].sort(),
    deferredMediaInspection,
    summary: revisionSummary(rows.length, entries, recurringQuestions.size, deferredMediaInspection.length),
  };
}

export function renderInterestMap(params: {
  generatedAt: string;
  revisionLabel: string;
  sourceCount: number;
  entries: InterestMapEntry[];
  recurringQuestions: string[];
  deferredMediaInspection: Array<{ sourceId: string; reason: string }>;
  rawPathBySourceId: Map<string, string>;
}): string {
  return [
    "# Interest Map",
    "",
    `Generated: ${params.generatedAt}`,
    `Revision: ${params.revisionLabel}`,
    `Sources with decisions: ${params.sourceCount}`,
    "",
    "## Core Interests",
    "",
    ...(params.entries.length ? params.entries.flatMap((entry) => renderInterestEntry(entry, params.rawPathBySourceId)) : ["_No matched interests recorded yet._", ""]),
    "## Recurring Questions",
    "",
    ...(params.recurringQuestions.length ? params.recurringQuestions.map((question) => `- ${question}`) : ["_No recurring questions recorded yet._"]),
    "",
    "## People And Organizations",
    "",
    "_Derived people and organization clustering is reserved for inspection after the baseline run._",
    "",
    "## Tools And Technical Stacks",
    "",
    "_Tool-specific interests are represented as stable entries above when they have source evidence._",
    "",
    "## Aesthetic And Product Preferences",
    "",
    "_No explicit aesthetic/product preference cluster has been promoted yet._",
    "",
    "## Recently Emerging Interests",
    "",
    "_Emerging interests are marked with `Status: emerging` in the core list until they have enough evidence._",
    "",
    "## Deferred Media Inspection",
    "",
    ...(params.deferredMediaInspection.length
      ? params.deferredMediaInspection.map((item) => `- ${item.sourceId}: ${item.reason}`)
      : ["_No sources deferred for media inspection yet._"]),
    "",
  ].join("\n");
}

export function upsertInterestMapEntries(db: Database, entries: InterestMapEntry[]): void {
  ensureInterestMapTables(db);
  const now = new Date().toISOString();
  const query = db.query(`
    INSERT INTO kb_interest_map_entries (
      interest_id, name, description, status, aliases_json, parent_interest_id,
      example_sources_json, source_count, confidence_json, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(interest_id) DO UPDATE SET
      name = excluded.name,
      description = excluded.description,
      status = excluded.status,
      aliases_json = excluded.aliases_json,
      parent_interest_id = excluded.parent_interest_id,
      example_sources_json = excluded.example_sources_json,
      source_count = excluded.source_count,
      confidence_json = excluded.confidence_json,
      updated_at = excluded.updated_at
  `);
  for (const entry of entries) {
    query.run(
      entry.interestId,
      entry.name,
      entry.description,
      entry.status,
      JSON.stringify(entry.aliases),
      entry.parentInterestId ?? null,
      JSON.stringify(entry.exampleSources),
      entry.sourceCount,
      JSON.stringify(entry.confidence),
      now,
      now,
    );
  }
}

export async function verifyInterestMap(config: XBookmarksConfig, runId = defaultInterestMapRunId()): Promise<InterestMapVerifyResult> {
  if (!config.databasePath) throw new Error("Cannot verify interest map because databasePath is not configured.");
  const mapPath = join(config.managedRoot, "wiki", "meta", "interest-map.md");
  const markdown = await readTextIfExists(mapPath);
  const parsed = parseInterestMapMarkdown(markdown);
  const findings: InterestMapVerifyResult["findings"] = [];
  const db = new Database(config.databasePath);
  ensureInterestMapTables(db);
  const decisionRows = db.query(`
    SELECT source_id, raw_path, status, why_saved, matched_interests_json, non_obvious_connections_json, actions_json, confidence, defer_reason
    FROM kb_ingest_decisions
    ORDER BY source_id
  `).all() as DecisionRow[];
  const decisionSourceIds = new Set(decisionRows.map((row) => String(row.source_id)));
  const entryRows = db.query("SELECT interest_id, source_count, example_sources_json FROM kb_interest_map_entries").all() as Array<Record<string, string | number | null>>;
  const entryCountById = new Map(entryRows.map((row) => [String(row.interest_id), Number(row.source_count ?? 0)]));
  const deferredDbCount = decisionRows.filter((row) => row.status === "deferred_media_inspection").length;

  for (const error of parsed.errors) findings.push({ severity: "error", ruleId: "parse-error", message: error });
  const seenIds = new Set<string>();
  for (const entry of parsed.entries) {
    if (seenIds.has(entry.interestId)) findings.push({ severity: "error", ruleId: "duplicate-interest-id", interestId: entry.interestId, message: `Duplicate interest id: ${entry.interestId}` });
    seenIds.add(entry.interestId);
    if (!isStableInterestId(entry.interestId)) findings.push({ severity: "error", ruleId: "invalid-interest-id", interestId: entry.interestId, message: `Interest id is not a lowercase slug: ${entry.interestId}` });
    if (!entry.name) findings.push({ severity: "error", ruleId: "missing-name", interestId: entry.interestId, message: "Interest is missing Name." });
    if (!entry.status) findings.push({ severity: "error", ruleId: "missing-status", interestId: entry.interestId, message: "Interest is missing Status." });
    if (!entry.description) findings.push({ severity: "error", ruleId: "missing-description", interestId: entry.interestId, message: "Interest is missing Description." });
    if (isPlaceholderInterest(entry.name) || isPlaceholderInterest(entry.interestId)) {
      findings.push({ severity: "error", ruleId: "placeholder-interest", interestId: entry.interestId, message: `Placeholder heading must not be a core interest: ${entry.name}` });
    }
    if (entry.status === "active" && entry.exampleSources.length === 0 && !entry.manuallySeeded) {
      findings.push({ severity: "error", ruleId: "active-without-source", interestId: entry.interestId, message: "Active interest needs an example source or Manually seeded: yes." });
    }
    const sqliteCount = entryCountById.get(entry.interestId);
    if (sqliteCount !== undefined && sqliteCount !== entry.sourceCount) {
      findings.push({ severity: "error", ruleId: "source-count-mismatch", interestId: entry.interestId, message: `Map source count ${entry.sourceCount} does not match SQLite entry count ${sqliteCount}.` });
    }
    for (const sourceId of entry.exampleSources) {
      const rawPath = rawPathForExample(markdown, sourceId) ?? `../../raw/x/ingested/${sourceId}.md`;
      const absolute = resolve(dirname(mapPath), rawPath);
      if (!(await fileExists(absolute))) {
        findings.push({ severity: "error", ruleId: "example-source-link-missing", interestId: entry.interestId, sourceId, message: `Example source link does not resolve: ${sourceId}` });
      }
      if (!decisionSourceIds.has(sourceId)) {
        findings.push({ severity: "error", ruleId: "example-source-no-decision", interestId: entry.interestId, sourceId, message: `Example source has no kb_ingest_decisions row: ${sourceId}` });
      }
    }
  }
  const recurringUnique = new Set(parsed.recurringQuestions);
  if (recurringUnique.size !== parsed.recurringQuestions.length) {
    findings.push({ severity: "error", ruleId: "duplicate-recurring-question", message: "Recurring questions contain duplicates." });
  }
  if (parsed.deferredMediaInspection.length !== deferredDbCount) {
    findings.push({ severity: "error", ruleId: "deferred-count-mismatch", message: `Map deferred count ${parsed.deferredMediaInspection.length} does not match SQLite count ${deferredDbCount}.` });
  }
  db.close();

  const result: InterestMapVerifyResult = {
    ok: findings.every((finding) => finding.severity !== "error"),
    errorCount: findings.filter((finding) => finding.severity === "error").length,
    warningCount: findings.filter((finding) => finding.severity === "warning").length,
    findings,
    artifactPaths: [],
    summary: {
      interestCount: parsed.entries.length,
      sourceCount: decisionRows.length,
      deferredMediaInspectionCount: parsed.deferredMediaInspection.length,
      recurringQuestionCount: parsed.recurringQuestions.length,
    },
  };

  const runPath = join(config.artifactRoot, runId);
  await mkdir(runPath, { recursive: true });
  const jsonPath = join(runPath, "interest-map-verify.json");
  const markdownPath = join(runPath, "interest-map-verify.md");
  result.artifactPaths.push(jsonPath, markdownPath);
  await writeJson(jsonPath, result);
  await writeTextAtomic(markdownPath, renderVerifyReport(result));
  return result;
}

export async function reconcileInterestMap(config: XBookmarksConfig, dryRun: boolean): Promise<ReconcileResult> {
  if (!config.databasePath) throw new Error("Cannot reconcile interest map because databasePath is not configured.");
  const mapPath = join(config.managedRoot, "wiki", "meta", "interest-map.md");
  const markdown = await readTextIfExists(mapPath);
  const parsed = parseInterestMapMarkdown(markdown);
  const db = new Database(config.databasePath);
  ensureInterestMapTables(db);
  const existing = db.query("SELECT interest_id, name, aliases_json, status FROM kb_interest_map_entries").all() as Array<Record<string, string | null>>;
  const existingById = new Map(existing.map((row) => [String(row.interest_id), row]));
  const result: ReconcileResult = {
    dryRun,
    parsedEntries: parsed.entries.length,
    newInterestIds: [],
    renamedInterestIds: [],
    aliasChangedInterestIds: [],
    deprecatedInterestIds: [],
    invalidSourceLinks: [],
    unsafeEntries: [...parsed.errors],
    applied: false,
  };
  for (const entry of parsed.entries) {
    const old = existingById.get(entry.interestId);
    if (!old) result.newInterestIds.push(entry.interestId);
    else {
      if (old.name !== entry.name) result.renamedInterestIds.push(entry.interestId);
      if (JSON.stringify(parseJsonArray<string>(old.aliases_json)) !== JSON.stringify(entry.aliases)) result.aliasChangedInterestIds.push(entry.interestId);
    }
    if (entry.status === "deprecated") result.deprecatedInterestIds.push(entry.interestId);
    for (const sourceId of entry.exampleSources) {
      const link = rawPathForExample(markdown, sourceId);
      if (link && !(await fileExists(resolve(dirname(mapPath), link)))) result.invalidSourceLinks.push(`${entry.interestId}:${sourceId}`);
    }
  }
  if (!dryRun && result.unsafeEntries.length === 0 && result.invalidSourceLinks.length === 0) {
    upsertInterestMapEntries(db, parsed.entries);
    result.applied = true;
  }
  db.close();
  return result;
}

export async function buildPriorDecisionContext(config: XBookmarksConfig, selected: SelectedBookmark, interestMapMarkdown: string, limit = 12): Promise<PriorDecisionContext> {
  if (!config.databasePath) throw new Error("Cannot build prior-decision context because databasePath is not configured.");
  const db = new Database(config.databasePath);
  ensureInterestMapTables(db);
  const rows = db.query(`
    SELECT source_id, raw_path, status, why_saved, matched_interests_json, non_obvious_connections_json, actions_json, confidence, defer_reason
    FROM kb_ingest_decisions
    WHERE source_id != ?
    ORDER BY source_id
  `).all(selected.sourceId) as DecisionRow[];
  const sourceMarkdown = await readFile(selected.rawPath, "utf8");
  const sourceTerms = termsFor(`${selected.title} ${selected.authorHandle ?? ""} ${sourceMarkdown}`);
  const parsedMap = parseInterestMapMarkdown(interestMapMarkdown);
  const interestTerms = new Map<string, Set<string>>();
  for (const entry of parsedMap.entries) {
    interestTerms.set(entry.interestId, termsFor([entry.interestId, entry.name, ...entry.aliases].join(" ")));
  }
  const scored: PriorDecisionContextItem[] = [];
  for (const row of rows) {
    const matches = parseJsonArray<MatchedInterest>(row.matched_interests_json);
    const connections = parseJsonArray<NonObviousConnection>(row.non_obvious_connections_json);
    const reasons: string[] = [];
    let score = 0;
    for (const match of matches) {
      const id = slugifyInterest(match.interest);
      const terms = interestTerms.get(id) ?? termsFor(match.interest);
      const overlap = countOverlap(sourceTerms, terms);
      if (overlap > 0) {
        score += overlap * 3;
        reasons.push(`interest:${id}`);
      }
    }
    const rowTextTerms = termsFor(`${row.why_saved ?? ""} ${matches.map((item) => item.interest).join(" ")}`);
    const textOverlap = Math.min(4, countOverlap(sourceTerms, rowTextTerms));
    if (textOverlap > 0) {
      score += textOverlap;
      reasons.push("keyword-overlap");
    }
    const priorAuthor = await authorForRawPath(config.managedRoot, String(row.raw_path));
    if (selected.authorHandle && priorAuthor && selected.authorHandle.toLowerCase() === priorAuthor.toLowerCase()) {
      score += 5;
      reasons.push("same-author");
    }
    if (row.status === "deferred_media_inspection" && /media|image|video|photo|screenshot|chart/i.test(sourceMarkdown)) {
      score += 2;
      reasons.push("media-primary-pattern");
    }
    if (score <= 0) continue;
    scored.push({
      source_id: String(row.source_id),
      raw_path: String(row.raw_path),
      markdown_link: `[${row.source_id}](../../${row.raw_path})`,
      status: String(row.status),
      why_saved: compact(String(row.why_saved ?? "")),
      matched_interests: matches,
      non_obvious_connections: connections,
      confidence: String(row.confidence ?? "medium"),
      defer_reason: row.defer_reason ? compact(row.defer_reason) : undefined,
      score,
      reasons: unique(reasons),
    });
  }
  db.close();
  const items = diversifyByInterest(scored.sort((a, b) => b.score - a.score || a.source_id.localeCompare(b.source_id)), limit);
  return {
    sourceId: selected.sourceId,
    limit,
    items,
    markdown: renderPriorDecisionContextMarkdown(items),
  };
}

export function defaultInterestMapRunId(): string {
  return `interest-map-${new Date().toISOString().replace(/[:.]/g, "-")}`;
}

export function slugifyInterest(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-") || "unnamed-interest";
}

export function usefulInterestName(value: string | undefined): value is string {
  if (!value?.trim()) return false;
  const normalized = value.trim().toLowerCase();
  return !isPlaceholderInterest(normalized);
}

export function parseJsonArray<T>(value: string | null | undefined): T[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed as T[] : [];
  } catch {
    return [];
  }
}

export function inferredInterestsFromActions(actions: SensemakingAction[], whySaved: string | undefined): MatchedInterest[] {
  return actions
    .filter((action) => action.kind === "create_new_page" || action.kind === "add_evidence_to_page")
    .map((action) => action.title ?? action.page?.split("/").pop()?.replace(/\.md$/, "").replaceAll("-", " "))
    .filter((interest): interest is string => usefulInterestName(interest))
    .slice(0, 3)
    .map((interest) => ({
      interest,
      evidence: whySaved ?? "Inferred from the proposed sensemaking action.",
      confidence: "medium",
    }));
}

export function cleanGeneratedText(value: string): string {
  return value
    .replace(/^#+\s*(Source Understanding|Why John Likely Saved This|Existing Interest Matches|Non-Obvious Connections|Durable Takeaways|Proposed Actions|Confidence And Deferrals)\s*/i, "")
    .replace(/^\s*-\s*#+\s*(Source Understanding|Why John Likely Saved This|Existing Interest Matches|Non-Obvious Connections|Durable Takeaways|Proposed Actions|Confidence And Deferrals)\s*/i, "")
    .trim();
}

export function compactInterestMapSignal(value: string): string {
  return cleanGeneratedText(value)
    .replace(/^John\s+likely\s+saved\s+this\s+(because|as|for|to)\s+/i, "")
    .replace(/^The\s+save\s+may\s+reflect\s+(an?\s+)?interest\s+in\s+/i, "")
    .replace(/^This\s+was\s+likely\s+saved\s+(because|as|for|to)\s+/i, "")
    .replace(/^It\s+(names|shows|connects|highlights|points\s+to)\s+/i, "$1 ")
    .replace(/\s+/g, " ")
    .replace(/\.$/, "")
    .trim();
}

function entryFromFields(heading: string, fields: Map<string, string>, line: number, errors: string[]): InterestMapEntry | undefined {
  const headingIsId = isStableInterestId(heading);
  const interestId = headingIsId ? heading : slugifyInterest(heading);
  const name = fields.get("name") || (headingIsId ? titleCaseInterest(heading) : heading);
  const status = parseStatus(fields.get("status") || "active", line, errors);
  const description = cleanGeneratedText(fields.get("description") || "");
  const aliases = parseCsv(fields.get("aliases")).filter((alias) => alias.toLowerCase() !== "none");
  const relatedInterestIds = parseCsv(fields.get("related interests")).map(slugifyInterest);
  const parentInterestId = fields.get("parent interest") ? slugifyInterest(fields.get("parent interest") ?? "") : undefined;
  const exampleSources = parseExampleSources(fields.get("example sources") || "");
  const sourceCount = Number(fields.get("source count") || exampleSources.length || 0);
  const manuallySeeded = /^(yes|true)$/i.test(fields.get("manually seeded") || "");
  if (!headingIsId) errors.push(`Line ${line}: legacy interest heading '${heading}' will reconcile to stable id '${interestId}'.`);
  return {
    interestId,
    name,
    status,
    description,
    aliases,
    parentInterestId,
    relatedInterestIds,
    exampleSources,
    sourceCount: Number.isFinite(sourceCount) ? sourceCount : exampleSources.length,
    manuallySeeded,
    signals: parseSignals(fields.get("signals")),
    confidence: parseConfidence(fields.get("confidence")),
  };
}

function renderInterestEntry(entry: InterestMapEntry, rawPathBySourceId: Map<string, string>): string[] {
  const aliases = entry.aliases.length ? entry.aliases.join(", ") : "none";
  const related = entry.relatedInterestIds.length ? entry.relatedInterestIds.join(", ") : "none";
  const examples = entry.exampleSources.length
    ? entry.exampleSources.map((sourceId) => `[${sourceId}](../../${rawPathBySourceId.get(sourceId) ?? `raw/x/ingested/${sourceId}.md`})`).join(", ")
    : "none";
  return [
    `### ${entry.interestId}`,
    "",
    `- Name: ${entry.name}`,
    `- Status: ${entry.status}`,
    `- Description: ${entry.description || "Inferred from baseline sources."}`,
    `- Aliases: ${aliases}`,
    `- Parent interest: ${entry.parentInterestId ?? "none"}`,
    `- Related interests: ${related}`,
    `- Source count: ${entry.sourceCount}`,
    `- Confidence: ${JSON.stringify(entry.confidence)}`,
    `- Manually seeded: ${entry.manuallySeeded ? "yes" : "no"}`,
    `- Example sources: ${examples}`,
    `- Signals: ${entry.signals.length ? entry.signals.join("; ") : "none"}`,
    "",
  ];
}

function renderVerifyReport(result: InterestMapVerifyResult): string {
  return [
    "# Interest Map Verify",
    "",
    `Status: ${result.ok ? "ok" : "failed"}`,
    `Errors: ${result.errorCount}`,
    `Warnings: ${result.warningCount}`,
    `Interests: ${result.summary.interestCount}`,
    `Sources with decisions: ${result.summary.sourceCount}`,
    `Deferred media inspection: ${result.summary.deferredMediaInspectionCount}`,
    `Recurring questions: ${result.summary.recurringQuestionCount}`,
    "",
    "## Findings",
    "",
    ...(result.findings.length
      ? result.findings.map((finding) => `- ${finding.severity.toUpperCase()} ${finding.ruleId}: ${finding.message}`)
      : ["- none"]),
    "",
  ].join("\n");
}

function revisionSummary(sourceCount: number, entries: InterestMapEntry[], recurringQuestionCount: number, deferredMediaInspectionCount: number): Record<string, unknown> {
  return {
    source_count: sourceCount,
    interest_count: entries.length,
    deferred_media_inspection_count: deferredMediaInspectionCount,
    recurring_question_count: recurringQuestionCount,
    interests: entries.map((entry) => ({
      interest_id: entry.interestId,
      name: entry.name,
      source_count: entry.sourceCount,
      example_sources: entry.exampleSources,
    })),
  };
}

function renderPriorDecisionContextMarkdown(items: PriorDecisionContextItem[]): string {
  if (items.length === 0) return "_No deterministic prior decisions retrieved._";
  return [
    "## Prior Decisions",
    "",
    ...items.flatMap((item) => [
      `- ${item.markdown_link} (${item.status}, ${item.confidence}, score ${item.score})`,
      `  - Why saved: ${item.why_saved}`,
      `  - Matched interests: ${item.matched_interests.map((match) => `${slugifyInterest(match.interest)} (${match.confidence})`).join(", ") || "none"}`,
      item.defer_reason ? `  - Defer reason: ${item.defer_reason}` : undefined,
      `  - Retrieval reasons: ${item.reasons.join(", ")}`,
    ].filter((line): line is string => line !== undefined)),
  ].join("\n");
}

function interestSection(section: string): boolean {
  return section === "Core Interests" || section === "Recently Emerging Interests" || section === "Deprecated Interests";
}

function normalizeFieldName(value: string): string {
  return value.trim().toLowerCase();
}

function parseStatus(value: string, line: number, errors: string[]): InterestStatus {
  const normalized = value.trim().toLowerCase();
  if (normalized === "active" || normalized === "emerging" || normalized === "deprecated") return normalized;
  errors.push(`Line ${line}: invalid status '${value}'.`);
  return "emerging";
}

function parseCsv(value: string | undefined): string[] {
  if (!value || value.trim().toLowerCase() === "none") return [];
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function parseSignals(value: string | undefined): string[] {
  if (!value || value.trim().toLowerCase() === "none") return [];
  return value.split(/\s*;\s*/).map(cleanGeneratedText).filter(Boolean);
}

function parseConfidence(value: string | undefined): Record<string, number> {
  if (!value) return {};
  try {
    const parsed = JSON.parse(value);
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? parsed as Record<string, number> : {};
  } catch {
    return {};
  }
}

function parseExampleSources(value: string): string[] {
  if (!value || value.trim().toLowerCase() === "none") return [];
  return unique([...value.matchAll(/\[([0-9]+)\]\(([^)]+)\)/g)].map((match) => match[1]));
}

function rawPathForExample(markdown: string, sourceId: string): string | undefined {
  const escaped = sourceId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`\\[${escaped}\\]\\(([^)]+)\\)`).exec(markdown)?.[1];
}

function isStableInterestId(value: string): boolean {
  return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value);
}

function isPlaceholderInterest(value: string): boolean {
  const normalized = value.trim().toLowerCase();
  return normalized.startsWith("no strong")
    || normalized.startsWith("no core")
    || normalized.startsWith("no existing")
    || normalized.startsWith("no clear")
    || normalized.startsWith("no matched")
    || normalized.includes("no strong existing")
    || normalized.includes("no core interest");
}

function titleCaseInterest(value: string): string {
  return value
    .trim()
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function normalizeLookup(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function countBy(values: string[]): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const value of values) counts[value] = (counts[value] ?? 0) + 1;
  return counts;
}

function unique<T>(values: T[]): T[] {
  return [...new Set(values)];
}

function termsFor(value: string): Set<string> {
  return new Set((value.toLowerCase().match(/[a-z0-9][a-z0-9_-]{3,}/g) ?? []).map((term) => term.replace(/_/g, "-")));
}

function countOverlap(a: Set<string>, b: Set<string>): number {
  let count = 0;
  for (const item of a) if (b.has(item)) count += 1;
  return count;
}

function compact(value: string): string {
  const clean = cleanGeneratedText(value).replace(/\s+/g, " ").trim();
  return clean.length <= 280 ? clean : `${clean.slice(0, 277)}...`;
}

async function authorForRawPath(managedRoot: string, rawPath: string): Promise<string | undefined> {
  const absolute = resolve(managedRoot, rawPath);
  if (!(await fileExists(absolute))) return undefined;
  const markdown = await readFile(absolute, "utf8");
  const { data } = parseFrontmatter(markdown);
  const value = data.author_username;
  return typeof value === "string" ? value : undefined;
}

function diversifyByInterest(items: PriorDecisionContextItem[], limit: number): PriorDecisionContextItem[] {
  const selected: PriorDecisionContextItem[] = [];
  const seenInterest = new Set<string>();
  for (const item of items) {
    const ids = item.matched_interests.map((match) => slugifyInterest(match.interest));
    if (ids.length > 0 && ids.every((id) => seenInterest.has(id)) && selected.length < Math.ceil(limit / 2)) continue;
    selected.push(item);
    for (const id of ids) seenInterest.add(id);
    if (selected.length >= limit) return selected;
  }
  for (const item of items) {
    if (!selected.includes(item)) selected.push(item);
    if (selected.length >= limit) break;
  }
  return selected;
}

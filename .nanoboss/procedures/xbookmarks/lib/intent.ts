import type { IntentConfidence, RefreshIntent, RefreshOptions } from "./types.ts";

const REFRESH_FIELDS = new Set([
  "dryRun",
  "noSync",
  "fullSync",
  "limit",
  "repair",
  "maxRepairAttempts",
  "batchId",
  "changedOnly",
  "agent",
]);

const SELECT_FIELDS = new Set(["limit", "batchId"]);

export function parseProgrammaticRefreshOptions(prompt: string): RefreshOptions {
  const parsed = parseStrictObject(prompt, REFRESH_FIELDS);
  const dryRun = optionalBoolean(parsed.dryRun, "dryRun") ?? true;
  const noSync = optionalBoolean(parsed.noSync, "noSync") ?? true;
  const fullSync = optionalBoolean(parsed.fullSync, "fullSync") ?? false;
  const limit = normalizeLimit(optionalNumber(parsed.limit, "limit"), 5);
  const repairDefault = dryRun ? false : true;
  return {
    dryRun,
    noSync,
    fullSync,
    limit,
    repair: optionalBoolean(parsed.repair, "repair") ?? repairDefault,
    maxRepairAttempts: normalizeRepairAttempts(optionalNumber(parsed.maxRepairAttempts, "maxRepairAttempts") ?? 1),
    batchId: optionalString(parsed.batchId, "batchId") ?? defaultBatchId(),
    changedOnly: optionalBoolean(parsed.changedOnly, "changedOnly") ?? true,
    agent: optionalString(parsed.agent, "agent"),
    intentRationale: "Programmatic JSON input.",
    intentConfidence: "high",
  };
}

export function parseProgrammaticSelectOptions(prompt: string): { limit: number; batchId: string } | undefined {
  if (!prompt.trim().startsWith("{")) return undefined;
  const parsed = parseStrictObject(prompt, SELECT_FIELDS);
  return {
    limit: normalizeLimit(optionalNumber(parsed.limit, "limit"), 25),
    batchId: optionalString(parsed.batchId, "batchId") ?? defaultBatchId(),
  };
}

export function validateAndDefaultRefreshIntent(intent: RefreshIntent): RefreshOptions {
  const dryRun = intent.mode === "apply" ? false : true;
  const noSync = intent.syncMode === "incremental" || intent.syncMode === "full" ? false : true;
  const fullSync = intent.syncMode === "full";
  const repair = intent.repair ?? (dryRun ? false : true);
  return {
    dryRun,
    noSync,
    fullSync,
    limit: normalizeLimit(intent.limit, 5),
    repair: dryRun ? false : repair,
    maxRepairAttempts: normalizeRepairAttempts(intent.maxRepairAttempts ?? 1),
    batchId: intent.batchId?.trim() || defaultBatchId(),
    changedOnly: true,
    intentRationale: intent.rationale,
    intentConfidence: intent.confidence,
  };
}

export function fallbackNaturalLanguageIntent(prompt: string): RefreshIntent {
  const lower = prompt.toLowerCase();
  const integer = /\b([1-9][0-9]?)\b/.exec(lower)?.[1];
  const mode = /\b(apply|write changes|process|commit to the wiki)\b/.test(lower)
    ? "apply"
    : "dry-run";
  const syncMode = /\b(full sync|reconcile everything)\b/.test(lower)
    ? "full"
    : /\b(sync first|fetch latest|refresh from x)\b/.test(lower)
      ? "incremental"
      : "none";
  const repair = /\b(no repair|do not auto-fix|without auto-repair)\b/.test(lower)
    ? false
    : undefined;

  return {
    mode,
    syncMode,
    limit: integer ? Number.parseInt(integer, 10) : undefined,
    repair,
    rationale: "Deterministic fallback intent extraction from natural-language cues.",
    confidence: "medium",
  };
}

export function parseNaturalSelectLimit(prompt: string): number {
  const integer = /\b([1-9][0-9]?)\b/.exec(prompt)?.[1];
  return normalizeLimit(integer ? Number.parseInt(integer, 10) : undefined, 25);
}

export function defaultBatchId(): string {
  return `batch-${new Date().toISOString().replace(/[:.]/g, "-")}`;
}

export function defaultRunId(): string {
  return `run-${new Date().toISOString().replace(/[:.]/g, "-")}`;
}

function parseStrictObject(prompt: string, allowedFields: Set<string>): Record<string, unknown> {
  const parsed = JSON.parse(prompt);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("Programmatic input must be a JSON object.");
  }
  const object = parsed as Record<string, unknown>;
  const unknown = Object.keys(object).filter((key) => !allowedFields.has(key));
  if (unknown.length > 0) {
    throw new Error(`Unknown field(s): ${unknown.join(", ")}`);
  }
  return object;
}

function normalizeLimit(value: number | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  if (!Number.isInteger(value) || value < 1 || value > 100) {
    throw new Error("limit must be an integer from 1 to 100.");
  }
  return value;
}

function normalizeRepairAttempts(value: number): number {
  if (!Number.isInteger(value) || value < 0) {
    throw new Error("maxRepairAttempts must be a non-negative integer.");
  }
  return Math.min(value, 2);
}

function optionalBoolean(value: unknown, name: string): boolean | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "boolean") throw new Error(`${name} must be a boolean.`);
  return value;
}

function optionalNumber(value: unknown, name: string): number | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "number") throw new Error(`${name} must be a number.`);
  return value;
}

function optionalString(value: unknown, name: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${name} must be a string.`);
  return value.trim() || undefined;
}

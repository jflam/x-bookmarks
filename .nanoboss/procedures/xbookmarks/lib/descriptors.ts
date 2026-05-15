import { jsonType } from "./nanoboss.ts";
import type { KbSensemakingDecision, RefreshIntent, TopicSynthesisIntent, WikiIngestPlan, WikiOperation } from "./types.ts";

export interface KbSensemakingDecisionBatch {
  decisions: Array<{ source_id: string; decision: KbSensemakingDecision }>;
}

export const RefreshIntentType = jsonType<RefreshIntent>(
  {
    type: "object",
    required: ["rationale", "confidence"],
    properties: {
      mode: { enum: ["dry-run", "apply"] },
      syncMode: { enum: ["none", "incremental", "full"] },
      limit: { type: "number" },
      repair: { type: "boolean" },
      maxRepairAttempts: { type: "number" },
      batchId: { type: "string" },
      rationale: { type: "string" },
      confidence: { enum: ["low", "medium", "high"] },
    },
  },
  isRefreshIntent,
);

export const WikiIngestPlanType = jsonType<WikiIngestPlan>(
  {
    type: "object",
    required: ["summary", "operations", "followUpSources", "relationshipCandidates", "spacedRepetitionCandidates"],
    properties: {
      summary: { type: "string" },
      operations: { type: "array" },
      followUpSources: { type: "array", items: { type: "string" } },
      relationshipCandidates: { type: "array", items: { type: "string" } },
      spacedRepetitionCandidates: { type: "array", items: { type: "string" } },
    },
  },
  isWikiIngestPlan,
);

export const TopicSynthesisIntentType = jsonType<TopicSynthesisIntent>(
  {
    type: "object",
    required: ["rationale", "confidence"],
    properties: {
      mode: { enum: ["dry-run", "apply"] },
      paths: { type: "array", items: { type: "string" } },
      all: { type: "boolean" },
      limit: { type: "number" },
      chunkSize: { type: "number" },
      repair: { type: "boolean" },
      maxRepairAttempts: { type: "number" },
      batchId: { type: "string" },
      rationale: { type: "string" },
      confidence: { enum: ["low", "medium", "high"] },
    },
  },
  isTopicSynthesisIntent,
);

export const KbSensemakingDecisionType = jsonType<KbSensemakingDecision>(
  {
    type: "object",
    required: [
      "source_understanding",
      "why_saved",
      "matched_interests",
      "non_obvious_connections",
      "durable_takeaways",
      "candidate_pages",
      "actions",
      "confidence",
    ],
    properties: {
      source_understanding: { type: "object" },
      why_saved: { type: "string" },
      matched_interests: { type: "array" },
      non_obvious_connections: { type: "array" },
      durable_takeaways: { type: "array", items: { type: "string" } },
      candidate_pages: { type: "array", items: { type: "string" } },
      actions: { type: "array" },
      confidence: { enum: ["low", "medium", "high"] },
      defer_reason: { type: "string" },
    },
  },
  isKbSensemakingDecision,
);

export const KbSensemakingDecisionBatchType = jsonType<KbSensemakingDecisionBatch>(
  {
    type: "object",
    required: ["decisions"],
    properties: {
      decisions: { type: "array" },
    },
  },
  isKbSensemakingDecisionBatch,
);

function isRefreshIntent(value: unknown): value is RefreshIntent {
  if (!isRecord(value)) return false;
  return (
    optionalEnum(value.mode, ["dry-run", "apply"])
    && optionalEnum(value.syncMode, ["none", "incremental", "full"])
    && optionalNumber(value.limit)
    && optionalBoolean(value.repair)
    && optionalNumber(value.maxRepairAttempts)
    && optionalString(value.batchId)
    && typeof value.rationale === "string"
    && enumValue(value.confidence, ["low", "medium", "high"])
  );
}

function isWikiIngestPlan(value: unknown): value is WikiIngestPlan {
  if (!isRecord(value)) return false;
  return (
    typeof value.summary === "string"
    && Array.isArray(value.operations)
    && value.operations.every(isWikiOperation)
    && stringArray(value.followUpSources)
    && stringArray(value.relationshipCandidates)
    && stringArray(value.spacedRepetitionCandidates)
  );
}

function isTopicSynthesisIntent(value: unknown): value is TopicSynthesisIntent {
  if (!isRecord(value)) return false;
  return (
    optionalEnum(value.mode, ["dry-run", "apply"])
    && (value.paths === undefined || stringArray(value.paths))
    && optionalBoolean(value.all)
    && optionalNumber(value.limit)
    && optionalNumber(value.chunkSize)
    && optionalBoolean(value.repair)
    && optionalNumber(value.maxRepairAttempts)
    && optionalString(value.batchId)
    && typeof value.rationale === "string"
    && enumValue(value.confidence, ["low", "medium", "high"])
  );
}

function isKbSensemakingDecision(value: unknown): value is KbSensemakingDecision {
  if (!isRecord(value)) return false;
  return (
    isRecord(value.source_understanding)
    && typeof value.why_saved === "string"
    && Array.isArray(value.matched_interests)
    && Array.isArray(value.non_obvious_connections)
    && Array.isArray(value.durable_takeaways)
    && Array.isArray(value.candidate_pages)
    && Array.isArray(value.actions)
    && enumValue(value.confidence, ["low", "medium", "high"])
    && optionalString(value.defer_reason)
  );
}

function isKbSensemakingDecisionBatch(value: unknown): value is KbSensemakingDecisionBatch {
  if (!isRecord(value) || !Array.isArray(value.decisions)) return false;
  return value.decisions.every((item) => (
    isRecord(item)
    && typeof item.source_id === "string"
    && isKbSensemakingDecision(item.decision)
  ));
}

function isWikiOperation(value: unknown): value is WikiOperation {
  if (!isRecord(value) || typeof value.kind !== "string") return false;
  if (value.kind === "ignore_source") {
    return typeof value.sourceId === "string" && typeof value.reason === "string";
  }
  if (value.kind === "append_log") {
    return typeof value.markdown === "string" && stringArray(value.sourceIds);
  }
  if (["create_page", "update_page", "update_review", "update_map"].includes(value.kind)) {
    return typeof value.path === "string" && typeof value.markdown === "string" && stringArray(value.sourceIds);
  }
  return false;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function optionalString(value: unknown): boolean {
  return value === undefined || typeof value === "string";
}

function optionalNumber(value: unknown): boolean {
  return value === undefined || typeof value === "number";
}

function optionalBoolean(value: unknown): boolean {
  return value === undefined || typeof value === "boolean";
}

function optionalEnum(value: unknown, allowed: string[]): boolean {
  return value === undefined || enumValue(value, allowed);
}

function enumValue(value: unknown, allowed: string[]): boolean {
  return typeof value === "string" && allowed.includes(value);
}

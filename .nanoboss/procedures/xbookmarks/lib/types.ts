export type RefreshMode = "dry-run" | "apply";
export type SyncMode = "none" | "incremental" | "full";
export type IntentConfidence = "low" | "medium" | "high";

export interface RefreshIntent {
  mode?: RefreshMode;
  syncMode?: SyncMode;
  limit?: number;
  repair?: boolean;
  maxRepairAttempts?: number;
  batchId?: string;
  rationale: string;
  confidence: IntentConfidence;
}

export interface RefreshOptions {
  dryRun: boolean;
  noSync: boolean;
  fullSync: boolean;
  limit: number;
  repair: boolean;
  maxRepairAttempts: number;
  batchId: string;
  changedOnly: boolean;
  agent?: string;
  intentRationale: string;
  intentConfidence: IntentConfidence;
}

export type LintSeverity = "error" | "warning";

export interface XBookmarksConfig {
  workspaceRoot: string;
  managedRoot: string;
  artifactRoot: string;
  xBookmarksBinary: string;
  xBookmarksHome?: string;
}

export interface SelectedBookmark {
  sourceId: string;
  rawPath: string;
  tweetId: string;
  title: string;
  contentHash: string;
  authorHandle?: string;
  postedAt?: string;
  exportedAt?: string;
  canonicalUrl?: string;
}

export interface ContextBundle {
  runId: string;
  batchId: string;
  rootPath: string;
  runPath: string;
  selectedBookmarksPath: string;
  selectedRawSourcesPath: string;
  selectedMediaPath: string;
  schemaPath: string;
  wikiIndexPath: string;
  homePath?: string;
  thisWeekPath?: string;
  relevantMapPaths: string[];
  candidateRelatedPagesPath: string;
}

export type WikiOperation =
  | { kind: "create_page"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "update_page"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "update_review"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "update_map"; path: string; markdown: string; sourceIds: string[] }
  | { kind: "ignore_source"; sourceId: string; reason: string }
  | { kind: "append_log"; markdown: string; sourceIds: string[] };

export interface WikiIngestPlan {
  summary: string;
  operations: WikiOperation[];
  followUpSources: string[];
  relationshipCandidates: string[];
  spacedRepetitionCandidates: string[];
}

export interface ApplyResult {
  dryRun: boolean;
  createdPages: string[];
  updatedPages: string[];
  updatedMaps: string[];
  updatedReviewPages: string[];
  ingestedSourceIds: string[];
  ignoredSourceIds: string[];
  unresolvedSourceIds: string[];
  artifactPaths: string[];
}

export interface LintFinding {
  ruleId: string;
  severity: LintSeverity;
  file: string;
  message: string;
  line?: number;
  suggestedFix?: string;
}

export interface LintResult {
  ok: boolean;
  errorCount: number;
  warningCount: number;
  findings: LintFinding[];
  artifactPaths: string[];
}

export interface XBookmarksRefreshData {
  intent: RefreshOptions;
  config: Pick<XBookmarksConfig, "workspaceRoot" | "managedRoot" | "artifactRoot">;
  selectedSourceIds: string[];
  contextBundlePath: string;
  applied: ApplyResult;
  lint: LintResult;
  followUpSources: string[];
  relationshipCandidates: string[];
  spacedRepetitionCandidates: string[];
}

export interface TopicSynthesisIntent {
  mode?: RefreshMode;
  paths?: string[];
  all?: boolean;
  limit?: number;
  chunkSize?: number;
  repair?: boolean;
  maxRepairAttempts?: number;
  batchId?: string;
  rationale: string;
  confidence: IntentConfidence;
}

export interface TopicSynthesisOptions {
  dryRun: boolean;
  paths: string[];
  all: boolean;
  limit: number;
  chunkSize: number;
  repair: boolean;
  maxRepairAttempts: number;
  batchId: string;
  intentRationale: string;
  intentConfidence: IntentConfidence;
}

export interface TopicSelection {
  path: string;
  title: string;
  sourceIds: string[];
  sourcePaths: string[];
  reason: string;
}

export interface TopicSynthesisContext {
  runId: string;
  batchId: string;
  rootPath: string;
  runPath: string;
  selectedTopicsPath: string;
  selectedTopicPagesPath: string;
  selectedRawSourcesPath: string;
  selectedMediaPath: string;
  wikiIndexPath: string;
}

export interface TopicSynthesisRefreshData {
  intent: TopicSynthesisOptions;
  config: Pick<XBookmarksConfig, "workspaceRoot" | "managedRoot" | "artifactRoot">;
  selectedTopicPaths: string[];
  contextBundlePath: string;
  contextBundlePaths: string[];
  applied: ApplyResult;
  lint: LintResult;
  chunkResults: TopicSynthesisChunkResult[];
  stoppedEarly: boolean;
  followUpSources: string[];
  relationshipCandidates: string[];
  spacedRepetitionCandidates: string[];
}

export interface TopicSynthesisChunkResult {
  index: number;
  total: number;
  selectedTopicPaths: string[];
  contextBundlePath: string;
  applied: ApplyResult;
  lint: LintResult;
}

export interface SelectBatchOptions {
  managedRoot: string;
  limit: number;
}

export interface BuildContextBundleOptions {
  config: XBookmarksConfig;
  selected: SelectedBookmark[];
  batchId: string;
  runId?: string;
}

export interface ApplyWikiPlanOptions {
  config: XBookmarksConfig;
  selected: SelectedBookmark[];
  plan: WikiIngestPlan;
  dryRun: boolean;
  runId: string;
}

export interface LintWikiOptions {
  config: XBookmarksConfig;
  selected?: SelectedBookmark[];
  plan?: WikiIngestPlan;
  runId?: string;
  finalizationMode?: "pre-move" | "post-move";
}

export interface SyncAndExportOptions {
  config: XBookmarksConfig;
  changedOnly: boolean;
  fullSync: boolean;
}

export interface BuildReviewPagesOptions {
  config: XBookmarksConfig;
  dryRun: boolean;
  weeks?: string[];
  limitWeeks?: number;
  overwriteExisting?: boolean;
  runId?: string;
}

export interface ReviewSourceEntry {
  sourceId: string;
  week: string;
  status: "ingested" | "ignored";
  rawPath: string;
  canonicalUrl: string;
  authorHandle?: string;
  postedAt?: string;
  wikiEntries: Array<{ path: string; title: string; link: string }>;
}

export interface ReviewPageBuild {
  week: string;
  path: string;
  sourceCount: number;
  markdown: string;
  existed: boolean;
}

export interface ReviewBuildResult {
  dryRun: boolean;
  reviewedWeeks: string[];
  createdPages: string[];
  updatedPages: string[];
  skippedPages: string[];
  artifactPaths: string[];
  pages: ReviewPageBuild[];
}

export interface CommandTranscript {
  command: string[];
  exitCode: number;
  stdout: string;
  stderr: string;
}

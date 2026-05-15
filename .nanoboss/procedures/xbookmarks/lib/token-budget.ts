import { getEncoding } from "js-tiktoken";

export interface TokenBudgetConfig {
  modelContextWindowTokens: number;
  tokenizerEncoding: string;
  maxContextRatio: number;
  outputReservePerSource: number;
  safetyMarginRatio: number;
}

export interface BatchTokenCounts {
  batchSourceIds: string[];
  staticPrefixTokens: number;
  batchPayloadTokens: number;
  outputReserveTokens: number;
  totalRequestTokens: number;
  modelContextWindowTokens: number;
  effectiveContextBudgetTokens: number;
  tokenizerEncoding: string;
}

export const DEFAULT_TOKEN_BUDGET_CONFIG: TokenBudgetConfig = {
  modelContextWindowTokens: 258_400,
  tokenizerEncoding: "o200k_base",
  maxContextRatio: 0.50,
  outputReservePerSource: 1_200,
  safetyMarginRatio: 0.05,
};

const encoders = new Map<string, ReturnType<typeof getEncoding>>();

export function countExactTokens(text: string, encodingName = DEFAULT_TOKEN_BUDGET_CONFIG.tokenizerEncoding): number {
  let encoder = encoders.get(encodingName);
  if (!encoder) {
    encoder = getEncoding(encodingName);
    encoders.set(encodingName, encoder);
  }
  return encoder.encode(text).length;
}

export function effectiveContextBudgetTokens(config: TokenBudgetConfig): number {
  return Math.floor(config.modelContextWindowTokens * (config.maxContextRatio - config.safetyMarginRatio));
}

export function countBatchRequestTokens(params: {
  staticPrefix: string;
  batchPayload: string;
  batchSourceIds: string[];
  config?: Partial<TokenBudgetConfig>;
}): BatchTokenCounts {
  const config = { ...DEFAULT_TOKEN_BUDGET_CONFIG, ...params.config };
  const staticPrefixTokens = countExactTokens(params.staticPrefix, config.tokenizerEncoding);
  const batchPayloadTokens = countExactTokens(params.batchPayload, config.tokenizerEncoding);
  const outputReserveTokens = config.outputReservePerSource * params.batchSourceIds.length;
  return {
    batchSourceIds: params.batchSourceIds,
    staticPrefixTokens,
    batchPayloadTokens,
    outputReserveTokens,
    totalRequestTokens: staticPrefixTokens + batchPayloadTokens + outputReserveTokens,
    modelContextWindowTokens: config.modelContextWindowTokens,
    effectiveContextBudgetTokens: effectiveContextBudgetTokens(config),
    tokenizerEncoding: config.tokenizerEncoding,
  };
}

export function assertWithinTokenBudget(counts: BatchTokenCounts): void {
  if (counts.totalRequestTokens <= counts.effectiveContextBudgetTokens) return;
  const error = new Error([
    "Batch prompt exceeds configured context budget.",
    `batch source IDs: ${counts.batchSourceIds.join(", ")}`,
    `static prefix tokens: ${counts.staticPrefixTokens}`,
    `batch payload tokens: ${counts.batchPayloadTokens}`,
    `output reserve tokens: ${counts.outputReserveTokens}`,
    `total request tokens: ${counts.totalRequestTokens}`,
    `model context window tokens: ${counts.modelContextWindowTokens}`,
    `effective context budget tokens: ${counts.effectiveContextBudgetTokens}`,
    `tokenizer encoding: ${counts.tokenizerEncoding}`,
  ].join("\n"));
  error.name = "TokenBudgetError";
  throw error;
}

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { ContextBundle, LintResult, RefreshOptions, SelectedBookmark, WikiIngestPlan } from "./types.ts";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const PROMPT_DIR = join(MODULE_DIR, "..", "prompts");

export function buildRefreshIntentPrompt(prompt: string): string {
  return [
    "Extract execution intent for an X bookmarks wiki refresh procedure.",
    "Return only typed JSON matching the provided schema.",
    "",
    "Rules:",
    "- dry run, preview, simulate, show me -> mode dry-run",
    "- apply, write changes, process, commit to the wiki -> mode apply",
    "- do not sync, from inbox, already exported -> syncMode none",
    "- sync first, fetch latest, refresh from X -> syncMode incremental",
    "- full sync, reconcile everything -> syncMode full",
    "- no repair, do not auto-fix -> repair false",
    "- first reasonable small integer -> limit",
    "",
    `User request: ${prompt}`,
  ].join("\n");
}

export function buildWikiIngestPrompt(params: {
  selected: SelectedBookmark[];
  context: ContextBundle;
  intent: RefreshOptions;
}): string {
  return [
    readPromptModule("x-bookmarks-wiki.md"),
    "",
    readPromptModule("obsidian-link-discipline.md"),
    "",
    "Current run:",
    JSON.stringify({
      intent: params.intent,
      selected: params.selected,
      contextBundle: params.context,
    }, null, 2),
    "",
    "Context bundle contents:",
    markdownBlock("schema.md", readOptional(params.context.schemaPath)),
    markdownBlock("wiki-index.md", readOptional(params.context.wikiIndexPath)),
    markdownBlock("home.md", params.context.homePath ? readOptional(params.context.homePath) : ""),
    markdownBlock("this-week.md", params.context.thisWeekPath ? readOptional(params.context.thisWeekPath) : ""),
    jsonBlock("candidate-related-pages.json", readOptional(params.context.candidateRelatedPagesPath)),
    markdownBlock("selected-media.md", readOptional(params.context.selectedMediaPath)),
    markdownBlock("selected-raw-sources.md", readOptional(params.context.selectedRawSourcesPath)),
    "",
    "Return a WikiIngestPlan JSON object. Do not edit files directly.",
    "Every operation must use sourceIds from the selected array, except ignore_source which uses sourceId.",
    "Use paths under wiki/ for page, review, and map writes. Use append_log for wiki/log.md.",
    "Deterministic procedure code will move raw files; your plan should cite final raw paths in markdown.",
  ].join("\n");
}

export function buildRepairPrompt(params: {
  plan: WikiIngestPlan;
  lint: LintResult;
}): string {
  return [
    "Repair a WikiIngestPlan for the X bookmarks wiki procedure.",
    "Fix only the lint findings. Return the full replacement WikiIngestPlan JSON object.",
    "",
    "Previous plan:",
    JSON.stringify(params.plan, null, 2),
    "",
    "Lint result:",
    JSON.stringify(params.lint, null, 2),
  ].join("\n");
}

function readPromptModule(name: string): string {
  for (const candidate of [
    join(PROMPT_DIR, name),
    join(process.cwd(), ".nanoboss", "procedures", "xbookmarks", "prompts", name),
  ]) {
    try {
      return readFileSync(candidate, "utf8");
    } catch {
      // Try the next resolution strategy.
    }
  }
  throw new Error(`Could not read xbookmarks prompt module: ${name}`);
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
  const max = 80_000;
  return content.length <= max ? content : `${content.slice(0, max)}\n\n[truncated]`;
}

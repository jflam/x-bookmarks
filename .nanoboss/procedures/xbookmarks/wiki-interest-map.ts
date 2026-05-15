import { type Procedure } from "./lib/nanoboss.ts";
import {
  buildPriorDecisionContext,
  readSourceForSensemaking,
  reconcileInterestMap,
  resolveXBookmarksConfig,
  verifyInterestMap,
} from "./lib/index.ts";
import { readTextIfExists } from "./lib/fs.ts";

export default {
  name: "xbookmarks/wiki-interest-map",
  description: "Verify, reconcile, or inspect deterministic prior-decision context for the X bookmarks interest map",
  inputHint: "Examples: verify | reconcile --dry-run | prior-decisions --source raw/x/ingested/ID.md --limit 12",
  async execute(prompt, ctx) {
    const request = parseRequest(prompt);
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    if (request.command === "verify") {
      const result = await verifyInterestMap(config);
      return {
        data: result,
        display: [
          `status: ${result.ok ? "ok" : "failed"}`,
          `errors: ${result.errorCount}`,
          `warnings: ${result.warningCount}`,
          `artifacts: ${result.artifactPaths.join(", ")}`,
        ].join("\n"),
        summary: `xbookmarks/wiki-interest-map verify: ${result.ok ? "ok" : "failed"}`,
      };
    }
    if (request.command === "reconcile") {
      const result = await reconcileInterestMap(config, request.dryRun);
      return {
        data: result,
        display: [
          `mode: ${result.dryRun ? "dry-run" : "apply"}`,
          `parsed entries: ${result.parsedEntries}`,
          `new entries: ${result.newInterestIds.join(", ") || "none"}`,
          `renamed entries: ${result.renamedInterestIds.join(", ") || "none"}`,
          `alias changes: ${result.aliasChangedInterestIds.join(", ") || "none"}`,
          `deprecated entries: ${result.deprecatedInterestIds.join(", ") || "none"}`,
          `invalid source links: ${result.invalidSourceLinks.join(", ") || "none"}`,
          `unsafe entries: ${result.unsafeEntries.join("; ") || "none"}`,
          `applied: ${result.applied ? "yes" : "no"}`,
        ].join("\n"),
        summary: `xbookmarks/wiki-interest-map reconcile: ${result.parsedEntries} parsed, applied ${result.applied ? "yes" : "no"}`,
      };
    }
    const selected = await readSourceForSensemaking(config, request.source);
    const map = await readTextIfExists(`${config.managedRoot}/wiki/meta/interest-map.md`);
    const result = await buildPriorDecisionContext(config, selected, map, request.limit);
    return {
      data: result,
      display: result.markdown,
      summary: `xbookmarks/wiki-interest-map prior-decisions: ${result.items.length} item(s) for ${selected.sourceId}`,
    };
  },
} satisfies Procedure;

type Request =
  | { command: "verify" }
  | { command: "reconcile"; dryRun: boolean }
  | { command: "prior-decisions"; source: string; limit: number };

function parseRequest(prompt: string): Request {
  const parts = prompt.trim().split(/\s+/).filter(Boolean);
  const command = parts[0] ?? "verify";
  if (command === "verify") return { command };
  if (command === "reconcile") {
    let dryRun = true;
    for (const part of parts.slice(1)) {
      if (part === "--dry-run") dryRun = true;
      else if (part === "--yes") dryRun = false;
    }
    return { command, dryRun };
  }
  if (command === "prior-decisions") {
    let source = "";
    let limit = 12;
    for (let index = 1; index < parts.length; index += 1) {
      const part = parts[index];
      if (part === "--source") source = parts[++index] ?? "";
      else if (part === "--limit") limit = parsePositiveInt(parts[++index], "limit");
    }
    if (!source) throw new Error("prior-decisions requires --source PATH.");
    return { command, source, limit };
  }
  throw new Error(`Unknown interest-map command: ${command}`);
}

function parsePositiveInt(value: string | undefined, label: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) throw new Error(`${label} must be a positive integer.`);
  return parsed;
}

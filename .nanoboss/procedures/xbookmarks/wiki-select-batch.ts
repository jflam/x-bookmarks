import type { Procedure } from "./lib/nanoboss.ts";

import {
  defaultBatchId,
  parseNaturalSelectLimit,
  parseProgrammaticSelectOptions,
  resolveXBookmarksConfig,
  selectBatch,
} from "./lib/index.ts";

export default {
  name: "xbookmarks/wiki-select-batch",
  description: "Show the next exported X bookmark raw sources that would be processed",
  inputHint: "Example: Show me the next 25 exported bookmarks that would be processed.",
  async execute(prompt, ctx) {
    const structured = parseProgrammaticSelectOptions(prompt.trim());
    const limit = structured?.limit ?? parseNaturalSelectLimit(prompt);
    const batchId = structured?.batchId ?? defaultBatchId();
    const config = await resolveXBookmarksConfig({ cwd: ctx.cwd });
    const selected = await selectBatch({ managedRoot: config.managedRoot, limit });

    return {
      data: {
        batchId,
        config: {
          workspaceRoot: config.workspaceRoot,
          managedRoot: config.managedRoot,
          artifactRoot: config.artifactRoot,
        },
        selected,
      },
      display: [
        `workspaceRoot: ${config.workspaceRoot}`,
        `managedRoot: ${config.managedRoot}`,
        `artifactRoot: ${config.artifactRoot}`,
        `batchId: ${batchId}`,
        `selected: ${selected.length}`,
        "",
        ...selected.map((item, index) => `${index + 1}. ${item.sourceId} ${item.postedAt ?? item.exportedAt ?? ""} ${item.authorHandle ? `@${item.authorHandle}` : ""} - ${item.title}`),
      ].join("\n"),
      summary: `xbookmarks/wiki-select-batch: ${selected.length} selected`,
    };
  },
} satisfies Procedure;

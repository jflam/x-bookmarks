import { basename, join } from "node:path";
import { readFile } from "node:fs/promises";

import { frontmatterString, parseFrontmatter } from "./frontmatter.ts";
import { listMarkdownFilesShallow, safeStatMtime, sha256Hex } from "./fs.ts";
import type { SelectBatchOptions, SelectedBookmark } from "./types.ts";

export async function selectBatch(options: SelectBatchOptions): Promise<SelectedBookmark[]> {
  const inboxRoot = join(options.managedRoot, "raw", "x", "inbox");
  const files = await listMarkdownFilesShallow(inboxRoot);
  const selected = await Promise.all(files.map(readSelectedBookmark));
  return selected
    .sort(compareSelectedBookmarks)
    .slice(0, options.limit);
}

export async function readSelectedBookmark(path: string): Promise<SelectedBookmark> {
  const markdown = await readFile(path, "utf8");
  const { data, body } = parseFrontmatter(markdown);
  const tweetId = frontmatterString(data, "tweet_id") ?? basename(path, ".md");
  const author = frontmatterString(data, "author_username");
  return {
    sourceId: tweetId,
    rawPath: path,
    tweetId,
    title: extractTitle(body, tweetId, author),
    contentHash: sha256Hex(markdown),
    authorHandle: author || undefined,
    postedAt: frontmatterString(data, "created_at"),
    exportedAt: frontmatterString(data, "bookmarked_at") ?? await safeStatMtime(path),
    canonicalUrl: frontmatterString(data, "canonical_url") || frontmatterString(data, "twitter_url"),
  };
}

function compareSelectedBookmarks(a: SelectedBookmark, b: SelectedBookmark): number {
  const aDate = dateMillis(a.postedAt) ?? dateMillis(a.exportedAt) ?? 0;
  const bDate = dateMillis(b.postedAt) ?? dateMillis(b.exportedAt) ?? 0;
  if (aDate !== bDate) return bDate - aDate;
  return b.tweetId.localeCompare(a.tweetId);
}

function dateMillis(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const millis = Date.parse(value);
  return Number.isFinite(millis) ? millis : undefined;
}

function extractTitle(body: string, tweetId: string, author: string | undefined): string {
  const heading = /^#\s+(.+)$/m.exec(body)?.[1]?.trim();
  if (heading) return heading;
  const firstText = body.split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith("!") && !line.startsWith("#"));
  if (firstText) return firstText.slice(0, 120);
  return author ? `X Bookmark @${author} / ${tweetId}` : `X Bookmark ${tweetId}`;
}

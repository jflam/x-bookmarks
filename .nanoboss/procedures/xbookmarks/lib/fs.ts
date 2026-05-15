import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { access, mkdir, readFile, readdir, rename, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

export async function fileExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export async function readTextIfExists(path: string): Promise<string> {
  return (await fileExists(path)) ? readFile(path, "utf8") : "";
}

export async function writeJson(path: string, value: unknown): Promise<void> {
  await writeTextAtomic(path, `${JSON.stringify(value, null, 2)}\n`);
}

export async function writeTextAtomic(path: string, content: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmpPath = `${path}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tmpPath, content, "utf8");
  await rename(tmpPath, path);
}

export async function appendTextAtomic(path: string, content: string): Promise<void> {
  const existing = await readTextIfExists(path);
  await writeTextAtomic(path, `${existing}${existing.endsWith("\n") || existing.length === 0 ? "" : "\n"}${content}`);
}

export async function listMarkdownFiles(root: string): Promise<string[]> {
  if (!(await fileExists(root))) return [];
  const files: string[] = [];
  await walk(root, files);
  return files.sort();
}

export async function listMarkdownFilesShallow(root: string): Promise<string[]> {
  if (!(await fileExists(root))) return [];
  const entries = await readdir(root, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".md"))
    .map((entry) => join(root, entry.name))
    .sort();
}

export async function safeStatMtime(path: string): Promise<string | undefined> {
  try {
    return (await stat(path)).mtime.toISOString();
  } catch {
    return undefined;
  }
}

export function sha256Hex(content: string): string {
  return createHash("sha256").update(content).digest("hex");
}

export function ensureInsideRoot(root: string, candidate: string, label = "path"): string {
  const resolvedRoot = resolve(root);
  const resolvedCandidate = resolve(candidate);
  const rel = relative(resolvedRoot, resolvedCandidate);
  if (rel === "" || (!rel.startsWith("..") && !isAbsolute(rel))) {
    return resolvedCandidate;
  }
  throw new Error(`${label} escapes configured root: ${candidate}`);
}

export function resolveMaybeRelative(base: string, candidate: string): string {
  return isAbsolute(candidate) ? resolve(candidate) : resolve(base, candidate);
}

export function toPosixRelative(fromRoot: string, path: string): string {
  return relative(fromRoot, path).split(sep).join("/");
}

async function walk(root: string, files: string[]): Promise<void> {
  const entries = await readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      await walk(path, files);
    } else if (entry.isFile() && entry.name.endsWith(".md")) {
      files.push(path);
    }
  }
}

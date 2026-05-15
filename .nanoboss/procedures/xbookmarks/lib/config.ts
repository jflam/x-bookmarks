import { join, resolve } from "node:path";
import { readFile } from "node:fs/promises";

import { ensureInsideRoot, fileExists, resolveMaybeRelative } from "./fs.ts";
import type { XBookmarksConfig } from "./types.ts";

interface ConfigResolutionOptions {
  cwd: string;
}

export async function resolveXBookmarksConfig(options: ConfigResolutionOptions): Promise<XBookmarksConfig> {
  const cwd = resolve(options.cwd);
  const configPath = join(cwd, ".nanoboss", "xbookmarks", "config.json");
  const localConfig = await readJsonObject(configPath);
  const dataConfigPath = join(cwd, "data", "config.json");
  const rootConfigPath = join(cwd, "config.json");
  const dataConfig = await readJsonObject(dataConfigPath);
  const rootConfig = dataConfig ? undefined : await readJsonObject(rootConfigPath);
  const existingConfig = dataConfig ?? rootConfig;

  const workspaceRoot = resolveMaybeRelative(
    cwd,
    env("XBOOKMARKS_WORKSPACE_ROOT")
      ?? stringValue(localConfig?.workspaceRoot)
      ?? cwd,
  );

  const managedRoot = env("XBOOKMARKS_MANAGED_ROOT")
    ?? stringValue(localConfig?.managedRoot)
    ?? managedRootFromExistingConfig(existingConfig);

  if (!managedRoot) {
    throw new Error(
      "Could not resolve X bookmarks managedRoot. Set XBOOKMARKS_MANAGED_ROOT or create .nanoboss/xbookmarks/config.json.",
    );
  }

  const artifactRoot = resolveMaybeRelative(
    workspaceRoot,
    env("XBOOKMARKS_ARTIFACT_ROOT")
      ?? stringValue(localConfig?.artifactRoot)
      ?? join(".nanoboss", "xbookmarks", "runs"),
  );

  const xBookmarksBinary = resolveMaybeRelative(
    workspaceRoot,
    env("XBOOKMARKS_BINARY")
      ?? stringValue(localConfig?.xBookmarksBinary)
      ?? join("zig-out", "bin", "x-bookmarks"),
  );
  const configuredHome = env("XBOOKMARKS_HOME") ?? stringValue(localConfig?.xBookmarksHome);
  const xBookmarksHome = configuredHome
    ? resolveMaybeRelative(workspaceRoot, configuredHome)
    : dataConfig
      ? resolveMaybeRelative(workspaceRoot, "data")
      : undefined;

  ensureInsideRoot(workspaceRoot, artifactRoot, "artifactRoot");
  if (xBookmarksHome) ensureInsideRoot(workspaceRoot, xBookmarksHome, "xBookmarksHome");

  return {
    workspaceRoot,
    managedRoot: resolveMaybeRelative(workspaceRoot, managedRoot),
    artifactRoot,
    xBookmarksBinary,
    xBookmarksHome,
  };
}

async function readJsonObject(path: string): Promise<Record<string, unknown> | undefined> {
  if (!(await fileExists(path))) return undefined;
  const parsed = JSON.parse(await readFile(path, "utf8"));
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Expected JSON object in ${path}`);
  }
  return parsed as Record<string, unknown>;
}

function managedRootFromExistingConfig(config: Record<string, unknown> | undefined): string | undefined {
  const obsidian = recordValue(config?.obsidian);
  const vaultPath = stringValue(obsidian?.vault_path);
  const rootDir = stringValue(obsidian?.root_dir) ?? "X Bookmarks";
  return vaultPath ? join(vaultPath, rootDir) : undefined;
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function env(name: string): string | undefined {
  const value = process.env[name];
  return value && value.trim() ? value : undefined;
}

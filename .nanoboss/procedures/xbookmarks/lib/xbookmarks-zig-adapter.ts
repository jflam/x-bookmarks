import { spawn } from "node:child_process";
import { join } from "node:path";

import { writeJson } from "./fs.ts";
import type { CommandTranscript, SyncAndExportOptions } from "./types.ts";

export async function syncAndExportRawX(options: SyncAndExportOptions): Promise<CommandTranscript[]> {
  const transcripts: CommandTranscript[] = [];
  const baseArgs = options.config.xBookmarksHome ? ["--home", options.config.xBookmarksHome] : [];
  const syncArgs = ["sync", "--yolo"];
  if (options.fullSync) syncArgs.splice(1, 0, "--full");
  transcripts.push(await runCommand(options.config.xBookmarksBinary, [...baseArgs, ...syncArgs], options.config.workspaceRoot));
  transcripts.push(await runCommand(
    options.config.xBookmarksBinary,
    [...baseArgs, "kb", "export-raw-x", ...(options.changedOnly ? ["--changed"] : [])],
    options.config.workspaceRoot,
  ));
  await writeJson(join(options.config.artifactRoot, "last-sync-transcript.json"), transcripts);
  return transcripts;
}

function runCommand(command: string, args: string[], cwd: string): Promise<CommandTranscript> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk) => stdout.push(Buffer.from(chunk)));
    child.stderr.on("data", (chunk) => stderr.push(Buffer.from(chunk)));
    child.on("error", reject);
    child.on("close", (exitCode) => {
      const transcript = {
        command: [command, ...args],
        exitCode: exitCode ?? -1,
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      };
      if (transcript.exitCode !== 0) {
        reject(new Error(`Command failed (${transcript.exitCode}): ${transcript.command.join(" ")}\n${transcript.stderr}`));
      } else {
        resolve(transcript);
      }
    });
  });
}

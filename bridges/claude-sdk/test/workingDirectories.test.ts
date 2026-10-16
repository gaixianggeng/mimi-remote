// transcript 工作目录兜底读取（#722）：只认顶层 cwd、跨块长行、文件长大后重读。
import { afterAll, describe, expect, test } from "bun:test";
import { appendFileSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { WorkingDirectories, type TranscriptFile } from "../src/claude/transcripts.ts";

const sandbox = mkdtempSync(path.join(os.tmpdir(), "mimi-claude-cwd-"));
afterAll(() => rmSync(sandbox, { recursive: true, force: true }));

function transcript(name: string, lines: unknown[], trailingNewline = true): TranscriptFile {
  const file = path.join(sandbox, `${name}.jsonl`);
  writeFileSync(file, lines.map((line) => JSON.stringify(line)).join("\n") + (trailingNewline ? "\n" : ""));
  return { sessionId: name, path: file, size: statSync(file).size, mtimeMs: 0 };
}

describe("WorkingDirectories", () => {
  test("skips a cwd nested in tool input and takes the first top-level one after a long line", async () => {
    const file = transcript("nested", [
      { type: "queue-operation", operation: "enqueue" },
      {
        type: "assistant",
        message: { content: [{ type: "tool_use", input: { cwd: "/elsewhere", data: "B".repeat(600 * 1024) } }] },
      },
      { type: "user", message: { content: "next" }, cwd: "/work/project" },
    ]);
    expect(await new WorkingDirectories().firstCwd(file)).toBe("/work/project");
  });

  test("reads the last line without a trailing newline", async () => {
    const file = transcript("tail", [{ type: "user", message: { content: "hi" }, cwd: "/work/tail" }], false);
    expect(await new WorkingDirectories().firstCwd(file)).toBe("/work/tail");
  });

  test("retries a transcript without cwd once it grows", async () => {
    const directories = new WorkingDirectories();
    const file = transcript("growing", [{ type: "queue-operation", operation: "enqueue" }]);
    expect(await directories.firstCwd(file)).toBeUndefined();
    appendFileSync(file.path, `${JSON.stringify({ type: "user", message: { content: "hi" }, cwd: "/work/later" })}\n`);
    expect(await directories.firstCwd({ ...file, size: statSync(file.path).size })).toBe("/work/later");
  });
});

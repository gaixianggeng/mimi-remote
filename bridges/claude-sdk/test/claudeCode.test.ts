// Claude Code 版本下限（#660）：探测、比较、缓存，以及过旧时 turn/start 给出明确提示。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import { ClaudeCodeVersionGate, compareVersions, probeClaudeCodeVersion, type ClaudeCodeProbe } from "../src/claude/claudeCode.ts";
import { Session } from "../src/session/session.ts";
import { MINIMUM_CLAUDE_CODE_VERSION } from "../src/version.ts";

const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-claude-code-")));

function script(name: string, output: string): string {
  const file = path.join(sandbox, name);
  writeFileSync(file, `#!/bin/sh\necho '${output}'\n`);
  chmodSync(file, 0o755);
  return file;
}

afterAll(() => rmSync(sandbox, { recursive: true, force: true }));

describe("version probe", () => {
  test("versions compare numerically", () => {
    expect(compareVersions("2.1.294", "2.1.294")).toBe(0);
    expect(compareVersions("2.1.300", "2.1.294")).toBe(1);
    expect(compareVersions("2.0.999", "2.1.0")).toBe(-1);
    expect(compareVersions("10.0.0", "9.9.9")).toBe(1);
  });

  test("the CLI's --version output is parsed; a missing or silent CLI is told apart", async () => {
    expect(await probeClaudeCodeVersion(script("claude-ok", "2.1.296 (Claude Code)"))).toEqual({ status: "ok", version: "2.1.296" });
    expect(await probeClaudeCodeVersion(script("claude-odd", "Claude Code"))).toEqual({ status: "unknown" });
    expect(await probeClaudeCodeVersion(path.join(sandbox, "no-such-claude"))).toEqual({ status: "missing" });
  });

  test("the gate caches a pass but re-checks after a failure", async () => {
    let answer: ClaudeCodeProbe = { status: "ok", version: "2.1.100" };
    let calls = 0;
    const gate = new ClaudeCodeVersionGate(
      () => "/opt/claude",
      async () => {
        calls += 1;
        return answer;
      },
      "2.1.294",
    );
    const error = await gate.ensure().catch((caught) => caught);
    expect(error.data).toEqual({ reason: "claude_unsupported", version: "2.1.100", minimumVersion: "2.1.294" });
    expect(error.message).toContain("claude update");
    answer = { status: "ok", version: "2.1.294" };
    await gate.ensure();
    await gate.ensure();
    expect(calls).toBe(2);
    answer = { status: "missing" };
    expect((await new ClaudeCodeVersionGate(() => "claude", async () => answer).ensure().catch((caught) => caught)).data.reason).toBe("claude_missing");
  });
});

describe("turn/start", () => {
  let app: App;

  beforeAll(async () => {
    process.env.CLAUDE_CONFIG_DIR = path.join(sandbox, "claude");
    process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
    const { createApp } = await import("../src/app.ts");
    app = createApp({
      stateDir: path.join(sandbox, "state"),
      log: () => {},
      claudeExecutable: () => "claude",
      probeClaudeCode: async () => ({ status: "ok", version: "2.0.1" }),
    });
  });

  afterAll(async () => {
    await app?.manager.closeAll();
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.MIMI_CLAUDE_LEGACY_INDEX;
  });

  test("an outdated Claude Code is refused before any process starts, with the upgrade hint", async () => {
    const session = new Session("old-cli");
    const { generation } = session.attach(undefined, () => {}, false);
    const dispatch = (id: number, method: string, params: unknown) => app.router.dispatch({ id, method, params }, { session, generation });
    const started = (await dispatch(1, "thread/start", { cwd: sandbox })) as { result: { thread: { id: string } } };
    const response = await dispatch(2, "turn/start", { threadId: started.result.thread.id, cwd: sandbox, input: [{ type: "text", text: "hi", text_elements: [] }] });
    expect(response).toMatchObject({
      error: { code: -32603, data: { reason: "claude_unsupported", version: "2.0.1", minimumVersion: MINIMUM_CLAUDE_CODE_VERSION } },
    });
    expect(app.manager.loadedThreadIds()).toEqual([]);
  });
});

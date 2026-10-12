// 适配器日志：固定格式（agentd 按级别分流）、级别过滤、主目录脱敏，以及关键处的打点。
import { afterEach, describe, expect, test } from "bun:test";
import os from "node:os";
import { LiveTurn } from "../src/runtime/liveTurn.ts";
import { Router } from "../src/server/router.ts";
import { Session } from "../src/session/session.ts";
import { configureLogging, formatLogLine, logText, logger } from "../src/util/logging.ts";

let restore: (() => void) | undefined;
afterEach(() => restore?.());

function capture(level: "info" | "debug"): string[] {
  const lines: string[] = [];
  restore = configureLogging({ level, sink: (line) => lines.push(line) });
  return lines;
}

describe("log format", () => {
  test("lines carry the adapter tag, the level and quoted values", () => {
    const line = formatLogLine("debug", "thread.list", {
      cwd: `${os.homedir()}/code/repo`,
      returned: 3,
      note: "two words",
      empty: "",
      skipped: undefined,
      multi: "a\nb",
    });
    expect(line).toBe('[mimi-claude-adapter] debug thread.list cwd=~/code/repo returned=3 note="two words" empty="" multi="a b"');
  });

  test("levels below the threshold are dropped; free text keeps its level", () => {
    const lines = capture("info");
    logger.debug("rpc", { method: "thread/list" });
    logger.info("adapter.start", { version: "0.3.0" });
    logText("warn", "something odd");
    expect(lines).toEqual(["[mimi-claude-adapter] info adapter.start version=0.3.0", "[mimi-claude-adapter] warn something odd"]);
  });
});

describe("key points", () => {
  test("every RPC records its method, session, duration and error code", async () => {
    const lines = capture("debug");
    const router = new Router(new Map([["thread/list", () => ({ data: [] })]]), () => {});
    const session = new Session("ipad-1");
    const { generation } = session.attach(undefined, () => {}, false);
    await router.dispatch({ id: 1, method: "thread/list", params: {} }, { session, generation });
    await router.dispatch({ id: 2, method: "review/start", params: {} }, { session, generation });
    expect(lines[0]).toMatch(/^\[mimi-claude-adapter\] debug rpc method=thread\/list id=1 session=ipad-1 ms=\d+$/);
    expect(lines[1]).toMatch(/^\[mimi-claude-adapter\] debug rpc method=review\/start id=2 session=ipad-1 ms=\d+ error=-32601$/);
  });

  test("a finished turn records its status without any content", () => {
    const lines = capture("debug");
    const turn = new LiveTurn("turn-1", "thread-1", () => {});
    turn.begin();
    turn.userMessage("turn-1", null, [{ type: "text", text: "private prompt", text_elements: [] }] as never);
    turn.finish({ subtype: "success", errors: [], usage: undefined, contextWindow: null }, undefined);
    const completed = lines.find((line) => line.includes("turn.complete"));
    expect(completed).toBe("[mimi-claude-adapter] debug turn.complete thread=thread-1 turn=turn-1 status=completed subtype=success");
    expect(lines.join("\n")).not.toContain("private prompt");
  });
});

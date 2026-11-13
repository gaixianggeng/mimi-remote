import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { ThreadManager } from "../src/runtime/manager.ts";
import type { RunSettings } from "../src/runtime/settings.ts";
import { Session } from "../src/session/session.ts";
import { ScriptedQuery } from "./support/scripted-query.ts";

// #911：没有订阅者、也不再工作的运行时要从管理器回收，长期访问不同会话不能无限累积。
const managers: ThreadManager[] = [];
const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-runtime-reclaim-")));
let previousConfig: string | undefined;
beforeAll(() => {
  previousConfig = process.env.CLAUDE_CONFIG_DIR;
  process.env.CLAUDE_CONFIG_DIR = path.join(sandbox, "config");
});
afterAll(() => {
  if (previousConfig === undefined) delete process.env.CLAUDE_CONFIG_DIR;
  else process.env.CLAUDE_CONFIG_DIR = previousConfig;
  rmSync(sandbox, { recursive: true, force: true });
});
afterEach(async () => { await Promise.all(managers.splice(0).map((manager) => manager.closeAll())); });

const settings: RunSettings = {
  model: undefined, effort: undefined, permissionMode: "default",
  executionPolicy: { type: "dangerFullAccess" },
};
const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 5));

function harness(reclaimDelayMs = 0) {
  const queries: ScriptedQuery[] = [];
  const manager = new ThreadManager({
    claudeExecutable: () => "unused",
    log: () => {},
    reclaimDelayMs,
    startQuery: ((args: { prompt: AsyncIterable<unknown> }) => {
      const query = new ScriptedQuery();
      query.attach(args.prompt);
      queries.push(query);
      return query;
    }) as never,
  });
  managers.push(manager);
  const session = new Session("ipad");
  session.attach(undefined, () => {}, false);
  const internals = manager as unknown as { runtimes: Map<string, unknown>; titles: Map<string, unknown>; subscribers: Map<string, unknown> };
  return { manager, session, queries, internals };
}

describe("idle runtime reclamation", () => {
  test("runtimes, titles and empty subscriber sets are reclaimed after the last subscriber leaves", async () => {
    const { manager, session, internals } = harness();
    const ids = Array.from({ length: 1000 }, (_, n) => `thread-${n}`);
    for (const id of ids) {
      manager.open(id, sandbox, settings, `title ${id}`);
      manager.subscribe(id, session);
    }
    manager.unsubscribeSession(session);
    await tick();

    expect(manager.loadedThreadIds()).toEqual([]);
    expect(internals.runtimes.size).toBe(0);
    expect(internals.titles.size).toBe(0);
    expect(internals.subscribers.size).toBe(0);
  });

  test("resubscribing before the delay keeps the same runtime", async () => {
    const { manager, session, internals } = harness(20);
    const runtime = manager.open("thread-a", sandbox, settings);
    manager.subscribe("thread-a", session);
    manager.unsubscribeSession(session);
    manager.subscribe("thread-a", session);
    await new Promise((resolve) => setTimeout(resolve, 40));

    expect(manager.get("thread-a")).toBe(runtime);
    expect(internals.runtimes.size).toBe(1);
  });

  test("a started thread without a transcript is kept so its ID can still be resumed", async () => {
    const { manager, session } = harness();
    const runtime = manager.create(sandbox, settings, "thread-new");
    manager.subscribe("thread-new", session);
    manager.unsubscribeSession(session);
    await tick();

    expect(manager.get("thread-new")).toBe(runtime);
  });

  test("a runtime with a running turn is kept until its process exits, then rebuilt on resume", async () => {
    const { manager, session, queries } = harness();
    const runtime = manager.create(sandbox, settings, "thread-busy");
    manager.subscribe("thread-busy", session);
    const turn = await runtime.startTurn({ input: [{ type: "text", text: "go", text_elements: [] }], clientUserMessageId: null, settings: {} });
    manager.unsubscribeSession(session);
    await tick();
    expect(manager.get("thread-busy")).toBe(runtime);

    queries[0]!.emit({ type: "result", subtype: "success", user_message_uuids: [turn.id], session_id: "thread-busy" });
    await tick();
    expect(runtime.activeTurnId).toBeUndefined();
    expect(manager.get("thread-busy")).toBe(runtime);

    queries[0]!.close();
    await tick();
    await tick();
    expect(manager.get("thread-busy")).toBeUndefined();

    const reopened = manager.open("thread-busy", sandbox, settings);
    expect(reopened).not.toBe(runtime);
    expect(manager.get("thread-busy")).toBe(reopened);
  });
});

// 接管规则（只结束核实过的空闲持有方、SIGINT 后 SIGTERM 兜底、重生不再杀）与占用登记的读取过滤。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { holdersOf, readHolders, type OwnProcesses, type SessionHolder } from "../src/runtime/holders.ts";
import {
  parseElapsed,
  processStartedAt,
  releaseForeignHolders,
  TakeoverError,
  type TakeoverDeps,
  type TakeoverReason,
} from "../src/runtime/takeover.ts";

const NOW = 1_800_000_000_000;
const holder = (pid: number, status: string | null, startedAt: number | null = NOW): SessionHolder => ({
  pid,
  entrypoint: "cli",
  kind: "interactive",
  status,
  version: "2",
  startedAt,
  statusUpdatedAt: null,
});

/** 可编排的进程世界：哪些 pid 活着、收到信号后谁退出、退出后谁重新认领。 */
function world(initial: SessionHolder[], behavior: { exitsOn?: Array<"SIGINT" | "SIGTERM">; respawn?: SessionHolder } = {}) {
  let holders = [...initial];
  const alive = new Set(initial.map((entry) => entry.pid));
  const signals: Array<[number, string]> = [];
  const deps: TakeoverDeps = {
    holdersOf: async () => holders.filter((entry) => alive.has(entry.pid)),
    processStartedAt: async (pid) => holders.find((entry) => entry.pid === pid)?.startedAt ?? undefined,
    signal: (pid, signal) => {
      signals.push([pid, signal]);
      if (behavior.exitsOn?.includes(signal)) {
        alive.delete(pid);
        if (behavior.respawn) {
          holders = [...holders, behavior.respawn];
          alive.add(behavior.respawn.pid);
        }
      }
    },
    alive: (pid) => alive.has(pid),
    sleep: async () => {},
  };
  return { deps, signals, alive };
}

const fast = { interruptGraceMs: 5, terminateGraceMs: 5, respawnGraceMs: 0 };

async function failure(promise: Promise<unknown>): Promise<TakeoverError> {
  const error = await promise.then(
    () => undefined,
    (caught) => caught,
  );
  expect(error).toBeInstanceOf(TakeoverError);
  return error as TakeoverError;
}

describe("releaseForeignHolders", () => {
  test("without a holder it is a plain resume", async () => {
    const { deps, signals } = world([]);
    expect(await releaseForeignHolders("s", deps, fast)).toEqual({ released: false });
    expect(signals).toEqual([]);
  });

  test("an idle verified holder is interrupted and released", async () => {
    const { deps, signals } = world([holder(4242, "idle")], { exitsOn: ["SIGINT"] });
    const outcome = await releaseForeignHolders("s", deps, fast);
    expect(outcome).toMatchObject({ released: true, signal: "SIGINT" });
    expect(signals).toEqual([[4242, "SIGINT"]]);
  });

  test("a holder that ignores SIGINT gets SIGTERM after its state is re-checked", async () => {
    const { deps, signals } = world([holder(4242, "idle")], { exitsOn: ["SIGTERM"] });
    expect(await releaseForeignHolders("s", deps, fast)).toMatchObject({ released: true, signal: "SIGTERM" });
    expect(signals).toEqual([
      [4242, "SIGINT"],
      [4242, "SIGTERM"],
    ]);
  });

  test("a holder that survives both signals times out and stays retryable", async () => {
    const { deps } = world([holder(4242, "idle")]);
    const error = await failure(releaseForeignHolders("s", deps, fast));
    expect(error).toMatchObject({ reason: "takeover_timeout", retryable: true });
  });

  test("busy, unknown and unverifiable holders are never signalled", async () => {
    const cases: Array<[SessionHolder[], TakeoverReason, boolean]> = [
      [[holder(4242, "busy")], "holder_busy", true],
      [[holder(4242, "shell")], "holder_busy", true],
      [[holder(4242, null)], "holder_state_unknown", true],
      [[holder(4242, "idle", null)], "holder_unverified", false],
      // 多个持有方里只要有一个在忙，连空闲的那个也不动。
      [[holder(4242, "idle"), holder(4343, "busy")], "holder_busy", true],
    ];
    for (const [holders, reason, retryable] of cases) {
      const { deps, signals } = world(holders, { exitsOn: ["SIGINT", "SIGTERM"] });
      const error = await failure(releaseForeignHolders("s", deps, fast));
      expect(error.reason).toBe(reason);
      expect(error.retryable).toBe(retryable);
      expect(signals).toEqual([]);
    }
  });

  test("a reused pid whose start time does not match its registration is not signalled", async () => {
    const { deps, signals } = world([holder(4242, "idle")], { exitsOn: ["SIGINT"] });
    deps.processStartedAt = async () => NOW - 60 * 60_000;
    const error = await failure(releaseForeignHolders("s", deps, fast));
    expect(error.reason).toBe("holder_unverified");
    expect(signals).toEqual([]);
  });

  test("a host that respawns a new holder is reported instead of killed again", async () => {
    const { deps, signals } = world([holder(4242, "idle")], { exitsOn: ["SIGINT"], respawn: holder(5353, "idle") });
    const error = await failure(releaseForeignHolders("s", deps, fast));
    expect(error).toMatchObject({ reason: "holder_respawned", retryable: false });
    expect(error.holder.pid).toBe(5353);
    expect(signals).toEqual([[4242, "SIGINT"]]);
  });
});

describe("process start time", () => {
  test("ps elapsed time formats parse to seconds", () => {
    expect(parseElapsed("  01:02\n")).toBe(62);
    expect(parseElapsed("03:01:02")).toBe(3 * 3600 + 62);
    expect(parseElapsed("2-03:01:02")).toBe(2 * 86_400 + 3 * 3600 + 62);
    expect(parseElapsed("garbage")).toBeUndefined();
  });

  test.skipIf(process.platform === "win32")("a freshly started process reports a start time close to now", async () => {
    const child = spawn("sleep", ["30"], { stdio: "ignore" });
    try {
      const startedAt = await processStartedAt(child.pid!);
      expect(startedAt).toBeDefined();
      expect(Math.abs(startedAt! - Date.now())).toBeLessThan(5_000);
      expect(await processStartedAt(999_999_999)).toBeUndefined();
    } finally {
      child.kill();
    }
  });
});

describe("session registry", () => {
  const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-holders-")));
  const sessions = path.join(sandbox, "sessions");
  const children: ChildProcess[] = [];
  const live = () => {
    const child = spawn("sleep", ["30"], { stdio: "ignore" });
    children.push(child);
    return child.pid!;
  };
  const register = (pid: number, sessionId: string, status: string, startedAt = Date.now()) =>
    writeFileSync(path.join(sessions, `${pid}.json`), JSON.stringify({ pid, sessionId, status, startedAt, entrypoint: "cli", kind: "interactive" }));
  const own = (pids: number[] = [], starting: Record<string, number> = {}): OwnProcesses => ({
    pids: new Set(pids),
    startingSince: (sessionId) => starting[sessionId],
  });

  beforeAll(() => {
    mkdirSync(sessions, { recursive: true });
    process.env.CLAUDE_CONFIG_DIR = sandbox;
  });

  afterAll(() => {
    for (const child of children) child.kill();
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(sandbox, { recursive: true, force: true });
  });

  test("dead, own and corrupt registrations are not foreign holders; a busy holder wins the summary", async () => {
    const [idle, busy, mine] = [live(), live(), live()];
    register(idle, "shared", "idle");
    register(busy, "shared", "busy");
    register(mine, "mine", "busy");
    register(999_999_999, "stale", "idle");
    writeFileSync(path.join(sessions, "broken.json"), "{");

    const holders = await readHolders(own([mine]));
    expect([...holders.keys()]).toEqual(["shared"]);
    expect(holders.get("shared")).toMatchObject({ pid: busy, status: "busy" });
    expect((await holdersOf("shared", own([mine]))).map((entry) => entry.pid).sort()).toEqual([idle, busy].sort());
  });

  test("a registration that may be the adapter's own starting process is deferred", async () => {
    const pid = live();
    const startedAt = Date.now();
    register(pid, "starting", "idle", startedAt + 200);
    expect((await readHolders(own([], { starting: startedAt }))).has("starting")).toBe(false);
    // 早在自己起进程之前就已持有的，仍然算别处。
    expect((await readHolders(own([], { starting: startedAt + 60_000 }))).has("starting")).toBe(true);
  });
});

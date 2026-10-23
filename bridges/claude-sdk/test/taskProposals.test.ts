import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRouter, turnHintsEnabledFromEnvironment } from "../src/app.ts";
import { Overlay } from "../src/claude/overlay.ts";
import { Session } from "../src/session/session.ts";

const temporaryDirectories: string[] = [];

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(path.join(os.tmpdir(), "mimi-task-proposals-"));
  temporaryDirectories.push(directory);
  return directory;
}

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function call(router: ReturnType<typeof createRouter>, method: string, params: unknown) {
  const session = new Session("proposal-test");
  const { generation } = session.attach(undefined, () => {}, false);
  return router.dispatch({ id: 1, method, params }, { session, generation });
}

describe("Mimi task proposals", () => {
  test("turn hints default on and accept explicit off values", () => {
    expect(turnHintsEnabledFromEnvironment(undefined)).toBe(true);
    expect(turnHintsEnabledFromEnvironment("")).toBe(true);
    for (const value of ["0", "false", "off", "disabled", " FALSE "]) {
      expect(turnHintsEnabledFromEnvironment(value)).toBe(false);
    }
    expect(turnHintsEnabledFromEnvironment("true")).toBe(true);
  });

  test("concurrent consumption binds one persisted child and retries reuse it", async () => {
    const state = await temporaryDirectory();
    const file = path.join(state, "overlay.json");
    const overlay = new Overlay(file, undefined);
    const proposalID = await overlay.recordTaskProposal("parent-1", "/repo", {
      title: "Follow-up",
      prompt: "Continue it",
    });

    const [first, second] = await Promise.all([
      overlay.consumeTaskProposal(proposalID, "parent-1", "/repo", "child-1"),
      overlay.consumeTaskProposal(proposalID, "parent-1", "/repo", "child-2"),
    ]);
    expect(first?.consumedByThreadId).toBe("child-1");
    expect(second?.consumedByThreadId).toBe("child-1");
    expect(overlay.spawnedFrom("child-1")).toBe("parent-1");
    expect(overlay.spawnedFrom("child-2")).toBeNull();

    const reloaded = new Overlay(file, undefined);
    await reloaded.load();
    expect(reloaded.spawnedFrom("child-1")).toBe("parent-1");
    expect(JSON.parse(await readFile(file, "utf8")).taskProposals[proposalID].consumedByThreadId).toBe("child-1");
  });

  test("thread/start validates the proposal binding and repeated delivery returns the same child", async () => {
    const state = await temporaryDirectory();
    const overlay = new Overlay(path.join(state, "overlay.json"), undefined);
    const proposalID = await overlay.recordTaskProposal("parent-1", "/repo", {
      title: "Follow-up",
      prompt: "Continue it",
    });
    const router = createRouter({ stateDir: state, log: () => {}, turnHintsEnabled: true });
    const params = {
      cwd: "/repo",
      mimiTaskProposal: { id: proposalID, parentThreadId: "parent-1" },
    };

    const first = await call(router, "thread/start", params);
    const second = await call(router, "thread/start", params);
    if (!("result" in first) || !("result" in second)) throw new Error("thread/start failed");
    const firstThread = (first.result as any).thread;
    const secondThread = (second.result as any).thread;
    expect(secondThread.id).toBe(firstThread.id);
    expect(firstThread.spawnedFromThreadId).toBe("parent-1");
    expect(firstThread.parentThreadId).toBeNull();
    expect(firstThread.canAcceptDirectInput).toBe(true);

    const wrongParent = await call(router, "thread/start", {
      cwd: "/repo",
      mimiTaskProposal: { id: proposalID, parentThreadId: "other-parent" },
    });
    const wrongCWD = await call(router, "thread/start", {
      cwd: "/other",
      mimiTaskProposal: { id: proposalID, parentThreadId: "parent-1" },
    });
    expect(wrongParent).toMatchObject({ error: { code: -32602 } });
    expect(wrongCWD).toMatchObject({ error: { code: -32602 } });
  });
});

import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createApp, createRouter, turnHintsEnabledFromEnvironment } from "../src/app.ts";
import { Overlay } from "../src/claude/overlay.ts";
import type { ClaudeSessions } from "../src/claude/sdk.ts";
import { Session } from "../src/session/session.ts";
import { ScriptedQuery } from "./support/scripted-query.ts";

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
    const transcriptSessions = new Set<string>();
    const sessions: ClaudeSessions = {
      list: async () => [],
      info: async (sessionId) => transcriptSessions.has(sessionId)
        ? ({ sessionId, cwd: "/repo", lastModified: Date.now() } as any)
        : undefined,
      messages: async () => [],
      rename: async () => {},
    };
    const router = createRouter({ stateDir: state, log: () => {}, turnHintsEnabled: true, sessions });
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
    expect((first.result as any).mimiTaskProposal.initialTurnStarted).toBe(false);
    expect((second.result as any).mimiTaskProposal.initialTurnStarted).toBe(false);

    transcriptSessions.add(firstThread.id);
    const completedRetry = await call(router, "thread/start", params);
    if (!("result" in completedRetry)) throw new Error("thread/start retry failed");
    expect((completedRetry.result as any).thread.id).toBe(firstThread.id);
    expect((completedRetry.result as any).mimiTaskProposal.initialTurnStarted).toBe(true);

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

  test("adapter restart opens a consumed child as a resumable transcript", async () => {
    const state = await temporaryDirectory();
    const overlay = new Overlay(path.join(state, "overlay.json"), undefined);
    const proposalID = await overlay.recordTaskProposal("parent-1", "/repo", {
      title: "Follow-up",
      prompt: "Continue it",
    });
    await overlay.consumeTaskProposal(proposalID, "parent-1", "/repo", "child-existing");
    const sessions: ClaudeSessions = {
      list: async () => [],
      info: async (sessionId) => sessionId === "child-existing"
        ? ({ sessionId, cwd: "/repo", customTitle: "Existing child", lastModified: Date.now() } as any)
        : undefined,
      messages: async () => [],
      rename: async () => {},
    };
    let queryOptions: Record<string, unknown> | undefined;
    const app = createApp({
      stateDir: state,
      log: () => {},
      turnHintsEnabled: true,
      sessions,
      probeClaudeCode: async () => ({ status: "ok", version: "9.9.9" }),
      startQuery: (({ prompt, options }: { prompt: AsyncIterable<unknown>; options: Record<string, unknown> }) => {
        queryOptions = options;
        const query = new ScriptedQuery();
        query.attach(prompt);
        return query;
      }) as never,
    });

    try {
      const started = await call(app.router, "thread/start", {
        cwd: "/repo",
        mimiTaskProposal: { id: proposalID, parentThreadId: "parent-1" },
      });
      if (!("result" in started)) throw new Error("thread/start retry failed");
      expect((started.result as any).mimiTaskProposal.initialTurnStarted).toBe(true);

      const turn = await call(app.router, "turn/start", {
        threadId: "child-existing",
        input: [{ type: "text", text: "next turn", text_elements: [] }],
        approvalPolicy: "never",
        sandbox: "dangerFullAccess",
      });
      if (!("result" in turn)) throw new Error("turn/start failed");
      expect(queryOptions?.resume).toBe("child-existing");
      expect(queryOptions?.sessionId).toBeUndefined();
    } finally {
      await app.manager.closeAll();
    }
  });
});

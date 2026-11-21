import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { serveConnection } from "@mimi/appserver-kit/server/connection.ts";
import { SessionRegistry } from "@mimi/appserver-kit/session/registry.ts";
import { capabilityDeclaration, createApp } from "../src/app.ts";
import { FakeAgyWorld } from "./support/fake-agy.ts";

describe("mimi-agy-adapter end-to-end runtime", () => {
  let tempRoot = "";
  let fakeHome = "";
  let workspaceDir = "";
  let stateDir = "";

  beforeEach(async () => {
    tempRoot = await mkdtemp(path.join(os.tmpdir(), "mimi-agy-test-"));
    fakeHome = path.join(tempRoot, "home");
    workspaceDir = path.join(tempRoot, "workspace");
    stateDir = path.join(tempRoot, "state");
    await mkdir(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations"), { recursive: true });
    await mkdir(workspaceDir, { recursive: true });
  });

  afterEach(async () => {
    if (tempRoot) {
      await rm(tempRoot, { recursive: true, force: true });
    }
  });

  async function createTestHarness(world: FakeAgyWorld, extra: { externalWritePollMs?: number } = {}) {
    const env = () => ({ HOME: fakeHome });
    const app = createApp({
      stateDir,
      log: () => {},
      agyExecutable: () => "/usr/local/bin/fake-agy",
      probeAgy: async () => ({ version: "1.5.10" }),
      spawnTransport: world.spawnTransport,
      env,
      ...(extra.externalWritePollMs !== undefined ? { externalWritePollMs: extra.externalWritePollMs } : {}),
    });
    const registry = new SessionRegistry({
      idleTtlMs: 60_000,
      onExpire: (session) => app.manager.unsubscribeSession(session),
    });
    registry.onCreate = (session) => session.setBusyCheck(() => app.manager.isSessionBusy(session));

    const clientToServer = new PassThrough();
    const serverToClient = new PassThrough();
    const connDone = serveConnection(clientToServer, serverToClient, {
      registry,
      router: app.router,
      log: () => {},
      onClientResponse: (session, generation, frame) => app.manager.handleClientResponse(session, generation, frame),
      onAnonymousSessionEnd: (session) => app.manager.unsubscribeSession(session),
    });

    const notifications: Array<Record<string, unknown>> = [];
    const serverRequests: Array<Record<string, unknown>> = [];
    const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
    let nextId = 1;
    let buf = "";

    serverToClient.on("data", (chunk: Buffer | string) => {
      buf += typeof chunk === "string" ? chunk : chunk.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        nl = buf.indexOf("\n");
        if (!line) continue;
        const frame = JSON.parse(line) as Record<string, unknown>;
        if (typeof frame.method === "string" && frame.id !== undefined && frame.id !== null) {
          serverRequests.push(frame);
        } else if (typeof frame.method === "string") {
          notifications.push(frame);
        } else if (typeof frame.id === "number") {
          const waiter = pending.get(frame.id);
          if (waiter) {
            pending.delete(frame.id);
            if (frame.error) waiter.reject(new Error(JSON.stringify(frame.error)));
            else waiter.resolve(frame.result);
          }
        }
      }
    });

    const rpc = <T = Record<string, unknown>>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
      const id = nextId++;
      return new Promise<T>((resolve, reject) => {
        pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
        clientToServer.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      });
    };

    const respondServerRequest = (id: unknown, result: Record<string, unknown>) => {
      clientToServer.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
    };

    clientToServer.write(`${JSON.stringify({ jsonrpc: "2.0", method: "_alleycat/attach", params: { sessionKey: "ios-test-device" } })}\n`);
    for (let i = 0; i < 20; i += 1) {
      if (notifications.some((n) => n.method === "_alleycat/attached")) break;
      await new Promise((r) => setTimeout(r, 10));
    }

    return {
      app,
      rpc,
      respondServerRequest,
      notifications,
      serverRequests,
      async close() {
        clientToServer.end();
        await connDone;
        await app.close();
      },
    };
  }

  test("declares capabilities, sends clientCapabilities: {}, streams turns, usage, auto-title, and slash commands", async () => {
    const world = new FakeAgyWorld();
    const harness = await createTestHarness(world);
    try {
      const caps = capabilityDeclaration(harness.app.router);
      expect(caps.name).toBe("mimi-agy-adapter");
      expect(caps.fullAccess).toBe(true);
      expect(caps.methods).toContain("slashCommand/list");
      expect(caps.methods).toContain("model/list");

      const started = await harness.rpc<{ thread: { id: string } }>("thread/start", {
        cwd: workspaceDir,
        approvalPolicy: "on-request",
        approvalsReviewer: "accept_edits",
        sandboxPolicy: { type: "workspaceWrite", writableRoots: [workspaceDir], networkAccess: false },
      });
      const threadId = started.thread.id;
      expect(threadId).toBe("fake-agy-session-1");
      // D6: initialize must send empty clientCapabilities so agy executes its own native tools
      expect(world.initializePayloads[0]?.clientCapabilities).toEqual({});
      expect(world.sessions.get(threadId)?.modeId).toBe("accept-edits");

      // Wait briefly for async available_commands_update
      await new Promise((r) => setTimeout(r, 40));
      const slashRes = await harness.rpc<{ data: Array<{ name: string }> }>("slashCommand/list", { cwd: workspaceDir });
      expect(slashRes.data.map((c) => c.name)).toContain("goal");
      expect(slashRes.data.map((c) => c.name)).not.toContain("clear");

      const modelsRes = await harness.rpc<{ data: Array<{ id: string }> }>("model/list", {});
      expect(modelsRes.data.map((m) => m.id)).toContain("gemini-4-hydrogen");

      await harness.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        model: "gemini-4-hydrogen",
        effort: "xhigh",
        input: [{ type: "text", text: "Hello Antigravity", text_elements: [] }],
      });

      // Wait for turn/completed notification
      for (let i = 0; i < 40; i += 1) {
        if (harness.notifications.some((n) => n.method === "turn/completed")) break;
        await new Promise((r) => setTimeout(r, 20));
      }

      expect(world.sessions.get(threadId)?.model).toBe("gemini-4-hydrogen");
      expect(world.sessions.get(threadId)?.thoughtLevel).toBe("xhigh");
      expect(harness.notifications.some((n) => n.method === "item/reasoning/textDelta")).toBe(true);
      expect(harness.notifications.some((n) => n.method === "item/agentMessage/delta")).toBe(true);
      expect(harness.notifications.some((n) => n.method === "thread/tokenUsage/updated")).toBe(true);
      expect(harness.notifications.some((n) => n.method === "thread/name/updated")).toBe(true);

      const turnsPage = await harness.rpc<{ data: Array<{ itemsView: string; items: Array<{ type: string }> }> }>(
        "thread/turns/list",
        { threadId, itemsView: "summary" },
      );
      expect(turnsPage.data).toHaveLength(1);
      expect(turnsPage.data[0]?.itemsView).toBe("summary");
      expect(turnsPage.data[0]?.items.map((i) => i.type)).toEqual(["userMessage", "agentMessage"]);
      // 同一个 appDataDir 下，model/list、slashCommand/list、thread/start 与 turn/start 必须共享唯一常驻 agy acp 进程，
      // 避免多进程并发打开 conversations/*.db 触发 SQLite `database is locked`。
      expect(world.spawns.filter((opt) => opt.appDataDirName !== "antigravity")).toHaveLength(1);
    } finally {
      await harness.close();
    }
  });

  test("classifies CLI and Other sessions by db directory, routes Other replay via antigravity appDataDir, and filters orphans", async () => {
    const cliSessionId = "cli-backed-session";
    const otherSessionId = "desktop-other-session";
    const orphanSessionId = "orphan-no-db-session";
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${cliSessionId}.db`),
      "sqlite-placeholder",
    );
    await mkdir(path.join(fakeHome, ".gemini", "antigravity", "conversations"), { recursive: true });
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity", "conversations", `${otherSessionId}.db`),
      "sqlite-placeholder",
    );

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId: cliSessionId,
          cwd: workspaceDir,
          title: "CLI Session",
          updatedAt: "2026-11-18T10:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [
            { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Hi from Herdr" } },
            { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hello back!" } },
          ],
        },
        {
          sessionId: otherSessionId,
          cwd: workspaceDir,
          title: "Desktop Other Session",
          updatedAt: "2026-11-18T11:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [
            { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Hi from Desktop" } },
            { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Loaded from antigravity!" } },
          ],
        },
        {
          sessionId: orphanSessionId,
          cwd: workspaceDir,
          title: "Orphan Session",
          updatedAt: "2026-11-18T12:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });

    const harness = await createTestHarness(world);
    try {
      const listed = await harness.rpc<{ data: Array<{ id: string; name: string | null; source: unknown }> }>("thread/list", {
        cwd: workspaceDir,
      });
      expect(listed.data.map((t) => ({ id: t.id, source: t.source }))).toEqual([
        { id: otherSessionId, source: { custom: "other" } },
        { id: cliSessionId, source: "cli" },
      ]);

      const readCli = await harness.rpc<{ thread: { source: unknown; turns: Array<{ items: Array<{ type: string }> }> } }>("thread/read", {
        threadId: cliSessionId,
        includeTurns: true,
      });
      expect(readCli.thread.source).toBe("cli");
      expect(readCli.thread.turns).toHaveLength(1);
      expect(readCli.thread.turns[0]?.items.map((i) => i.type)).toEqual(["userMessage", "agentMessage"]);

      const readOther = await harness.rpc<{ thread: { source: unknown; turns: Array<{ items: Array<{ type: string }> }> } }>("thread/read", {
        threadId: otherSessionId,
        includeTurns: true,
      });
      expect(readOther.thread.source).toEqual({ custom: "other" });
      expect(readOther.thread.turns).toHaveLength(1);
      expect(readOther.thread.turns[0]?.items.map((i) => i.type)).toEqual(["userMessage", "agentMessage"]);
      expect(world.spawns.some((opt) => opt.appDataDirName === "antigravity")).toBe(true);
    } finally {
      await harness.close();
    }
  });

  test("forwards ACP session/request_permission to client approval card and returns selected option", async () => {
    let observedOutcome: unknown;
    const world = new FakeAgyWorld({
      onPrompt: async ({ emitUpdate, requestPermission }) => {
        emitUpdate({
          sessionUpdate: "tool_call",
          toolCallId: "call-cmd-1",
          title: "Run tests",
          kind: "execute",
          status: "pending",
          rawInput: { CommandLine: "bun test" },
        });
        observedOutcome = await requestPermission(
          { toolCallId: "call-cmd-1", title: "Run tests", kind: "execute", rawInput: { CommandLine: "bun test" } },
          [
            { optionId: "opt-allow-once", name: "Allow once", kind: "allow_once" },
            { optionId: "opt-reject", name: "Reject", kind: "reject_once" },
          ],
        );
        emitUpdate({
          sessionUpdate: "tool_call_update",
          toolCallId: "call-cmd-1",
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: "1 passed" } }],
        });
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Tests passed." } });
        return { stopReason: "end_turn" };
      },
    });

    const harness = await createTestHarness(world);
    try {
      const started = await harness.rpc<{ thread: { id: string } }>("thread/start", {
        cwd: workspaceDir,
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        sandboxPolicy: { type: "workspaceWrite", writableRoots: [workspaceDir], networkAccess: false },
      });
      await harness.rpc("turn/start", {
        threadId: started.thread.id,
        cwd: workspaceDir,
        input: [{ type: "text", text: "Please run tests", text_elements: [] }],
      });

      for (let i = 0; i < 40; i += 1) {
        if (harness.serverRequests.length > 0) break;
        await new Promise((r) => setTimeout(r, 20));
      }
      expect(harness.serverRequests).toHaveLength(1);
      expect(harness.serverRequests[0]?.method).toBe("item/commandExecution/requestApproval");
      harness.respondServerRequest(harness.serverRequests[0]?.id, { decision: "accept" });

      for (let i = 0; i < 40; i += 1) {
        if (harness.notifications.some((n) => n.method === "turn/completed")) break;
        await new Promise((r) => setTimeout(r, 20));
      }
      expect(observedOutcome).toEqual({ outcome: { outcome: "selected", optionId: "opt-allow-once" } });
    } finally {
      await harness.close();
    }
  });

  test("resuming an old session does not bump its updatedAt above newer sessions", async () => {
    const oldSessionId = "old-cli-session";
    const newerSessionId = "newer-cli-session";
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${oldSessionId}.db`),
      "sqlite-placeholder",
    );
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${newerSessionId}.db`),
      "sqlite-placeholder",
    );

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId: oldSessionId,
          cwd: workspaceDir,
          title: "Old Session",
          updatedAt: "2026-11-18T10:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
        {
          sessionId: newerSessionId,
          cwd: workspaceDir,
          title: "Newer Session",
          updatedAt: "2026-11-20T01:22:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });

    const harness = await createTestHarness(world);
    try {
      await harness.rpc("thread/resume", { threadId: oldSessionId, cwd: workspaceDir });
      const listed = await harness.rpc<{ data: Array<{ id: string; updatedAt: number }> }>("thread/list", {
        cwd: workspaceDir,
      });
      expect(listed.data.map((t) => t.id)).toEqual([newerSessionId, oldSessionId]);
      const oldRow = listed.data.find((t) => t.id === oldSessionId);
      expect(oldRow?.updatedAt).toBe(Math.floor(Date.parse("2026-11-18T10:00:00Z") / 1000));
    } finally {
      await harness.close();
    }
  });

  test("live turn IDs and item IDs match persisted transcript history without duplication on reopen", async () => {
    const world = new FakeAgyWorld({
      onPrompt: async ({ emitUpdate }) => {
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "ok" } });
        return { stopReason: "end_turn" };
      },
    });

    const harness = await createTestHarness(world);
    try {
      const started = await harness.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      const threadId = started.thread.id;
      const clientId = "client-msg-ok-1";
      const turnRes = await harness.rpc<{ turn: { id: string } }>("turn/start", {
        threadId,
        cwd: workspaceDir,
        clientUserMessageId: clientId,
        input: [{ type: "text", text: "测试 回复 ok", text_elements: [] }],
      });

      for (let i = 0; i < 40; i += 1) {
        if (harness.notifications.some((n) => n.method === "turn/completed")) break;
        await new Promise((r) => setTimeout(r, 20));
      }

      const itemOf = (params: unknown) =>
        (params as { item?: { type?: string; id?: string; clientId?: string | null; text?: string } } | undefined)?.item;
      const liveUser = harness.notifications.find((n) => n.method === "item/completed" && itemOf(n.params)?.type === "userMessage");
      const liveAgent = harness.notifications.find((n) => n.method === "item/completed" && itemOf(n.params)?.type === "agentMessage");
      const liveUserItem = itemOf(liveUser?.params)!;
      const liveAgentItem = itemOf(liveAgent?.params)!;

      expect(turnRes.turn.id).toBe(`${threadId}:turn:1`);
      expect(liveUserItem.id).toBe(`${threadId}:turn:1:user`);
      expect(liveUserItem.clientId).toBe(clientId);
      expect(liveAgentItem.id).toBe(`${threadId}:turn:1:msg:1`);

      // 模拟 agy 把刚完成的回合写入 transcript_full.jsonl，客户端随后重开会话拉取 thread/turns/list。
      const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      await writeFile(
        path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`),
        "sqlite-placeholder",
      );
      await writeFile(
        path.join(logsDir, "transcript_full.jsonl"),
        [
          JSON.stringify({
            step_index: 0,
            type: "USER_INPUT",
            status: "DONE",
            created_at: "2026-11-20T01:22:01Z",
            content: "<USER_REQUEST>\n测试 回复 ok\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 1,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: "2026-11-20T01:22:02Z",
            content: "ok",
          }),
        ].join("\n"),
      );

      const historyRes = await harness.rpc<{
        data: Array<{ id: string; items: Array<{ type: string; id: string; clientId?: string | null; text?: string }> }>;
      }>("thread/turns/list", { threadId, itemsView: "full" });
      expect(historyRes.data).toHaveLength(1);
      expect(historyRes.data[0]?.id).toBe(turnRes.turn.id);
      expect(historyRes.data[0]?.items[0]).toMatchObject({
        type: "userMessage",
        id: liveUserItem.id,
        clientId,
      });
      expect(historyRes.data[0]?.items[1]).toMatchObject({
        type: "agentMessage",
        id: liveAgentItem.id,
        text: "ok",
      });
    } finally {
      await harness.close();
    }
  });

  test("drains trailing post-session/load replay updates before starting a new live turn", async () => {
    const existingId = "large-existing-session";
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${existingId}.db`),
      "sqlite-placeholder",
    );

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId: existingId,
          cwd: workspaceDir,
          title: "Large Session",
          updatedAt: "2026-11-21T02:09:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [
            { sessionUpdate: "user_message_chunk", content: { type: "text", text: "First prompt" } },
          ],
          postLoadReplayUpdates: [
            {
              delayMs: 30,
              update: {
                sessionUpdate: "tool_call",
                toolCallId: "stale-prev-tool",
                title: "Stale previous turn tool",
                kind: "execute",
                status: "completed",
              },
            },
            {
              delayMs: 70,
              update: {
                sessionUpdate: "agent_message_chunk",
                content: { type: "text", text: "Stale previous assistant reply" },
              },
            },
          ],
        },
      ],
      onPrompt: async ({ emitUpdate }) => {
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Fresh new reply" } });
        return { stopReason: "end_turn" };
      },
    });

    const harness = await createTestHarness(world);
    try {
      await harness.rpc("thread/resume", { threadId: existingId, cwd: workspaceDir });
      await harness.rpc("turn/start", {
        threadId: existingId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "Second prompt", text_elements: [] }],
      });

      for (let i = 0; i < 60; i += 1) {
        if (harness.notifications.some((n) => n.method === "turn/completed")) break;
        await new Promise((r) => setTimeout(r, 20));
      }

      const completedItems = harness.notifications
        .filter((n) => n.method === "item/completed")
        .map((n) => (n.params as { item?: { type?: string; text?: string; id?: string } }).item);
      const agentTexts = completedItems.filter((i) => i?.type === "agentMessage").map((i) => i?.text);
      const toolIds = completedItems.filter((i) => i?.type === "commandExecution").map((i) => i?.id);

      expect(agentTexts).toEqual(["Fresh new reply"]);
      expect(toolIds).toEqual([]);
    } finally {
      await harness.close();
    }
  });

  test("C12: detects concurrent external Mac CLI write during pending approval, cancels approval, and fails turn explicitly", async () => {
    let observedOutcome: unknown;
    let promptAborted = false;
    const world = new FakeAgyWorld({
      onPrompt: async ({ session, emitUpdate, requestPermission, signal }) => {
        signal.addEventListener("abort", () => {
          promptAborted = true;
        });
        emitUpdate({
          sessionUpdate: "tool_call",
          toolCallId: "call-pwd-1",
          title: "Run pwd",
          kind: "execute",
          status: "pending",
          rawInput: { CommandLine: "pwd" },
        });
        observedOutcome = await requestPermission(
          { toolCallId: "call-pwd-1", title: "Run pwd", kind: "execute", rawInput: { CommandLine: "pwd" } },
          [
            { optionId: "opt-allow-once", name: "Allow once", kind: "allow_once" },
            { optionId: "opt-reject", name: "Reject", kind: "reject_once" },
          ],
        );
        return { stopReason: "cancelled" };
      },
    });

    const harness = await createTestHarness(world, { externalWritePollMs: 25 });
    try {
      const started = await harness.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      const threadId = started.thread.id;
      const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      await writeFile(
        path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`),
        "sqlite-placeholder",
      );
      const transcriptPath = path.join(logsDir, "transcript_full.jsonl");
      const priorLines = [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: new Date(Date.now() - 5_000).toISOString(),
          content: "<USER_REQUEST>\nPrior completed turn\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: new Date(Date.now() - 4_000).toISOString(),
          content: "Prior answer",
        }),
      ];
      await writeFile(transcriptPath, `${priorLines.join("\n")}\n`);

      await harness.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "Run pwd and wait for approval", text_elements: [] }],
      });

      for (let i = 0; i < 40; i += 1) {
        if (harness.serverRequests.length > 0) break;
        await new Promise((r) => setTimeout(r, 15));
      }
      expect(harness.serverRequests).toHaveLength(1);

      // Simulate Mac CLI writing a contending turn into the same session while iPad holds the approval.
      await writeFile(
        transcriptPath,
        [
          ...priorLines,
          JSON.stringify({
            step_index: 2,
            type: "USER_INPUT",
            status: "DONE",
            created_at: new Date().toISOString(),
            content: "<USER_REQUEST>\nRun pwd and wait for approval\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 3,
            type: "USER_INPUT",
            status: "DONE",
            created_at: new Date().toISOString(),
            content: "<USER_REQUEST>\nCROSS MAC CONTENDING\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 4,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: new Date().toISOString(),
            content: "CROSS MAC CONTENDING",
          }),
        ].join("\n") + "\n",
      );

      for (let i = 0; i < 60; i += 1) {
        if (harness.notifications.some((n) => n.method === "turn/completed")) break;
        await new Promise((r) => setTimeout(r, 20));
      }

      expect(observedOutcome).toEqual({ outcome: { outcome: "cancelled" } });
      expect(promptAborted).toBe(true);
      expect(harness.notifications.some((n) => n.method === "serverRequest/resolved")).toBe(true);
      const completed = harness.notifications.find((n) => n.method === "turn/completed");
      const completedTurn = (completed?.params as { turn?: { status?: string; error?: { message?: string } | null } })?.turn;
      expect(completedTurn?.status).toBe("failed");
      expect(completedTurn?.error?.message).toContain("Another Antigravity process");

      // Also verify turn/start rejects when an external process is actively running.
      await writeFile(
        transcriptPath,
        `${JSON.stringify({
          step_index: 3,
          type: "USER_INPUT",
          status: "RUNNING",
          created_at: new Date().toISOString(),
          content: "<USER_REQUEST>\nExternal busy\n</USER_REQUEST>",
        })}\n`,
      );
      await expect(
        harness.rpc("turn/start", {
          threadId,
          cwd: workspaceDir,
          input: [{ type: "text", text: "Should be blocked", text_elements: [] }],
        }),
      ).rejects.toThrow("currently active");
    } finally {
      await harness.close();
    }
  });

  test("B10: preserves failed and interrupted turn terminal status and structured error across cold restart on both ACP replay and transcript paths", async () => {
    let callCount = 0;
    const world = new FakeAgyWorld({
      onPrompt: async ({ emitUpdate }) => {
        callCount += 1;
        if (callCount === 1) {
          emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "before failure" } });
          throw new Error("EDGE_FIXTURE_E42: injected turn failure");
        }
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "partial before stop" } });
        return { stopReason: "cancelled" };
      },
    });

    const firstHarness = await createTestHarness(world);
    let threadId = "";
    try {
      const started = await firstHarness.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      threadId = started.thread.id;
      await writeFile(
        path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`),
        "sqlite-placeholder",
      );

      await firstHarness.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "edge-error", text_elements: [] }],
      });
      for (let i = 0; i < 40; i += 1) {
        if (firstHarness.notifications.filter((n) => n.method === "turn/completed").length >= 1) break;
        await new Promise((r) => setTimeout(r, 15));
      }

      await firstHarness.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "edge-stop", text_elements: [] }],
      });
      for (let i = 0; i < 40; i += 1) {
        if (firstHarness.notifications.filter((n) => n.method === "turn/completed").length >= 2) break;
        await new Promise((r) => setTimeout(r, 15));
      }
    } finally {
      await firstHarness.close();
    }

    // Cold restart (new adapter instance reading the same stateDir/overlay.json):
    // 1) ACP replay path (no transcript file yet).
    const coldHarness = await createTestHarness(world);
    try {
      const replayHistory = await coldHarness.rpc<{
        data: Array<{ id: string; status: string; error: { message: string } | null }>;
      }>("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full" });
      expect(replayHistory.data).toHaveLength(2);
      expect(replayHistory.data[0]?.status).toBe("failed");
      expect(replayHistory.data[0]?.error?.message).toContain("EDGE_FIXTURE_E42");
      expect(replayHistory.data[1]?.status).toBe("interrupted");
      expect(replayHistory.data[1]?.error).toBeNull();

      // 2) Transcript direct-read path (even if transcript itself does not mark the failed/interrupted steps).
      const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      await writeFile(
        path.join(logsDir, "transcript_full.jsonl"),
        [
          JSON.stringify({
            step_index: 0,
            type: "USER_INPUT",
            status: "DONE",
            created_at: "2026-11-21T10:00:00Z",
            content: "<USER_REQUEST>\nedge-error\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 1,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: "2026-11-21T10:00:01Z",
            content: "before failure",
          }),
          JSON.stringify({
            step_index: 2,
            type: "USER_INPUT",
            status: "DONE",
            created_at: "2026-11-21T10:00:02Z",
            content: "<USER_REQUEST>\nedge-stop\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 3,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: "2026-11-21T10:00:03Z",
            content: "partial before stop",
          }),
        ].join("\n") + "\n",
      );

      const transcriptHistory = await coldHarness.rpc<{
        data: Array<{ id: string; status: string; error: { message: string } | null }>;
      }>("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full" });
      expect(transcriptHistory.data).toHaveLength(2);
      expect(transcriptHistory.data[0]?.status).toBe("failed");
      expect(transcriptHistory.data[0]?.error?.message).toContain("EDGE_FIXTURE_E42");
      expect(transcriptHistory.data[1]?.status).toBe("interrupted");
      expect(transcriptHistory.data[1]?.error).toBeNull();
    } finally {
      await coldHarness.close();
    }
  });

  test("B15/C05: command and fileChange item IDs stay identical across live streaming, approvals, ACP replay, and cold transcript read", async () => {
    const world = new FakeAgyWorld({
      onPrompt: async ({ emitUpdate, requestPermission }) => {
        emitUpdate({
          sessionUpdate: "tool_call",
          toolCallId: "native-random-cmd-99",
          title: "Run pwd",
          kind: "execute",
          status: "pending",
          rawInput: { CommandLine: "pwd" },
        });
        await requestPermission(
          { toolCallId: "native-random-cmd-99", title: "Run pwd", kind: "execute", rawInput: { CommandLine: "pwd" } },
          [{ optionId: "allow", name: "Allow once", kind: "allow_once" }],
        );
        emitUpdate({
          sessionUpdate: "tool_call_update",
          toolCallId: "native-random-cmd-99",
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: workspaceDir } }],
        });
        emitUpdate({
          sessionUpdate: "tool_call",
          toolCallId: "native-random-diff-88",
          title: "Edit notes.txt",
          kind: "edit",
          status: "completed",
          content: [{ type: "diff", path: path.join(workspaceDir, "notes.txt"), oldText: "a", newText: "b" }],
        });
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done." } });
        return { stopReason: "end_turn" };
      },
    });

    const first = await createTestHarness(world);
    let threadId = "";
    let liveCmdId = "";
    let liveDiffId = "";
    let approvalItemId = "";
    try {
      const started = await first.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      threadId = started.thread.id;
      await writeFile(
        path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`),
        "sqlite-placeholder",
      );
      await first.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "run pwd and edit notes.txt", text_elements: [] }],
      });
      for (let i = 0; i < 40; i += 1) {
        if (first.serverRequests.length > 0) break;
        await new Promise((r) => setTimeout(r, 15));
      }
      approvalItemId = String((first.serverRequests[0]?.params as { itemId?: string } | undefined)?.itemId ?? "");
      first.respondServerRequest(first.serverRequests[0]?.id, { decision: "accept" });
      for (let i = 0; i < 40; i += 1) {
        if (first.notifications.some((n) => n.method === "turn/completed")) break;
        await new Promise((r) => setTimeout(r, 15));
      }
      const completedItems = first.notifications
        .filter((n) => n.method === "item/completed")
        .map((n) => (n.params as { item?: { type?: string; id?: string } }).item);
      liveCmdId = completedItems.find((i) => i?.type === "commandExecution")?.id ?? "";
      liveDiffId = completedItems.find((i) => i?.type === "fileChange")?.id ?? "";
      expect(liveCmdId).toBe(`${threadId}:turn:1:tool:1`);
      expect(liveDiffId).toBe(`${threadId}:turn:1:tool:2`);
      expect(approvalItemId).toBe(liveCmdId);
    } finally {
      await first.close();
    }

    const cold = await createTestHarness(world);
    try {
      // 1) Cold ACP replay path
      const replayTurns = await cold.rpc<{ data: Array<{ items: Array<{ type: string; id: string }> }> }>(
        "thread/turns/list",
        { threadId, itemsView: "full" },
      );
      expect(replayTurns.data[0]?.items.find((i) => i.type === "commandExecution")?.id).toBe(liveCmdId);
      expect(replayTurns.data[0]?.items.find((i) => i.type === "fileChange")?.id).toBe(liveDiffId);

      // 2) Cold transcript direct-read path
      const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      await writeFile(
        path.join(logsDir, "transcript_full.jsonl"),
        [
          JSON.stringify({
            step_index: 0,
            type: "USER_INPUT",
            status: "DONE",
            created_at: "2026-11-21T11:00:00Z",
            content: "<USER_REQUEST>\nrun pwd and edit notes.txt\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 1,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: "2026-11-21T11:00:01Z",
            tool_calls: [
              { name: "run_command", args: { CommandLine: "\"pwd\"" } },
              { name: "edit_file", args: { Path: path.join(workspaceDir, "notes.txt"), Target: "a", Replacement: "b" } },
            ],
          }),
          JSON.stringify({ step_index: 2, type: "GENERIC", status: "DONE", content: workspaceDir }),
          JSON.stringify({ step_index: 3, type: "GENERIC", status: "DONE", content: "updated" }),
          JSON.stringify({ step_index: 4, type: "PLANNER_RESPONSE", status: "DONE", content: "Done." }),
        ].join("\n") + "\n",
      );

      const transcriptTurns = await cold.rpc<{ data: Array<{ items: Array<{ type: string; id: string }> }> }>(
        "thread/turns/list",
        { threadId, itemsView: "full" },
      );
      expect(transcriptTurns.data[0]?.items.find((i) => i.type === "commandExecution")?.id).toBe(liveCmdId);
      expect(transcriptTurns.data[0]?.items.find((i) => i.type === "fileChange")?.id).toBe(liveDiffId);
    } finally {
      await cold.close();
    }
  });

  test("B20: continuing a session pinned to a non-default model does not overwrite global default model in model/list", async () => {
    const pinnedId = "pinned-hydrogen-session";
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${pinnedId}.db`),
      "sqlite-placeholder",
    );
    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId: pinnedId,
          cwd: workspaceDir,
          title: "Pinned Hydrogen",
          updatedAt: "2026-11-21T10:00:00Z",
          modeId: "default",
          model: "gemini-4-hydrogen",
          thoughtLevel: "high",
          replayUpdates: [
            { sessionUpdate: "user_message_chunk", content: { type: "text", text: "hi" } },
            { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hello" } },
          ],
        },
      ],
      onPrompt: async ({ emitUpdate }) => {
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "continued" } });
        return { stopReason: "end_turn" };
      },
    });

    const harness = await createTestHarness(world);
    try {
      const before = await harness.rpc<{ data: Array<{ id: string; isDefault: boolean }> }>("model/list", {});
      expect(before.data.find((m) => m.isDefault)?.id).toBe("gemini-4-carbon");

      await harness.rpc("thread/resume", { threadId: pinnedId, cwd: workspaceDir });
      await harness.rpc("turn/start", {
        threadId: pinnedId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "continue pinned session", text_elements: [] }],
      });
      for (let i = 0; i < 40; i += 1) {
        if (harness.notifications.some((n) => n.method === "turn/completed")) break;
        await new Promise((r) => setTimeout(r, 15));
      }

      const after = await harness.rpc<{ data: Array<{ id: string; isDefault: boolean }> }>("model/list", {});
      expect(after.data.find((m) => m.isDefault)?.id).toBe("gemini-4-carbon");
      expect(after.data.find((m) => m.id === "gemini-4-hydrogen")?.isDefault).toBe(false);
      expect(world.sessions.get(pinnedId)?.model).toBe("gemini-4-hydrogen");
    } finally {
      await harness.close();
    }
  });
});

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { serveConnection } from "@mimi/appserver-kit/server/connection.ts";
import { SessionRegistry } from "@mimi/appserver-kit/session/registry.ts";
import { capabilityDeclaration, createApp } from "../src/app.ts";
import type { AcpSessionUpdate } from "../src/acp/types.ts";
import type { SpawnAgyTransport } from "../src/agy/binary.ts";
import type { OtherListDiagnostic } from "../src/agy/catalog.ts";
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

  async function createTestHarness(
    world: FakeAgyWorld,
    extra: {
      externalWritePollMs?: number;
      spawnTransport?: SpawnAgyTransport;
      env?: () => NodeJS.ProcessEnv;
      onOtherListDiagnostic?: (diag: OtherListDiagnostic) => void;
    } = {},
  ) {
    const env = extra.env ?? (() => ({ HOME: fakeHome }));
    const app = createApp({
      stateDir,
      log: () => {},
      agyExecutable: () => "/usr/local/bin/fake-agy",
      probeAgy: async () => ({ version: "1.5.10" }),
      spawnTransport: extra.spawnTransport ?? world.spawnTransport,
      env,
      ...(extra.externalWritePollMs !== undefined ? { externalWritePollMs: extra.externalWritePollMs } : {}),
      ...(extra.onOtherListDiagnostic ? { onOtherListDiagnostic: extra.onOtherListDiagnostic } : {}),
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
      expect(liveCmdId).toBe(`${threadId}:turn:1:tool:native-random-cmd-99`);
      expect(liveDiffId).toBe(`${threadId}:turn:1:tool:native-random-diff-88`);
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

  test("C10: discovers sessions present only in the Other native ACP index", async () => {
    const otherOnlyId = "other-only-native-session";
    await mkdir(path.join(fakeHome, ".gemini", "antigravity", "conversations"), { recursive: true });
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity", "conversations", `${otherOnlyId}.db`),
      "sqlite-placeholder",
    );

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId: otherOnlyId,
          cwd: workspaceDir,
          title: "Other Only Fixture",
          updatedAt: "2026-11-21T12:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          appDataDirName: "antigravity",
          replayUpdates: [
            { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Hello from Other" } },
            { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Other reply" } },
          ],
        },
      ],
    });

    const harness = await createTestHarness(world);
    try {
      const globalList = await harness.rpc<{ data: Array<{ id: string; source: unknown }> }>("thread/list", {});
      expect(globalList.data.map((t) => ({ id: t.id, source: t.source }))).toEqual([
        { id: otherOnlyId, source: { custom: "other" } },
      ]);

      const scopedList = await harness.rpc<{ data: Array<{ id: string; source: unknown }> }>("thread/list", {
        cwd: workspaceDir,
      });
      expect(scopedList.data.map((t) => ({ id: t.id, source: t.source }))).toEqual([
        { id: otherOnlyId, source: { custom: "other" } },
      ]);

      const readRes = await harness.rpc<{ thread: { id: string; source: unknown; turns: Array<{ items: Array<{ type: string }> }> } }>(
        "thread/read",
        { threadId: otherOnlyId, includeTurns: true },
      );
      expect(readRes.thread.source).toEqual({ custom: "other" });
      expect(readRes.thread.turns).toHaveLength(1);
    } finally {
      await harness.close();
    }
  });

  test("B11: normalizes ACP Authentication required error into actionable agy sign-in guidance", async () => {
    const world = new FakeAgyWorld({
      sessionNewError: { code: -32000, message: "Authentication required" },
    });
    const harness = await createTestHarness(world);
    try {
      await expect(harness.rpc("thread/start", { cwd: workspaceDir })).rejects.toThrow("agy_authentication_required");
    } finally {
      await harness.close();
    }
  });

  test("C14/C15: keeps sessions discoverable and readable as read-only with cwdMissing when directory is moved or removed", async () => {
    const missingSubdir = path.join(workspaceDir, "moved-or-removed-dir");
    await mkdir(missingSubdir, { recursive: true });
    const sessionId = "missing-cwd-session";
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`),
      "sqlite-placeholder",
    );

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: missingSubdir,
          title: "Removed Workspace Fixture",
          updatedAt: "2026-11-21T13:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [
            { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Hello before delete" } },
            { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Saved reply" } },
          ],
        },
      ],
    });

    // Remove the directory before querying the adapter.
    await rm(missingSubdir, { recursive: true, force: true });

    const harness = await createTestHarness(world);
    try {
      const scopedList = await harness.rpc<{
        data: Array<{ id: string; canAcceptDirectInput: boolean; cwdMissing?: boolean }>;
      }>("thread/list", { cwd: workspaceDir });
      expect(scopedList.data).toHaveLength(1);
      expect(scopedList.data[0]).toMatchObject({
        id: sessionId,
        canAcceptDirectInput: false,
        cwdMissing: true,
      });

      const readRes = await harness.rpc<{
        thread: { id: string; canAcceptDirectInput: boolean; cwdMissing?: boolean; turns: Array<{ items: Array<{ type: string }> }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(readRes.thread.canAcceptDirectInput).toBe(false);
      expect(readRes.thread.cwdMissing).toBe(true);
      expect(readRes.thread.turns).toHaveLength(1);

      await expect(
        harness.rpc("turn/start", {
          threadId: sessionId,
          cwd: missingSubdir,
          input: [{ type: "text", text: "should fail read-only", text_elements: [] }],
        }),
      ).rejects.toThrow("no longer exists");
    } finally {
      await harness.close();
    }
  });

  test("B05 round2: cross-session allow_always is never advertised as acceptForSession and second distinct session still prompts", async () => {
    const outcomes: Array<{ sessionId: string; toolCallId: string; outcome: unknown }> = [];
    const persistentAllowedTools = new Set<string>();
    const sessionAllowedTools = new Map<string, Set<string>>();
    const world = new FakeAgyWorld({
      onPrompt: async ({ session, prompt, emitUpdate, requestPermission }) => {
        const text = prompt.find((p): p is { type: "text"; text: string } => p.type === "text")?.text ?? "";
        if (text === "cross-session-test") {
          if (!persistentAllowedTools.has("cmd:pwd")) {
            const res = await requestPermission(
              { toolCallId: "cross-cmd", title: "Run pwd", kind: "execute", rawInput: { CommandLine: "pwd" } },
              [
                { optionId: "cross-always", name: "Remember for every conversation", kind: "allow_always" },
                { optionId: "cross-reject", name: "Reject", kind: "reject_once" },
              ],
            );
            outcomes.push({ sessionId: session.sessionId, toolCallId: "cross-cmd", outcome: res });
            const selected = (res as { outcome?: { outcome?: string; optionId?: string } })?.outcome;
            if (selected?.outcome === "selected" && selected.optionId === "cross-always") {
              persistentAllowedTools.add("cmd:pwd");
            }
          }
        } else if (text === "session-scoped-cmd-and-file") {
          const allowed = sessionAllowedTools.get(session.sessionId) ?? new Set<string>();
          sessionAllowedTools.set(session.sessionId, allowed);
          if (!allowed.has("cmd:pwd")) {
            const cmdRes = await requestPermission(
              { toolCallId: "sess-cmd", title: "Run pwd", kind: "execute", rawInput: { CommandLine: "pwd" } },
              [
                { optionId: "cmd-once", name: "Allow once", kind: "allow_once" },
                { optionId: "cmd-session", name: "Allow for this session", kind: "allow_always" },
                { optionId: "cmd-reject", name: "Reject", kind: "reject_once" },
              ],
            );
            outcomes.push({ sessionId: session.sessionId, toolCallId: "sess-cmd", outcome: cmdRes });
            const selected = (cmdRes as { outcome?: { outcome?: string; optionId?: string } })?.outcome;
            if (selected?.outcome === "selected" && selected.optionId === "cmd-session") {
              allowed.add("cmd:pwd");
            }
          }
          if (!allowed.has("file:notes")) {
            const fileRes = await requestPermission(
              { toolCallId: "sess-file", title: "Edit notes.txt", kind: "edit", rawInput: { Path: path.join(workspaceDir, "notes.txt") } },
              [
                { optionId: "file-once", name: "Allow once", kind: "allow_once" },
                { optionId: "file-session", name: "Allow for this session", kind: "allow_always" },
                { optionId: "file-reject", name: "Reject", kind: "reject_once" },
              ],
            );
            outcomes.push({ sessionId: session.sessionId, toolCallId: "sess-file", outcome: fileRes });
            const selected = (fileRes as { outcome?: { outcome?: string; optionId?: string } })?.outcome;
            if (selected?.outcome === "selected" && selected.optionId === "file-session") {
              allowed.add("file:notes");
            }
          }
        }
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "done" } });
        return { stopReason: "end_turn" };
      },
    });

    const harness = await createTestHarness(world);
    try {
      const s1 = (await harness.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir })).thread.id;
      const s2 = (await harness.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir })).thread.id;

      // 1) Cross-session upstream option ("Remember for every conversation") in Session 1:
      // Must NOT advertise acceptForSession; sending acceptForSession must cancel, never select cross-always.
      await harness.rpc("turn/start", {
        threadId: s1,
        cwd: workspaceDir,
        input: [{ type: "text", text: "cross-session-test", text_elements: [] }],
      });
      for (let i = 0; i < 40 && harness.serverRequests.length < 1; i += 1) await new Promise((r) => setTimeout(r, 15));
      const req1 = harness.serverRequests[0]!;
      expect((req1.params as { availableDecisions?: string[] }).availableDecisions).toEqual(["acceptAlways", "decline"]);
      expect((req1.params as { alwaysAllowLabel?: string }).alwaysAllowLabel).toBe("Remember for every conversation");
      harness.respondServerRequest(req1.id, { decision: "acceptForSession" });
      for (let i = 0; i < 40 && harness.notifications.filter((n) => n.method === "turn/completed").length < 1; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }
      expect(outcomes[0]?.outcome).toEqual({ outcome: { outcome: "cancelled" } });
      expect(persistentAllowedTools.has("cmd:pwd")).toBe(false);

      // Session 2 MUST still prompt because cross-session option was never escalated.
      await harness.rpc("turn/start", {
        threadId: s2,
        cwd: workspaceDir,
        input: [{ type: "text", text: "cross-session-test", text_elements: [] }],
      });
      for (let i = 0; i < 40 && harness.serverRequests.length < 2; i += 1) await new Promise((r) => setTimeout(r, 15));
      expect(harness.serverRequests).toHaveLength(2);
      harness.respondServerRequest(harness.serverRequests[1]!.id, { decision: "decline" });
      for (let i = 0; i < 40 && harness.notifications.filter((n) => n.method === "turn/completed").length < 2; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }

      // 2) Session-scoped options for command and file in Session 1 -> selects exact session optionId,
      // does NOT allow Session 2 without prompting.
      await harness.rpc("turn/start", {
        threadId: s1,
        cwd: workspaceDir,
        input: [{ type: "text", text: "session-scoped-cmd-and-file", text_elements: [] }],
      });
      for (let i = 0; i < 40 && harness.serverRequests.length < 3; i += 1) await new Promise((r) => setTimeout(r, 15));
      expect(harness.serverRequests[2]?.method).toBe("item/commandExecution/requestApproval");
      expect((harness.serverRequests[2]?.params as { availableDecisions?: string[] }).availableDecisions).toEqual([
        "accept",
        "acceptForSession",
        "decline",
      ]);
      harness.respondServerRequest(harness.serverRequests[2]!.id, { decision: "acceptForSession" });

      for (let i = 0; i < 40 && harness.serverRequests.length < 4; i += 1) await new Promise((r) => setTimeout(r, 15));
      expect(harness.serverRequests[3]?.method).toBe("item/fileChange/requestApproval");
      expect((harness.serverRequests[3]?.params as { availableDecisions?: string[] }).availableDecisions).toEqual([
        "accept",
        "acceptForSession",
        "decline",
      ]);
      harness.respondServerRequest(harness.serverRequests[3]!.id, { decision: "acceptForSession" });
      for (let i = 0; i < 40 && harness.notifications.filter((n) => n.method === "turn/completed").length < 3; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }

      // Session 2 still prompts for both command and file!
      await harness.rpc("turn/start", {
        threadId: s2,
        cwd: workspaceDir,
        input: [{ type: "text", text: "session-scoped-cmd-and-file", text_elements: [] }],
      });
      for (let i = 0; i < 40 && harness.serverRequests.length < 5; i += 1) await new Promise((r) => setTimeout(r, 15));
      expect(harness.serverRequests[4]?.method).toBe("item/commandExecution/requestApproval");
      harness.respondServerRequest(harness.serverRequests[4]!.id, { decision: "decline" });
      for (let i = 0; i < 40 && harness.serverRequests.length < 6; i += 1) await new Promise((r) => setTimeout(r, 15));
      expect(harness.serverRequests[5]?.method).toBe("item/fileChange/requestApproval");
      harness.respondServerRequest(harness.serverRequests[5]!.id, { decision: "decline" });
      for (let i = 0; i < 40 && harness.notifications.filter((n) => n.method === "turn/completed").length < 4; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }
    } finally {
      await harness.close();
    }
  });

  test("B10 round2: early failure before persistence stays visible after restart and next successful turn gets a new ID without inheriting old error", async () => {
    let callCount = 0;
    const world = new FakeAgyWorld({
      onPrompt: async ({ session, emitUpdate }) => {
        callCount += 1;
        if (callCount === 1) {
          emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "first ok" } });
          return { stopReason: "end_turn" };
        }
        if (callCount === 2) {
          // Simulate failure BEFORE upstream writes the user message to DB/replay.
          session.replayUpdates.pop();
          throw new Error("EARLY_FAILURE: failed before user message persisted");
        }
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "recovered ok" } });
        return { stopReason: "end_turn" };
      },
    });

    let threadId = "";
    let failedTurnId = "";
    let nextSuccessTurnId = "";

    const first = await createTestHarness(world);
    try {
      const started = await first.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      threadId = started.thread.id;
      await writeFile(
        path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`),
        "sqlite-placeholder",
      );

      // Turn 1: succeeds
      await first.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "turn one", text_elements: [] }],
      });
      for (let i = 0; i < 40 && first.notifications.filter((n) => n.method === "turn/completed").length < 1; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }

      // Turn 2: fails BEFORE user message persists
      const failedStart = await first.rpc<{ turn: { id: string } }>("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "retry me", text_elements: [] }],
      });
      failedTurnId = failedStart.turn.id;
      for (let i = 0; i < 40 && first.notifications.filter((n) => n.method === "turn/completed").length < 2; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }
    } finally {
      await first.close();
    }

    // Restart #1: verify early failure did NOT disappear, then run next successful turn (even with same prompt!).
    const second = await createTestHarness(world);
    try {
      const afterEarlyFail = await second.rpc<{
        data: Array<{ id: string; status: string; error: { message: string } | null }>;
      }>("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full" });
      expect(afterEarlyFail.data).toHaveLength(2);
      expect(afterEarlyFail.data[0]?.status).toBe("completed");
      expect(afterEarlyFail.data[1]?.id).toBe(failedTurnId);
      expect(afterEarlyFail.data[1]?.status).toBe("failed");
      expect(afterEarlyFail.data[1]?.error?.message).toContain("EARLY_FAILURE");

      // Next turn succeeds — must allocate a NEW non-reused turn ID!
      const nextStart = await second.rpc<{ turn: { id: string } }>("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "retry me", text_elements: [] }],
      });
      nextSuccessTurnId = nextStart.turn.id;
      expect(nextSuccessTurnId).not.toBe(failedTurnId);
      for (let i = 0; i < 40 && second.notifications.filter((n) => n.method === "turn/completed").length < 1; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }
    } finally {
      await second.close();
    }

    // Restart #2: cold read on BOTH ACP replay and transcript paths must keep failedTurnId as failed
    // and nextSuccessTurnId as completed (error: null)!
    const third = await createTestHarness(world);
    try {
      const replayTurns = await third.rpc<{
        data: Array<{ id: string; status: string; error: { message: string } | null }>;
      }>("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full" });
      expect(replayTurns.data).toHaveLength(3);
      expect(replayTurns.data[0]?.status).toBe("completed");
      expect(replayTurns.data[1]?.id).toBe(failedTurnId);
      expect(replayTurns.data[1]?.status).toBe("failed");
      expect(replayTurns.data[1]?.error?.message).toContain("EARLY_FAILURE");
      expect(replayTurns.data[2]?.id).toBe(nextSuccessTurnId);
      expect(replayTurns.data[2]?.status).toBe("completed");
      expect(replayTurns.data[2]?.error).toBeNull();

      // Also test cold transcript read (transcript only persisted turn 1 and turn 3).
      const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      await writeFile(
        path.join(logsDir, "transcript_full.jsonl"),
        [
          JSON.stringify({
            step_index: 0,
            type: "USER_INPUT",
            status: "DONE",
            created_at: "2026-11-22T01:00:00Z",
            content: "<USER_REQUEST>\nturn one\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 1,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: "2026-11-22T01:00:01Z",
            content: "first ok",
          }),
          JSON.stringify({
            step_index: 2,
            type: "USER_INPUT",
            status: "DONE",
            created_at: "2026-11-22T01:00:05Z",
            content: "<USER_REQUEST>\nretry me\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 3,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: "2026-11-22T01:00:06Z",
            content: "recovered ok",
          }),
        ].join("\n") + "\n",
      );

      const transcriptTurns = await third.rpc<{
        data: Array<{ id: string; status: string; error: { message: string } | null }>;
      }>("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full" });
      expect(transcriptTurns.data).toHaveLength(3);
      expect(transcriptTurns.data[1]?.id).toBe(failedTurnId);
      expect(transcriptTurns.data[1]?.status).toBe("failed");
      expect(transcriptTurns.data[1]?.error?.message).toContain("EARLY_FAILURE");
      expect(transcriptTurns.data[2]?.id).toBe(nextSuccessTurnId);
      expect(transcriptTurns.data[2]?.status).toBe("completed");
      expect(transcriptTurns.data[2]?.error).toBeNull();
    } finally {
      await third.close();
    }
  });

  test("B15 round2: approval-first, interleaved dual tools, and command+file keep identical IDs across live, approval, replay, and transcript", async () => {
    let turnNum = 0;
    const world = new FakeAgyWorld({
      onPrompt: async ({ emitUpdate, requestPermission }) => {
        turnNum += 1;
        if (turnNum === 1) {
          // Case 1: Approval for Tool B ("printf second") arrives BEFORE tool updates for Tool A ("printf first") & Tool B!
          await requestPermission(
            { toolCallId: "call-second", title: "printf second", kind: "execute", rawInput: { CommandLine: "printf second" } },
            [{ optionId: "allow", name: "Allow once", kind: "allow_once" }],
          );
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "call-first",
            title: "printf first",
            kind: "execute",
            status: "completed",
            rawInput: { CommandLine: "printf first" },
            content: [{ type: "content", content: { type: "text", text: "first" } }],
          });
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "call-second",
            title: "printf second",
            kind: "execute",
            status: "completed",
            rawInput: { CommandLine: "printf second" },
            content: [{ type: "content", content: { type: "text", text: "second" } }],
          });
        } else if (turnNum === 2) {
          // Case 2: Interleaved dual tools (A starts, B starts, B completes, A completes).
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "interleave-a",
            title: "echo A",
            kind: "execute",
            status: "in_progress",
            rawInput: { CommandLine: "echo A" },
          });
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "interleave-b",
            title: "echo B",
            kind: "execute",
            status: "in_progress",
            rawInput: { CommandLine: "echo B" },
          });
          emitUpdate({
            sessionUpdate: "tool_call_update",
            toolCallId: "interleave-b",
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: "B" } }],
          });
          emitUpdate({
            sessionUpdate: "tool_call_update",
            toolCallId: "interleave-a",
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: "A" } }],
          });
        } else {
          // Case 3: File approval arrives before command update, then command + file complete.
          const filePath = path.join(workspaceDir, "out-of-order.txt");
          await requestPermission(
            { toolCallId: "call-file", title: "Edit out-of-order.txt", kind: "edit", rawInput: { Path: filePath } },
            [{ optionId: "allow", name: "Allow once", kind: "allow_once" }],
          );
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "call-cmd",
            title: "Run date",
            kind: "execute",
            status: "completed",
            rawInput: { CommandLine: "date" },
            content: [{ type: "content", content: { type: "text", text: "today" } }],
          });
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "call-file",
            title: "Edit out-of-order.txt",
            kind: "edit",
            status: "completed",
            content: [{ type: "diff", path: filePath, oldText: "old", newText: "new" }],
          });
        }
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `turn ${turnNum} done` } });
        return { stopReason: "end_turn" };
      },
    });

    const first = await createTestHarness(world);
    let threadId = "";
    const liveIdsByLabel = new Map<string, string>();
    let turn1ApprovalItemId = "";
    let turn3ApprovalItemId = "";
    try {
      const started = await first.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      threadId = started.thread.id;
      await writeFile(
        path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`),
        "sqlite-placeholder",
      );

      // Turn 1: approval-first
      await first.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "approval first", text_elements: [] }],
      });
      for (let i = 0; i < 40 && first.serverRequests.length < 1; i += 1) await new Promise((r) => setTimeout(r, 15));
      turn1ApprovalItemId = String((first.serverRequests[0]?.params as { itemId?: string }).itemId ?? "");
      first.respondServerRequest(first.serverRequests[0]!.id, { decision: "accept" });
      for (let i = 0; i < 40 && first.notifications.filter((n) => n.method === "turn/completed").length < 1; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }

      // Turn 2: interleaved
      await first.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "interleaved", text_elements: [] }],
      });
      for (let i = 0; i < 40 && first.notifications.filter((n) => n.method === "turn/completed").length < 2; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }

      // Turn 3: command + file with file approval first
      await first.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "cmd plus file", text_elements: [] }],
      });
      for (let i = 0; i < 40 && first.serverRequests.length < 2; i += 1) await new Promise((r) => setTimeout(r, 15));
      turn3ApprovalItemId = String((first.serverRequests[1]?.params as { itemId?: string }).itemId ?? "");
      first.respondServerRequest(first.serverRequests[1]!.id, { decision: "accept" });
      for (let i = 0; i < 40 && first.notifications.filter((n) => n.method === "turn/completed").length < 3; i += 1) {
        await new Promise((r) => setTimeout(r, 15));
      }

      for (const n of first.notifications) {
        if (n.method !== "item/completed") continue;
        const item = (n.params as { item?: { type?: string; id?: string; command?: string; changes?: Array<{ path?: string }> } }).item;
        if (item?.type === "commandExecution" && item.command && item.id) {
          liveIdsByLabel.set(item.command, item.id);
        }
        if (item?.type === "fileChange" && item.id) {
          liveIdsByLabel.set("file:out-of-order.txt", item.id);
        }
      }
      expect(turn1ApprovalItemId).toBe(liveIdsByLabel.get("printf second")!);
      expect(turn3ApprovalItemId).toBe(liveIdsByLabel.get("file:out-of-order.txt")!);
      expect(liveIdsByLabel.get("printf first")).not.toBe(liveIdsByLabel.get("printf second"));
    } finally {
      await first.close();
    }

    const cold = await createTestHarness(world);
    try {
      // 1) Cold ACP replay: every item matches its live ID (zero swapping!)
      const replay = await cold.rpc<{
        data: Array<{ items: Array<{ type: string; id: string; command?: string }> }>;
      }>("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full" });
      expect(replay.data).toHaveLength(3);
      const t1 = replay.data[0]!.items;
      expect(t1.find((i) => i.command === "printf first")?.id).toBe(liveIdsByLabel.get("printf first"));
      expect(t1.find((i) => i.command === "printf second")?.id).toBe(liveIdsByLabel.get("printf second"));
      const t2 = replay.data[1]!.items;
      expect(t2.find((i) => i.command === "echo A")?.id).toBe(liveIdsByLabel.get("echo A"));
      expect(t2.find((i) => i.command === "echo B")?.id).toBe(liveIdsByLabel.get("echo B"));
      const t3 = replay.data[2]!.items;
      expect(t3.find((i) => i.command === "date")?.id).toBe(liveIdsByLabel.get("date"));
      expect(t3.find((i) => i.type === "fileChange")?.id).toBe(liveIdsByLabel.get("file:out-of-order.txt"));

      // 2) Cold transcript read (without native tool_call IDs in JSONL) uses persisted overlay mappings!
      const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      const filePath = path.join(workspaceDir, "out-of-order.txt");
      await writeFile(
        path.join(logsDir, "transcript_full.jsonl"),
        [
          JSON.stringify({ step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\napproval first\n</USER_REQUEST>" }),
          JSON.stringify({
            step_index: 1,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            tool_calls: [
              { name: "run_command", args: { CommandLine: "\"printf first\"" } },
              { name: "run_command", args: { CommandLine: "\"printf second\"" } },
            ],
          }),
          JSON.stringify({ step_index: 2, type: "GENERIC", status: "DONE", content: "first" }),
          JSON.stringify({ step_index: 3, type: "GENERIC", status: "DONE", content: "second" }),
          JSON.stringify({ step_index: 4, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ninterleaved\n</USER_REQUEST>" }),
          JSON.stringify({
            step_index: 5,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            tool_calls: [
              { name: "run_command", args: { CommandLine: "\"echo A\"" } },
              { name: "run_command", args: { CommandLine: "\"echo B\"" } },
            ],
          }),
          JSON.stringify({ step_index: 6, type: "GENERIC", status: "DONE", content: "A" }),
          JSON.stringify({ step_index: 7, type: "GENERIC", status: "DONE", content: "B" }),
          JSON.stringify({ step_index: 8, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ncmd plus file\n</USER_REQUEST>" }),
          JSON.stringify({
            step_index: 9,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            tool_calls: [
              { name: "run_command", args: { CommandLine: "\"date\"" } },
              { name: "edit_file", args: { Path: filePath, Target: "old", Replacement: "new" } },
            ],
          }),
          JSON.stringify({ step_index: 10, type: "GENERIC", status: "DONE", content: "today" }),
          JSON.stringify({ step_index: 11, type: "GENERIC", status: "DONE", content: "edited" }),
        ].join("\n") + "\n",
      );

      const transcript = await cold.rpc<{
        data: Array<{ items: Array<{ type: string; id: string; command?: string }> }>;
      }>("thread/turns/list", { threadId, sortDirection: "asc", itemsView: "full" });
      expect(transcript.data).toHaveLength(3);
      expect(transcript.data[0]!.items.find((i) => i.command === "printf first")?.id).toBe(liveIdsByLabel.get("printf first"));
      expect(transcript.data[0]!.items.find((i) => i.command === "printf second")?.id).toBe(liveIdsByLabel.get("printf second"));
      expect(transcript.data[1]!.items.find((i) => i.command === "echo A")?.id).toBe(liveIdsByLabel.get("echo A"));
      expect(transcript.data[1]!.items.find((i) => i.command === "echo B")?.id).toBe(liveIdsByLabel.get("echo B"));
      expect(transcript.data[2]!.items.find((i) => i.command === "date")?.id).toBe(liveIdsByLabel.get("date"));
      expect(transcript.data[2]!.items.find((i) => i.type === "fileChange")?.id).toBe(liveIdsByLabel.get("file:out-of-order.txt"));
    } finally {
      await cold.close();
    }
  });

  test("C10 round2: healthy CLI pagination stays available when Other is unconfigured, fails to start, or responds slowly", async () => {
    const cliIds = ["cli-page-1", "cli-page-2", "cli-page-3"];
    for (const id of cliIds) {
      await writeFile(
        path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${id}.db`),
        "sqlite-placeholder",
      );
    }
    const baseSessions = cliIds.map((id, idx) => ({
      sessionId: id,
      cwd: workspaceDir,
      title: `CLI ${idx + 1}`,
      updatedAt: `2026-11-22T0${idx + 1}:00:00Z`,
      modeId: "default",
      model: "gemini-4-carbon",
      thoughtLevel: "medium",
      appDataDirName: "antigravity-cli",
      replayUpdates: [],
    }));

    // 1) Other unconfigured (no antigravity/conversations/*.db): otherSharedAcp is never spawned; CLI pagination works.
    const world1 = new FakeAgyWorld({ sessions: baseSessions });
    const h1 = await createTestHarness(world1);
    try {
      const page1 = await h1.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", { limit: 2 });
      expect(page1.data).toHaveLength(2);
      expect(page1.nextCursor).not.toBeNull();
      const page2 = await h1.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", {
        limit: 2,
        cursor: page1.nextCursor,
      });
      expect(page2.data).toHaveLength(1);
      expect(page2.nextCursor).toBeNull();
      expect(world1.spawns.some((s) => s.appDataDirName === "antigravity")).toBe(false);
    } finally {
      await h1.close();
    }

    // Create a placeholder Other db so hasOtherConversations returns true for cases 2 & 3.
    await mkdir(path.join(fakeHome, ".gemini", "antigravity", "conversations"), { recursive: true });
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity", "conversations", "other-broken.db"),
      "sqlite-placeholder",
    );

    // 2) Other fails to start: healthy CLI pagination still succeeds.
    const world2 = new FakeAgyWorld({ sessions: baseSessions });
    const h2 = await createTestHarness(world2, {
      spawnTransport: (opts) => {
        if (opts.appDataDirName === "antigravity") {
          throw new Error("simulated Other ACP spawn failure");
        }
        return world2.spawnTransport(opts);
      },
    });
    try {
      const page1 = await h2.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", { limit: 2 });
      expect(page1.data).toHaveLength(2);
      expect(page1.nextCursor).not.toBeNull();
      const page2 = await h2.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", {
        limit: 2,
        cursor: page1.nextCursor,
      });
      expect(page2.data).toHaveLength(1);
    } finally {
      await h2.close();
    }

    // 3) Other hangs / responds slowly past bounded timeout: healthy CLI pagination returns promptly.
    const world3 = new FakeAgyWorld({ sessions: baseSessions });
    const h3 = await createTestHarness(world3, {
      env: () => ({
        ...process.env,
        HOME: fakeHome,
        AGY_ADAPTER_OTHER_LIST_TIMEOUT_MS: "120",
      }),
      spawnTransport: (opts) => {
        if (opts.appDataDirName === "antigravity") {
          const stdin = new PassThrough();
          const stdout = new PassThrough();
          // Never responds to initialize / session/list (simulates hung Other subprocess).
          return {
            stdin,
            stdout,
            pid: 99_999,
            async close() {
              stdin.end();
              stdout.end();
            },
          };
        }
        return world3.spawnTransport(opts);
      },
    });
    try {
      const startedAt = Date.now();
      const page1 = await h3.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", { limit: 2 });
      const elapsedMs = Date.now() - startedAt;
      expect(page1.data).toHaveLength(2);
      expect(page1.nextCursor).not.toBeNull();
      expect(elapsedMs).toBeLessThan(1_500);
      const page2 = await h3.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", {
        limit: 2,
        cursor: page1.nextCursor,
      });
      expect(page2.data).toHaveLength(1);
    } finally {
      await h3.close();
    }
  });

  test("B10 round3: legacy overlay upgrade preserves old terminal states and coexists with new adapter writes and external native appends without turn ID collisions", async () => {
    const sessionId = "b10-legacy-upgrade-session";
    await mkdir(stateDir, { recursive: true });
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`),
      "sqlite-placeholder",
    );

    // Seed a round-1 legacy overlay.json (only `turnOutcomes`, no `turnAttempts`).
    await writeFile(
      path.join(stateDir, "overlay.json"),
      JSON.stringify({
        version: 1,
        sessions: {
          [sessionId]: {
            cwd: workspaceDir,
            turnOutcomes: {
              [`${sessionId}:turn:1`]: {
                status: "failed",
                error: "LEGACY_TEST_ERROR",
              },
            },
          },
        },
      }),
    );

    const replayUpdates: AcpSessionUpdate[] = [
      { sessionUpdate: "user_message_chunk", content: { type: "text", text: "legacy failed prompt" } },
      { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "legacy partial reply before failure" } },
    ];
    let failNextPrompt = false;
    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Legacy Upgrade Session",
          updatedAt: "2026-11-22T01:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates,
        },
      ],
      onPrompt: async ({ session, prompt, emitUpdate }) => {
        const text = prompt.find((p): p is { type: "text"; text: string } => p.type === "text")?.text ?? "";
        if (failNextPrompt) {
          failNextPrompt = false;
          // Early failure before writing user message to native replay/storage.
          session.replayUpdates.pop();
          throw new Error("EARLY_FAILURE");
        }
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `REPLY:${text}` } });
        return { stopReason: "end_turn" };
      },
    });

    const waitCompleted = async (notifications: Array<Record<string, unknown>>, count: number) => {
      for (let i = 0; i < 100; i += 1) {
        const completedCount = notifications.filter((n) => n.method === "turn/completed").length;
        const idleCount = notifications.filter(
          (n) => n.method === "thread/status/changed" && (n.params as { status?: { type?: string } })?.status?.type === "idle",
        ).length;
        if (completedCount >= count && idleCount >= count) return;
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error(`timed out waiting for ${count} completed+idle notifications`);
    };

    // 1) Upgraded adapter reads legacy history -> turn 1 preserves LEGACY_TEST_ERROR.
    const h1 = await createTestHarness(world);
    try {
      const before = await h1.rpc<{ thread: { turns: Array<{ id: string; status: string; error: { message: string } | null }> } }>(
        "thread/read",
        { threadId: sessionId, includeTurns: true },
      );
      expect(before.thread.turns).toEqual([
        expect.objectContaining({
          id: `${sessionId}:turn:1`,
          status: "failed",
          error: expect.objectContaining({ message: "LEGACY_TEST_ERROR" }),
        }),
      ]);

      // 2) First new-format write on upgraded adapter (Turn 2: early failure, unpersisted).
      failNextPrompt = true;
      await h1.rpc("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "early-fail-after-upgrade", text_elements: [] }],
      });
      await waitCompleted(h1.notifications, 1);

      // 3) Recovery write on upgraded adapter (Turn 3: persisted success).
      await h1.rpc("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "adapter-recovery-success", text_elements: [] }],
      });
      await waitCompleted(h1.notifications, 2);
    } finally {
      await h1.close();
    }

    // 4) Simulate a real cross-device external Mac CLI append directly to native history!
    const storedSession = world.sessions.get(sessionId)!;
    storedSession.replayUpdates.push({ sessionUpdate: "user_message_chunk", content: { type: "text", text: "External Mac CLI append" } });
    storedSession.replayUpdates.push({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "EXTERNAL MAC REPLY" } });

    // 5) Cold read after restart: legacy Turn 1 failure MUST survive, early fail Turn 2 survives,
    //    adapter Turn 3 survives, and external native append gets unique Turn 4 (NO duplicate :turn:3)!
    const h2 = await createTestHarness(world);
    try {
      const afterExternal = await h2.rpc<{
        thread: { turns: Array<{ id: string; status: string; error: { message: string } | null }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      const idsAfterExternal = afterExternal.thread.turns.map((t) => t.id);
      expect(afterExternal.thread.turns).toHaveLength(4);
      expect(new Set(idsAfterExternal).size).toBe(4);
      expect(afterExternal.thread.turns[0]).toMatchObject({
        id: `${sessionId}:turn:1`,
        status: "failed",
        error: expect.objectContaining({ message: "LEGACY_TEST_ERROR" }),
      });
      expect(afterExternal.thread.turns[1]).toMatchObject({
        id: `${sessionId}:turn:2`,
        status: "failed",
        error: expect.objectContaining({ message: expect.stringContaining("EARLY_FAILURE") }),
      });
      expect(afterExternal.thread.turns[2]).toMatchObject({
        id: `${sessionId}:turn:3`,
        status: "completed",
        error: null,
      });
      expect(afterExternal.thread.turns[3]).toMatchObject({
        id: `${sessionId}:turn:4`,
        status: "completed",
        error: null,
      });

      // 6) Follow-up write from adapter after external append gets unique Turn 5!
      await h2.rpc("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "adapter-after-external", text_elements: [] }],
      });
      await waitCompleted(h2.notifications, 1);
    } finally {
      await h2.close();
    }

    // 7) Final cold read after restart confirms all 5 turns remain unique, stable, and intact.
    const h3 = await createTestHarness(world);
    try {
      const finalRead = await h3.rpc<{
        thread: { turns: Array<{ id: string; status: string; error: { message: string } | null }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(finalRead.thread.turns).toHaveLength(5);
      expect(finalRead.thread.turns.map((t) => t.id)).toEqual([
        `${sessionId}:turn:1`,
        `${sessionId}:turn:2`,
        `${sessionId}:turn:3`,
        `${sessionId}:turn:4`,
        `${sessionId}:turn:5`,
      ]);
      expect(finalRead.thread.turns[0]?.status).toBe("failed");
      expect(finalRead.thread.turns[0]?.error?.message).toBe("LEGACY_TEST_ERROR");
      expect(finalRead.thread.turns[1]?.status).toBe("failed");
      expect(finalRead.thread.turns[2]?.status).toBe("completed");
      expect(finalRead.thread.turns[3]?.status).toBe("completed");
      expect(finalRead.thread.turns[4]?.status).toBe("completed");
    } finally {
      await h3.close();
    }
  });

  test("B15 round3: duplicate commands finishing in reverse order keep exact IDs on cold transcript read, and ambiguous concurrent identical outputs fall back safely", async () => {
    const world = new FakeAgyWorld({
      onPrompt: async ({ prompt, emitUpdate }) => {
        const text = prompt.find((p): p is { type: "text"; text: string } => p.type === "text")?.text ?? "";
        if (text === "reverse-duplicate-distinct") {
          // Both start in invocation order: first, then second.
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "duplicate-first",
            title: "Run printf",
            kind: "execute",
            status: "in_progress",
            rawInput: { CommandLine: "printf fixture-repeat" },
          });
          emitUpdate({
            sessionUpdate: "tool_call",
            toolCallId: "duplicate-second",
            title: "Run printf",
            kind: "execute",
            status: "in_progress",
            rawInput: { CommandLine: "printf fixture-repeat" },
          });
          // Complete in REVERSE order: second finishes BEFORE first!
          emitUpdate({
            sessionUpdate: "tool_call_update",
            toolCallId: "duplicate-second",
            status: "completed",
            rawOutput: { output: "FIXTURE SECOND RESULT", exitCode: 0 },
          });
          emitUpdate({
            sessionUpdate: "tool_call_update",
            toolCallId: "duplicate-first",
            status: "completed",
            rawOutput: { output: "FIXTURE FIRST RESULT", exitCode: 0 },
          });
          emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "done distinct" } });
          return { stopReason: "end_turn" };
        }
        // Ambiguous concurrent duplicates with identical output.
        emitUpdate({
          sessionUpdate: "tool_call",
          toolCallId: "ambig-a",
          title: "Run printf",
          kind: "execute",
          status: "in_progress",
          rawInput: { CommandLine: "printf same-output" },
        });
        emitUpdate({
          sessionUpdate: "tool_call",
          toolCallId: "ambig-b",
          title: "Run printf",
          kind: "execute",
          status: "in_progress",
          rawInput: { CommandLine: "printf same-output" },
        });
        emitUpdate({
          sessionUpdate: "tool_call_update",
          toolCallId: "ambig-b",
          status: "completed",
          rawOutput: { output: "IDENTICAL RESULT", exitCode: 0 },
        });
        emitUpdate({
          sessionUpdate: "tool_call_update",
          toolCallId: "ambig-a",
          status: "completed",
          rawOutput: { output: "IDENTICAL RESULT", exitCode: 0 },
        });
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "done ambiguous" } });
        return { stopReason: "end_turn" };
      },
    });

    let threadId = "";
    const first = await createTestHarness(world);
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
        input: [{ type: "text", text: "reverse-duplicate-distinct", text_elements: [] }],
      });
      for (let i = 0; i < 60; i += 1) {
        const idle = first.notifications.filter(
          (n) => n.method === "thread/status/changed" && (n.params as { status?: { type?: string } })?.status?.type === "idle",
        );
        if (idle.length >= 1) break;
        await new Promise((r) => setTimeout(r, 10));
      }

      await first.rpc("turn/start", {
        threadId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "reverse-duplicate-ambiguous", text_elements: [] }],
      });
      for (let i = 0; i < 60; i += 1) {
        const idle = first.notifications.filter(
          (n) => n.method === "thread/status/changed" && (n.params as { status?: { type?: string } })?.status?.type === "idle",
        );
        if (idle.length >= 2) break;
        await new Promise((r) => setTimeout(r, 10));
      }
    } finally {
      await first.close();
    }

    // Write a native transcript WITHOUT native tool call IDs, recording invocations in start order.
    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const lines = [
      JSON.stringify({
        step_index: 0,
        type: "USER_INPUT",
        status: "DONE",
        created_at: "2026-11-22T02:00:00Z",
        content: "<USER_REQUEST>\nreverse-duplicate-distinct\n</USER_REQUEST>",
      }),
      JSON.stringify({
        step_index: 1,
        type: "PLANNER_RESPONSE",
        status: "DONE",
        created_at: "2026-11-22T02:00:01Z",
        tool_calls: [
          { name: "run_command", args: { CommandLine: "\"printf fixture-repeat\"" } },
          { name: "run_command", args: { CommandLine: "\"printf fixture-repeat\"" } },
        ],
      }),
      JSON.stringify({ step_index: 2, type: "GENERIC", status: "DONE", content: "FIXTURE FIRST RESULT" }),
      JSON.stringify({ step_index: 3, type: "GENERIC", status: "DONE", content: "FIXTURE SECOND RESULT" }),
      JSON.stringify({ step_index: 4, type: "PLANNER_RESPONSE", status: "DONE", content: "done distinct" }),
      JSON.stringify({
        step_index: 5,
        type: "USER_INPUT",
        status: "DONE",
        created_at: "2026-11-22T02:01:00Z",
        content: "<USER_REQUEST>\nreverse-duplicate-ambiguous\n</USER_REQUEST>",
      }),
      JSON.stringify({
        step_index: 6,
        type: "PLANNER_RESPONSE",
        status: "DONE",
        created_at: "2026-11-22T02:01:01Z",
        tool_calls: [
          { name: "run_command", args: { CommandLine: "\"printf same-output\"" } },
          { name: "run_command", args: { CommandLine: "\"printf same-output\"" } },
        ],
      }),
      JSON.stringify({ step_index: 7, type: "GENERIC", status: "DONE", content: "IDENTICAL RESULT" }),
      JSON.stringify({ step_index: 8, type: "GENERIC", status: "DONE", content: "IDENTICAL RESULT" }),
      JSON.stringify({ step_index: 9, type: "PLANNER_RESPONSE", status: "DONE", content: "done ambiguous" }),
    ];
    await writeFile(path.join(logsDir, "transcript_full.jsonl"), `${lines.join("\n")}\n`);

    const second = await createTestHarness(world);
    try {
      const readRes = await second.rpc<{
        thread: {
          turns: Array<{
            id: string;
            items: Array<{ id: string; type: string; command?: string; aggregatedOutput?: string | null }>;
          }>;
        };
      }>("thread/read", { threadId, includeTurns: true });
      expect(readRes.thread.turns).toHaveLength(2);

      // Turn 1: distinct outputs MUST bind duplicate-first -> FIRST RESULT and duplicate-second -> SECOND RESULT!
      const turn1Cmds = readRes.thread.turns[0]!.items.filter((i) => i.type === "commandExecution");
      expect(turn1Cmds).toEqual([
        expect.objectContaining({
          id: `${threadId}:turn:1:tool:duplicate-first`,
          aggregatedOutput: "FIXTURE FIRST RESULT",
        }),
        expect.objectContaining({
          id: `${threadId}:turn:1:tool:duplicate-second`,
          aggregatedOutput: "FIXTURE SECOND RESULT",
        }),
      ]);

      // Turn 2: ambiguous concurrent identical outputs MUST keep deterministic fallback IDs rather than misbinding!
      const turn2Cmds = readRes.thread.turns[1]!.items.filter((i) => i.type === "commandExecution");
      expect(turn2Cmds.map((c) => c.id)).toEqual([
        `${threadId}:turn:2:tool:1`,
        `${threadId}:turn:2:tool:2`,
      ]);
    } finally {
      await second.close();
    }
  });

  test("C11 round3: every entry point shows and enforces external holder across early, mid-flight interim planner reply, and post-exit windows", async () => {
    const sessionId = "c11-all-entries-session";
    await writeFile(
      path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`),
      "sqlite-placeholder",
    );
    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const transcriptPath = path.join(logsDir, "transcript_full.jsonl");

    const baseSteps = [
      { step_index: 0, type: "USER_INPUT", status: "DONE", created_at: "2026-11-22T02:28:00Z", content: "<USER_REQUEST>\nbase\n</USER_REQUEST>" },
      { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:28:01Z", content: "BASE READY" },
    ];
    await writeFile(transcriptPath, `${baseSteps.map((s) => JSON.stringify(s)).join("\n")}\n`);

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "C11 All Entries",
          updatedAt: "2026-11-22T02:28:01Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });

    const harness = await createTestHarness(world);
    try {
      const assertAllEntriesHeld = async (stageLabel: string) => {
        // 1) Global thread/list
        const globalList = await harness.rpc<{ data: Array<{ id: string; canAcceptDirectInput: boolean; claudeOwner?: { status?: string } }> }>(
          "thread/list",
          {},
        );
        const globalEntry = globalList.data.find((d) => d.id === sessionId);
        expect(globalEntry, `${stageLabel}: global thread/list`).toMatchObject({
          id: sessionId,
          canAcceptDirectInput: false,
          claudeOwner: expect.objectContaining({ status: "busy" }),
        });

        // 2) Scoped thread/list
        const scopedList = await harness.rpc<{ data: Array<{ id: string; canAcceptDirectInput: boolean; claudeOwner?: { status?: string } }> }>(
          "thread/list",
          { cwd: workspaceDir },
        );
        const scopedEntry = scopedList.data.find((d) => d.id === sessionId);
        expect(scopedEntry, `${stageLabel}: scoped thread/list`).toMatchObject({
          id: sessionId,
          canAcceptDirectInput: false,
          claudeOwner: expect.objectContaining({ status: "busy" }),
        });

        // 3) thread/read
        const readRes = await harness.rpc<{
          thread: { id: string; canAcceptDirectInput: boolean; claudeOwner?: { status?: string }; turns: Array<{ status: string }> };
        }>("thread/read", { threadId: sessionId, includeTurns: true });
        expect(readRes.thread.canAcceptDirectInput, `${stageLabel}: thread/read`).toBe(false);
        expect(readRes.thread.claudeOwner?.status, `${stageLabel}: thread/read owner`).toBe("busy");
        expect(readRes.thread.turns[readRes.thread.turns.length - 1]?.status, `${stageLabel}: thread/read last turn`).toBe("inProgress");

        // 4) thread/turns/list
        const turnsRes = await harness.rpc<{ data: Array<{ status: string }> }>("thread/turns/list", {
          threadId: sessionId,
          sortDirection: "desc",
          itemsView: "full",
        });
        expect(turnsRes.data[0]?.status, `${stageLabel}: thread/turns/list`).toBe("inProgress");

        // 5) thread/resume
        const resumeRes = await harness.rpc<{ thread: { canAcceptDirectInput: boolean; claudeOwner?: { status?: string } } }>(
          "thread/resume",
          { threadId: sessionId, cwd: workspaceDir },
        );
        expect(resumeRes.thread.canAcceptDirectInput, `${stageLabel}: thread/resume`).toBe(false);
        expect(resumeRes.thread.claudeOwner?.status, `${stageLabel}: thread/resume owner`).toBe("busy");

        // 6) turn/start rejected
        await expect(
          harness.rpc("turn/start", {
            threadId: sessionId,
            cwd: workspaceDir,
            input: [{ type: "text", text: "blocked during holder", text_elements: [] }],
          }),
        ).rejects.toThrow("currently active");

        // 7) turn/interrupt rejected
        await expect(harness.rpc("turn/interrupt", { threadId: sessionId })).rejects.toThrow("cannot be interrupted remotely");
      };

      // Stage 1 (early): native CLI starts sleep 55 -> GENERIC RUNNING
      const earlySteps = [
        ...baseSteps,
        { step_index: 2, type: "USER_INPUT", status: "DONE", created_at: "2026-11-22T02:28:57Z", content: "<USER_REQUEST>\nsleep 55\n</USER_REQUEST>" },
        { step_index: 3, type: "SYSTEM_MESSAGE", status: "DONE", created_at: "2026-11-22T02:28:57Z" },
        { step_index: 4, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:28:57Z", tool_calls: [{ name: "run_command", args: { CommandLine: "\"sleep 55\"" } }] },
        { step_index: 5, type: "GENERIC", status: "RUNNING", created_at: "2026-11-22T02:29:04Z" },
      ];
      await writeFile(transcriptPath, `${earlySteps.map((s) => JSON.stringify(s)).join("\n")}\n`);
      await assertAllEntriesHeld("early");

      // Stage 2 (mid-flight): interim PLANNER_RESPONSE ("Waiting for sleep 55 to finish.") while step 5 is STILL RUNNING!
      const midSteps = [
        ...earlySteps,
        { step_index: 6, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:29:14Z", content: "Waiting for `sleep 55` to finish." },
      ];
      await writeFile(transcriptPath, `${midSteps.map((s) => JSON.stringify(s)).join("\n")}\n`);
      await assertAllEntriesHeld("mid-flight-interim-planner");

      // Stage 3 (post-exit): command completes -> SYSTEM_MESSAGE + final PLANNER_RESPONSE -> all entries recover to writable & completed!
      const finishedSteps = [
        ...midSteps,
        { step_index: 7, type: "SYSTEM_MESSAGE", status: "DONE", created_at: "2026-11-22T02:29:59Z" },
        { step_index: 8, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:29:59Z", content: "VERIFY C11 MAC BUSY FINISH" },
      ];
      await writeFile(transcriptPath, `${finishedSteps.map((s) => JSON.stringify(s)).join("\n")}\n`);

      const readAfter = await harness.rpc<{
        thread: { canAcceptDirectInput: boolean; claudeOwner?: unknown; turns: Array<{ status: string }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(readAfter.thread.canAcceptDirectInput).toBe(true);
      expect(readAfter.thread.claudeOwner).toBeUndefined();
      expect(readAfter.thread.turns[readAfter.thread.turns.length - 1]?.status).toBe("completed");

      const turnsAfter = await harness.rpc<{ data: Array<{ status: string }> }>("thread/turns/list", {
        threadId: sessionId,
        sortDirection: "desc",
        itemsView: "full",
      });
      expect(turnsAfter.data[0]?.status).toBe("completed");

      const listAfter = await harness.rpc<{ data: Array<{ id: string; canAcceptDirectInput: boolean }> }>("thread/list", {});
      expect(listAfter.data.find((d) => d.id === sessionId)?.canAcceptDirectInput).toBe(true);
    } finally {
      await harness.close();
    }
  });

  test("C10 round3: Other list distinguishes empty/timeout/failed diagnostics, cancels timed-out subprocess, and recovers during pagination", async () => {
    const cliIds = ["cli-rec-1", "cli-rec-2", "cli-rec-3"];
    for (const id of cliIds) {
      await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${id}.db`), "sqlite");
    }
    const otherId = "other-recovered-session";
    await mkdir(path.join(fakeHome, ".gemini", "antigravity", "conversations"), { recursive: true });
    await writeFile(path.join(fakeHome, ".gemini", "antigravity", "conversations", `${otherId}.db`), "sqlite");

    const cliSessions = cliIds.map((id, idx) => ({
      sessionId: id,
      cwd: workspaceDir,
      title: `CLI ${idx + 1}`,
      updatedAt: `2026-11-22T03:0${idx}:00Z`,
      modeId: "default",
      model: "gemini-4-carbon",
      thoughtLevel: "medium",
      replayUpdates: [],
      appDataDirName: "antigravity-cli",
    }));
    const otherSession = {
      sessionId: otherId,
      cwd: workspaceDir,
      title: "Other Recovered",
      updatedAt: "2026-11-22T02:59:00Z",
      modeId: "default",
      model: "gemini-4-carbon",
      thoughtLevel: "medium",
      replayUpdates: [],
      appDataDirName: "antigravity",
    };

    // 1) Empty Other index records explicit "empty" diagnostic (not timeout/failed).
    const emptyDiags: OtherListDiagnostic[] = [];
    const emptyWorld = new FakeAgyWorld({ sessions: cliSessions });
    const hEmpty = await createTestHarness(emptyWorld, {
      onOtherListDiagnostic: (d) => emptyDiags.push(d),
    });
    try {
      const res = await hEmpty.rpc<{ data: Array<{ id: string }> }>("thread/list", { limit: 10 });
      expect(res.data).toHaveLength(3);
      expect(emptyDiags).toContainEqual(expect.objectContaining({ status: "empty", count: 0 }));
    } finally {
      await hEmpty.close();
    }

    // 2) Failed Other subprocess records explicit "failed" diagnostic.
    const failedDiags: OtherListDiagnostic[] = [];
    const failWorld = new FakeAgyWorld({ sessions: [...cliSessions, otherSession] });
    const hFail = await createTestHarness(failWorld, {
      onOtherListDiagnostic: (d) => failedDiags.push(d),
      spawnTransport: (opts) => {
        if (opts.appDataDirName === "antigravity") {
          throw new Error("simulated Other crash");
        }
        return failWorld.spawnTransport(opts);
      },
    });
    try {
      const res = await hFail.rpc<{ data: Array<{ id: string }> }>("thread/list", { limit: 10 });
      expect(res.data).toHaveLength(3);
      expect(failedDiags).toContainEqual(
        expect.objectContaining({ status: "failed", error: expect.stringContaining("simulated Other crash") }),
      );
    } finally {
      await hFail.close();
    }

    // 3) Timeout during page 1 cancels & closes the hung Other transport and records "timeout";
    //    then Other recovers before page 2 and pagination discovers the Other session seamlessly!
    const recoveryDiags: OtherListDiagnostic[] = [];
    let otherHungMode = true;
    let hungTransportClosed = false;
    const recoveryWorld = new FakeAgyWorld({ sessions: [...cliSessions, otherSession] });
    const hRec = await createTestHarness(recoveryWorld, {
      env: () => ({
        ...process.env,
        HOME: fakeHome,
        AGY_ADAPTER_OTHER_LIST_TIMEOUT_MS: "100",
      }),
      onOtherListDiagnostic: (d) => recoveryDiags.push(d),
      spawnTransport: (opts) => {
        if (opts.appDataDirName === "antigravity" && otherHungMode) {
          const stdin = new PassThrough();
          const stdout = new PassThrough();
          return {
            stdin,
            stdout,
            pid: 88_888,
            async close() {
              hungTransportClosed = true;
              stdin.end();
              stdout.end();
            },
          };
        }
        return recoveryWorld.spawnTransport(opts);
      },
    });
    try {
      // Page 1 while Other is hung -> CLI returns page 1 promptly, hung transport is cancelled & closed.
      const page1 = await hRec.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", {
        limit: 2,
        sortKey: "updated_at",
      });
      expect(page1.data.map((d) => d.id)).toEqual(["cli-rec-3", "cli-rec-2"]);
      expect(page1.nextCursor).not.toBeNull();
      expect(hungTransportClosed).toBe(true);
      expect(recoveryDiags).toContainEqual(expect.objectContaining({ status: "timeout", timeoutMs: 100 }));

      // Other recovers BEFORE page 2 is fetched!
      otherHungMode = false;
      const page2 = await hRec.rpc<{ data: Array<{ id: string }>; nextCursor: string | null }>("thread/list", {
        limit: 5,
        sortKey: "updated_at",
        cursor: page1.nextCursor,
      });
      expect(page2.data.map((d) => d.id)).toEqual(["cli-rec-1", otherId]);
      expect(recoveryDiags).toContainEqual(expect.objectContaining({ status: "ok", count: 1 }));
    } finally {
      await hRec.close();
    }
  });
});

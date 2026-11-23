import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { serveConnection } from "@mimi/appserver-kit/server/connection.ts";
import { SessionRegistry } from "@mimi/appserver-kit/session/registry.ts";
import { AgyOverlay } from "../src/agy/overlay.ts";
import { createApp } from "../src/app.ts";
import { hashNormalizedPrompt } from "../src/runtime/userInput.ts";
import { FakeAgyWorld } from "./support/fake-agy.ts";

describe("mimi-agy-adapter round6 fixes (B10)", () => {
  let tempRoot = "";
  let fakeHome = "";
  let workspaceDir = "";
  let stateDir = "";

  beforeEach(async () => {
    tempRoot = await mkdtemp(path.join(os.tmpdir(), "mimi-agy-round6-"));
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

  async function createHarness(world: FakeAgyWorld) {
    const app = createApp({
      stateDir,
      log: () => {},
      agyExecutable: () => "/usr/local/bin/fake-agy",
      probeAgy: async () => ({ version: "1.5.14" }),
      spawnTransport: world.spawnTransport,
      env: () => ({ HOME: fakeHome }),
    });
    const registry = new SessionRegistry({
      idleTtlMs: 60_000,
      onExpire: (session) => app.manager.unsubscribeSession(session),
    });
    registry.onCreate = (session) => session.setBusyCheck(() => app.manager.isSessionBusy(session));

    const clientIn = new PassThrough();
    const clientOut = new PassThrough();
    let seq = 0;
    const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
    const notifications: Array<Record<string, unknown>> = [];

    let buffer = "";
    clientOut.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      while (true) {
        const idx = buffer.indexOf("\n");
        if (idx < 0) break;
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        if (!line) continue;
        const frame = JSON.parse(line) as { id?: number; method?: string; result?: unknown; error?: { message: string } };
        if (typeof frame.id === "number" && !frame.method) {
          const waiter = pending.get(frame.id);
          if (waiter) {
            pending.delete(frame.id);
            if (frame.error) waiter.reject(new Error(frame.error.message));
            else waiter.resolve(frame.result);
          }
        } else {
          notifications.push(frame as Record<string, unknown>);
        }
      }
    });

    const served = serveConnection(clientIn, clientOut, {
      registry,
      router: app.router,
      log: () => {},
      onClientResponse: (session, generation, frame) => app.manager.handleClientResponse(session, generation, frame),
      onAnonymousSessionEnd: (session) => app.manager.unsubscribeSession(session),
    });

    const rpc = <T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> =>
      new Promise<T>((resolve, reject) => {
        const id = ++seq;
        pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
        clientIn.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      });

    await rpc("initialize", { clientInfo: { name: "test", version: "1.0.0" } });

    return {
      app,
      rpc,
      notifications,
      async close() {
        clientIn.end();
        await served.catch(() => {});
        await app.close();
      },
    };
  }

  async function waitIdle(notifications: Array<Record<string, unknown>>, count = 1): Promise<void> {
    for (let i = 0; i < 100; i += 1) {
      const completed = notifications.filter((n) => n.method === "turn/completed").length;
      const idle = notifications.filter(
        (n) => n.method === "thread/status/changed" && (n.params as { status?: { type?: string } })?.status?.type === "idle",
      ).length;
      if (completed >= count && idle >= count) return;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error(`timed out waiting for ${count} completed+idle notifications`);
  }

  test("B10 round6: merging same assistant message ID with partial native prefix preserves streamed suffix, clientId, and supports follow-up continuation", async () => {
    const sessionId = "b10-r6-prefix-merge";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const transcriptPath = path.join(logsDir, "transcript_full.jsonl");
    const baseLines = [
      JSON.stringify({
        step_index: 0,
        type: "USER_INPUT",
        status: "DONE",
        created_at: new Date(Date.now() - 60_000).toISOString(),
        content: "<USER_REQUEST>\nfirst turn\n</USER_REQUEST>",
      }),
      JSON.stringify({
        step_index: 1,
        type: "PLANNER_RESPONSE",
        status: "DONE",
        created_at: new Date(Date.now() - 59_000).toISOString(),
        content: "FIRST REPLY",
      }),
    ];
    await writeFile(transcriptPath, `${baseLines.join("\n")}\n`);
    const oldTime = new Date(Date.now() - 5 * 60_000);
    await utimes(transcriptPath, oldTime, oldTime);

    let promptCount = 0;
    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Prefix Merge",
          updatedAt: new Date(Date.now() - 59_000).toISOString(),
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [
            { sessionUpdate: "user_message_chunk", content: { type: "text", text: "first turn" } },
            { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "FIRST REPLY" } },
          ],
        },
      ],
      onPrompt: async ({ emitUpdate }) => {
        promptCount += 1;
        if (promptCount === 1) {
          emitUpdate({
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP" },
          });
          return { stopReason: "cancelled" };
        }
        emitUpdate({
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "FOLLOWUP TURN THREE OK" },
        });
        return { stopReason: "end_turn" };
      },
    });

    const promptStartedAt = new Date().toISOString();
    const live = await createHarness(world);
    try {
      await live.rpc("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        clientUserMessageId: "client-partial-stop",
        input: [{ type: "text", text: "stream partial then stop", text_elements: [] }],
      });
      await waitIdle(live.notifications, 1);

      // Fixture A: Native delayed persistence writes only the prefix under the same msg:1 ID with CANCELLED.
      await writeFile(
        transcriptPath,
        [
          ...baseLines,
          JSON.stringify({
            step_index: 2,
            type: "USER_INPUT",
            status: "DONE",
            created_at: promptStartedAt,
            content: "<USER_REQUEST>\nstream partial then stop\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 3,
            type: "PLANNER_RESPONSE",
            status: "CANCELLED",
            created_at: new Date().toISOString(),
            content: "PARTIAL STREAMED OUTPUT",
          }),
        ].join("\n") + "\n",
      );
      await utimes(transcriptPath, oldTime, oldTime);
    } finally {
      await live.close();
    }

    // Cold reopen #1 (CANCELLED partial native prefix): must keep fuller suffix, same msg:1 ID, and clientId.
    const coldA = await createHarness(world);
    try {
      const read = await coldA.rpc<{
        thread: {
          turns: Array<{
            id: string;
            status: string;
            items: Array<{ type: string; id: string; text?: string; clientId?: string | null }>;
          }>;
        };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(2);
      const second = read.thread.turns[1]!;
      expect(second.id).toBe(`${sessionId}:turn:2`);
      expect(second.status).toBe("interrupted");
      expect(second.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: `${sessionId}:turn:2:user`,
        clientId: "client-partial-stop",
      });
      const agentMsgs = second.items.filter((i) => i.type === "agentMessage");
      expect(agentMsgs).toHaveLength(1);
      expect(agentMsgs[0]).toMatchObject({
        id: `${sessionId}:turn:2:msg:1`,
        text: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP",
      });
    } finally {
      await coldA.close();
    }

    // Fixture B: Native delayed persistence writes the same prefix but marked DONE (instead of CANCELLED).
    await writeFile(
      transcriptPath,
      [
        ...baseLines,
        JSON.stringify({
          step_index: 2,
          type: "USER_INPUT",
          status: "DONE",
          created_at: promptStartedAt,
          content: "<USER_REQUEST>\nstream partial then stop\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 3,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: new Date().toISOString(),
          content: "PARTIAL STREAMED OUTPUT",
        }),
      ].join("\n") + "\n",
    );
    await utimes(transcriptPath, oldTime, oldTime);

    const coldB = await createHarness(world);
    let followUpTurnId = "";
    let followUpUserId = "";
    let followUpMsgId = "";
    try {
      const read = await coldB.rpc<{
        thread: {
          turns: Array<{
            id: string;
            status: string;
            items: Array<{ type: string; id: string; text?: string; clientId?: string | null }>;
          }>;
        };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(2);
      expect(read.thread.turns[1]?.status).toBe("interrupted");
      expect(read.thread.turns[1]?.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: `${sessionId}:turn:2:user`,
        clientId: "client-partial-stop",
      });
      expect(read.thread.turns[1]?.items.find((i) => i.type === "agentMessage")).toMatchObject({
        id: `${sessionId}:turn:2:msg:1`,
        text: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP",
      });

      // Continue the session with Turn 3 after cold reopen.
      const started = await coldB.rpc<{ turn: { id: string } }>("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        clientUserMessageId: "client-followup-turn-3",
        input: [{ type: "text", text: "continue after partial merge", text_elements: [] }],
      });
      followUpTurnId = started.turn.id;
      expect(followUpTurnId).not.toBe(`${sessionId}:turn:1`);
      expect(followUpTurnId).not.toBe(`${sessionId}:turn:2`);
      await waitIdle(coldB.notifications, 1);

      const completedItems = coldB.notifications
        .filter((n) => n.method === "item/completed")
        .map((n) => (n.params as { item?: { type?: string; id?: string; clientId?: string | null } }).item);
      followUpUserId = completedItems.find((i) => i?.type === "userMessage")?.id ?? "";
      followUpMsgId = completedItems.find((i) => i?.type === "agentMessage")?.id ?? "";
      expect(followUpUserId).toBe(`${followUpTurnId}:user`);
      expect(followUpMsgId).toBe(`${followUpTurnId}:msg:1`);

      // Persist Turn 3 into native transcript and verify cold read preserves both Turn 2 suffix and Turn 3 clientId.
      await writeFile(
        transcriptPath,
        [
          ...baseLines,
          JSON.stringify({
            step_index: 2,
            type: "USER_INPUT",
            status: "DONE",
            created_at: promptStartedAt,
            content: "<USER_REQUEST>\nstream partial then stop\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 3,
            type: "PLANNER_RESPONSE",
            status: "CANCELLED",
            created_at: new Date().toISOString(),
            content: "PARTIAL STREAMED OUTPUT",
          }),
          JSON.stringify({
            step_index: 4,
            type: "USER_INPUT",
            status: "DONE",
            created_at: new Date().toISOString(),
            content: "<USER_REQUEST>\ncontinue after partial merge\n</USER_REQUEST>",
          }),
          JSON.stringify({
            step_index: 5,
            type: "PLANNER_RESPONSE",
            status: "DONE",
            created_at: new Date().toISOString(),
            content: "FOLLOWUP TURN THREE OK",
          }),
        ].join("\n") + "\n",
      );
      await utimes(transcriptPath, oldTime, oldTime);
    } finally {
      await coldB.close();
    }

    const coldAfterFollowUp = await createHarness(world);
    try {
      const read = await coldAfterFollowUp.rpc<{
        thread: {
          turns: Array<{
            id: string;
            status: string;
            items: Array<{ type: string; id: string; text?: string; clientId?: string | null }>;
          }>;
        };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(3);
      expect(read.thread.turns[1]?.items.find((i) => i.type === "agentMessage")).toMatchObject({
        id: `${sessionId}:turn:2:msg:1`,
        text: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP",
      });
      expect(read.thread.turns[2]).toMatchObject({
        id: followUpTurnId,
        status: "completed",
      });
      expect(read.thread.turns[2]?.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: followUpUserId,
        clientId: "client-followup-turn-3",
      });
      expect(read.thread.turns[2]?.items.find((i) => i.type === "agentMessage")).toMatchObject({
        id: followUpMsgId,
        text: "FOLLOWUP TURN THREE OK",
      });
    } finally {
      await coldAfterFollowUp.close();
    }

    // Native text already longer than synthetic snapshot must NOT be truncated backwards.
    await writeFile(
      transcriptPath,
      [
        ...baseLines,
        JSON.stringify({
          step_index: 2,
          type: "USER_INPUT",
          status: "DONE",
          created_at: promptStartedAt,
          content: "<USER_REQUEST>\nstream partial then stop\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 3,
          type: "PLANNER_RESPONSE",
          status: "CANCELLED",
          created_at: new Date().toISOString(),
          content: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP PLUS EXTRA NATIVE TAIL",
        }),
      ].join("\n") + "\n",
    );
    await utimes(transcriptPath, oldTime, oldTime);

    const coldLongerNative = await createHarness(world);
    try {
      const read = await coldLongerNative.rpc<{
        thread: {
          turns: Array<{
            id: string;
            status: string;
            items: Array<{ type: string; id: string; text?: string; clientId?: string | null }>;
          }>;
        };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(read.thread.turns[1]?.items.find((i) => i.type === "agentMessage")).toMatchObject({
        id: `${sessionId}:turn:2:msg:1`,
        text: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP PLUS EXTRA NATIVE TAIL",
      });
    } finally {
      await coldLongerNative.close();
    }
  });

  test("B10 round6: completed turn with 306-char prompt (space at char 240) preserves turn ID, message IDs, and clientId across cold restart", async () => {
    const prompt306 = `${"P".repeat(239)} ${"tail-segment-306-".repeat(3)}end-token-01234`;
    expect(prompt306.length).toBe(306);
    expect(prompt306[239]).toBe(" ");

    const world = new FakeAgyWorld({
      onPrompt: async ({ emitUpdate }) => {
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "COMPLETED LONG REPLY" } });
        return { stopReason: "end_turn" };
      },
    });

    let threadId = "";
    let liveTurnId = "";
    let liveUserId = "";
    let liveMsgId = "";
    const clientId = "client-completed-long-306";

    const live = await createHarness(world);
    try {
      const started = await live.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      threadId = started.thread.id;
      await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`), "sqlite");

      const startedTurn = await live.rpc<{ turn: { id: string } }>("turn/start", {
        threadId,
        cwd: workspaceDir,
        clientUserMessageId: clientId,
        input: [{ type: "text", text: prompt306, text_elements: [] }],
      });
      liveTurnId = startedTurn.turn.id;
      await waitIdle(live.notifications, 1);

      const completedItems = live.notifications
        .filter((n) => n.method === "item/completed")
        .map((n) => (n.params as { item?: { type?: string; id?: string; clientId?: string | null } }).item);
      const userItem = completedItems.find((i) => i?.type === "userMessage");
      const msgItem = completedItems.find((i) => i?.type === "agentMessage");
      liveUserId = userItem?.id ?? "";
      liveMsgId = msgItem?.id ?? "";
      expect(userItem?.clientId).toBe(clientId);
    } finally {
      await live.close();
    }

    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", threadId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const transcriptPath = path.join(logsDir, "transcript_full.jsonl");
    await writeFile(
      transcriptPath,
      [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: new Date(Date.now() - 10_000).toISOString(),
          content: `<USER_REQUEST>\n${prompt306}\n</USER_REQUEST>`,
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: new Date(Date.now() - 9_000).toISOString(),
          content: "COMPLETED LONG REPLY",
        }),
      ].join("\n") + "\n",
    );
    const oldTime = new Date(Date.now() - 5 * 60_000);
    await utimes(transcriptPath, oldTime, oldTime);

    const cold = await createHarness(world);
    try {
      const read = await cold.rpc<{
        thread: {
          turns: Array<{
            id: string;
            status: string;
            items: Array<{ type: string; id: string; clientId?: string | null; text?: string }>;
          }>;
        };
      }>("thread/read", { threadId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(1);
      expect(read.thread.turns[0]?.id).toBe(liveTurnId);
      expect(read.thread.turns[0]?.status).toBe("completed");
      expect(read.thread.turns[0]?.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: liveUserId,
        clientId,
      });
      expect(read.thread.turns[0]?.items.find((i) => i.type === "agentMessage")).toMatchObject({
        id: liveMsgId,
        text: "COMPLETED LONG REPLY",
      });

      const listed = await cold.rpc<{
        data: Array<{
          id: string;
          items: Array<{ type: string; id: string; clientId?: string | null }>;
        }>;
      }>("thread/turns/list", { threadId });
      expect(listed.data).toHaveLength(1);
      expect(listed.data[0]?.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: liveUserId,
        clientId,
      });
    } finally {
      await cold.close();
    }
  });

  test("pruning turnAttempts past 200 preserves historical turn identities, clientIds, and unpersisted synthetic turns across cold restart", async () => {
    const sessionId = "prune-history-205";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const transcriptPath = path.join(logsDir, "transcript_full.jsonl");

    const overlayPath = path.join(stateDir, "overlay.json");
    const overlay = new AgyOverlay(overlayPath);
    const baseMs = Date.now() - 300_000;

    // Attempt 1: unpersisted early failure assigned turn:1 with a synthetic turn and clientId.
    const failPrompt = "early failed prompt before persist";
    const failReserved = await overlay.reserveTurnAttempt(sessionId, {
      minTurnOrdinal: 1,
      afterPersistedTurnCount: 0,
      promptText: failPrompt,
      promptHash: hashNormalizedPrompt(failPrompt),
      promptTruncated: false,
      clientId: "client-fail-1",
      startedAtMs: baseMs,
    });
    expect(failReserved.turnId).toBe(`${sessionId}:turn:1`);
    await overlay.recordSession(sessionId, {
      cwd: workspaceDir,
      updatedAt: Math.floor(baseMs / 1000),
      turnAttemptUpdate: {
        attemptId: failReserved.attemptId,
        turnId: failReserved.turnId,
        promptText: failPrompt,
        promptHash: hashNormalizedPrompt(failPrompt),
        promptTruncated: false,
        clientId: "client-fail-1",
        afterPersistedTurnCount: 0,
        status: "failed",
        error: "quota exceeded before persist",
        persisted: false,
        startedAtMs: baseMs,
        completedAtMs: baseMs + 500,
        syntheticTurn: {
          id: failReserved.turnId,
          rootTurnId: null,
          items: [
            {
              type: "userMessage",
              id: `${failReserved.turnId}:user`,
              clientId: "client-fail-1",
              content: [{ type: "text", text: failPrompt, text_elements: [] }],
            },
          ],
          itemsView: "full",
          status: "failed",
          error: {
            message: "quota exceeded before persist",
            codexErrorInfo: null,
            additionalDetails: null,
            misalignment: null,
          },
          startedAt: Math.floor(baseMs / 1000),
          completedAt: Math.floor((baseMs + 500) / 1000),
          durationMs: 500,
        },
      },
    });

    // Attempts 2..205: 204 persisted native turns (total 205 attempts -> exceeds 200-attempt active window).
    const transcriptLines: string[] = [];
    const totalNativeTurns = 204;
    for (let nativeIdx = 0; nativeIdx < totalNativeTurns; nativeIdx += 1) {
      const turnNumber = nativeIdx + 2;
      const prompt = `native prompt number ${turnNumber}`;
      const promptHash = hashNormalizedPrompt(prompt);
      const clientId = `client-ok-${turnNumber}`;
      const userStepIndex = nativeIdx * 2;
      const startedAtMs = baseMs + turnNumber * 1_000;
      const reserved = await overlay.reserveTurnAttempt(sessionId, {
        minTurnOrdinal: turnNumber,
        afterPersistedTurnCount: nativeIdx,
        promptText: prompt,
        promptHash,
        promptTruncated: false,
        clientId,
        startedAtMs,
      });
      expect(reserved.turnId).toBe(`${sessionId}:turn:${turnNumber}`);
      await overlay.recordSession(sessionId, {
        updatedAt: Math.floor((startedAtMs + 500) / 1000),
        turnAttemptUpdate: {
          attemptId: reserved.attemptId,
          turnId: reserved.turnId,
          promptText: prompt,
          promptHash,
          promptTruncated: false,
          clientId,
          afterPersistedTurnCount: nativeIdx,
          status: "completed",
          error: null,
          persisted: true,
          nativeUserStepIndex: userStepIndex,
          startedAtMs,
          completedAtMs: startedAtMs + 500,
        },
      });
      transcriptLines.push(
        JSON.stringify({
          step_index: userStepIndex,
          type: "USER_INPUT",
          status: "DONE",
          created_at: new Date(startedAtMs).toISOString(),
          content: `<USER_REQUEST>\n${prompt}\n</USER_REQUEST>`,
        }),
        JSON.stringify({
          step_index: userStepIndex + 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: new Date(startedAtMs + 400).toISOString(),
          content: `reply ${turnNumber}`,
        }),
      );
    }
    await overlay.flush();

    await writeFile(transcriptPath, `${transcriptLines.join("\n")}\n`);
    const oldTime = new Date(Date.now() - 5 * 60_000);
    await utimes(transcriptPath, oldTime, oldTime);

    // Verify on-disk overlay keeps active turnAttempts bounded to 200 while compacting evicted entries into archivedTurnAttempts.
    const rawOverlay = JSON.parse(await readFile(overlayPath, "utf8")) as {
      sessions?: Record<
        string,
        {
          turnAttempts?: Array<{ turnId: string; promptText: string; promptHash?: string; clientId?: string }>;
          archivedTurnAttempts?: Array<{
            turnId: string;
            status: string;
            promptText: string;
            promptHash?: string;
            clientId?: string;
            startedAtMs?: number;
            syntheticTurn?: unknown;
          }>;
        }
      >;
    };
    const sessionOverlay = rawOverlay.sessions?.[sessionId];
    expect(sessionOverlay?.turnAttempts).toHaveLength(200);
    expect(sessionOverlay?.archivedTurnAttempts).toHaveLength(5);
    expect(sessionOverlay?.archivedTurnAttempts?.[0]).toMatchObject({
      turnId: `${sessionId}:turn:1`,
      status: "failed",
      clientId: "client-fail-1",
    });
    expect(sessionOverlay?.archivedTurnAttempts?.[0]?.syntheticTurn).toBeDefined();
    expect(sessionOverlay?.archivedTurnAttempts?.[1]).toMatchObject({
      turnId: `${sessionId}:turn:2`,
      status: "completed",
      promptText: "",
      promptHash: hashNormalizedPrompt("native prompt number 2"),
      clientId: "client-ok-2",
    });
    expect(sessionOverlay?.archivedTurnAttempts?.[1]?.startedAtMs).toBeUndefined();

    // Cold reopen must reconstruct all 205 turns with exact historical IDs and clientIds.
    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Long History 205",
          updatedAt: new Date(baseMs + 206_000).toISOString(),
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });
    const cold = await createHarness(world);
    try {
      const read = await cold.rpc<{
        thread: {
          turns: Array<{
            id: string;
            status: string;
            error?: { message?: string } | null;
            items: Array<{ type: string; id: string; clientId?: string | null; text?: string }>;
          }>;
        };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(205);

      // Turn 1: unpersisted synthetic failure preserved intact.
      expect(read.thread.turns[0]).toMatchObject({
        id: `${sessionId}:turn:1`,
        status: "failed",
        error: { message: "quota exceeded before persist" },
      });
      expect(read.thread.turns[0]?.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: `${sessionId}:turn:1:user`,
        clientId: "client-fail-1",
      });

      // Turn 2: first persisted native turn MUST remain turn:2 with client-ok-2 (not shift down to turn:1 without clientId).
      expect(read.thread.turns[1]).toMatchObject({
        id: `${sessionId}:turn:2`,
        status: "completed",
      });
      expect(read.thread.turns[1]?.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: `${sessionId}:turn:2:user`,
        clientId: "client-ok-2",
      });

      // Turn 205: latest turn preserved intact.
      expect(read.thread.turns[204]).toMatchObject({
        id: `${sessionId}:turn:205`,
        status: "completed",
      });
      expect(read.thread.turns[204]?.items.find((i) => i.type === "userMessage")).toMatchObject({
        id: `${sessionId}:turn:205:user`,
        clientId: "client-ok-205",
      });
    } finally {
      await cold.close();
    }

    // Reserving after an external native turn (afterPersistedTurnCount=205) still counts the archived unpersisted failure.
    const reloadedOverlay = new AgyOverlay(overlayPath);
    const nextReserved = await reloadedOverlay.reserveTurnAttempt(sessionId, {
      minTurnOrdinal: 206,
      afterPersistedTurnCount: 205,
      promptText: "after external native append",
      promptHash: hashNormalizedPrompt("after external native append"),
      promptTruncated: false,
      clientId: "client-ok-207",
    });
    expect(nextReserved.turnId).toBe(`${sessionId}:turn:207`);
  });
});

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { serveConnection } from "@mimi/appserver-kit/server/connection.ts";
import { SessionRegistry } from "@mimi/appserver-kit/session/registry.ts";
import { createApp } from "../src/app.ts";
import type { SpawnAgyTransport } from "../src/agy/binary.ts";
import type { AgySessionBackend } from "../src/agy/catalog.ts";
import { decodePercentEncodedPath, normalizeNativeCwd } from "../src/agy/git.ts";
import { inspectTranscriptActivity } from "../src/agy/transcript.ts";
import { FakeAgyWorld } from "./support/fake-agy.ts";

describe("mimi-agy-adapter round5 fixes", () => {
  let tempRoot = "";
  let fakeHome = "";
  let workspaceDir = "";
  let stateDir = "";

  beforeEach(async () => {
    tempRoot = await mkdtemp(path.join(os.tmpdir(), "mimi-agy-round5-"));
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

  async function createHarness(
    world: FakeAgyWorld,
    extra: {
      spawnTransport?: SpawnAgyTransport;
      env?: () => NodeJS.ProcessEnv;
      sessionBackend?: AgySessionBackend;
    } = {},
  ) {
    const env = extra.env ?? (() => ({ HOME: fakeHome }));
    const app = createApp({
      stateDir,
      log: () => {},
      agyExecutable: () => "/usr/local/bin/fake-agy",
      probeAgy: async () => ({ version: "1.5.14" }),
      spawnTransport: extra.spawnTransport ?? world.spawnTransport,
      env,
      ...(extra.sessionBackend ? { sessionBackend: extra.sessionBackend } : {}),
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

  test("B10 round5: 263-char prompt with space at char 240 preserves turn and message IDs across cold restart (both new and legacy overlays)", async () => {
    // Construct a 263-char prompt whose 240th character (index 239) is a space.
    const prefix239 = "A".repeat(239);
    const suffix23 = "tail-distinct-segment-1";
    const prompt263 = `${prefix239} ${suffix23}`;
    expect(prompt263.length).toBe(263);
    expect(prompt263[239]).toBe(" ");

    const world = new FakeAgyWorld({
      onPrompt: async ({ emitUpdate }) => {
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "LONG PROMPT ANSWER" } });
        return { stopReason: "end_turn" };
      },
    });

    let threadId = "";
    let liveTurnId = "";
    let liveUserId = "";
    let liveMsgId = "";

    const live = await createHarness(world);
    try {
      const started = await live.rpc<{ thread: { id: string } }>("thread/start", { cwd: workspaceDir });
      threadId = started.thread.id;
      await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${threadId}.db`), "sqlite");

      const startedTurn = await live.rpc<{ turn: { id: string } }>("turn/start", {
        threadId,
        cwd: workspaceDir,
        clientUserMessageId: "client-long-240-space",
        input: [{ type: "text", text: prompt263, text_elements: [] }],
      });
      liveTurnId = startedTurn.turn.id;
      await waitIdle(live.notifications, 1);

      const completedItems = live.notifications
        .filter((n) => n.method === "item/completed")
        .map((n) => (n.params as { item?: { type?: string; id?: string } }).item);
      liveUserId = completedItems.find((i) => i?.type === "userMessage")?.id ?? "";
      liveMsgId = completedItems.find((i) => i?.type === "agentMessage")?.id ?? "";
      expect(liveTurnId).toBe(`${threadId}:turn:1`);
      expect(liveUserId).toBe(`${threadId}:turn:1:user`);
      expect(liveMsgId).toBe(`${threadId}:turn:1:msg:1`);
    } finally {
      await live.close();
    }

    // Write native transcript containing the full 263-char prompt and reply.
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
          content: `<USER_REQUEST>\n${prompt263}\n</USER_REQUEST>`,
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: new Date(Date.now() - 9_000).toISOString(),
          content: "LONG PROMPT ANSWER",
        }),
      ].join("\n") + "\n",
    );
    const oldTime = new Date(Date.now() - 5 * 60_000);
    await utimes(transcriptPath, oldTime, oldTime);

    // 1) Cold restart with round5 overlay (explicit promptHash + promptTruncated).
    const coldNew = await createHarness(world);
    try {
      const read = await coldNew.rpc<{
        thread: { turns: Array<{ id: string; status: string; items: Array<{ type: string; id: string }> }> };
      }>("thread/read", { threadId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(1);
      expect(read.thread.turns[0]?.id).toBe(liveTurnId);
      expect(read.thread.turns[0]?.status).toBe("completed");
      expect(read.thread.turns[0]?.items.find((i) => i.type === "userMessage")?.id).toBe(liveUserId);
      expect(read.thread.turns[0]?.items.find((i) => i.type === "agentMessage")?.id).toBe(liveMsgId);
    } finally {
      await coldNew.close();
    }

    // 2) Legacy overlay (no promptHash / promptTruncated, raw 240-char preview ending with space) also keeps exact IDs.
    const legacySessionId = "b10-r5-legacy-240-space";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${legacySessionId}.db`), "sqlite");
    const legacyLogs = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", legacySessionId, ".system_generated", "logs");
    await mkdir(legacyLogs, { recursive: true });
    const legacyTranscript = path.join(legacyLogs, "transcript_full.jsonl");
    await writeFile(
      legacyTranscript,
      [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: `<USER_REQUEST>\n${prompt263}\n</USER_REQUEST>`,
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:01Z",
          content: "LEGACY LONG ANSWER",
        }),
      ].join("\n") + "\n",
    );
    await utimes(legacyTranscript, oldTime, oldTime);

    await writeFile(
      path.join(stateDir, "overlay.json"),
      JSON.stringify({
        version: 1,
        sessions: {
          [legacySessionId]: {
            cwd: workspaceDir,
            nextTurnOrdinal: 1,
            nextAttemptSeq: 1,
            turnAttempts: [
              {
                attemptId: `${legacySessionId}:attempt:1`,
                turnId: `${legacySessionId}:turn:1`,
                promptText: prompt263.slice(0, 240),
                afterPersistedTurnCount: 0,
                status: "completed",
                error: null,
                persisted: true,
                createdAt: 1700000000,
              },
            ],
          },
        },
      }),
    );

    const legacyWorld = new FakeAgyWorld({
      sessions: [
        {
          sessionId: legacySessionId,
          cwd: workspaceDir,
          title: "Legacy 240 Space",
          updatedAt: "2026-11-22T01:00:01Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });

    const coldLegacy = await createHarness(legacyWorld);
    try {
      const read = await coldLegacy.rpc<{
        thread: { turns: Array<{ id: string; status: string; items: Array<{ type: string; id: string }> }> };
      }>("thread/read", { threadId: legacySessionId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(1);
      expect(read.thread.turns[0]?.id).toBe(`${legacySessionId}:turn:1`);
      expect(read.thread.turns[0]?.items.find((i) => i.type === "userMessage")?.id).toBe(`${legacySessionId}:turn:1:user`);
      expect(read.thread.turns[0]?.items.find((i) => i.type === "agentMessage")?.id).toBe(`${legacySessionId}:turn:1:msg:1`);
    } finally {
      await coldLegacy.close();
    }
  });

  test("B10 round5: late-flushed user-only native turn preserves streamed partial assistant output and original IDs when deduplicated", async () => {
    const sessionId = "b10-r5-late-partial";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    // Seed an existing persisted transcript with Turn 1 so Turn 2 starts on a persisted session.
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

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Late Partial",
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
        emitUpdate({
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP" },
        });
        return { stopReason: "cancelled" };
      },
    });

    const live = await createHarness(world);
    try {
      const promptStartedAt = new Date().toISOString();
      await live.rpc("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        clientUserMessageId: "client-partial-stop",
        input: [{ type: "text", text: "stream partial then stop", text_elements: [] }],
      });
      await waitIdle(live.notifications, 1);

      // Now native transcript flushes ONLY the USER_INPUT late (without the streamed assistant text).
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
        ].join("\n") + "\n",
      );
      await utimes(transcriptPath, oldTime, oldTime);
    } finally {
      await live.close();
    }

    const cold = await createHarness(world);
    try {
      const read = await cold.rpc<{
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
      expect(second.items.find((i) => i.type === "agentMessage")).toMatchObject({
        id: `${sessionId}:turn:2:msg:1`,
        text: "PARTIAL STREAMED OUTPUT VISIBLE BEFORE STOP",
      });
    } finally {
      await cold.close();
    }
  });

  test("B10 round5: independent identical-text retries without assistant reply are NOT merged into prior early failure or prior interrupt", async () => {
    const sessionId = "b10-r5-identical-retries";
    await mkdir(stateDir, { recursive: true });
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const transcriptPath = path.join(logsDir, "transcript_full.jsonl");

    // Case A: Prior early failure (persisted:false, no assistant output), followed by an independent native
    // identical-text turn that persisted USER_INPUT only (no assistant reply).
    await writeFile(
      transcriptPath,
      [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: "<USER_REQUEST>\nbaseline\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:01Z",
          content: "BASELINE OK",
        }),
        JSON.stringify({
          step_index: 2,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:05:00Z",
          content: "<USER_REQUEST>\nsame retry prompt\n</USER_REQUEST>",
        }),
      ].join("\n") + "\n",
    );
    const oldTime = new Date(Date.now() - 5 * 60_000);
    await utimes(transcriptPath, oldTime, oldTime);

    await writeFile(
      path.join(stateDir, "overlay.json"),
      JSON.stringify({
        version: 1,
        sessions: {
          [sessionId]: {
            cwd: workspaceDir,
            nextTurnOrdinal: 2,
            nextAttemptSeq: 1,
            turnAttempts: [
              {
                attemptId: `${sessionId}:attempt:1`,
                turnId: `${sessionId}:turn:2`,
                promptText: "same retry prompt",
                afterPersistedTurnCount: 1,
                status: "failed",
                error: "Error: EARLY_FAILURE_BEFORE_PERSIST",
                persisted: false,
                startedAtMs: Date.parse("2026-11-22T01:02:00Z"),
                completedAtMs: Date.parse("2026-11-22T01:02:01Z"),
                syntheticTurn: {
                  id: `${sessionId}:turn:2`,
                  rootTurnId: null,
                  items: [
                    {
                      type: "userMessage",
                      id: `${sessionId}:turn:2:user`,
                      clientId: null,
                      content: [{ type: "text", text: "same retry prompt", text_elements: [] }],
                    },
                  ],
                  itemsView: "full",
                  status: "failed",
                  error: {
                    message: "Error: EARLY_FAILURE_BEFORE_PERSIST",
                    codexErrorInfo: null,
                    additionalDetails: null,
                    misalignment: null,
                  },
                  startedAt: Math.floor(Date.parse("2026-11-22T01:02:00Z") / 1000),
                  completedAt: Math.floor(Date.parse("2026-11-22T01:02:01Z") / 1000),
                  durationMs: 1000,
                },
                createdAt: Math.floor(Date.parse("2026-11-22T01:02:00Z") / 1000),
              },
            ],
          },
        },
      }),
    );

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Identical Retry",
          updatedAt: "2026-11-22T01:05:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });

    const hA = await createHarness(world);
    try {
      const read = await hA.rpc<{
        thread: { turns: Array<{ id: string; status: string; error: { message: string } | null }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      // Must preserve ALL 3 distinct turns: baseline, prior early failure, and independent native retry!
      expect(read.thread.turns).toHaveLength(3);
      expect(read.thread.turns[0]).toMatchObject({ id: `${sessionId}:turn:1`, status: "completed", error: null });
      expect(read.thread.turns[1]).toMatchObject({
        id: `${sessionId}:turn:2`,
        status: "failed",
        error: expect.objectContaining({ message: "Error: EARLY_FAILURE_BEFORE_PERSIST" }),
      });
      expect(read.thread.turns[2]).toMatchObject({ id: `${sessionId}:turn:3`, status: "completed", error: null });
    } finally {
      await hA.close();
    }

    // Case B: Prior interrupt (persisted:false) + later independent identical-text retry (adapter interrupted & persisted, no assistant reply).
    const sessionB = "b10-r5-identical-two-attempts";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionB}.db`), "sqlite");
    const logsB = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionB, ".system_generated", "logs");
    await mkdir(logsB, { recursive: true });
    const transcriptB = path.join(logsB, "transcript_full.jsonl");
    await writeFile(
      transcriptB,
      [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:02:00Z",
          content: "<USER_REQUEST>\nsame retry prompt\n</USER_REQUEST>",
        }),
      ].join("\n") + "\n",
    );
    await utimes(transcriptB, oldTime, oldTime);

    await writeFile(
      path.join(stateDir, "overlay.json"),
      JSON.stringify({
        version: 1,
        sessions: {
          [sessionB]: {
            cwd: workspaceDir,
            nextTurnOrdinal: 2,
            nextAttemptSeq: 2,
            turnAttempts: [
              {
                attemptId: `${sessionB}:attempt:1`,
                turnId: `${sessionB}:turn:1`,
                promptText: "same retry prompt",
                afterPersistedTurnCount: 0,
                status: "interrupted",
                error: null,
                persisted: false,
                startedAtMs: Date.parse("2026-11-22T01:02:00Z"),
                completedAtMs: Date.parse("2026-11-22T01:02:00Z"),
                syntheticTurn: {
                  id: `${sessionB}:turn:1`,
                  rootTurnId: null,
                  items: [
                    {
                      type: "userMessage",
                      id: `${sessionB}:turn:1:user`,
                      clientId: "c1",
                      content: [{ type: "text", text: "same retry prompt", text_elements: [] }],
                    },
                  ],
                  itemsView: "full",
                  status: "interrupted",
                  error: null,
                  startedAt: 1700000000,
                  completedAt: 1700000001,
                  durationMs: 1000,
                },
                createdAt: 1700000000,
              },
              {
                attemptId: `${sessionB}:attempt:2`,
                turnId: `${sessionB}:turn:2`,
                promptText: "same retry prompt",
                afterPersistedTurnCount: 0,
                status: "interrupted",
                error: null,
                persisted: true,
                startedAtMs: Date.parse("2026-11-22T01:02:00Z"),
                completedAtMs: Date.parse("2026-11-22T01:02:01Z"),
                syntheticTurn: {
                  id: `${sessionB}:turn:2`,
                  rootTurnId: null,
                  items: [
                    {
                      type: "userMessage",
                      id: `${sessionB}:turn:2:user`,
                      clientId: "c2",
                      content: [{ type: "text", text: "same retry prompt", text_elements: [] }],
                    },
                  ],
                  itemsView: "full",
                  status: "interrupted",
                  error: null,
                  startedAt: 1700000000,
                  completedAt: 1700000001,
                  durationMs: 1000,
                },
                createdAt: 1700000000,
              },
            ],
          },
        },
      }),
    );

    const worldB = new FakeAgyWorld({
      sessions: [
        {
          sessionId: sessionB,
          cwd: workspaceDir,
          title: "Two Identical Interrupted Retries",
          updatedAt: "2026-11-22T01:02:01Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });

    const hB = await createHarness(worldB);
    try {
      const read = await hB.rpc<{
        thread: { turns: Array<{ id: string; status: string }> };
      }>("thread/read", { threadId: sessionB, includeTurns: true });
      expect(read.thread.turns).toHaveLength(2);
      expect(read.thread.turns.map((t) => ({ id: t.id, status: t.status }))).toEqual([
        { id: `${sessionB}:turn:1`, status: "interrupted" },
        { id: `${sessionB}:turn:2`, status: "interrupted" },
      ]);
    } finally {
      await hB.close();
    }
  });

  test("B15 round5: legacy overlapped reverse-completion mappings do NOT misbind FIRST/SECOND, while legacy provably serial mappings still restore original IDs (including after B10 turnId rewrite)", async () => {
    const sessionId = "b15-r5-legacy-overlap-and-serial";
    await mkdir(stateDir, { recursive: true });
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    const prompt263 = `${"B".repeat(239)} serial-and-overlap-tail`;
    expect(prompt263.length).toBe(263);
    expect(prompt263[239]).toBe(" ");

    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const transcriptPath = path.join(logsDir, "transcript_full.jsonl");
    await writeFile(
      transcriptPath,
      [
        // Native Turn 1 (will be rewritten to :turn:2 by B10 because Attempt 1 was an unpersisted early failure):
        // Two provably serial identical commands (separate PLANNER_RESPONSE steps with GENERIC DONE in between).
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: `<USER_REQUEST>\n${prompt263}\n</USER_REQUEST>`,
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:01Z",
          tool_calls: [{ name: "run_command", args: { CommandLine: "\"printf fixture-repeat\"" } }],
        }),
        JSON.stringify({
          step_index: 2,
          type: "GENERIC",
          status: "DONE",
          created_at: "2026-11-22T01:00:02Z",
          content: "SERIAL FIRST RESULT",
        }),
        JSON.stringify({
          step_index: 3,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:03Z",
          tool_calls: [{ name: "run_command", args: { CommandLine: "\"printf fixture-repeat\"" } }],
        }),
        JSON.stringify({
          step_index: 4,
          type: "GENERIC",
          status: "DONE",
          created_at: "2026-11-22T01:00:04Z",
          content: "SERIAL SECOND RESULT",
        }),
        JSON.stringify({
          step_index: 5,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:05Z",
          content: "Serial done.",
        }),

        // Native Turn 2 (will be rewritten to :turn:3):
        // Two overlapped concurrent identical commands emitted in a SINGLE PLANNER_RESPONSE batch,
        // where legacy b36 recorded completion order [SECOND, FIRST] (reverse completion!).
        JSON.stringify({
          step_index: 6,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:01:00Z",
          content: "<USER_REQUEST>\nrun overlapped legacy commands\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 7,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:01:01Z",
          tool_calls: [
            { name: "run_command", args: { CommandLine: "\"printf fixture-repeat\"" } },
            { name: "run_command", args: { CommandLine: "\"printf fixture-repeat\"" } },
          ],
        }),
        JSON.stringify({
          step_index: 8,
          type: "GENERIC",
          status: "DONE",
          created_at: "2026-11-22T01:01:02Z",
          content: "OVERLAP FIRST RESULT",
        }),
        JSON.stringify({
          step_index: 9,
          type: "GENERIC",
          status: "DONE",
          created_at: "2026-11-22T01:01:03Z",
          content: "OVERLAP SECOND RESULT",
        }),
        JSON.stringify({
          step_index: 10,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:01:04Z",
          content: "Overlap done.",
        }),
      ].join("\n") + "\n",
    );
    const oldTime = new Date(Date.now() - 5 * 60_000);
    await utimes(transcriptPath, oldTime, oldTime);

    const serialFirstId = `${sessionId}:turn:2:tool:legacy-serial-FIRST`;
    const serialSecondId = `${sessionId}:turn:2:tool:legacy-serial-SECOND`;
    const overlapFirstId = `${sessionId}:turn:3:tool:legacy-overlap-FIRST`;
    const overlapSecondId = `${sessionId}:turn:3:tool:legacy-overlap-SECOND`;

    // Seed legacy overlay with:
    // - Turn 1: unpersisted early failure (forces B10 turnId rewrite on Native Turns 1 & 2 -> :turn:2 and :turn:3)
    // - Turn 2: 263-char space-at-240 completed attempt + legacy serial toolMappings (no invocationIndex)
    // - Turn 3: completed attempt + legacy overlapped toolMappings stored in reverse completion order [SECOND, FIRST]
    await writeFile(
      path.join(stateDir, "overlay.json"),
      JSON.stringify({
        version: 1,
        sessions: {
          [sessionId]: {
            cwd: workspaceDir,
            nextTurnOrdinal: 3,
            nextAttemptSeq: 3,
            turnAttempts: [
              {
                attemptId: `${sessionId}:attempt:1`,
                turnId: `${sessionId}:turn:1`,
                promptText: "early failure before tools",
                afterPersistedTurnCount: 0,
                status: "failed",
                error: "EARLY_FAIL",
                persisted: false,
                syntheticTurn: {
                  id: `${sessionId}:turn:1`,
                  rootTurnId: null,
                  items: [
                    {
                      type: "userMessage",
                      id: `${sessionId}:turn:1:user`,
                      clientId: null,
                      content: [{ type: "text", text: "early failure before tools", text_elements: [] }],
                    },
                  ],
                  itemsView: "full",
                  status: "failed",
                  error: { message: "EARLY_FAIL", codexErrorInfo: null, additionalDetails: null, misalignment: null },
                  startedAt: 1700000000,
                  completedAt: 1700000001,
                  durationMs: 1000,
                },
                createdAt: 1700000000,
              },
              {
                attemptId: `${sessionId}:attempt:2`,
                turnId: `${sessionId}:turn:2`,
                promptText: prompt263.slice(0, 240),
                afterPersistedTurnCount: 0,
                status: "completed",
                error: null,
                persisted: true,
                createdAt: 1700000010,
              },
              {
                attemptId: `${sessionId}:attempt:3`,
                turnId: `${sessionId}:turn:3`,
                promptText: "run overlapped legacy commands",
                afterPersistedTurnCount: 1,
                status: "completed",
                error: null,
                persisted: true,
                createdAt: 1700000020,
              },
            ],
            toolMappings: {
              [`${sessionId}:turn:2`]: [
                {
                  rawToolCallId: "legacy-serial-FIRST",
                  itemId: serialFirstId,
                  itemType: "commandExecution",
                  fingerprint: "cmd:printf fixture-repeat",
                },
                {
                  rawToolCallId: "legacy-serial-SECOND",
                  itemId: serialSecondId,
                  itemType: "commandExecution",
                  fingerprint: "cmd:printf fixture-repeat",
                },
              ],
              // Legacy b36 stored completion order: SECOND finished before FIRST!
              [`${sessionId}:turn:3`]: [
                {
                  rawToolCallId: "legacy-overlap-SECOND",
                  itemId: overlapSecondId,
                  itemType: "commandExecution",
                  fingerprint: "cmd:printf fixture-repeat",
                },
                {
                  rawToolCallId: "legacy-overlap-FIRST",
                  itemId: overlapFirstId,
                  itemType: "commandExecution",
                  fingerprint: "cmd:printf fixture-repeat",
                },
              ],
            },
          },
        },
      }),
    );

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Legacy Serial + Overlap",
          updatedAt: "2026-11-22T01:01:04Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
    });

    const harness = await createHarness(world);
    try {
      const read = await harness.rpc<{
        thread: {
          turns: Array<{
            id: string;
            status: string;
            items: Array<{ type: string; id: string; aggregatedOutput?: string | null }>;
          }>;
        };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      expect(read.thread.turns).toHaveLength(3);
      expect(read.thread.turns.map((t) => t.id)).toEqual([
        `${sessionId}:turn:1`,
        `${sessionId}:turn:2`,
        `${sessionId}:turn:3`,
      ]);

      // Turn 2 (provably serial + rewritten by B10): MUST restore original stable legacy serial IDs!
      const serialCmds = read.thread.turns[1]!.items.filter((i) => i.type === "commandExecution");
      expect(serialCmds).toHaveLength(2);
      expect(serialCmds[0]).toMatchObject({ id: serialFirstId, aggregatedOutput: "SERIAL FIRST RESULT" });
      expect(serialCmds[1]).toMatchObject({ id: serialSecondId, aggregatedOutput: "SERIAL SECOND RESULT" });

      // Turn 3 (overlapped concurrent batch in legacy overlay without outputFingerprint/invocationIndex):
      // MUST NOT misbind SECOND -> FIRST RESULT or FIRST -> SECOND RESULT; MUST keep neutral deterministic IDs!
      const overlapCmds = read.thread.turns[2]!.items.filter((i) => i.type === "commandExecution");
      expect(overlapCmds).toHaveLength(2);
      expect(overlapCmds[0]).toMatchObject({ id: `${sessionId}:turn:3:tool:1`, aggregatedOutput: "OVERLAP FIRST RESULT" });
      expect(overlapCmds[1]).toMatchObject({ id: `${sessionId}:turn:3:tool:2`, aggregatedOutput: "OVERLAP SECOND RESULT" });
      expect(overlapCmds[0]?.id).not.toBe(overlapSecondId);
      expect(overlapCmds[1]?.id).not.toBe(overlapFirstId);
    } finally {
      await harness.close();
    }
  });

  test("C11 round5: list keeps process cache while turn/start, turn/interrupt, and ThreadRuntime pre-reservation recheck bypass 300ms cache (including before first transcript flushes)", async () => {
    const sessionId = "c11-r5-write-recheck";
    const inspectCalls: Array<{ sessionId: string; bypassProcessCache: boolean }> = [];
    let staleCachedBusy = false;
    let freshHolderBusy = false;
    let promptCalls = 0;

    // 1) Verify inspectTranscriptActivity forwards bypassProcessCache -> findExternalHolderPid({ bypassCache }).
    const observedBypassFlags: boolean[] = [];
    const directActivity = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
      bypassProcessCache: true,
      findExternalHolderPid: async (_sid, _own, opts) => {
        observedBypassFlags.push(Boolean(opts?.bypassCache));
        return 77_123;
      },
    });
    expect(observedBypassFlags).toEqual([true]);
    expect(directActivity?.externallyBusy).toBe(true);
    expect(directActivity?.holderPid).toBe(77_123);

    // 2) Full adapter harness: session has NO transcript yet (and no .db on disk yet for early pre-flush window).
    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "C11 Write Recheck",
          updatedAt: "2026-11-22T02:00:00Z",
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
      onPrompt: async ({ emitUpdate }) => {
        promptCalls += 1;
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "SHOULD NOT RUN" } });
        return { stopReason: "end_turn" };
      },
    });

    const backend: AgySessionBackend = {
      async listSummaries() {
        return {
          summaries: [{ sessionId, cwd: workspaceDir, title: "C11 Write Recheck", updatedAt: "2026-11-22T02:00:00Z" }],
          listMeta: { schemaVersion: 1, complete: true, sources: ["cli"] },
        };
      },
      async loadReplay() {
        return [];
      },
      async resolveSessionOrigin() {
        // Deliberately simulate pre-transcript / pre-.db origin lookup returning null for first check,
        // then switching to "cli" after list verification.
        return sessionOriginResult;
      },
      conversationFilePath() {
        return null;
      },
      async inspectExternalActivity(sid, _origin, opts) {
        const bypass = opts?.bypassProcessCache === true;
        inspectCalls.push({ sessionId: sid, bypassProcessCache: bypass });
        const busy = bypass ? freshHolderBusy : staleCachedBusy;
        return {
          path: "",
          size: 0,
          mtimeMs: Date.now(),
          externallyBusy: busy,
          ...(busy ? { holderPid: 88_001 } : {}),
        };
      },
    };
    let sessionOriginResult: "cli" | null = "cli";

    const harness = await createHarness(world, { sessionBackend: backend });
    try {
      // External process starts inside the 300ms cache window: cached snapshot still says idle, fresh check sees holder.
      staleCachedBusy = false;
      freshHolderBusy = true;

      // List path keeps cached behavior (bypassProcessCache === false).
      const listed = await harness.rpc<{ data: Array<{ id: string; canAcceptDirectInput: boolean }> }>("thread/list", {});
      expect(listed.data[0]?.id).toBe(sessionId);
      expect(listed.data[0]?.canAcceptDirectInput).toBe(true);
      expect(inspectCalls[inspectCalls.length - 1]).toEqual({ sessionId, bypassProcessCache: false });

      // Even before .db / transcript exists (resolveSessionOrigin returns null), write paths MUST still bypass cache and reject!
      // First open existing runtime via thread/resume while origin is visible, then clear origin to test pre-flush path.
      await harness.rpc("thread/resume", { threadId: sessionId, cwd: workspaceDir });
      sessionOriginResult = null;

      await expect(
        harness.rpc("turn/start", {
          threadId: sessionId,
          cwd: workspaceDir,
          input: [{ type: "text", text: "blocked by fresh write check", text_elements: [] }],
        }),
      ).rejects.toThrow("currently active");
      expect(inspectCalls[inspectCalls.length - 1]).toEqual({ sessionId, bypassProcessCache: true });

      await expect(harness.rpc("turn/interrupt", { threadId: sessionId })).rejects.toThrow("cannot be interrupted remotely");
      expect(inspectCalls[inspectCalls.length - 1]).toEqual({ sessionId, bypassProcessCache: true });
      expect(promptCalls).toBe(0);

      // 3) Race window between handlers/turns.ts pre-check and ThreadRuntime.startTurn pre-reservation check:
      // First bypass call (handlers/turns.ts) sees idle, then external holder acquires session before reserveTurnAttempt!
      sessionOriginResult = "cli";
      let bypassSeq = 0;
      backend.inspectExternalActivity = async (sid, _origin, opts) => {
        const bypass = opts?.bypassProcessCache === true;
        inspectCalls.push({ sessionId: sid, bypassProcessCache: bypass });
        if (!bypass) {
          return { path: "", size: 0, mtimeMs: Date.now(), externallyBusy: false };
        }
        bypassSeq += 1;
        // 1st bypass call is handlers/turns.ts turnStart -> idle;
        // 2nd bypass call is ThreadRuntime.startTurn right before reserveTurnAttempt -> externally busy!
        const busy = bypassSeq >= 2;
        return {
          path: "",
          size: 0,
          mtimeMs: Date.now(),
          externallyBusy: busy,
          ...(busy ? { holderPid: 88_002 } : {}),
        };
      };

      const notificationsBefore = harness.notifications.length;
      await expect(
        harness.rpc("turn/start", {
          threadId: sessionId,
          cwd: workspaceDir,
          input: [{ type: "text", text: "blocked before reserveTurnAttempt", text_elements: [] }],
        }),
      ).rejects.toThrow("currently active");

      expect(bypassSeq).toBe(2);
      expect(promptCalls).toBe(0);
      // MUST NOT publish turn/started or write a reserved attempt into overlay.json!
      const newNotifications = harness.notifications.slice(notificationsBefore);
      expect(newNotifications.some((n) => n.method === "turn/started")).toBe(false);
      const overlayRaw = await readFile(path.join(stateDir, "overlay.json"), "utf8").catch(() => "");
      if (overlayRaw) {
        const parsed = JSON.parse(overlayRaw) as { sessions?: Record<string, { turnAttempts?: unknown[] }> };
        expect(parsed.sessions?.[sessionId]?.turnAttempts ?? []).toHaveLength(0);
      }
    } finally {
      await harness.close();
    }
  });

  test("B23 round5: percent-encoded native cwd (Chinese, spaces, &, quotes, file:// URI) and literal % directories reopen as existing writable sessions without breaking traversal guards", async () => {
    // 1) Create real directories: Chinese/space/&/quote, literal %20, and literal 100% done.
    const specialName = "边界 空格 & '引号'";
    const specialDir = path.join(tempRoot, specialName);
    const literalPercent20Dir = path.join(tempRoot, "foo%20bar");
    const literalPercentSpaceDir = path.join(tempRoot, "100% done");
    const removedChineseDir = path.join(tempRoot, "已删除 目录");
    await mkdir(specialDir, { recursive: true });
    await mkdir(literalPercent20Dir, { recursive: true });
    await mkdir(literalPercentSpaceDir, { recursive: true });

    const encodePathSegments = (absPath: string) =>
      absPath
        .split("/")
        .map((seg) => encodeURIComponent(seg))
        .join("/");

    const encodedSpecialCwd = encodePathSegments(specialDir);
    const fileUrlSpecialCwd = `file://${encodedSpecialCwd}`;
    const doubleEncodedLiteralPercent20 = encodePathSegments(literalPercent20Dir); // .../foo%2520bar
    const encodedLiteralPercentSpace = encodePathSegments(literalPercentSpaceDir); // .../100%25%20done
    const encodedRemovedChinese = encodePathSegments(removedChineseDir);

    // Direct unit checks on path normalization & security guards:
    expect(await normalizeNativeCwd(encodedSpecialCwd)).toBe(specialDir);
    expect(await normalizeNativeCwd(fileUrlSpecialCwd)).toBe(specialDir);
    // Literal foo%20bar returned unencoded MUST stay foo%20bar (never decoded to "foo bar")!
    expect(await normalizeNativeCwd(literalPercent20Dir)).toBe(literalPercent20Dir);
    // Literal foo%20bar returned percent-encoded as foo%2520bar decodes ONCE to foo%20bar!
    expect(await normalizeNativeCwd(doubleEncodedLiteralPercent20)).toBe(literalPercent20Dir);
    expect(await normalizeNativeCwd(encodedLiteralPercentSpace)).toBe(literalPercentSpaceDir);
    // Security guard: encoded traversal (%2E%2E) or encoded slash (%2F) MUST be rejected!
    expect(decodePercentEncodedPath(`${tempRoot}/%2E%2E/secret`)).toBeUndefined();
    expect(decodePercentEncodedPath(`${tempRoot}/a%2Fb`)).toBeUndefined();
    expect(decodePercentEncodedPath(`${tempRoot}/a%00b`)).toBeUndefined();

    // 2) Full cold-reopen E2E across global thread/list, scoped thread/list, thread/read, and turn/start!
    const sessions = [
      { id: "b23-r5-special", rawCwd: encodedSpecialCwd, expectedCwd: specialDir, expectMissing: false },
      { id: "b23-r5-fileurl", rawCwd: fileUrlSpecialCwd, expectedCwd: specialDir, expectMissing: false },
      { id: "b23-r5-lit-raw", rawCwd: literalPercent20Dir, expectedCwd: literalPercent20Dir, expectMissing: false },
      { id: "b23-r5-lit-enc", rawCwd: doubleEncodedLiteralPercent20, expectedCwd: literalPercent20Dir, expectMissing: false },
      { id: "b23-r5-lit-100", rawCwd: encodedLiteralPercentSpace, expectedCwd: literalPercentSpaceDir, expectMissing: false },
      { id: "b23-r5-removed", rawCwd: encodedRemovedChinese, expectedCwd: removedChineseDir, expectMissing: true },
    ];
    for (const s of sessions) {
      await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${s.id}.db`), "sqlite");
    }

    const world = new FakeAgyWorld({
      sessions: sessions.map((s, idx) => ({
        sessionId: s.id,
        cwd: s.rawCwd,
        title: `B23 ${s.id}`,
        updatedAt: `2026-11-22T03:0${idx}:00Z`,
        modeId: "default",
        model: "gemini-4-carbon",
        thoughtLevel: "medium",
        replayUpdates: [
          { sessionUpdate: "user_message_chunk", content: { type: "text", text: "pwd" } },
          { sessionUpdate: "agent_message_chunk", content: { type: "text", text: s.expectedCwd } },
        ],
      })),
      onPrompt: async ({ emitUpdate }) => {
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "CONTINUED OK" } });
        return { stopReason: "end_turn" };
      },
    });

    const harness = await createHarness(world);
    try {
      const globalList = await harness.rpc<{
        data: Array<{ id: string; cwd: string; cwdMissing?: boolean; canAcceptDirectInput: boolean }>;
      }>("thread/list", { limit: 20 });

      for (const s of sessions) {
        const entry = globalList.data.find((d) => d.id === s.id);
        expect(entry, `global list entry for ${s.id}`).toMatchObject({
          id: s.id,
          cwd: s.expectedCwd,
          cwdMissing: s.expectMissing,
          canAcceptDirectInput: !s.expectMissing,
        });
      }

      // Scoped thread/list by real unencoded Chinese/space/&/quote cwd finds BOTH percent-encoded & file:// sessions!
      const scopedSpecial = await harness.rpc<{ data: Array<{ id: string; cwd: string; cwdMissing?: boolean }> }>(
        "thread/list",
        { cwd: specialDir, limit: 20 },
      );
      expect(scopedSpecial.data.map((d) => d.id).sort()).toEqual(["b23-r5-fileurl", "b23-r5-special"]);
      expect(scopedSpecial.data.every((d) => d.cwd === specialDir && d.cwdMissing === false)).toBe(true);

      // Scoped thread/list by literal foo%20bar finds BOTH raw and %2520-encoded sessions!
      const scopedLiteral = await harness.rpc<{ data: Array<{ id: string; cwd: string; cwdMissing?: boolean }> }>(
        "thread/list",
        { cwd: literalPercent20Dir, limit: 20 },
      );
      expect(scopedLiteral.data.map((d) => d.id).sort()).toEqual(["b23-r5-lit-enc", "b23-r5-lit-raw"]);

      // Cold thread/read and real takeover turn/start on Chinese/space/&/quote and literal %20 directories succeed!
      for (const targetId of ["b23-r5-special", "b23-r5-lit-enc"]) {
        const expected = sessions.find((s) => s.id === targetId)!;
        const readRes = await harness.rpc<{
          thread: { id: string; cwd: string; cwdMissing?: boolean; canAcceptDirectInput: boolean };
        }>("thread/read", { threadId: targetId, includeTurns: true });
        expect(readRes.thread).toMatchObject({
          id: targetId,
          cwd: expected.expectedCwd,
          cwdMissing: false,
          canAcceptDirectInput: true,
        });

        await harness.rpc("turn/start", {
          threadId: targetId,
          cwd: expected.expectedCwd,
          input: [{ type: "text", text: "continue after cold reopen", text_elements: [] }],
        });
      }
      await waitIdle(harness.notifications, 2);

      // Truly removed Chinese directory still stays read-only with cwdMissing:true and rejects writes (C14/C15 preserved).
      await expect(
        harness.rpc("turn/start", {
          threadId: "b23-r5-removed",
          cwd: removedChineseDir,
          input: [{ type: "text", text: "must stay read-only", text_elements: [] }],
        }),
      ).rejects.toThrow("no longer exists");
    } finally {
      await harness.close();
    }
  });
});

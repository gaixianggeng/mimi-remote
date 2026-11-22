import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { serveConnection } from "@mimi/appserver-kit/server/connection.ts";
import { SessionRegistry } from "@mimi/appserver-kit/session/registry.ts";
import { createApp } from "../src/app.ts";
import type { SpawnAgyTransport } from "../src/agy/binary.ts";
import type { OtherListDiagnostic } from "../src/agy/catalog.ts";
import { FakeAgyWorld } from "./support/fake-agy.ts";

describe("mimi-agy-adapter round4 fixes", () => {
  let tempRoot = "";
  let fakeHome = "";
  let workspaceDir = "";
  let stateDir = "";

  beforeEach(async () => {
    tempRoot = await mkdtemp(path.join(os.tmpdir(), "mimi-agy-round4-"));
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
      onOtherListDiagnostic?: (diag: OtherListDiagnostic) => void;
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
      ...(extra.onOtherListDiagnostic ? { onOtherListDiagnostic: extra.onOtherListDiagnostic } : {}),
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
      rpc,
      notifications,
      async close() {
        clientIn.end();
        await served.catch(() => {});
        await app.close();
      },
    };
  }

  test("B10 round4: legacy interrupted attempt marked persisted:false deduplicates against late-flushed native transcript turn", async () => {
    const sessionId = "b10-r4-legacy-interrupted";
    await mkdir(stateDir, { recursive: true });
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    // Seed native transcript where the interrupted user request actually landed on disk (no assistant reply).
    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const transcriptPath = path.join(logsDir, "transcript_full.jsonl");
    await writeFile(
      transcriptPath,
      [
        JSON.stringify({
          step_index: 2,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: "<USER_REQUEST>\nrealMacBefore\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 3,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:01Z",
          content: "ROUND THREE LEGACY MAC BEFORE",
        }),
        JSON.stringify({
          step_index: 5,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:01:00Z",
          content: "<USER_REQUEST>\nv1Interrupted request\n</USER_REQUEST>",
        }),
      ].join("\n") + "\n",
    );
    const oldTime = new Date(Date.now() - 5 * 60_000);
    await utimes(transcriptPath, oldTime, oldTime);

    // Seed legacy b36 overlay recording attempt as persisted:false with syntheticTurn.
    await writeFile(
      path.join(stateDir, "overlay.json"),
      JSON.stringify({
        version: 1,
        sessions: {
          [sessionId]: {
            cwd: workspaceDir,
            nextTurnOrdinal: 3,
            nextAttemptSeq: 1,
            turnAttempts: [
              {
                attemptId: `${sessionId}:attempt:1`,
                turnId: `${sessionId}:turn:3`,
                promptText: "v1Interrupted request",
                afterPersistedTurnCount: 1,
                status: "interrupted",
                error: null,
                persisted: false,
                syntheticTurn: {
                  id: `${sessionId}:turn:3`,
                  rootTurnId: null,
                  items: [
                    {
                      type: "userMessage",
                      id: `${sessionId}:turn:3:user`,
                      clientId: null,
                      content: [{ type: "text", text: "v1Interrupted request", text_elements: [] }],
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

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Legacy Interrupted",
          updatedAt: "2026-11-22T01:01:00Z",
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
        thread: { turns: Array<{ id: string; status: string; error: unknown; items: Array<{ type: string }> }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      // Must contain exactly 2 turns: realMacBefore (completed) and ONE v1Interrupted (interrupted), NEVER duplicated!
      expect(read.thread.turns).toHaveLength(2);
      expect(read.thread.turns[0]?.status).toBe("completed");
      expect(read.thread.turns[1]?.id).toBe(`${sessionId}:turn:3`);
      expect(read.thread.turns[1]?.status).toBe("interrupted");
      expect(read.thread.turns[1]?.error).toBeNull();
    } finally {
      await harness.close();
    }
  });

  test("B10 round4: related substring native prompt does NOT merge into prior unpersisted failed attempt", async () => {
    const sessionId = "b10-r4-related-prompt";
    await mkdir(stateDir, { recursive: true });
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    await writeFile(
      path.join(logsDir, "transcript_full.jsonl"),
      [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: "<USER_REQUEST>\nEDGE-ECHO unrelated baseline\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:01Z",
          content: "UNRELATED BASELINE FINISHED",
        }),
        JSON.stringify({
          step_index: 2,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:02:00Z",
          content: "<USER_REQUEST>\nInspect prior EDGE-ERROR-BEFORE-REPLAY and report success as a separate task\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 3,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:02:05Z",
          content: "NATIVE SEPARATE TASK FINISHED",
        }),
      ].join("\n") + "\n",
    );

    // Overlay has an early-failed attempt (persisted absent/undefined) whose prompt is a substring of the later native prompt.
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
                promptText: "EDGE-ERROR-BEFORE-REPLAY",
                afterPersistedTurnCount: 1,
                status: "failed",
                error: "Error: EARLY_FAILURE",
                syntheticTurn: {
                  id: `${sessionId}:turn:2`,
                  rootTurnId: null,
                  items: [
                    {
                      type: "userMessage",
                      id: `${sessionId}:turn:2:user`,
                      clientId: null,
                      content: [{ type: "text", text: "EDGE-ERROR-BEFORE-REPLAY", text_elements: [] }],
                    },
                  ],
                  itemsView: "full",
                  status: "failed",
                  error: {
                    message: "Error: EARLY_FAILURE",
                    codexErrorInfo: null,
                    additionalDetails: null,
                    misalignment: null,
                  },
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

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "Related Prompt",
          updatedAt: "2026-11-22T01:02:05Z",
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
        thread: { turns: Array<{ id: string; status: string; error: { message: string } | null }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      // Must preserve ALL 3 distinct turns: baseline completed, early failure failed, separate native task completed!
      expect(read.thread.turns).toHaveLength(3);
      expect(read.thread.turns[0]).toMatchObject({ id: `${sessionId}:turn:1`, status: "completed", error: null });
      expect(read.thread.turns[1]).toMatchObject({
        id: `${sessionId}:turn:2`,
        status: "failed",
        error: expect.objectContaining({ message: "Error: EARLY_FAILURE" }),
      });
      expect(read.thread.turns[2]).toMatchObject({ id: `${sessionId}:turn:3`, status: "completed", error: null });
    } finally {
      await harness.close();
    }
  });

  test("B15 round4: legacy overlay tool mappings without invocationIndex/outputFingerprint preserve original tool IDs on cold read", async () => {
    const sessionId = "b15-r4-legacy-serial";
    await mkdir(stateDir, { recursive: true });
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "sqlite");

    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    await writeFile(
      path.join(logsDir, "transcript_full.jsonl"),
      [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: "<USER_REQUEST>\nrun duplicate serial commands\n</USER_REQUEST>",
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
          content: "FIXTURE FIRST RESULT",
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
          content: "FIXTURE SECOND RESULT",
        }),
        JSON.stringify({
          step_index: 5,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:05Z",
          content: "Done.",
        }),
      ].join("\n") + "\n",
    );

    // Seed round2 legacy overlay toolMappings (no invocationIndex, no outputFingerprint, no overlappedConcurrent).
    const firstId = `${sessionId}:turn:1:tool:legacy-serial-FIRST`;
    const secondId = `${sessionId}:turn:1:tool:legacy-serial-SECOND`;
    await writeFile(
      path.join(stateDir, "overlay.json"),
      JSON.stringify({
        version: 1,
        sessions: {
          [sessionId]: {
            cwd: workspaceDir,
            toolMappings: {
              [`${sessionId}:turn:1`]: [
                {
                  rawToolCallId: "legacy-serial-FIRST",
                  itemId: firstId,
                  itemType: "commandExecution",
                  fingerprint: "cmd:printf fixture-repeat",
                },
                {
                  rawToolCallId: "legacy-serial-SECOND",
                  itemId: secondId,
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
          title: "Legacy Serial Tools",
          updatedAt: "2026-11-22T01:00:05Z",
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
        thread: { turns: Array<{ items: Array<{ type: string; id: string; aggregatedOutput?: string }> }> };
      }>("thread/read", { threadId: sessionId, includeTurns: true });
      const cmds = read.thread.turns[0]?.items.filter((item) => item.type === "commandExecution") ?? [];
      expect(cmds).toHaveLength(2);
      expect(cmds[0]?.id).toBe(firstId);
      expect(cmds[0]?.aggregatedOutput).toContain("FIXTURE FIRST RESULT");
      expect(cmds[1]?.id).toBe(secondId);
      expect(cmds[1]?.aggregatedOutput).toContain("FIXTURE SECOND RESULT");
    } finally {
      await harness.close();
    }
  });
});

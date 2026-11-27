import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { serveConnection } from "@mimi/appserver-kit/server/connection.ts";
import { SessionRegistry } from "@mimi/appserver-kit/session/registry.ts";
import { inspectTranscriptActivity, type OwnTurnTranscriptWatermark } from "../src/agy/transcript.ts";
import { createApp } from "../src/app.ts";
import { FakeAgyWorld } from "./support/fake-agy.ts";

describe("gh-1175: own-turn settlement watermark prevents false desktop-running state after interrupt/failure", () => {
  let tempRoot = "";
  let fakeHome = "";
  let workspaceDir = "";
  let stateDir = "";

  beforeEach(async () => {
    tempRoot = await mkdtemp(path.join(os.tmpdir(), "mimi-agy-gh1175-"));
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

  async function writeTranscript(sessionId: string, steps: readonly Record<string, unknown>[]): Promise<string> {
    const logsDir = path.join(fakeHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
    await mkdir(logsDir, { recursive: true });
    const filePath = path.join(logsDir, "transcript_full.jsonl");
    await writeFile(filePath, `${steps.map((s) => JSON.stringify(s)).join("\n")}\n`, "utf8");
    return filePath;
  }

  async function createHarness(world: FakeAgyWorld, options?: { externalWritePollMs?: number }) {
    const app = createApp({
      stateDir,
      log: () => {},
      agyExecutable: () => "/usr/local/bin/fake-agy",
      probeAgy: async () => ({ version: "1.5.14" }),
      spawnTransport: world.spawnTransport,
      env: () => ({ HOME: fakeHome }),
      ...(options?.externalWritePollMs !== undefined ? { externalWritePollMs: options.externalWritePollMs } : {}),
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
    for (let i = 0; i < 150; i += 1) {
      const completed = notifications.filter((n) => n.method === "turn/completed").length;
      const idle = notifications.filter(
        (n) => n.method === "thread/status/changed" && (n.params as { status?: { type?: string } })?.status?.type === "idle",
      ).length;
      if (completed >= count && idle >= count) return;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error(`timed out waiting for ${count} completed+idle notifications`);
  }

  test("unit: inspectTranscriptActivity suppresses unfinished tail steps matching own settled watermark, including RUNNING tools", async () => {
    const cases: Array<{ label: string; steps: Record<string, unknown>[] }> = [
      {
        label: "USER_INPUT only",
        steps: [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nstop right away\n</USER_REQUEST>" },
        ],
      },
      {
        label: "PLANNER_RESPONSE with tool_calls",
        steps: [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ncheck repo\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
        ],
      },
      {
        label: "GENERIC DONE",
        steps: [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ncheck repo\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
          { step_index: 2, type: "GENERIC", status: "DONE", content: "command output" },
        ],
      },
      {
        label: "SYSTEM_MESSAGE DONE",
        steps: [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ncheck repo\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
          { step_index: 2, type: "GENERIC", status: "DONE", content: "command output" },
          { step_index: 3, type: "SYSTEM_MESSAGE", status: "DONE", content: "reminder" },
        ],
      },
      {
        label: "GENERIC RUNNING (10-minute window)",
        steps: [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nrun long cmd\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
          { step_index: 2, type: "GENERIC", status: "RUNNING", content: "running..." },
        ],
      },
    ];

    for (let i = 0; i < cases.length; i += 1) {
      const tc = cases[i]!;
      const sessionId = `unit-wm-${i}`;
      const filePath = await writeTranscript(sessionId, tc.steps);
      const info = await stat(filePath);
      const lastStep = tc.steps[tc.steps.length - 1]!;

      // Without watermark: heuristic treats unfinished recent tail as externallyBusy.
      const withoutWm = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
        findExternalHolderPid: async () => null,
      });
      expect(withoutWm?.externallyBusy, `${tc.label}: without watermark`).toBe(true);

      // With matching own watermark: suppressed -> externallyBusy === false.
      const watermark: OwnTurnTranscriptWatermark = {
        status: "interrupted",
        completedAtMs: info.mtimeMs + 100,
        size: info.size,
        mtimeMs: info.mtimeMs,
        lastUserStepIndex: 0,
        lastStepIndex: Number(lastStep.step_index),
        persistedAtSettlement: true,
      };
      const withWm = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
        ownSettledWatermark: watermark,
        findExternalHolderPid: async () => null,
      });
      expect(withWm?.externallyBusy, `${tc.label}: with watermark`).toBe(false);

      // Live external PID ALWAYS overrides watermark.
      const withPid = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
        ownSettledWatermark: watermark,
        findExternalHolderPid: async () => 77889,
      });
      expect(withPid?.externallyBusy, `${tc.label}: with live holder PID`).toBe(true);
      expect(withPid?.holderPid).toBe(77889);
    }
  });

  test("unit: post-cancel trailing tool flush stays suppressed, while new external USER_INPUT or PLANNER_RESPONSE immediately flips busy", async () => {
    const sessionId = "unit-wm-trailing-vs-external";
    const baseSteps = [
      { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nhello\n</USER_REQUEST>" },
      { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
      { step_index: 2, type: "GENERIC", status: "RUNNING", content: "running" },
    ];
    const filePath = await writeTranscript(sessionId, baseSteps);
    const baseStat = await stat(filePath);
    const completedAtMs = baseStat.mtimeMs + 50;
    const watermark: OwnTurnTranscriptWatermark = {
      status: "interrupted",
      completedAtMs,
      size: baseStat.size,
      mtimeMs: baseStat.mtimeMs,
      lastUserStepIndex: 0,
      lastStepIndex: 2,
      persistedAtSettlement: true,
      expectedPromptText: "hello",
    };

    // 1) 200ms after cancel, own agy acp flushes trailing GENERIC (DONE) under same USER_INPUT.
    const flushedSteps = [
      ...baseSteps,
      { step_index: 3, type: "GENERIC", status: "DONE", content: "aborted result" },
    ];
    await writeTranscript(sessionId, flushedSteps);
    const flushAtSec = (completedAtMs + 200) / 1000;
    await utimes(filePath, flushAtSec, flushAtSec);

    // Even 30s later (well past the 5s flush grace), mtimeMs is still within 5s of completedAtMs -> remains idle.
    const afterFlush = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
      nowMs: completedAtMs + 30_000,
      ownSettledWatermark: watermark,
      findExternalHolderPid: async () => null,
    });
    expect(afterFlush?.externallyBusy).toBe(false);

    // 2) If Desktop appends a new PLANNER_RESPONSE even 300ms after cancel -> immediately busy!
    await writeTranscript(sessionId, [
      ...flushedSteps,
      { step_index: 4, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "read_file" }] },
    ]);
    const plannerAtSec = (completedAtMs + 300) / 1000;
    await utimes(filePath, plannerAtSec, plannerAtSec);
    const afterExternalPlanner = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
      nowMs: completedAtMs + 500,
      ownSettledWatermark: watermark,
      findExternalHolderPid: async () => null,
    });
    expect(afterExternalPlanner?.externallyBusy).toBe(true);

    // 3) If Desktop appends a new USER_INPUT even 100ms after cancel -> immediately busy!
    await writeTranscript(sessionId, [
      ...baseSteps,
      { step_index: 3, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ndesktop follow-up\n</USER_REQUEST>" },
    ]);
    const userAtSec = (completedAtMs + 100) / 1000;
    await utimes(filePath, userAtSec, userAtSec);
    const afterExternalUser = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
      nowMs: completedAtMs + 200,
      ownSettledWatermark: watermark,
      findExternalHolderPid: async () => null,
    });
    expect(afterExternalUser?.externallyBusy).toBe(true);

    // 4) Delayed write > 5s after cancel -> immediately busy!
    await writeTranscript(sessionId, flushedSteps);
    const lateAtSec = (completedAtMs + 6_000) / 1000;
    await utimes(filePath, lateAtSec, lateAtSec);
    const afterLateWrite = await inspectTranscriptActivity(sessionId, "cli", { HOME: fakeHome }, {
      nowMs: completedAtMs + 6_500,
      ownSettledWatermark: watermark,
      findExternalHolderPid: async () => null,
    });
    expect(afterLateWrite?.externallyBusy).toBe(true);
  });

  test("e2e: interrupting a running agy turn keeps thread writable across read/resume/list, follow-up turn/start, and adapter restart", async () => {
    const sessionId = "gh1175-interrupt-e2e";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "db");
    await writeTranscript(sessionId, [
      { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ninitial\n</USER_REQUEST>" },
      { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "initial ok" },
    ]);

    let promptCount = 0;
    let resolvePromptStarted: (() => void) | undefined;
    const promptStarted = new Promise<void>((resolve) => {
      resolvePromptStarted = resolve;
    });

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "GH1175 Interrupt Session",
          updatedAt: new Date().toISOString(),
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
      onPrompt: async ({ emitUpdate, signal }) => {
        promptCount += 1;
        if (promptCount === 1) {
          // Simulate real agy acp writing USER_INPUT + tool_calls + GENERIC (DONE) + SYSTEM_MESSAGE without any cancel step.
          await writeTranscript(sessionId, [
            { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ninitial\n</USER_REQUEST>" },
            { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "initial ok" },
            { step_index: 2, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nrun diagnostic\n</USER_REQUEST>" },
            { step_index: 3, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
            { step_index: 4, type: "GENERIC", status: "DONE", content: "partial output" },
            { step_index: 5, type: "SYSTEM_MESSAGE", status: "DONE", content: "reminder" },
          ]);
          emitUpdate({ sessionUpdate: "tool_call", toolCallId: "tc-1", title: "run_command", kind: "execute", status: "in_progress" });
          resolvePromptStarted?.();
          await new Promise<void>((resolve) => {
            if (signal.aborted) return resolve();
            signal.addEventListener("abort", () => resolve(), { once: true });
          });
          // Real agy acp returns cancelled WITHOUT appending CANCELLED to transcript_full.jsonl.
          return { stopReason: "cancelled" };
        }
        await writeTranscript(sessionId, [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ninitial\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "initial ok" },
          { step_index: 2, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nrun diagnostic\n</USER_REQUEST>" },
          { step_index: 3, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
          { step_index: 4, type: "GENERIC", status: "DONE", content: "partial output" },
          { step_index: 5, type: "SYSTEM_MESSAGE", status: "DONE", content: "reminder" },
          { step_index: 6, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nfollow up\n</USER_REQUEST>" },
          { step_index: 7, type: "PLANNER_RESPONSE", status: "DONE", content: "follow up ok" },
        ]);
        emitUpdate({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "follow up ok" } });
        return { stopReason: "end_turn" };
      },
    });

    const harness = await createHarness(world);
    try {
      const started = await harness.rpc<{ turn: { id: string } }>("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "run diagnostic" }],
      });
      await promptStarted;

      await harness.rpc("turn/interrupt", { threadId: sessionId, turnId: started.turn.id });
      await waitIdle(harness.notifications, 1);

      // Immediately after interrupt: thread/read, thread/resume, thread/list MUST all report writable (NOT desktop-running).
      const readRes = await harness.rpc<{ thread: { canAcceptDirectInput: boolean; claudeOwner?: unknown; status: { type: string } } }>(
        "thread/read",
        { threadId: sessionId, includeTurns: true },
      );
      expect(readRes.thread.canAcceptDirectInput).toBe(true);
      expect(readRes.thread.claudeOwner).toBeUndefined();
      expect(readRes.thread.status.type).toBe("idle");

      const resumeRes = await harness.rpc<{ thread: { canAcceptDirectInput: boolean; claudeOwner?: unknown; status: { type: string } } }>(
        "thread/resume",
        { threadId: sessionId, cwd: workspaceDir },
      );
      expect(resumeRes.thread.canAcceptDirectInput).toBe(true);
      expect(resumeRes.thread.claudeOwner).toBeUndefined();
      expect(resumeRes.thread.status.type).toBe("idle");

      const listRes = await harness.rpc<{ data: Array<{ id: string; canAcceptDirectInput: boolean; claudeOwner?: unknown }> }>(
        "thread/list",
        { cwd: workspaceDir },
      );
      const listed = listRes.data.find((entry) => entry.id === sessionId);
      expect(listed?.canAcceptDirectInput).toBe(true);
      expect(listed?.claudeOwner).toBeUndefined();

      // Simulate adapter restart before follow-up: persisted watermark in overlay.json still prevents false busy.
      await harness.close();
      const restarted = await createHarness(world);
      try {
        const readAfterRestart = await restarted.rpc<{ thread: { canAcceptDirectInput: boolean; claudeOwner?: unknown } }>(
          "thread/read",
          { threadId: sessionId, includeTurns: true },
        );
        expect(readAfterRestart.thread.canAcceptDirectInput).toBe(true);
        expect(readAfterRestart.thread.claudeOwner).toBeUndefined();

        // Follow-up turn/start succeeds immediately.
        await restarted.rpc("turn/start", {
          threadId: sessionId,
          cwd: workspaceDir,
          input: [{ type: "text", text: "follow up" }],
        });
        await waitIdle(restarted.notifications, 1);

        // If external Desktop subsequently appends a new USER_INPUT, read/list/start immediately detect external busy.
        await writeTranscript(sessionId, [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ninitial\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "initial ok" },
          { step_index: 6, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nfollow up\n</USER_REQUEST>" },
          { step_index: 7, type: "PLANNER_RESPONSE", status: "DONE", content: "follow up ok" },
          { step_index: 8, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ndesktop took over\n</USER_REQUEST>" },
        ]);

        const readExternal = await restarted.rpc<{ thread: { canAcceptDirectInput: boolean; claudeOwner?: { status?: string } } }>(
          "thread/read",
          { threadId: sessionId },
        );
        expect(readExternal.thread.canAcceptDirectInput).toBe(false);
        expect(readExternal.thread.claudeOwner?.status).toBe("busy");

        await expect(
          restarted.rpc("turn/start", {
            threadId: sessionId,
            cwd: workspaceDir,
            input: [{ type: "text", text: "blocked while desktop busy" }],
          }),
        ).rejects.toThrow("Another Antigravity process");
      } finally {
        await restarted.close();
      }
    } finally {
      await harness.close().catch(() => {});
    }
  });

  test("e2e: failed own agy turn leaving unfinished transcript tail does not falsely report desktop-running", async () => {
    const sessionId = "gh1175-failed-e2e";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "db");
    await writeTranscript(sessionId, [
      { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nbase\n</USER_REQUEST>" },
      { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "base ok" },
    ]);

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "GH1175 Failed Session",
          updatedAt: new Date().toISOString(),
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
      onPrompt: async () => {
        await writeTranscript(sessionId, [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nbase\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "base ok" },
          { step_index: 2, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\ntrigger failure\n</USER_REQUEST>" },
          { step_index: 3, type: "PLANNER_RESPONSE", status: "DONE", tool_calls: [{ name: "run_command" }] },
          { step_index: 4, type: "GENERIC", status: "RUNNING", content: "still running when upstream failed" },
        ]);
        throw new Error("upstream model transport failed");
      },
    });

    const harness = await createHarness(world);
    try {
      await harness.rpc("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "trigger failure" }],
      });
      await waitIdle(harness.notifications, 1);

      const readRes = await harness.rpc<{ thread: { canAcceptDirectInput: boolean; claudeOwner?: unknown } }>(
        "thread/read",
        { threadId: sessionId, includeTurns: true },
      );
      expect(readRes.thread.canAcceptDirectInput).toBe(true);
      expect(readRes.thread.claudeOwner).toBeUndefined();
    } finally {
      await harness.close();
    }
  });

  test("e2e: external write conflict during active turn clears watermark and still reports desktop-running", async () => {
    const sessionId = "gh1175-conflict-e2e";
    await writeFile(path.join(fakeHome, ".gemini", "antigravity-cli", "conversations", `${sessionId}.db`), "db");
    await writeTranscript(sessionId, [
      { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nbase\n</USER_REQUEST>" },
      { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "base ok" },
    ]);

    const world = new FakeAgyWorld({
      sessions: [
        {
          sessionId,
          cwd: workspaceDir,
          title: "GH1175 Conflict Session",
          updatedAt: new Date().toISOString(),
          modeId: "default",
          model: "gemini-4-carbon",
          thoughtLevel: "medium",
          replayUpdates: [],
        },
      ],
      onPrompt: async ({ signal }) => {
        // Simulate external Desktop writing a different USER_INPUT while phone turn is active.
        await writeTranscript(sessionId, [
          { step_index: 0, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nbase\n</USER_REQUEST>" },
          { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", content: "base ok" },
          { step_index: 2, type: "USER_INPUT", status: "DONE", content: "<USER_REQUEST>\nexternal desktop hijack\n</USER_REQUEST>" },
        ]);
        await new Promise<void>((resolve) => {
          if (signal.aborted) return resolve();
          signal.addEventListener("abort", () => resolve(), { once: true });
        });
        return { stopReason: "cancelled" };
      },
    });

    const harness = await createHarness(world, { externalWritePollMs: 25 });
    try {
      await harness.rpc("turn/start", {
        threadId: sessionId,
        cwd: workspaceDir,
        input: [{ type: "text", text: "phone message" }],
      });

      // Wait until conflict detection cancels the turn and emits desktop-owned status.
      for (let i = 0; i < 150; i += 1) {
        const ownedNotice = harness.notifications.find(
          (n) =>
            n.method === "thread/status/changed"
            && (n.params as { canAcceptDirectInput?: boolean; claudeOwner?: { status?: string } })?.canAcceptDirectInput === false
            && (n.params as { claudeOwner?: { status?: string } })?.claudeOwner?.status === "busy",
        );
        if (ownedNotice) break;
        await new Promise((r) => setTimeout(r, 15));
      }

      const readRes = await harness.rpc<{ thread: { canAcceptDirectInput: boolean; claudeOwner?: { status?: string } } }>(
        "thread/read",
        { threadId: sessionId },
      );
      expect(readRes.thread.canAcceptDirectInput).toBe(false);
      expect(readRes.thread.claudeOwner?.status).toBe("busy");
    } finally {
      await harness.close();
    }
  });
});

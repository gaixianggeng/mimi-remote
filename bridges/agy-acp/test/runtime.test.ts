import { expect, test } from "bun:test";
import type { AcpClient } from "../src/acp/client.ts";
import type { AcpRequestPermissionParams, AcpRequestPermissionResult } from "../src/acp/types.ts";
import type { TranscriptTurnSnapshot } from "../src/agy/transcript.ts";
import { serverApprovalFor } from "../src/runtime/approvals.ts";
import { LiveTurn } from "../src/runtime/liveTurn.ts";
import {
  EXTERNAL_WRITE_CONFLICT_MESSAGE,
  EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE,
  ThreadRuntime,
  type RuntimeHost,
} from "../src/runtime/threadRuntime.ts";

test("declining an ACP request with only an allow option cancels it", () => {
  const approval = serverApprovalFor({
    sessionId: "session",
    toolCall: { toolCallId: "tool", kind: "execute" },
    options: [{ optionId: "allow", name: "Allow once", kind: "allow_once" }],
  }, { threadId: "session", turnId: "turn", cwd: "/workspace" });

  expect(approval.toAcpResult({ decision: "decline" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "accept" })).toEqual({
    outcome: { outcome: "selected", optionId: "allow" },
  });
  expect(approval.params.availableDecisions).toEqual(["accept", "decline"]);
  expect(approval.toAcpResult({ decision: "acceptForSession" })).toEqual({ outcome: { outcome: "cancelled" } });
});

test("B01/B05: ACP request with persistent allow_always omits accept & acceptForSession and rejects unadvertised decisions", () => {
  const approval = serverApprovalFor({
    sessionId: "session",
    toolCall: { toolCallId: "tool-always-only", kind: "execute", title: "Run command" },
    options: [
      { optionId: "fixture-allow-always", name: "Remember for every conversation", kind: "allow_always" },
      { optionId: "fixture-reject", name: "Reject", kind: "reject_once" },
    ],
  }, { threadId: "session", turnId: "turn", cwd: "/workspace" });

  expect(approval.params.availableDecisions).toEqual(["acceptAlways", "decline"]);
  expect(approval.params.alwaysAllowLabel).toBe("Remember for every conversation");
  expect(approval.toAcpResult({ decision: "accept" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "acceptForSession" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "acceptWithPermissionUpdate" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "acceptWithExecpolicyAmendment" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "acceptAlways" })).toEqual({
    outcome: { outcome: "selected", optionId: "fixture-allow-always" },
  });
  expect(approval.toAcpResult({ decision: "decline" })).toEqual({
    outcome: { outcome: "selected", optionId: "fixture-reject" },
  });
});

test("B05: session-scoped allow_always maps strictly to acceptForSession for command and file approvals", () => {
  const commandApproval = serverApprovalFor({
    sessionId: "session-1",
    toolCall: { toolCallId: "cmd-1", kind: "execute", title: "Run pwd", rawInput: { command: "pwd" } },
    options: [
      { optionId: "cmd-once", name: "Allow once", kind: "allow_once" },
      { optionId: "cmd-session", name: "Allow for this session", kind: "allow_always" },
      { optionId: "cmd-reject", name: "Reject", kind: "reject_once" },
    ],
  }, { threadId: "session-1", turnId: "turn-1", cwd: "/workspace" });

  expect(commandApproval.method).toBe("item/commandExecution/requestApproval");
  expect(commandApproval.params.availableDecisions).toEqual(["accept", "acceptForSession", "decline"]);
  expect(commandApproval.params.alwaysAllowLabel).toBeUndefined();
  expect(commandApproval.toAcpResult({ decision: "acceptForSession" })).toEqual({
    outcome: { outcome: "selected", optionId: "cmd-session" },
  });
  expect(commandApproval.toAcpResult({ decision: "acceptAlways" })).toEqual({ outcome: { outcome: "cancelled" } });

  const fileApproval = serverApprovalFor({
    sessionId: "session-1",
    toolCall: { toolCallId: "file-1", kind: "edit", title: "Edit README.md", locations: [{ path: "/workspace/README.md" }] },
    options: [
      { optionId: "file-once", name: "Allow once", kind: "allow_once" },
      { optionId: "file-session", name: "Allow for this session", kind: "allow_always" },
      { optionId: "file-reject", name: "Reject", kind: "reject_once" },
    ],
  }, { threadId: "session-1", turnId: "turn-1", cwd: "/workspace" });

  expect(fileApproval.method).toBe("item/fileChange/requestApproval");
  expect(fileApproval.params.availableDecisions).toEqual(["accept", "acceptForSession", "decline"]);
  expect(fileApproval.toAcpResult({ decision: "acceptForSession" })).toEqual({
    outcome: { outcome: "selected", optionId: "file-session" },
  });
});

test("B05: generic unqualified allow_always does not advertise acceptForSession", () => {
  const approval = serverApprovalFor({
    sessionId: "session-1",
    toolCall: { toolCallId: "cmd-2", kind: "execute", title: "Run ls" },
    options: [
      { optionId: "opt-once", name: "Allow once", kind: "allow_once" },
      { optionId: "opt-always", name: "Always allow", kind: "allow_always" },
    ],
  }, { threadId: "session-1", turnId: "turn-1", cwd: "/workspace" });

  expect(approval.params.availableDecisions).toEqual(["accept", "acceptAlways", "decline"]);
  expect(approval.toAcpResult({ decision: "acceptForSession" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "acceptAlways" })).toEqual({
    outcome: { outcome: "selected", optionId: "opt-always" },
  });
});

test("a failed turn completion includes the same error as its history", () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const liveTurn = new LiveTurn("turn", "session", "/workspace", (method, params) => {
    notifications.push({ method, params });
  });
  liveTurn.begin(null, [{ type: "text", text: "Hello", text_elements: [] }]);

  const { turn } = liveTurn.finish(undefined, "Provider quota exhausted");

  expect(turn.status).toBe("failed");
  expect(turn.items).toHaveLength(1);
  expect(turn.error?.message).toBe("Provider quota exhausted");
  expect(notifications.find(({ method }) => method === "turn/completed")?.params).toEqual({
    threadId: "session",
    turn: { ...turn, items: [] },
  });
});

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function makeMockAcpClient(onPrompt: (sessionId: string) => Promise<{ stopReason: string }>) {
  let permissionHandler:
    | ((params: AcpRequestPermissionParams, signal: AbortSignal) => Promise<AcpRequestPermissionResult>)
    | undefined;
  const cancelledSessions: string[] = [];
  const client = {
    isClosed: false,
    onSession: () => () => {},
    onPermission: (_sid: string, handler: typeof permissionHandler) => {
      permissionHandler = handler;
      return () => {
        permissionHandler = undefined;
      };
    },
    sessionNew: async () => ({ sessionId: "race-session" }),
    sessionLoadWithReplay: async () => ({ result: { sessionId: "race-session" }, updates: [] }),
    sessionSetMode: async () => {},
    sessionSetConfigOption: async () => {},
    sessionPrompt: async (sessionId: string) => onPrompt(sessionId),
    sessionCancel: (sessionId: string) => {
      cancelledSessions.push(sessionId);
    },
    sessionClose: async () => {},
  } as unknown as AcpClient;
  return {
    client,
    cancelledSessions,
    triggerPermission: (params: AcpRequestPermissionParams, signal = new AbortController().signal) => {
      if (!permissionHandler) throw new Error("permission handler not registered");
      return permissionHandler(params, signal);
    },
  };
}

test("C12 round2: approval submission awaits blocking in-flight transcript check and cancels on conflict", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const blockingPoll = deferred<TranscriptTurnSnapshot | undefined>();
  const approvalResponse = deferred<unknown>();
  const promptDone = deferred<{ stopReason: string }>();
  let inspectCall = 0;

  const mockAcp = makeMockAcpClient(() => promptDone.promise);
  let permissionResultPromise: Promise<AcpRequestPermissionResult> | undefined;

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: (_tid, _method, _params, signal) =>
      new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
        void approvalResponse.promise.then(resolve, reject);
      }),
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 25,
    inspectTranscriptState: async () => {
      inspectCall += 1;
      // 1: initial baseline in startTurn, 2: pre-approval check, 3: pre-approval snapshot
      if (inspectCall <= 3) {
        return { path: "/tmp/t.jsonl", size: 10, mtimeMs: 1, userInputs: ["first"], plannerResponseCount: 0, stepCount: 1 };
      }
      // 4: blocking background poll started while approval is waiting
      if (inspectCall === 4) {
        return blockingPoll.promise;
      }
      return {
        path: "/tmp/t.jsonl",
        size: 40,
        mtimeMs: 2,
        userInputs: ["first", "external cli write"],
        plannerResponseCount: 0,
        stepCount: 2,
      };
    },
  };

  const runtime = new ThreadRuntime(
    "",
    "/workspace",
    host,
    { model: undefined, effort: undefined, mode: "default", executionPolicy: { type: "workspaceWrite", networkAccess: false } },
    false,
  );
  await runtime.initializeNewSession();
  await runtime.startTurn({
    input: [{ type: "text", text: "first", text_elements: [] }],
    clientUserMessageId: null,
    settings: {},
  });

  permissionResultPromise = mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-1", title: "Run pwd", kind: "execute" },
    options: [{ optionId: "allow-once", name: "Allow once", kind: "allow_once" }],
  });

  // Wait for the blocking background poll (#4) to enter inspectTranscriptState.
  for (let i = 0; i < 40 && inspectCall < 4; i += 1) {
    await new Promise((r) => setTimeout(r, 10));
  }
  expect(inspectCall).toBe(4);

  // User submits approval WHILE poll #4 is still blocked!
  let resolvedEarly = false;
  void permissionResultPromise.then(() => {
    resolvedEarly = true;
  });
  approvalResponse.resolve({ decision: "accept" });
  await new Promise((r) => setTimeout(r, 30));
  // Must NOT slip through before the in-flight check finishes!
  expect(resolvedEarly).toBe(false);

  // Now poll #4 completes and reports the concurrent external write.
  blockingPoll.resolve({
    path: "/tmp/t.jsonl",
    size: 40,
    mtimeMs: 2,
    userInputs: ["first", "external cli write"],
    plannerResponseCount: 0,
    stepCount: 2,
  });

  const outcome = await permissionResultPromise;
  expect(outcome).toEqual({ outcome: { outcome: "cancelled" } });
  expect(mockAcp.cancelledSessions).toContain("race-session");

  promptDone.resolve({ stopReason: "cancelled" });
  await new Promise((r) => setTimeout(r, 20));
  const completed = notifications.find((n) => n.method === "turn/completed");
  const turn = (completed?.params as { turn?: { status?: string; error?: { message?: string } | null } })?.turn;
  expect(turn?.status).toBe("failed");
  expect(turn?.error?.message).toBe(EXTERNAL_WRITE_CONFLICT_MESSAGE);
});

test("C12 round2: unknown transcript inspect error during approval re-check fails closed and prompts refresh", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const promptDone = deferred<{ stopReason: string }>();
  let inspectCall = 0;
  const mockAcp = makeMockAcpClient(() => promptDone.promise);

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: async () => ({ decision: "accept" }),
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 0,
    inspectTranscriptState: async () => {
      inspectCall += 1;
      if (inspectCall <= 3) {
        return { path: "/tmp/t.jsonl", size: 10, mtimeMs: 1, userInputs: ["first"], plannerResponseCount: 0, stepCount: 1 };
      }
      throw new Error("EACCES: transient transcript read error");
    },
  };

  const runtime = new ThreadRuntime(
    "",
    "/workspace",
    host,
    { model: undefined, effort: undefined, mode: "default", executionPolicy: { type: "workspaceWrite", networkAccess: false } },
    false,
  );
  await runtime.initializeNewSession();
  await runtime.startTurn({
    input: [{ type: "text", text: "first", text_elements: [] }],
    clientUserMessageId: null,
    settings: {},
  });

  const outcome = await mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-unknown", title: "Run pwd", kind: "execute" },
    options: [{ optionId: "allow-once", name: "Allow once", kind: "allow_once" }],
  });
  expect(outcome).toEqual({ outcome: { outcome: "cancelled" } });

  promptDone.resolve({ stopReason: "cancelled" });
  await new Promise((r) => setTimeout(r, 20));
  const completed = notifications.find((n) => n.method === "turn/completed");
  const turn = (completed?.params as { turn?: { status?: string; error?: { message?: string } | null } })?.turn;
  expect(turn?.status).toBe("failed");
  expect(turn?.error?.message).toBe(EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE);
});

test("C12 round2: stale transcript check from aborted turn does not poison or cancel the next turn", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const staleTurn1Check = deferred<TranscriptTurnSnapshot | undefined>();
  const turn1Prompt = deferred<{ stopReason: string }>();
  const turn2Prompt = deferred<{ stopReason: string }>();
  let promptNum = 0;
  let inspectCall = 0;

  const mockAcp = makeMockAcpClient(() => {
    promptNum += 1;
    return promptNum === 1 ? turn1Prompt.promise : turn2Prompt.promise;
  });

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: async () => ({ decision: "accept" }),
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 20,
    inspectTranscriptState: async () => {
      inspectCall += 1;
      if (inspectCall === 1) {
        return { path: "/tmp/t.jsonl", size: 10, mtimeMs: 1, userInputs: [], plannerResponseCount: 0, stepCount: 0 };
      }
      if (inspectCall === 2) {
        // Turn 1's background poll hangs until Turn 2 is already active.
        return staleTurn1Check.promise;
      }
      return { path: "/tmp/t.jsonl", size: 20, mtimeMs: 2, userInputs: ["turn1", "turn2"], plannerResponseCount: 1, stepCount: 3 };
    },
  };

  const runtime = new ThreadRuntime(
    "",
    "/workspace",
    host,
    { model: undefined, effort: undefined, mode: "default", executionPolicy: { type: "workspaceWrite", networkAccess: false } },
    false,
  );
  await runtime.initializeNewSession();
  await runtime.startTurn({
    input: [{ type: "text", text: "turn1", text_elements: [] }],
    clientUserMessageId: null,
    settings: {},
  });

  for (let i = 0; i < 40 && inspectCall < 2; i += 1) {
    await new Promise((r) => setTimeout(r, 10));
  }
  expect(inspectCall).toBe(2);

  // Interrupt and finish Turn 1 while its poll #2 is still pending.
  runtime.interrupt();
  turn1Prompt.resolve({ stopReason: "cancelled" });
  await new Promise((r) => setTimeout(r, 20));
  mockAcp.cancelledSessions.length = 0;

  // Start Turn 2.
  await runtime.startTurn({
    input: [{ type: "text", text: "turn2", text_elements: [] }],
    clientUserMessageId: null,
    settings: {},
  });

  // Now Turn 1's stale poll resolves with a conflict payload.
  staleTurn1Check.resolve({
    path: "/tmp/t.jsonl",
    size: 99,
    mtimeMs: 9,
    userInputs: ["turn1", "stale external write"],
    plannerResponseCount: 0,
    stepCount: 2,
  });
  await new Promise((r) => setTimeout(r, 30));

  // Turn 2 must NOT be cancelled or conflicted!
  expect(mockAcp.cancelledSessions).toEqual([]);
  turn2Prompt.resolve({ stopReason: "end_turn" });
  await new Promise((r) => setTimeout(r, 20));

  const turnCompletedEvents = notifications.filter((n) => n.method === "turn/completed");
  expect(turnCompletedEvents).toHaveLength(2);
  const turn2 = (turnCompletedEvents[1]?.params as { turn?: { status?: string; error?: unknown } })?.turn;
  expect(turn2?.status).toBe("completed");
  expect(turn2?.error).toBeNull();
});

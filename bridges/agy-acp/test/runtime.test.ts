import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { AcpClient } from "../src/acp/client.ts";
import type { AcpRequestPermissionParams, AcpRequestPermissionResult } from "../src/acp/types.ts";
import { AgyOverlay } from "../src/agy/overlay.ts";
import type { TranscriptSnapshotResult, TranscriptTurnSnapshot } from "../src/agy/transcript.ts";
import { capabilityDeclaration, createApp } from "../src/app.ts";
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
  expect(approval.params.alwaysAllowLabel).toBe("Always allow");
  expect(approval.params.alwaysAllowScopeUncertain).toBe(true);
  expect(approval.toAcpResult({ decision: "acceptForSession" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "acceptAlways" })).toEqual({
    outcome: { outcome: "selected", optionId: "opt-always" },
  });
});

test("B05 round3: opaque optionId containing 'session' NEVER downgrades persistent or uncertain allow_always into acceptForSession", () => {
  const opaqueWithGenericLabel = serverApprovalFor({
    sessionId: "session-1",
    toolCall: { toolCallId: "cmd-opaque-1", kind: "execute", title: "Run rm -rf tmp" },
    options: [
      { optionId: "allow-session", name: "Allow always", kind: "allow_always" },
      { optionId: "reject-1", name: "Reject", kind: "reject_once" },
    ],
  }, { threadId: "session-1", turnId: "turn-1", cwd: "/workspace" });

  expect(opaqueWithGenericLabel.params.availableDecisions).toEqual(["acceptAlways", "decline"]);
  expect(opaqueWithGenericLabel.params.alwaysAllowLabel).toBe("Allow always");
  expect(opaqueWithGenericLabel.params.alwaysAllowScopeUncertain).toBe(true);
  expect(opaqueWithGenericLabel.toAcpResult({ decision: "acceptForSession" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(opaqueWithGenericLabel.toAcpResult({ decision: "acceptAlways" })).toEqual({
    outcome: { outcome: "selected", optionId: "allow-session" },
  });

  const opaqueWithCrossSessionLabel = serverApprovalFor({
    sessionId: "session-1",
    toolCall: { toolCallId: "cmd-opaque-2", kind: "execute", title: "Run echo" },
    options: [
      { optionId: "session_rule_v1", name: "Remember for every conversation", kind: "allow_always" },
      { optionId: "reject-2", name: "Reject", kind: "reject_once" },
    ],
  }, { threadId: "session-1", turnId: "turn-1", cwd: "/workspace" });

  expect(opaqueWithCrossSessionLabel.params.availableDecisions).toEqual(["acceptAlways", "decline"]);
  expect(opaqueWithCrossSessionLabel.params.alwaysAllowLabel).toBe("Remember for every conversation");
  expect(opaqueWithCrossSessionLabel.params.alwaysAllowScopeUncertain).toBe(false);
  expect(opaqueWithCrossSessionLabel.toAcpResult({ decision: "acceptForSession" })).toEqual({ outcome: { outcome: "cancelled" } });

  const ambiguousCombinedLabel = serverApprovalFor({
    sessionId: "session-1",
    toolCall: { toolCallId: "cmd-opaque-3", kind: "execute", title: "Run echo" },
    options: [
      { optionId: "opt-mixed", name: "Allow for this session and future sessions", kind: "allow_always" },
    ],
  }, { threadId: "session-1", turnId: "turn-1", cwd: "/workspace" });
  expect(ambiguousCombinedLabel.params.availableDecisions).toEqual(["acceptAlways", "decline"]);
  expect(ambiguousCombinedLabel.toAcpResult({ decision: "acceptForSession" })).toEqual({ outcome: { outcome: "cancelled" } });

  const trustedStructuredScope = serverApprovalFor({
    sessionId: "session-1",
    toolCall: { toolCallId: "cmd-structured", kind: "execute", title: "Run pwd" },
    options: [
      { optionId: "opaque-id-99", name: "Allow", kind: "allow_always", _meta: { scope: "session" } },
      { optionId: "reject-3", name: "Reject", kind: "reject_once" },
    ],
  }, { threadId: "session-1", turnId: "turn-1", cwd: "/workspace" });
  expect(trustedStructuredScope.params.availableDecisions).toEqual(["acceptForSession", "decline"]);
  expect(trustedStructuredScope.toAcpResult({ decision: "acceptForSession" })).toEqual({
    outcome: { outcome: "selected", optionId: "opaque-id-99" },
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

test("C12 round3: initial transcript read failure fails closed on approval instead of treating error as missing", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const promptDone = deferred<{ stopReason: string }>();
  let requestCalled = false;
  const mockAcp = makeMockAcpClient(() => promptDone.promise);

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: async () => {
      requestCalled = true;
      return { decision: "accept" };
    },
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 0,
    inspectTranscriptState: async (): Promise<TranscriptSnapshotResult> => ({
      kind: "error",
      reason: "transcript_read_failed",
      error: "EACCES: permission denied",
    }),
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
    toolCall: { toolCallId: "tc-init-err", title: "Run pwd", kind: "execute" },
    options: [{ optionId: "allow-once", name: "Allow once", kind: "allow_once" }],
  });
  expect(outcome).toEqual({ outcome: { outcome: "cancelled" } });
  expect(requestCalled).toBe(false);
  expect(mockAcp.cancelledSessions).toContain("race-session");

  promptDone.resolve({ stopReason: "cancelled" });
  await new Promise((r) => setTimeout(r, 20));
  const completed = notifications.find((n) => n.method === "turn/completed");
  const turn = (completed?.params as { turn?: { status?: string; error?: { message?: string } | null } })?.turn;
  expect(turn?.status).toBe("failed");
  expect(turn?.error?.message).toBe(EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE);
});

test("C12 round3: multiple concurrent approvals in the same turn keep isolated baselines and controllers", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const promptDone = deferred<{ stopReason: string }>();
  const approvalAResponse = deferred<unknown>();
  const approvalBResponse = deferred<unknown>();
  const abortedFlags: Record<string, boolean> = {};
  let userInputs = ["concurrent approvals"];
  let plannerResponses = 1;
  const mockAcp = makeMockAcpClient(() => promptDone.promise);

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: (_tid, _method, params, signal) => {
      const itemId = String(params.itemId ?? "");
      abortedFlags[itemId] = false;
      const target = itemId.includes("tc-a") ? approvalAResponse : approvalBResponse;
      return new Promise((resolve, reject) => {
        signal.addEventListener(
          "abort",
          () => {
            abortedFlags[itemId] = true;
            reject(new Error("aborted"));
          },
          { once: true },
        );
        void target.promise.then(resolve, reject);
      });
    },
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 0,
    inspectTranscriptState: async (): Promise<TranscriptSnapshotResult> => ({
      kind: "present",
      snapshot: {
        path: "/tmp/t.jsonl",
        size: 100,
        mtimeMs: 1,
        userInputs: [...userInputs],
        plannerResponseCount: plannerResponses,
        stepCount: userInputs.length + plannerResponses,
      },
    }),
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
    input: [{ type: "text", text: "concurrent approvals", text_elements: [] }],
    clientUserMessageId: null,
    settings: {},
  });

  const promiseA = mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-a", title: "Run cmd A", kind: "execute" },
    options: [{ optionId: "allow-a", name: "Allow once", kind: "allow_once" }],
  });
  const promiseB = mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-b", title: "Run cmd B", kind: "execute" },
    options: [{ optionId: "allow-b", name: "Allow once", kind: "allow_once" }],
  });
  await new Promise((r) => setTimeout(r, 20));

  // Approval A finishes first while Approval B is still waiting.
  approvalAResponse.resolve({ decision: "accept" });
  expect(await promiseA).toEqual({ outcome: { outcome: "selected", optionId: "allow-a" } });

  // External process writes a new USER_INPUT while Approval B is still pending.
  // Approval A finishing MUST NOT have wiped Approval B's baseline or abort controller!
  userInputs = ["concurrent approvals", "external mac cli write"];
  plannerResponses = 2;
  approvalBResponse.resolve({ decision: "accept" });
  expect(await promiseB).toEqual({ outcome: { outcome: "cancelled" } });
  expect(mockAcp.cancelledSessions).toContain("race-session");

  promptDone.resolve({ stopReason: "cancelled" });
  await new Promise((r) => setTimeout(r, 20));
  const completed = notifications.find((n) => n.method === "turn/completed");
  const turn = (completed?.params as { turn?: { status?: string; error?: { message?: string } | null } })?.turn;
  expect(turn?.status).toBe("failed");
  expect(turn?.error?.message).toBe(EXTERNAL_WRITE_CONFLICT_MESSAGE);
});

test("C12 round4: benign local tool planner progress does NOT cancel a second legitimate approval", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const promptDone = deferred<{ stopReason: string }>();
  const approvalAResponse = deferred<unknown>();
  const approvalBResponse = deferred<unknown>();
  let plannerResponses = 1;
  const mockAcp = makeMockAcpClient(() => promptDone.promise);

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: (_tid, _method, params, signal) => {
      const itemId = String(params.itemId ?? "");
      const target = itemId.includes("tc-a") ? approvalAResponse : approvalBResponse;
      return new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
        void target.promise.then(resolve, reject);
      });
    },
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 0,
    inspectTranscriptState: async (): Promise<TranscriptSnapshotResult> => ({
      kind: "present",
      snapshot: {
        path: "/tmp/t.jsonl",
        size: 120,
        mtimeMs: 1,
        userInputs: ["two local tools"],
        plannerResponseCount: plannerResponses,
        stepCount: plannerResponses + 1,
      },
    }),
    externalActivity: async () => ({
      path: "/tmp/t.jsonl",
      size: 120,
      mtimeMs: 1,
      externallyBusy: false,
      holderPid: null,
    }),
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
    input: [{ type: "text", text: "two local tools", text_elements: [] }],
    clientUserMessageId: null,
    settings: {},
  });

  const promiseA = mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-a", title: "Run cmd A", kind: "execute" },
    options: [{ optionId: "allow-a", name: "Allow once", kind: "allow_once" }],
  });
  const promiseB = mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-b", title: "Run cmd B", kind: "execute" },
    options: [{ optionId: "allow-b", name: "Allow once", kind: "allow_once" }],
  });
  await new Promise((r) => setTimeout(r, 20));

  approvalAResponse.resolve({ decision: "accept" });
  expect(await promiseA).toEqual({ outcome: { outcome: "selected", optionId: "allow-a" } });

  // Local ACP writes a benign follow-up PLANNER_RESPONSE after tool A finishes while tool B awaits approval.
  plannerResponses = 2;
  approvalBResponse.resolve({ decision: "accept" });
  expect(await promiseB).toEqual({ outcome: { outcome: "selected", optionId: "allow-b" } });
  expect(mockAcp.cancelledSessions).toEqual([]);

  promptDone.resolve({ stopReason: "end_turn" });
  await new Promise((r) => setTimeout(r, 20));
  const completed = notifications.find((n) => n.method === "turn/completed");
  const turn = (completed?.params as { turn?: { status?: string; error?: { message?: string } | null } })?.turn;
  expect(turn?.status).toBe("completed");
  expect(turn?.error).toBeNull();
});

test("C12 round4: local interrupt immediately revokes all pending approvals for the active turn", async () => {
  const promptDone = deferred<{ stopReason: string }>();
  const aborted: string[] = [];
  const mockAcp = makeMockAcpClient(() => promptDone.promise);

  const host: RuntimeHost = {
    publish: () => {},
    request: (_tid, _method, params, signal) =>
      new Promise((_resolve, reject) => {
        signal.addEventListener(
          "abort",
          () => {
            aborted.push(String(params.itemId ?? ""));
            reject(new Error("aborted"));
          },
          { once: true },
        );
      }),
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 0,
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
    input: [{ type: "text", text: "interrupt pending approvals", text_elements: [] }],
    clientUserMessageId: null,
    settings: {},
  });

  const p1 = mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-int-1", title: "Cmd 1", kind: "execute" },
    options: [{ optionId: "allow-1", name: "Allow once", kind: "allow_once" }],
  });
  const p2 = mockAcp.triggerPermission({
    sessionId: "race-session",
    toolCall: { toolCallId: "tc-int-2", title: "Cmd 2", kind: "execute" },
    options: [{ optionId: "allow-2", name: "Allow once", kind: "allow_once" }],
  });
  await new Promise((r) => setTimeout(r, 20));

  // Interrupt BEFORE upstream prompt resolves: both pending approvals must immediately abort & cancel.
  runtime.interrupt();
  expect(await p1).toEqual({ outcome: { outcome: "cancelled" } });
  expect(await p2).toEqual({ outcome: { outcome: "cancelled" } });
  expect(aborted).toHaveLength(2);
  expect(mockAcp.cancelledSessions).toContain("race-session");

  promptDone.resolve({ stopReason: "cancelled" });
  await new Promise((r) => setTimeout(r, 20));
});

test("C12 round3: same-millisecond approval re-check still runs a fresh verification via monotonic sequence", async () => {
  const realDateNow = Date.now;
  Date.now = () => 1_700_000_000_000;
  try {
    const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
    const blockingPoll = deferred<TranscriptSnapshotResult>();
    const approvalResponse = deferred<unknown>();
    const promptDone = deferred<{ stopReason: string }>();
    let inspectCall = 0;
    const mockAcp = makeMockAcpClient(() => promptDone.promise);

    const host: RuntimeHost = {
      publish: (_tid, method, params) => notifications.push({ method, params }),
      request: (_tid, _method, _params, signal) =>
        new Promise((resolve, reject) => {
          signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
          void approvalResponse.promise.then(resolve, reject);
        }),
      acquireClient: async () => mockAcp.client,
      idleCloseMs: 0,
      externalWritePollMs: 15,
      inspectTranscriptState: async (): Promise<TranscriptSnapshotResult> => {
        inspectCall += 1;
        if (inspectCall <= 3) {
          return {
            kind: "present",
            snapshot: { path: "/tmp/t.jsonl", size: 10, mtimeMs: 1, userInputs: ["same-ms"], plannerResponseCount: 0, stepCount: 1 },
          };
        }
        if (inspectCall === 4) {
          // Poll #4 started BEFORE user approval, in the exact same Date.now() millisecond, and returns clean.
          return blockingPoll.promise;
        }
        // Fresh post-approval check (#5) sees the external write that landed before approval submission.
        return {
          kind: "present",
          snapshot: {
            path: "/tmp/t.jsonl",
            size: 50,
            mtimeMs: 2,
            userInputs: ["same-ms", "external same-ms write"],
            plannerResponseCount: 0,
            stepCount: 2,
          },
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
      input: [{ type: "text", text: "same-ms", text_elements: [] }],
      clientUserMessageId: null,
      settings: {},
    });

    const permissionPromise = mockAcp.triggerPermission({
      sessionId: "race-session",
      toolCall: { toolCallId: "tc-same-ms", title: "Run pwd", kind: "execute" },
      options: [{ optionId: "allow-once", name: "Allow once", kind: "allow_once" }],
    });
    for (let i = 0; i < 40 && inspectCall < 4; i += 1) {
      await new Promise((r) => setTimeout(r, 10));
    }
    expect(inspectCall).toBe(4);

    // Submit approval in the exact same Date.now() millisecond as poll #4!
    approvalResponse.resolve({ decision: "accept" });
    await new Promise((r) => setTimeout(r, 10));
    // Poll #4 resolves as clean (stale from before approval submission).
    blockingPoll.resolve({
      kind: "present",
      snapshot: { path: "/tmp/t.jsonl", size: 10, mtimeMs: 1, userInputs: ["same-ms"], plannerResponseCount: 0, stepCount: 1 },
    });

    const outcome = await permissionPromise;
    expect(inspectCall).toBeGreaterThanOrEqual(5);
    expect(outcome).toEqual({ outcome: { outcome: "cancelled" } });
    expect(mockAcp.cancelledSessions).toContain("race-session");

    promptDone.resolve({ stopReason: "cancelled" });
    await new Promise((r) => setTimeout(r, 20));
  } finally {
    Date.now = realDateNow;
  }
});

test("delayed final transcript inspection from previous turn does not publish idle over a newer active turn", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const persistedAttempts: string[] = [];
  const prompt1Done = deferred<{ stopReason: string }>();
  const prompt2Done = deferred<{ stopReason: string }>();
  const turn1AfterInspect = deferred<TranscriptSnapshotResult>();
  let promptCall = 0;
  let inspectCall = 0;

  const mockAcp = makeMockAcpClient(() => {
    promptCall += 1;
    return promptCall === 1 ? prompt1Done.promise : prompt2Done.promise;
  });

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: async () => ({ decision: "decline" }),
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 0,
    onTurnPersisted: (_tid, patch) => {
      if (patch.turnAttemptUpdate) {
        persistedAttempts.push(patch.turnAttemptUpdate.turnId);
      }
    },
    inspectTranscriptState: async () => {
      inspectCall += 1;
      if (inspectCall === 1) {
        return { kind: "missing" };
      }
      if (inspectCall === 2) {
        return turn1AfterInspect.promise;
      }
      return {
        kind: "present",
        snapshot: { path: "/tmp/t.jsonl", size: 20, mtimeMs: 2, userInputs: ["turn-1", "turn-2"], plannerResponseCount: 1, stepCount: 3 },
      };
    },
  };

  const runtime = new ThreadRuntime(
    "race-session",
    "/workspace",
    host,
    { model: undefined, effort: undefined, mode: "default", executionPolicy: { type: "workspaceWrite", networkAccess: false } },
    false,
  );
  await runtime.initializeNewSession();

  const turn1 = await runtime.startTurn({
    input: [{ type: "text", text: "turn-1", text_elements: [] }],
    clientUserMessageId: "client-1",
    settings: {},
  });
  expect(runtime.activeTurnId).toBe(turn1.id);

  // Turn 1 finishes prompt and enters finally, blocking on its final inspectTranscriptState (#2).
  prompt1Done.resolve({ stopReason: "end_turn" });
  for (let i = 0; i < 40 && inspectCall < 2; i += 1) {
    await new Promise((r) => setTimeout(r, 5));
  }
  expect(inspectCall).toBe(2);
  expect(runtime.activeTurnId).toBeUndefined();

  // Follow-up turn 2 starts while turn 1 finalization is still pending.
  const turn2 = await runtime.startTurn({
    input: [{ type: "text", text: "turn-2", text_elements: [] }],
    clientUserMessageId: "client-2",
    settings: {},
  });
  expect(runtime.activeTurnId).toBe(turn2.id);

  // Unblock turn 1's delayed inspection; turn 1 must still persist its attempt but MUST NOT emit idle over turn 2.
  turn1AfterInspect.resolve({
    kind: "present",
    snapshot: { path: "/tmp/t.jsonl", size: 10, mtimeMs: 1, userInputs: ["turn-1"], plannerResponseCount: 1, stepCount: 2 },
  });
  for (let i = 0; i < 40 && !persistedAttempts.includes(turn1.id); i += 1) {
    await new Promise((r) => setTimeout(r, 5));
  }
  await new Promise((r) => setTimeout(r, 10));

  const statusesWhileTurn2Active = notifications
    .filter((n) => n.method === "thread/status/changed")
    .map((n) => (n.params.status as { type?: string } | undefined)?.type);
  expect(statusesWhileTurn2Active).toEqual(["active", "active"]);
  expect(runtime.activeTurnId).toBe(turn2.id);
  expect(persistedAttempts).toContain(turn1.id);

  // Completing turn 2 publishes idle normally.
  prompt2Done.resolve({ stopReason: "end_turn" });
  for (let i = 0; i < 40 && !persistedAttempts.includes(turn2.id); i += 1) {
    await new Promise((r) => setTimeout(r, 5));
  }
  await new Promise((r) => setTimeout(r, 10));

  const statusesAfterTurn2Done = notifications
    .filter((n) => n.method === "thread/status/changed")
    .map((n) => (n.params.status as { type?: string } | undefined)?.type);
  expect(statusesAfterTurn2Done).toEqual(["active", "active", "idle"]);
  expect(runtime.activeTurnId).toBeUndefined();
});

test("delayed final transcript inspection still publishes idle when a follow-up startTurn fails before becoming active", async () => {
  const notifications: Array<{ method: string; params: Record<string, unknown> }> = [];
  const prompt1Done = deferred<{ stopReason: string }>();
  const turn1AfterInspect = deferred<TranscriptSnapshotResult>();
  let inspectCall = 0;
  let extBusy = false;

  const mockAcp = makeMockAcpClient(() => prompt1Done.promise);

  const host: RuntimeHost = {
    publish: (_tid, method, params) => notifications.push({ method, params }),
    request: async () => ({ decision: "decline" }),
    acquireClient: async () => mockAcp.client,
    idleCloseMs: 0,
    externalWritePollMs: 0,
    externalActivity: async () =>
      extBusy ? { path: "/tmp/t.jsonl", size: 10, externallyBusy: true, mtimeMs: Date.now(), holderPid: 4242 } : undefined,
    inspectTranscriptState: async () => {
      inspectCall += 1;
      if (inspectCall === 1) return { kind: "missing" };
      return turn1AfterInspect.promise;
    },
  };

  const runtime = new ThreadRuntime(
    "race-session",
    "/workspace",
    host,
    { model: undefined, effort: undefined, mode: "default", executionPolicy: { type: "workspaceWrite", networkAccess: false } },
    false,
  );
  await runtime.initializeNewSession();

  await runtime.startTurn({
    input: [{ type: "text", text: "turn-1", text_elements: [] }],
    clientUserMessageId: "client-1",
    settings: {},
  });

  prompt1Done.resolve({ stopReason: "end_turn" });
  for (let i = 0; i < 40 && inspectCall < 2; i += 1) {
    await new Promise((r) => setTimeout(r, 5));
  }
  expect(inspectCall).toBe(2);

  // Follow-up fails before publishing active (external busy guard).
  extBusy = true;
  await expect(
    runtime.startTurn({
      input: [{ type: "text", text: "turn-2-rejected", text_elements: [] }],
      clientUserMessageId: "client-2",
      settings: {},
    }),
  ).rejects.toThrow(/Another Antigravity process/);

  // Turn 1 finalization finishes and must still publish idle so clients do not stay stuck in active.
  turn1AfterInspect.resolve({ kind: "missing" });
  for (let i = 0; i < 40; i += 1) {
    const types = notifications
      .filter((n) => n.method === "thread/status/changed")
      .map((n) => (n.params.status as { type?: string } | undefined)?.type);
    if (types.includes("idle")) break;
    await new Promise((r) => setTimeout(r, 5));
  }

  const statuses = notifications
    .filter((n) => n.method === "thread/status/changed")
    .map((n) => (n.params.status as { type?: string } | undefined)?.type);
  expect(statuses).toEqual(["active", "idle"]);
});

test("#1177: preserving existing agy session permissions skips session/set_mode, handles transient plan, and respects explicit override", async () => {
  const setModeCalls: string[] = [];
  const fakeClient = {
    isClosed: false,
    onSession: () => () => {},
    onPermission: () => () => {},
    sessionLoadWithReplay: async () => ({
      result: {
        sessionId: "ext-session",
        modes: { currentModeId: "accept-edits", availableModes: [] },
      },
      updates: [],
    }),
    sessionSetMode: async (_sessionId: string, modeId: string) => {
      setModeCalls.push(modeId);
    },
    sessionSetConfigOption: async () => {},
    sessionPrompt: async () => ({ stopReason: "end_turn" }),
    sessionCancel: () => {},
  } as unknown as AcpClient;

  const host: RuntimeHost = {
    publish: () => {},
    request: async () => ({}),
    acquireClient: async () => fakeClient,
    idleCloseMs: 60_000,
  };

  const runtime = new ThreadRuntime(
    "ext-session",
    "/workspace",
    host,
    { model: undefined, effort: undefined, mode: "default", executionPolicy: { type: "workspaceWrite", networkAccess: false } },
    true,
    null,
    undefined,
    undefined,
    true,
  );

  // 1) Preserved turn must NOT overwrite upstream currentModeId ("accept-edits") with default.
  await runtime.startTurn({
    input: [{ type: "text", text: "follow up", text_elements: [] }],
    clientUserMessageId: "c1",
    preservePermissions: true,
    planMode: false,
    settings: {},
  });
  await new Promise((r) => setTimeout(r, 20));
  expect(setModeCalls).toEqual([]);
  expect(runtime.effectiveMode).toBe("accept-edits");

  // 2) One-off Plan turn temporarily enters "plan", then next preserved turn restores "accept-edits".
  await runtime.startTurn({
    input: [{ type: "text", text: "plan first", text_elements: [] }],
    clientUserMessageId: "c2",
    preservePermissions: true,
    planMode: true,
    settings: {},
  });
  await new Promise((r) => setTimeout(r, 20));
  expect(setModeCalls).toEqual(["plan"]);

  await runtime.startTurn({
    input: [{ type: "text", text: "back to normal", text_elements: [] }],
    clientUserMessageId: "c3",
    preservePermissions: true,
    planMode: false,
    settings: {},
  });
  await new Promise((r) => setTimeout(r, 20));
  expect(setModeCalls).toEqual(["plan", "accept-edits"]);

  // 3) Explicit user permission selection overrides the preserved mode.
  await runtime.startTurn({
    input: [{ type: "text", text: "switch to auto", text_elements: [] }],
    clientUserMessageId: "c4",
    preservePermissions: false,
    planMode: false,
    settings: { mode: "auto", executionPolicy: { type: "workspaceWrite", networkAccess: false } },
  });
  await new Promise((r) => setTimeout(r, 20));
  expect(setModeCalls).toEqual(["plan", "accept-edits", "auto"]);
  expect(runtime.effectiveMode).toBe("auto");
});

test("#1177: adapter advertises preserveThreadPermissions and overlay persists explicit session permissions", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "agy-perm-overlay-"));
  try {
    const app = createApp({ stateDir: dir, log: () => {} });
    const caps = capabilityDeclaration(app.router);
    expect(caps.preserveThreadPermissions).toBe(true);
    await app.close();

    const overlayFile = path.join(dir, "overlay.json");
    const writer = new AgyOverlay(overlayFile);
    await writer.recordSession("sess-1", {
      permissions: {
        mode: "accept-edits",
        executionPolicy: { type: "workspaceWrite", networkAccess: false },
        approvalPolicy: "on-request",
        approvalsReviewer: "accept_edits",
      },
    });
    await writer.flush();

    const reader = new AgyOverlay(overlayFile);
    await reader.load();
    expect(reader.get("sess-1")?.permissions).toEqual({
      mode: "accept-edits",
      executionPolicy: { type: "workspaceWrite", networkAccess: false },
      approvalPolicy: "on-request",
      approvalsReviewer: "accept_edits",
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

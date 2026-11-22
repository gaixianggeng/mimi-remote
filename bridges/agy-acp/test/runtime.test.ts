import { expect, test } from "bun:test";
import { serverApprovalFor } from "../src/runtime/approvals.ts";
import { LiveTurn } from "../src/runtime/liveTurn.ts";

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

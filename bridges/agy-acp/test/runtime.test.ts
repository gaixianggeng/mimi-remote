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

test("B01: ACP request with only allow_always omits accept and never escalates allow_once", () => {
  const approval = serverApprovalFor({
    sessionId: "session",
    toolCall: { toolCallId: "tool-always-only", kind: "execute", title: "Run command" },
    options: [{ optionId: "fixture-allow-always", name: "Always allow", kind: "allow_always" }],
  }, { threadId: "session", turnId: "turn", cwd: "/workspace" });

  expect(approval.params.availableDecisions).toEqual(["acceptForSession", "decline"]);
  expect(approval.toAcpResult({ decision: "accept" })).toEqual({ outcome: { outcome: "cancelled" } });
  expect(approval.toAcpResult({ decision: "acceptForSession" })).toEqual({
    outcome: { outcome: "selected", optionId: "fixture-allow-always" },
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

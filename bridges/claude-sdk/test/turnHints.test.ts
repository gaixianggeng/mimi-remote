import { describe, expect, test } from "bun:test";
import { completeToolItem, isTurnHintItem, toolUseItem, unfinishedToolItem } from "../src/claude/tools.ts";
import type { JsonValue } from "../src/protocol/codex/serde_json/JsonValue.ts";

describe("Claude turn hint tools", () => {
  test("live tool projection preserves structured arguments for every supported hint", () => {
    const hints: Array<[string, JsonValue]> = [
      ["mcp__ccd_turn__wrap_up", { recap: "done", ask: "next?", actions: [{ label: "Continue", message: "continue" }] }],
      ["mcp__ccd_session__start_session", { title: "Follow-up", prompt: "continue" }],
      ["mcp__ccd_session__spawn_task", { title: "Legacy follow-up", tldr: "continue" }],
    ];

    for (const [name, input] of hints) {
      const item = toolUseItem(`item-${name}`, name, input, "session-1");
      expect(item.type).toBe("mcpToolCall");
      expect(item.type === "mcpToolCall" && item.arguments).toEqual(input);
      expect(isTurnHintItem(item)).toBe(true);
    }
  });

  test("similarly named tools from other servers stay ordinary tool calls", () => {
    const item = toolUseItem("other-wrap", "mcp__other__wrap_up", { recap: "done" }, "session-1");
    expect(item.type).toBe("mcpToolCall");
    expect(isTurnHintItem(item)).toBe(false);
  });

  test("acceptance and malformed calls do not enter the summary as hint cards", () => {
    const acceptance = toolUseItem(
      "accept-proposal",
      "mcp__ccd_session__start_session",
      { proposal_id: "proposal-1" },
      "session-1",
    );
    const malformedWrapUp = toolUseItem("empty-wrap", "mcp__ccd_turn__wrap_up", { actions: [] }, "session-1");
    expect(isTurnHintItem(acceptance)).toBe(false);
    expect(isTurnHintItem(malformedWrapUp)).toBe(false);
  });

  test("failed and interrupted hint tools remain ordinary tool calls", () => {
    const call = toolUseItem(
      "failed-wrap",
      "mcp__ccd_turn__wrap_up",
      { recap: "done", ask: "next?" },
      "session-1",
    );
    if (call.type !== "mcpToolCall") throw new Error("expected MCP tool call");
    expect(isTurnHintItem(call)).toBe(true);
    const failed = completeToolItem(call, { text: "rejected", images: [], isError: true });
    expect(failed.type === "mcpToolCall" && [failed.status, failed.error?.message]).toEqual(["failed", "rejected"]);
    expect(isTurnHintItem(failed)).toBe(false);
    expect(isTurnHintItem({ ...call, status: "completed", error: { message: "inconsistent error" } })).toBe(false);
    expect(isTurnHintItem(unfinishedToolItem(call, false))).toBe(false);
    expect(isTurnHintItem(unfinishedToolItem(call, true))).toBe(true);
  });
});

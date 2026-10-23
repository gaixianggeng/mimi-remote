import { describe, expect, test } from "bun:test";
import { messagesToTurns, summarizeTurn, type HistoryMessage } from "../src/claude/history.ts";

let clock = Date.parse("2026-09-01T00:00:00.000Z");
let counter = 0;
const ts = () => new Date((clock += 1_000)).toISOString();
const uuid = (prefix: string) => `${prefix}-${++counter}`;

const user = (content: unknown, extra: Partial<HistoryMessage> = {}): HistoryMessage => ({
  type: "user",
  uuid: uuid("u"),
  message: { role: "user", content },
  timestamp: ts(),
  ...extra,
});
const assistant = (content: unknown[], id = uuid("msg")): HistoryMessage => ({
  type: "assistant",
  uuid: uuid("a"),
  message: { id, role: "assistant", content },
  timestamp: ts(),
});
const translate = (messages: HistoryMessage[], running = false) =>
  messagesToTurns(messages, { sessionId: "session-1", running });

describe("messagesToTurns", () => {
  test("each real prompt starts a turn with its replies and tool calls", () => {
    const turns = translate([
      user("list files"),
      assistant([{ type: "thinking", thinking: "plan" }]),
      assistant([{ type: "tool_use", id: "tool-1", name: "Bash", input: { command: "ls" } }]),
      user([{ type: "tool_result", tool_use_id: "tool-1", content: "a.txt" }]),
      assistant([{ type: "text", text: "Found a.txt" }]),
      user("thanks"),
      assistant([{ type: "text", text: "You're welcome" }]),
    ]);
    expect(turns.map((turn) => turn.items.map((item) => item.type))).toEqual([
      ["userMessage", "reasoning", "commandExecution", "agentMessage"],
      ["userMessage", "agentMessage"],
    ]);
    const command = turns[0]!.items[2]!;
    expect(command.type === "commandExecution" && [command.command, command.status, command.aggregatedOutput]).toEqual([
      "ls",
      "completed",
      "a.txt",
    ]);
    expect(turns[0]!.status).toBe("completed");
  });

  test("each content block of one API message is its own item with an ordinal id", () => {
    // transcript 每条记录是一个内容块；ID 规则与实时事件相同。
    const turns = translate([
      user("hi"),
      assistant([{ type: "thinking", thinking: "" }], "msg-x"),
      assistant([{ type: "text", text: "Hello" }], "msg-x"),
      assistant([{ type: "text", text: "again" }], "msg-x"),
    ]);
    expect(turns[0]!.items.slice(1).map((item) => item.id)).toEqual([
      "reasoning_msg_msg-x",
      "assistant_msg_msg-x",
      "assistant_msg_msg-x_1",
    ]);
  });

  test("tool calls map to the same item kinds as the old bridge", () => {
    const calls = [
      ["Read", { file_path: "/repo/a.ts", offset: 2, limit: 10 }],
      ["Grep", { pattern: "TODO", output_mode: "content" }],
      ["Glob", { pattern: "**/*.ts", path: "/repo" }],
      ["Edit", { file_path: "/repo/a.ts", old_string: "a", new_string: "b" }],
      ["Write", { file_path: "/repo/b.ts", content: "x\ny" }],
      ["mcp__github__list_issues", { repo: "r" }],
      ["Task", { description: "explore", prompt: "look around", subagent_type: "Explore" }],
      ["ExitPlanMode", { plan: "1. do it" }],
      ["WebSearch", { query: "q" }],
    ] as const;
    const turns = translate([
      user("go"),
      assistant(calls.map(([name, input], index) => ({ type: "tool_use", id: `t${index}`, name, input }))),
    ]);
    const items = turns[0]!.items.slice(1);
    expect(items.map((item) => item.type)).toEqual([
      "commandExecution",
      "commandExecution",
      "commandExecution",
      "fileChange",
      "fileChange",
      "mcpToolCall",
      "collabAgentToolCall",
      "plan",
      "dynamicToolCall",
    ]);
    const read = items[0]!;
    expect(read.type === "commandExecution" && read.command).toBe("Read /repo/a.ts (offset 2, limit 10)");
    const mcp = items[5]!;
    expect(mcp.type === "mcpToolCall" && [mcp.server, mcp.tool]).toEqual(["github", "list_issues"]);
    const write = items[4]!;
    expect(write.type === "fileChange" && write.changes[0]!.diff).toBe("@@ -0,0 +1,2 @@\n+x\n+y\n");
  });

  test("tool calls without a result are interrupted unless the session is still running", () => {
    const messages = [user("run"), assistant([{ type: "tool_use", id: "t1", name: "Bash", input: { command: "sleep 9" } }])];
    const stopped = translate(messages)[0]!;
    expect(stopped.items[1]!.type === "commandExecution" && stopped.items[1]!.status).toBe("failed");
    const running = translate(messages, true)[0]!;
    expect(running.status).toBe("inProgress");
    expect(running.items[1]!.type === "commandExecution" && running.items[1]!.status).toBe("inProgress");
  });

  test("a holder elsewhere keeps its last pending tool call in progress without synthesizing a running turn", () => {
    const messages = [
      user("first"),
      assistant([{ type: "tool_use", id: "t1", name: "Bash", input: { command: "sleep 9" } }]),
      user("second"),
      assistant([{ type: "tool_use", id: "t2", name: "Bash", input: { command: "touch x" } }]),
    ];
    const [earlier, last] = messagesToTurns(messages, { sessionId: "session-1", running: false, holderActive: true });
    expect(earlier!.items[1]!.type === "commandExecution" && earlier!.items[1]!.status).toBe("failed");
    expect(last!.items[1]!.type === "commandExecution" && last!.items[1]!.status).toBe("inProgress");
    expect(last!.status).not.toBe("inProgress");
    expect(last!.status).toBe(translate(messages)[1]!.status);
  });

  test("interrupt markers end the turn as interrupted and are not shown", () => {
    const turns = translate([user("long task"), assistant([{ type: "text", text: "working" }]), user("[Request interrupted by user]")]);
    expect(turns).toHaveLength(1);
    expect(turns[0]!.status).toBe("interrupted");
  });

  test("internal user records do not start turns; slash commands do", () => {
    const turns = translate([
      user("first"),
      user("<task-notification>\n<status>completed</status>\n</task-notification>", { isQueuedCommand: true }),
      user("<local-command-stdout>ok</local-command-stdout>"),
      user("<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>"),
    ]);
    expect(turns.map((turn) => turn.items[0]!.type === "userMessage" && turn.items[0]!.content)).toEqual([
      [{ type: "text", text: "first", text_elements: [] }],
      [{ type: "text", text: "/model opus", text_elements: [] }],
    ]);
  });

  test("a compaction summary becomes a context compaction item", () => {
    const turns = translate([
      user("This session is being continued from a previous conversation...", { isCompactSummary: true }),
      assistant([{ type: "text", text: "continuing" }]),
      user("next"),
    ]);
    expect(turns[0]!.items.map((item) => item.type)).toEqual(["contextCompaction", "agentMessage"]);
    expect(turns[1]!.items[0]!.type).toBe("userMessage");
  });

  test("pasted images become data URLs in the user message", () => {
    const turns = translate([
      user([
        { type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } },
        { type: "text", text: "what is this" },
      ]),
    ]);
    const first = turns[0]!.items[0]!;
    expect(first.type === "userMessage" && first.content).toEqual([
      { type: "image", url: "data:image/png;base64,AAAA" },
      { type: "text", text: "what is this", text_elements: [] },
    ]);
  });

  test("summary view keeps only the conversation text", () => {
    const turn = translate([
      user("go"),
      assistant([{ type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } }]),
      user([{ type: "tool_result", tool_use_id: "t1", content: "x" }]),
      assistant([{ type: "text", text: "done" }]),
    ])[0]!;
    const summary = summarizeTurn(turn);
    expect(summary.itemsView).toBe("summary");
    expect(summary.items.map((item) => item.type)).toEqual(["userMessage", "agentMessage"]);
  });

  test("summary view keeps turn hints such as the next-step box and task proposals", () => {
    const wrapUp = { recap: "done", ask: "merge?", actions: [{ label: "Merge", message: "merge it" }] };
    const turn = translate([
      user("go"),
      assistant([{ type: "tool_use", id: "t1", name: "mcp__other__wrap_up", input: {} }]),
      user([{ type: "tool_result", tool_use_id: "t1", content: "x" }]),
      assistant([{ type: "tool_use", id: "t2", name: "mcp__ccd_session__start_session", input: { title: "Follow-up", prompt: "do it" } }]),
      user([{ type: "tool_result", tool_use_id: "t2", content: "Proposed" }]),
      assistant([{ type: "tool_use", id: "t3", name: "mcp__ccd_turn__wrap_up", input: wrapUp }]),
      user([{ type: "tool_result", tool_use_id: "t3", content: "Shown" }]),
    ])[0]!;
    const summary = summarizeTurn(turn);
    const hints = summary.items.filter((item) => item.type === "mcpToolCall");
    expect(hints.map((item) => item.type === "mcpToolCall" && `${item.server}/${item.tool}`)).toEqual([
      "ccd_session/start_session",
      "ccd_turn/wrap_up",
    ]);
    // 客户端靠 arguments 渲染卡片，必须原样保留。
    expect(hints[1]!.type === "mcpToolCall" && hints[1]!.arguments).toEqual(wrapUp);
  });
});

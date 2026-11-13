import { describe, expect, test } from "bun:test";
import { messagesToTurns, summarizeTurn, type HistoryMessage } from "../src/claude/history.ts";
import { notificationTurnId } from "../src/claude/itemIds.ts";

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

  describe("background task notifications (#797)", () => {
    const notification = (runId: string | undefined, extra: Partial<HistoryMessage> = {}) =>
      user("<task-notification>\n<task-id>bash-1</task-id>\n<status>completed</status>\n</task-notification>", {
        ...(runId ? { origin: { kind: "task-notification", producer: "session-task", runId } } : {}),
        ...extra,
      });
    const shape = (turns: ReturnType<typeof translate>) => turns.map((turn) => [turn.id, turn.status, turn.items.map((item) => item.type)]);

    test("a notification between turns starts the continuation under the id the live side uses", () => {
      const prompt = user("run it in the background");
      const turns = translate([
        prompt,
        assistant([{ type: "text", text: "started" }]),
        notification("run-1"),
        assistant([{ type: "text", text: "background finished" }]),
      ]);
      expect(shape(turns)).toEqual([
        [prompt.uuid, "completed", ["userMessage", "agentMessage"]],
        [notificationTurnId("session-1", "run-1"), "completed", ["agentMessage"]],
      ]);
    });

    test("while the continuation runs it is the turn in progress, even before its first record", () => {
      const prompt = user("run it in the background");
      const before = [prompt, assistant([{ type: "text", text: "started" }]), notification("run-1")];
      const continuation = notificationTurnId("session-1", "run-1");
      expect(shape(translate(before, true))).toEqual([
        [prompt.uuid, "completed", ["userMessage", "agentMessage"]],
        [continuation, "inProgress", []],
      ]);
      const streaming = translate([...before, assistant([{ type: "text", text: "partial" }])], true);
      expect(shape(streaming).at(-1)).toEqual([continuation, "inProgress", ["agentMessage"]]);
      // 停止后 CLI 写中断标记：续写回合以 interrupted 收尾，不影响上一轮。
      const stopped = translate([...before, assistant([{ type: "text", text: "partial" }]), user("[Request interrupted by user]")]);
      expect(shape(stopped).map(([, status]) => status)).toEqual(["completed", "interrupted"]);
    });

    test("notifications arriving together share one continuation, owned by the last one", () => {
      const turns = translate([
        user("two jobs"),
        assistant([{ type: "text", text: "started" }]),
        notification("run-1"),
        notification("run-2"),
        assistant([{ type: "text", text: "both finished" }]),
        notification("run-3"),
        assistant([{ type: "text", text: "third finished" }]),
      ]);
      expect(turns.slice(1).map((turn) => turn.id)).toEqual([notificationTurnId("session-1", "run-2"), notificationTurnId("session-1", "run-3")]);
    });

    test("a notification folded into a running turn stays in that turn", () => {
      const turns = translate([
        user("work"),
        assistant([{ type: "tool_use", id: "tool-1", name: "Bash", input: { command: "make" } }]),
        user([{ type: "tool_result", tool_use_id: "tool-1", content: "ok" }]),
        notification("run-1", { isQueuedCommand: true }),
        assistant([{ type: "text", text: "build and job done" }]),
      ]);
      expect(turns).toHaveLength(1);
      expect(turns[0]!.items.map((item) => item.type)).toEqual(["userMessage", "commandExecution", "agentMessage"]);
    });

    test("without a run id (older Claude Code) the notification record's own uuid names the turn", () => {
      const record = notification(undefined);
      const turns = translate([user("job"), assistant([{ type: "text", text: "started" }]), record, assistant([{ type: "text", text: "done" }])]);
      expect(turns.map((turn) => turn.id).at(-1)).toBe(record.uuid);
    });
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
    const legacySpawn = { title: "Legacy follow-up", tldr: "Keep the old proposal", prompt: "continue", cwd: "/tmp/demo" };
    const turn = translate([
      user("go"),
      assistant([{ type: "tool_use", id: "t1", name: "mcp__other__wrap_up", input: {} }]),
      user([{ type: "tool_result", tool_use_id: "t1", content: "x" }]),
      assistant([{ type: "tool_use", id: "t2", name: "mcp__ccd_session__start_session", input: { title: "Follow-up", prompt: "do it" } }]),
      user([{ type: "tool_result", tool_use_id: "t2", content: "Proposed" }]),
      assistant([{ type: "tool_use", id: "t3", name: "mcp__ccd_turn__wrap_up", input: wrapUp }]),
      user([{ type: "tool_result", tool_use_id: "t3", content: "Shown" }]),
      assistant([{ type: "tool_use", id: "t4", name: "mcp__ccd_session__spawn_task", input: legacySpawn }]),
      user([{ type: "tool_result", tool_use_id: "t4", content: "Proposed" }]),
    ])[0]!;
    const summary = summarizeTurn(turn);
    const hints = summary.items.filter((item) => item.type === "mcpToolCall");
    expect(hints.map((item) => item.type === "mcpToolCall" && `${item.server}/${item.tool}`)).toEqual([
      "ccd_session/start_session",
      "ccd_turn/wrap_up",
      "ccd_session/spawn_task",
    ]);
    // 客户端靠 arguments 渲染卡片，必须原样保留。
    expect(hints[1]!.type === "mcpToolCall" && hints[1]!.arguments).toEqual(wrapUp);
    expect(hints[2]!.type === "mcpToolCall" && hints[2]!.arguments).toEqual(legacySpawn);
  });

  test("only a proposal marker recorded by this adapter becomes actionable structured content", () => {
    const marker = JSON.stringify({
      mimi_task_proposal: { version: 1, proposal_id: "proposal-trusted" },
    });
    const messages = [
      user("go"),
      assistant([{ type: "tool_use", id: "proposal", name: "mcp__ccd_session__start_session", input: { title: "Follow-up", prompt: "do it" } }]),
      user([{ type: "tool_result", tool_use_id: "proposal", content: marker }]),
    ];
    const untrusted = messagesToTurns(messages, { sessionId: "session-1", running: false })[0]!.items[1]!;
    const trusted = messagesToTurns(messages, {
      sessionId: "session-1",
      running: false,
      isMimiTaskProposal: (id) => id === "proposal-trusted",
    })[0]!.items[1]!;

    expect(untrusted.type === "mcpToolCall" && untrusted.result?.structuredContent).toBeNull();
    expect(trusted.type === "mcpToolCall" && trusted.result?.structuredContent).toEqual({
      mimi_task_proposal: { version: 1, proposal_id: "proposal-trusted" },
    });
  });

  test("summary view drops failed and interrupted turn hints", () => {
    const failed = translate([
      user("go"),
      assistant([{ type: "tool_use", id: "failed", name: "mcp__ccd_turn__wrap_up", input: { recap: "done" } }]),
      user([{ type: "tool_result", tool_use_id: "failed", content: "rejected", is_error: true }]),
      assistant([{ type: "tool_use", id: "interrupted", name: "mcp__ccd_session__start_session", input: { title: "Follow-up" } }]),
    ])[0]!;

    const fullHints = failed.items.filter((item) => item.type === "mcpToolCall");
    expect(fullHints.map((item) => item.type === "mcpToolCall" && item.status)).toEqual(["failed", "failed"]);
    expect(summarizeTurn(failed).items.filter((item) => item.type === "mcpToolCall")).toEqual([]);
  });
});

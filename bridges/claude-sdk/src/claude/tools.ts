// Claude 工具调用 → Codex ThreadItem。分类与展示文案和旧 bridge 保持一致，
// 这样 iOS 的渲染（命令卡片、文件改动、MCP、子代理）切换后不变。
import type { ThreadItem } from "../protocol/codex/v2/ThreadItem.ts";
import type { CommandAction } from "../protocol/codex/v2/CommandAction.ts";
import type { FileUpdateChange } from "../protocol/codex/v2/FileUpdateChange.ts";
import type { JsonValue } from "../protocol/codex/serde_json/JsonValue.ts";

type Args = Record<string, unknown>;

export type ToolKind =
  | { kind: "command" }
  | { kind: "fileChange" }
  | { kind: "mcp"; server: string; tool: string }
  | { kind: "plan" }
  | { kind: "subagent" }
  | { kind: "read" }
  | { kind: "search" }
  | { kind: "list" }
  | { kind: "dynamic"; namespace: string; tool: string };

const FILE_CHANGE_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);

export function classifyTool(name: string): ToolKind {
  if (name === "Bash") return { kind: "command" };
  if (FILE_CHANGE_TOOLS.has(name)) return { kind: "fileChange" };
  const mcp = splitMcpName(name);
  if (mcp) return { kind: "mcp", ...mcp };
  switch (name) {
    case "ExitPlanMode":
      return { kind: "plan" };
    case "Task":
    case "Agent":
      return { kind: "subagent" };
    case "Read":
      return { kind: "read" };
    case "Grep":
      return { kind: "search" };
    case "Glob":
    case "LS":
      return { kind: "list" };
    default:
      return { kind: "dynamic", namespace: "claude", tool: name };
  }
}

/** `mcp__<server>__<tool>`：server 与 tool 在 `mcp__` 之后的第一个 `__` 处分开。 */
export function splitMcpName(name: string): { server: string; tool: string } | undefined {
  if (!name.startsWith("mcp__")) return undefined;
  const rest = name.slice("mcp__".length);
  const separator = rest.indexOf("__");
  if (separator <= 0) return undefined;
  const server = rest.slice(0, separator);
  const tool = rest.slice(separator + 2);
  return tool ? { server, tool } : undefined;
}

function str(args: Args, key: string): string | undefined {
  const value = args[key];
  return typeof value === "string" && value !== "" ? value : undefined;
}

function int(args: Args, key: string): number | undefined {
  const value = args[key];
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (typeof value === "string" && /^-?\d+$/.test(value)) return Number(value);
  return undefined;
}

function withDetails(base: string, details: string[]): string {
  return details.length ? `${base} (${details.join(", ")})` : base;
}

function baseName(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? "file";
}

function commandItem(id: string, command: string, actions: CommandAction[]): ThreadItem {
  return {
    type: "commandExecution",
    id,
    pluginId: null,
    scriptPath: null,
    command,
    cwd: "",
    processId: null,
    source: "agent",
    status: "inProgress",
    commandActions: actions,
    aggregatedOutput: null,
    exitCode: null,
    durationMs: null,
  };
}

function explorationItem(kind: "read" | "search" | "list", tool: string, id: string, args: Args): ThreadItem {
  if (kind === "read") {
    const path = str(args, "file_path") ?? "";
    const details: string[] = [];
    const offset = int(args, "offset");
    const limit = int(args, "limit");
    if (offset !== undefined) details.push(`offset ${offset}`);
    if (limit !== undefined) details.push(`limit ${limit}`);
    const command = withDetails(`Read ${path}`, details);
    return commandItem(id, command, [{ type: "read", command, name: baseName(path), path }]);
  }
  if (kind === "search") {
    const pattern = str(args, "pattern") ?? "";
    const details: string[] = [];
    const mode = str(args, "output_mode");
    const head = int(args, "head_limit");
    if (mode) details.push(`mode ${mode}`);
    if (head !== undefined) details.push(`head ${head}`);
    if (args["-n"] === true) details.push("-n");
    const command = withDetails(`Grep ${pattern}`, details);
    return commandItem(id, command, [{ type: "search", command, query: pattern, path: str(args, "path") ?? null }]);
  }
  const pattern = str(args, "pattern");
  const path = str(args, "path");
  const command = [tool, pattern, path].filter(Boolean).join(" ");
  return commandItem(id, command, [{ type: "listFiles", command, path: path ?? null }]);
}

function unifiedAddition(content: string): string {
  const lines = content.split("\n");
  return `@@ -0,0 +1,${lines.length} @@\n${lines.map((line) => `+${line}`).join("\n")}\n`;
}

function unifiedHunk(oldText: string, newText: string): string {
  const removed = oldText === "" ? [] : oldText.split("\n");
  const added = newText === "" ? [] : newText.split("\n");
  const body = [...removed.map((line) => `-${line}`), ...added.map((line) => `+${line}`)].join("\n");
  return `@@ -1,${removed.length} +1,${added.length} @@\n${body}\n`;
}

export function fileChanges(tool: string, args: Args): FileUpdateChange[] {
  if (tool === "NotebookEdit") {
    const path = str(args, "notebook_path");
    if (!path) return [];
    return [{ path, kind: { type: "update", move_path: null }, diff: unifiedAddition(str(args, "new_source") ?? "") }];
  }
  const path = str(args, "file_path");
  if (!path) return [];
  if (tool === "Write") return [{ path, kind: { type: "add" }, diff: unifiedAddition(String(args.content ?? "")) }];
  if (tool === "MultiEdit") {
    const edits = Array.isArray(args.edits) ? (args.edits as Args[]) : [];
    if (!edits.length) return [];
    const diff = edits.map((edit) => unifiedHunk(String(edit.old_string ?? ""), String(edit.new_string ?? ""))).join("");
    return [{ path, kind: { type: "update", move_path: null }, diff }];
  }
  return [
    {
      path,
      kind: { type: "update", move_path: null },
      diff: unifiedHunk(String(args.old_string ?? ""), String(args.new_string ?? "")),
    },
  ];
}

function subagentLabel(args: Args): string {
  const name = str(args, "name");
  const type = str(args, "subagent_type");
  const description = str(args, "description");
  const head = [name, type].filter(Boolean).join(" · ");
  const parts = [head && description ? `${head}: ${description}` : head || description || ""].filter(Boolean);
  const team = str(args, "team_name");
  if (team) parts.push(`team ${team}`);
  if (args.run_in_background === true) parts.push("background");
  return parts.join(" · ");
}

/**
 * 回合提示工具：Claude 桌面版注入的「下一步提示框」与「新任务提议」。
 * 它们是给用户看的交互卡片，不是执行过程，所以 summary 视图也要保留，客户端按 server/tool 渲染。
 */
export function isTurnHintItem(item: ThreadItem): boolean {
  if (
    item.type !== "mcpToolCall" ||
    (item.status !== "completed" && item.status !== "inProgress") ||
    item.error !== null ||
    !item.arguments ||
    typeof item.arguments !== "object" ||
    Array.isArray(item.arguments)
  ) {
    return false;
  }
  const args = item.arguments;
  const hasText = (key: string) => typeof args[key] === "string" && args[key].trim().length > 0;
  switch (`${item.server}/${item.tool}`) {
    case "ccd_turn/wrap_up":
      return hasText("recap") || hasText("ask");
    case "ccd_session/start_session":
    case "ccd_session/spawn_task":
      // start_session 的接受调用只有 proposal_id，不是给用户展示的新提议。
      return hasText("title");
    default:
      return false;
  }
}

/** 不在时间线上单独显示的工具：提问由 item/tool/requestUserInput 卡片承载。 */
export function isHiddenTool(name: string): boolean {
  return name === "AskUserQuestion";
}

/** 由 tool_use 块生成进行中的 item；结果到达后用 completeToolItem 补齐。 */
export function toolUseItem(id: string, name: string, input: unknown, sessionId: string): ThreadItem {
  const args = (input && typeof input === "object" ? input : {}) as Args;
  const kind = classifyTool(name);
  switch (kind.kind) {
    case "command":
      return commandItem(id, str(args, "command") ?? "", []);
    case "fileChange":
      return { type: "fileChange", id, changes: fileChanges(name, args), status: "inProgress" };
    case "mcp":
      return {
        type: "mcpToolCall",
        id,
        server: kind.server,
        tool: kind.tool,
        status: "inProgress",
        arguments: args as JsonValue,
        appContext: null,
        mcpAppUi: null,
        pluginId: null,
        readOnlyHint: null,
        result: null,
        error: null,
        durationMs: null,
      };
    case "plan":
      return { type: "plan", id, text: str(args, "plan") ?? "" };
    case "subagent": {
      const receiver = `subagent-${id}`;
      const label = subagentLabel(args);
      return {
        type: "collabAgentToolCall",
        id,
        tool: "spawnAgent",
        status: "inProgress",
        senderThreadId: sessionId,
        receiverThreadIds: [receiver],
        prompt: str(args, "prompt") ?? null,
        model: null,
        reasoningEffort: null,
        agentsStates: { [receiver]: { status: "running", message: label || null } },
      };
    }
    case "read":
    case "search":
    case "list":
      return explorationItem(kind.kind, name, id, args);
    case "dynamic":
      return {
        type: "dynamicToolCall",
        id,
        namespace: kind.namespace,
        tool: kind.tool,
        arguments: args as JsonValue,
        status: "inProgress",
        contentItems: null,
        success: null,
        durationMs: null,
      };
  }
}

export interface ToolOutput {
  text: string;
  images: string[];
  isError: boolean;
}

type IsMimiTaskProposal = (proposalId: string) => boolean;

function taskProposalStructuredContent(
  item: ThreadItem,
  output: ToolOutput,
  isMimiTaskProposal: IsMimiTaskProposal | undefined,
): JsonValue | null {
  if (item.type !== "mcpToolCall" || item.server !== "ccd_session" || item.tool !== "start_session" || !isMimiTaskProposal) {
    return null;
  }
  try {
    const parsed = JSON.parse(output.text) as Record<string, unknown>;
    const marker = parsed.mimi_task_proposal as Record<string, unknown> | undefined;
    const proposalId = marker?.proposal_id;
    if (marker?.version !== 1 || typeof proposalId !== "string" || !isMimiTaskProposal(proposalId)) return null;
    return { mimi_task_proposal: { version: 1, proposal_id: proposalId } };
  } catch {
    return null;
  }
}

/** 命令输出在历史里截断，避免单个 item 把分页撑大；完整内容仍在 transcript。 */
const MAX_OUTPUT_CHARS = 64 * 1024;

function capOutput(text: string): string {
  if (text.length <= MAX_OUTPUT_CHARS) return text;
  return `${text.slice(0, MAX_OUTPUT_CHARS)}\n…（输出过长，已截断 ${text.length - MAX_OUTPUT_CHARS} 字符）`;
}

export function completeToolItem(
  item: ThreadItem,
  output: ToolOutput,
  isMimiTaskProposal?: IsMimiTaskProposal,
): ThreadItem {
  switch (item.type) {
    case "commandExecution":
      return { ...item, status: output.isError ? "failed" : "completed", aggregatedOutput: capOutput(output.text) };
    case "fileChange":
      return { ...item, status: output.isError ? "failed" : "completed" };
    case "mcpToolCall":
      return output.isError
        ? { ...item, status: "failed", error: { message: output.text } }
        : {
            ...item,
            status: "completed",
            result: {
              content: [{ type: "text", text: output.text }],
              structuredContent: taskProposalStructuredContent(item, output, isMimiTaskProposal),
              _meta: null,
            },
          };
    case "collabAgentToolCall": {
      const states = Object.fromEntries(
        Object.entries(item.agentsStates).map(([key, state]) => [
          key,
          { status: output.isError ? "errored" : "completed", message: output.text || state?.message || null },
        ]),
      ) as typeof item.agentsStates;
      return { ...item, status: output.isError ? "failed" : "completed", agentsStates: states };
    }
    case "dynamicToolCall":
      return {
        ...item,
        status: output.isError ? "failed" : "completed",
        success: !output.isError,
        contentItems: [
          ...(output.text ? [{ type: "inputText" as const, text: output.text }] : []),
          ...output.images.map((imageUrl) => ({ type: "inputImage" as const, imageUrl })),
        ],
      };
    default:
      return item;
  }
}

/** 历史里没有结果的工具调用：仍在运行的会话里是进行中，否则视为中断。 */
export function unfinishedToolItem(item: ThreadItem, running: boolean): ThreadItem {
  if (running) return item;
  switch (item.type) {
    case "commandExecution":
      return { ...item, status: "failed" };
    case "fileChange":
      return { ...item, status: "failed" };
    case "mcpToolCall":
      return { ...item, status: "failed" };
    case "collabAgentToolCall":
      return { ...item, status: "interrupted" };
    case "dynamicToolCall":
      return { ...item, status: "failed", success: false };
    default:
      return item;
  }
}

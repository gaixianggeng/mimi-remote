// SDK 的 getSessionMessages 已经给出与 `claude --resume` 一致的消息序列（主链、
// 压缩处理、排队消息、并行工具结果都由 SDK 决定）。这里只负责把它切成 turn、
// 映射成 Codex item，不再自行判断哪些消息该显示。
import type { ThreadItem } from "../protocol/codex/v2/ThreadItem.ts";
import type { Turn } from "../protocol/codex/v2/Turn.ts";
import type { TurnStatus } from "../protocol/codex/v2/TurnStatus.ts";
import type { UserInput } from "../protocol/codex/v2/UserInput.ts";
import { completeToolItem, toolUseItem, unfinishedToolItem, type ToolOutput } from "./tools.ts";

/** SDK SessionMessage 中本模块用到的字段。 */
export interface HistoryMessage {
  type: "user" | "assistant" | "system";
  uuid: string;
  message: unknown;
  timestamp?: string;
  isCompactSummary?: boolean;
  isQueuedCommand?: boolean;
}

type Block = Record<string, unknown> & { type?: unknown };

const INTERRUPT_MARKER = /^\[Request interrupted by user[^\]]*\]$/;
const COMMAND_NAME = /<command-name>([\s\S]*?)<\/command-name>/;
const COMMAND_ARGS = /<command-args>([\s\S]*?)<\/command-args>/;
// CLI 不把这些当作用户提问显示：本地命令输出、caveat、后台任务完成通知。
const INTERNAL_PREFIXES = ["<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>", "<task-notification>"];

/**
 * 用户记录是否只是内部记录（本地命令输出、caveat、后台任务通知），CLI 不把它显示为提问。
 * 活动时间与历史共用这条规则。
 */
export function isInternalUserContent(content: unknown): boolean {
  const texts =
    typeof content === "string"
      ? [content]
      : Array.isArray(content) && content.every((block) => (block as Block)?.type === "text")
        ? (content as Block[]).map((block) => String(block.text ?? ""))
        : [];
  return texts.length > 0 && texts.every((text) => INTERNAL_PREFIXES.some((prefix) => text.trim().startsWith(prefix)));
}

function blocksOf(message: unknown): Block[] | string | undefined {
  const content = (message as { content?: unknown } | null)?.content;
  if (typeof content === "string") return content;
  return Array.isArray(content) ? (content as Block[]) : undefined;
}

function seconds(timestamp: string | undefined): number | null {
  if (!timestamp) return null;
  const ms = Date.parse(timestamp);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

function imageUrl(block: Block): string | undefined {
  const source = block.source as Record<string, unknown> | undefined;
  if (!source) return undefined;
  if (source.type === "base64" && typeof source.data === "string") {
    return `data:${String(source.media_type ?? "image/png")};base64,${source.data}`;
  }
  return typeof source.url === "string" ? source.url : undefined;
}

type Prompt = { kind: "prompt"; input: UserInput[] } | { kind: "interrupt" } | { kind: "internal" };

/** 判断一条用户消息在 CLI 里显示成什么：真实提问、中断标记，或不显示的内部记录。 */
function classifyUserText(text: string): Prompt | undefined {
  const trimmed = text.trim();
  if (INTERRUPT_MARKER.test(trimmed)) return { kind: "interrupt" };
  if (INTERNAL_PREFIXES.some((prefix) => trimmed.startsWith(prefix))) return { kind: "internal" };
  const command = COMMAND_NAME.exec(trimmed);
  if (command) {
    const name = command[1]!.trim();
    const args = COMMAND_ARGS.exec(trimmed)?.[1]?.trim();
    const display = `${name.startsWith("/") ? name : `/${name}`}${args ? ` ${args}` : ""}`;
    return { kind: "prompt", input: [{ type: "text", text: display, text_elements: [] }] };
  }
  return undefined;
}

function userPrompt(blocks: Block[] | string): Prompt {
  if (typeof blocks === "string") {
    return classifyUserText(blocks) ?? { kind: "prompt", input: [{ type: "text", text: blocks, text_elements: [] }] };
  }
  const input: UserInput[] = [];
  for (const block of blocks) {
    if (block.type === "text" && typeof block.text === "string") {
      const special = classifyUserText(block.text);
      if (special && special.kind !== "prompt") return special;
      if (special) input.push(...special.input);
      else if (block.text.trim()) input.push({ type: "text", text: block.text, text_elements: [] });
    } else if (block.type === "image") {
      const url = imageUrl(block);
      if (url) input.push({ type: "image", url });
    }
  }
  return input.length ? { kind: "prompt", input } : { kind: "internal" };
}

function toolOutput(block: Block): ToolOutput {
  const content = block.content;
  const texts: string[] = [];
  const images: string[] = [];
  if (typeof content === "string") texts.push(content);
  else if (Array.isArray(content)) {
    for (const part of content as Block[]) {
      if (part.type === "text" && typeof part.text === "string") texts.push(part.text);
      else if (part.type === "image") {
        const url = imageUrl(part);
        if (url) images.push(url);
      }
    }
  }
  return { text: texts.join("\n"), images, isError: block.is_error === true };
}

interface TurnDraft {
  id: string;
  items: ThreadItem[];
  status: TurnStatus;
  startedAt: number | null;
  completedAt: number | null;
  /** 最近一条 agentMessage 所属的 API 消息 id；同一消息拆成多条记录时合并文本。 */
  lastTextMessageId: string | undefined;
}

export interface TranslateOptions {
  sessionId: string;
  /** 会话是否仍有进程在写入；决定没有结果的工具调用显示为进行中还是中断。 */
  running: boolean;
}

export function messagesToTurns(messages: readonly HistoryMessage[], options: TranslateOptions): Turn[] {
  const turns: TurnDraft[] = [];
  const toolIndex = new Map<string, { turn: TurnDraft; index: number }>();
  let current: TurnDraft | undefined;

  const open = (id: string, timestamp: string | undefined): TurnDraft => {
    const draft: TurnDraft = {
      id,
      items: [],
      status: "completed",
      startedAt: seconds(timestamp),
      completedAt: seconds(timestamp),
      lastTextMessageId: undefined,
    };
    turns.push(draft);
    return draft;
  };
  const ensure = (message: HistoryMessage) => current ?? (current = open(message.uuid, message.timestamp));

  for (const message of messages) {
    if (message.type === "system") continue;
    if (message.isCompactSummary) {
      const turn = ensure(message);
      turn.items.push({ type: "contextCompaction", id: message.uuid });
      turn.lastTextMessageId = undefined;
      continue;
    }
    const blocks = blocksOf(message.message);
    if (blocks === undefined) continue;

    if (message.type === "user") {
      const toolResults = typeof blocks === "string" ? [] : blocks.filter((block) => block.type === "tool_result");
      for (const result of toolResults) {
        const target = toolIndex.get(String(result.tool_use_id ?? ""));
        if (!target) continue;
        const item = target.turn.items[target.index]!;
        target.turn.items[target.index] = completeToolItem(item, toolOutput(result));
        target.turn.completedAt = seconds(message.timestamp) ?? target.turn.completedAt;
      }
      const rest = typeof blocks === "string" ? blocks : blocks.filter((block) => block.type !== "tool_result");
      if (typeof rest !== "string" && rest.length === 0) continue;
      const prompt = userPrompt(rest);
      if (prompt.kind === "interrupt") {
        if (current) current.status = "interrupted";
        continue;
      }
      if (prompt.kind === "internal") continue;
      current = open(message.uuid, message.timestamp);
      current.items.push({ type: "userMessage", id: message.uuid, clientId: null, content: prompt.input });
      continue;
    }

    // assistant
    const turn = ensure(message);
    const apiMessageId = String((message.message as { id?: unknown })?.id ?? message.uuid);
    const assistantBlocks = typeof blocks === "string" ? [{ type: "text", text: blocks }] : blocks;
    assistantBlocks.forEach((block, index) => {
      if (block.type === "text" && typeof block.text === "string") {
        if (!block.text.trim()) return;
        const last = turn.items[turn.items.length - 1];
        if (last?.type === "agentMessage" && turn.lastTextMessageId === apiMessageId) {
          turn.items[turn.items.length - 1] = { ...last, text: `${last.text}${block.text}` };
        } else {
          turn.items.push({
            type: "agentMessage",
            // 一条记录里出现多个文本块时按块序号区分，保证 item ID 唯一。
            id: index === 0 ? message.uuid : `${message.uuid}:${index}`,
            text: block.text,
            phase: null,
            memoryCitation: null,
            delivery: null,
            questions: null,
          });
        }
        turn.lastTextMessageId = apiMessageId;
      } else if (block.type === "thinking" && typeof block.thinking === "string" && block.thinking.trim()) {
        turn.items.push({ type: "reasoning", id: `${message.uuid}:${index}`, summary: [], content: [block.thinking] });
        turn.lastTextMessageId = undefined;
      } else if (block.type === "tool_use" && typeof block.id === "string") {
        turn.items.push(toolUseItem(block.id, String(block.name ?? ""), block.input, options.sessionId));
        toolIndex.set(block.id, { turn, index: turn.items.length - 1 });
        turn.lastTextMessageId = undefined;
      }
    });
    turn.completedAt = seconds(message.timestamp) ?? turn.completedAt;
  }

  const lastTurn = turns[turns.length - 1];
  return turns.map((draft) => {
    const running = options.running && draft === lastTurn;
    const items = draft.items.map((item) => {
      const pending = toolIndex.get(item.id);
      const unfinished = pending && "status" in item && item.status === "inProgress";
      return unfinished ? unfinishedToolItem(item, running) : item;
    });
    const status: TurnStatus = running && draft.status === "completed" ? "inProgress" : draft.status;
    const durationMs =
      draft.startedAt !== null && draft.completedAt !== null ? (draft.completedAt - draft.startedAt) * 1000 : null;
    return {
      id: draft.id,
      rootTurnId: null,
      items,
      itemsView: "full",
      status,
      error: null,
      startedAt: draft.startedAt,
      completedAt: status === "inProgress" ? null : draft.completedAt,
      durationMs: status === "inProgress" ? null : durationMs,
    } satisfies Turn;
  });
}

/** summary 视图只保留对话文本，工具过程由 thread/items/list 按 turn 补齐。 */
export function summarizeTurn(turn: Turn): Turn {
  return {
    ...turn,
    itemsView: "summary",
    items: turn.items.filter((item) => item.type === "userMessage" || item.type === "agentMessage"),
  };
}

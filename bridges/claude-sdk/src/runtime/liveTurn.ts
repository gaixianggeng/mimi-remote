// 一个进行中的 turn：把 SDK 的流式消息翻译成 app-server 通知。事件顺序与旧 bridge
// 一致（turn/started → 用户消息 → 回复/思考/工具的 started、delta、completed → token
// 用量 → turn/completed），item ID 与历史记录同一套规则。
import type { ThreadItem } from "../protocol/codex/v2/ThreadItem.ts";
import type { Turn } from "../protocol/codex/v2/Turn.ts";
import type { TurnStatus } from "../protocol/codex/v2/TurnStatus.ts";
import type { UserInput } from "../protocol/codex/v2/UserInput.ts";
import { ItemIdAllocator } from "../claude/itemIds.ts";
import { completeToolItem, isHiddenTool, toolUseItem, unfinishedToolItem, type ToolOutput } from "../claude/tools.ts";
import { logger } from "../util/logging.ts";

export type Emit = (method: string, params: Record<string, unknown>) => void;

type Block = Record<string, unknown> & { type?: unknown };

interface OpenText {
  id: string;
  kind: "text" | "thinking";
  messageId: string;
  text: string;
}

export interface TurnUsage {
  inputTokens: number;
  cachedInputTokens: number;
  cacheWriteInputTokens: number;
  outputTokens: number;
  reasoningOutputTokens: number;
  totalTokens: number;
}

export interface TurnOutcome {
  subtype: string;
  errors: string[];
  usage: TurnUsage | undefined;
  contextWindow: number | null;
}

const INTERRUPT_MARKER = /^\[Request interrupted by user[^\]]*\]$/;
const nowSeconds = () => Math.floor(Date.now() / 1000);

function toolOutput(block: Block): ToolOutput {
  const content = block.content;
  const texts: string[] = [];
  const images: string[] = [];
  if (typeof content === "string") texts.push(content);
  else if (Array.isArray(content)) {
    for (const part of content as Block[]) {
      if (part.type === "text" && typeof part.text === "string") texts.push(part.text);
      const source = part.source as Record<string, unknown> | undefined;
      if (part.type === "image" && source?.type === "base64") {
        images.push(`data:${String(source.media_type)};base64,${String(source.data)}`);
      }
    }
  }
  return { text: texts.join("\n"), images, isError: block.is_error === true };
}

export class LiveTurn {
  status: TurnStatus = "inProgress";
  finished = false;
  /** 用户通过 turn/interrupt 明确中断。 */
  explicitlyInterrupted = false;
  /** Claude 记录了 "[Request interrupted by user]"（可能只是引导打断了上一段输出）。 */
  private interruptMarker = false;
  private readonly startedAt = nowSeconds();
  private readonly ids = new ItemIdAllocator();
  private messageId = "";
  /** 流式中已开始、等完整 assistant 消息来收尾的文本/思考 item，按块序号索引。 */
  private readonly blocks = new Map<number, OpenText>();
  private readonly openTexts: OpenText[] = [];
  private readonly tools = new Map<string, ThreadItem>();

  constructor(
    readonly id: string,
    private readonly threadId: string,
    private readonly emit: Emit,
    private readonly isMimiTaskProposal?: (proposalId: string) => boolean,
  ) {}

  private scoped(params: Record<string, unknown>): Record<string, unknown> {
    return { threadId: this.threadId, turnId: this.id, ...params };
  }

  private started(item: ThreadItem): void {
    this.emit("item/started", this.scoped({ item }));
  }

  private completed(item: ThreadItem): void {
    this.emit("item/completed", this.scoped({ item }));
  }

  snapshot(): Turn {
    const done = this.status !== "inProgress";
    const completedAt = done ? nowSeconds() : null;
    return {
      id: this.id,
      rootTurnId: null,
      items: [],
      itemsView: "full",
      status: this.status,
      error: null,
      startedAt: this.startedAt,
      completedAt,
      durationMs: completedAt === null ? null : (completedAt - this.startedAt) * 1000,
    };
  }

  begin(): void {
    this.emit("turn/started", { threadId: this.threadId, turn: this.snapshot() });
  }

  userMessage(id: string, clientId: string | null, content: UserInput[]): void {
    const item: ThreadItem = { type: "userMessage", id, clientId, content };
    this.started(item);
    this.completed(item);
  }

  onStreamEvent(event: Record<string, unknown>): void {
    switch (event.type) {
      case "message_start":
        this.messageId = String((event.message as { id?: unknown } | undefined)?.id ?? "");
        this.blocks.clear();
        return;
      case "content_block_start": {
        const block = event.content_block as Block;
        const index = Number(event.index);
        if (block.type !== "text" && block.type !== "thinking") return;
        const open: OpenText = {
          kind: block.type,
          messageId: this.messageId,
          id: block.type === "text" ? this.ids.agentMessage(this.messageId) : this.ids.reasoning(this.messageId),
          text: "",
        };
        this.blocks.set(index, open);
        this.openTexts.push(open);
        this.started(this.textItem(open));
        return;
      }
      case "content_block_delta": {
        const open = this.blocks.get(Number(event.index));
        const delta = event.delta as Block;
        if (!open) return;
        if (delta.type === "text_delta" && typeof delta.text === "string" && delta.text) {
          open.text += delta.text;
          this.emit("item/agentMessage/delta", this.scoped({ itemId: open.id, delta: delta.text }));
        } else if (delta.type === "thinking_delta" && typeof delta.thinking === "string" && delta.thinking) {
          open.text += delta.thinking;
          this.emit("item/reasoning/textDelta", this.scoped({ itemId: open.id, contentIndex: 0, delta: delta.thinking }));
        }
        return;
      }
    }
  }

  private textItem(open: OpenText): ThreadItem {
    return open.kind === "text"
      ? { type: "agentMessage", id: open.id, text: open.text, phase: null, memoryCitation: null, delivery: null, questions: null }
      : { type: "reasoning", id: open.id, summary: [], content: open.text ? [open.text] : [] };
  }

  /** 取出流式阶段已开始的同类 item；没有流式（或漏了）时现场分配并补发 started。 */
  private claimOpen(kind: OpenText["kind"], messageId: string): OpenText {
    const index = this.openTexts.findIndex((open) => open.kind === kind && open.messageId === messageId);
    if (index >= 0) return this.openTexts.splice(index, 1)[0]!;
    const open: OpenText = {
      kind,
      messageId,
      id: kind === "text" ? this.ids.agentMessage(messageId) : this.ids.reasoning(messageId),
      text: "",
    };
    this.started(this.textItem(open));
    return open;
  }

  onAssistant(message: Record<string, unknown>, sessionId: string): void {
    const messageId = String(message.id ?? this.messageId);
    const content = Array.isArray(message.content) ? (message.content as Block[]) : [];
    for (const block of content) {
      if (block.type === "text" && typeof block.text === "string") {
        const open = this.claimOpen("text", messageId);
        open.text = block.text;
        this.completed(this.textItem(open));
      } else if (block.type === "thinking") {
        const open = this.claimOpen("thinking", messageId);
        if (typeof block.thinking === "string" && block.thinking) open.text = block.thinking;
        this.completed(this.textItem(open));
      } else if (block.type === "tool_use" && typeof block.id === "string" && !isHiddenTool(String(block.name ?? ""))) {
        const item = toolUseItem(block.id, String(block.name ?? ""), block.input, sessionId);
        this.tools.set(block.id, item);
        this.started(item);
      }
    }
  }

  onUserMessage(message: Record<string, unknown>): void {
    const content = message.content;
    if (typeof content === "string") {
      if (INTERRUPT_MARKER.test(content.trim())) this.interruptMarker = true;
      return;
    }
    if (!Array.isArray(content)) return;
    for (const block of content as Block[]) {
      if (block.type === "tool_result") {
        const id = String(block.tool_use_id ?? "");
        const item = this.tools.get(id);
        if (!item) continue;
        this.tools.delete(id);
        this.completed(completeToolItem(item, toolOutput(block), this.isMimiTaskProposal));
      } else if (block.type === "text" && typeof block.text === "string" && INTERRUPT_MARKER.test(block.text.trim())) {
        this.interruptMarker = true;
      }
    }
  }

  onCompactBoundary(id: string): void {
    const item: ThreadItem = { type: "contextCompaction", id };
    this.started(item);
    this.completed(item);
  }

  markInterrupted(): void {
    this.explicitlyInterrupted = true;
  }

  /**
   * 引导消息让 Claude 打断上一段输出、继续回应：中间结果不收尾 turn，先把已开始的 item
   * 收尾，清掉中断标记，后续输出仍归这个 turn。
   */
  continueAfterSteer(): void {
    for (const open of this.openTexts.splice(0)) this.completed(this.textItem(open));
    for (const item of this.tools.values()) this.completed(unfinishedToolItem(item, false));
    this.tools.clear();
    this.blocks.clear();
    this.interruptMarker = false;
  }

  /** 收尾：补完未收尾的 item，发 token 用量与 turn/completed。 */
  finish(outcome: TurnOutcome, total: TurnUsage | undefined): Turn {
    this.finished = true;
    for (const open of this.openTexts.splice(0)) this.completed(this.textItem(open));
    for (const item of this.tools.values()) this.completed(unfinishedToolItem(item, false));
    this.tools.clear();
    const success = outcome.subtype === "success";
    this.status = this.explicitlyInterrupted
      ? "interrupted"
      : success
        ? "completed"
        : this.interruptMarker
          ? "interrupted"
          : "failed";
    if (outcome.usage) {
      this.emit(
        "thread/tokenUsage/updated",
        this.scoped({ tokenUsage: { last: outcome.usage, total: total ?? outcome.usage, modelContextWindow: outcome.contextWindow } }),
      );
    }
    const turn = this.snapshot();
    if (this.status === "failed") {
      turn.error = {
        message: outcome.errors.join("\n") || outcome.subtype,
        codexErrorInfo: null,
        additionalDetails: null,
        misalignment: null,
      };
    }
    logger.debug("turn.complete", { thread: this.threadId, turn: this.id, status: this.status, subtype: outcome.subtype });
    this.emit("turn/completed", { threadId: this.threadId, turn });
    return turn;
  }
}

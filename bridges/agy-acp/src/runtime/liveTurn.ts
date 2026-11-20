import type { ThreadItem } from "@mimi/appserver-kit/protocol/codex/v2/ThreadItem.ts";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { TurnStatus } from "@mimi/appserver-kit/protocol/codex/v2/TurnStatus.ts";
import type { UserInput } from "@mimi/appserver-kit/protocol/codex/v2/UserInput.ts";
import type { AcpPromptResult, AcpSessionUpdate } from "../acp/types.ts";
import { acpToolToThreadItem, formatPlanMarkdown, mergeToolState, type AcpToolState } from "../agy/tools.ts";

export type Emit = (method: string, params: Record<string, unknown>) => void;

export interface TurnUsage {
  inputTokens: number;
  cachedInputTokens: number;
  cacheWriteInputTokens: number;
  outputTokens: number;
  reasoningOutputTokens: number;
  totalTokens: number;
}

const nowSeconds = () => Math.floor(Date.now() / 1000);

export class LiveTurn {
  status: TurnStatus = "inProgress";
  finished = false;
  explicitlyInterrupted = false;
  private readonly startedAt = nowSeconds();
  private completedAt: number | null = null;
  private userSeq = 0;
  private reasoningSeq = 0;
  private msgSeq = 0;
  private openThought: { id: string; text: string } | null = null;
  private openMessage: { id: string; text: string } | null = null;
  private planItem: { id: string; text: string } | null = null;
  private readonly toolStates = new Map<string, AcpToolState>();
  private readonly completedItems: ThreadItem[] = [];
  private contextWindow: number | null = null;
  private contextUsed: number | null = null;

  constructor(
    readonly id: string,
    private readonly threadId: string,
    private readonly cwd: string,
    private readonly emit: Emit,
  ) {}

  private nextUserItemId(): string {
    this.userSeq += 1;
    return this.userSeq === 1 ? `${this.id}:user` : `${this.id}:user:${this.userSeq}`;
  }

  private nextReasoningItemId(): string {
    this.reasoningSeq += 1;
    return `${this.id}:reasoning:${this.reasoningSeq}`;
  }

  private nextMessageItemId(): string {
    this.msgSeq += 1;
    return `${this.id}:msg:${this.msgSeq}`;
  }

  private scoped(params: Record<string, unknown>): Record<string, unknown> {
    return { threadId: this.threadId, turnId: this.id, ...params };
  }

  private emitStarted(item: ThreadItem): void {
    this.emit("item/started", this.scoped({ item }));
  }

  private emitCompleted(item: ThreadItem): void {
    this.completedItems.push(item);
    this.emit("item/completed", this.scoped({ item }));
  }

  private closeOpenText(): void {
    if (this.openThought) {
      const thought = this.openThought;
      this.openThought = null;
      this.emitCompleted({
        type: "reasoning",
        id: thought.id,
        summary: [],
        content: thought.text ? [thought.text] : [],
      });
    }
    if (this.openMessage) {
      const msg = this.openMessage;
      this.openMessage = null;
      this.emitCompleted({
        type: "agentMessage",
        id: msg.id,
        text: msg.text,
        phase: null,
        memoryCitation: null,
        delivery: null,
        questions: null,
      });
    }
  }

  snapshot(includeItems = false): Turn {
    const done = this.status !== "inProgress";
    const end = done ? (this.completedAt ?? nowSeconds()) : null;
    const liveItems: ThreadItem[] = includeItems ? [...this.completedItems] : [];
    if (includeItems) {
      if (this.openThought) {
        liveItems.push({ type: "reasoning", id: this.openThought.id, summary: [], content: [this.openThought.text] });
      }
      if (this.openMessage) {
        liveItems.push({
          type: "agentMessage",
          id: this.openMessage.id,
          text: this.openMessage.text,
          phase: null,
          memoryCitation: null,
          delivery: null,
          questions: null,
        });
      }
      for (const state of this.toolStates.values()) {
        liveItems.push(acpToolToThreadItem(state, this.cwd, !done));
      }
    }
    return {
      id: this.id,
      rootTurnId: null,
      items: liveItems,
      itemsView: "full",
      status: this.status,
      error: null,
      startedAt: this.startedAt,
      completedAt: end,
      durationMs: end === null ? null : (end - this.startedAt) * 1000,
    };
  }

  begin(clientId: string | null, input: UserInput[]): void {
    this.emit("turn/started", { threadId: this.threadId, turn: this.snapshot(false) });
    const userItem: ThreadItem = {
      type: "userMessage",
      id: this.nextUserItemId(),
      clientId,
      content: input,
    };
    this.emitStarted(userItem);
    this.emitCompleted(userItem);
  }

  onUpdate(update: AcpSessionUpdate): void {
    switch (update.sessionUpdate) {
      case "agent_thought_chunk": {
        const delta = update.content?.type === "text" ? (update.content.text ?? "") : "";
        if (!delta) return;
        if (this.openMessage) this.closeOpenText();
        if (!this.openThought) {
          const id = this.nextReasoningItemId();
          this.openThought = { id, text: "" };
          this.emitStarted({ type: "reasoning", id, summary: [], content: [] });
        }
        this.openThought.text += delta;
        this.emit("item/reasoning/textDelta", this.scoped({ itemId: this.openThought.id, contentIndex: 0, delta }));
        return;
      }

      case "agent_message_chunk": {
        const delta = update.content?.type === "text" ? (update.content.text ?? "") : "";
        if (!delta) return;
        if (this.openThought) this.closeOpenText();
        if (!this.openMessage) {
          const id = this.nextMessageItemId();
          this.openMessage = { id, text: "" };
          this.emitStarted({
            type: "agentMessage",
            id,
            text: "",
            phase: null,
            memoryCitation: null,
            delivery: null,
            questions: null,
          });
        }
        this.openMessage.text += delta;
        this.emit("item/agentMessage/delta", this.scoped({ itemId: this.openMessage.id, delta }));
        return;
      }

      case "tool_call":
      case "tool_call_update": {
        const toolCallId = typeof update.toolCallId === "string" ? update.toolCallId : "";
        if (!toolCallId) return;
        this.closeOpenText();
        const isFirst = !this.toolStates.has(toolCallId);
        const merged = mergeToolState(this.toolStates.get(toolCallId), {
          toolCallId,
          title: typeof update.title === "string" ? update.title : undefined,
          kind: typeof update.kind === "string" ? update.kind : undefined,
          status: typeof update.status === "string" ? update.status : undefined,
          content: Array.isArray(update.content) ? update.content : undefined,
          locations: Array.isArray(update.locations) ? update.locations : undefined,
          rawInput: update.rawInput && typeof update.rawInput === "object" ? (update.rawInput as Record<string, unknown>) : undefined,
          rawOutput: update.rawOutput,
        });
        const terminal = merged.status === "completed" || merged.status === "failed";
        const item = acpToolToThreadItem(merged, this.cwd, !terminal);
        if (isFirst) {
          this.toolStates.set(toolCallId, merged);
          this.emitStarted(acpToolToThreadItem({ ...merged, status: "in_progress" }, this.cwd, true));
        } else {
          this.toolStates.set(toolCallId, merged);
        }
        if (terminal) {
          this.toolStates.delete(toolCallId);
          this.emitCompleted(item);
        }
        return;
      }

      case "plan": {
        const entries = Array.isArray(update.entries) ? update.entries : [];
        const markdown = formatPlanMarkdown(entries);
        if (!markdown) return;
        this.closeOpenText();
        const id = this.planItem?.id ?? `${this.id}:plan`;
        const isNew = !this.planItem;
        this.planItem = { id, text: markdown };
        const item: ThreadItem = { type: "plan", id, text: markdown };
        if (isNew) this.emitStarted(item);
        this.emitCompleted(item);
        return;
      }

      case "usage_update": {
        if (typeof update.size === "number" && update.size > 0) {
          this.contextWindow = update.size;
        }
        if (typeof update.used === "number" && update.used >= 0) {
          this.contextUsed = update.used;
        }
        if (this.contextWindow !== null && this.contextUsed !== null) {
          const snapshot: TurnUsage = {
            inputTokens: this.contextUsed,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: this.contextUsed,
          };
          this.emit(
            "thread/tokenUsage/updated",
            this.scoped({ tokenUsage: { last: snapshot, total: snapshot, modelContextWindow: this.contextWindow } }),
          );
        }
        return;
      }
    }
  }

  markInterrupted(): void {
    this.explicitlyInterrupted = true;
  }

  finish(result: AcpPromptResult | undefined, errorMessage?: string, totalUsage?: TurnUsage): { turn: Turn; usage?: TurnUsage } {
    this.finished = true;
    this.completedAt = nowSeconds();
    this.closeOpenText();
    for (const state of this.toolStates.values()) {
      this.emitCompleted(acpToolToThreadItem(state, this.cwd, false));
    }
    this.toolStates.clear();

    const stopReason = result?.stopReason;
    if (this.explicitlyInterrupted || stopReason === "cancelled") {
      this.status = "interrupted";
    } else if (errorMessage) {
      this.status = "failed";
    } else {
      this.status = "completed";
    }

    let lastUsage: TurnUsage | undefined;
    if (result?.usage) {
      const u = result.usage;
      const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
      const inputTokens = num(u.inputTokens);
      const cachedInputTokens = num(u.cachedReadTokens);
      const cacheWriteInputTokens = num(u.cachedWriteTokens);
      const outputTokens = num(u.outputTokens);
      const reasoningOutputTokens = num(u.thoughtTokens);
      const totalTokens = num(u.totalTokens) || inputTokens + cachedInputTokens + cacheWriteInputTokens + outputTokens + reasoningOutputTokens;
      lastUsage = {
        inputTokens,
        cachedInputTokens,
        cacheWriteInputTokens,
        outputTokens,
        reasoningOutputTokens,
        totalTokens,
      };
      const combinedTotal = totalUsage
        ? {
            inputTokens: totalUsage.inputTokens + lastUsage.inputTokens,
            cachedInputTokens: totalUsage.cachedInputTokens + lastUsage.cachedInputTokens,
            cacheWriteInputTokens: totalUsage.cacheWriteInputTokens + lastUsage.cacheWriteInputTokens,
            outputTokens: totalUsage.outputTokens + lastUsage.outputTokens,
            reasoningOutputTokens: totalUsage.reasoningOutputTokens + lastUsage.reasoningOutputTokens,
            totalTokens: totalUsage.totalTokens + lastUsage.totalTokens,
          }
        : lastUsage;
      this.emit(
        "thread/tokenUsage/updated",
        this.scoped({
          tokenUsage: {
            last: lastUsage,
            total: combinedTotal,
            modelContextWindow: this.contextWindow ?? 1_048_576,
          },
        }),
      );
      lastUsage = combinedTotal;
    }

    const turn = this.snapshot(true);
    if (this.status === "failed") {
      turn.error = {
        message: errorMessage ?? "Antigravity turn failed",
        codexErrorInfo: null,
        additionalDetails: null,
        misalignment: null,
      };
    }
    this.emit("turn/completed", { threadId: this.threadId, turn: this.snapshot(false) });
    return { turn, usage: lastUsage };
  }
}

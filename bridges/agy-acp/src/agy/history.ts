import type { ThreadItem } from "@mimi/appserver-kit/protocol/codex/v2/ThreadItem.ts";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { TurnStatus } from "@mimi/appserver-kit/protocol/codex/v2/TurnStatus.ts";
import type { UserInput } from "@mimi/appserver-kit/protocol/codex/v2/UserInput.ts";
import type { AcpSessionUpdate } from "../acp/types.ts";
import { acpToolToThreadItem, formatPlanMarkdown, mergeToolState, type AcpToolState } from "./tools.ts";

interface TurnBuilder {
  id: string;
  items: ThreadItem[];
  userTextIndex: number | null;
  openThoughtIndex: number | null;
  openMessageIndex: number | null;
  planIndex: number | null;
  toolIndices: Map<string, number>;
  toolStates: Map<string, AcpToolState>;
}

function userInputFromContent(content: { type: string; text?: string; data?: string; mimeType?: string } | undefined): UserInput | undefined {
  if (!content) return undefined;
  if (content.type === "text" && typeof content.text === "string") {
    return { type: "text", text: content.text, text_elements: [] };
  }
  if (content.type === "image" && typeof content.data === "string") {
    return { type: "image", url: `data:${content.mimeType || "image/png"};base64,${content.data}` };
  }
  return undefined;
}

/**
 * 把 `session/load` 回放的 `session/update` 序列按用户消息边界切分为标准 `Turn[]`。
 */
export function updatesToTurns(
  sessionId: string,
  cwd: string,
  updates: readonly AcpSessionUpdate[],
  running = false,
): Turn[] {
  const turns: TurnBuilder[] = [];
  let current: TurnBuilder | undefined;
  let seq = 0;

  const nextTurn = (): TurnBuilder => {
    const index = turns.length + 1;
    const draft: TurnBuilder = {
      id: `${sessionId}:turn:${index}`,
      items: [],
      userTextIndex: null,
      openThoughtIndex: null,
      openMessageIndex: null,
      planIndex: null,
      toolIndices: new Map(),
      toolStates: new Map(),
    };
    turns.push(draft);
    current = draft;
    return draft;
  };

  for (const update of updates) {
    switch (update.sessionUpdate) {
      case "user_message_chunk": {
        const input = userInputFromContent(update.content);
        if (!input) break;
        // 连续的 user_message_chunk（还没有产生任何助手或工具输出）合并进同一条 userMessage。
        if (!current || current.items.some((item) => item.type !== "userMessage")) {
          nextTurn();
        }
        const turn = current!;
        if (turn.userTextIndex !== null) {
          const existing = turn.items[turn.userTextIndex]!;
          if (existing.type === "userMessage") {
            const last = existing.content[existing.content.length - 1];
            if (last?.type === "text" && input.type === "text") {
              last.text += input.text;
            } else {
              existing.content.push(input);
            }
          }
        } else {
          seq += 1;
          turn.userTextIndex = turn.items.length;
          turn.items.push({
            type: "userMessage",
            id: `${sessionId}:item:${seq}`,
            clientId: null,
            content: [input],
          });
        }
        break;
      }

      case "agent_thought_chunk": {
        const text = update.content?.type === "text" ? (update.content.text ?? "") : "";
        if (!text) break;
        const turn = current ?? nextTurn();
        turn.openMessageIndex = null;
        if (turn.openThoughtIndex !== null) {
          const item = turn.items[turn.openThoughtIndex]!;
          if (item.type === "reasoning") {
            item.content = [`${item.content[0] ?? ""}${text}`];
          }
        } else {
          seq += 1;
          turn.openThoughtIndex = turn.items.length;
          turn.items.push({
            type: "reasoning",
            id: `${sessionId}:item:${seq}`,
            summary: [],
            content: [text],
          });
        }
        break;
      }

      case "agent_message_chunk": {
        const text = update.content?.type === "text" ? (update.content.text ?? "") : "";
        if (!text) break;
        const turn = current ?? nextTurn();
        turn.openThoughtIndex = null;
        if (turn.openMessageIndex !== null) {
          const item = turn.items[turn.openMessageIndex]!;
          if (item.type === "agentMessage") {
            item.text += text;
          }
        } else {
          seq += 1;
          turn.openMessageIndex = turn.items.length;
          turn.items.push({
            type: "agentMessage",
            id: `${sessionId}:item:${seq}`,
            text,
            phase: null,
            memoryCitation: null,
            delivery: null,
            questions: null,
          });
        }
        break;
      }

      case "tool_call":
      case "tool_call_update": {
        const toolCallId = typeof update.toolCallId === "string" ? update.toolCallId : "";
        if (!toolCallId) break;
        const turn = current ?? nextTurn();
        turn.openThoughtIndex = null;
        turn.openMessageIndex = null;
        const merged = mergeToolState(turn.toolStates.get(toolCallId), {
          toolCallId,
          title: typeof update.title === "string" ? update.title : undefined,
          kind: typeof update.kind === "string" ? update.kind : undefined,
          status: typeof update.status === "string" ? update.status : undefined,
          content: Array.isArray(update.content) ? update.content : undefined,
          locations: Array.isArray(update.locations) ? update.locations : undefined,
          rawInput: update.rawInput && typeof update.rawInput === "object" ? (update.rawInput as Record<string, unknown>) : undefined,
          rawOutput: update.rawOutput,
        });
        turn.toolStates.set(toolCallId, merged);
        const existingIndex = turn.toolIndices.get(toolCallId);
        const item = acpToolToThreadItem(merged, cwd, true);
        if (existingIndex !== undefined) {
          turn.items[existingIndex] = item;
        } else {
          turn.toolIndices.set(toolCallId, turn.items.length);
          turn.items.push(item);
        }
        break;
      }

      case "plan": {
        const entries = Array.isArray(update.entries) ? update.entries : [];
        const markdown = formatPlanMarkdown(entries);
        if (!markdown) break;
        const turn = current ?? nextTurn();
        if (turn.planIndex !== null) {
          const existing = turn.items[turn.planIndex]!;
          if (existing.type === "plan") existing.text = markdown;
        } else {
          seq += 1;
          turn.planIndex = turn.items.length;
          turn.items.push({ type: "plan", id: `${sessionId}:plan:${seq}`, text: markdown });
        }
        break;
      }
    }
  }

  const lastTurn = turns[turns.length - 1];
  return turns.map((draft) => {
    const isActiveTurn = running && draft === lastTurn;
    const finalizedItems = draft.items.map((item) => {
      const state = draft.toolStates.get(item.id);
      if (!state) return item;
      return acpToolToThreadItem(state, cwd, isActiveTurn);
    });
    const status: TurnStatus = isActiveTurn ? "inProgress" : "completed";
    return {
      id: draft.id,
      rootTurnId: null,
      items: finalizedItems,
      itemsView: "full",
      status,
      error: null,
      startedAt: null,
      completedAt: null,
      durationMs: null,
    };
  });
}

export function summarizeTurn(turn: Turn): Turn {
  return {
    ...turn,
    itemsView: "summary",
    items: turn.items.filter((item) => item.type === "userMessage" || item.type === "agentMessage" || item.type === "plan"),
  };
}

import { createSdkMcpServer, tool, type McpServerConfig, type SdkMcpToolDefinition } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

export const MIMI_TURN_HINT_TOOL_NAMES = new Set([
  "mcp__ccd_turn__wrap_up",
  "mcp__ccd_session__start_session",
]);

export const MIMI_TURN_HINT_SYSTEM_PROMPT = `
At the natural end of a turn, you may call ccd_turn.wrap_up to show a concise recap, one useful next-step question, and up to three suggested reply actions. Use it only after completing the user's current request.

When a clearly separate follow-up would benefit from its own conversation, you may call ccd_session.start_session once to propose a title and an initial prompt. These tools only create cards for the user. They never send a reply, continue work, or start a conversation by themselves. A new conversation starts only after the user explicitly chooses Start.
`.trim();

export interface MimiTaskProposalInput {
  title: string;
  prompt: string;
  initiation?: string;
}

export interface MimiTaskProposalStore {
  recordTaskProposal(parentThreadId: string, cwd: string, input: MimiTaskProposalInput): Promise<string>;
}

const action = z.object({
  label: z.string().trim().min(1).max(120),
  message: z.string().trim().min(1).max(2_000),
});

/** 工具只记录展示数据；创建子会话始终由用户点击后的 thread/start 完成。 */
export function mimiTurnHintTools(
  threadId: string,
  cwd: string,
  store: MimiTaskProposalStore,
): Array<SdkMcpToolDefinition<any>> {
  return [
    tool(
      "wrap_up",
      "Show a completed-turn recap and optional suggested replies. This does not send a reply or continue work.",
      {
        recap: z.string().trim().min(1).max(4_000).optional(),
        ask: z.string().trim().min(1).max(1_000).optional(),
        actions: z.array(action).max(3).optional(),
      },
      async () => ({ content: [{ type: "text", text: "Turn hint recorded." }] }),
      {
        annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
        alwaysLoad: true,
      },
    ),
    tool(
      "start_session",
      "Propose a separate follow-up conversation. This only records a card; it never starts the conversation.",
      {
        title: z.string().trim().min(1).max(200),
        prompt: z.string().trim().min(1).max(4_000),
        initiation: z.string().trim().min(1).max(100).optional(),
      },
      async (input) => {
        const proposalId = await store.recordTaskProposal(threadId, cwd, input);
        // Agent SDK 把 structuredContent 原样写入 tool_result.content。投影层再和 Overlay
        // 中的随机 proposal ID 对照；不能根据模型可写的 arguments 判断来源。
        return {
          content: [{ type: "text", text: "Task proposal recorded." }],
          structuredContent: {
            mimi_task_proposal: { version: 1, proposal_id: proposalId },
          },
        };
      },
      {
        annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false },
        alwaysLoad: true,
      },
    ),
  ];
}

export function mimiTurnHintServers(
  threadId: string,
  cwd: string,
  store: MimiTaskProposalStore,
): Record<string, McpServerConfig> {
  const tools = mimiTurnHintTools(threadId, cwd, store);
  return {
    ccd_turn: createSdkMcpServer({ name: "ccd_turn", version: "1.0.0", tools: [tools[0]!], alwaysLoad: true }),
    ccd_session: createSdkMcpServer({ name: "ccd_session", version: "1.0.0", tools: [tools[1]!], alwaysLoad: true }),
  };
}

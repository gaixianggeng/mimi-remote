// 适配器对 Agent SDK 的全部依赖集中在这里，测试可以替换成假实现。
import {
  getSessionInfo,
  getSessionMessages,
  listSessions,
  renameSession,
  type SDKSessionInfo,
} from "@anthropic-ai/claude-agent-sdk";
import type { HistoryMessage } from "./history.ts";

export type SessionInfo = SDKSessionInfo;

export interface ClaudeSessions {
  list(options: { dir?: string }): Promise<SessionInfo[]>;
  info(sessionId: string): Promise<SessionInfo | undefined>;
  messages(sessionId: string): Promise<HistoryMessage[]>;
  /** 与 CLI `/rename` 相同：往 transcript 追加一条 custom-title 记录。 */
  rename(sessionId: string, title: string, dir?: string): Promise<void>;
}

export const sdkSessions: ClaudeSessions = {
  list: (options) => listSessions(options.dir ? { dir: options.dir, includeWorktrees: true } : {}),
  info: (sessionId) => getSessionInfo(sessionId),
  messages: async (sessionId) => (await getSessionMessages(sessionId)) as unknown as HistoryMessage[],
  rename: (sessionId, title, dir) => renameSession(sessionId, title, dir ? { dir } : undefined),
};

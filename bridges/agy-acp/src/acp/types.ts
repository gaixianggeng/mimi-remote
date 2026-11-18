// 标准 ACP (Agent Client Protocol) v1 消息类型定义。
// 保持纯协议层（与具体 CLI 无关），后续接入任意 ACP 生态 Agent 均可直接复用。

export interface AcpClientInfo {
  name: string;
  version: string;
}

export interface AcpInitializeParams {
  protocolVersion: number;
  /**
   * 关键契约：Mimi 是远程移动端客户端，不是拥有未保存 Buffer 的本地 IDE。
   * 默认传 `{}`（不声明 `fs` 与 `terminal` 反向委托），让 Agent 100% 运行其内置原生工具链、
   * 沙箱、Hooks 与子代理，同时照常接收 `session/update` 过程帧与 `session/request_permission`。
   */
  clientCapabilities: Record<string, unknown>;
  clientInfo: AcpClientInfo;
}

export interface AcpInitializeResult {
  protocolVersion: number;
  agentInfo?: { name?: string; version?: string; title?: string };
  agentCapabilities?: {
    loadSession?: boolean;
    promptCapabilities?: { image?: boolean; audio?: boolean; embeddedContext?: boolean };
    sessionCapabilities?: Record<string, unknown>;
  };
  authMethods?: Array<{ id: string; name?: string; description?: string }>;
}

export interface AcpSessionSummary {
  sessionId: string;
  cwd?: string;
  title?: string | null;
  updatedAt?: string | null;
}

export interface AcpModelOption {
  modelId: string;
  name: string;
  description?: string;
}

export interface AcpModeOption {
  id: string;
  name: string;
  description?: string;
}

export interface AcpConfigSelectOption {
  value: string;
  name: string;
  description?: string;
}

export interface AcpConfigOption {
  id: string;
  name: string;
  category?: string;
  type: "select" | string;
  currentValue: string;
  options?: AcpConfigSelectOption[];
}

export interface AcpSessionOpenResult {
  sessionId: string;
  models?: {
    availableModels?: AcpModelOption[];
    currentModelId?: string;
  };
  modes?: {
    availableModes?: AcpModeOption[];
    currentModeId?: string;
  };
  configOptions?: AcpConfigOption[];
  _meta?: Record<string, unknown>;
}

export type AcpContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string; uri?: string }
  | { type: "resource_link"; uri: string; name?: string; mimeType?: string; title?: string }
  | {
      type: "resource";
      resource: { uri: string; mimeType?: string; text?: string; blob?: string };
    };

export interface AcpAvailableCommand {
  name: string;
  description?: string;
  input?: { hint?: string };
}

export type AcpToolCallKind =
  | "read"
  | "edit"
  | "delete"
  | "move"
  | "search"
  | "execute"
  | "think"
  | "fetch"
  | "switch_mode"
  | "other"
  | string;

export type AcpToolCallStatus = "pending" | "in_progress" | "completed" | "failed" | string;

export type AcpToolCallContent =
  | {
      type: "content";
      content?: { type: string; text?: string; data?: string; mimeType?: string };
    }
  | {
      type: "diff";
      path: string;
      oldText?: string | null;
      newText?: string;
    }
  | {
      type: "terminal";
      terminalId: string;
    };

export interface AcpToolCallLocation {
  path: string;
  line?: number;
}

export interface AcpPlanEntry {
  content: string;
  priority?: "high" | "medium" | "low" | string;
  status?: "pending" | "in_progress" | "completed" | string;
}

export type AcpSessionUpdate =
  | {
      sessionUpdate: "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk";
      content?: { type: string; text?: string; data?: string; mimeType?: string };
    }
  | {
      sessionUpdate: "tool_call" | "tool_call_update";
      toolCallId: string;
      title?: string;
      kind?: AcpToolCallKind;
      status?: AcpToolCallStatus;
      content?: AcpToolCallContent[];
      locations?: AcpToolCallLocation[];
      rawInput?: Record<string, unknown>;
      rawOutput?: unknown;
    }
  | {
      sessionUpdate: "plan";
      entries?: AcpPlanEntry[];
    }
  | {
      sessionUpdate: "available_commands_update";
      availableCommands?: AcpAvailableCommand[];
    }
  | {
      sessionUpdate: "current_mode_update";
      currentModeId?: string;
    }
  | {
      sessionUpdate: "config_option_update";
      configOptions?: AcpConfigOption[];
    }
  | {
      sessionUpdate: "session_info_update";
      title?: string | null;
      updatedAt?: string | null;
    }
  | {
      sessionUpdate: "usage_update";
      used?: number;
      size?: number;
    };

export interface AcpPermissionOption {
  optionId: string;
  name: string;
  kind: "allow_once" | "allow_always" | "reject_once" | "reject_always" | string;
}

export interface AcpRequestPermissionParams {
  sessionId: string;
  toolCall: {
    toolCallId: string;
    title?: string;
    kind?: AcpToolCallKind;
    status?: AcpToolCallStatus;
    content?: AcpToolCallContent[];
    locations?: AcpToolCallLocation[];
    rawInput?: Record<string, unknown>;
  };
  options: AcpPermissionOption[];
}

export type AcpRequestPermissionResult = {
  outcome: { outcome: "selected"; optionId: string } | { outcome: "cancelled" };
};

export interface AcpPromptUsage {
  inputTokens?: number;
  outputTokens?: number;
  cachedReadTokens?: number;
  cachedWriteTokens?: number;
  thoughtTokens?: number;
  totalTokens?: number;
}

export interface AcpPromptResult {
  stopReason: "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" | "cancelled" | string;
  usage?: AcpPromptUsage;
}

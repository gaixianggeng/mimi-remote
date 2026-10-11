// turn / thread 参数 → Claude 运行设置。映射规则与旧 bridge 一致，iOS 的权限档位语义不变。
import type { EffortLevel, PermissionMode } from "@anthropic-ai/claude-agent-sdk";

type Params = Record<string, unknown>;

export interface RunSettings {
  model: string | undefined;
  effort: EffortLevel | undefined;
  permissionMode: PermissionMode;
}

function collaborationModeName(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    const mode = (value as Params).mode;
    return typeof mode === "string" ? mode : undefined;
  }
  return undefined;
}

function sandboxType(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    const type = (value as Params).type;
    return typeof type === "string" ? type : undefined;
  }
  return undefined;
}

/**
 * - Plan 协作模式或只读沙箱 → plan
 * - 显式完全访问且审批为 never → bypassPermissions（孤立的 never 不提升档位）
 * - 按需审批 + 自动审核 → auto
 * - 其余 → default
 */
export function permissionModeFor(params: Params): PermissionMode {
  if (collaborationModeName(params.collaborationMode) === "plan") return "plan";
  const sandbox = sandboxType(params.sandboxPolicy ?? params.sandbox);
  if (sandbox === "readOnly" || sandbox === "read-only") return "plan";
  if (params.approvalPolicy === "never" && (sandbox === "dangerFullAccess" || sandbox === "danger-full-access")) {
    return "bypassPermissions";
  }
  const reviewer = params.approvalsReviewer;
  // guardian_subagent 是 auto_review 的旧名。
  if (params.approvalPolicy === "on-request" && (reviewer === "auto_review" || reviewer === "guardian_subagent")) {
    return "auto";
  }
  return "default";
}

const EFFORTS = new Set<EffortLevel>(["low", "medium", "high", "xhigh", "max"]);

function effortFor(value: unknown): EffortLevel | undefined {
  if (typeof value !== "string") return undefined;
  // Codex 的 minimal 在 Claude 上没有对应档位，按最低档处理。
  if (value === "minimal" || value === "none") return "low";
  return EFFORTS.has(value as EffortLevel) ? (value as EffortLevel) : undefined;
}

export function runSettingsFor(params: Params): RunSettings {
  const model = typeof params.model === "string" && params.model.trim() ? params.model.trim() : undefined;
  return { model, effort: effortFor(params.effort), permissionMode: permissionModeFor(params) };
}

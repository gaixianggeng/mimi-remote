import path from "node:path";
import { RpcError } from "@mimi/appserver-kit/rpc/frames.ts";

type Params = Record<string, unknown>;

export type AgyModeId = "default" | "accept-edits" | "auto" | "plan";

export type ExecutionPolicy =
  | { type: "dangerFullAccess" }
  | { type: "readOnly"; networkAccess: boolean }
  | { type: "workspaceWrite"; writableRoots?: string[]; networkAccess: boolean };

export interface AgyRunSettings {
  model: string | undefined;
  effort: string | undefined;
  mode: AgyModeId;
  executionPolicy: ExecutionPolicy;
}

export interface PersistedSessionPermissions {
  mode: AgyModeId;
  executionPolicy: ExecutionPolicy;
  approvalPolicy: string;
  approvalsReviewer: string;
}

const KNOWN_EFFORTS = new Set(["low", "medium", "high", "xhigh"]);
const KNOWN_MODES = new Set<AgyModeId>(["default", "accept-edits", "auto", "plan"]);

export function isAgyModeId(value: unknown): value is AgyModeId {
  return typeof value === "string" && KNOWN_MODES.has(value as AgyModeId);
}

export function collaborationModeName(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    const mode = (value as Params).mode;
    return typeof mode === "string" ? mode : undefined;
  }
  return undefined;
}

export function hasExplicitPermissionParams(params: Params): boolean {
  return (
    params.approvalPolicy !== undefined
    || params.approvalsReviewer !== undefined
    || params.sandboxPolicy !== undefined
    || params.sandbox !== undefined
  );
}

export function permissionMetaFor(
  executionPolicy: ExecutionPolicy,
  mode: AgyModeId,
): { approvalPolicy: string; approvalsReviewer: string; sandbox: ExecutionPolicy } {
  if (executionPolicy.type === "dangerFullAccess") {
    return { approvalPolicy: "never", approvalsReviewer: "user", sandbox: executionPolicy };
  }
  if (executionPolicy.type === "readOnly" || mode === "plan") {
    return {
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandbox: executionPolicy.type === "readOnly" ? executionPolicy : { type: "readOnly", networkAccess: false },
    };
  }
  if (mode === "accept-edits") {
    return { approvalPolicy: "on-request", approvalsReviewer: "accept_edits", sandbox: executionPolicy };
  }
  if (mode === "auto") {
    return { approvalPolicy: "on-request", approvalsReviewer: "auto_review", sandbox: executionPolicy };
  }
  return { approvalPolicy: "on-request", approvalsReviewer: "user", sandbox: executionPolicy };
}

export function persistedPermissionsFor(params: Params, executionPolicy: ExecutionPolicy): PersistedSessionPermissions {
  // 持久化的会话权限只记录基础权限档位，不把单轮临时 collaborationMode=plan 固化成永久权限。
  const baseMode = agyModeFor({ ...params, collaborationMode: undefined }, executionPolicy);
  const meta = permissionMetaFor(executionPolicy, baseMode);
  return {
    mode: baseMode,
    executionPolicy,
    approvalPolicy: meta.approvalPolicy,
    approvalsReviewer: meta.approvalsReviewer,
  };
}

export function executionPolicyFor(raw: unknown): ExecutionPolicy {
  const value = typeof raw === "string" ? { type: raw } : (raw ?? { type: "workspaceWrite" });
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw RpcError.invalidParams("sandboxPolicy 无效");
  }
  const policy = value as Params;
  if (policy.type === "dangerFullAccess" || policy.type === "danger-full-access") {
    return { type: "dangerFullAccess" };
  }
  if (policy.networkAccess !== undefined && typeof policy.networkAccess !== "boolean") {
    throw RpcError.invalidParams("sandboxPolicy.networkAccess 必须为布尔值");
  }
  const networkAccess = policy.networkAccess === true;
  if (policy.type === "readOnly" || policy.type === "read-only") {
    return { type: "readOnly", networkAccess };
  }
  if (policy.type !== "workspaceWrite" && policy.type !== "workspace-write") {
    throw RpcError.invalidParams("不支持此 sandboxPolicy");
  }
  const roots = policy.writableRoots;
  if (
    roots !== undefined
    && (!Array.isArray(roots) || !roots.every((root) => typeof root === "string" && path.isAbsolute(root)))
  ) {
    throw RpcError.invalidParams("sandboxPolicy.writableRoots 必须为绝对路径数组");
  }
  return {
    type: "workspaceWrite",
    ...(roots !== undefined ? { writableRoots: [...(roots as string[])] } : {}),
    networkAccess,
  };
}

/**
 * Mimi 权限与协作模式 → Antigravity 原生 `mode`（D2）：
 * - `collaborationMode == "plan"` 或 `readOnly` 沙箱 → `plan`
 * - `dangerFullAccess` + `approvalPolicy == "never"` → `auto`（启动子进程时附带 `--dangerously-skip-permissions`）
 * - `approvalsReviewer == "accept_edits"` → `accept-edits`
 * - `approvalsReviewer == "auto_review" | "guardian_subagent"` → `auto`
 * - 其余（请求审批） → `default`
 */
export function agyModeFor(params: Params, policy: ExecutionPolicy): AgyModeId {
  if (collaborationModeName(params.collaborationMode) === "plan") {
    return "plan";
  }
  if (policy.type === "readOnly") {
    return "plan";
  }
  if (policy.type === "dangerFullAccess" && params.approvalPolicy === "never") {
    return "auto";
  }
  const reviewer = params.approvalsReviewer;
  if (params.approvalPolicy === "on-request" && reviewer === "accept_edits") {
    return "accept-edits";
  }
  if (params.approvalPolicy === "on-request" && (reviewer === "auto_review" || reviewer === "guardian_subagent")) {
    return "auto";
  }
  return "default";
}

function effortFor(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim().toLowerCase();
  if (!trimmed || trimmed === "none") return undefined;
  if (trimmed === "minimal") return "low";
  if (trimmed === "max") return "xhigh";
  return KNOWN_EFFORTS.has(trimmed) ? trimmed : undefined;
}

export function runSettingsFor(params: Params): AgyRunSettings {
  const model = typeof params.model === "string" && params.model.trim() ? params.model.trim() : undefined;
  const policy = executionPolicyFor(params.sandboxPolicy ?? params.sandbox);
  return {
    model,
    effort: effortFor(params.effort),
    mode: agyModeFor(params, policy),
    executionPolicy: policy,
  };
}

export function sameProcessBoundary(a: ExecutionPolicy, b: ExecutionPolicy): boolean {
  if (a.type !== b.type) return false;
  if (a.type === "workspaceWrite" && b.type === "workspaceWrite") {
    const ar = (a.writableRoots ?? []).join("\0");
    const br = (b.writableRoots ?? []).join("\0");
    return ar === br && a.networkAccess === b.networkAccess;
  }
  if (a.type === "readOnly" && b.type === "readOnly") {
    return a.networkAccess === b.networkAccess;
  }
  return true;
}

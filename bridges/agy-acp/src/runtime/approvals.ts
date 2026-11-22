import type { AcpPermissionOption, AcpRequestPermissionParams, AcpRequestPermissionResult } from "../acp/types.ts";
import { extractDiffChanges, type AcpToolState } from "../agy/tools.ts";

export interface ApprovalContext {
  threadId: string;
  turnId: string;
  cwd: string;
  itemId?: string;
}

export interface ServerApprovalSpec {
  method: string;
  params: Record<string, unknown>;
  toAcpResult(response: unknown): AcpRequestPermissionResult;
}

const MAX_SUMMARY = 4_000;

function summarizeInput(rawInput: Record<string, unknown> | undefined): string {
  if (!rawInput) return "{}";
  const text = JSON.stringify(rawInput);
  return text.length > MAX_SUMMARY ? `${text.slice(0, MAX_SUMMARY)}…` : text;
}

function decisionTag(response: unknown): string {
  const decision = (response as { decision?: unknown } | null)?.decision;
  if (typeof decision === "string") return decision;
  if (decision && typeof decision === "object") return Object.keys(decision)[0] ?? "decline";
  return "decline";
}

function pickOption(options: readonly AcpPermissionOption[], preferredKinds: readonly string[]): string | undefined {
  for (const kind of preferredKinds) {
    const found = options.find((opt) => opt.kind === kind);
    if (found) return found.optionId;
  }
  return undefined;
}

export function selectPermissionOption(
  options: readonly AcpPermissionOption[],
  kind: "allow_once" | "allow_always" | "allow_any" | "reject_once",
): AcpRequestPermissionResult {
  const order =
    kind === "allow_any"
      ? ["allow_always", "allow_once"]
      : kind === "allow_always"
        ? ["allow_always"]
        : kind === "allow_once"
          ? ["allow_once"]
          : ["reject_once", "reject_always"];
  const optionId = pickOption(options, order);
  return optionId ? { outcome: { outcome: "selected", optionId } } : { outcome: { outcome: "cancelled" } };
}

const CROSS_SESSION_SCOPE_PATTERNS: readonly RegExp[] = [
  /\bevery\s+(conversation|session|chat|thread)\b/i,
  /\ball\s+(conversations|sessions|chats|threads|projects)\b/i,
  /\bfuture\s+(conversations|sessions|chats|threads)\b/i,
  /\bother\s+(conversations|sessions|chats|threads)\b/i,
  /\bremember\s+for\s+every\b/i,
  /\b(global|globally|permanent|permanently|forever|settings\.json|workspace|project)\b/i,
  /跨会话|跨对话|所有会话|全部会话|后续会话|永久|记住|保存至|项目范围|工作区范围/,
];

// ACP 规范约定：optionId 只是不透明标识符，绝不可用于推断授权范围；
// 只有运行时通过结构化 scope 元数据，或通过无歧义的完整单会话范围文案明确承诺仅限本会话时，
// 才允许映射为 acceptForSession（B01/B05）。
const EXPLICIT_SESSION_ONLY_NAME_PATTERNS: readonly RegExp[] = [
  /^(?:allow|approve|permit)(?:\s+always)?\s+(?:for\s+)?(?:this|the\s+current|current)\s+(?:session|conversation|chat|thread)(?:\s+only)?\.?$/i,
  /^(?:allow|approve|permit)\s+in\s+(?:this|the\s+current|current)\s+(?:session|conversation|chat|thread)(?:\s+only)?\.?$/i,
  /^(?:this\s+|current\s+)?(?:session|conversation)[\s_-]?only\.?$/i,
  /^(?:仅限?|只在?)?(?:本|当前|本次)(?:会话|对话)(?:内)?(?:允许|批准|放行)(?:（仅限本会话）)?$/,
  /^(?:允许|批准)(?:本|当前|本次)(?:会话|对话)(?:（仅限本会话）)?$/,
];

const TRUSTED_SESSION_SCOPES = new Set(["session", "this_session", "current_session", "session_only"]);
const EXPLICIT_PERSISTENT_SCOPES = new Set(["always", "persistent", "global", "workspace", "project", "cross_session", "all_sessions"]);

type AllowAlwaysScopeClassification = "session" | "persistent" | "uncertain";

function readStructuredOptionScope(option: AcpPermissionOption): string | undefined {
  const direct = typeof option.scope === "string" ? option.scope.trim().toLowerCase() : "";
  if (direct) return direct;
  const metaScope = option._meta && typeof option._meta.scope === "string" ? option._meta.scope.trim().toLowerCase() : "";
  return metaScope || undefined;
}

function classifyAllowAlwaysOption(option: AcpPermissionOption): AllowAlwaysScopeClassification {
  if (option.kind !== "allow_always") return "uncertain";
  const name = (option.name ?? "").trim();
  const structuredScope = readStructuredOptionScope(option);
  const nameHasCrossSession = name.length > 0 && CROSS_SESSION_SCOPE_PATTERNS.some((pattern) => pattern.test(name));

  if (structuredScope) {
    if (TRUSTED_SESSION_SCOPES.has(structuredScope) && !nameHasCrossSession) {
      return "session";
    }
    if (EXPLICIT_PERSISTENT_SCOPES.has(structuredScope)) {
      return "persistent";
    }
  }

  if (nameHasCrossSession) {
    return "persistent";
  }
  if (name.length > 0 && EXPLICIT_SESSION_ONLY_NAME_PATTERNS.some((pattern) => pattern.test(name))) {
    return "session";
  }
  return "uncertain";
}

export function serverApprovalFor(
  request: AcpRequestPermissionParams,
  context: ApprovalContext,
): ServerApprovalSpec {
  const tool = request.toolCall;
  const kind = tool.kind ?? "execute";
  const state: AcpToolState = {
    toolCallId: tool.toolCallId,
    title: tool.title,
    kind: tool.kind,
    status: tool.status,
    content: tool.content,
    locations: tool.locations,
    rawInput: tool.rawInput,
  };
  const allowOnceOption = request.options.find((opt) => opt.kind === "allow_once");
  const sessionAllowOption = request.options.find(
    (opt) => opt.kind === "allow_always" && classifyAllowAlwaysOption(opt) === "session",
  );
  const persistentAllowOption = request.options.find(
    (opt) => opt.kind === "allow_always" && classifyAllowAlwaysOption(opt) !== "session",
  );
  const persistentClassification = persistentAllowOption
    ? classifyAllowAlwaysOption(persistentAllowOption)
    : undefined;
  const rejectOption =
    request.options.find((opt) => opt.kind === "reject_once")
    ?? request.options.find((opt) => opt.kind === "reject_always");

  const availableDecisions: string[] = [];
  const decisionOptionIds = new Map<string, string>();
  if (allowOnceOption) {
    availableDecisions.push("accept");
    decisionOptionIds.set("accept", allowOnceOption.optionId);
  }
  if (sessionAllowOption) {
    availableDecisions.push("acceptForSession");
    decisionOptionIds.set("acceptForSession", sessionAllowOption.optionId);
  }
  if (persistentAllowOption) {
    availableDecisions.push("acceptAlways");
    decisionOptionIds.set("acceptAlways", persistentAllowOption.optionId);
  }
  availableDecisions.push("decline");

  const alwaysAllowLabel = persistentAllowOption?.name?.trim() || null;
  const alwaysAllowScopeUncertain = persistentAllowOption ? persistentClassification === "uncertain" : undefined;

  const common = {
    threadId: context.threadId,
    turnId: context.turnId,
    itemId: context.itemId ?? tool.toolCallId,
    startedAtMs: Date.now(),
    reason: tool.title ?? null,
    inputSummary: summarizeInput(tool.rawInput),
    toolName: tool.title || kind,
    ...(alwaysAllowLabel ? { alwaysAllowLabel } : {}),
    ...(alwaysAllowScopeUncertain !== undefined ? { alwaysAllowScopeUncertain } : {}),
  };

  // B01/B05 严格校验：只接受本次请求实际公布的决议并绑定到精确 optionId，
  // 拒绝未公布的决议及旧别名（如 acceptWithPermissionUpdate / acceptWithExecpolicyAmendment），
  // 绝不把跨会话持久授权（如 "Remember for every conversation"）伪装或放行给 acceptForSession。
  const toAcpResult = (response: unknown): AcpRequestPermissionResult => {
    const tag = decisionTag(response);
    if (tag === "cancel") {
      return { outcome: { outcome: "cancelled" } };
    }
    if (tag === "decline") {
      return rejectOption
        ? { outcome: { outcome: "selected", optionId: rejectOption.optionId } }
        : { outcome: { outcome: "cancelled" } };
    }
    if (!availableDecisions.includes(tag)) {
      return { outcome: { outcome: "cancelled" } };
    }
    const optionId = decisionOptionIds.get(tag);
    return optionId ? { outcome: { outcome: "selected", optionId } } : { outcome: { outcome: "cancelled" } };
  };

  const changes = extractDiffChanges(state);
  if (kind === "edit" || kind === "delete" || kind === "move" || changes.length > 0) {
    const first = changes[0];
    return {
      method: "item/fileChange/requestApproval",
      params: {
        ...common,
        grantRoot: null,
        availableDecisions,
        path: first?.path ?? tool.locations?.[0]?.path ?? null,
        diff: first?.diff ?? "",
      },
      toAcpResult,
    };
  }

  const rawCommand =
    (typeof tool.rawInput?.CommandLine === "string" && tool.rawInput.CommandLine)
    || (typeof tool.rawInput?.command === "string" && tool.rawInput.command)
    || tool.title
    || `${kind} ${summarizeInput(tool.rawInput)}`;

  return {
    method: "item/commandExecution/requestApproval",
    params: {
      ...common,
      kind: "command",
      approvalId: null,
      environmentId: null,
      command: rawCommand,
      cwd: context.cwd,
      availableDecisions,
      path: tool.locations?.[0]?.path ?? null,
      permissionSuggestions: [],
    },
    toAcpResult,
  };
}

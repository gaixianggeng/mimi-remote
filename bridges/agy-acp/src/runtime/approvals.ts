import type { AcpPermissionOption, AcpRequestPermissionParams, AcpRequestPermissionResult } from "../acp/types.ts";
import { extractDiffChanges, type AcpToolState } from "../agy/tools.ts";

export interface ApprovalContext {
  threadId: string;
  turnId: string;
  cwd: string;
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
  const hasOnceOption = request.options.some((opt) => opt.kind === "allow_once");
  const hasAlwaysOption = request.options.some((opt) => opt.kind === "allow_always");
  const availableDecisions: string[] = [];
  if (hasOnceOption) availableDecisions.push("accept");
  if (hasAlwaysOption) availableDecisions.push("acceptForSession");
  availableDecisions.push("decline");

  const common = {
    threadId: context.threadId,
    turnId: context.turnId,
    itemId: tool.toolCallId,
    startedAtMs: Date.now(),
    reason: tool.title ?? null,
    inputSummary: summarizeInput(tool.rawInput),
    toolName: tool.title || kind,
  };

  const toAcpResult = (response: unknown): AcpRequestPermissionResult => {
    switch (decisionTag(response)) {
      case "acceptForSession":
      case "acceptWithPermissionUpdate":
      case "acceptWithExecpolicyAmendment":
        return selectPermissionOption(request.options, "allow_always");
      case "accept":
        return selectPermissionOption(request.options, "allow_once");
      case "cancel":
        return { outcome: { outcome: "cancelled" } };
      default:
        return selectPermissionOption(request.options, "reject_once");
    }
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

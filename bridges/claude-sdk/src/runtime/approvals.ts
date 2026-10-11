// Claude 的权限询问（canUseTool）→ app-server 服务端请求，以及客户端答复 → PermissionResult。
// 请求形状保留旧 bridge 的字段（availableDecisions、inputSummary、toolName 等），iOS 的
// 审批卡片按这些字段渲染；同时补齐 Codex 协议的必填字段。
import type { PermissionResult, PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";
import { fileChanges } from "../claude/tools.ts";

export interface ApprovalContext {
  threadId: string;
  turnId: string;
  cwd: string;
}

export interface ToolPermissionRequest {
  toolName: string;
  input: Record<string, unknown>;
  toolUseID: string;
  suggestions?: PermissionUpdate[];
  decisionReason?: string;
  blockedPath?: string;
}

export interface ServerRequestSpec {
  method: string;
  params: Record<string, unknown>;
  toResult(response: unknown): PermissionResult;
}

const FILE_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);
const MAX_SUMMARY = 4_000;

function summary(input: Record<string, unknown>): string {
  const text = JSON.stringify(input);
  return text.length > MAX_SUMMARY ? `${text.slice(0, MAX_SUMMARY)}…` : text;
}

function decisionTag(response: unknown): string {
  const decision = (response as { decision?: unknown } | null)?.decision;
  if (typeof decision === "string") return decision;
  if (decision && typeof decision === "object") return Object.keys(decision)[0] ?? "decline";
  return "decline";
}

export const DECLINED_MESSAGE = "user declined this tool call";

function approvalResult(request: ToolPermissionRequest, response: unknown): PermissionResult {
  switch (decisionTag(response)) {
    case "acceptWithPermissionUpdate":
      return request.suggestions?.length
        ? { behavior: "allow", updatedInput: request.input, updatedPermissions: request.suggestions }
        : { behavior: "allow", updatedInput: request.input };
    case "accept":
    case "acceptForSession":
    case "acceptWithExecpolicyAmendment":
    case "applyNetworkPolicyAmendment":
      return { behavior: "allow", updatedInput: request.input };
    case "cancel":
      return { behavior: "deny", message: "user cancelled the turn", interrupt: true };
    default:
      return { behavior: "deny", message: DECLINED_MESSAGE };
  }
}

interface Question {
  question?: unknown;
  header?: unknown;
  multiSelect?: unknown;
  options?: Array<{ label?: unknown; description?: unknown }>;
}

function userInputRequest(request: ToolPermissionRequest, context: ApprovalContext): ServerRequestSpec {
  const questions = (Array.isArray(request.input.questions) ? request.input.questions : []) as Question[];
  return {
    method: "item/tool/requestUserInput",
    params: {
      threadId: context.threadId,
      turnId: context.turnId,
      itemId: request.toolUseID,
      questions: questions.map((question, index) => ({
        id: `question-${index}`,
        header: String(question.header ?? ""),
        question: String(question.question ?? ""),
        multiSelect: question.multiSelect === true,
        isOther: true,
        isSecret: false,
        options: (question.options ?? []).map((option) => ({
          label: String(option.label ?? ""),
          description: String(option.description ?? ""),
        })),
      })),
    },
    toResult(response) {
      const answers = (response as { answers?: Record<string, { answers?: unknown }> } | null)?.answers;
      if (!answers || typeof answers !== "object") {
        return { behavior: "deny", message: "user cancelled the question", interrupt: true };
      }
      // Claude 按问题原文索引答案；单选给字符串，多选给数组。
      const byQuestion: Record<string, string | string[]> = {};
      questions.forEach((question, index) => {
        const picked = answers[`question-${index}`]?.answers;
        if (!Array.isArray(picked) || !picked.length) return;
        const labels = picked.map(String);
        byQuestion[String(question.question ?? "")] = labels.length === 1 ? labels[0]! : labels;
      });
      return { behavior: "allow", updatedInput: { ...request.input, answers: byQuestion } };
    },
  };
}

export function serverRequestFor(request: ToolPermissionRequest, context: ApprovalContext): ServerRequestSpec {
  if (request.toolName === "AskUserQuestion") return userInputRequest(request, context);
  const common = {
    threadId: context.threadId,
    turnId: context.turnId,
    itemId: request.toolUseID,
    startedAtMs: Date.now(),
    reason: request.decisionReason ?? null,
    inputSummary: summary(request.input),
    toolName: request.toolName,
  };
  if (FILE_TOOLS.has(request.toolName)) {
    const [change] = fileChanges(request.toolName, request.input);
    return {
      method: "item/fileChange/requestApproval",
      params: {
        ...common,
        grantRoot: null,
        availableDecisions: ["accept", "decline"],
        path: change?.path ?? null,
        diff: change?.diff ?? "",
      },
      toResult: (response) => approvalResult(request, response),
    };
  }
  const command =
    request.toolName === "Bash" && typeof request.input.command === "string"
      ? request.input.command
      : `${request.toolName} ${summary(request.input)}`;
  return {
    method: "item/commandExecution/requestApproval",
    params: {
      ...common,
      kind: "command",
      approvalId: null,
      environmentId: null,
      command,
      cwd: context.cwd,
      availableDecisions: request.suggestions?.length
        ? ["accept", "acceptWithPermissionUpdate", "decline"]
        : ["accept", "decline"],
      path: request.blockedPath ?? null,
      permissionSuggestions: request.suggestions ?? [],
    },
    toResult: (response) => approvalResult(request, response),
  };
}

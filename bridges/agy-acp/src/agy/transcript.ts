import { open, readFile, stat } from "node:fs/promises";
import path from "node:path";
import type { ThreadItem } from "@mimi/appserver-kit/protocol/codex/v2/ThreadItem.ts";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { TurnStatus } from "@mimi/appserver-kit/protocol/codex/v2/TurnStatus.ts";
import type { UserInput } from "@mimi/appserver-kit/protocol/codex/v2/UserInput.ts";
import { resolveAgyDataPaths, type AgySessionOrigin } from "./env.ts";
import { acpToolToThreadItem, type AcpToolState } from "./tools.ts";

const SAFE_SESSION_ID = /^[A-Za-z0-9._-]+$/;
const EXTERNAL_BUSY_WINDOW_MS = 90_000;
const MAX_MEDIA_BYTES = 4 * 1024 * 1024;
const TAIL_READ_BYTES = 24 * 1024;

interface TranscriptToolCall {
  name?: string;
  args?: Record<string, unknown>;
}

interface TranscriptMedia {
  mime_type?: string;
  uri?: string;
}

interface TranscriptStep {
  step_index?: number;
  source?: string;
  type?: string;
  status?: string;
  created_at?: string;
  content?: string;
  thinking?: string;
  tool_calls?: TranscriptToolCall[];
  media?: TranscriptMedia[];
}

export interface TranscriptActivityInfo {
  path: string;
  size: number;
  mtimeMs: number;
  externallyBusy: boolean;
}

export interface TranscriptTurnSnapshot {
  path: string;
  size: number;
  mtimeMs: number;
  userInputs: string[];
  plannerResponseCount: number;
  stepCount: number;
}

export interface ExternalWriteBaseline {
  userInputCount: number;
  expectedPromptText: string;
  approvalUserInputCount?: number;
  approvalPlannerResponseCount?: number;
}

export interface ExternalWriteDetection {
  detected: boolean;
  reason?: string;
}

function brainDirForOrigin(origin: AgySessionOrigin, env: NodeJS.ProcessEnv): string {
  const paths = resolveAgyDataPaths(env);
  const root = origin === "other" ? paths.otherAppDataRoot : paths.appDataRoot;
  return path.join(root, "brain");
}

export async function resolveTranscriptPath(
  sessionId: string,
  origin: AgySessionOrigin,
  env: NodeJS.ProcessEnv = process.env,
): Promise<string | undefined> {
  if (!SAFE_SESSION_ID.test(sessionId)) return undefined;
  const logsDir = path.join(brainDirForOrigin(origin, env), sessionId, ".system_generated", "logs");
  for (const name of ["transcript_full.jsonl", "transcript.jsonl"]) {
    const candidate = path.join(logsDir, name);
    try {
      const info = await stat(candidate);
      if (info.isFile() && info.size > 0) return candidate;
    } catch {
      // 不存在时尝试下一个候选文件。
    }
  }
  return undefined;
}

async function readTailSteps(filePath: string, fileSize: number): Promise<TranscriptStep[]> {
  const handle = await open(filePath, "r");
  try {
    const start = Math.max(0, fileSize - TAIL_READ_BYTES);
    const length = fileSize - start;
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, start);
    let text = buffer.toString("utf8");
    if (start > 0) {
      const firstNewline = text.indexOf("\n");
      if (firstNewline >= 0) text = text.slice(firstNewline + 1);
    }
    const steps: TranscriptStep[] = [];
    for (const rawLine of text.split("\n")) {
      const trimmed = rawLine.trim();
      if (!trimmed) continue;
      try {
        steps.push(JSON.parse(trimmed) as TranscriptStep);
      } catch {
        // 文件尾部可能正在追加写，忽略未写完的半行。
      }
    }
    return steps;
  } finally {
    await handle.close();
  }
}

function isStepIndicatingExternalActivity(step: TranscriptStep | undefined): boolean {
  if (!step) return false;
  if (step.status === "RUNNING") return true;
  if (step.type === "USER_INPUT" || step.type === "SYSTEM_MESSAGE") return true;
  if (step.type === "GENERIC") return true;
  if (step.type === "PLANNER_RESPONSE") {
    if (Array.isArray(step.tool_calls) && step.tool_calls.length > 0) return true;
    const hasReplyText = typeof step.content === "string" && step.content.trim().length > 0;
    return !hasReplyText;
  }
  return false;
}

export async function inspectTranscriptActivity(
  sessionId: string,
  origin: AgySessionOrigin,
  env: NodeJS.ProcessEnv = process.env,
  nowMs = Date.now(),
): Promise<TranscriptActivityInfo | undefined> {
  const filePath = await resolveTranscriptPath(sessionId, origin, env);
  if (!filePath) return undefined;
  try {
    const info = await stat(filePath);
    let externallyBusy = false;
    if (nowMs - info.mtimeMs <= EXTERNAL_BUSY_WINDOW_MS) {
      const tailSteps = await readTailSteps(filePath, info.size);
      const lastMeaningful = [...tailSteps].reverse().find((s) => s.type !== "CHECKPOINT");
      externallyBusy = isStepIndicatingExternalActivity(lastMeaningful);
    }
    return {
      path: filePath,
      size: info.size,
      mtimeMs: info.mtimeMs,
      externallyBusy,
    };
  } catch {
    return undefined;
  }
}

function normalizePromptCompare(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

export async function snapshotTranscriptState(
  sessionId: string,
  origin: AgySessionOrigin,
  env: NodeJS.ProcessEnv = process.env,
): Promise<TranscriptTurnSnapshot | undefined> {
  const filePath = await resolveTranscriptPath(sessionId, origin, env);
  if (!filePath) return undefined;
  try {
    const [info, raw] = await Promise.all([stat(filePath), readFile(filePath, "utf8")]);
    const userInputs: string[] = [];
    let plannerResponseCount = 0;
    let stepCount = 0;
    for (const line of raw.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let step: TranscriptStep;
      try {
        step = JSON.parse(trimmed) as TranscriptStep;
      } catch {
        continue;
      }
      stepCount += 1;
      if (step.type === "USER_INPUT") {
        userInputs.push(normalizePromptCompare(formatTranscriptUserText(step.content ?? "")));
      } else if (step.type === "PLANNER_RESPONSE") {
        plannerResponseCount += 1;
      }
    }
    return {
      path: filePath,
      size: info.size,
      mtimeMs: info.mtimeMs,
      userInputs,
      plannerResponseCount,
      stepCount,
    };
  } catch {
    return undefined;
  }
}

export function detectExternalConcurrentWrite(
  baseline: ExternalWriteBaseline,
  current: TranscriptTurnSnapshot | undefined,
): ExternalWriteDetection {
  if (!current) return { detected: false };
  const newUserInputs = current.userInputs.slice(baseline.userInputCount);
  if (newUserInputs.length > 1) {
    return { detected: true, reason: "multiple_user_inputs_during_active_turn" };
  }
  const expected = normalizePromptCompare(baseline.expectedPromptText);
  if (newUserInputs.length === 1 && expected) {
    const observed = newUserInputs[0] ?? "";
    if (observed && observed !== expected && !observed.includes(expected) && !expected.includes(observed)) {
      return { detected: true, reason: "mismatched_user_input_during_active_turn" };
    }
  }
  if (
    baseline.approvalUserInputCount !== undefined
    && current.userInputs.length > baseline.approvalUserInputCount
  ) {
    return { detected: true, reason: "external_user_input_during_pending_approval" };
  }
  if (
    baseline.approvalPlannerResponseCount !== undefined
    && current.plannerResponseCount > baseline.approvalPlannerResponseCount
  ) {
    return { detected: true, reason: "external_planner_response_during_pending_approval" };
  }
  return { detected: false };
}

interface ParsedMention {
  label: string;
  kind: string;
  body: string;
}

function parseMentionBlocks(metadata: string): ParsedMention[] {
  const marker = "The user has mentioned some items in the form @[ITEM].";
  const markerIndex = metadata.indexOf(marker);
  if (markerIndex < 0) return [];
  const afterMarker = metadata.slice(markerIndex);
  const firstBreak = afterMarker.indexOf("\n\n");
  if (firstBreak < 0) return [];
  const section = afterMarker.slice(firstBreak + 2).trim();
  if (!section) return [];

  const headerRegex = /^@\[([^\]]+)\]\s+is\s+a\s+\[([^\]]+)\]:\s*$/gm;
  const matches: Array<{ index: number; end: number; label: string; kind: string }> = [];
  let match: RegExpExecArray | null;
  while ((match = headerRegex.exec(section)) !== null) {
    matches.push({
      index: match.index,
      end: match.index + match[0].length,
      label: match[1]!.trim(),
      kind: match[2]!.trim(),
    });
  }
  const results: ParsedMention[] = [];
  for (let i = 0; i < matches.length; i += 1) {
    const current = matches[i]!;
    const nextStart = i + 1 < matches.length ? matches[i + 1]!.index : section.length;
    const rawBody = section.slice(current.end, nextStart).trim();
    const cleanedBody = rawBody
      .replace(/\nThe user has uploaded \d+ image\(s\):[\s\S]*$/i, "")
      .replace(/\nYou can embed this image[\s\S]*$/i, "")
      .trim();
    if (cleanedBody) {
      results.push({ label: current.label, kind: current.kind, body: cleanedBody });
    }
  }
  return results;
}

/**
 * 提取 `<USER_REQUEST>` 正文并把 `<ADDITIONAL_METADATA>` 中的 `@[Quote]` / `@[ITEM]` 引用展开为
 * Markdown 引用块，确保桌面端引用内容在 Mimi 中完整可见。
 */
export function formatTranscriptUserText(rawContent: string): string {
  const reqMatch = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i.exec(rawContent);
  let body = (reqMatch ? reqMatch[1]! : rawContent).trim();
  const metaMatch = /<ADDITIONAL_METADATA>\s*([\s\S]*?)\s*<\/ADDITIONAL_METADATA>/i.exec(rawContent);
  const mentions = metaMatch ? parseMentionBlocks(metaMatch[1]!) : [];
  if (mentions.length === 0) return body;

  const quoteBlocks: string[] = [];
  for (const mention of mentions) {
    const token = `@[${mention.label}]`;
    const isQuote = mention.label.toLowerCase() === "quote" || mention.kind.toLowerCase() === "text block";
    const lines = mention.body.split("\n").map((line) => `> ${line}`);
    if (isQuote) {
      quoteBlocks.push(lines.join("\n"));
      if (body.startsWith(token)) {
        body = body.slice(token.length).trim();
      }
    } else {
      quoteBlocks.push([`> **${mention.label}** (${mention.kind})`, ...lines].join("\n"));
    }
  }
  if (quoteBlocks.length === 0) return body;
  return body ? `${quoteBlocks.join("\n\n")}\n\n${body}` : quoteBlocks.join("\n\n");
}

function inferImageMime(uri: string, declared?: string): string {
  const lower = uri.toLowerCase();
  if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
  if (lower.endsWith(".webp")) return "image/webp";
  if (lower.endsWith(".gif")) return "image/gif";
  if (lower.endsWith(".png")) return "image/png";
  return declared && declared.startsWith("image/") ? declared : "image/png";
}

async function loadMediaInputs(mediaList: readonly TranscriptMedia[] | undefined): Promise<UserInput[]> {
  if (!mediaList || mediaList.length === 0) return [];
  const out: UserInput[] = [];
  for (const entry of mediaList) {
    const uri = entry.uri?.trim();
    if (!uri) continue;
    try {
      const info = await stat(uri);
      if (!info.isFile() || info.size <= 0 || info.size > MAX_MEDIA_BYTES) continue;
      const bytes = await readFile(uri);
      const mime = inferImageMime(uri, entry.mime_type);
      out.push({ type: "image", url: `data:${mime};base64,${bytes.toString("base64")}` });
    } catch {
      // 附件已被清理或不可读时跳过，不阻塞整段历史加载。
    }
  }
  return out;
}

function decodeToolArgs(rawArgs: Record<string, unknown> | undefined): Record<string, unknown> {
  if (!rawArgs) return {};
  const decoded: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(rawArgs)) {
    if (typeof value === "string") {
      try {
        decoded[key] = JSON.parse(value);
        continue;
      } catch {
        // 保留原始字符串。
      }
    }
    decoded[key] = value;
  }
  return decoded;
}

function toolKindForName(name: string): string {
  const lower = name.toLowerCase();
  if (lower === "run_command" || lower === "command_status" || lower === "send_command_input") return "execute";
  if (lower === "edit_file" || lower === "write_file" || lower === "replace_file_content" || lower === "multi_replace_file_content") {
    return "edit";
  }
  if (lower === "read_file" || lower === "view_file" || lower === "view_file_outline" || lower === "view_code_item") {
    return "read";
  }
  if (lower === "search_web" || lower === "grep_search" || lower === "find_by_name") return "search";
  return "other";
}

function toolTitleForCall(name: string, args: Record<string, unknown>): string {
  const summary = typeof args.toolSummary === "string" ? args.toolSummary.trim() : "";
  if (summary) return summary;
  const targetPath = [args.Path, args.TargetFile, args.path, args.file_path].find(
    (v): v is string => typeof v === "string" && v.trim().length > 0,
  );
  if (targetPath) {
    const base = targetPath.split(/[\\/]/).filter(Boolean).pop() ?? targetPath;
    return `${name} ${base}`;
  }
  return name;
}

function parseIsoMs(iso: string | undefined): number | null {
  if (!iso) return null;
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? ms : null;
}

interface PendingToolSlot {
  turnIndex: number;
  itemIndex: number;
  state: AcpToolState;
}

export async function readTranscriptTurns(
  sessionId: string,
  cwd: string,
  transcriptPath: string,
  running = false,
  holderActive = false,
): Promise<Turn[]> {
  const raw = await readFile(transcriptPath, "utf8");
  const steps: TranscriptStep[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      steps.push(JSON.parse(trimmed) as TranscriptStep);
    } catch {
      // 忽略正在写入的末尾半行。
    }
  }

  interface TurnDraft {
    id: string;
    items: ThreadItem[];
    userSeq: number;
    reasoningSeq: number;
    msgSeq: number;
    toolSeq: number;
    startedAtMs: number | null;
    completedAtMs: number | null;
    toolStates: Map<string, AcpToolState>;
    terminalStatus?: "failed" | "interrupted";
    errorMessage?: string;
  }

  const turns: TurnDraft[] = [];
  let current: TurnDraft | undefined;
  const pendingTools: PendingToolSlot[] = [];

  const nextTurn = (startedAtMs: number | null): TurnDraft => {
    const index = turns.length + 1;
    const draft: TurnDraft = {
      id: `${sessionId}:turn:${index}`,
      items: [],
      userSeq: 0,
      reasoningSeq: 0,
      msgSeq: 0,
      toolSeq: 0,
      startedAtMs,
      completedAtMs: startedAtMs,
      toolStates: new Map(),
    };
    turns.push(draft);
    current = draft;
    return draft;
  };

  for (const step of steps) {
    const stepMs = parseIsoMs(step.created_at);
    if (step.type === "USER_INPUT") {
      pendingTools.length = 0;
      const draft = nextTurn(stepMs);
      const text = formatTranscriptUserText(step.content ?? "");
      const mediaInputs = await loadMediaInputs(step.media);
      const content: UserInput[] = [];
      if (text) content.push({ type: "text", text, text_elements: [] });
      content.push(...mediaInputs);
      if (content.length > 0) {
        draft.userSeq += 1;
        draft.items.push({
          type: "userMessage",
          id: draft.userSeq === 1 ? `${draft.id}:user` : `${draft.id}:user:${draft.userSeq}`,
          clientId: null,
          content,
        });
      }
      continue;
    }

    if (step.type === "PLANNER_RESPONSE") {
      const draft = current ?? nextTurn(stepMs);
      if (stepMs !== null) draft.completedAtMs = stepMs;
      const normalizedStatus = typeof step.status === "string" ? step.status.toUpperCase() : "";
      if (
        (normalizedStatus === "CANCELLED" || normalizedStatus === "CANCELED" || normalizedStatus === "INTERRUPTED")
        && draft.terminalStatus !== "failed"
      ) {
        draft.terminalStatus = "interrupted";
      }
      if (typeof step.thinking === "string" && step.thinking.trim()) {
        draft.reasoningSeq += 1;
        draft.items.push({
          type: "reasoning",
          id: `${draft.id}:reasoning:${draft.reasoningSeq}`,
          summary: [],
          content: [step.thinking.trim()],
        });
      }
      if (typeof step.content === "string" && step.content.trim()) {
        draft.msgSeq += 1;
        draft.items.push({
          type: "agentMessage",
          id: `${draft.id}:msg:${draft.msgSeq}`,
          text: step.content,
          phase: null,
          memoryCitation: null,
          delivery: null,
          questions: null,
        });
      }
      if (Array.isArray(step.tool_calls) && step.tool_calls.length > 0) {
        const turnIndex = turns.length - 1;
        for (const call of step.tool_calls) {
          const name = call.name?.trim() || "tool";
          const args = decodeToolArgs(call.args);
          draft.toolSeq += 1;
          const toolCallId = `${draft.id}:tool:${draft.toolSeq}`;
          const targetPath = [args.Path, args.TargetFile, args.path, args.file_path].find(
            (v): v is string => typeof v === "string" && v.trim().length > 0,
          );
          const state: AcpToolState = {
            toolCallId,
            title: toolTitleForCall(name, args),
            kind: toolKindForName(name),
            status: "in_progress",
            rawInput: args,
            ...(targetPath ? { locations: [{ path: targetPath }] } : {}),
          };
          draft.toolStates.set(toolCallId, state);
          const itemIndex = draft.items.length;
          draft.items.push(acpToolToThreadItem(state, cwd, true));
          pendingTools.push({ turnIndex, itemIndex, state });
        }
      }
      continue;
    }

    if (step.type === "GENERIC") {
      if (current && stepMs !== null) current.completedAtMs = stepMs;
      const slot = pendingTools.shift();
      if (!slot) continue;
      const draft = turns[slot.turnIndex];
      if (!draft) continue;
      const status = step.status === "ERROR" ? "failed" : step.status === "RUNNING" ? "in_progress" : "completed";
      const updated: AcpToolState = {
        ...slot.state,
        status,
        rawOutput: typeof step.content === "string" ? step.content : slot.state.rawOutput,
      };
      draft.toolStates.set(updated.toolCallId, updated);
      draft.items[slot.itemIndex] = acpToolToThreadItem(updated, cwd, status === "in_progress");
      continue;
    }

    if (step.type === "ERROR_MESSAGE") {
      const draft = current ?? nextTurn(stepMs);
      if (stepMs !== null) draft.completedAtMs = stepMs;
      draft.terminalStatus = "failed";
      const errText = typeof step.content === "string" ? step.content.trim() : "";
      if (errText) {
        draft.errorMessage = errText;
      }
      continue;
    }

    const normalizedStepStatus = typeof step.status === "string" ? step.status.toUpperCase() : "";
    if (
      current
      && (normalizedStepStatus === "CANCELLED" || normalizedStepStatus === "CANCELED" || normalizedStepStatus === "INTERRUPTED")
      && current.terminalStatus !== "failed"
    ) {
      current.terminalStatus = "interrupted";
    }
  }

  const lastTurn = turns[turns.length - 1];
  return turns.map((draft) => {
    const isLastTurn = draft === lastTurn;
    const isActiveTurn = isLastTurn && running;
    const toolsPending = isLastTurn && (running || holderActive);
    const finalizedItems = draft.items.map((item) => {
      const state = draft.toolStates.get(item.id);
      if (!state) return item;
      return acpToolToThreadItem(state, cwd, toolsPending);
    });
    const status: TurnStatus = isActiveTurn ? "inProgress" : (draft.terminalStatus ?? "completed");
    const error =
      !isActiveTurn && status === "failed"
        ? {
            message: draft.errorMessage ?? "Antigravity turn failed",
            codexErrorInfo: null,
            additionalDetails: null,
            misalignment: null,
          }
        : null;
    const startedAt = draft.startedAtMs !== null ? Math.floor(draft.startedAtMs / 1000) : null;
    const completedAt = !isActiveTurn && draft.completedAtMs !== null ? Math.floor(draft.completedAtMs / 1000) : null;
    const durationMs =
      !isActiveTurn && draft.startedAtMs !== null && draft.completedAtMs !== null && draft.completedAtMs >= draft.startedAtMs
        ? draft.completedAtMs - draft.startedAtMs
        : null;
    return {
      id: draft.id,
      rootTurnId: null,
      items: finalizedItems,
      itemsView: "full",
      status,
      error,
      startedAt,
      completedAt,
      durationMs,
    };
  });
}

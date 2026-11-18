import { PassThrough } from "node:stream";
import type { AcpTransport } from "../../src/acp/client.ts";
import type {
  AcpAvailableCommand,
  AcpConfigOption,
  AcpContentBlock,
  AcpPermissionOption,
  AcpPromptResult,
  AcpSessionSummary,
  AcpSessionUpdate,
} from "../../src/acp/types.ts";
import type { SpawnAgyAcpOptions, SpawnAgyTransport } from "../../src/agy/binary.ts";

export interface FakeStoredSession {
  sessionId: string;
  cwd: string;
  title: string | null;
  updatedAt: string;
  modeId: string;
  model: string;
  thoughtLevel: string;
  replayUpdates: AcpSessionUpdate[];
}

export interface FakeAgyBehavior {
  sessions?: FakeStoredSession[];
  commands?: AcpAvailableCommand[];
  onPrompt?: (ctx: {
    session: FakeStoredSession;
    prompt: AcpContentBlock[];
    emitUpdate: (update: AcpSessionUpdate) => void;
    requestPermission: (
      toolCall: { toolCallId: string; title?: string; kind?: string; rawInput?: Record<string, unknown> },
      options: AcpPermissionOption[],
    ) => Promise<unknown>;
    signal: AbortSignal;
  }) => Promise<AcpPromptResult>;
}

const DEFAULT_CONFIG_OPTIONS: AcpConfigOption[] = [
  {
    id: "model",
    name: "Model",
    category: "model",
    type: "select",
    currentValue: "gemini-4-carbon",
    options: [
      { value: "gemini-4-carbon", name: "Gemini 4 Carbon" },
      { value: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen" },
      { value: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)" },
      { value: "claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
    ],
  },
  {
    id: "thought_level",
    name: "Thinking Level",
    category: "thought_level",
    type: "select",
    currentValue: "medium",
    options: [
      { value: "low", name: "Low" },
      { value: "medium", name: "Medium" },
      { value: "high", name: "High" },
    ],
  },
  {
    id: "mode",
    name: "Mode",
    category: "mode",
    type: "select",
    currentValue: "default",
    options: [
      { value: "default", name: "Default" },
      { value: "accept-edits", name: "Accept edits" },
      { value: "auto", name: "Auto" },
      { value: "plan", name: "Plan" },
    ],
  },
];

const DEFAULT_AVAILABLE_MODELS = [
  { modelId: "gemini-4-carbon-low", name: "Gemini 4 Carbon (Low)" },
  { modelId: "gemini-4-carbon-medium", name: "Gemini 4 Carbon (Medium)" },
  { modelId: "gemini-4-carbon-high", name: "Gemini 4 Carbon (High)" },
  { modelId: "gemini-4-hydrogen-low", name: "Gemini 4 Hydrogen (Low)" },
  { modelId: "gemini-4-hydrogen-medium", name: "Gemini 4 Hydrogen (Medium)" },
  { modelId: "gemini-4-hydrogen-high", name: "Gemini 4 Hydrogen (High)" },
  { modelId: "gemini-4-hydrogen-xhigh", name: "Gemini 4 Hydrogen (XHigh)" },
  { modelId: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)" },
  { modelId: "claude-sonnet-5-5-low", name: "Claude Sonnet 5.5 (Low)" },
  { modelId: "claude-sonnet-5-5-medium", name: "Claude Sonnet 5.5 (Medium)" },
  { modelId: "claude-sonnet-5-5-high", name: "Claude Sonnet 5.5 (High)" },
];

const DEFAULT_COMMANDS: AcpAvailableCommand[] = [
  { name: "goal", description: "Run until the specified goal is completely finished." },
  { name: "compact", description: "Compact the conversation now." },
  { name: "plan", description: "Plan carefully before executing a task." },
  { name: "grill-me", description: "Interview me to align on a plan." },
  { name: "clear", description: "Clear TUI session" },
  { name: "exit", description: "Exit TUI" },
];

export class FakeAgyWorld {
  readonly sessions = new Map<string, FakeStoredSession>();
  readonly spawns: SpawnAgyAcpOptions[] = [];
  readonly initializePayloads: Array<Record<string, unknown>> = [];
  private nextSessionNum = 1;
  private nextPid = 40_000;
  private nextServerReqId = 500;

  constructor(private readonly behavior: FakeAgyBehavior = {}) {
    for (const initial of behavior.sessions ?? []) {
      this.sessions.set(initial.sessionId, { ...initial, replayUpdates: [...initial.replayUpdates] });
    }
  }

  readonly spawnTransport: SpawnAgyTransport = (options): AcpTransport => {
    this.spawns.push(options);
    const stdin = new PassThrough();
    const stdout = new PassThrough();
    const pid = ++this.nextPid;
    const pendingServerReqs = new Map<string | number, (value: unknown) => void>();
    const activePromptAborts = new Map<string, AbortController>();

    const sendFrame = (frame: Record<string, unknown>) => {
      stdout.write(`${JSON.stringify(frame)}\n`);
    };

    const emitUpdate = (sessionId: string, update: AcpSessionUpdate) => {
      sendFrame({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update } });
    };

    let buffer = "";
    stdin.on("data", (chunk: Buffer | string) => {
      buffer += typeof chunk === "string" ? chunk : chunk.toString("utf8");
      let idx = buffer.indexOf("\n");
      while (idx >= 0) {
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        idx = buffer.indexOf("\n");
        if (!line) continue;
        const msg = JSON.parse(line) as Record<string, unknown>;
        if (typeof msg.method !== "string" && "id" in msg) {
          const resolver = pendingServerReqs.get(msg.id as string | number);
          if (resolver) {
            pendingServerReqs.delete(msg.id as string | number);
            resolver(msg.result);
          }
          continue;
        }
        void handleClientFrame(msg);
      }
    });

    const handleClientFrame = async (msg: Record<string, unknown>) => {
      const id = msg.id as string | number | undefined;
      const method = String(msg.method ?? "");
      const params = (msg.params ?? {}) as Record<string, unknown>;

      if (method === "session/cancel") {
        const sid = String(params.sessionId ?? "");
        activePromptAborts.get(sid)?.abort();
        return;
      }

      if (id === undefined) return;

      switch (method) {
        case "initialize": {
          this.initializePayloads.push(params);
          sendFrame({
            jsonrpc: "2.0",
            id,
            result: {
              protocolVersion: 1,
              agentInfo: { name: "agy", version: "1.5.10" },
              agentCapabilities: { loadSession: true, promptCapabilities: { image: true, embeddedContext: true } },
            },
          });
          return;
        }

        case "session/list": {
          const summaries: AcpSessionSummary[] = [...this.sessions.values()].map((s) => ({
            sessionId: s.sessionId,
            cwd: s.cwd,
            title: s.title,
            updatedAt: s.updatedAt,
          }));
          sendFrame({ jsonrpc: "2.0", id, result: { sessions: summaries } });
          return;
        }

        case "session/new": {
          const sessionId = `fake-agy-session-${this.nextSessionNum++}`;
          const cwd = String(params.cwd ?? "");
          const stored: FakeStoredSession = {
            sessionId,
            cwd,
            title: null,
            updatedAt: new Date().toISOString(),
            modeId: "default",
            model: "gemini-4-carbon",
            thoughtLevel: "medium",
            replayUpdates: [],
          };
          this.sessions.set(sessionId, stored);
          sendFrame({
            jsonrpc: "2.0",
            id,
            result: {
              sessionId,
              models: { availableModels: DEFAULT_AVAILABLE_MODELS, currentModelId: "gemini-4-carbon-medium" },
              modes: {
                currentModeId: "default",
                availableModes: [
                  { id: "default", name: "Default" },
                  { id: "accept-edits", name: "Accept edits" },
                  { id: "auto", name: "Auto" },
                  { id: "plan", name: "Plan" },
                ],
              },
              configOptions: structuredClone(DEFAULT_CONFIG_OPTIONS),
            },
          });
          queueMicrotask(() => {
            emitUpdate(sessionId, {
              sessionUpdate: "available_commands_update",
              availableCommands: this.behavior.commands ?? DEFAULT_COMMANDS,
            });
            emitUpdate(sessionId, {
              sessionUpdate: "usage_update",
              used: 0,
              size: 1_048_576,
            });
          });
          return;
        }

        case "session/load": {
          const sessionId = String(params.sessionId ?? "");
          const stored = this.sessions.get(sessionId);
          if (!stored) {
            sendFrame({ jsonrpc: "2.0", id, error: { code: -32602, message: `Session not found: ${sessionId}` } });
            return;
          }
          for (const replay of stored.replayUpdates) {
            emitUpdate(sessionId, replay);
          }
          sendFrame({
            jsonrpc: "2.0",
            id,
            result: {
              sessionId,
              models: { availableModels: DEFAULT_AVAILABLE_MODELS, currentModelId: `${stored.model}-${stored.thoughtLevel}` },
              modes: { currentModeId: stored.modeId, availableModes: [] },
              configOptions: structuredClone(DEFAULT_CONFIG_OPTIONS),
            },
          });
          return;
        }

        case "session/set_mode": {
          const sessionId = String(params.sessionId ?? "");
          const modeId = String(params.modeId ?? "default");
          const stored = this.sessions.get(sessionId);
          if (stored) stored.modeId = modeId;
          emitUpdate(sessionId, { sessionUpdate: "current_mode_update", currentModeId: modeId });
          sendFrame({ jsonrpc: "2.0", id, result: {} });
          return;
        }

        case "session/set_config_option": {
          const sessionId = String(params.sessionId ?? "");
          const configId = String(params.configId ?? "");
          const value = String(params.value ?? "");
          const stored = this.sessions.get(sessionId);
          if (stored) {
            if (configId === "model") stored.model = value;
            if (configId === "thought_level") stored.thoughtLevel = value;
          }
          sendFrame({ jsonrpc: "2.0", id, result: { configOptions: structuredClone(DEFAULT_CONFIG_OPTIONS) } });
          return;
        }

        case "session/close": {
          sendFrame({ jsonrpc: "2.0", id, result: {} });
          return;
        }

        case "session/prompt": {
          const sessionId = String(params.sessionId ?? "");
          const prompt = (params.prompt ?? []) as AcpContentBlock[];
          const stored = this.sessions.get(sessionId);
          if (!stored) {
            sendFrame({ jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown session ${sessionId}` } });
            return;
          }
          const abort = new AbortController();
          activePromptAborts.set(sessionId, abort);

          const firstText = prompt.find((b): b is { type: "text"; text: string } => b.type === "text")?.text ?? "";
          if (firstText) {
            stored.replayUpdates.push({
              sessionUpdate: "user_message_chunk",
              content: { type: "text", text: firstText },
            });
          }

          const recordAndEmit = (update: AcpSessionUpdate) => {
            if (
              update.sessionUpdate === "agent_thought_chunk"
              || update.sessionUpdate === "agent_message_chunk"
              || update.sessionUpdate === "tool_call"
              || update.sessionUpdate === "tool_call_update"
              || update.sessionUpdate === "plan"
            ) {
              stored.replayUpdates.push(update);
            }
            if (update.sessionUpdate === "session_info_update" && typeof update.title === "string") {
              stored.title = update.title;
            }
            emitUpdate(sessionId, update);
          };

          const requestPermission = (
            toolCall: { toolCallId: string; title?: string; kind?: string; rawInput?: Record<string, unknown> },
            permOptions: AcpPermissionOption[],
          ) => {
            const reqId = `acp-perm-${++this.nextServerReqId}`;
            return new Promise<unknown>((resolve) => {
              pendingServerReqs.set(reqId, resolve);
              sendFrame({
                jsonrpc: "2.0",
                id: reqId,
                method: "session/request_permission",
                params: { sessionId, toolCall, options: permOptions },
              });
            });
          };

          try {
            let res: AcpPromptResult;
            if (this.behavior.onPrompt) {
              res = await this.behavior.onPrompt({
                session: stored,
                prompt,
                emitUpdate: recordAndEmit,
                requestPermission,
                signal: abort.signal,
              });
            } else {
              if (!stored.title) {
                recordAndEmit({ sessionUpdate: "session_info_update", title: "Auto Generated Agy Title" });
              }
              recordAndEmit({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Thinking carefully..." } });
              recordAndEmit({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Echo: ${firstText}` } });
              recordAndEmit({ sessionUpdate: "usage_update", used: 12_345, size: 1_048_576 });
              res = {
                stopReason: abort.signal.aborted ? "cancelled" : "end_turn",
                usage: { inputTokens: 12_000, outputTokens: 345, thoughtTokens: 50, totalTokens: 12_395 },
              };
            }
            stored.updatedAt = new Date().toISOString();
            sendFrame({ jsonrpc: "2.0", id, result: res });
          } catch (error) {
            sendFrame({
              jsonrpc: "2.0",
              id,
              error: { code: -32603, message: error instanceof Error ? error.message : String(error) },
            });
          } finally {
            activePromptAborts.delete(sessionId);
          }
          return;
        }
      }
    };

    return {
      stdin,
      stdout,
      pid,
      async close() {
        stdin.end();
        stdout.end();
      },
    };
  };
}

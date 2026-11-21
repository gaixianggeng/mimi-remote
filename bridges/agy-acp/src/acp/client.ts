import type { Readable, Writable } from "node:stream";
import { classifyFrame, ErrorCode, errorFrame, resultFrame, RpcError, type RequestId } from "@mimi/appserver-kit/rpc/frames.ts";
import { readLines } from "@mimi/appserver-kit/rpc/lines.ts";
import type {
  AcpClientInfo,
  AcpConfigOption,
  AcpContentBlock,
  AcpInitializeResult,
  AcpPromptResult,
  AcpRequestPermissionParams,
  AcpRequestPermissionResult,
  AcpSessionOpenResult,
  AcpSessionSummary,
  AcpSessionUpdate,
} from "./types.ts";

export interface AcpTransport {
  readonly stdin: Writable;
  readonly stdout: Readable;
  readonly pid?: number;
  close(): Promise<void>;
}

export interface AcpClientOptions {
  clientInfo: AcpClientInfo;
  clientCapabilities?: Record<string, unknown>;
  onSessionUpdate?: (sessionId: string, update: AcpSessionUpdate) => void;
  onRequestPermission?: (params: AcpRequestPermissionParams, signal: AbortSignal) => Promise<AcpRequestPermissionResult>;
  onClose?: (error?: Error) => void;
  log?: (message: string) => void;
  /** `session/load` 响应返回后等待尾部异步历史回放静默的窗口（毫秒），默认 200ms。 */
  replaySettleMs?: number;
}

interface PendingCall {
  method: string;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer?: ReturnType<typeof setTimeout>;
}

interface ReplayCapture {
  updates: AcpSessionUpdate[];
  onUpdate?: () => void;
  onClose?: () => void;
}

const DEFAULT_REPLAY_SETTLE_MS = 200;
const MAX_REPLAY_SETTLE_MS = 5_000;

export class AcpClient {
  private nextId = 1;
  private closed = false;
  private readonly pending = new Map<RequestId, PendingCall>();
  private readonly inboundControllers = new Set<AbortController>();
  private readonly sessionListeners = new Map<string, Set<(update: AcpSessionUpdate) => void>>();
  private readonly replayCaptures = new Map<string, ReplayCapture>();
  private readonly permissionHandlers = new Map<
    string,
    (params: AcpRequestPermissionParams, signal: AbortSignal) => Promise<AcpRequestPermissionResult>
  >();
  private readonly readerDone: Promise<void>;

  constructor(
    private readonly transport: AcpTransport,
    private readonly options: AcpClientOptions,
  ) {
    this.readerDone = this.pumpStdout();
  }

  get pid(): number | undefined {
    return this.transport.pid;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  onSession(sessionId: string, listener: (update: AcpSessionUpdate) => void): () => void {
    let set = this.sessionListeners.get(sessionId);
    if (!set) {
      set = new Set();
      this.sessionListeners.set(sessionId, set);
    }
    set.add(listener);
    return () => {
      const existing = this.sessionListeners.get(sessionId);
      if (!existing) return;
      existing.delete(listener);
      if (existing.size === 0) this.sessionListeners.delete(sessionId);
    };
  }

  onPermission(
    sessionId: string,
    handler: (params: AcpRequestPermissionParams, signal: AbortSignal) => Promise<AcpRequestPermissionResult>,
  ): () => void {
    this.permissionHandlers.set(sessionId, handler);
    return () => {
      if (this.permissionHandlers.get(sessionId) === handler) {
        this.permissionHandlers.delete(sessionId);
      }
    };
  }

  async initialize(timeoutMs = 15_000): Promise<AcpInitializeResult> {
    return (await this.call(
      "initialize",
      {
        protocolVersion: 1,
        clientCapabilities: this.options.clientCapabilities ?? {},
        clientInfo: this.options.clientInfo,
      },
      timeoutMs,
    )) as AcpInitializeResult;
  }

  async sessionList(timeoutMs = 15_000): Promise<AcpSessionSummary[]> {
    const res = (await this.call("session/list", {}, timeoutMs)) as { sessions?: AcpSessionSummary[] } | null;
    return Array.isArray(res?.sessions) ? res.sessions : [];
  }

  async sessionNew(cwd: string, mcpServers: unknown[] = [], timeoutMs = 20_000): Promise<AcpSessionOpenResult> {
    return (await this.call("session/new", { cwd, mcpServers }, timeoutMs)) as AcpSessionOpenResult;
  }

  /**
   * 加载已有会话并收集全部历史回放 `session/update` 帧。
   * 实测 `agy acp` 的 `session/load` 会在 JSON-RPC 响应返回后继续由后台 goroutine 异步冲出剩余
   * 历史帧（大型会话可持续数十至数百毫秒）；这里在响应返回后继续捕获直到流静默，确保历史尾部
   * 不会泄漏到紧随其后的新 `session/prompt` 回合里。
   */
  async sessionLoadWithReplay(
    sessionId: string,
    cwd: string,
    mcpServers: unknown[] = [],
    timeoutMs = 30_000,
  ): Promise<{ result: AcpSessionOpenResult; updates: AcpSessionUpdate[] }> {
    const capture: ReplayCapture = { updates: [] };
    const previous = this.replayCaptures.get(sessionId);
    this.replayCaptures.set(sessionId, capture);
    try {
      const result = (await this.call("session/load", { sessionId, cwd, mcpServers }, timeoutMs)) as AcpSessionOpenResult;
      await this.waitForReplayQuiescence(capture);
      return { result, updates: capture.updates };
    } finally {
      capture.onUpdate = undefined;
      capture.onClose = undefined;
      if (this.replayCaptures.get(sessionId) === capture) {
        if (previous) {
          this.replayCaptures.set(sessionId, previous);
        } else {
          this.replayCaptures.delete(sessionId);
        }
      }
    }
  }

  private waitForReplayQuiescence(capture: ReplayCapture): Promise<void> {
    const settleMs = this.options.replaySettleMs ?? DEFAULT_REPLAY_SETTLE_MS;
    if (settleMs <= 0 || this.closed) return Promise.resolve();
    return new Promise((resolve) => {
      let finished = false;
      let quietTimer: ReturnType<typeof setTimeout> | undefined;
      const done = () => {
        if (finished) return;
        finished = true;
        if (quietTimer) clearTimeout(quietTimer);
        clearTimeout(maxTimer);
        capture.onUpdate = undefined;
        capture.onClose = undefined;
        resolve();
      };
      const armQuiet = () => {
        if (quietTimer) clearTimeout(quietTimer);
        quietTimer = setTimeout(done, settleMs);
      };
      const maxTimer = setTimeout(done, MAX_REPLAY_SETTLE_MS);
      capture.onUpdate = armQuiet;
      capture.onClose = done;
      armQuiet();
    });
  }

  async sessionClose(sessionId: string, timeoutMs = 5_000): Promise<void> {
    await this.call("session/close", { sessionId }, timeoutMs);
  }

  async sessionSetMode(sessionId: string, modeId: string, timeoutMs = 10_000): Promise<void> {
    await this.call("session/set_mode", { sessionId, modeId }, timeoutMs);
  }

  async sessionSetConfigOption(
    sessionId: string,
    configId: string,
    value: string,
    timeoutMs = 10_000,
  ): Promise<{ configOptions?: AcpConfigOption[] }> {
    return ((await this.call("session/set_config_option", { sessionId, configId, value }, timeoutMs)) ?? {}) as {
      configOptions?: AcpConfigOption[];
    };
  }

  async sessionPrompt(sessionId: string, prompt: AcpContentBlock[]): Promise<AcpPromptResult> {
    return (await this.call("session/prompt", { sessionId, prompt })) as AcpPromptResult;
  }

  sessionCancel(sessionId: string): void {
    if (this.closed) return;
    this.writeFrame({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } });
  }

  async close(): Promise<void> {
    if (this.closed) {
      await this.readerDone;
      return;
    }
    this.failAll(new Error("ACP client closed"));
    await this.transport.close();
    await this.readerDone;
  }

  private call(method: string, params: unknown, timeoutMs?: number): Promise<unknown> {
    if (this.closed) {
      return Promise.reject(new RpcError(ErrorCode.internalError, `ACP connection closed before ${method}`));
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const pending: PendingCall = { method, resolve, reject };
      if (timeoutMs !== undefined && timeoutMs > 0) {
        pending.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new RpcError(ErrorCode.internalError, `ACP ${method} timed out after ${timeoutMs}ms`));
        }, timeoutMs);
      }
      this.pending.set(id, pending);
      try {
        this.writeFrame({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        if (pending.timer) clearTimeout(pending.timer);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private writeFrame(frame: Record<string, unknown>): void {
    this.transport.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  private async pumpStdout(): Promise<void> {
    let streamError: Error | undefined;
    try {
      for await (const event of readLines(this.transport.stdout)) {
        if (event.type === "oversize") {
          this.options.log?.("dropped oversize ACP frame");
          continue;
        }
        let parsed: unknown;
        try {
          parsed = JSON.parse(event.text);
        } catch {
          this.options.log?.("ignored malformed ACP JSON line");
          continue;
        }
        const classified = classifyFrame(parsed);
        switch (classified.kind) {
          case "response": {
            const raw = parsed as { result?: unknown; error?: { code?: unknown; message?: unknown; data?: unknown } };
            const pending = this.pending.get(classified.id);
            if (!pending) break;
            this.pending.delete(classified.id);
            if (pending.timer) clearTimeout(pending.timer);
            if (raw.error && typeof raw.error === "object") {
              const code = typeof raw.error.code === "number" ? raw.error.code : ErrorCode.internalError;
              const message = typeof raw.error.message === "string" ? raw.error.message : `ACP ${pending.method} failed`;
              pending.reject(new RpcError(code, message, raw.error.data));
            } else {
              pending.resolve(raw.result);
            }
            break;
          }
          case "notification": {
            if (classified.frame.method === "session/update") {
              const params = classified.frame.params as { sessionId?: unknown; update?: AcpSessionUpdate } | undefined;
              const sessionId = typeof params?.sessionId === "string" ? params.sessionId : "";
              const update = params?.update;
              if (sessionId && update && typeof update === "object" && typeof update.sessionUpdate === "string") {
                const capture = this.replayCaptures.get(sessionId);
                if (capture) {
                  capture.updates.push(update);
                  capture.onUpdate?.();
                } else {
                  const listeners = this.sessionListeners.get(sessionId);
                  if (listeners) {
                    for (const listener of [...listeners]) listener(update);
                  }
                  this.options.onSessionUpdate?.(sessionId, update);
                }
              }
            }
            break;
          }
          case "request": {
            void this.handleServerRequest(classified.frame.id, classified.frame.method, classified.frame.params);
            break;
          }
          case "invalid":
            break;
        }
      }
    } catch (error) {
      streamError = error instanceof Error ? error : new Error(String(error));
    } finally {
      this.failAll(streamError ?? new Error("ACP stdout closed"));
      this.options.onClose?.(streamError);
    }
  }

  private async handleServerRequest(id: RequestId, method: string, params: unknown): Promise<void> {
    const controller = new AbortController();
    this.inboundControllers.add(controller);
    try {
      if (method === "session/request_permission") {
        const reqParams = params as AcpRequestPermissionParams;
        const handler = (reqParams?.sessionId ? this.permissionHandlers.get(reqParams.sessionId) : undefined)
          ?? this.options.onRequestPermission;
        if (!handler) {
          this.writeFrame(resultFrame(id, { outcome: { outcome: "cancelled" } } satisfies AcpRequestPermissionResult));
          return;
        }
        const res = await handler(reqParams, controller.signal);
        if (!this.closed) this.writeFrame(resultFrame(id, res));
        return;
      }
      if (!this.closed) {
        this.writeFrame(errorFrame(id, { code: ErrorCode.methodNotFound, message: `Unsupported client method: ${method}` }));
      }
    } catch (error) {
      if (!this.closed) {
        const rpc = error instanceof RpcError ? error : new RpcError(ErrorCode.internalError, error instanceof Error ? error.message : String(error));
        this.writeFrame(errorFrame(id, { code: rpc.code, message: rpc.message, ...(rpc.data !== undefined ? { data: rpc.data } : {}) }));
      }
    } finally {
      this.inboundControllers.delete(controller);
    }
  }

  private failAll(error: Error): void {
    if (this.closed) return;
    this.closed = true;
    for (const capture of this.replayCaptures.values()) capture.onClose?.();
    this.replayCaptures.clear();
    for (const controller of this.inboundControllers) controller.abort();
    this.inboundControllers.clear();
    for (const [, pending] of this.pending) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

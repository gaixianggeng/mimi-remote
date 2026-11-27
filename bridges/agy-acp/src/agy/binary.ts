import os from "node:os";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { ErrorCode, RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import { readLines } from "@mimi/appserver-kit/rpc/lines.ts";
import { logger } from "../util/logging.ts";
import { AcpClient, DEFAULT_ACP_INITIALIZE_TIMEOUT_MS, type AcpClientOptions, type AcpTransport } from "../acp/client.ts";
import type { AcpSessionUpdate } from "../acp/types.ts";
import { MINIMUM_AGY_VERSION, ADAPTER_NAME, ADAPTER_VERSION } from "../version.ts";
import { resolveAgyDataPaths, sanitizeAgyEnv } from "./env.ts";

const execFileAsync = promisify(execFile);

export interface AgyProbeResult {
  version: string;
}

export type ProbeAgy = (executable: string, env?: NodeJS.ProcessEnv) => Promise<AgyProbeResult>;

function parseSemver(raw: string): [number, number, number] | undefined {
  const match = /(\d+)\.(\d+)\.(\d+)/.exec(raw);
  if (!match) return undefined;
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

export function compareSemver(a: string, b: string): number {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  if (!pa || !pb) return 0;
  for (let i = 0; i < 3; i += 1) {
    const diff = pa[i]! - pb[i]!;
    if (diff !== 0) return diff;
  }
  return 0;
}

export async function defaultProbeAgy(executable: string, baseEnv: NodeJS.ProcessEnv = process.env): Promise<AgyProbeResult> {
  const { stdout, stderr } = await execFileAsync(executable, ["--version"], {
    env: sanitizeAgyEnv(baseEnv),
    timeout: 8_000,
  });
  const combined = `${stdout}\n${stderr}`.trim();
  const match = /(\d+\.\d+\.\d+)/.exec(combined);
  if (!match) {
    throw new Error(`无法从 agy --version 解析版本号：${combined.slice(0, 120)}`);
  }
  return { version: match[1]! };
}

export class AgyVersionGate {
  private checkedVersion: string | undefined;
  private inflight: Promise<string> | undefined;

  constructor(
    private readonly executable: () => string,
    private readonly probe: ProbeAgy = defaultProbeAgy,
    private readonly env: () => NodeJS.ProcessEnv = () => process.env,
  ) {}

  async ensure(): Promise<string> {
    if (this.checkedVersion) return this.checkedVersion;
    if (this.inflight) return this.inflight;
    const run = this.check();
    this.inflight = run;
    try {
      const version = await run;
      this.checkedVersion = version;
      return version;
    } finally {
      if (this.inflight === run) this.inflight = undefined;
    }
  }

  private async check(): Promise<string> {
    const bin = this.executable();
    let probeResult: AgyProbeResult;
    try {
      probeResult = await this.probe(bin, this.env());
    } catch (error) {
      throw new RpcError(
        ErrorCode.invalidParams,
        `无法启动 Antigravity CLI (${bin})：${error instanceof Error ? error.message : String(error)}`,
      );
    }
    if (compareSemver(probeResult.version, MINIMUM_AGY_VERSION) < 0) {
      throw new RpcError(
        ErrorCode.invalidParams,
        `Antigravity CLI 版本过低（当前 ${probeResult.version}，至少需要 ${MINIMUM_AGY_VERSION}）`,
      );
    }
    return probeResult.version;
  }
}

export interface SpawnAgyAcpOptions {
  executable: string;
  cwd: string;
  sandbox?: boolean;
  skipPermissions?: boolean;
  addDirs?: readonly string[];
  appDataDirName?: string;
  env?: NodeJS.ProcessEnv;
}

export type SpawnAgyTransport = (options: SpawnAgyAcpOptions) => AcpTransport;

export function defaultSpawnAgyTransport(options: SpawnAgyAcpOptions): AcpTransport {
  const cleanEnv = sanitizeAgyEnv(options.env ?? process.env);
  const paths = resolveAgyDataPaths(options.env ?? process.env);
  const effectiveAppDataDir = options.appDataDirName?.trim() || paths.appDataDirName;
  const args = ["acp", "--stdio"];
  if (paths.geminiDirName !== ".gemini") {
    args.push("--gemini-dir", paths.geminiDirName);
  }
  if (effectiveAppDataDir !== "antigravity-cli") {
    args.push("--app-data-dir", effectiveAppDataDir);
  }
  if (options.sandbox) {
    args.push("--sandbox");
  }
  if (options.skipPermissions) {
    args.push("--dangerously-skip-permissions");
  }
  for (const dir of options.addDirs ?? []) {
    if (dir && dir !== options.cwd) {
      args.push("--add-dir", dir);
    }
  }

  const child = spawn(options.executable, args, {
    cwd: options.cwd,
    env: cleanEnv,
    stdio: ["pipe", "pipe", "pipe"],
  });

  if (child.stderr) {
    void (async () => {
      try {
        for await (const event of readLines(child.stderr)) {
          if (event.type === "line" && event.text) {
            logger.debug("agy.stderr", { pid: child.pid ?? null, line: event.text.slice(0, 500) });
          }
        }
      } catch {
        // stderr 随子进程关闭。
      }
    })();
  }

  let closePromise: Promise<void> | undefined;
  return {
    stdin: child.stdin,
    stdout: child.stdout,
    get pid() {
      return child.pid;
    },
    close() {
      if (closePromise) return closePromise;
      closePromise = new Promise<void>((resolve) => {
        if (child.exitCode !== null || child.signalCode !== null) {
          resolve();
          return;
        }
        const killTimer = setTimeout(() => {
          try {
            child.kill("SIGKILL");
          } catch {
            // 已退出。
          }
        }, 2_000);
        child.once("exit", () => {
          clearTimeout(killTimer);
          resolve();
        });
        try {
          child.stdin.end();
          child.kill("SIGTERM");
        } catch {
          clearTimeout(killTimer);
          resolve();
        }
      });
      return closePromise;
    },
  };
}

export async function startAgyAcpClient(
  spawnTransport: SpawnAgyTransport,
  spawnOptions: SpawnAgyAcpOptions,
  clientOptions: Omit<AcpClientOptions, "clientInfo"> = {},
  initOptions?: { timeoutMs?: number; signal?: AbortSignal },
): Promise<AcpClient> {
  if (initOptions?.signal?.aborted) {
    throw new RpcError(ErrorCode.internalError, "ACP startup aborted");
  }
  const transport = spawnTransport(spawnOptions);
  const client = new AcpClient(transport, {
    ...clientOptions,
    clientInfo: { name: ADAPTER_NAME, version: ADAPTER_VERSION },
    // 固定不声明 fs / terminal 反向委托（D6）。
    clientCapabilities: {},
  });
  try {
    await client.initialize(initOptions?.timeoutMs, initOptions?.signal);
    return client;
  } catch (error) {
    await client.close().catch(() => {});
    throw error;
  }
}

/**
 * 每个 `appDataDir`（`antigravity-cli` / `antigravity`）只维护唯一一个常驻 `agy acp` 服务进程，
 * 复用于目录查询、历史回放、模型/命令发现以及所有活跃对话回合。
 * 多个 `agy acp` 并发访问同一 `conversations/` 会触发 SQLite `database is locked` 导致新建会话丢失索引；
 * 统一复用单实例后既彻底消除锁冲突，又把 `thread/start` 与 `thread/list` 冷启动耗时从 ~5s 降至 ~30ms。
 */
export class SharedReadonlyAcp {
  private client: AcpClient | undefined;
  private connecting: { ready: Promise<AcpClient>; controller: AbortController; waiters: Set<symbol> } | undefined;
  private retiring: Promise<void> | undefined;
  private disposed = false;
  private readonly updateListeners = new Set<(sessionId: string, update: AcpSessionUpdate) => void>();

  constructor(
    private readonly executable: () => string,
    private readonly spawnTransport: SpawnAgyTransport,
    private readonly env: () => NodeJS.ProcessEnv = () => process.env,
    private readonly appDataDirName?: string,
    private readonly hasActiveTurn: () => boolean = () => false,
  ) {}

  subscribeUpdates(listener: (sessionId: string, update: AcpSessionUpdate) => void): () => void {
    this.updateListeners.add(listener);
    return () => {
      this.updateListeners.delete(listener);
    };
  }

  get pid(): number | undefined {
    return this.client && !this.client.isClosed ? this.client.pid : undefined;
  }

  async acquire(options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<AcpClient> {
    if (this.retiring) await this.retiring;
    if (this.disposed) {
      throw new RpcError(ErrorCode.internalError, "SharedReadonlyAcp has been closed");
    }
    const signal = options?.signal;
    if (signal?.aborted) {
      throw new RpcError(ErrorCode.internalError, "SharedReadonlyAcp acquire aborted");
    }
    if (this.client && !this.client.isClosed) return this.client;
    if (!this.connecting) {
      const controller = new AbortController();
      const ready = this.connect(controller.signal, options?.timeoutMs).finally(() => {
        this.connecting = undefined;
      });
      this.connecting = { ready, controller, waiters: new Set() };
    }
    const flight = this.connecting;
    if (flight.controller.signal.aborted) {
      await flight.ready.catch(() => {});
      return this.acquire(options);
    }
    const waiter = Symbol();
    flight.waiters.add(waiter);
    let onAbort: (() => void) | undefined;
    try {
      if (!signal) return await flight.ready;
      return await new Promise<AcpClient>((resolve, reject) => {
        onAbort = () => {
          flight.waiters.delete(waiter);
          if (flight.waiters.size === 0 && !this.hasActiveTurn()) {
            // A stalled cold start with no remaining owner is reclaimed before the next list retry.
            flight.controller.abort();
          } else {
            reject(new RpcError(ErrorCode.internalError, "SharedReadonlyAcp acquire aborted"));
          }
        };
        signal.addEventListener("abort", onAbort, { once: true });
        flight.ready.then(resolve, reject);
      });
    } finally {
      flight.waiters.delete(waiter);
      if (onAbort) signal?.removeEventListener("abort", onAbort);
    }
  }

  private async connect(signal: AbortSignal, timeoutMs?: number): Promise<AcpClient> {
    let createdClient: AcpClient | undefined;
    createdClient = await startAgyAcpClient(
      this.spawnTransport,
      {
        executable: this.executable(),
        cwd: os.tmpdir(),
        sandbox: false,
        ...(this.appDataDirName ? { appDataDirName: this.appDataDirName } : {}),
        env: this.env(),
      },
      {
        onSessionUpdate: (sessionId, update) => {
          for (const listener of this.updateListeners) {
            listener(sessionId, update);
          }
        },
        onClose: () => {
          if (this.client === createdClient) {
            this.client = undefined;
          }
        },
      },
      { signal, timeoutMs: Math.max(timeoutMs ?? 0, DEFAULT_ACP_INITIALIZE_TIMEOUT_MS) },
    );
    if (this.disposed || signal.aborted) {
      await createdClient.close().catch(() => {});
      throw new RpcError(ErrorCode.internalError, "SharedReadonlyAcp closed while connecting");
    }
    this.client = createdClient;
    return createdClient;
  }

  private async retireIfIdle(client: AcpClient): Promise<void> {
    if (this.client !== client || this.hasActiveTurn() || client.hasPendingWork) return;
    this.client = undefined;
    // Keep a single writer per data directory until the retiring process has actually exited.
    this.retiring = client.close().catch(() => {});
    try {
      await this.retiring;
    } finally {
      this.retiring = undefined;
    }
  }

  async use<T>(fn: (client: AcpClient) => Promise<T>, options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<T> {
    const client = await this.acquire(options);
    try {
      return await fn(client);
    } catch (error) {
      if (options?.signal?.aborted) {
        await this.retireIfIdle(client);
        throw error;
      }
      if (client.isClosed && !this.disposed) {
        const retryClient = await this.acquire(options);
        return await fn(retryClient);
      }
      throw error;
    }
  }

  async close(): Promise<void> {
    this.disposed = true;
    this.connecting?.controller.abort();
    await this.connecting?.ready.catch(() => {});
    await this.retiring;
    const current = this.client;
    this.client = undefined;
    if (current) {
      await current.close().catch(() => {});
    }
  }
}

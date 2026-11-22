import os from "node:os";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { ErrorCode, RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import { readLines } from "@mimi/appserver-kit/rpc/lines.ts";
import { logger } from "../util/logging.ts";
import { AcpClient, type AcpClientOptions, type AcpTransport } from "../acp/client.ts";
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
  private connecting: Promise<AcpClient> | undefined;
  private disposed = false;
  private readonly updateListeners = new Set<(sessionId: string, update: AcpSessionUpdate) => void>();

  constructor(
    private readonly executable: () => string,
    private readonly spawnTransport: SpawnAgyTransport,
    private readonly env: () => NodeJS.ProcessEnv = () => process.env,
    private readonly appDataDirName?: string,
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
    if (this.disposed) {
      throw new RpcError(ErrorCode.internalError, "SharedReadonlyAcp has been closed");
    }
    if (options?.signal?.aborted) {
      throw new RpcError(ErrorCode.internalError, "SharedReadonlyAcp acquire aborted");
    }
    if (this.client && !this.client.isClosed) {
      return this.client;
    }
    if (this.connecting) {
      const inflight = this.connecting;
      if (!options?.signal) return inflight;
      return await new Promise<AcpClient>((resolve, reject) => {
        const onAbort = () => reject(new RpcError(ErrorCode.internalError, "SharedReadonlyAcp acquire aborted"));
        options.signal!.addEventListener("abort", onAbort, { once: true });
        inflight.then(
          (value) => {
            options.signal!.removeEventListener("abort", onAbort);
            resolve(value);
          },
          (err) => {
            options.signal!.removeEventListener("abort", onAbort);
            reject(err);
          },
        );
      });
    }
    let createdClient: AcpClient | undefined;
    const connectPromise = startAgyAcpClient(
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
      options,
    );
    this.connecting = connectPromise;
    try {
      createdClient = await connectPromise;
      if (this.disposed || options?.signal?.aborted) {
        await createdClient.close().catch(() => {});
        throw new RpcError(ErrorCode.internalError, "SharedReadonlyAcp closed while connecting");
      }
      this.client = createdClient;
      return createdClient;
    } finally {
      if (this.connecting === connectPromise) {
        this.connecting = undefined;
      }
    }
  }

  /**
   * 主动关闭并清理卡死的常驻子进程而不置 disposed，使下一次请求可重新拉起健康进程（C10）。
   * 若传入 expectedClient，则仅回收发起超时的对应实例，避免误杀已恢复的新实例（C10 round4）。
   */
  async reset(expectedClient?: AcpClient): Promise<void> {
    if (expectedClient && this.client !== expectedClient) {
      await expectedClient.close().catch(() => {});
      return;
    }
    const current = this.client;
    this.client = undefined;
    if (current) {
      await current.close().catch(() => {});
    }
  }

  async use<T>(fn: (client: AcpClient) => Promise<T>, options?: { timeoutMs?: number; signal?: AbortSignal }): Promise<T> {
    const client = await this.acquire(options);
    try {
      return await fn(client);
    } catch (error) {
      if (options?.signal?.aborted) {
        await this.reset(client);
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
    const current = this.client;
    this.client = undefined;
    if (current) {
      await current.close().catch(() => {});
    }
  }
}

import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { ErrorCode, RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import { readLines } from "@mimi/appserver-kit/rpc/lines.ts";
import { logger } from "../util/logging.ts";
import { AcpClient, type AcpClientOptions, type AcpTransport } from "../acp/client.ts";
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
  env?: NodeJS.ProcessEnv;
}

export type SpawnAgyTransport = (options: SpawnAgyAcpOptions) => AcpTransport;

export function defaultSpawnAgyTransport(options: SpawnAgyAcpOptions): AcpTransport {
  const cleanEnv = sanitizeAgyEnv(options.env ?? process.env);
  const paths = resolveAgyDataPaths(options.env ?? process.env);
  const args = ["acp", "--stdio"];
  if (paths.geminiDirName !== ".gemini") {
    args.push("--gemini-dir", paths.geminiDirName);
  }
  if (paths.appDataDirName !== "antigravity-cli") {
    args.push("--app-data-dir", paths.appDataDirName);
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
): Promise<AcpClient> {
  const transport = spawnTransport(spawnOptions);
  const client = new AcpClient(transport, {
    ...clientOptions,
    clientInfo: { name: ADAPTER_NAME, version: ADAPTER_VERSION },
    // 固定不声明 fs / terminal 反向委托（D6）。
    clientCapabilities: {},
  });
  try {
    await client.initialize();
    return client;
  } catch (error) {
    await client.close().catch(() => {});
    throw error;
  }
}

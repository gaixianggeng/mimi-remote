// 以 iPhone 的方式连本机 agentd 网关：同一个 WebSocket 入口、同一个 Bearer 令牌、同样的
// JSON-RPC。只在本机使用，令牌只放请求头，不打印。
import { readFileSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

export interface AgentdConfig {
  listen: string;
  token: string;
  scanRoots: string[];
  codexEnabled: boolean;
}

export function defaultConfigPath(): string {
  if (process.env.MIMI_AGENTD_CONFIG) return process.env.MIMI_AGENTD_CONFIG;
  return path.join(os.homedir(), "Library", "Application Support", "mimi-remote", "config.json");
}

const expandHome = (value: string) => (value.startsWith("~") ? path.join(os.homedir(), value.slice(1)) : value);

export function loadAgentdConfig(file = defaultConfigPath()): AgentdConfig {
  const raw = JSON.parse(readFileSync(file, "utf8")) as Record<string, any>;
  const token = raw.auth?.token;
  if (typeof raw.listen !== "string" || typeof token !== "string" || !token) throw new Error(`${file} 缺少 listen 或 auth.token`);
  return {
    listen: raw.listen,
    token,
    scanRoots: (Array.isArray(raw.scan_roots) ? raw.scan_roots : []).map((root: string) => expandHome(String(root))),
    codexEnabled: raw.codex?.enabled === true,
  };
}

/**
 * 直连本机网关：在 TCP 上直接发一个 HTTP/1.1 请求。Bun 的 fetch 和 node:http 都会读
 * HTTP_PROXY 等环境变量，把本机地址也转给代理。
 */
export function httpJson(config: AgentdConfig, route: string): Promise<any> {
  const separator = config.listen.lastIndexOf(":");
  const host = config.listen.slice(0, separator).replace(/^\[|\]$/g, "");
  const port = Number(config.listen.slice(separator + 1));
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const socket = net.connect({ host, port }, () => {
      socket.write(
        `GET ${route} HTTP/1.1\r\nHost: ${config.listen}\r\nAuthorization: Bearer ${config.token}\r\nAccept: application/json\r\nConnection: close\r\n\r\n`,
      );
    });
    socket.setTimeout(30_000, () => socket.destroy(new Error(`GET ${route} 超时`)));
    socket.on("data", (chunk: Buffer) => chunks.push(chunk));
    socket.on("error", reject);
    socket.on("end", () => {
      const raw = Buffer.concat(chunks);
      const split = raw.indexOf("\r\n\r\n");
      const head = raw.subarray(0, split).toString("latin1");
      const status = Number(head.split(" ")[1]);
      let body: Buffer<ArrayBufferLike> = raw.subarray(split + 4);
      if (/^transfer-encoding:\s*chunked/im.test(head)) body = dechunk(body);
      if (status !== 200) return reject(new Error(`GET ${route} 返回 HTTP ${status}`));
      try {
        resolve(JSON.parse(body.toString("utf8")));
      } catch (error) {
        reject(error);
      }
    });
  });
}

/** 按字节解开 chunked 编码（块大小是字节数，不能在字符串上切）。 */
function dechunk(body: Buffer<ArrayBufferLike>): Buffer<ArrayBufferLike> {
  const parts: Buffer<ArrayBufferLike>[] = [];
  let offset = 0;
  while (offset < body.length) {
    const lineEnd = body.indexOf("\r\n", offset);
    if (lineEnd < 0) break;
    const size = parseInt(body.subarray(offset, lineEnd).toString("latin1"), 16);
    if (!size) break;
    parts.push(body.subarray(lineEnd + 2, lineEnd + 2 + size));
    offset = lineEnd + 2 + size + 2;
  }
  return Buffer.concat(parts);
}

export interface RpcResult {
  result?: any;
  error?: { code: number; message: string; data?: any };
}

export interface Frame {
  method?: string;
  id?: unknown;
  params?: any;
  result?: any;
  error?: any;
  at: number;
}

export class GatewayClient {
  readonly frames: Frame[] = [];
  private nextId = 1;
  private readonly waiters = new Map<unknown, (frame: Frame) => void>();

  private constructor(private readonly socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      const frame = { ...(JSON.parse(String(event.data)) as Omit<Frame, "at">), at: Date.now() } as Frame;
      if (frame.id !== undefined && frame.method === undefined && this.waiters.has(frame.id)) {
        this.waiters.get(frame.id)!(frame);
        this.waiters.delete(frame.id);
        return;
      }
      this.frames.push(frame);
    });
  }

  /** 每个连接用独立的 session key，和不同设备一样互不干扰。 */
  static connect(config: AgentdConfig, sessionKey: string): Promise<GatewayClient> {
    const url = `ws://${config.listen}/api/app-server/ws?runtime=claude&session=${encodeURIComponent(sessionKey)}`;
    // Bun 的 WebSocket 支持自定义请求头。
    const socket = new WebSocket(url, { headers: { Authorization: `Bearer ${config.token}` } } as never);
    return new Promise((resolve, reject) => {
      socket.addEventListener("open", () => resolve(new GatewayClient(socket)), { once: true });
      socket.addEventListener("error", () => reject(new Error(`无法连接 ${config.listen} 的网关`)), { once: true });
    });
  }

  async initialize(): Promise<void> {
    const response = await this.call("initialize", { clientInfo: { name: "mimi-acceptance", title: "Mimi acceptance", version: "0" } });
    if (response.error) throw new Error(`initialize 失败：${response.error.message}`);
  }

  call(method: string, params: unknown, timeoutMs = 90_000): Promise<RpcResult> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(id);
        reject(new Error(`${method} 超过 ${Math.round(timeoutMs / 1000)} 秒没有响应`));
      }, timeoutMs);
      this.waiters.set(id, (frame) => {
        clearTimeout(timer);
        resolve({ result: frame.result, error: frame.error });
      });
      this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  /** 答复服务端请求（审批、提问）。 */
  respond(id: unknown, result: unknown): void {
    this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
  }

  async waitFor(predicate: (frame: Frame) => boolean, timeoutMs: number, label: string): Promise<Frame> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const found = this.frames.find(predicate);
      if (found) return found;
      await Bun.sleep(50);
    }
    throw new Error(`等不到 ${label}（${Math.round(timeoutMs / 1000)} 秒）`);
  }

  close(): void {
    this.socket.close();
  }
}

/** iPhone 发消息时的输入格式。 */
export const textInput = (text: string) => [{ type: "text", text, text_elements: [] }];

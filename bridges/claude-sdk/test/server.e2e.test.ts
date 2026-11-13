// 以 agentd 的方式启动适配器进程：--socket（Windows 上 --tcp-listen）常驻，先 attach 再收发 JSON-RPC。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { TranscriptBuilder } from "./support/transcripts.ts";

const entry = path.join(import.meta.dir, "..", "src", "main.ts");
const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-sock-")));
const socketPath = path.join(sandbox, "bridge.sock");
const env = {
  ...process.env,
  CLAUDE_CONFIG_DIR: path.join(sandbox, "claude"),
  MIMI_CLAUDE_ADAPTER_STATE_DIR: path.join(sandbox, "state"),
  MIMI_CLAUDE_LEGACY_INDEX: "",
};
let child: ChildProcess;

class Client {
  private buffer = "";
  private waiters: Array<{ matches(frame: any): boolean; resolve(frame: any): void }> = [];
  private queue: any[] = [];

  private constructor(private readonly socket: net.Socket) {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      this.buffer += chunk;
      let index = this.buffer.indexOf("\n");
      while (index >= 0) {
        const frame = JSON.parse(this.buffer.slice(0, index));
        this.buffer = this.buffer.slice(index + 1);
        const waiterIndex = this.waiters.findIndex((waiter) => waiter.matches(frame));
        if (waiterIndex >= 0) this.waiters.splice(waiterIndex, 1)[0]!.resolve(frame);
        else this.queue.push(frame);
        index = this.buffer.indexOf("\n");
      }
    });
  }

  static connect(target: string | net.TcpNetConnectOpts = socketPath): Promise<Client> {
    return new Promise((resolve, reject) => {
      const socket = typeof target === "string" ? net.createConnection(target) : net.createConnection(target);
      socket.once("connect", () => resolve(new Client(socket)));
      socket.once("error", reject);
    });
  }

  send(frame: unknown): void {
    this.socket.write(`${JSON.stringify(frame)}\n`);
  }

  next(): Promise<any> {
    return this.nextMatching(() => true);
  }

  /** TCP 连接可能穿插所有权通知；按 id 取请求响应，并保留其他帧供后续断言。 */
  response(id: string | number): Promise<any> {
    return this.nextMatching((frame) => frame.id === id);
  }

  private nextMatching(matches: (frame: any) => boolean): Promise<any> {
    const queuedIndex = this.queue.findIndex(matches);
    if (queuedIndex >= 0) return Promise.resolve(this.queue.splice(queuedIndex, 1)[0]);
    return new Promise((resolve) => this.waiters.push({ matches, resolve }));
  }

  close(): void {
    this.socket.end();
  }
}

beforeAll(async () => {
  const session = new TranscriptBuilder("77777777-7777-4777-8777-777777777777", path.join(sandbox, "project"));
  session.user("hello from fixture");
  session.write(env.CLAUDE_CONFIG_DIR);
  child = spawn(process.execPath, [entry, "--socket", socketPath], { env, stdio: ["ignore", "ignore", "pipe"] });
  const deadline = Date.now() + 10_000;
  while (!existsSync(socketPath)) {
    if (Date.now() > deadline) throw new Error("adapter did not bind its socket");
    await Bun.sleep(25);
  }
});

afterAll(() => {
  child?.kill("SIGTERM");
  rmSync(sandbox, { recursive: true, force: true });
});

describe("socket server", () => {
  test("--version prints a parseable semantic version", () => {
    const result = spawnSync(process.execPath, [entry, "--version"], { encoding: "utf8" });
    expect(result.stdout.trim()).toMatch(/^mimi-claude-adapter \d+\.\d+\.\d+$/);
  });

  test("--capabilities declares exactly the registered methods", () => {
    const result = spawnSync(process.execPath, [entry, "--capabilities"], { encoding: "utf8", env });
    const declared = JSON.parse(result.stdout);
    expect(declared).toMatchObject({ name: "mimi-claude-adapter", fullAccess: true, claudeCode: { minimumVersion: "2.1.294" } });
    expect(declared.methods).toEqual(
      expect.arrayContaining(["initialized", "thread/list", "turn/start", "turn/steer", "turn/interrupt", "model/list", "account/rateLimits/read", "thread/name/set"]),
    );
    expect(declared.methods).not.toContain("review/start");
  });

  test("attach acknowledges, leaves responses unsequenced and resumes by key", async () => {
    const client = await Client.connect();
    client.send({ jsonrpc: "2.0", method: "_alleycat/attach", params: { sessionKey: "ipad-1", lastSeen: 0 } });
    const ack = await client.next();
    expect(ack).toMatchObject({ method: "_alleycat/attached", params: { sessionKey: "ipad-1", kind: "fresh", currentSeq: 0 } });

    client.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "t", version: "0" } } });
    const init = await client.next();
    expect(init.result.userAgent).toMatch(/^mimi-claude-adapter\//);
    expect(init._alleycat_seq).toBeUndefined();

    client.send({ jsonrpc: "2.0", id: 2, method: "thread/list", params: {} });
    const list = await client.next();
    expect(list.result.data.map((thread: any) => thread.preview)).toEqual(["hello from fixture"]);
    expect(list._alleycat_seq).toBeUndefined();

    client.send({ jsonrpc: "2.0", id: 3, method: "review/start", params: {} });
    const unsupported = await client.next();
    expect(unsupported.error.code).toBe(-32601);
    client.close();

    const again = await Client.connect();
    again.send({ jsonrpc: "2.0", method: "_alleycat/attach", params: { sessionKey: "ipad-1", lastSeen: 0 } });
    const resumed = await again.next();
    // 响应不入重放环，三次请求之后序号仍为 0（#910）。
    expect(resumed.params).toMatchObject({ kind: "resumed", currentSeq: 0 });
    // 响应不重放：下一帧应该是新请求的应答。
    again.send({ jsonrpc: "2.0", id: 9, method: "thread/loaded/list", params: {} });
    const loaded = await again.next();
    expect(loaded).toMatchObject({ id: 9, result: { data: [] } });
    again.close();
  });

  test("a connection without attach is served as an isolated session", async () => {
    const client = await Client.connect();
    client.send({ jsonrpc: "2.0", id: 1, method: "thread/list", params: { limit: 1 } });
    const list = await client.next();
    expect(list.result.data).toHaveLength(1);
    client.close();
  });
});

/** 与 agentd 在 Windows 上的做法相同：先占一个回环端口，释放后交给适配器绑定。 */
async function freePort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>((resolve) => server.listen({ host: "127.0.0.1", port: 0 }, resolve));
  const { port } = server.address() as net.AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

describe("tcp server", () => {
  test("--tcp-listen serves the same protocol on a loopback port", async () => {
    const port = await freePort();
    const tcp = spawn(process.execPath, [entry, "--tcp-listen", `127.0.0.1:${port}`], {
      env: { ...env, MIMI_CLAUDE_ADAPTER_STATE_DIR: path.join(sandbox, "state-tcp") },
      stdio: ["ignore", "ignore", "pipe"],
    });
    try {
      let client: Client | undefined;
      const deadline = Date.now() + 10_000;
      while (!client) {
        client = await Client.connect({ host: "127.0.0.1", port }).catch(() => undefined);
        if (!client && Date.now() > deadline) throw new Error("adapter did not bind its tcp port");
        if (!client) await Bun.sleep(25);
      }
      client.send({ jsonrpc: "2.0", method: "_alleycat/attach", params: { sessionKey: "windows-1", lastSeen: 0 } });
      expect(await client.next()).toMatchObject({ method: "_alleycat/attached", params: { kind: "fresh" } });
      client.send({ jsonrpc: "2.0", id: 1, method: "thread/list", params: {} });
      const list = await client.response(1);
      expect(list.result.data.map((thread: any) => thread.preview)).toEqual(["hello from fixture"]);
      client.close();
    } finally {
      tcp.kill("SIGTERM");
    }
  });

  test("non-loopback addresses and two transports are refused before binding", () => {
    const outside = spawnSync(process.execPath, [entry, "--tcp-listen", "0.0.0.0:7777"], { encoding: "utf8", env });
    expect(outside.status).toBe(1);
    expect(outside.stderr).toContain("只能使用回环地址");
    const both = spawnSync(process.execPath, [entry, "--socket", `${socketPath}-x`, "--tcp-listen", "127.0.0.1:7777"], { encoding: "utf8", env });
    expect(both.status).toBe(1);
    expect(both.stderr).toContain("只能选一个");
  });
});

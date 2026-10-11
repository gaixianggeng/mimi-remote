// 以 agentd 的方式启动适配器进程：--socket 常驻，先 attach 再收发 JSON-RPC。
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
  private waiters: Array<(frame: any) => void> = [];
  private queue: any[] = [];

  private constructor(private readonly socket: net.Socket) {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      this.buffer += chunk;
      let index = this.buffer.indexOf("\n");
      while (index >= 0) {
        const frame = JSON.parse(this.buffer.slice(0, index));
        this.buffer = this.buffer.slice(index + 1);
        const waiter = this.waiters.shift();
        if (waiter) waiter(frame);
        else this.queue.push(frame);
        index = this.buffer.indexOf("\n");
      }
    });
  }

  static connect(): Promise<Client> {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(socketPath, () => resolve(new Client(socket)));
      socket.once("error", reject);
    });
  }

  send(frame: unknown): void {
    this.socket.write(`${JSON.stringify(frame)}\n`);
  }

  next(): Promise<any> {
    const queued = this.queue.shift();
    if (queued) return Promise.resolve(queued);
    return new Promise((resolve) => this.waiters.push(resolve));
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
    expect(declared).toMatchObject({ name: "mimi-claude-adapter", fullAccess: true });
    expect(declared.methods).toEqual(expect.arrayContaining(["thread/list", "turn/start", "turn/steer", "turn/interrupt"]));
    expect(declared.methods).not.toContain("review/start");
  });

  test("attach acknowledges, stamps sequence numbers and resumes by key", async () => {
    const client = await Client.connect();
    client.send({ jsonrpc: "2.0", method: "_alleycat/attach", params: { sessionKey: "ipad-1", lastSeen: 0 } });
    const ack = await client.next();
    expect(ack).toMatchObject({ method: "_alleycat/attached", params: { sessionKey: "ipad-1", kind: "fresh", currentSeq: 0 } });

    client.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "t", version: "0" } } });
    const init = await client.next();
    expect(init.result.userAgent).toMatch(/^mimi-claude-adapter\//);
    expect(init._alleycat_seq).toBe(1);

    client.send({ jsonrpc: "2.0", id: 2, method: "thread/list", params: {} });
    const list = await client.next();
    expect(list.result.data.map((thread: any) => thread.preview)).toEqual(["hello from fixture"]);
    expect(list._alleycat_seq).toBe(2);

    client.send({ jsonrpc: "2.0", id: 3, method: "review/start", params: {} });
    const unsupported = await client.next();
    expect(unsupported.error.code).toBe(-32601);
    client.close();

    const again = await Client.connect();
    again.send({ jsonrpc: "2.0", method: "_alleycat/attach", params: { sessionKey: "ipad-1", lastSeen: 1 } });
    const resumed = await again.next();
    expect(resumed.params).toMatchObject({ kind: "resumed", currentSeq: 3 });
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

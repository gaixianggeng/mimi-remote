import { rm } from "node:fs/promises";
import net from "node:net";
import { createRouter } from "./app.ts";
import { serveConnection } from "./server/connection.ts";
import { SessionRegistry } from "./session/registry.ts";
import { ADAPTER_NAME, ADAPTER_VERSION } from "./version.ts";

const USAGE = `用法：
  ${ADAPTER_NAME} --version
  ${ADAPTER_NAME} --socket <path>   在 Unix socket 上服务（agentd 常驻模式）
  ${ADAPTER_NAME}                   在标准输入输出上服务一条连接
`;

// 日志只写 stderr：stdout 在 stdio 模式下是协议通道。agentd 会采集 stderr。
const log = (message: string) => process.stderr.write(`[${ADAPTER_NAME}] ${message}\n`);

async function serveSocket(socketPath: string): Promise<void> {
  const registry = new SessionRegistry();
  registry.startReaper();
  const router = createRouter({ log });
  await rm(socketPath, { force: true });
  const server = net.createServer((socket) => {
    socket.on("error", () => socket.destroy());
    serveConnection(socket, socket, { registry, router, log })
      .catch((error) => log(`connection failed: ${error instanceof Error ? error.message : String(error)}`))
      .finally(() => socket.end());
  });
  const shutdown = () => {
    server.close();
    void rm(socketPath, { force: true }).finally(() => process.exit(0));
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
  log(`listening on ${socketPath}`);
}

async function serveStdio(): Promise<void> {
  const registry = new SessionRegistry();
  await serveConnection(process.stdin, process.stdout, { registry, router: createRouter({ log }), log });
}

async function main(argv: string[]): Promise<void> {
  if (argv.includes("--version") || argv.includes("-V")) {
    process.stdout.write(`${ADAPTER_NAME} ${ADAPTER_VERSION}\n`);
    return;
  }
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(USAGE);
    return;
  }
  const socketIndex = argv.indexOf("--socket");
  if (socketIndex >= 0) {
    const socketPath = argv[socketIndex + 1];
    if (!socketPath) throw new Error("--socket 需要路径参数");
    await serveSocket(socketPath);
    return;
  }
  await serveStdio();
}

main(process.argv.slice(2)).catch((error) => {
  log(error instanceof Error ? (error.stack ?? error.message) : String(error));
  process.exit(1);
});

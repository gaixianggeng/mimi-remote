import { rm } from "node:fs/promises";
import net from "node:net";
import { capabilityDeclaration, createApp, type App } from "./app.ts";
import { serveConnection } from "./server/connection.ts";
import { describeListen, parseListenArgs, type ListenTarget } from "./server/listen.ts";
import { SessionRegistry } from "./session/registry.ts";
import type { Session } from "./session/session.ts";
import { errorText, logEnabled, logText, logger } from "./util/logging.ts";
import { ADAPTER_NAME, ADAPTER_VERSION } from "./version.ts";

const USAGE = `用法：
  ${ADAPTER_NAME} --version
  ${ADAPTER_NAME} --capabilities  输出能力声明（JSON），供 agentd 探测
  ${ADAPTER_NAME} --socket <path>   在 Unix socket 上服务（agentd 常驻模式）
  ${ADAPTER_NAME} --tcp-listen <回环IP>:<端口>   在本机回环 TCP 上服务（Windows 上的常驻模式）
  ${ADAPTER_NAME}                   在标准输入输出上服务一条连接
`;

// 日志只写 stderr：stdout 在 stdio 模式下是协议通道。agentd 会采集 stderr 并按级别分流。
const log = (message: string) => logText("info", message);

/**
 * 会话注册表与对话运行时的联动：忙碌的会话不回收，回收时取消订阅；列表级通知（持有方变化）
 * 广播给注册表里的全部会话。注册表先于 app 建立，app 通过闭包延迟引用它。
 */
function wire(): { registry: SessionRegistry; app: App } {
  let app: App | undefined;
  const registry = new SessionRegistry({
    idleTtlMs: 600_000,
    onExpire: (session) => app?.manager.unsubscribeSession(session),
  });
  app = createApp({ log, broadcast: (frame) => registry.publishAll(frame) });
  const created = app;
  registry.onCreate = (session) => session.setBusyCheck(() => created.manager.isSessionBusy(session));
  return { registry, app: created };
}

function connectionDeps(app: App, registry: SessionRegistry) {
  return {
    registry,
    router: app.router,
    log,
    onClientResponse: (session: Session, generation: number, frame: Record<string, unknown>) =>
      app.manager.handleClientResponse(session, generation, frame),
    onAnonymousSessionEnd: (session: Session) => app.manager.unsubscribeSession(session),
  };
}

async function serve(target: ListenTarget): Promise<void> {
  const { registry, app } = wire();
  registry.startReaper();
  // 列表页不订阅会话；要让终端里的会话开始 / 结束处理推到列表，登记监听必须从一开始就在。
  app.manager.startOwnershipWatcher();
  // 常驻模式下预热模型目录，让首个 model/list 命中缓存，而不是等 CLI 冷启动。
  app.models.warm();
  const removeSocket = () => (target.kind === "unix" ? rm(target.path, { force: true }) : Promise.resolve());
  await removeSocket();
  const server = net.createServer((socket) => {
    socket.on("error", () => socket.destroy());
    serveConnection(socket, socket, connectionDeps(app, registry))
      .catch((error) => log(`connection failed: ${error instanceof Error ? error.message : String(error)}`))
      .finally(() => socket.end());
  });
  const shutdown = () => {
    server.close();
    void Promise.allSettled([app.manager.closeAll(), removeSocket()]).finally(() => process.exit(0));
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    if (target.kind === "unix") server.listen(target.path, () => resolve());
    else server.listen({ host: target.host, port: target.port, exclusive: true }, () => resolve());
  });
  log(`listening on ${describeListen(target, server.address())}`);
  // 旧 bridge 里的 Mimi 名称：后台执行，不挡住连接。
  void app.migrateLegacyNames().catch((error) => logger.warn("legacy.names.failed", { error: errorText(error) }));
  logger.info("adapter.start", { version: ADAPTER_VERSION, mode: target.kind === "unix" ? "socket" : "tcp", debug: logEnabled("debug") });
}

async function serveStdio(): Promise<void> {
  const { registry, app } = wire();
  app.manager.startOwnershipWatcher();
  await serveConnection(process.stdin, process.stdout, connectionDeps(app, registry));
  await app.manager.closeAll();
}

async function main(argv: string[]): Promise<void> {
  if (argv.includes("--version") || argv.includes("-V")) {
    process.stdout.write(`${ADAPTER_NAME} ${ADAPTER_VERSION}\n`);
    return;
  }
  if (argv.includes("--capabilities")) {
    process.stdout.write(`${JSON.stringify(capabilityDeclaration(createApp({ log }).router))}\n`);
    return;
  }
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(USAGE);
    return;
  }
  const target = parseListenArgs(argv);
  if (target) {
    await serve(target);
    return;
  }
  await serveStdio();
}

main(process.argv.slice(2)).catch((error) => {
  logText("error", error instanceof Error ? (error.stack ?? error.message) : String(error));
  process.exit(1);
});

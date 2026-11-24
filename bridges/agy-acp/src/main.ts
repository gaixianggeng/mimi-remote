import { rm } from "node:fs/promises";
import net from "node:net";
import { serveConnection } from "@mimi/appserver-kit/server/connection.ts";
import { describeListen, parseListenArgs, type ListenTarget } from "@mimi/appserver-kit/server/listen.ts";
import { SessionRegistry } from "@mimi/appserver-kit/session/registry.ts";
import type { Session } from "@mimi/appserver-kit/session/session.ts";
import { logEnabled, logText, logger } from "./util/logging.ts";
import { capabilityDeclaration, createApp, type App } from "./app.ts";
import { ADAPTER_NAME, ADAPTER_VERSION } from "./version.ts";

const USAGE = `用法：
  ${ADAPTER_NAME} --version
  ${ADAPTER_NAME} --capabilities  输出能力声明（JSON），供 agentd 探测
  ${ADAPTER_NAME} --socket <path>   在 Unix socket 上服务（agentd 常驻模式）
  ${ADAPTER_NAME} --tcp-listen <回环IP>:<端口>   在本机回环 TCP 上服务（Windows 常驻模式）
  ${ADAPTER_NAME}                   在标准输入输出上服务一条连接
`;

const log = (message: string) => logText("info", message);

function wire(): { registry: SessionRegistry; app: App } {
  let app: App | undefined;
  const registry = new SessionRegistry({
    idleTtlMs: 600_000,
    onExpire: (session) => app?.manager.unsubscribeSession(session),
  });
  app = createApp({ log });
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
  app.models.warm();
  app.rateLimits.warm();
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
    void Promise.allSettled([app.close(), removeSocket()]).finally(() => process.exit(0));
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    if (target.kind === "unix") server.listen(target.path, () => resolve());
    else server.listen({ host: target.host, port: target.port, exclusive: true }, () => resolve());
  });
  log(`listening on ${describeListen(target, server.address())}`);
  logger.info("adapter.start", { version: ADAPTER_VERSION, mode: target.kind === "unix" ? "socket" : "tcp", debug: logEnabled("debug") });
}

async function serveStdio(): Promise<void> {
  const { registry, app } = wire();
  await serveConnection(process.stdin, process.stdout, connectionDeps(app, registry));
  await app.close();
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

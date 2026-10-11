import type { Readable, Writable } from "node:stream";
import { ErrorCode, classifyFrame, errorFrame, type OutboundFrame } from "../rpc/frames.ts";
import { readLines } from "../rpc/lines.ts";
import { SessionRegistry } from "../session/registry.ts";
import { Session, type AttachOutcome } from "../session/session.ts";
import type { Logger, Router } from "./router.ts";

export const ATTACH_METHOD = "_alleycat/attach";
export const ATTACHED_METHOD = "_alleycat/attached";

interface AttachParams {
  sessionKey: string;
  lastSeen?: number;
}

function parseAttach(value: unknown): AttachParams | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const frame = value as Record<string, unknown>;
  if (frame.method !== ATTACH_METHOD) return undefined;
  const params = (frame.params ?? {}) as Record<string, unknown>;
  const sessionKey = params.sessionKey;
  if (typeof sessionKey !== "string" || sessionKey === "") return undefined;
  const lastSeen = params.lastSeen;
  return {
    sessionKey,
    ...(typeof lastSeen === "number" && Number.isInteger(lastSeen) && lastSeen >= 0 ? { lastSeen } : {}),
  };
}

function parseLine(text: string): { ok: true; value: unknown } | { ok: false } {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false };
  }
}

export interface ConnectionDeps {
  registry: SessionRegistry;
  router: Router;
  log: Logger;
}

/**
 * 服务一条连接。首帧若是 `_alleycat/attach` 就绑定到具名会话（断线可续传）；
 * 否则是 agentd 内部任务用的匿名连接，会话随连接结束而丢弃。
 */
export async function serveConnection(input: Readable, output: Writable, deps: ConnectionDeps): Promise<void> {
  const write = (frame: OutboundFrame) => {
    if (!output.writableEnded && !output.destroyed) output.write(`${JSON.stringify(frame)}\n`);
  };
  const lines = readLines(input);
  let session: Session | undefined;
  let outcome: AttachOutcome | undefined;
  let pendingFirst: unknown;
  let hasPendingFirst = false;

  const first = await lines.next();
  if (first.done) return;
  if (first.value.type === "line") {
    const parsed = parseLine(first.value.text);
    const attach = parsed.ok ? parseAttach(parsed.value) : undefined;
    if (attach) {
      const resolved = deps.registry.resolve(attach.sessionKey);
      session = resolved.session;
      outcome = session.attach(attach.lastSeen, write, resolved.existed);
      write({
        jsonrpc: "2.0",
        method: ATTACHED_METHOD,
        params: {
          sessionKey: attach.sessionKey,
          kind: outcome.kind,
          currentSeq: outcome.currentSeq,
          floorSeq: outcome.floorSeq,
        },
      });
      session.flushBacklog(outcome.backlog, outcome.generation);
    } else {
      const claimsAttach = parsed.ok && (parsed.value as { method?: unknown })?.method === ATTACH_METHOD;
      if (claimsAttach) deps.log("ignoring malformed attach preamble; serving an isolated session");
      else {
        pendingFirst = parsed.ok ? parsed.value : undefined;
        hasPendingFirst = true;
        if (!parsed.ok) write(errorFrame(null, { code: ErrorCode.parseError, message: "invalid JSON" }));
      }
    }
  }
  if (!session || !outcome) {
    session = new Session("anonymous");
    outcome = session.attach(undefined, write, false);
  }

  const active = session;
  const generation = outcome.generation;
  const inflight = new Set<Promise<void>>();
  const handle = (value: unknown) => {
    const classified = classifyFrame(value);
    switch (classified.kind) {
      case "request": {
        const task = deps.router
          .dispatch(classified.frame, { session: active, generation })
          .then((response) => active.respond(response, generation));
        inflight.add(task);
        void task.finally(() => inflight.delete(task));
        return;
      }
      case "notification":
      case "response":
        // `initialized` 等通知无需处理；对服务端请求的应答在驱动对话阶段接入。
        return;
      case "invalid":
        active.respond(errorFrame(null, { code: ErrorCode.invalidRequest, message: classified.reason }), generation);
    }
  };

  try {
    if (hasPendingFirst && pendingFirst !== undefined) handle(pendingFirst);
    for await (const event of lines) {
      if (event.type === "oversize") {
        active.respond(errorFrame(null, { code: ErrorCode.invalidRequest, message: "frame too large" }), generation);
        continue;
      }
      const parsed = parseLine(event.text);
      if (!parsed.ok) {
        active.respond(errorFrame(null, { code: ErrorCode.parseError, message: "invalid JSON" }), generation);
        continue;
      }
      handle(parsed.value);
    }
    await Promise.allSettled([...inflight]);
  } finally {
    active.detach(generation);
  }
}

import { describe, expect, test } from "bun:test";
import { PassThrough } from "node:stream";
import { serveConnection } from "../src/server/connection.ts";
import { Router } from "../src/server/router.ts";
import { ReplayRing, SEQ_FIELD } from "../src/session/ring.ts";
import { SessionRegistry } from "../src/session/registry.ts";
import { Session } from "../src/session/session.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";

const note = (n: number): OutboundFrame => ({ jsonrpc: "2.0", method: "turn/started", params: { n } });

describe("ReplayRing", () => {
  test("stamps sequence numbers and replays after a cursor", () => {
    const ring = new ReplayRing();
    ring.push(note(1));
    ring.push(note(2));
    const third = ring.push(note(3));
    expect(third.frame[SEQ_FIELD]).toBe(3);
    const replay = ring.replayFrom(1);
    expect(replay.ok && replay.frames.map((entry) => entry.seq)).toEqual([2, 3]);
    expect(ring.replayFrom(3)).toEqual({ ok: true, frames: [] });
    // 来自别的实例、超过当前序号的游标不报错，也不重放。
    expect(ring.replayFrom(99)).toEqual({ ok: true, frames: [] });
  });

  test("evicts from the front and reports drift for cursors below the floor", () => {
    const ring = new ReplayRing(2);
    for (let n = 1; n <= 4; n += 1) ring.push(note(n));
    expect(ring.floorSeq).toBe(3);
    expect(ring.replayFrom(1)).toEqual({ ok: false, drift: true });
    const replay = ring.replayFrom(2);
    expect(replay.ok && replay.frames.map((entry) => entry.seq)).toEqual([3, 4]);
  });

  test.each(["hello", "中文", "🙂🚀"])("enforces exact UTF-8 byte boundaries for %s", (text) => {
    const frame: OutboundFrame = { jsonrpc: "2.0", method: "test", params: { text } };
    const wireBytes = new TextEncoder().encode(JSON.stringify({ ...frame, [SEQ_FIELD]: 1 })).byteLength;
    const exact = new ReplayRing(10, wireBytes);
    expect(exact.push(frame).bytes).toBe(wireBytes);
    const retained = exact.replayFrom(0);
    expect(retained.ok && retained.frames.map((entry) => entry.seq)).toEqual([1]);
    expect(exact.floorSeq).toBe(1);

    const tooSmall = new ReplayRing(10, wireBytes - 1);
    tooSmall.push(frame);
    expect(tooSmall.currentSeq).toBe(1);
    expect(tooSmall.floorSeq).toBe(2);
    expect(tooSmall.replayFrom(0)).toEqual({ ok: false, drift: true });
    expect(tooSmall.replayFrom(1)).toEqual({ ok: true, frames: [] });
  });

  test("evicts by cumulative UTF-8 bytes and releases the evicted byte budget", () => {
    const frame: OutboundFrame = { jsonrpc: "2.0", method: "test", params: { text: "中文🙂".repeat(24) } };
    const wireBytes = new TextEncoder().encode(JSON.stringify({ ...frame, [SEQ_FIELD]: 1 })).byteLength;
    // 序号 1–4 的编码长度相同，预算恰好容纳两帧，第三帧必须逐出最旧帧。
    const ring = new ReplayRing(10, wireBytes * 2);
    ring.push(frame);
    ring.push(frame);
    expect(ring.floorSeq).toBe(1);
    for (let seq = 3; seq <= 4; seq += 1) {
      ring.push(frame);
      expect(ring.currentSeq).toBe(seq);
      expect(ring.floorSeq).toBe(seq - 1);
      expect(ring.replayFrom(seq - 3)).toEqual({ ok: false, drift: true });
      const replay = ring.replayFrom(seq - 2);
      expect(replay.ok && replay.frames.map((entry) => entry.seq)).toEqual([seq - 1, seq]);
    }
  });
});

describe("Session attach", () => {
  test("new sessions attach fresh and existing ones resume from the cursor", () => {
    const registry = new SessionRegistry();
    const first = registry.resolve("ipad");
    const seen: OutboundFrame[] = [];
    const outcome = first.session.attach(0, (frame) => seen.push(frame), first.existed);
    expect(outcome.kind).toBe("fresh");
    first.session.publish(note(1));
    first.session.publish(note(2));
    first.session.detach(outcome.generation);
    first.session.publish(note(3));

    const again = registry.resolve("ipad");
    expect(again.existed).toBe(true);
    const resumed = again.session.attach(1, () => {}, again.existed);
    expect(resumed.kind).toBe("resumed");
    expect(resumed.backlog.map((entry) => entry.seq)).toEqual([2, 3]);
  });

  test("responses are never replayed to a later connection", () => {
    const session = new Session("ipad");
    const outcome = session.attach(undefined, () => {}, false);
    session.respond({ jsonrpc: "2.0", id: 7, result: { data: [] } }, outcome.generation);
    session.publish(note(1));
    session.detach(outcome.generation);
    const resumed = session.attach(0, () => {}, true);
    expect(resumed.backlog.map((entry) => entry.frame.method)).toEqual(["turn/started"]);
  });

  test("responses bypass the ring so a large one cannot evict an unacknowledged notification", () => {
    const session = new Session("ipad", new ReplayRing(20, 1024));
    const delivered: OutboundFrame[] = [];
    const outcome = session.attach(undefined, (frame) => delivered.push(frame), false);
    session.publish({ jsonrpc: "2.0", method: "turn/completed", params: { turnId: "t1" } });
    session.respond({ jsonrpc: "2.0", id: 1, result: { text: "x".repeat(2000) } }, outcome.generation);
    expect(delivered.map((frame) => ("id" in frame ? frame.id : frame.method))).toEqual(["turn/completed", 1]);
    expect(delivered[1]).not.toHaveProperty(SEQ_FIELD);
    expect(session.ring.currentSeq).toBe(1);
    expect(session.ring.floorSeq).toBe(1);

    session.detach(outcome.generation);
    const resumed = session.attach(0, () => {}, true);
    expect(resumed.kind).toBe("resumed");
    expect(resumed.backlog.map((entry) => entry.frame.method)).toEqual(["turn/completed"]);
  });

  test("a response for a replaced connection is dropped", () => {
    const session = new Session("ipad");
    const old = session.attach(undefined, () => {}, false);
    const delivered: OutboundFrame[] = [];
    session.attach(0, (frame) => delivered.push(frame), true);
    session.respond({ jsonrpc: "2.0", id: 1, result: {} }, old.generation);
    expect(delivered).toEqual([]);
    expect(session.ring.currentSeq).toBe(0);
  });

  test("an existing session without a cursor resumes from the last attempted frame", () => {
    const session = new Session("ipad");
    const first = session.attach(undefined, () => {}, false);
    session.publish(note(1));
    session.publish(note(2));
    session.detach(first.generation);
    const resumed = session.attach(undefined, () => {}, true);
    expect(resumed.backlog.map((entry) => entry.seq)).toEqual([2]);
  });

  test("an answered prompt is not replayed to a reconnecting client, its resolution still is (#873)", () => {
    const session = new Session("ipad");
    const first = session.attach(undefined, () => {}, false);
    session.publish(note(1));
    session.publishRequest("mimi-1", "item/tool/requestUserInput", { threadId: "t1", itemId: "ask-1" });
    session.resolveRequest("mimi-1");
    session.publish({ jsonrpc: "2.0", method: "serverRequest/resolved", params: { threadId: "t1", requestId: "mimi-1" } });
    session.publish(note(2));
    session.detach(first.generation);

    const replayed: OutboundFrame[] = [];
    const resumed = session.attach(0, (frame) => replayed.push(frame), true);
    // 冷启动的客户端不认识 mimi-1；补发请求帧会先弹出补充信息、随后被 resolved 收起。
    // resolved 仍要补发：显示过卡片后断线、期间被别的设备答复的客户端只能靠它收起卡片。
    expect(resumed.backlog.map((entry) => entry.frame.method)).toEqual([
      "turn/started",
      "serverRequest/resolved",
      "turn/started",
    ]);
    session.sendReplay(resumed.generation);
    expect(replayed).toEqual([]);
  });

  test("an unanswered prompt is restored once through serverRequest/replay, not from the ring", () => {
    const session = new Session("ipad");
    const first = session.attach(undefined, () => {}, false);
    session.publishRequest("mimi-1", "item/tool/requestUserInput", { threadId: "t1", itemId: "ask-1" });
    session.resolveRequest("mimi-1");
    session.publish({ jsonrpc: "2.0", method: "serverRequest/resolved", params: { threadId: "t1", requestId: "mimi-1" } });
    session.publishRequest("mimi-2", "item/commandExecution/requestApproval", { threadId: "t1", itemId: "cmd-2" });
    session.publish(note(1));
    session.detach(first.generation);

    const replayed: OutboundFrame[] = [];
    const resumed = session.attach(0, (frame) => replayed.push(frame), true);
    expect(resumed.backlog.map((entry) => entry.frame.method)).toEqual(["serverRequest/resolved", "turn/started"]);
    session.sendReplay(resumed.generation);
    expect(replayed).toEqual([
      {
        jsonrpc: "2.0",
        method: "serverRequest/replay",
        params: {
          outstanding: [
            { id: "mimi-2", method: "item/commandExecution/requestApproval", params: { threadId: "t1", itemId: "cmd-2" } },
          ],
        },
      },
    ]);
  });

  test("the reaper drops idle detached sessions only", () => {
    const registry = new SessionRegistry({ idleTtlMs: 1_000 });
    const attached = registry.resolve("attached");
    attached.session.attach(undefined, () => {}, false);
    registry.resolve("detached");
    registry.sweep(Date.now() + 2_000);
    expect(registry.size).toBe(1);
  });
});

describe("SessionRegistry.publishAll", () => {
  test("reaches every registered session plus unregistered subscribers, each exactly once", () => {
    const registry = new SessionRegistry();
    const attached = registry.resolve("ipad").session;
    const anonymous = new Session("anonymous");
    const seen = { attached: 0, anonymous: 0 };
    attached.attach(undefined, () => (seen.attached += 1), false);
    anonymous.attach(undefined, () => (seen.anonymous += 1), false);
    // 订阅者里既有已注册的连接，也有匿名连接：已注册的不能重复收到。
    registry.publishAll(note(1), [attached, anonymous, anonymous]);
    expect(seen).toEqual({ attached: 1, anonymous: 1 });
    registry.publishAll(note(2));
    expect(seen).toEqual({ attached: 2, anonymous: 1 });
  });
});

describe("serveConnection", () => {
  test("an anonymous session is released when its connection ends; an attached one is kept", async () => {
    const ended: Session[] = [];
    const deps = {
      registry: new SessionRegistry(),
      router: new Router(new Map(), () => {}),
      log: () => {},
      onAnonymousSessionEnd: (session: Session) => ended.push(session),
    };
    const anonymous = new PassThrough();
    const servedAnonymous = serveConnection(anonymous, new PassThrough(), deps);
    anonymous.end(`${JSON.stringify({ jsonrpc: "2.0", method: "initialized" })}\n`);
    await servedAnonymous;
    expect(ended.map((session) => session.key)).toEqual(["anonymous"]);

    const attached = new PassThrough();
    const servedAttached = serveConnection(attached, new PassThrough(), deps);
    attached.end(`${JSON.stringify({ jsonrpc: "2.0", method: "_alleycat/attach", params: { sessionKey: "ipad-1" } })}\n`);
    await servedAttached;
    // 具名会话留给注册表按空闲期回收，断线可续。
    expect(ended).toHaveLength(1);
  });
});

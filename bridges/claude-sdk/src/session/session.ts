import { isClientRequestResponse, notificationFrame, type OutboundFrame } from "../rpc/frames.ts";
import { ReplayRing, type SequencedFrame } from "./ring.ts";

export type AttachKind = "fresh" | "resumed" | "driftReload";

export interface AttachOutcome {
  kind: AttachKind;
  currentSeq: number;
  floorSeq: number;
  backlog: SequencedFrame[];
  generation: number;
}

export type FrameSink = (frame: OutboundFrame) => void;

/**
 * 一个 agentd 会话（按 sessionKey 区分的客户端）。连接可以断开再接上，
 * 会话里的重放环保证断线期间产生的通知不丢。
 */
export class Session {
  readonly ring: ReplayRing;
  private sink: FrameSink | undefined;
  private generation = 0;
  private detachedAt: number | undefined;
  private lastAttemptedSeq = 0;
  /** 已发出、客户端尚未答复的服务端请求（审批、提问）。重连时由 serverRequest/replay 一次性补发。 */
  private readonly outstanding = new Map<string, { method: string; params: unknown }>();
  private busyCheck: (() => boolean) | undefined;

  constructor(readonly key: string, ring = new ReplayRing()) {
    this.ring = ring;
    this.detachedAt = Date.now();
  }

  /**
   * 换上新连接并计算需要补发的帧。旧连接的 sink 被替换后不再收到任何帧。
   * 响应只属于发起请求的那条连接，不参与重放。
   */
  attach(lastSeen: number | undefined, sink: FrameSink, existed: boolean): AttachOutcome {
    const currentSeq = this.ring.currentSeq;
    const floorSeq = this.ring.floorSeq;
    let kind: AttachKind = existed ? "resumed" : "fresh";
    let backlog: SequencedFrame[] = [];
    // 已有会话但客户端没带游标时，从上次尝试投递的那一帧开始补发。
    const cursor = existed ? (lastSeen ?? Math.max(0, this.lastAttemptedSeq - 1)) : undefined;
    if (cursor !== undefined) {
      const replay = this.ring.replayFrom(cursor);
      if (replay.ok) {
        // 未答复的请求只走 serverRequest/replay 一条路径恢复，环里的原帧不再重复投递，
        // 否则同一个审批会弹两次。
        backlog = replay.frames.filter(
          (entry) => !isClientRequestResponse(entry.frame) && !this.isUnansweredRequest(entry.frame),
        );
      } else {
        kind = "driftReload";
      }
    }
    this.sink = sink;
    this.generation += 1;
    this.detachedAt = undefined;
    return { kind, currentSeq, floorSeq, backlog, generation: this.generation };
  }

  detach(generation: number): void {
    if (generation !== this.generation) return;
    this.sink = undefined;
    this.detachedAt = Date.now();
  }

  /** 通知与服务端请求：入环并投递给当前连接（若有）。 */
  publish(frame: OutboundFrame): number {
    const entry = this.ring.push(frame);
    this.deliver(entry);
    return entry.seq;
  }

  /** 请求的响应：发起请求的连接已被替换时直接丢弃，不占重放容量。 */
  respond(frame: OutboundFrame, generation: number): void {
    if (generation !== this.generation || !this.sink) return;
    this.deliver(this.ring.push(frame));
  }

  /** attach 应答写出之后再补发积压帧，保证客户端先看到应答。 */
  flushBacklog(backlog: SequencedFrame[], generation: number): void {
    if (generation !== this.generation) return;
    for (const entry of backlog) this.deliver(entry);
  }

  private deliver(entry: SequencedFrame): void {
    if (!this.sink) return;
    this.lastAttemptedSeq = Math.max(this.lastAttemptedSeq, entry.seq);
    this.sink(entry.frame);
  }

  /** 会话是否还有进行中的工作（订阅的 turn 在运行或有待答复的请求），有就不回收。 */
  isBusy(): boolean {
    return this.outstanding.size > 0 || (this.busyCheck?.() ?? false);
  }

  setBusyCheck(check: () => boolean): void {
    this.busyCheck = check;
  }

  publishRequest(id: string, method: string, params: unknown): void {
    this.outstanding.set(id, { method, params });
    this.publish({ jsonrpc: "2.0", id, method, params });
  }

  resolveRequest(id: string): void {
    this.outstanding.delete(id);
  }

  hasOutstanding(id: string): boolean {
    return this.outstanding.has(id);
  }

  /** attach 应答之后直接发给当前连接（不入环），列出仍待答复的请求。 */
  sendReplay(generation: number): void {
    if (generation !== this.generation || !this.sink || this.outstanding.size === 0) return;
    const outstanding = [...this.outstanding].map(([id, entry]) => ({ id, method: entry.method, params: entry.params }));
    this.sink(notificationFrame("serverRequest/replay", { outstanding }));
  }

  private isUnansweredRequest(frame: OutboundFrame): boolean {
    return typeof frame.method === "string" && typeof frame.id === "string" && this.outstanding.has(frame.id);
  }

  detachedLongerThan(ms: number, now = Date.now()): boolean {
    return this.detachedAt !== undefined && now - this.detachedAt >= ms;
  }
}

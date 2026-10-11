import { isClientRequestResponse, type OutboundFrame } from "../rpc/frames.ts";
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
        backlog = replay.frames.filter((entry) => !isClientRequestResponse(entry.frame));
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

  /** 会话是否有进行中的工作；只读阶段没有，后续驱动对话时扩展。 */
  isBusy(): boolean {
    return false;
  }

  detachedLongerThan(ms: number, now = Date.now()): boolean {
    return this.detachedAt !== undefined && now - this.detachedAt >= ms;
  }
}

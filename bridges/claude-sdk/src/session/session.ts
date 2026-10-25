import {
  isClientRequestResponse,
  isServerToClientRequest,
  notificationFrame,
  type OutboundFrame,
} from "../rpc/frames.ts";
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
        backlog = replay.frames.filter((entry) => isReplayableFrame(entry.frame));
      } else {
        kind = "driftReload";
      }
    }
    this.sink = sink;
    this.generation += 1;
    this.detachedAt = undefined;
    return { kind, currentSeq, floorSeq, backlog, generation: this.generation };
  }

  /** 这一代连接仍是会话当前的连接（未被替换、未断开）。 */
  isCurrent(generation: number): boolean {
    return generation === this.generation && this.sink !== undefined;
  }

  get connectedGeneration(): number | undefined {
    return this.sink ? this.generation : undefined;
  }

  /** 建议只属于看到本轮完成的连接，不入重放环，也不补给重连或新订阅者。 */
  publishTransient(frame: OutboundFrame, generation: number): void {
    if (this.isCurrent(generation)) this.sink?.(frame);
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

  /**
   * 请求的响应只发给发起请求的当前连接，不入环也不打序号：重连从不补发响应，
   * 入环只会让大历史响应挤掉尚未确认的通知（#910）。连接已被替换时直接丢弃。
   */
  respond(frame: OutboundFrame, generation: number): void {
    if (generation !== this.generation || !this.sink) return;
    this.sink(frame);
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

  detachedLongerThan(ms: number, now = Date.now()): boolean {
    return this.detachedAt !== undefined && now - this.detachedAt >= ms;
  }
}

/**
 * 断线重连时环里哪些帧可以补发给新连接。
 *
 * - 客户端请求的响应只属于发起它的旧连接：新连接的请求 ID 从头编号，重放会把响应
 *   错配到复用同一 ID 的新请求上。
 * - 服务端请求（审批、提问）一律不从环里补发。仍未答复的由 serverRequest/replay
 *   一次性恢复；已答复或已撤回的再发一次，冷启动的客户端会先弹出卡片、紧接着又被
 *   随后的 serverRequest/resolved 收起（#873）。
 * - serverRequest/resolved 照常补发：客户端可能在显示卡片后断线，期间请求被另一台
 *   设备答复，它只能靠这条通知收起卡片。没见过对应请求的客户端收到它什么也不做。
 */
export function isReplayableFrame(frame: OutboundFrame): boolean {
  return !isClientRequestResponse(frame) && !isServerToClientRequest(frame);
}

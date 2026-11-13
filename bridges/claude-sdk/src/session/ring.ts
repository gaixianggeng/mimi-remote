import { Buffer } from "node:buffer";
import type { OutboundFrame } from "../rpc/frames.ts";

/** 出站帧上的序号字段；agentd 用它记录每个会话的投递进度。 */
export const SEQ_FIELD = "_alleycat_seq";

export interface SequencedFrame {
  seq: number;
  frame: OutboundFrame;
  bytes: number;
}

export type ReplayResult = { ok: true; frames: SequencedFrame[] } | { ok: false; drift: true };

/**
 * 有界重放环：按条数和字节数两个上限从头部淘汰。
 * 序号从 1 开始单调递增；`floorSeq` 是仍在环内的最小序号（环空时等于下一个序号）。
 */
export class ReplayRing {
  private frames: SequencedFrame[] = [];
  private bytes = 0;
  private nextSeq = 1;
  private floor = 1;

  constructor(
    private readonly maxFrames = 2048,
    private readonly maxBytes = 16 * 1024 * 1024,
  ) {}

  get currentSeq(): number {
    return this.nextSeq - 1;
  }

  get floorSeq(): number {
    return this.floor;
  }

  /** 打上序号后入环，返回带序号的帧。 */
  push(frame: OutboundFrame): SequencedFrame {
    const seq = this.nextSeq++;
    const stamped = { ...frame, [SEQ_FIELD]: seq };
    // 连接按 UTF-8 发送 JSON；字符串 length 会低估中文和 emoji 的字节数。
    const entry = { seq, frame: stamped, bytes: Buffer.byteLength(JSON.stringify(stamped), "utf8") };
    this.frames.push(entry);
    this.bytes += entry.bytes;
    while (this.frames.length > this.maxFrames || this.bytes > this.maxBytes) {
      const evicted = this.frames.shift();
      if (!evicted) break;
      this.bytes -= evicted.bytes;
    }
    this.floor = this.frames[0]?.seq ?? this.nextSeq;
    return entry;
  }

  /**
   * 取 `lastSeen` 之后的帧。游标早于环底说明中间有帧已被淘汰，返回 drift；
   * 游标超过当前序号（例如另一个实例的游标）时什么也不重放，不报错。
   */
  replayFrom(lastSeen: number): ReplayResult {
    if (lastSeen >= this.currentSeq) return { ok: true, frames: [] };
    if (lastSeen + 1 < this.floor) return { ok: false, drift: true };
    return { ok: true, frames: this.frames.filter((entry) => entry.seq > lastSeen) };
  }
}

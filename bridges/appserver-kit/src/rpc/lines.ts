import type { Readable } from "node:stream";

// agentd 网关单帧上限远低于此；超长行直接丢弃，避免恶意或损坏输入撑爆内存。
export const MAX_LINE_BYTES = 32 * 1024 * 1024;

export type LineEvent = { type: "line"; text: string } | { type: "oversize" };

/** 把字节流切成行。单行超过上限时整行丢弃并报告一次 oversize。 */
export async function* readLines(stream: Readable, maxBytes = MAX_LINE_BYTES): AsyncGenerator<LineEvent> {
  let pending: Buffer[] = [];
  let pendingBytes = 0;
  let discarding = false;
  for await (const chunk of stream) {
    let buffer = typeof chunk === "string" ? Buffer.from(chunk) : (chunk as Buffer);
    let newline = buffer.indexOf(0x0a);
    while (newline !== -1) {
      const head = buffer.subarray(0, newline);
      buffer = buffer.subarray(newline + 1);
      if (discarding || pendingBytes + head.length > maxBytes) {
        if (!discarding) yield { type: "oversize" };
        discarding = false;
      } else {
        pending.push(head);
        const text = Buffer.concat(pending).toString("utf8").trim();
        if (text) yield { type: "line", text };
      }
      pending = [];
      pendingBytes = 0;
      newline = buffer.indexOf(0x0a);
    }
    if (discarding) continue;
    if (pendingBytes + buffer.length > maxBytes) {
      discarding = true;
      pending = [];
      pendingBytes = 0;
      yield { type: "oversize" };
      continue;
    }
    if (buffer.length) {
      pending.push(buffer);
      pendingBytes += buffer.length;
    }
  }
  if (!discarding && pending.length) {
    const text = Buffer.concat(pending).toString("utf8").trim();
    if (text) yield { type: "line", text };
  }
}

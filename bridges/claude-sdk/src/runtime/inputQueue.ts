import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

/**
 * 交给 SDK `query({ prompt })` 的流式输入。进程常驻期间一直打开，
 * 每次 turn/start 或 turn/steer 往里推一条用户消息；关闭后 SDK 结束会话。
 */
export class InputQueue implements AsyncIterable<SDKUserMessage> {
  private readonly pending: SDKUserMessage[] = [];
  private wake: (() => void) | undefined;
  private closed = false;

  push(message: SDKUserMessage): void {
    if (this.closed) throw new Error("input queue is closed");
    this.pending.push(message);
    this.wake?.();
  }

  close(): void {
    this.closed = true;
    this.wake?.();
  }

  async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    while (true) {
      const next = this.pending.shift();
      if (next) {
        yield next;
        continue;
      }
      if (this.closed) return;
      await new Promise<void>((resolve) => (this.wake = resolve));
      this.wake = undefined;
    }
  }
}

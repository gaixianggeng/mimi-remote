// 脚本化的 SDK Query：不启动 CLI，测试按顺序 emit 消息，精确控制到达顺序。
/** 只实现运行时用到的 Query 接口；emit 的消息按顺序交给适配器。 */
export class ScriptedQuery {
  readonly sent: Array<Record<string, any>> = [];
  private readonly outbox: unknown[] = [];
  private wake: (() => void) | undefined;
  private closed = false;

  attach(prompt: AsyncIterable<unknown>) {
    void (async () => {
      for await (const message of prompt) this.sent.push(message as Record<string, any>);
    })();
  }

  emit(message: Record<string, unknown>) {
    this.outbox.push(message);
    this.wake?.();
  }

  async *[Symbol.asyncIterator]() {
    while (true) {
      if (this.outbox.length) {
        yield this.outbox.shift();
        continue;
      }
      if (this.closed) return;
      await new Promise<void>((resolve) => (this.wake = resolve));
    }
  }

  interrupts = 0;
  /** 设置后切换模型会停在这里，模拟 turn/start 等待控制请求的窗口。 */
  settingsGate: Promise<void> | undefined;

  async initializationResult() {
    return {};
  }
  async interrupt() {
    this.interrupts += 1;
  }
  async setModel() {
    await this.settingsGate;
  }
  async setPermissionMode() {}
  async applyFlagSettings() {}
  close() {
    this.closed = true;
    this.wake?.();
  }
}

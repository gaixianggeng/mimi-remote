// 实时事件与历史记录共用的 item ID 规则（与旧 bridge 一致）。同一条 API 消息里的
// 第二段文本 / 思考加序号后缀。两边一致，App 重新加载历史时才不会出现重复条目。

export class ItemIdAllocator {
  private readonly counts = new Map<string, number>();

  private next(prefix: string, messageId: string): string {
    const key = `${prefix}:${messageId}`;
    const ordinal = this.counts.get(key) ?? 0;
    this.counts.set(key, ordinal + 1);
    return ordinal === 0 ? `${prefix}_${messageId}` : `${prefix}_${messageId}_${ordinal}`;
  }

  agentMessage(messageId: string): string {
    return this.next("assistant_msg", messageId);
  }

  reasoning(messageId: string): string {
    return this.next("reasoning_msg", messageId);
  }
}

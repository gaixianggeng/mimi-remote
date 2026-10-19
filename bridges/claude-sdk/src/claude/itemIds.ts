// 实时事件与历史记录共用的 item ID 规则（与旧 bridge 一致）。同一条 API 消息里的
// 第二段文本 / 思考加序号后缀。两边一致，App 重新加载历史时才不会出现重复条目。
import { createHash } from "node:crypto";

/**
 * 后台任务完成通知触发的续写回合（#797）。通知在 transcript 里是一条内部用户记录，它的 uuid 由 CLI
 * 写入时才分配，实时侧拿不到；两边都认得的是这次任务运行的 run_id（实时 task_notification 帧的
 * run_id、通知记录 origin.runId）。按会话与 run_id 生成稳定的 UUID 作回合 ID，实时与历史一致。
 */
export function notificationTurnId(sessionId: string, runId: string): string {
  const hex = createHash("sha256").update(`task-notification\0${sessionId}\0${runId}`).digest("hex");
  const variant = ((parseInt(hex[16]!, 16) & 0x3) | 0x8).toString(16);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-5${hex.slice(13, 16)}-${variant}${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

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

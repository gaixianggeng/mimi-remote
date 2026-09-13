import Foundation

/// 进程内按 thread 单调递增的事件序号源，所有投影器实例共用。
///
/// ConversationStore 拿 `seq` 当水位线：小于等于已见序号的正文事件视为陈旧重放直接丢弃。
/// 但 runtime（连同它的投影器）会在进后台、切主机、凭据轮换时整体重建；序号若随实例从 1
/// 重来，重建后正文可能落在旧水位线之下。完成状态仍可更新，因而不能用完成反馈
/// 证明正文已落地；这里修复序号源，不改变正文去重与历史恢复策略。
/// 序号必须跟着 thread 走而不是跟着投影器实例走。
final class CodexAppServerEventSequenceClock: @unchecked Sendable {
    static let shared = CodexAppServerEventSequenceClock()

    private let lock = NSLock()
    private var nextSeqBySessionID: [SessionID: EventSequence] = [:]

    init() {}

    func next(for sessionID: SessionID) -> EventSequence {
        lock.lock()
        defer { lock.unlock() }
        let next = (nextSeqBySessionID[sessionID] ?? 0) + 1
        nextSeqBySessionID[sessionID] = next
        return next
    }
}

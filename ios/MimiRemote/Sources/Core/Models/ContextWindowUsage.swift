import Foundation

/// 会话当前上下文窗口的占用情况，来自 `thread/tokenUsage/updated`。
///
/// 口径与 Codex CLI 的「context left」一致（codex-rs `TokenUsage::percent_of_context_window_remaining`）：
/// 用最近一次模型响应的 `last.totalTokens` 表示当前上下文占用；分子和分母都先减去 12000 的固定基线
/// （系统提示、工具说明和压缩预留），所以首轮之后接近 100%，随对话推进降到 0%。
/// `total` 是整段会话的累计消耗，不代表当前上下文，不能拿来算剩余比例。
struct ContextWindowUsage: Equatable, Sendable {
    static let baselineTokens = 12_000
    /// 剩余比例不高于这个值时提示用户压缩。
    static let lowRemainingPercent = 15

    let usedTokens: Int
    let contextWindow: Int
    let remainingPercent: Int

    init(usedTokens: Int, contextWindow: Int) {
        self.usedTokens = max(0, usedTokens)
        self.contextWindow = contextWindow
        self.remainingPercent = Self.remainingPercent(usedTokens: usedTokens, contextWindow: contextWindow)
    }

    /// 缺少窗口大小或最近一次响应用量时返回 nil：界面不显示，而不是显示成 0%。
    init?(sample: AppServerTokenUsageSample) {
        guard let contextWindow = sample.modelContextWindow, contextWindow > 0,
              let last = sample.last else {
            return nil
        }
        let used: Int
        if let totalTokens = last.totalTokens {
            used = totalTokens
        } else if let input = last.inputTokens, let output = last.outputTokens {
            used = input + output
        } else {
            return nil
        }
        self.init(usedTokens: used, contextWindow: contextWindow)
    }

    var isLow: Bool {
        remainingPercent <= Self.lowRemainingPercent
    }

    static func remainingPercent(usedTokens: Int, contextWindow: Int) -> Int {
        guard contextWindow > baselineTokens else {
            return 0
        }
        let effectiveWindow = Double(contextWindow - baselineTokens)
        let used = Double(max(0, usedTokens - baselineTokens))
        let remaining = max(0, effectiveWindow - used)
        let percent = (remaining / effectiveWindow * 100).rounded()
        return Int(min(100, max(0, percent)))
    }
}

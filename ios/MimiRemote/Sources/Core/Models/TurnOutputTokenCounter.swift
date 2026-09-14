import Foundation

/// `thread/tokenUsage/updated` 里与“本轮产出”有关的数值。
///
/// `total` 的累计口径随运行时不同：Codex 按整个会话累计，Claude bridge 按本轮累计。
/// 两者都满足“有新的模型响应计入时 total 必然变化”，所以这里只拿它判重，不直接做差。
struct AppServerTokenUsageSample: Hashable, Sendable {
    struct Breakdown: Hashable, Sendable {
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
    }

    let total: Breakdown
    /// 最近一次模型响应的用量。旧协议可能缺失，此时退回用 total 的输出增量。
    let last: Breakdown?
}

/// 单个会话当前一轮的输出 token 计数。
///
/// 规则：本轮开始清零，之后每当 `total` 变化就累加 `last.outputTokens`。
/// Codex 在限额刷新时会重发同一份用量，Claude bridge 在 turn 完成时也会再发一次，
/// 这些重复推送的 total 与上一次相同，会被跳过；上一轮的 total 跨轮保留，用于判重。
struct TurnOutputTokenCounter: Equatable, Sendable {
    private(set) var turnID: TurnID?
    private(set) var outputTokens: Int
    /// 只有看到了本轮 `turn/started`，累加值才代表整轮产出；中途进入会话时不展示，避免偏小。
    private(set) var observedTurnStart: Bool
    private(set) var lastTotal: AppServerTokenUsageSample.Breakdown?

    static func started(turnID: TurnID?, previous: TurnOutputTokenCounter?) -> TurnOutputTokenCounter {
        // 同一 turn 的 started 被重放时不能把已累计的产出清零。
        if let previous, previous.observedTurnStart, turnID != nil, previous.turnID == turnID {
            return previous
        }
        return TurnOutputTokenCounter(
            turnID: turnID,
            outputTokens: 0,
            observedTurnStart: true,
            lastTotal: previous?.lastTotal
        )
    }

    static func applying(
        _ sample: AppServerTokenUsageSample,
        turnID: TurnID?,
        to current: TurnOutputTokenCounter?
    ) -> TurnOutputTokenCounter {
        var next = current ?? TurnOutputTokenCounter(
            turnID: turnID,
            outputTokens: 0,
            observedTurnStart: false,
            lastTotal: nil
        )
        if let turnID, let currentTurnID = next.turnID, turnID != currentTurnID {
            if next.observedTurnStart {
                // 已经进入新一轮后才到达的旧轮用量：只刷新判重基线，不计入本轮。
                next.lastTotal = sample.total
                return next
            }
            next = TurnOutputTokenCounter(
                turnID: turnID,
                outputTokens: 0,
                observedTurnStart: false,
                lastTotal: next.lastTotal
            )
        } else if next.turnID == nil {
            next.turnID = turnID
        }
        guard sample.total != next.lastTotal else {
            return next
        }
        let increment: Int
        if let lastOutput = sample.last?.outputTokens {
            increment = lastOutput
        } else if let previous = next.lastTotal?.outputTokens,
                  let current = sample.total.outputTokens,
                  current >= previous {
            increment = current - previous
        } else {
            increment = 0
        }
        next.outputTokens += max(0, increment)
        next.lastTotal = sample.total
        return next
    }

    /// 可展示的本轮输出 token；没有看到本轮开头、不是当前活跃 turn 或尚无产出时返回 nil。
    func displayOutputTokens(activeTurnID: TurnID?) -> Int? {
        guard observedTurnStart, outputTokens > 0 else {
            return nil
        }
        if let activeTurnID, let turnID, activeTurnID != turnID {
            return nil
        }
        return outputTokens
    }
}

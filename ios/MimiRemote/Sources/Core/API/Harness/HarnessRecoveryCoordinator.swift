import Foundation

/// 连接恢复编排：退避、前后台、重连顺序。
///
/// ## 为什么单独一层
///
/// `HarnessSessionRuntime` 已经管代次与传输，但它**不知道**"现在该不该重连"：
/// 那取决于失败分类（哪些可重连）、App 是否在前台、退避有没有到期。
/// 把这三件事放进 runtime 会让"传输"和"策略"混在一起，两边都难测。
/// 这一层只做决策，不碰传输。
///
/// ## 三条不重试（契约 D6）
///
/// 权限失败 / 结构不兼容 / 连续性无法修复**不重试**。它们的共同点是"重试多少次
/// 都是同一个结论"——继续退避重连只会把一次明确失败伪装成"网络不好"，
/// 用户看到的是一直转圈而不是"需要升级/重新授权"。
///
/// ## 重连顺序（契约 §5.2）
///
/// 1. 确认通道/认证/事件 `ready`（新的 clientId）
/// 2. 目录重新读取
/// 3. 活会话重新 follow：先拿 opening snapshot，再按 cursor 对账历史
/// 4. pending 以 Harness 重投（同 eventId）或撤销恢复
///
/// 顺序不可换：`session/page` 的 throughSeq 必须取自**本次** follow 的 snapshot。
@MainActor
final class HarnessRecoveryCoordinator {

    /// 退避参数。契约给定的是**方案拟定值**（待实测校准），不是 Harness 保证，
    /// 因此它们是可注入的，测试用假时钟推进，不靠 sleep 赌时序。
    struct Backoff: Equatable {
        var base: TimeInterval
        var factor: Double
        var maxDelay: TimeInterval

        /// 契约拟定值：base 1s、factor 2、max 30s。
        static let `default` = Backoff(base: 1, factor: 2, maxDelay: 30)

        /// 第 `attempt` 次重试的**上限**（未加抖动）。attempt 从 0 起。
        func ceiling(attempt: Int) -> TimeInterval {
            guard attempt > 0 else { return 0 }
            let raw = base * pow(factor, Double(attempt - 1))
            return min(raw, maxDelay)
        }

        /// 实际延迟 = full jitter：在 `[0, ceiling]` 上均匀取值。
        ///
        /// full jitter 而非固定延迟，是为了避免多台设备在同一时刻一起重连。
        /// `random` 可注入，测试因此能验证"确实落在区间内"而不是"等于某个值"。
        func delay(attempt: Int, random: () -> Double) -> TimeInterval {
            ceiling(attempt: attempt) * random()
        }
    }

    /// 一次恢复动作的决策结果。
    enum Decision: Equatable {
        /// 等待指定秒数后重连。
        case retry(after: TimeInterval)
        /// 不重试，把失败暴露给用户。
        case surface(reason: String)
        /// 后台中，暂停重连（回到前台再试一次）。
        case pausedInBackground
    }

    private let backoff: Backoff
    private let random: () -> Double
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void

    /// 连续失败次数。成功后归零——否则退避会一路涨到 max 再也降不下来。
    private(set) var attempt = 0
    private(set) var isForeground = true
    /// 下一次允许重连的时刻。后台期间不推进。
    private(set) var nextAttemptAt: Date?

    /// 有一条可重连的失败尚未处理。
    ///
    /// **后台失败必须被记住。** 如果只在排定时器时才记录，那么"后台期间断线"
    /// 会什么都不留下——回到前台时 `enterForeground` 无从知道需要重连，
    /// 于是连接一直躺在断开状态，UI 也不显示 reconnecting。
    /// 这个字段就是那种情况下的"待办"标记。
    private(set) var hasPendingReconnect = false

    init(
        backoff: Backoff = .default,
        random: @escaping () -> Double = { Double.random(in: 0...1) },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.backoff = backoff
        self.random = random
        self.now = now
        self.sleep = sleep
    }

    // MARK: - 决策

    /// 根据失败分类决定下一步。
    ///
    /// 分类依据是 `HarnessTransportError.shouldReconnect`——H04 已把它钉死
    /// （只有链路层失败为真）。这里不重新判一遍：两处判断必然漂移，
    /// 而漂移的后果是"业务失败被当成网络问题无限重试"。
    func decide(for error: HarnessTransportError) -> Decision {
        guard error.shouldReconnect else {
            // 权限、策略、协议缺陷、连续性问题：重试多少次都是同一结论。
            attempt = 0
            nextAttemptAt = nil
            hasPendingReconnect = false
            return .surface(reason: error.diagnosticSummary)
        }
        // 可重连失败：无论前后台都记下"有待办"，否则后台断线会被彻底遗忘。
        hasPendingReconnect = true
        guard isForeground else {
            // 后台不重连：既省电，也避免"用户没看的时候把连接反复拉起"。
            // 但待办标记留着，等回前台立即处理。
            return .pausedInBackground
        }
        attempt += 1
        let delay = backoff.delay(attempt: attempt, random: random)
        nextAttemptAt = now().addingTimeInterval(delay)
        return .retry(after: delay)
    }

    /// 等到下一次重连时刻。返回是否真的等到了（后台可能打断）。
    func waitForNextAttempt() async -> Bool {
        guard let target = nextAttemptAt else { return true }
        let remaining = target.timeIntervalSince(now())
        guard remaining > 0 else { return true }
        await sleep(remaining)
        return isForeground
    }

    /// 一次重连成功。
    ///
    /// 归零 attempt 是必须的：不归零会让退避单调增长，之后每次断开都要等满 max。
    func recordSuccess() {
        attempt = 0
        nextAttemptAt = nil
        hasPendingReconnect = false
    }

    // MARK: - 前后台

    /// 进入前台：立即允许一次重试（契约 D6）。
    ///
    /// 返回是否应当立刻发起重连。后台挂起过的连接在回到前台时不该还等退避，
    /// 那会让用户看到"明明回来了却还在转圈"。
    @discardableResult
    func enterForeground() -> Bool {
        isForeground = true
        // 有待办就必须立刻处理：包括"后台期间断线、还没来得及排定时器"那种。
        guard hasPendingReconnect || nextAttemptAt != nil || attempt > 0 else { return false }
        nextAttemptAt = nil
        return true
    }

    /// 进入后台：暂停重连，**但不禁用**退避计数。
    ///
    /// 计数保留是有意的：后台期间网络失败不该被当成"新一轮"从头开始，
    /// 否则每次切后台再回来都会以最短延迟重试。
    func enterBackground() {
        isForeground = false
    }

    /// 是否处于"等待重连"状态。UI 据此显示 reconnecting 而不是 connected。
    var isAwaitingRetry: Bool { hasPendingReconnect || nextAttemptAt != nil || attempt > 0 }
}

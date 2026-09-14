import Foundation

/// 一次前台恢复链路的最终结果。
///
/// 它只回答“恢复走到了哪一步”，供通知路由决定是直接选路、提示用户稍后再点，还是把通知
/// 留到下一次前台再试；连接状态的展示仍由 AppStore 负责，这里不重复承担。
enum ForegroundResumeOutcome: Equatable, Sendable {
    /// 凭据、Tailcat（如需要）和 SessionStore 全部恢复完成。
    case completed
    /// Keychain 读不到当前档案的 Token；没有凭据就没有任何可用的 client。
    case credentialsUnavailable
    /// 凭据已恢复，但后台之后的 Tailcat 重启没有成功；下一次进入前台仍要重试。
    case tailcatUnavailable
    /// 其它未归类失败；只保留错误类别，不携带用户内容。
    case failed(String)
    /// 真实取消或凭据代次已变：由更新的生命周期操作接管，本次不下结论。
    case cancelled

    /// 恢复没有成功时，通知路由不能拿着半挂起的 Store 去发网络定位；
    /// 取消不算失败——它意味着已经有更新的恢复任务或后台切换在接管。
    var blocksNotificationRouting: Bool {
        switch self {
        case .completed, .cancelled:
            return false
        case .credentialsUnavailable, .tailcatUnavailable, .failed:
            return true
        }
    }

    /// 诊断里的枚举式短语。
    var diagnosticReason: String {
        switch self {
        case .completed: return "completed"
        case .credentialsUnavailable: return "credentials_unavailable"
        case .tailcatUnavailable: return "tailcat_unavailable"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// 通知路由的放行门。纯值语义，方便在测试里穷举生命周期组合。
///
/// 三个条件缺一不可：冷启动 bootstrap 已跑完（否则没有 client 和项目索引）、场景处于前台
/// （后台选路会被系统挂起，且会和下一次前台恢复互相退役连接）、前台恢复不在进行中
/// （否则会与恢复链路同时重启 Tailcat）。恢复“失败”刻意不是关门条件：失败也要让路由
/// 跑起来，由路由自己提示用户并保留通知，而不是把通知永远卡在收件箱里。
struct NotificationRoutingGate: Equatable {
    enum ClosedReason: String, Equatable {
        case bootstrapping
        case inactive
        case resumeInFlight = "resume_in_flight"
    }

    let bootstrapped: Bool
    let sceneActive: Bool
    let foregroundResumeInFlight: Bool

    /// 第一个未满足的条件；nil 表示放行。顺序即诊断里的优先级。
    var closedReason: ClosedReason? {
        if !bootstrapped { return .bootstrapping }
        if !sceneActive { return .inactive }
        if foregroundResumeInFlight { return .resumeInFlight }
        return nil
    }

    var isReady: Bool { closedReason == nil }

    static func isReady(
        bootstrapped: Bool,
        sceneActive: Bool,
        foregroundResumeInFlight: Bool
    ) -> Bool {
        NotificationRoutingGate(
            bootstrapped: bootstrapped,
            sceneActive: sceneActive,
            foregroundResumeInFlight: foregroundResumeInFlight
        ).isReady
    }
}

/// 前台恢复任务的进行中标记与代次。
///
/// 场景快速抖动时旧任务会被取消并由新任务顶替；旧任务的 defer 稍后才执行，若它能清掉
/// 标记，新任务尚未完成时闸门就会误开。代次让只有“当前那一个”任务能结束进行中状态。
struct ForegroundResumeTracker: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var inFlightGeneration: UInt64?
    /// 最近一次真正结束（而非被顶替）的恢复结果；冷启动前为 nil。
    private(set) var lastOutcome: ForegroundResumeOutcome?
    /// 产生 lastOutcome 时的活动连接档案。恢复失败只对那一台 Mac 成立：用户随后切到
    /// 另一台并连上后，不能再拿旧失败去拦截新 Mac 的通知。
    private(set) var lastOutcomeProfileID: String?
    /// 由启动前台恢复的同一个场景回调登记的前台状态。闸门必须读这个镜像，不能直接读
    /// 环境里的 scenePhase：场景刚激活的那一帧 body 已经看到 active，而启动恢复的
    /// onChange 还没执行，直接读环境值会让闸门在恢复开始前提前放行一次，随后又被
    /// 恢复关门取消，同一条通知因此被处理两次。
    private(set) var sceneActive = false

    var isInFlight: Bool { inFlightGeneration != nil }

    /// 与 begin() 在同一个场景回调里调用：先登记前台状态，再开始恢复。
    mutating func observeScene(active: Bool) {
        sceneActive = active
    }

    /// 开始一次新的恢复；返回它的代次，结束时必须带回同一个值。
    mutating func begin() -> UInt64 {
        generation &+= 1
        inFlightGeneration = generation
        return generation
    }

    /// 只有当前代次的任务能结束进行中状态并记录结果；被顶替的旧任务返回 false，
    /// 不改变任何状态。
    @discardableResult
    mutating func finish(
        generation: UInt64,
        outcome: ForegroundResumeOutcome,
        profileID: String? = nil
    ) -> Bool {
        guard inFlightGeneration == generation else { return false }
        inFlightGeneration = nil
        lastOutcome = outcome
        lastOutcomeProfileID = profileID
        return true
    }

    /// 只返回属于当前活动档案的恢复结果；档案已切换则视为没有可用结论。
    func outcome(forActiveProfileID profileID: String?) -> ForegroundResumeOutcome? {
        guard lastOutcomeProfileID == profileID else { return nil }
        return lastOutcome
    }
}

/// 通知导航权独立于列表刷新产生的 selection lease。只有新点击或用户导航能撤销它，
/// 自动 bootstrap / host 暖恢复不能重建或撤销用户尚未处理的点击。
@MainActor
final class NotificationNavigationOwnership {
    private var current: UUID?
    private var committed = false

    func accept(_ intent: UUID = UUID()) -> UUID {
        current = intent
        committed = false
        return intent
    }

    func isCurrent(_ intent: UUID) -> Bool { current == intent }

    func hasCommitted(_ intent: UUID) -> Bool { isCurrent(intent) && committed }

    func userNavigated() { current = nil }

    func observe(_ event: WorkbenchNavigationEvent) {
        switch event {
        case .open, .compactPathChanged, .compactTabChanged:
            userNavigated()
        case .synchronize, .selectionCommitted, .sessionSelectionFinished:
            break
        }
    }

    /// 在 MainActor 上紧贴选择提交执行，同一投递重入也只能提交一次。
    func claim(_ intent: UUID) -> Bool {
        guard isCurrent(intent), !committed else { return false }
        committed = true
        return true
    }
}

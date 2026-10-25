import Combine
import Foundation

/// 系统评分邀请（#842）的本机计数。只写本机 UserDefaults：不上传、不进诊断日志、
/// 不随连接档案同步，App Store 隐私标签「不收集数据」与隐私政策保持成立。
struct AppReviewPromptState: Codable, Equatable {
    /// 有「算数」回合正常完成的本地日期（yyyy-MM-dd），只保留判断阈值所需的最近几天。
    var completedTurnDays: [String] = []
    /// 上次请求评分（或首次使用）以来「算数」回合正常完成的次数，达到阈值后不再增长。
    var completedTurnCount = 0
    /// 最近一次配对成功的日期。
    var lastPairingDay: String?
    /// 最近一次出现连接失败、回合失败或中断的日期。
    var lastSetbackDay: String?
    /// 已请求过评分的 App 版本（CFBundleShortVersionString）。
    var requestedVersion: String?
}

/// 何时邀请评分的纯规则，阈值集中在这里。
///
/// 触发点只有一种：一个「算数」的回合正常完成。算数指回合由用户在 App 里发出，或用户在
/// App 里批准过它的审批；电脑端自己跑、手机只是旁观的回合不算。在这个触发点上：
/// - 批准后完成：用户在 App 里批准过审批，且该回合正常完成，立即可以邀请。用户刚靠手机
///   放行了一步、结果也顺利出来，是最直接的「好用」时刻。
/// - 多日使用：在至少 3 个不同的日子里累计至少 5 个回合正常完成后，后续任一算数回合
///   正常完成都可以邀请。跨天说明 App 已经用进日常，不是装完试一次；5 个回合避免只在
///   三天里各发一条就被打扰。
///
/// 两种情况都还要满足：
/// - 当前版本没请求过。请求后清零累计，下个版本要重新攒满，避免一升级就立刻再问。
/// - 今天不是配对日。首次配对当天还在摸索连接，体验未定型；之后重新配对的当天同样跳过。
/// - 今天没出现过连接失败、回合失败或中断。出过问题的当天整天不问，第二天再看。
/// 会话是否就在眼前、用户是否正在输入由协调器在请求前检查。
enum AppReviewPromptPolicy {
    static let requiredCompletedTurnDays = 3
    static let requiredCompletedTurns = 5

    enum Trigger: Equatable {
        case approvedTurnCompleted
        case turnCompleted
    }

    static func shouldRequest(
        _ trigger: Trigger,
        state: AppReviewPromptState,
        today: String,
        appVersion: String
    ) -> Bool {
        guard state.requestedVersion != appVersion,
              state.lastPairingDay != today,
              state.lastSetbackDay != today
        else {
            return false
        }
        switch trigger {
        case .approvedTurnCompleted:
            return true
        case .turnCompleted:
            return state.completedTurnDays.count >= requiredCompletedTurnDays
                && state.completedTurnCount >= requiredCompletedTurns
        }
    }

    static func recordingCompletedTurn(
        _ state: AppReviewPromptState,
        today: String
    ) -> AppReviewPromptState {
        var next = state
        if !next.completedTurnDays.contains(today) {
            next.completedTurnDays = Array((next.completedTurnDays + [today]).suffix(requiredCompletedTurnDays))
        }
        next.completedTurnCount = min(next.completedTurnCount + 1, requiredCompletedTurns)
        return next
    }
}

/// 收集评分信号并在正向时刻请求系统评分框。
///
/// 只调用注入的 `requestReview`（线上由界面层装入 SwiftUI 的 `requestReview`），不自建弹窗、
/// 不跳转外部页面；系统自己决定是否真的显示，并限制每年最多 3 次。
@MainActor
final class AppReviewPromptCoordinator {
    static let storageKey = "mimi.appReviewPrompt.v1"

    /// 请求系统评分框。界面出现前为 nil，此时不消耗本版本的机会。
    var requestReview: (@MainActor () -> Void)?
    /// 用户正在输入（输入框处于编辑状态或当前会话有草稿）时返回 true，这一刻不打断。
    var isUserTyping: @MainActor () -> Bool = { false }

    private(set) var state: AppReviewPromptState
    private let defaults: UserDefaults
    private let appVersion: String
    private let calendar: Calendar
    private let now: () -> Date
    /// 本进程里用户在 App 发出、回合尚未结束的会话。只在内存中，不持久化。
    private var submittedSessionIDs: Set<SessionID> = []
    /// 用户在 App 里批准过审批、回合尚未结束的会话；值为批准时的回合 ID，未知时为空串。
    private var approvedTurnIDsBySessionID: [SessionID: String] = [:]
    private var connectionFailureObservation: AnyCancellable?

    init(
        defaults: UserDefaults = .standard,
        appVersion: String,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.appVersion = appVersion
        self.calendar = calendar
        self.now = now
        state = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(AppReviewPromptState.self, from: $0) }
            ?? AppReviewPromptState()
    }

    func recordTurnSubmitted(sessionID: SessionID) {
        submittedSessionIDs.insert(sessionID)
    }

    /// 发送失败回滚时撤销登记，免得下一次完成（可能是电脑端的回合）被算成 App 发起。
    func discardTurnSubmitted(sessionID: SessionID) {
        submittedSessionIDs.remove(sessionID)
    }

    /// 新建会话先用乐观 ID 发出，服务端返回真实 ID 后跟着迁移，首个回合才能算数。
    func moveSubmittedSession(from sourceSessionID: SessionID, to targetSessionID: SessionID) {
        guard submittedSessionIDs.remove(sourceSessionID) != nil else { return }
        submittedSessionIDs.insert(targetSessionID)
    }

    func recordApprovalAccepted(sessionID: SessionID, turnID: String?) {
        approvedTurnIDsBySessionID[sessionID] = turnID ?? ""
    }

    func recordPairingCompleted() {
        let today = dayKey()
        guard state.lastPairingDay != today else { return }
        state.lastPairingDay = today
        persist()
    }

    /// 连接失败、回合失败或中断：当天不再邀请。
    func recordSetback() {
        let today = dayKey()
        guard state.lastSetbackDay != today else { return }
        state.lastSetbackDay = today
        persist()
    }

    /// `publisher` 在主线程上、用户可见的连接失败出现时发出 true；冷启动预热中的过程性
    /// 失败不应发出。
    func observeConnectionFailures<P: Publisher>(_ publisher: P) where P.Output == Bool, P.Failure == Never {
        connectionFailureObservation = publisher.sink { [weak self] isFailure in
            guard isFailure else { return }
            MainActor.assumeIsolated { self?.recordSetback() }
        }
    }

    func recordTurnFinished(
        sessionID: SessionID,
        turnID: String?,
        lifecycle: ConversationTurnLifecycle,
        isSessionVisible: Bool
    ) {
        guard lifecycle.isTerminal else { return }
        let wasSubmitted = submittedSessionIDs.remove(sessionID) != nil
        let approvedTurnID = approvedTurnIDsBySessionID.removeValue(forKey: sessionID)
        guard lifecycle == .completed else {
            recordSetback()
            return
        }
        let wasApproved = approvedTurnID.map { $0.isEmpty || turnID == nil || $0 == turnID } ?? false
        guard wasSubmitted || wasApproved else { return }

        let today = dayKey()
        state = AppReviewPromptPolicy.recordingCompletedTurn(state, today: today)
        persist()

        let isEligible = (wasApproved && shouldRequest(.approvedTurnCompleted, today: today))
            || shouldRequest(.turnCompleted, today: today)
        // 会话不在眼前（后台、看着别的页面）时请求会落空或显得突兀；正在输入时不打断。
        // 这些情况都不消耗本版本的机会，等下一个正向时刻。
        guard isEligible, isSessionVisible, let requestReview, !isUserTyping() else { return }
        state.requestedVersion = appVersion
        state.completedTurnDays = []
        state.completedTurnCount = 0
        persist()
        requestReview()
    }

    private func shouldRequest(_ trigger: AppReviewPromptPolicy.Trigger, today: String) -> Bool {
        AppReviewPromptPolicy.shouldRequest(trigger, state: state, today: today, appVersion: appVersion)
    }

    private func dayKey() -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

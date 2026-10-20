import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// 锁屏 / 灵动岛 Live Activity 的客户端协调器（#830）。
///
/// - 观察 push-to-start Token 与每个活动的更新 Token，换成推送服务的 Ticket 后登记到
///   消息提醒绑定的那台 Mac 上的 agentd；之后的启动、更新、结束都由 agentd 经推送驱动。
/// - App 在前台、有回合开始时直接本机拉起活动，省掉一次远程启动。
/// - 关闭开关、关闭消息通知或换绑时结束本机活动，注销并撤销票据。
///
/// 任何失败都只影响活动本身，不改变消息提醒的状态。
@MainActor
final class LiveActivityCoordinator: ObservableObject {
    enum Availability: Equatable {
        /// 用户关闭了实时活动。
        case off
        /// 消息通知未开启或还没绑定到一台 Mac。
        case requiresNotifications
        /// 系统设置里关闭了这个 App 的实时活动，或平台不支持。
        case systemDisabled
        /// 这台 Mac 上的 Mimi 版本还不支持（旧版 agentd）。
        case unavailableOnHost
        /// 已开启，正在等待系统下发 Token 或登记中。
        case pending
        /// 已登记 push-to-start 票据。
        case ready
        /// 推送服务或 agentd 拒绝登记（例如推送服务尚未升级）；下次回到前台重试。
        case failed
    }

    struct Binding: Equatable {
        let profileID: String
        let providerURL: String
        let deviceID: String
        let installationID: String
        let hostTag: String
    }

    @Published private(set) var isToggleOn: Bool
    @Published private(set) var availability: Availability = .pending

    private let defaults: UserDefaults
    private let ticketStore: LiveActivityTicketStore
    private let environment: PushEnvironment
    private let providerClientFactory: (String) -> PushProviderClient
    private weak var lockScreenStore: LockScreenApprovalStore?
    /// 按档案取 agentd 客户端；由 App 注入，与锁屏审批走同一条路由。
    var makeClient: ((String) async throws -> AgentAPIClient)?
    /// 档案的 agentd installation_id，用来在本机算出 hostTag。
    var installationIDForProfile: ((String) -> String?)?

    private var hostSupport: [String: (supported: Bool, hostTag: String?)] = [:]
    private var latestStartToken: String?
    private var latestUpdateTokens: [String: (hostTag: String, token: String)] = [:]
    private var operationTail: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private var activityTasks: [String: [Task<Void, Never>]] = [:]
    private var localSessionsWereActive = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        defaults: UserDefaults = .standard,
        ticketStore: LiveActivityTicketStore = LiveActivityTicketStore(),
        environment: PushEnvironment = .current(),
        providerClientFactory: @escaping (String) -> PushProviderClient = { PushProviderClient(baseURL: $0) }
    ) {
        self.defaults = defaults
        self.ticketStore = ticketStore
        self.environment = environment
        self.providerClientFactory = providerClientFactory
        self.isToggleOn = LiveActivityPreferences.isToggleOn(in: defaults)
    }

    static var isSupportedPlatform: Bool {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    func attach(lockScreenStore: LockScreenApprovalStore, sessionStore: SessionStore, appStore: AppStore) {
        self.lockScreenStore = lockScreenStore
        startObservingActivities()
        // 会话列表在流式回复期间持续变化；按秒节流，只关心「有没有会话在跑」的跳变。
        sessionStore.$sessions
            .combineLatest(appStore.$activeConnectionProfileID)
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] sessions, profileID in
                self?.sessionsDidChange(sessions, activeProfileID: profileID, isAppActive: Self.isAppActive)
            }
            .store(in: &cancellables)
        // 关闭消息通知、注销或换绑都会改变绑定；@Published 在 willSet 发布，等下一轮再读。
        lockScreenStore.$notificationsEnabled.map { _ in () }
            .merge(with: lockScreenStore.$status.map { _ in () })
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.notificationBindingDidChange() }
            .store(in: &cancellables)
    }

    private static var isAppActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    // MARK: - 开关

    func setToggle(_ enabled: Bool) {
        LiveActivityPreferences.setToggle(enabled, in: defaults)
        isToggleOn = enabled
        if enabled {
            enqueue { await self.registerStartTokenIfNeeded() }
        } else {
            availability = .off
            enqueue { await self.teardown(unregisterRemote: true) }
        }
    }

    /// 前台生命周期刷新：在锁屏审批同步之后调用，确认绑定、agentd 能力并补登记。
    func synchronize(client: AgentAPIClient, profileID: String) {
        enqueue {
            guard let binding = self.currentBinding(), binding.profileID == profileID else {
                await self.reconcileBinding()
                return
            }
            if let status = try? await client.pushStatus() {
                self.hostSupport[profileID] = (status.liveActivity == true, status.hostTag)
            }
            await self.reconcileBinding()
            await self.registerStartTokenIfNeeded()
            for activityID in Array(self.latestUpdateTokens.keys) {
                await self.registerUpdateTokenIfNeeded(activityID: activityID)
            }
        }
    }

    /// 消息通知开关或绑定变化后调用：不再满足条件时结束活动并清理票据。
    func notificationBindingDidChange() {
        enqueue { await self.reconcileBinding() }
    }

    // MARK: - 前台本机拉起

    /// App 在前台、当前档案就是消息提醒绑定的 Mac 时，回合一开始就本机拉起活动。
    /// 只在「没有会话在跑 → 有会话在跑」的那一刻尝试一次；用户在这一轮里划掉活动不会被拉回来。
    func sessionsDidChange(_ sessions: [AgentSession], activeProfileID: String?, isAppActive: Bool) {
        let state = LiveActivityLocalState.make(sessions: sessions, now: Date())
        let wasActive = localSessionsWereActive
        localSessionsWereActive = state != nil
        guard let state, !wasActive, isAppActive, LiveActivityPreferences.isEffective(in: defaults),
              let binding = currentBinding(), binding.profileID == activeProfileID,
              hostSupport[binding.profileID]?.supported == true,
              ticketStore.load()?.matches(
                profileID: binding.profileID, providerURL: binding.providerURL, hostTag: binding.hostTag
              ) == true,
              ticketStore.load()?.start != nil else {
            return
        }
        requestLocalActivity(hostTag: binding.hostTag, state: state)
    }

    // MARK: - 绑定

    private func currentBinding() -> Binding? {
        guard let store = lockScreenStore, store.notificationsEnabled, store.isEnabled,
              let profileID = store.registeredProfileID,
              let providerURL = store.registeredProviderURL,
              !store.deviceID.isEmpty, !store.installationID.isEmpty else {
            return nil
        }
        let reported = hostSupport[profileID]?.hostTag?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let computed = installationIDForProfile?(profileID).map { NotificationSessionTag.hostTag(installationID: $0) }
        guard let hostTag = (reported?.isEmpty == false ? reported : nil) ?? computed else { return nil }
        return Binding(
            profileID: profileID,
            providerURL: providerURL,
            deviceID: store.deviceID,
            installationID: store.installationID,
            hostTag: hostTag
        )
    }

    private func reconcileBinding() async {
        guard isToggleOn else {
            availability = .off
            return
        }
        guard LiveActivityPreferences.isEffective(in: defaults), let binding = currentBinding() else {
            availability = .requiresNotifications
            // 关闭消息通知时 agentd 已随设备注销删掉活动票据，这里只撤销与清理本机。
            await teardown(unregisterRemote: false)
            return
        }
        if let record = ticketStore.load(),
           !record.matches(profileID: binding.profileID, providerURL: binding.providerURL, hostTag: binding.hostTag) {
            // 换绑到另一台 Mac 或换了推送服务：旧票据整体作废。
            await teardown(unregisterRemote: false)
        }
        endActivities { $0 != binding.hostTag }
        if hostSupport[binding.profileID]?.supported == false {
            availability = .unavailableOnHost
        } else if !Self.systemAllowsActivities {
            availability = .systemDisabled
        } else if ticketStore.load()?.start != nil {
            availability = .ready
        } else if case .failed = availability {
            // 保持失败态直到下一次登记成功。
        } else {
            availability = .pending
        }
    }

    // MARK: - 登记

    private func registrationContext() -> (Binding, PushProviderClient)? {
        guard isToggleOn, LiveActivityPreferences.isEffective(in: defaults),
              let binding = currentBinding(),
              hostSupport[binding.profileID]?.supported == true,
              Self.systemAllowsActivities else {
            return nil
        }
        return (binding, providerClientFactory(binding.providerURL))
    }

    private func loadRecord(for binding: Binding) -> LiveActivityTicketRecord {
        if var record = ticketStore.load(),
           record.matches(profileID: binding.profileID, providerURL: binding.providerURL, hostTag: binding.hostTag) {
            record.pruneExpiredUpdates(now: Date())
            return record
        }
        return LiveActivityTicketRecord(
            profileID: binding.profileID,
            providerURL: binding.providerURL,
            hostTag: binding.hostTag
        )
    }

    private func registerStartTokenIfNeeded() async {
        guard let token = latestStartToken, let context = registrationContext() else { return }
        let (binding, provider) = context
        var record = loadRecord(for: binding)
        let fingerprint = connectionCredentialFingerprint(token)
        if record.startIsCurrent(tokenFingerprint: fingerprint, now: Date()) {
            availability = .ready
            return
        }
        do {
            let entry = try await issueAndRegister(
                kind: .start, token: token, activityID: nil, binding: binding, provider: provider
            )
            if let previous = record.start, previous.ticket != entry.ticket {
                try? await provider.revokeTicket(previous.ticket)
            }
            record.start = entry
            ticketStore.save(record)
            availability = .ready
            recordDiagnostic("start_registered", reason: nil)
        } catch {
            availability = .failed
            recordDiagnostic("start_failed", reason: Self.reason(error))
        }
    }

    private func registerUpdateTokenIfNeeded(activityID: String) async {
        guard let latest = latestUpdateTokens[activityID],
              let context = registrationContext(),
              latest.hostTag == context.0.hostTag,
              isActivityAlive(activityID) else {
            return
        }
        let (binding, provider) = context
        var record = loadRecord(for: binding)
        let fingerprint = connectionCredentialFingerprint(latest.token)
        if record.updateIsCurrent(activityID: activityID, tokenFingerprint: fingerprint, now: Date()) {
            return
        }
        do {
            let entry = try await issueAndRegister(
                kind: .update, token: latest.token, activityID: activityID, binding: binding, provider: provider
            )
            if let previous = record.updates[activityID], previous.ticket != entry.ticket {
                try? await provider.revokeTicket(previous.ticket)
            }
            record.updates[activityID] = entry
            ticketStore.save(record)
            recordDiagnostic("update_registered", reason: nil)
        } catch {
            recordDiagnostic("update_failed", reason: Self.reason(error))
        }
    }

    /// 签发成功但 agentd 登记失败时立即撤销新 Ticket，不留下没人用的有效票据。
    private func issueAndRegister(
        kind: LiveActivityTicketKind,
        token: String,
        activityID: String?,
        binding: Binding,
        provider: PushProviderClient
    ) async throws -> LiveActivityTicketRecord.Entry {
        guard let makeClient else { throw LockScreenApprovalRoutingError.sourceProfileUnavailable }
        let ticket = try await provider.issueTicket(
            deviceToken: token,
            installation: binding.installationID,
            environment: environment,
            kind: kind.providerKind
        )
        do {
            let client = try await makeClient(binding.profileID)
            _ = try await client.registerLiveActivity(
                deviceID: binding.deviceID,
                kind: kind,
                ticket: ticket.value,
                expiresAt: ticket.expiresAt,
                activityID: activityID
            )
        } catch {
            try? await provider.revokeTicket(ticket.value)
            throw error
        }
        return LiveActivityTicketRecord.Entry(
            ticket: ticket.value,
            expiresAt: ticket.expiresAt,
            tokenFingerprint: connectionCredentialFingerprint(token)
        )
    }

    /// 活动被用户划掉或系统回收：注销它的更新票据（按 activity_id，不误删新活动的）并撤销。
    private func activityDidEnd(_ activityID: String) async {
        latestUpdateTokens[activityID] = nil
        guard var record = ticketStore.load(), let entry = record.updates[activityID] else { return }
        record.updates[activityID] = nil
        ticketStore.save(record)
        if let makeClient, let client = try? await makeClient(record.profileID), let store = lockScreenStore {
            try? await client.unregisterLiveActivity(deviceID: store.deviceID, kind: .update, activityID: activityID)
        }
        try? await providerClientFactory(record.providerURL).revokeTicket(entry.ticket)
    }

    /// 结束本机全部活动并撤销已登记的票据。agentd 侧：关闭开关时显式注销；关闭消息通知
    /// 或换绑时设备注销已经一并删掉，不再联系。
    private func teardown(unregisterRemote: Bool) async {
        endActivities { _ in true }
        latestUpdateTokens.removeAll()
        guard let record = ticketStore.load() else { return }
        ticketStore.delete()
        if unregisterRemote, let makeClient, let store = lockScreenStore, !store.deviceID.isEmpty,
           let client = try? await makeClient(record.profileID) {
            try? await client.unregisterLiveActivity(deviceID: store.deviceID)
        }
        let provider = providerClientFactory(record.providerURL)
        for ticket in record.allTickets {
            try? await provider.revokeTicket(ticket)
        }
        recordDiagnostic("cleared", reason: unregisterRemote ? "toggle_off" : "binding_changed")
    }

    // MARK: - 串行化

    /// 登记、注销与清理都排进同一条队列：MainActor 在 await 期间会重入，
    /// 不能让关闭开关之后的旧登记又把票据写回 agentd。
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = operationTail
        operationTail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func recordDiagnostic(_ outcome: String, reason: String?) {
        NotificationRouteDiagnostics.record(
            stage: NotificationRouteDiagnostics.Stage.liveActivity,
            outcome: outcome,
            reason: reason
        )
    }

    /// 诊断只记错误类型与状态码，不记 Token、Ticket 或响应正文。
    private static func reason(_ error: Error) -> String {
        if let error = error as? PushProviderError, case .rejected(let status) = error {
            return "provider_\(status)"
        }
        if let error = error as? AgentAPIError, case .server(let status, _) = error {
            return "agentd_\(status)"
        }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    // MARK: - ActivityKit

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private static var systemAllowsActivities: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private func startObservingActivities() {
        guard observationTasks.isEmpty else { return }
        observationTasks.append(Task { @MainActor [weak self] in
            for await data in Activity<MimiTurnActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                self.latestStartToken = Self.hex(data)
                self.enqueue { await self.registerStartTokenIfNeeded() }
            }
        })
        observationTasks.append(Task { @MainActor [weak self] in
            for await activity in Activity<MimiTurnActivityAttributes>.activityUpdates {
                guard let self else { return }
                // 同一台 Mac 只保留最新的一个：本机拉起与远程启动撞在一起时，旧的那个
                // 没有人更新，留着只会停在过时的状态。
                for other in Activity<MimiTurnActivityAttributes>.activities
                where other.id != activity.id && other.attributes.hostTag == activity.attributes.hostTag
                    && Self.isAlive(other.activityState) {
                    Task { await other.end(nil, dismissalPolicy: .immediate) }
                }
                self.track(activity)
            }
        })
        for activity in Activity<MimiTurnActivityAttributes>.activities {
            track(activity)
        }
    }

    private func track(_ activity: Activity<MimiTurnActivityAttributes>) {
        let activityID = activity.id
        guard activityTasks[activityID] == nil else { return }
        let hostTag = activity.attributes.hostTag
        activityTasks[activityID] = [
            Task { @MainActor [weak self] in
                for await data in activity.pushTokenUpdates {
                    guard let self else { return }
                    self.latestUpdateTokens[activityID] = (hostTag, Self.hex(data))
                    self.enqueue { await self.registerUpdateTokenIfNeeded(activityID: activityID) }
                }
            },
            Task { @MainActor [weak self] in
                for await state in activity.activityStateUpdates where !Self.isAlive(state) {
                    guard let self else { return }
                    self.activityTasks[activityID]?.forEach { $0.cancel() }
                    self.activityTasks[activityID] = nil
                    self.enqueue { await self.activityDidEnd(activityID) }
                    return
                }
            },
        ]
    }

    private func isActivityAlive(_ activityID: String) -> Bool {
        Activity<MimiTurnActivityAttributes>.activities.contains {
            $0.id == activityID && Self.isAlive($0.activityState)
        }
    }

    private static func isAlive(_ state: ActivityState) -> Bool {
        state == .active || state == .stale
    }

    private func endActivities(where shouldEnd: (String) -> Bool) {
        for activity in Activity<MimiTurnActivityAttributes>.activities
        where shouldEnd(activity.attributes.hostTag) && Self.isAlive(activity.activityState) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func requestLocalActivity(hostTag: String, state: MimiTurnActivityState) {
        guard Self.systemAllowsActivities,
              !Activity<MimiTurnActivityAttributes>.activities.contains(where: {
                  $0.attributes.hostTag == hostTag && Self.isAlive($0.activityState)
              }) else {
            return
        }
        do {
            let activity = try Activity<MimiTurnActivityAttributes>.request(
                attributes: MimiTurnActivityAttributes(hostTag: hostTag),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(2 * 60 * 60)),
                pushType: .token
            )
            track(activity)
            recordDiagnostic("local_started", reason: nil)
        } catch {
            // 系统预算用尽或用户关闭了实时活动：交给 agentd 的 push-to-start 兜底。
            recordDiagnostic("local_start_failed", reason: Self.reason(error))
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    #else
    private static var systemAllowsActivities: Bool { false }
    private func startObservingActivities() {}
    private func isActivityAlive(_ activityID: String) -> Bool { false }
    private func endActivities(where shouldEnd: (String) -> Bool) {}
    private func requestLocalActivity(hostTag: String, state: MimiTurnActivityState) {}
    #endif
}

/// 点按 Live Activity 的链接只带两个匿名标签：hostTag 找回连接档案，会话标签在当前档案的
/// 会话列表里找回会话。只有当前档案就是那台 Mac 时才能映射；否则只打开 App，不切换主机。
enum LiveActivityLinkRouting {
    static func route(
        for link: MimiTurnActivityLink,
        profiles: [ConnectionProfile],
        activeProfileID: String?,
        sessions: [AgentSession]
    ) -> SessionNotificationRoute? {
        guard let activeProfileID,
              let profile = profiles.first(where: { $0.id == activeProfileID }),
              let installationID = profile.installationID,
              NotificationSessionTag.hostTag(installationID: installationID) == link.hostTag else {
            return nil
        }
        let match = sessions.first { candidate in
            guard !candidate.isLocalDraft else { return false }
            let threadIDs = [candidate.id] + (candidate.resumeID.map { [$0] } ?? [])
            return threadIDs.contains { NotificationSessionTag.messageTag(threadID: $0) == link.sessionTag }
        }
        guard let session = match else { return nil }
        return SessionNotificationRoute.current(
            profileID: activeProfileID,
            projectID: session.projectID,
            sessionID: session.id,
            runtimeProvider: session.runtimeProvider
        )
    }
}

/// 前台本机拉起活动时的初始状态。只是开头一帧：agentd 收到更新 Ticket 后立即推送准确的汇总。
enum LiveActivityLocalState {
    static func make(sessions: [AgentSession], now: Date) -> MimiTurnActivityState? {
        var running: [AgentSession] = []
        var needsYou: [AgentSession] = []
        for session in sessions where !session.isLocalDraft {
            switch session.activityState {
            case .needsYou: needsYou.append(session)
            case .running: running.append(session)
            default: break
            }
        }
        let byRecency: (AgentSession, AgentSession) -> Bool = { lhs, rhs in
            (lhs.updatedAt ?? lhs.recencyAt ?? .distantPast) > (rhs.updatedAt ?? rhs.recencyAt ?? .distantPast)
        }
        guard let focus = needsYou.sorted(by: byRecency).first ?? running.sorted(by: byRecency).first else {
            return nil
        }
        return MimiTurnActivityState(
            status: needsYou.isEmpty ? .running : .needsYou,
            runningCount: min(running.count, 99),
            needsYouCount: min(needsYou.count, 99),
            startedAt: Int64(now.timeIntervalSince1970),
            focusSessionTag: NotificationSessionTag.messageTag(threadID: focus.id)
        )
    }
}

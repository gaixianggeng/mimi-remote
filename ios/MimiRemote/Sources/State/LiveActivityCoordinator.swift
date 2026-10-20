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
        /// 已关闭，但还有票据没向推送服务撤销成功；回到前台时重试。只在关闭状态下出现，
        /// 从不阻塞重新开启或绑定另一台 Mac。
        case disablePending
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
    private let system: LiveActivitySystemHooks
    private weak var lockScreenStore: LockScreenApprovalStore?
    /// 按档案取 agentd 客户端；由 App 注入，与锁屏审批走同一条路由。
    var makeClient: ((String) async throws -> AgentAPIClient)?
    /// 档案的 agentd installation_id，用来在本机算出 hostTag。
    var installationIDForProfile: ((String) -> String?)?
    /// 档案是否还在。档案删掉后它的 agentd 上没有可注销的设备，注销这一步视为完成。
    var profileExists: ((String) -> Bool)?
    /// 点按活动解析出会话后交给现有通知跳转；由 App 注入。
    var onRouteResolved: ((SessionNotificationRoute) -> Void)?
    /// 冷启动时会话列表还没加载，点按的链接先留着，会话列表到了再解析。
    private var pendingLink: LiveActivityPendingLink?

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
        providerClientFactory: @escaping (String) -> PushProviderClient = { PushProviderClient(baseURL: $0) },
        system: LiveActivitySystemHooks = .live
    ) {
        self.defaults = defaults
        self.ticketStore = ticketStore
        self.environment = environment
        self.providerClientFactory = providerClientFactory
        self.system = system
        self.isToggleOn = LiveActivityPreferences.isToggleOn(in: defaults)
    }

    static var isSupportedPlatform: Bool {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    func attach(lockScreenStore: LockScreenApprovalStore) {
        self.lockScreenStore = lockScreenStore
        // 上次关闭（本开关或消息通知）或删掉绑定的那台 Mac 之后，进程可能在清理排队前就被结束：
        // 启动时补做，票据才会被撤销。放进队列里判断，用的是 App 注入完的档案查询。只有关闭本开关
        // 时才另外注销 agentd；关闭消息通知时设备注销会一并删掉，档案删了也无处可注销。
        enqueue {
            let record = self.ticketStore.load()
            let profileGone = record.map { self.profileExists?($0.profileID) == false } ?? false
            guard !self.isToggleOn || !LiveActivityPreferences.isEffective(in: self.defaults) || profileGone else {
                return
            }
            await self.teardown(unregisterRemote: !self.isToggleOn && record != nil && !profileGone)
        }
    }

    func attach(lockScreenStore: LockScreenApprovalStore, sessionStore: SessionStore, appStore: AppStore) {
        attach(lockScreenStore: lockScreenStore)
        startObservingActivities()
        // 会话列表在流式回复期间持续变化；按秒节流，只关心「有没有会话在跑」的跳变。
        sessionStore.$sessions
            .combineLatest(appStore.$activeConnectionProfileID)
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak appStore] sessions, profileID in
                self?.resolvePendingLink(
                    profiles: appStore?.connectionProfiles ?? [], activeProfileID: profileID, sessions: sessions
                )
                self?.sessionsDidChange(sessions, activeProfileID: profileID, isAppActive: Self.isAppActive)
            }
            .store(in: &cancellables)
        // 关闭消息通知、注销、换绑或删掉绑定的那台 Mac 都会改变绑定；@Published 在 willSet
        // 发布，等下一轮再读。
        lockScreenStore.$notificationsEnabled.map { _ in () }
            .merge(with: lockScreenStore.$status.map { _ in () })
            .merge(with: appStore.$connectionProfiles.map { $0.map(\.id) }.removeDuplicates().map { _ in () })
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
            enqueue {
                await self.reconcileBinding()
                await self.registerStartTokenIfNeeded()
            }
        } else {
            availability = .off
            enqueue { await self.teardown(unregisterRemote: true) }
        }
    }

    /// 前台生命周期刷新：在锁屏审批同步之后调用，确认绑定、agentd 能力并补登记。
    func synchronize(client: AgentAPIClient, profileID: String) {
        enqueue {
            // 先取 agentd 能力与 host_tag：档案没存 installation_id 时，绑定要靠它才能算出 hostTag。
            var repair = LiveActivityRegistrationRepair()
            if let store = self.lockScreenStore, store.notificationsEnabled, store.isEnabled,
               store.registeredProfileID == profileID,
               let status = try? await client.pushStatus() {
                self.hostSupport[profileID] = (status.liveActivity == true, status.hostTag)
                repair = LiveActivityRegistrationRepair(
                    device: status.devices?.first { $0.deviceID == store.deviceID },
                    record: self.ticketStore.load()
                )
            }
            await self.reconcileBinding()
            guard self.currentBinding()?.profileID == profileID else { return }
            // agentd 那边丢了票据（例如它的活动票据文件被重置）而本机记录还新：按状态接口强制补登记。
            await self.registerStartTokenIfNeeded(force: repair.start)
            for activityID in Array(self.latestUpdateTokens.keys) {
                await self.registerUpdateTokenIfNeeded(activityID: activityID, force: repair.update)
            }
        }
    }

    /// 消息通知开关或绑定变化后调用：不再满足条件时结束活动并清理票据。
    func notificationBindingDidChange() {
        enqueue { await self.reconcileBinding() }
    }

    // MARK: - 点按活动

    /// 能立即映射到会话就打开；会话列表还没加载（冷启动）时留着，到了再解析，过期则只打开 App。
    func open(link: MimiTurnActivityLink, profiles: [ConnectionProfile], activeProfileID: String?, sessions: [AgentSession]) {
        pendingLink = LiveActivityPendingLink(link: link, createdAt: Date())
        resolvePendingLink(profiles: profiles, activeProfileID: activeProfileID, sessions: sessions)
    }

    private func resolvePendingLink(profiles: [ConnectionProfile], activeProfileID: String?, sessions: [AgentSession]) {
        guard let pendingLink else { return }
        switch pendingLink.resolve(now: Date(), profiles: profiles, activeProfileID: activeProfileID, sessions: sessions) {
        case .route(let route):
            self.pendingLink = nil
            onRouteResolved?(route)
        case .drop:
            self.pendingLink = nil
        case .wait:
            break
        }
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
              !store.deviceID.isEmpty, !store.installationID.isEmpty,
              // 绑定的那台 Mac 已从本机删除：它的活动与票据都应清理，不再算有效绑定。
              profileExists?(profileID) ?? true else {
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
        // 上次关闭没撤销完的票据先补撤销；补不完也照常往下走，不阻塞重新开启。
        await drainBacklog()
        guard isToggleOn else {
            // 开关已关但记录或活动还在（例如关闭后清理还没跑进程就被结束）：先补做清理。
            await teardown(unregisterRemote: ticketStore.load() != nil)
            availability = closedAvailability(.off)
            return
        }
        guard LiveActivityPreferences.isEffective(in: defaults), let binding = currentBinding() else {
            // 关闭消息通知时 agentd 已随设备注销删掉活动票据，这里只撤销与清理本机。
            await teardown(unregisterRemote: false)
            availability = LiveActivityPreferences.isEffective(in: defaults)
                ? .requiresNotifications
                : closedAvailability(.requiresNotifications)
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
        } else if !system.activitiesEnabled() {
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

    /// `allowsUnconfirmedHost`：还没取到 agentd 状态时也放行。hostSupport 只在前台同步时填，
    /// 远程拉起后 App 在后台被冷启动唤醒时它是空的；这时活动本身就证明那台 Mac 支持实时活动。
    private func registrationContext(allowsUnconfirmedHost: Bool = false) -> (Binding, PushProviderClient)? {
        guard isToggleOn, LiveActivityPreferences.isEffective(in: defaults),
              let binding = currentBinding(),
              system.activitiesEnabled() else {
            return nil
        }
        switch hostSupport[binding.profileID]?.supported {
        case true?:
            break
        case nil where allowsUnconfirmedHost:
            break
        default:
            return nil
        }
        return (binding, providerClientFactory(binding.providerURL))
    }

    /// 更新 Token 没能登记的原因，只用于诊断。
    private func updateSkipReason() -> String {
        guard isToggleOn, LiveActivityPreferences.isEffective(in: defaults) else { return "disabled" }
        guard let binding = currentBinding() else { return "no_binding" }
        if hostSupport[binding.profileID]?.supported == false { return "host_unsupported" }
        return "system_disabled"
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

    private func registerStartTokenIfNeeded(force: Bool = false) async {
        guard let token = latestStartToken, let context = registrationContext() else { return }
        let (binding, provider) = context
        var record = loadRecord(for: binding)
        let fingerprint = connectionCredentialFingerprint(token)
        if !force, record.startIsCurrent(tokenFingerprint: fingerprint, now: Date()) {
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

    /// 收到某个活动的更新 Token（包括启动时已存在的活动）：记下并排队登记。同一个 Token 不重复排队，
    /// 没登记上的由回到前台时的 `synchronize` 补登记。
    func didReceiveUpdateToken(_ token: String, activityID: String, hostTag: String) {
        guard latestUpdateTokens[activityID]?.token != token else { return }
        latestUpdateTokens[activityID] = (hostTag, token)
        recordDiagnostic("update_token", reason: nil)
        enqueue { await self.registerUpdateTokenIfNeeded(activityID: activityID) }
    }

    private func registerUpdateTokenIfNeeded(activityID: String, force: Bool = false) async {
        guard let latest = latestUpdateTokens[activityID] else { return }
        // 活动是这台 Mac 远程拉起的，或在确认支持后本机拉起的：不必等状态接口确认能力。
        guard let context = registrationContext(allowsUnconfirmedHost: true) else {
            recordDiagnostic("update_skipped", reason: updateSkipReason())
            return
        }
        guard latest.hostTag == context.0.hostTag else {
            recordDiagnostic("update_skipped", reason: "host_mismatch")
            return
        }
        guard system.isActivityAlive(activityID) else {
            recordDiagnostic("update_skipped", reason: "activity_ended")
            return
        }
        let (binding, provider) = context
        var record = loadRecord(for: binding)
        let fingerprint = connectionCredentialFingerprint(latest.token)
        if !force, record.updateIsCurrent(activityID: activityID, tokenFingerprint: fingerprint, now: Date()) {
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

    /// 结束本机全部活动，把已登记的票据移进待撤销队列后清掉当前记录，再尽力撤销。
    /// agentd 侧：关闭开关时显式注销；关闭消息通知或换绑时设备注销已经一并删掉，不再联系。
    private func teardown(unregisterRemote: Bool) async {
        endActivities { _ in true }
        latestUpdateTokens.removeAll()
        if let record = ticketStore.load() {
            var backlog = ticketStore.loadBacklog() ?? LiveActivityRevocationBacklog()
            backlog.append(record)
            if unregisterRemote {
                backlog.unregisterProfileID = record.profileID
            }
            // 先落盘队列再删记录：中途被杀也不会丢掉还没撤销的票据。
            ticketStore.saveBacklog(backlog)
            ticketStore.delete()
        }
        await drainBacklog()
    }

    /// 撤销待撤销队列。失败的部分留到下次回到前台；它不阻塞任何登记。
    private func drainBacklog() async {
        guard var backlog = ticketStore.loadBacklog() else { return }
        if isToggleOn, LiveActivityPreferences.isEffective(in: defaults) {
            // 已重新开启：新登记的票据会覆盖旧的，再注销反而会删掉新票据。
            backlog.unregisterProfileID = nil
        }
        let deviceID = lockScreenStore?.deviceID ?? ""
        let makeClient = self.makeClient
        let profileExists = self.profileExists
        let providerClientFactory = self.providerClientFactory
        let remaining = await LiveActivityTicketRevocation.run(
            backlog: backlog,
            unregister: { profileID in
                guard !deviceID.isEmpty, let makeClient, profileExists?(profileID) == true else {
                    throw LiveActivityRevocationError.hostGone
                }
                do {
                    try await makeClient(profileID).unregisterLiveActivity(deviceID: deviceID)
                } catch let error where LiveActivityTicketRevocation.isHostGone(error) {
                    throw LiveActivityRevocationError.hostGone
                }
            },
            revoke: { try await providerClientFactory($0.providerURL).revokeTicket($0.ticket) }
        )
        ticketStore.saveBacklog(remaining)
        if let remaining {
            recordDiagnostic("clear_pending", reason: "tickets=\(remaining.tickets.count)")
        } else {
            recordDiagnostic("cleared", reason: nil)
        }
        if !(isToggleOn && LiveActivityPreferences.isEffective(in: defaults)) {
            availability = remaining != nil ? .disablePending : (isToggleOn ? .requiresNotifications : .off)
        } else if availability == .disablePending {
            availability = .pending
        }
    }

    /// 新出现或启动时已存在的活动该归哪台 Mac：优先当前绑定，算不出时用已登记记录里的
    /// hostTag；两者都没有时不判断，避免绑定尚未就绪时误删正常活动。
    private func expectedHostTag() -> String? {
        if let binding = currentBinding() { return binding.hostTag }
        guard let record = ticketStore.load(), record.profileID == lockScreenStore?.registeredProfileID else {
            return nil
        }
        return record.hostTag
    }

    /// 已关闭（开关或消息通知）时的显示：还有票据没撤销完就是「关闭尚未完成」。
    private func closedAvailability(_ fallback: Availability) -> Availability {
        ticketStore.loadBacklog() != nil ? .disablePending : fallback
    }

    /// 测试用：等待已排队的登记、注销与清理完成。
    func waitForPendingOperations() async {
        await operationTail?.value
    }

    // MARK: - 串行化

    /// 登记、注销与清理都排进同一条队列：MainActor 在 await 期间会重入，
    /// 不能让关闭开关之后的旧登记又把票据写回 agentd。
    ///
    /// 远程拉起后系统只在后台短暂唤醒 App 交付 Token，登记要先向推送服务换票据、再登记到 agentd，
    /// 两次联网都得在挂起前做完；排队等前一项的时间也算在内，所以从入队起就申请后台执行时间。
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = operationTail
        let endBackgroundExecution = system.beginBackgroundExecution("MimiLiveActivityRegistration")
        operationTail = Task { @MainActor in
            await previous?.value
            await operation()
            endBackgroundExecution()
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
    fileprivate static var systemAllowsActivities: Bool {
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
                // 关闭后、撤销确认前，推送服务仍可能凭旧 Ticket 远程拉起；换绑后旧 Mac 也可能
                // 迟到地远程拉起。这两种都在本机立即结束。
                guard LiveActivityHostFilter.keeps(
                    hostTag: activity.attributes.hostTag,
                    expectedHostTag: self.expectedHostTag(),
                    isEnabled: self.isToggleOn && LiveActivityPreferences.isEffective(in: self.defaults)
                ) else {
                    Task { await activity.end(nil, dismissalPolicy: .immediate) }
                    continue
                }
                self.endSuperseded(by: activity)
                self.track(activity)
            }
        })
        let isEnabled = isToggleOn && LiveActivityPreferences.isEffective(in: defaults)
        let expected = expectedHostTag()
        let existing = Activity<MimiTurnActivityAttributes>.activities
        var kept: [Activity<MimiTurnActivityAttributes>] = []
        for activity in existing where Self.isAlive(activity.activityState) {
            if LiveActivityHostFilter.keeps(
                hostTag: activity.attributes.hostTag, expectedHostTag: expected, isEnabled: isEnabled
            ) {
                kept.append(activity)
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
        // App 没在运行时 agentd 可能又远程拉起了一个：同一台 Mac 只留一个，优先已登记更新票据的。
        let duplicates = LiveActivityHostFilter.duplicatesToEnd(
            kept.map { (id: $0.id, hostTag: $0.attributes.hostTag) },
            registeredIDs: Set(ticketStore.load()?.updates.keys.map { $0 } ?? [])
        )
        // 远程拉起新一轮时 App 常常是被冷启动到后台的：上一轮已结束、还留在锁屏上的卡同样立即收起。
        let lingering = existing.filter { $0.activityState == .ended }
        let current = kept.filter { !duplicates.contains($0.id) }
        let superseded = LiveActivityHostFilter.supersededToEnd(
            lingering.map { (id: $0.id, hostTag: $0.attributes.hostTag) },
            current: current.map { (id: $0.id, hostTag: $0.attributes.hostTag) }
        )
        let dismissed = lingering.filter { superseded.contains($0.id) }
        for activity in dismissed {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        if !dismissed.isEmpty {
            recordDiagnostic("superseded", reason: "launch ended=\(dismissed.count)")
        }
        for activity in kept {
            if duplicates.contains(activity.id) {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            } else {
                track(activity)
            }
        }
    }

    /// 同一台 Mac 只保留最新的一个：本机拉起与远程启动撞在一起时，旧的那个没有人更新，留着只会停在
    /// 过时的状态；上一轮已结束的卡按 dismissal 还会在锁屏留一段时间，和新一轮叠在一起时常排在最上面，
    /// 盖住新一轮的「待你处理」。两种都立即收起。
    private func endSuperseded(by activity: Activity<MimiTurnActivityAttributes>) {
        guard Self.isAlive(activity.activityState) else { return }
        let others = Activity<MimiTurnActivityAttributes>.activities.filter {
            $0.id != activity.id && (Self.isAlive($0.activityState) || $0.activityState == .ended)
        }
        let superseded = LiveActivityHostFilter.supersededToEnd(
            others.map { (id: $0.id, hostTag: $0.attributes.hostTag) },
            current: [(id: activity.id, hostTag: activity.attributes.hostTag)]
        )
        let ending = others.filter { superseded.contains($0.id) }
        for other in ending {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        if !ending.isEmpty {
            let ended = ending.filter { $0.activityState == .ended }.count
            recordDiagnostic("superseded", reason: "alive=\(ending.count - ended) ended=\(ended)")
        }
    }

    private func track(_ activity: Activity<MimiTurnActivityAttributes>) {
        let activityID = activity.id
        guard activityTasks[activityID] == nil else { return }
        let hostTag = activity.attributes.hostTag
        if let token = activity.pushToken {
            // 冷启动（包括远程拉起后在后台被唤醒）时活动早就有 Token：直接登记，不赌
            // pushTokenUpdates 会不会再发一次当前值。
            didReceiveUpdateToken(Self.hex(token), activityID: activityID, hostTag: hostTag)
        }
        activityTasks[activityID] = [
            Task { @MainActor [weak self] in
                for await data in activity.pushTokenUpdates {
                    guard let self else { return }
                    self.didReceiveUpdateToken(Self.hex(data), activityID: activityID, hostTag: hostTag)
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

    fileprivate static func isActivityAlive(_ activityID: String) -> Bool {
        Activity<MimiTurnActivityAttributes>.activities.contains {
            $0.id == activityID && isAlive($0.activityState)
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
        guard system.activitiesEnabled(),
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
            // 上面只挡住了还在跑的同一台 Mac 的活动；上一轮已结束的卡这里收起，不依赖 activityUpdates
            // 是否会报告本机拉起的活动。
            endSuperseded(by: activity)
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
    fileprivate static var systemAllowsActivities: Bool { false }
    private func startObservingActivities() {}
    fileprivate static func isActivityAlive(_ activityID: String) -> Bool { false }
    private func endActivities(where shouldEnd: (String) -> Bool) {}
    private func requestLocalActivity(hostTag: String, state: MimiTurnActivityState) {}
    #endif
}

/// 协调器用到的系统能力：ActivityKit 的授权与活动状态、UIKit 的后台执行时间。单测里没有真实活动，
/// 也不该真去申请后台时间，所以集中成一处可替换。
struct LiveActivitySystemHooks {
    /// 系统设置里是否允许这个 App 的实时活动。
    var activitiesEnabled: @MainActor () -> Bool
    /// 这个活动是否还在（active 或 stale）。
    var isActivityAlive: @MainActor (String) -> Bool
    /// 申请后台执行时间，返回结束申请的闭包；系统提前收回时自行结束，重复调用无副作用。
    var beginBackgroundExecution: @MainActor (String) -> @MainActor () -> Void

    static var live: LiveActivitySystemHooks {
        LiveActivitySystemHooks(
            activitiesEnabled: { LiveActivityCoordinator.systemAllowsActivities },
            isActivityAlive: { LiveActivityCoordinator.isActivityAlive($0) },
            beginBackgroundExecution: { name in
                #if canImport(UIKit)
                let assertion = LiveActivityBackgroundExecution(name: name)
                return { assertion.end() }
                #else
                return {}
                #endif
            }
        )
    }
}

#if canImport(UIKit)
/// 一次后台执行时间申请。到期时只结束申请、不打断登记：没做完的部分回到前台由 `synchronize` 补。
@MainActor
private final class LiveActivityBackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

/// 本机记录说已登记、agentd 状态却说没有：需要强制补登记。旧版 agentd 不回报这两个字段时不判断。
struct LiveActivityRegistrationRepair: Equatable {
    var start = false
    var update = false

    init() {}

    init(device: PushDeviceSummary?, record: LiveActivityTicketRecord?) {
        guard let device, let record else { return }
        start = record.start != nil && device.liveActivityStart == false
        update = !record.updates.isEmpty && device.liveActivityUpdate == false
    }
}

/// 本机看到的活动要不要留：实时活动关闭时一律不留；知道当前该归哪台 Mac 时只留那台的。
enum LiveActivityHostFilter {
    static func keeps(hostTag: String, expectedHostTag: String?, isEnabled: Bool) -> Bool {
        guard isEnabled else { return false }
        guard let expectedHostTag else { return true }
        return hostTag.uppercased() == expectedHostTag.uppercased()
    }

    /// 同一台 Mac 有多个活动时要结束的那些：保留已登记更新票据的最后一个，都没登记时保留
    /// 最后一个（系统按创建顺序列出）。
    static func duplicatesToEnd(
        _ activities: [(id: String, hostTag: String)],
        registeredIDs: Set<String>
    ) -> Set<String> {
        var byHost: [String: [String]] = [:]
        var hostOrder: [String] = []
        for activity in activities {
            let host = activity.hostTag.uppercased()
            if byHost[host] == nil { hostOrder.append(host) }
            byHost[host, default: []].append(activity.id)
        }
        var ending: Set<String> = []
        for host in hostOrder {
            guard let ids = byHost[host], ids.count > 1 else { continue }
            let keeper = ids.last(where: registeredIDs.contains) ?? ids[ids.count - 1]
            ending.formUnion(ids.filter { $0 != keeper })
        }
        return ending
    }

    /// 同一台 Mac 有了当前活动后要立即收起的其他活动：还在跑的没人再更新，已结束的按 dismissal 还留在
    /// 锁屏上。只看是不是同一台 Mac，不看先后：已结束的活动不会再更新，当前活动一定是更新的一轮；而且
    /// 系统列出活动的顺序不是创建顺序，冷启动时实测新活动排在已结束的旧活动前面。
    static func supersededToEnd(
        _ activities: [(id: String, hostTag: String)],
        current: [(id: String, hostTag: String)]
    ) -> Set<String> {
        let currentIDs = Set(current.map(\.id))
        let currentHosts = Set(current.map { $0.hostTag.uppercased() })
        return Set(activities.filter {
            !currentIDs.contains($0.id) && currentHosts.contains($0.hostTag.uppercased())
        }.map(\.id))
    }
}

/// 点按活动时留着待解析的链接。只等一分钟：之后才加载出来的会话不再自动跳转，免得打断用户。
struct LiveActivityPendingLink: Equatable {
    static let lifetime: TimeInterval = 60

    enum Resolution: Equatable {
        case route(SessionNotificationRoute)
        case wait
        case drop
    }

    let link: MimiTurnActivityLink
    let createdAt: Date

    func resolve(
        now: Date,
        profiles: [ConnectionProfile],
        activeProfileID: String?,
        sessions: [AgentSession]
    ) -> Resolution {
        guard now.timeIntervalSince(createdAt) <= Self.lifetime else { return .drop }
        // 点按时当前就在另一台 Mac：只打开 App。不能留着等，否则用户一分钟内自己切到那台 Mac
        // 时会被突然拉进它的会话（#851 评审）。只有档案还没就绪或会话没加载完时才等。
        if LiveActivityLinkRouting.activeHostMatches(
            link: link, profiles: profiles, activeProfileID: activeProfileID
        ) == false {
            return .drop
        }
        if let route = LiveActivityLinkRouting.route(
            for: link, profiles: profiles, activeProfileID: activeProfileID, sessions: sessions
        ) {
            return .route(route)
        }
        return .wait
    }
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
              activeHostMatches(link: link, profiles: profiles, activeProfileID: activeProfileID) == true else {
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

extension LiveActivityLinkRouting {
    /// 当前档案是不是链接里那台 Mac：nil 表示还判断不了（没有当前档案或还不知道它的安装身份）。
    static func activeHostMatches(
        link: MimiTurnActivityLink,
        profiles: [ConnectionProfile],
        activeProfileID: String?
    ) -> Bool? {
        guard let activeProfileID,
              let profile = profiles.first(where: { $0.id == activeProfileID }),
              let installationID = profile.installationID else {
            return nil
        }
        return NotificationSessionTag.hostTag(installationID: installationID) == link.hostTag
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

import SwiftUI
import Combine
import UIKit
import UserNotifications

/// 本地通知只携带路由元数据，不携带 Token、消息正文或工作目录。
/// version 用于拒绝未来不兼容或旧版无边界的 payload。
struct SessionNotificationRoute: Equatable, Hashable {
    static let currentVersion = 1

    let version: Int
    let profileID: String
    let projectID: String
    let sessionID: SessionID
    /// 来源 runtime（codex / claude）。远程推送和 agentd 路由都知道它；缺失时由
    /// SessionStore 按已记住的会话路由推断，不得把已知 Claude 会话改写成 Codex。
    let runtimeProvider: String?

    private enum Key {
        static let version = "mimi.route.version"
        static let profileID = "mimi.route.profileID"
        static let projectID = "mimi.route.projectID"
        static let sessionID = "mimi.route.sessionID"
        static let runtimeProvider = "mimi.route.runtime"
    }

    static func current(
        profileID: String,
        projectID: String,
        sessionID: SessionID,
        runtimeProvider: String? = nil
    ) -> SessionNotificationRoute {
        SessionNotificationRoute(
            version: currentVersion,
            profileID: profileID,
            projectID: projectID,
            sessionID: sessionID,
            runtimeProvider: Self.normalizedRuntimeProvider(runtimeProvider)
        )
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let version = userInfo[Key.version] as? Int,
              version == Self.currentVersion,
              let profileID = Self.normalizedIdentifier(userInfo[Key.profileID]),
              let projectID = Self.normalizedIdentifier(userInfo[Key.projectID]),
              let sessionID = Self.normalizedIdentifier(userInfo[Key.sessionID])
        else {
            return nil
        }
        self.version = version
        self.profileID = profileID
        self.projectID = projectID
        self.sessionID = sessionID
        self.runtimeProvider = Self.normalizedRuntimeProvider(userInfo[Key.runtimeProvider] as? String)
    }

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            Key.version: version,
            Key.profileID: profileID,
            Key.projectID: projectID,
            Key.sessionID: sessionID
        ]
        if let runtimeProvider {
            info[Key.runtimeProvider] = runtimeProvider
        }
        return info
    }

    private init(
        version: Int,
        profileID: String,
        projectID: String,
        sessionID: SessionID,
        runtimeProvider: String?
    ) {
        self.version = version
        self.profileID = profileID
        self.projectID = projectID
        self.sessionID = sessionID
        self.runtimeProvider = runtimeProvider
    }

    /// 只接受两个已知 runtime；其它值视为未知，交给本地会话路由推断。
    private static func normalizedRuntimeProvider(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value == "codex" || value == "claude" else {
            return nil
        }
        return value
    }

    private static func normalizedIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 通知路由不是自由文本；限制长度可避免畸形 payload 被带入请求路径。
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
        return trimmed
    }
}

/// UNUserNotificationCenter 的薄适配层：系统回调只负责严格解码并入队，业务选择在 RootView 中执行。
/// pendingRoute 让冷启动时“通知先到、SwiftUI 后建立”也不会丢失点击。
@MainActor
final class SessionNotificationResponseAdapter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var pendingRoute: SessionNotificationRoute?
    /// App 在前台时代替系统横幅的回复轻提示（#510）。所有前台窗口共用同一条，点按、超时或
    /// 目标会话变为可见时清空。
    @Published private(set) var foregroundNotice: ForegroundSessionNotice?
    private(set) var pendingRouteIntent: UUID?
    var navigationOwnership: NotificationNavigationOwnership { approvalInbox.navigationOwnership }
    /// 锁屏审批走独立收件箱：它的动作要提交决策，而不是打开某个会话。
	let approvalInbox = LockScreenApprovalInbox()
	var handleApprovalAction: ((LockScreenApprovalDelivery) async -> Void)?
    private var approvalInboxObservation: AnyCancellable?
    private var visibleSessionRoutesByScene: [UUID: SessionNotificationRoute] = [:]
    private var visibleMessageTagsByScene: [UUID: (profile: String, session: String)] = [:]
    /// 此刻处于前台、挂着工作台的 Scene，以及“现在能否让用户看到轻提示”的判断。
    /// 没有任何一个能显示时（还没进入工作台；控制中心、通知中心盖住 App 使 Scene 变为
    /// inactive；工作台上正盖着 sheet 等模态页面）回复类通知仍交给系统横幅，不能静默丢掉。
    private var inAppNoticeHosts: [UUID: @MainActor () -> Bool] = [:]
    /// Scene 最近一次登记为前台的顺序；多窗口时轻提示交给最近激活、且此刻能显示的那个窗口。
    private var inAppNoticeHostOrder: [UUID] = []
    /// 以轻提示呈现、同时留在通知中心（`.list`）的回复提醒。用户点按轻提示或自己打开该会话后
    /// 从通知中心清掉，避免前台使用时持续累积；审批与定时提醒从不登记在这里。
    private var listedReplyNotificationIDs: [ForegroundSessionNotice.Target: [String]] = [:]
    var removeDeliveredNotifications: @MainActor ([String]) -> Void = { identifiers in
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    override init() {
        super.init()
        // RootView 观察的是 adapter；嵌套收件箱不会自动触发它的刷新。
        // 转发变化后，审批等待期间也能立即执行通知跳转，不依赖其他页面更新。
        approvalInboxObservation = approvalInbox.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    @discardableResult
    func receive(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = SessionNotificationRoute(userInfo: userInfo) else {
            return false
        }
        receive(route: route)
        return true
    }

    /// 点按 Live Activity（#830）等本机已经解析出会话的入口直接交给同一套跳转。
    func receive(route: SessionNotificationRoute) {
        pendingRouteIntent = navigationOwnership.accept()
        pendingRoute = route
    }

    func consume(_ route: SessionNotificationRoute) {
        guard pendingRoute == route else { return }
        pendingRouteIntent = nil
        pendingRoute = nil
    }

    /// 每个 Scene 独立登记当前真正可见的会话；任一窗口正在展示目标会话时，
    /// 对应运行态通知都不应再用横幅和声音重复打断用户。
    func setVisibleSessionRoute(_ route: SessionNotificationRoute?, for sceneID: UUID, installationID: String? = nil) {
        if let route, let installationID {
            visibleMessageTagsByScene[sceneID] = (
                LockScreenApprovalRouting.profileTag(installationID: installationID),
                LockScreenApprovalRouting.messageSessionTag(threadID: route.sessionID)
            )
        } else {
            visibleMessageTagsByScene.removeValue(forKey: sceneID)
        }
        if let route {
            visibleSessionRoutesByScene[sceneID] = route
        } else {
            visibleSessionRoutesByScene.removeValue(forKey: sceneID)
        }
        // 用户自己打开了提示对应的会话，轻提示已经没有意义。
        if let notice = foregroundNotice, isTargetVisible(notice.target) {
            foregroundNotice = nil
        }
        for target in listedReplyNotificationIDs.keys where isTargetVisible(target) {
            removeListedReplyNotifications(for: target)
        }
    }

    /// 每个 Scene 登记自己能否显示轻提示：工作台已挂载且 Scene 处于 active 时登记，
    /// `canPresent` 在通知到达那一刻再确认没有模态页面挡住提示。
    /// 全部窗口都离开前台时立即收起旧提示，回到前台不残留过期内容。
    func setInAppNoticeHostAvailable(
        _ available: Bool,
        for sceneID: UUID,
        canPresent: @escaping @MainActor () -> Bool = { true }
    ) {
        let wasHost = inAppNoticeHosts[sceneID] != nil
        if available {
            inAppNoticeHosts[sceneID] = canPresent
            if !wasHost {
                inAppNoticeHostOrder.removeAll { $0 == sceneID }
                inAppNoticeHostOrder.append(sceneID)
            }
        } else {
            inAppNoticeHosts.removeValue(forKey: sceneID)
            inAppNoticeHostOrder.removeAll { $0 == sceneID }
        }
        // 负责显示的窗口离开前台、或已经没有前台窗口时收起提示；通知本身已留在通知中心。
        if let notice = foregroundNotice,
           inAppNoticeHosts.isEmpty || (!available && notice.hostSceneID == sceneID) {
            foregroundNotice = nil
        }
    }

    func foregroundPresentation(
        forNotificationIdentifier identifier: String,
        userInfo: [AnyHashable: Any]
    ) -> ForegroundNotificationPresentation {
        let message = LockScreenApprovalNotification(userInfo: userInfo)
        let isRuntimeNotification = UserNotificationSessionReminderScheduler.isRuntimeNotificationID(identifier)
        if !MessageNotificationPreferences.isEnabled(), isRuntimeNotification || message != nil {
            return .quiet
        }
        if let message {
            // 审批推送有时效，必须当场看到；只有回复类消息改成轻提示。
            guard let tone = ForegroundSessionNotice.Tone(event: message.event) else {
                return .system
            }
            return replyPresentation(
                tone: tone,
                target: .message(profileTag: message.profileID, sessionTag: message.sessionTag)
            )
        }
        guard isRuntimeNotification, let route = SessionNotificationRoute(userInfo: userInfo) else {
            // 定时提醒、路由缺失或状态不确定时继续提醒，避免把真正需要处理的后台事件静默掉。
            return .system
        }
        if isTargetVisible(.route(route)) {
            // 目标会话就在眼前：审批卡片和回复都已经显示在页面里。
            return .quiet
        }
        // 旧版已排队的运行态通知没有类别键，无法确认是回复类时按系统横幅兜底。
        guard let kind = SessionRuntimeNotification.Kind(notificationUserInfo: userInfo),
              let tone = ForegroundSessionNotice.Tone(runtimeKind: kind) else {
            return .system
        }
        return replyPresentation(tone: tone, target: .route(route))
    }

    func presentationOptions(
        forNotificationIdentifier identifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        foregroundPresentation(forNotificationIdentifier: identifier, userInfo: userInfo).options
    }

    /// `willPresent` 的主线程部分：决定呈现方式，需要轻提示时发布给前台窗口。
    func presentInForeground(
        identifier: String,
        title: String,
        subtitle: String,
        body: String,
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        let presentation = foregroundPresentation(forNotificationIdentifier: identifier, userInfo: userInfo)
        if case .inApp(let tone, let target) = presentation {
            listedReplyNotificationIDs[target, default: []].append(identifier)
            foregroundNotice = ForegroundSessionNotice(
                requestIdentifier: identifier,
                tone: tone,
                target: target,
                title: title,
                subtitle: subtitle,
                body: body,
                userInfo: userInfo,
                hostSceneID: presentingNoticeSceneID()
            )
        }
        NotificationRouteDiagnostics.record(
            stage: NotificationRouteDiagnostics.Stage.foreground,
            outcome: presentation.diagnosticOutcome
        )
        return presentation.options
    }

    func dismissForegroundNotice(_ id: UUID) {
        guard foregroundNotice?.id == id else { return }
        foregroundNotice = nil
    }

    /// 轻提示点按与点系统横幅走同一个入口，不另建跳转逻辑。
    func openForegroundNotice(_ notice: ForegroundSessionNotice) async {
        dismissForegroundNotice(notice.id)
        // 用户已经通过轻提示去看这个会话，通知中心里同一会话的回复提醒随之清掉。
        removeListedReplyNotifications(for: notice.target)
        NotificationRouteDiagnostics.record(
            stage: NotificationRouteDiagnostics.Stage.foreground,
            outcome: "in_app_opened"
        )
        await handleNotificationOpen(
            userInfo: notice.userInfo,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: notice.requestIdentifier
        )
    }

    private func replyPresentation(
        tone: ForegroundSessionNotice.Tone,
        target: ForegroundSessionNotice.Target
    ) -> ForegroundNotificationPresentation {
        if isTargetVisible(target) {
            return .quiet
        }
        guard presentingNoticeSceneID() != nil else {
            return .system
        }
        return .inApp(tone, target)
    }

    private func removeListedReplyNotifications(for target: ForegroundSessionNotice.Target) {
        guard let identifiers = listedReplyNotificationIDs.removeValue(forKey: target),
              !identifiers.isEmpty else { return }
        removeDeliveredNotifications(identifiers)
    }

    /// 最近激活、且此刻没有被模态页面挡住的前台窗口。
    private func presentingNoticeSceneID() -> UUID? {
        inAppNoticeHostOrder.last { inAppNoticeHosts[$0]?() == true }
    }

    private func isTargetVisible(_ target: ForegroundSessionNotice.Target) -> Bool {
        switch target {
        case .route(let route):
            return visibleSessionRoutesByScene.values.contains(route)
        case .message(let profileTag, let sessionTag):
            return visibleMessageTagsByScene.values.contains {
                $0.profile == profileTag && $0.session == sessionTag
            }
        }
    }

    /// 通知点击的唯一入口：系统横幅、通知中心与 App 内轻提示的点按都从这里进入。
    func handleNotificationOpen(
        userInfo: [AnyHashable: Any],
        actionIdentifier: String,
        requestIdentifier: String
    ) async {
        // 自定义允许/拒绝动作必须在系统给出的通知响应窗口内完成。completion 只有
        // 在 agentd 返回后才调用，App 即使没有进入前台也能提交决策。
        if let delivery = LockScreenApprovalDelivery(
            userInfo: userInfo,
            actionIdentifier: actionIdentifier,
            requestIdentifier: requestIdentifier
        ) {
            // 只记事件、类型和截短的 action_id；这是整条路由诊断链的起点。
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.received,
                outcome: delivery.notification.event.rawValue,
                reason: delivery.decision.map { "\(delivery.notification.kind.rawValue)/\($0.rawValue)" }
                    ?? delivery.notification.kind.rawValue,
                correlation: NotificationRouteDiagnostics.shortReference(delivery.notification.actionID)
            )
            if delivery.decision != nil, let handleApprovalAction {
                await handleApprovalAction(delivery)
            } else {
                _ = approvalInbox.receive(
                    userInfo: userInfo,
                    actionIdentifier: actionIdentifier,
                    requestIdentifier: requestIdentifier
                )
            }
            return
        }
        let accepted = receive(userInfo: userInfo)
        // 本地运行态通知没有 action_id，用会话标签摘要做关联；无法解码的载荷也要留痕，
        // 否则“点了没反应”在诊断里会是一片空白。
        NotificationRouteDiagnostics.record(
            stage: NotificationRouteDiagnostics.Stage.received,
            outcome: accepted ? "session_route" : "rejected",
            reason: accepted ? nil : "undecodable_payload",
            correlation: pendingRoute.flatMap {
                NotificationRouteDiagnostics.shortReference(
                    LockScreenApprovalRouting.messageSessionTag(threadID: $0.sessionID)
                )
            }
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let requestIdentifier = response.notification.request.identifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            await self?.handleNotificationOpen(
                userInfo: userInfo,
                actionIdentifier: actionIdentifier,
                requestIdentifier: requestIdentifier
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request
        Task { @MainActor [weak self] in
            let options = self?.presentInForeground(
                identifier: request.identifier,
                title: request.content.title,
                subtitle: request.content.subtitle,
                body: request.content.body,
                userInfo: request.content.userInfo
            ) ?? [.banner, .sound]
            completionHandler(options)
        }
    }
}

@main
struct MimiRemoteApp: App {
#if canImport(UIKit)
    // Device Token 只在 UIApplicationDelegate 回调里出现，SwiftUI App 拿不到它。
    @UIApplicationDelegateAdaptor(PushApplicationDelegate.self) private var pushDelegate
#endif
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @StateObject private var appStore: AppStore
    @StateObject private var conversationStore: ConversationStore
    @StateObject private var logStore: LogStore
    @StateObject private var contextStore: SessionContextStore
    @StateObject private var sessionStore: SessionStore
    @StateObject private var themeStore: ThemeStore
    @StateObject private var workspaceAppearanceStore: WorkspaceAppearanceStore
    @StateObject private var notificationResponseAdapter: SessionNotificationResponseAdapter
    @StateObject private var hostStatusStore: HostStatusStore
    @StateObject private var lockScreenApprovalStore: LockScreenApprovalStore
    /// 把会话标题写进 App Group，通知扩展据此改写锁屏通知；随 App 生命周期常驻。
    @StateObject private var notificationTitleCacheWriter: NotificationTitleCacheWriter
    /// 锁屏 / 灵动岛实时活动（#830）：票据登记、前台本机拉起与关闭清理。
    @StateObject private var liveActivityCoordinator: LiveActivityCoordinator
    @StateObject private var tailcatExperimentController: TailcatExperimentController
    @StateObject private var managedConnectionEntitlementStore: ManagedConnectionEntitlementStore
    @StateObject private var managedConnectionDeviceStore: ManagedConnectionDeviceStore

    /// 紧凑布局的会话搜索走系统 `.searchable`，而系统在 iOS 26 上给它铺的是
    /// Liquid Glass——一屏里其它 chrome 全是扁平磨砂，只有它一块玻璃。
    /// `.searchable` 没有换材质的 API，只能用 appearance proxy 覆盖底色。
    ///
    /// 用动态 UIColor 而不是定值：闭包在绘制时才求值，深浅色切换能自动跟上。
    /// 局限是切换主题预设不会改变 trait，颜色要等下一次 trait 变化或重启才刷新。
    private static func installFlatSearchFieldAppearance(themeStore: ThemeStore) {
        UISearchTextField.appearance().backgroundColor = UIColor { traits in
            let scheme: ColorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
            // 中性阴影：浅色下比页面底暗、深色下比页面底亮，与磨砂 chrome 的明暗方向
            // 一致，且不带任何预设的主题色（纯 surface 在浅色下反而会比底色更亮）。
            return UIColor(themeStore.tokens(for: scheme).searchFieldBackground)
        }
    }

    init() {
        let appStore = AppStore()
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let contextStore = SessionContextStore()
        let themeStore = ThemeStore()
        Self.installFlatSearchFieldAppearance(themeStore: themeStore)
        let workspaceAppearanceStore = WorkspaceAppearanceStore()
        // 冷启动先把唯一 endpoint 下的旧偏好归入当前 Profile，避免用户直接打开
        // “个性化”时短暂看到默认风格，并在修改设置后覆盖原来的 Emoji 选择。
        workspaceAppearanceStore.migrateLegacyValueIfNeeded(
            profileID: appStore.activeHostScope.profileID,
            endpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
        let notificationResponseAdapter = SessionNotificationResponseAdapter()
        let managedConnectionEntitlementStore = ManagedConnectionEntitlementStore(
            storeKit: LiveManagedConnectionStoreKitClient(),
            entitlementAPI: LiveManagedConnectionEntitlementAPIClient()
        )
        let managedConnectionIdentityStore = ManagedConnectionMobileIdentityStore()
        let managedConnectionDeviceStore = ManagedConnectionDeviceStore(
            entitlementStore: managedConnectionEntitlementStore,
            identityStore: managedConnectionIdentityStore
        )
        let managedConnectionEventReporter = ManagedConnectionEventReporter(
            identityStore: managedConnectionIdentityStore
        )
        let tailcatExperimentController = TailcatExperimentController(
            appStore: appStore,
            managedPairingAuthorizer: managedConnectionDeviceStore,
            managedConnectionEventReporter: managedConnectionEventReporter
        )
        // SessionStore 初始化会同步绑定三个缓存 Store 的 Profile namespace。
        // 必须在 SwiftUI 接管这些 ObservableObject 前完成，避免在视图更新事务内发布状态。
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            contextStore: contextStore,
            workspaceAppearanceStore: workspaceAppearanceStore,
            tailcatExperimentController: tailcatExperimentController
        )
        notificationResponseAdapter.approvalInbox.navigationOwnership = sessionStore.notificationNavigation
        sessionStore.appReviewPrompt = AppReviewPromptCoordinator.makeLive(appStore: appStore, sessionStore: sessionStore)
        _appStore = StateObject(wrappedValue: appStore)
        _conversationStore = StateObject(wrappedValue: conversationStore)
        _logStore = StateObject(wrappedValue: logStore)
        _contextStore = StateObject(wrappedValue: contextStore)
        _themeStore = StateObject(wrappedValue: themeStore)
        _workspaceAppearanceStore = StateObject(wrappedValue: workspaceAppearanceStore)
        _notificationResponseAdapter = StateObject(wrappedValue: notificationResponseAdapter)
        _hostStatusStore = StateObject(wrappedValue: HostStatusStore())
		let lockScreenApprovalStore = LockScreenApprovalStore()
		_lockScreenApprovalStore = StateObject(wrappedValue: lockScreenApprovalStore)
		// 会话标题缓存只在锁屏提醒开启时维护；写入防抖并在后台队列完成。
		let notificationTitleCacheWriter = NotificationTitleCacheWriter()
		notificationTitleCacheWriter.attach(
			sessionStore: sessionStore,
			appStore: appStore,
			lockScreenApprovalStore: lockScreenApprovalStore
		)
		_notificationTitleCacheWriter = StateObject(wrappedValue: notificationTitleCacheWriter)
		let liveActivityCoordinator = LiveActivityCoordinator()
		liveActivityCoordinator.makeClient = { [weak appStore] profileID in
			guard let appStore else { throw LockScreenApprovalRoutingError.sourceProfileUnavailable }
			// 远程拉起后多在后台登记更新票据，那时当前档案的内存凭据已清空。
			return try await LockScreenApprovalRouting.maintenanceClient(profileID: profileID, appStore: appStore)
		}
		liveActivityCoordinator.installationIDForProfile = { [weak appStore] profileID in
			appStore?.connectionProfiles.first { $0.id == profileID }?.installationID
		}
		liveActivityCoordinator.profileExists = { [weak appStore] profileID in
			appStore?.connectionProfiles.contains { $0.id == profileID } ?? false
		}
		liveActivityCoordinator.onRouteResolved = { [weak notificationResponseAdapter] route in
			notificationResponseAdapter?.receive(route: route)
		}
		liveActivityCoordinator.attach(
			lockScreenStore: lockScreenApprovalStore,
			sessionStore: sessionStore,
			appStore: appStore
		)
		_liveActivityCoordinator = StateObject(wrappedValue: liveActivityCoordinator)
		notificationResponseAdapter.handleApprovalAction = { [weak appStore, weak lockScreenApprovalStore, weak sessionStore] delivery in
			guard let appStore, let lockScreenApprovalStore, let sessionStore, let decision = delivery.decision else { return }
			do {
				let source = try await LockScreenApprovalRouting.sourceClient(
					for: delivery.notification,
					appStore: appStore,
                    sessionStore: sessionStore
				)
				await lockScreenApprovalStore.submitDecision(
					decision,
					for: delivery.notification,
					client: source.client,
					notificationRequestIdentifier: delivery.requestIdentifier
				)
			} catch {
				lockScreenApprovalStore.markDecisionUnknown()
			}
		}
        _tailcatExperimentController = StateObject(wrappedValue: tailcatExperimentController)
        _managedConnectionEntitlementStore = StateObject(
            wrappedValue: managedConnectionEntitlementStore
        )
        _managedConnectionDeviceStore = StateObject(
            wrappedValue: managedConnectionDeviceStore
        )
        _sessionStore = StateObject(wrappedValue: sessionStore)
        // 桥接必须在 delegate 可能回调之前装好，否则冷启动拿到的 Token 会被丢弃。
		PushDeviceTokenBridge.onToken = { [weak appStore, weak lockScreenApprovalStore] token in
			guard let appStore, let lockScreenApprovalStore,
				  lockScreenApprovalStore.handleDeviceToken(token),
				  let profileID = lockScreenApprovalStore.registeredProfileID else { return }
			Task { @MainActor in
				guard let client = try? await LockScreenApprovalRouting.client(
					profileID: profileID,
					appStore: appStore
				) else {
					lockScreenApprovalStore.markRegistrationFailed()
					return
				}
				await lockScreenApprovalStore.refreshRegistrationAfterDeviceTokenChange(
					client: client,
					profileID: profileID
				)
			}
		}
        PushDeviceTokenBridge.onFailure = { [weak lockScreenApprovalStore] error in
            lockScreenApprovalStore?.handleDeviceTokenFailure(error)
        }
        PushDeviceTokenBridge.onSilentPayload = { [weak lockScreenApprovalStore] userInfo in
            guard let payload = LockScreenApprovalNotification(userInfo: userInfo) else { return }
            await lockScreenApprovalStore?.handleResolved(payload)
        }
		// 先安装桥接回调，再触发 APNs 注册，避免冷启动立即返回的 Token 丢失。
		if lockScreenApprovalStore.notificationsEnabled && lockScreenApprovalStore.isEnabled {
			lockScreenApprovalStore.registerNotificationInfrastructure()
		}
        // 尽早注册 delegate；冷启动点击会先进入 adapter 的 pendingRoute，等 RootView 消费。
        UNUserNotificationCenter.current().delegate = notificationResponseAdapter
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // locale 变化会让整个 SwiftUI 视图树重新求值，现有 L10n 调用即可即时换语言。
                .environment(\.locale, selectedAppLanguage.locale)
                .environmentObject(appStore)
                .environmentObject(lockScreenApprovalStore)
                .environmentObject(liveActivityCoordinator)
                .environmentObject(sessionStore)
                .environmentObject(conversationStore)
                .environmentObject(logStore)
                .environmentObject(contextStore)
                .environmentObject(themeStore)
                .environmentObject(workspaceAppearanceStore)
                .environmentObject(notificationResponseAdapter)
                .environmentObject(hostStatusStore)
                .environmentObject(tailcatExperimentController)
                .environmentObject(managedConnectionEntitlementStore)
                .environmentObject(managedConnectionDeviceStore)
                .onOpenURL { url in
                    if let link = MimiTurnActivityLink(url: url) {
                        // 点按 Live Activity：本机能映射到会话就打开它；冷启动时等会话列表加载，
                        // 映射不到只回到 App。
                        liveActivityCoordinator.open(
                            link: link,
                            profiles: appStore.connectionProfiles,
                            activeProfileID: appStore.activeConnectionProfileID,
                            sessions: sessionStore.sessions
                        )
                        return
                    }
                    Task { @MainActor in
                        await sessionStore.openPairingLink(url)
                    }
                }
        }
        // iPad 外接键盘的会话快捷键；动作由工作台外壳经 focusedSceneValue 提供（#828）。
        .commands {
            WorkbenchSessionCommands()
        }
    }

    private var selectedAppLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }
}

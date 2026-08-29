import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var workspaceAppearanceStore: WorkspaceAppearanceStore
    @EnvironmentObject private var notificationResponseAdapter: SessionNotificationResponseAdapter
    @EnvironmentObject private var hostStatusStore: HostStatusStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLogInspector = false
    @SceneStorage("root.lastSessionSnapshot") private var lastSessionSnapshot = ""
    @SceneStorage("root.workbenchRoute.v1") private var workbenchRouteStorage = WorkbenchRestorationRoute.defaultStorageValue
    @SceneStorage("root.hostRestoration.v2") private var hostRestorationStorage = ""
    @State private var notificationRouteAlertMessage: String?
    @State private var hasCompletedInitialBootstrap = false
    @State private var workbenchRouteRevision: UInt64 = 0
    @State private var pendingNotificationRouteRevision: UInt64?
    @State private var activeRestorationProfileID: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if appStore.canEnterWorkbench {
                appShell
            } else {
                SettingsView(isInitialSetup: true)
                    .environment(\.themeSystemColorScheme, colorScheme)
            }
        }
        .task(id: appStore.activeHostScope) {
            migrateLegacyWorkspaceAppearance()
        }
        .onChange(of: appStore.connectionProfiles) { _, _ in
            // 删除重复 endpoint 后，旧数据可能刚刚变成可唯一归属；此时立即重试，
            // 不要求用户先进入工作区页面才能恢复原来的图标偏好。
            migrateLegacyWorkspaceAppearance()
        }
        .task {
            restoreActiveHostNavigationIfNeeded()
            defer { hasCompletedInitialBootstrap = true }
#if targetEnvironment(macCatalyst)
            // Catalyst 先完成本机选路，再创建首批 REST/WebSocket client；否则并行 bootstrap
            // 可能已经拿 Tailscale 地址建好 runtime，导致本次启动无法真正切到 loopback。
            await appStore.preflightConnection()
#endif
            let requestedRoute = workbenchRoute
            let requestedRouteRevision = workbenchRouteRevision
            let requestedSnapshot = decodedSessionRestoreSnapshot
            await sessionStore.bootstrap()

            guard workbenchRoute == requestedRoute,
                  workbenchRouteRevision == requestedRouteRevision else {
                return
            }
            guard requestedRoute.detailSessionID != nil else {
                return
            }
            guard let requestedSnapshot else {
                // endpoint 或快照失效时安全回到列表，但不能覆盖 bootstrap 期间产生的新导航。
                setWorkbenchRoute(.sessions)
                return
            }

            let restoreLease = sessionStore.currentSelectionLease()
            let restoredSession = await sessionStore.resolveSessionForRestore(requestedSnapshot)
            guard workbenchRoute == requestedRoute,
                  workbenchRouteRevision == requestedRouteRevision,
                  sessionStore.isSelectionLeaseCurrent(restoreLease) else {
                return
            }
            guard let restoredSession else {
                setWorkbenchRoute(.sessions)
                return
            }
            _ = await sessionStore.selectSession(
                restoredSession,
                reason: .restoration,
                ifCurrent: restoreLease
            )
        }
        .task {
#if targetEnvironment(macCatalyst)
            // 已在上面的有序启动任务中完成。
#else
            // 冷启动先并行探测真实控制面和 WebSocket，设置页无需用户手动测试即可看到连接状态。
            await appStore.preflightConnection()
#endif
        }
        .task(id: notificationRouteTaskID) {
            guard let route = notificationResponseAdapter.pendingRoute else {
                pendingNotificationRouteRevision = nil
                return
            }
            // 记录通知到达时的内容路由。bootstrap 自己可能补齐默认项目，因此不能保存它之前的
            // selection lease；用户真正去往别处会推进 route revision，仍可淘汰这条旧通知。
            guard hasCompletedInitialBootstrap else {
                if pendingNotificationRouteRevision == nil {
                    pendingNotificationRouteRevision = workbenchRouteRevision
                }
                return
            }
            let expectedRouteRevision = pendingNotificationRouteRevision ?? workbenchRouteRevision
            // 先消费再做网络操作；新点击可独立入队，不会被旧任务结束时误清。
            notificationResponseAdapter.consume(route)
            pendingNotificationRouteRevision = nil
            guard expectedRouteRevision == workbenchRouteRevision else {
                return
            }
            let expectedSelectionLease = sessionStore.currentSelectionLease()
            await handleNotificationRoute(route, ifCurrent: expectedSelectionLease)
        }
        .task(id: scenePhase == .active ? sessionStore.selectedProjectID : nil) {
            guard scenePhase == .active else {
                return
            }
            await sessionStore.pollSelectedProjectSessionsWhileVisible()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                persistActiveHostRestoration()
                hostStatusStore.cancel()
                sessionStore.suspendForBackground()
                appStore.suspendCredentialsForBackground()
                return
            }
            guard phase == .active else {
                return
            }
            Task {
                do {
                    try await appStore.restoreCredentialsForForeground()
                    await sessionStore.resumeFromForeground()
                } catch is CancellationError {
                    // 后台/前台快速抖动或同时切换主机时由最新生命周期操作接管。
                } catch {
                    appStore.connectionStatus = .failed(error.localizedDescription)
                    appStore.lastError = error.localizedDescription
                }
            }
        }
        .onChange(of: sessionStore.selectedSession) { _, session in
            persistSessionRestoreSnapshotIfNeeded(session)
        }
        .onChange(of: appStore.activeConnectionProfileID) { _, profileID in
            switchRestorationNamespace(to: profileID)
        }
        .onChange(of: sessionStore.isConnectionSwitchInProgress) { _, isSwitching in
            if isSwitching {
                hostStatusStore.cancel()
            }
        }
        .environment(\.themeSystemColorScheme, colorScheme)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
        .background {
            ThemeScreenContextReader { isPad, screenSize in
                themeStore.applyDeviceDefaultFontScale(isPad: isPad, screenSize: screenSize)
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .background(tokens.background.ignoresSafeArea())
        .alert(L10n.text("ui.can_t_open_notifications"), isPresented: notificationRouteAlertBinding) {
            Button(L10n.text("ui.got_it"), role: .cancel) {}
        } message: {
            Text(notificationRouteAlertMessage ?? L10n.text("ui.please_try_again_later"))
        }
    }

    private func migrateLegacyWorkspaceAppearance() {
        workspaceAppearanceStore.migrateLegacyValueIfNeeded(
            profileID: appStore.activeHostScope.profileID,
            endpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
    }

    private var notificationRouteAlertBinding: Binding<Bool> {
        Binding(
            get: { notificationRouteAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    notificationRouteAlertMessage = nil
                }
            }
        )
    }

    private var notificationRouteTaskID: NotificationRouteTaskID {
        NotificationRouteTaskID(
            route: notificationResponseAdapter.pendingRoute,
            hasCompletedInitialBootstrap: hasCompletedInitialBootstrap
        )
    }

    private func handleNotificationRoute(
        _ route: SessionNotificationRoute,
        ifCurrent selectionLease: SessionSelectionLease
    ) async {
        switch await sessionStore.openSessionFromNotification(route, ifCurrent: selectionLease) {
        case .opened, .ignored:
            break
        case .requiresProfileSwitch(let displayName):
            if let displayName {
                notificationRouteAlertMessage = L10n.format("ui.this_notification_comes_from_value_please_switch_to", displayName)
            } else {
                notificationRouteAlertMessage = L10n.text("ui.this_notification_comes_from_another_mac_please_switch")
            }
        case .unavailable(let message):
            notificationRouteAlertMessage = message
        }
    }

    private var decodedSessionRestoreSnapshot: SessionRestoreSnapshot? {
        workbenchRoute.restoreSnapshot(
            from: lastSessionSnapshot,
            currentProfileID: appStore.activeConnectionProfileID,
            currentEndpoint: appStore.endpoint
        )
    }

    private var workbenchRoute: WorkbenchRestorationRoute {
        WorkbenchRestorationRoute(storageValue: workbenchRouteStorage)
    }

    private var workbenchRouteBinding: Binding<WorkbenchRestorationRoute> {
        Binding(
            get: { workbenchRoute },
            set: { setWorkbenchRoute($0) }
        )
    }

    private func setWorkbenchRoute(_ route: WorkbenchRestorationRoute) {
        guard workbenchRoute != route else { return }
        workbenchRouteRevision &+= 1
        workbenchRouteStorage = route.storageValue
        if route.detailSessionID == nil {
            // 用户已经真实离开详情页；旧快照继续存在会让下次冷启动再次进入会话。
            lastSessionSnapshot = ""
        } else {
            // 通知和工作区入口可能先完成 selectSession、再切详情路由；这里补齐另一种事件顺序。
            persistSessionRestoreSnapshotIfNeeded(sessionStore.selectedSession, route: route)
        }
        persistActiveHostRestoration()
    }

    private func persistSessionRestoreSnapshotIfNeeded(
        _ session: AgentSession?,
        route: WorkbenchRestorationRoute? = nil
    ) {
        let route = route ?? workbenchRoute
        guard let session,
              route.detailSessionID == session.id else { return }
        let snapshot = SessionRestoreSnapshot(
            profileID: appStore.notificationRoutingProfileID,
            endpoint: appStore.endpoint,
            session: session
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            lastSessionSnapshot = data.base64EncodedString()
            persistActiveHostRestoration()
        }
    }

    private func restoreActiveHostNavigationIfNeeded() {
        guard activeRestorationProfileID == nil else { return }
        let profileID = appStore.notificationRoutingProfileID
        activeRestorationProfileID = profileID
        guard let record = hostRestorationEnvelope.records[profileID] else {
            return
        }
        workbenchRouteRevision &+= 1
        workbenchRouteStorage = record.routeStorage
        lastSessionSnapshot = record.sessionSnapshot
    }

    private func switchRestorationNamespace(to rawProfileID: String?) {
        let nextProfileID = rawProfileID ?? appStore.notificationRoutingProfileID
        if let currentProfileID = activeRestorationProfileID {
            persistRestorationRecord(for: currentProfileID)
        }
        activeRestorationProfileID = nextProfileID
        let record = hostRestorationEnvelope.records[nextProfileID]
        workbenchRouteRevision &+= 1
        workbenchRouteStorage = record?.routeStorage ?? WorkbenchRestorationRoute.defaultStorageValue
        lastSessionSnapshot = record?.sessionSnapshot ?? ""
    }

    private func persistActiveHostRestoration() {
        guard let profileID = activeRestorationProfileID else { return }
        persistRestorationRecord(for: profileID)
    }

    private func persistRestorationRecord(for profileID: String) {
        var envelope = hostRestorationEnvelope
        envelope.records[profileID] = HostRestorationRecord(
            routeStorage: workbenchRouteStorage,
            sessionSnapshot: lastSessionSnapshot,
            updatedAt: Date()
        )
        // SceneStorage 只保留最近 8 台的轻量导航，不保存历史正文或媒体。
        if envelope.records.count > 8 {
            let retainedIDs = envelope.records
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(8)
                .map(\.key)
            envelope.records = envelope.records.filter { retainedIDs.contains($0.key) }
        }
        if let data = try? JSONEncoder().encode(envelope) {
            hostRestorationStorage = data.base64EncodedString()
        }
    }

    private var hostRestorationEnvelope: HostRestorationEnvelope {
        guard let data = Data(base64Encoded: hostRestorationStorage),
              let decoded = try? JSONDecoder().decode(HostRestorationEnvelope.self, from: data) else {
            return HostRestorationEnvelope(records: [:])
        }
        return decoded
    }

    private var appShell: some View {
        UnifiedWorkbenchShell(
            showingInspector: $showingLogInspector,
            restorationRoute: workbenchRouteBinding
        )
    }
}

private struct HostRestorationEnvelope: Codable {
    var records: [String: HostRestorationRecord]
}

private struct HostRestorationRecord: Codable {
    let routeStorage: String
    let sessionSnapshot: String
    let updatedAt: Date
}

private struct NotificationRouteTaskID: Equatable {
    let route: SessionNotificationRoute?
    let hasCompletedInitialBootstrap: Bool
}

/// SwiftUI 的容器宽度会随 Split View 改变；通过实际 Window Scene 读取物理屏幕，
/// 才能让 iPad mini 的默认字号稳定，并避免大屏 iPad 窄窗口被误判。
private struct ThemeScreenContextReader: UIViewRepresentable {
    let onResolve: @MainActor (_ isPad: Bool, _ screenSize: CGSize) -> Void

    func makeUIView(context: Context) -> ThemeScreenContextView {
        ThemeScreenContextView(onResolve: onResolve)
    }

    func updateUIView(_ uiView: ThemeScreenContextView, context: Context) {
        uiView.onResolve = onResolve
    }
}

private final class ThemeScreenContextView: UIView {
    var onResolve: @MainActor (_ isPad: Bool, _ screenSize: CGSize) -> Void

    init(onResolve: @escaping @MainActor (_ isPad: Bool, _ screenSize: CGSize) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let screen = window?.windowScene?.screen else {
            return
        }
#if targetEnvironment(macCatalyst)
        let isPad = false
#else
        let isPad = traitCollection.userInterfaceIdiom == .pad
#endif
        onResolve(isPad, screen.bounds.size)
    }
}

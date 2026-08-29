import SwiftUI
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

    private enum Key {
        static let version = "mimi.route.version"
        static let profileID = "mimi.route.profileID"
        static let projectID = "mimi.route.projectID"
        static let sessionID = "mimi.route.sessionID"
    }

    static func current(profileID: String, projectID: String, sessionID: SessionID) -> SessionNotificationRoute {
        SessionNotificationRoute(
            version: currentVersion,
            profileID: profileID,
            projectID: projectID,
            sessionID: sessionID
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
    }

    var userInfo: [AnyHashable: Any] {
        [
            Key.version: version,
            Key.profileID: profileID,
            Key.projectID: projectID,
            Key.sessionID: sessionID
        ]
    }

    private init(version: Int, profileID: String, projectID: String, sessionID: SessionID) {
        self.version = version
        self.profileID = profileID
        self.projectID = projectID
        self.sessionID = sessionID
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
    private var visibleSessionRoutesByScene: [UUID: SessionNotificationRoute] = [:]

    @discardableResult
    func receive(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = SessionNotificationRoute(userInfo: userInfo) else {
            return false
        }
        pendingRoute = route
        return true
    }

    func consume(_ route: SessionNotificationRoute) {
        guard pendingRoute == route else { return }
        pendingRoute = nil
    }

    /// 每个 Scene 独立登记当前真正可见的会话；任一窗口正在展示目标会话时，
    /// 对应运行态通知都不应再用横幅和声音重复打断用户。
    func setVisibleSessionRoute(_ route: SessionNotificationRoute?, for sceneID: UUID) {
        if let route {
            visibleSessionRoutesByScene[sceneID] = route
        } else {
            visibleSessionRoutesByScene.removeValue(forKey: sceneID)
        }
    }

    func presentationOptions(
        forNotificationIdentifier identifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        guard UserNotificationSessionReminderScheduler.isRuntimeNotificationID(identifier),
              let route = SessionNotificationRoute(userInfo: userInfo),
              visibleSessionRoutesByScene.values.contains(route)
        else {
            // 路由缺失或状态不确定时继续提醒，避免把真正需要处理的后台事件静默掉。
            return [.banner, .sound]
        }
        return []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor [weak self] in
            _ = self?.receive(userInfo: userInfo)
        }
        // 系统回调不等待网络或会话加载，避免通知点击处理超时。
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request
        Task { @MainActor [weak self] in
            let options = self?.presentationOptions(
                forNotificationIdentifier: request.identifier,
                userInfo: request.content.userInfo
            ) ?? [.banner, .sound]
            completionHandler(options)
        }
    }
}

@main
struct MimiRemoteApp: App {
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

    /// 紧凑布局的会话搜索走系统 `.searchable`，而系统在 iOS 26 上给它铺的是
    /// Liquid Glass——一屏里其它 chrome 全是扁平磨砂，只有它一块玻璃。
    /// `.searchable` 没有换材质的 API，只能用 appearance proxy 覆盖底色。
    ///
    /// 用动态 UIColor 而不是定值：闭包在绘制时才求值，深浅色切换能自动跟上。
    /// 局限是切换主题预设不会改变 trait，颜色要等下一次 trait 变化或重启才刷新。
    private static func installFlatSearchFieldAppearance(themeStore: ThemeStore) {
        UISearchTextField.appearance().backgroundColor = UIColor { traits in
            let scheme: ColorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
            // selectionFill 是主题里的中性色阶填充：浅色下比页面底暗、深色下比页面底亮，
            // 与磨砂 chrome 的明暗方向一致（纯 surface 在浅色下反而会比底色更亮）。
            return UIColor(themeStore.tokens(for: scheme).selectionFill)
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
        // SessionStore 初始化会同步绑定三个缓存 Store 的 Profile namespace。
        // 必须在 SwiftUI 接管这些 ObservableObject 前完成，避免在视图更新事务内发布状态。
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            contextStore: contextStore,
            workspaceAppearanceStore: workspaceAppearanceStore
        )
        _appStore = StateObject(wrappedValue: appStore)
        _conversationStore = StateObject(wrappedValue: conversationStore)
        _logStore = StateObject(wrappedValue: logStore)
        _contextStore = StateObject(wrappedValue: contextStore)
        _themeStore = StateObject(wrappedValue: themeStore)
        _workspaceAppearanceStore = StateObject(wrappedValue: workspaceAppearanceStore)
        _notificationResponseAdapter = StateObject(wrappedValue: notificationResponseAdapter)
        _hostStatusStore = StateObject(wrappedValue: HostStatusStore())
        _sessionStore = StateObject(wrappedValue: sessionStore)
        // 尽早注册 delegate；冷启动点击会先进入 adapter 的 pendingRoute，等 RootView 消费。
        UNUserNotificationCenter.current().delegate = notificationResponseAdapter
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // locale 变化会让整个 SwiftUI 视图树重新求值，现有 L10n 调用即可即时换语言。
                .environment(\.locale, selectedAppLanguage.locale)
                .environmentObject(appStore)
                .environmentObject(sessionStore)
                .environmentObject(conversationStore)
                .environmentObject(logStore)
                .environmentObject(contextStore)
                .environmentObject(themeStore)
                .environmentObject(workspaceAppearanceStore)
                .environmentObject(notificationResponseAdapter)
                .environmentObject(hostStatusStore)
                .onOpenURL { url in
                    Task { @MainActor in
                        do {
                            let wasConfigured = appStore.isConfigured
                            _ = try await sessionStore.applyPairingURL(url)
                            // 首次 URL 配对要覆盖 Tailscale / gateway 冷启动窗口；已有档案修复只做短等待。
                            _ = await sessionStore.refreshAfterConnectionCommit(
                                maxWait: wasConfigured ? 10 : 45
                            )
                        } catch {
                            appStore.connectionStatus = .failed(error.localizedDescription)
                            appStore.lastError = error.localizedDescription
                        }
                    }
                }
        }
    }

    private var selectedAppLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }
}

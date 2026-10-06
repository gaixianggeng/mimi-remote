import SwiftUI

/// 设置路径放在工作台外壳中。横竖屏更换 NavigationStack 时仍能恢复同一个详情页，
/// 不把这些临时导航信息写进用户偏好或会话恢复格式。
enum SettingsDestination: Hashable {
    case connection
    case appearance
    case language
    case defaultModels
    case defaultPermissions
    case lockScreenApproval
    case diagnostics
    case appDiagnostics
    case doctor
    case support
    case advanced
    case capabilities
    case about
    case privacyPolicy
    case termsOfUse
    case thirdPartyNotices
    case managedConnection
    case addComputer
    case speedTest
    case tailcat
}

@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published var mePath: [SettingsDestination] = [] {
        didSet { clearErrorWhenEnteringAddComputer(from: oldValue, to: mePath) }
    }
    @Published var devicePath: [SettingsDestination] = [] {
        didSet { clearErrorWhenEnteringAddComputer(from: oldValue, to: devicePath) }
    }
    @Published var profileRenamePresentation = ConnectionProfileRenamePresentationState()
    let connectionDraft = ConnectionSettingsDraft()
    let transientPreferences = SettingsTransientPreferences()

    private func clearErrorWhenEnteringAddComputer(
        from oldPath: [SettingsDestination],
        to newPath: [SettingsDestination]
    ) {
        // 导航路径在横竖屏重建时仍保留；只有新推入添加页才开始一轮新反馈。
        if !oldPath.contains(.addComputer), newPath.contains(.addComputer) {
            connectionDraft.beginAddingComputer()
        }
    }
}

/// 回退线路（Tailscale/局域网/HTTPS）的一次探测结果。Tailcat 的探测历史由
/// TailcatExperimentController 持久化，这里只承载非 Tailcat 线路的会话内展示。
struct FallbackRouteProbe: Equatable {
    let checkedAt: Date
    let pathKind: TailscaleNetworkPathResponse.Kind?
    let relayRegion: String?
    let httpMillis: Int?
    let succeeded: Bool
}

/// 仅保留当前工作台内的连接表单草稿；输入不触发会话外壳重绘，旋转也不会重置访问码。
@MainActor
final class ConnectionSettingsDraft: ObservableObject {
    @Published var endpoint = ""
    @Published var token = ""
    @Published var didLoadInitialConnection = false
    @Published var pendingManualConnectionIntent: ConnectionQRCodeScanIntent?
    /// 工作台横幅的「重新配对」要把用户直接带到扫码页，但扫码页由连接页持有并呈现：
    /// 横幅只能先打开这一页，再把一次性的请求交给它消费（#554）。
    @Published var pendingRepairRequest = false
    @Published var isSavingConnection = false
    @Published var isAddingConnectionProfile = false
    @Published var profileDisplayName = ""
    @Published var profileOperationID: String?
    @Published var pendingRemovalConfirmation: ConnectionCredentialRemovalConfirmation?
    @Published var isShowingAdvancedManualConnection = false
    @Published var localError: String?
    @Published var addComputerError: String?
    @Published var copyingConnectionProfileID: String?
    @Published var copiedConnectionProfileID: String?
    // 设备首页线路行的探测状态放草稿里，Section 重建或旋转都不丢。
    // 结果记着属于哪台电脑：切换后不能拿 A 的路径和延迟冒充 B 的。
    @Published var isProbingRoute = false
    @Published var fallbackRouteProbe: FallbackRouteProbe?
    @Published var routeProbeProfileID: String?
    var copyConnectionTask: Task<Void, Never>?
    var copyFeedbackTask: Task<Void, Never>?

    private var loadedProfileID: String?
    private var loadedEndpoint = ""
    private var loadedToken = ""

    func beginAddingComputer() {
        addComputerError = nil
    }

    /// 旋转只重建页面，不会改变来源值，因此保留用户输入。外部连接切换或凭据更新时，
    /// 旧草稿已不再对应当前连接，必须重新载入并退出旧的编辑上下文。
    @discardableResult
    func reloadIfConnectionChanged(profileID: String?, endpoint: String, token: String) -> Bool {
        guard !didLoadInitialConnection ||
                loadedProfileID != profileID ||
                loadedEndpoint != endpoint ||
                loadedToken != token else {
            return false
        }

        didLoadInitialConnection = true
        loadedProfileID = profileID
        loadedEndpoint = endpoint
        loadedToken = token
        self.endpoint = endpoint
        self.token = token
        pendingManualConnectionIntent = nil
        isAddingConnectionProfile = false
        profileDisplayName = ""
        pendingRemovalConfirmation = nil
        isShowingAdvancedManualConnection = false
        localError = nil
        addComputerError = nil
        return true
    }
}

struct SettingsDestinationView: View {
    @EnvironmentObject private var appStore: AppStore
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar
    @Environment(\.workbenchHasBottomTabBar) private var hasBottomTabBar
    @ObservedObject var navigation: SettingsNavigationState
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    let destination: SettingsDestination

    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(VoiceInputProvider.storageKey) private var voiceInputProviderRawValue = VoiceInputProvider.resolved(rawValue: nil).rawValue
    @AppStorage(ComposerPermissionMode.defaultStorageKey) private var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue

    /// 顶部 Tab 条只在 Tab 根页出现，push 出来的详情页藏掉它。
    ///
    /// 不藏的话，详情页顶部同时存在 Tab 条和导航栏，两者是否共用同一条 54pt 中心线
    /// 由系统在 TabView 首次布局时定下：冷启动是共用的，一旦经历「紧凑 → 宽屏 → 紧凑」
    /// 就会改成上下叠放，导航栏整体下移一整条 Tab 条的高度（实测 64pt）且不再复位，
    /// 看起来像返回键和标题自己往下掉。详情页本来也不需要就地切 Tab。
    ///
    /// 只针对顶部 Tab（iPad 紧凑宽度）。iPhone 的底部 Tab 条不参与顶部布局，
    /// 没有这个问题，继续保留；宽屏没有 TabView，这个修饰符本身是空操作。
    private var hidesTopTabBar: Bool {
        hasCompactTabBar && !hasBottomTabBar
    }

    var body: some View {
        destinationContent
            .toolbar(hidesTopTabBar ? .hidden : .automatic, for: .tabBar)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .connection:
            ConnectionSettingsView(qrScannerPresentation: qrScannerPresentation, navigation: navigation)
        case .appearance:
            AppearanceView(profileID: appStore.activeHostScope.profileID)
        case .language:
            LanguageSettingsView(appLanguageRawValue: $appLanguageRawValue, voiceInputProviderRawValue: $voiceInputProviderRawValue)
        case .defaultModels:
            DefaultModelSettingsView()
        case .defaultPermissions:
            SettingsOptionListView(
                title: L10n.text("ui.default_permissions"),
                options: ComposerPermissionMode.allCases,
                selection: Binding(
                    get: { ComposerPermissionMode.stored(defaultPermissionModeID) },
                    set: { defaultPermissionModeID = $0.rawValue }
                )
            )
        case .lockScreenApproval:
            LockScreenApprovalSettingsView()
        case .diagnostics:
            DiagnosticsAndSupportSettingsView(showsHistoryDiagnostics: developerModeEnabled)
        case .appDiagnostics:
            AppDiagnosticsSettingsView()
        case .doctor:
            DoctorView(showsHistoryDiagnostics: developerModeEnabled)
        case .support:
            LegalDocumentView(document: .support)
        case .advanced:
            AdvancedDevelopmentSettingsView(developerModeEnabled: $developerModeEnabled)
        case .capabilities:
            CapabilitiesView()
        case .about:
            AboutAndLegalSettingsView()
        case .privacyPolicy:
            LegalDocumentView(document: .privacyPolicy)
        case .termsOfUse:
            LegalDocumentView(document: .termsOfUse)
        case .thirdPartyNotices:
            ThirdPartyNoticesView()
        case .managedConnection:
            ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
        case .addComputer:
            AddComputerView(qrScannerPresentation: qrScannerPresentation, navigation: navigation)
        case .speedTest:
            ConnectionSpeedTestView(transientPreferences: navigation.transientPreferences)
        case .tailcat:
            TailcatExperimentSettingsView()
        }
    }
}

/// Tab 与宽屏详情共享同一份设置路径和扫码状态，页面只根据入口调整标题和返回行为。
struct WorkbenchSettingsPage: View {
    @ObservedObject var navigation: SettingsNavigationState
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    let tab: CompactWorkbenchTab
    let usesCompactNavigation: Bool
    let onOpenDevices: () -> Void
    let onReturnToMe: () -> Void

    var body: some View {
        Group {
            if tab == .devices {
                NavigationStack(path: $navigation.devicePath) {
                    ConnectionSettingsView(
                        qrScannerPresentation: qrScannerPresentation,
                        navigation: navigation,
                        isDevicesTab: usesCompactNavigation
                    )
                    .navigationDestination(for: SettingsDestination.self) { destination in
                        SettingsDestinationView(navigation: navigation, qrScannerPresentation: qrScannerPresentation, destination: destination)
                    }
                    .toolbar {
                        if !usesCompactNavigation {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: onReturnToMe) {
                                    Label(L10n.text("ui.me"), systemImage: "chevron.left")
                                }
                                .accessibilityIdentifier("settings.devices.backToMe")
                            }
                        }
                    }
                }
            } else {
                SettingsView(
                    isInitialSetup: false,
                    showsDoneButton: false,
                    showsDeviceEntry: !usesCompactNavigation,
                    onOpenDevices: onOpenDevices,
                    navigation: navigation,
                    qrScannerPresentation: qrScannerPresentation
                )
            }
        }
        .environmentObject(qrScannerPresentation)
        .environment(\.settingsUsesWorkbenchCanvas, true)
    }
}

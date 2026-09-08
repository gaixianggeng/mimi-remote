import SwiftUI

/// 设置路径放在工作台外壳中。横竖屏更换 NavigationStack 时仍能恢复同一个详情页，
/// 不把这些临时导航信息写进用户偏好或会话恢复格式。
enum SettingsDestination: Hashable {
    case connection
    case appearance
    case language
    case defaultModels
    case defaultPermissions
    case diagnostics
    case doctor
    case support
    case advanced
    case capabilities
    case about
    case privacyPolicy
    case termsOfUse
    case thirdPartyNotices
    case managedConnection
    case speedTest
    case tailcat
}

@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published var mePath: [SettingsDestination] = []
    @Published var devicePath: [SettingsDestination] = []
    @Published var profileRenamePresentation = ConnectionProfileRenamePresentationState()
    let connectionDraft = ConnectionSettingsDraft()
    let transientPreferences = SettingsTransientPreferences()
}

/// 仅保留当前工作台内的连接表单草稿；输入不触发会话外壳重绘，旋转也不会重置访问码。
@MainActor
final class ConnectionSettingsDraft: ObservableObject {
    @Published var endpoint = ""
    @Published var token = ""
    @Published var didLoadInitialConnection = false
    @Published var pendingManualConnectionIntent: ConnectionQRCodeScanIntent?
    @Published var isSavingConnection = false
    @Published var isAddingConnectionProfile = false
    @Published var profileDisplayName = ""
    @Published var profileOperationID: String?
    @Published var pendingRemovalConfirmation: ConnectionCredentialRemovalConfirmation?
    @Published var isShowingAdvancedManualConnection = false
    @Published var localError: String?
    @Published var copyingConnectionProfileID: String?
    @Published var copiedConnectionProfileID: String?
    var copyConnectionTask: Task<Void, Never>?
    var copyFeedbackTask: Task<Void, Never>?

    private var loadedProfileID: String?
    private var loadedEndpoint = ""
    private var loadedToken = ""

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
        return true
    }
}

struct SettingsDestinationView: View {
    @EnvironmentObject private var appStore: AppStore
    @ObservedObject var navigation: SettingsNavigationState
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    let destination: SettingsDestination

    @AppStorage("agentd.developerMode") private var developerModeEnabled = false
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(VoiceInputProvider.storageKey) private var voiceInputProviderRawValue = VoiceInputProvider.resolved(rawValue: nil).rawValue
    @AppStorage(ComposerPermissionMode.defaultStorageKey) private var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue

    var body: some View {
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
        case .diagnostics:
            DiagnosticsAndSupportSettingsView(showsHistoryDiagnostics: developerModeEnabled)
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

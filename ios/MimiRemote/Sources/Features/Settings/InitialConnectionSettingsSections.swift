import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum InitialConnectionErrorClassifier {
    static func isCredentialRejection(_ raw: String) -> Bool {
        let lowercased = raw.lowercased()
        if lowercased.contains("unauthorized") {
            return true
        }
        // 401 必须是独立状态码；Keychain 的 -34018 等 OSStatus 不能被子串误判为鉴权失败。
        return raw.range(
            of: #"(^|\D)401(\D|$)"#,
            options: .regularExpression
        ) != nil
    }
}

enum ConnectionQRCodeScanIntent: Equatable, Identifiable {
    case initialConnection
    case addConnectionProfile
    case repairCurrentProfile(expectedProfileID: String)

    var id: String {
        switch self {
        case .initialConnection:
            return "initialConnection"
        case .addConnectionProfile:
            return "addConnectionProfile"
        case .repairCurrentProfile(let expectedProfileID):
            return "repairCurrentProfile:\(expectedProfileID)"
        }
    }

    var addsConnectionProfile: Bool {
        self == .addConnectionProfile
    }

    func isValid(activeProfileID: String?) -> Bool {
        switch self {
        case .initialConnection:
            return activeProfileID == nil
        case .addConnectionProfile:
            return true
        case .repairCurrentProfile(let expectedProfileID):
            return activeProfileID == expectedProfileID
        }
    }
}

@MainActor
final class ConnectionQRCodeScannerPresentation: ObservableObject {
    typealias SubmissionHandler = (
        _ rawValue: String,
        _ intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult

    @Published var intent: ConnectionQRCodeScanIntent?
    @Published private(set) var isRequestingCameraAuthorization = false

    private var submissionHandler: SubmissionHandler?
    private var manualConnectionHandler: ((ConnectionQRCodeScanIntent) -> Void)?
    private var dismissalHandler: (() -> Void)?

    func configure(
        onSubmit: @escaping SubmissionHandler,
        onChooseManualConnection: @escaping (ConnectionQRCodeScanIntent) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        submissionHandler = onSubmit
        manualConnectionHandler = onChooseManualConnection
        dismissalHandler = onDismiss
    }

    func request(_ requestedIntent: ConnectionQRCodeScanIntent) {
        guard !isRequestingCameraAuthorization else {
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            intent = requestedIntent
            return
        }

        // 这里必须由 SettingsView 持有的引用对象承接回调。系统权限弹窗期间 Form
        // 可能重建 Section；若回调只写 Section 自己的 @State，结果会落到已经失效的
        // 视图实例上，首次扫码便不会继续展示 Sheet。
        isRequestingCameraAuthorization = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            // 权限回调会早于系统弹窗的 dismiss 动画结束。若同一帧设置 sheet item，
            // UIKit 会拒绝新的 presenter，但绑定已经变成非 nil，SwiftUI 之后也不会
            // 再尝试。留出一个很短的系统过渡窗口，再提交唯一一次呈现状态。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                guard let self else {
                    return
                }
                self.isRequestingCameraAuthorization = false
                if self.intent == nil {
                    self.intent = requestedIntent
                }
            }
        }
    }

    func dismiss() {
        intent = nil
    }

    func chooseManualConnection(for intent: ConnectionQRCodeScanIntent) {
        manualConnectionHandler?(intent)
    }

    func submit(
        _ rawValue: String,
        intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult {
        guard let submissionHandler else {
            return .rejected(L10n.text("ui.the_connection_was_not_completed_please_confirm_that"))
        }
        return await submissionHandler(rawValue, intent)
    }

    func didDismiss() {
        dismissalHandler?()
    }
}

// 首次连接流程按功能区拆出，主设置页只负责导航和页面编排。
struct InitialConnectionSettingsSections: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var tailcatController: TailcatExperimentController
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation

    @State private var endpoint = ""
    @State private var token = ""
    @State private var didLoadInitialConnection = false
    @State private var pendingManualConnectionIntent: ConnectionQRCodeScanIntent?
    @State private var isSavingConnection = false
    @State private var isAddingConnectionProfile = false
    @State private var profileDisplayName = ""
    @State private var profileOperationID: String?
    @State private var pendingRemovalConfirmation: ConnectionCredentialRemovalConfirmation?
    @State private var isShowingAdvancedManualConnection = false
    @State private var localError: String?
    @State private var copyingConnectionProfileID: String?
    @State private var copiedConnectionProfileID: String?
    @State private var copyConnectionTask: Task<Void, Never>?
    @State private var copyFeedbackTask: Task<Void, Never>?

    let onRequestProfileRename: (ConnectionProfile) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if !appStore.connectionProfiles.isEmpty {
                Section {
                    if let current = appStore.connectionProfileSettingsModel.current {
                        connectionProfileRow(current)
                    }
                    ForEach(appStore.connectionProfileSettingsModel.others) { item in
                        connectionProfileRow(item)
                    }
                } header: {
                    Text(L10n.text("ui.saved_mac"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("ui.only_one_mac_is_connected_at_a_time"))
                        Text(L10n.text("ui.connection_info_copy_security_notice"))
                    }
                }
            }

            // 状态和线路描述的就是上面那台当前电脑，紧跟其后才符合"控件靠近它作用的对象"。
            // 添加电脑是低频动作，让位到页尾，首屏先回答"我连着哪台机器、通不通"。
            if appStore.isConfigured {
                connectionStatusSection
                connectionMethodSection
            }

            if !appStore.isConfigured && !appStore.localAgentDetected {
                HostInstallationSetupView(
                    connectionFooter: connectionSectionFooter,
                    isScanDisabled: isSavingConnection || qrScannerPresentation.isRequestingCameraAuthorization,
                    onScan: beginScanningHost,
                    onPasteConnectionInfo: pasteConnectionInfo
                )

                connectionPresentationSection {
                    advancedConnectionOptions(tokens: tokens)
                } header: {
                    Text(L10n.text("ui.other_connection_methods"))
                } footer: {
                    EmptyView()
                }
            } else {
                connectionPresentationSection {
#if targetEnvironment(macCatalyst)
                    if appStore.localAgentDetected {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(
                                appStore.isUsingLocalConnection ? L10n.text("ui.directly_connected_through_local_assistant") : L10n.text("ui.assistant_has_been_detected_on_this_mac"),
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(themeStore.uiFont(.body, weight: .semibold))
                            .foregroundStyle(tokens.success)
                            if !appStore.isConfigured {
                                Text(localAgentPairingHint)
                                    .font(themeStore.uiFont(.footnote))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
#endif
                    // 这一节的 footer 已经写明推荐扫码，布局也要说同一句话：
                    // 只有扫码保留满宽强调按钮，粘贴与命令行、手动连接同属备选路径，
                    // 一起降级成列表行，避免两颗等重的大按钮互相抵消主次。
                    Button {
                        beginScanningHost()
                    } label: {
                        Label(primaryScanButtonTitle, systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tokens.primaryAction)
                    .controlSize(.large)
                    .disabled(isSavingConnection || qrScannerPresentation.isRequestingCameraAuthorization)
                    .accessibilityIdentifier("settings.connection.scanQRCode")

                    Button(action: pasteConnectionInfo) {
                        Label(
                            L10n.text("ui.paste_connection_info"),
                            systemImage: "doc.on.clipboard"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .tint(tokens.primaryAction)
                    .disabled(isSavingConnection || qrScannerPresentation.isRequestingCameraAuthorization)
                    .accessibilityHint(L10n.text("ui.paste_connection_info_hint"))
                    .accessibilityIdentifier("settings.connection.pasteConnectionInfo")

                    advancedConnectionOptions(tokens: tokens)
                } header: {
                    Text(appStore.isConfigured ? L10n.text("ui.add_mac") : L10n.text("ui.start_setup"))
                } footer: {
                    Text(connectionSectionFooter)
                }
            }

            // 首次配对时状态是配对流程的结果，留在扫码入口下方；一旦配对完成，
            // 它描述的就是页首那台当前电脑，已经上移到保存列表之后。
            if !appStore.isConfigured {
                connectionStatusSection
            }

#if DEBUG
            Section {
                Button {
                    appStore.enterDebugWorkbenchWithoutPairing()
                } label: {
                    Label(L10n.text("ui.debug_enter_the_workbench"), systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("settings.debugEnterWorkbench")
            }
#endif
        }
        .listRowBackground(tokens.elevatedSurface)
        // 连接地址/Token 是高频编辑状态，放在这个小子树里，避免每次删字都重绘整个设置页。
        .onAppear(perform: loadInitialConnectionIfNeeded)
        .onDisappear {
            copyConnectionTask?.cancel()
            copyFeedbackTask?.cancel()
        }
        .task {
            // 根启动任务负责自动配对和提交；这里与它复用同一个探测 Task，只更新设置页提示，
            // 避免两个连接事务争抢后导致 bootstrap 提前返回。
            _ = await appStore.detectLocalAgent()
        }
    }

    @ViewBuilder
    private var connectionStatusSection: some View {
        if shouldShowConnectionStatus {
            Section {
                HStack {
                    Label(L10n.text("ui.connection_status"), systemImage: connectionStatusSystemImage)
                    Spacer()
                    if isConnectionTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(appStore.connectionStatus.title)
                        .foregroundStyle(statusColor)
                }
                if let message = displayErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(themeStore.uiFont(size: 13))
                }

                if appStore.isConfigured {
                    NavigationLink {
                        ConnectionSpeedTestView()
                    } label: {
                        SettingsValueLabel(
                            title: L10n.text("ui.connection_speed_test"),
                            value: tailcatController.isEnabled ? "Tailcat" : "Tailscale",
                            systemImage: "gauge.with.dots.needle.67percent"
                        )
                    }
                    .settingsStandardListRow()
                    .accessibilityIdentifier("settings.connectionSpeedTest")
                }
            } header: {
                Text(L10n.text("ui.status"))
            }
        }
    }

    @ViewBuilder
    private var connectionMethodSection: some View {
        if appStore.isConfigured {
            Section {
                NavigationLink {
                    TailcatExperimentSettingsView()
                } label: {
                    SettingsValueLabel(
                        title: L10n.text("ui.tailcat_experiment"),
                        value: tailcatController.isEnabled
                            ? L10n.text("ui.tailcat_experiment_enabled")
                            : L10n.text("ui.tailcat_experiment_disabled"),
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.connection.tailcat")
            } header: {
                Text(L10n.text("ui.connection_method"))
            }
        }
    }

    /// 首次连接时只把高级恢复入口放进这一节；已有连接仍复用同一组控件。
    /// 默认折叠能保留完整能力，同时不让低频技术信息和扫码主路径竞争注意力。
    @ViewBuilder
    private func advancedConnectionOptions(tokens: ThemeTokens) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("ui.first_time_installation"))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("brew install gaixianggeng/tap/mimi-remote")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.text("ui.start_the_assistant_and_display_the_qr_code"))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("agentd up")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.text("ui.run_agentd_pair_when_the_qr_code_expires"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } label: {
            Label(
                L10n.text("ui.command_line_installation_advanced"),
                systemImage: "terminal"
            )
        }

        DisclosureGroup(isExpanded: manualConnectionExpandedBinding) {
            VStack(alignment: .leading, spacing: 12) {
                if isAddingConnectionProfile {
                    connectionFieldLabel(L10n.text("ui.display_name")) {
                        TextField(L10n.text("ui.example_studio_mac"), text: $profileDisplayName)
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("settings.profileDisplayName")
                    }
                }
                connectionFieldLabel(L10n.text("ui.connection_address")) {
                    StableEndpointTextField(placeholder: endpointPlaceholder, text: $endpoint)
                        .frame(minHeight: 28)
                }
                connectionFieldLabel(L10n.text("ui.access_code")) {
                    SecureField(L10n.text("ui.enter_access_code"), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                EndpointTransportNotice(assessment: endpointTransportAssessment)
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 8) {
                        if isSavingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSavingConnection ? L10n.text("ui.connecting") : manualSaveButtonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.primaryAction)
                .disabled(!canSubmit)
            }
            .padding(.vertical, 6)
        } label: {
            Label(manualConnectionTitle, systemImage: "keyboard")
        }
    }

    /// 业务回调和弹窗只挂到每条连接流程中的一个原生 Section，
    /// 避免系统权限弹窗期间因多个 presenter 同时存在而重复呈现。
    private func connectionPresentationSection<Content: View, Header: View, Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        Section {
            content()
        } header: {
            header()
        } footer: {
            footer()
        }
        // 真正的相机 Cover 由 SettingsView 根层呈现，避免 Form.Section 重建后丢失 presenter。
        .onAppear(perform: configureQRCodeScannerPresentation)
        .confirmationDialog(
            pendingRemovalConfirmation?.title ?? L10n.text("ui.confirm_to_delete_connection_credentials"),
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingRemovalConfirmation
        ) { confirmation in
            Button(confirmation.confirmButtonTitle, role: .destructive) {
                Task {
                    await performCredentialRemoval(confirmation)
                }
            }
            .accessibilityIdentifier(removalConfirmationAccessibilityIdentifier(confirmation))

            Button(L10n.text("ui.cancel"), role: .cancel) {
                pendingRemovalConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemovalConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemovalConfirmation = nil
                }
            }
        )
    }

    private var manualConnectionExpandedBinding: Binding<Bool> {
        Binding(
            get: { isShowingAdvancedManualConnection },
            set: { isExpanded in
                if isExpanded, !isShowingAdvancedManualConnection {
                    if appStore.activeConnectionProfile != nil {
                        prepareAddingConnectionProfile()
                    } else {
                        isAddingConnectionProfile = false
                        endpoint = ""
                        token = ""
                        localError = nil
                    }
                }
                isShowingAdvancedManualConnection = isExpanded
            }
        )
    }

    private var primaryScanButtonTitle: String {
        appStore.isConfigured ? L10n.text("ui.scan_qr_code_to_add_mac") : L10n.text("ui.scan_the_qr_code_to_connect")
    }

    private var connectionSectionFooter: String {
        if !appStore.isConfigured && !appStore.localAgentDetected {
            return L10n.text("ui.pairing_information_only_transmitted_between_your_devices")
        }
        return L10n.text("ui.it_is_recommended_to_scan_the_qr_code")
    }

    private var localAgentPairingHint: String {
        switch appStore.connectionStatus {
        case .testing:
            return L10n.text("ui.automatically_claiming_local_credentials_and_verifying_codex_connection")
        case .failed:
            return L10n.text("ui.the_automatic_connection_is_not_completed_please_upgrade")
        case .idle, .connected:
            return L10n.text("ui.the_local_assistant_will_be_automatically_connected_older")
        }
    }

    private var endpointPlaceholder: String {
#if targetEnvironment(macCatalyst)
        L10n.text("ui.native_or_tailscale_address")
#else
        L10n.text("ui.tailscale_address")
#endif
    }

    private var manualConnectionTitle: String {
        guard appStore.activeConnectionProfile != nil else {
            return L10n.text("ui.manual_connection")
        }
        if !isShowingAdvancedManualConnection || isAddingConnectionProfile {
            return L10n.text("ui.add_mac_manually")
        }
        return L10n.text("ui.manually_update_your_current_mac")
    }

    private var manualSaveButtonTitle: String {
        if isAddingConnectionProfile {
            return L10n.text("ui.add_and_connect")
        }
        return appStore.isConfigured ? L10n.text("ui.update_connection") : L10n.text("ui.connect")
    }

    private func connectionFieldLabel<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private var connectionStatusSystemImage: String {
        switch appStore.connectionStatus {
        case .connected:
            return "checkmark.circle.fill"
        case .testing:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "circle.dashed"
        }
    }

    private var shouldShowConnectionStatus: Bool {
        appStore.isConfigured ||
        isConnectionTesting ||
        displayErrorMessage != nil ||
        connectionTestDurationText != nil ||
        appStore.lastConnectionTestReport != nil
    }

    private var canSubmit: Bool {
        !isSavingConnection &&
        !isConnectionTesting &&
        endpointTransportAssessment.isAllowed &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func connectionProfileRow(_ item: ConnectionProfileSettingsItem) -> some View {
        HStack(spacing: 12) {
            // 设置页与工作台复用服务端上报的平台语义；未知平台继续显示通用电脑。
            HostPlatformGlyph(kind: item.profile.hostPlatform.iconKind)
                .foregroundStyle(item.isCurrent ? themeStore.tokens(for: colorScheme).accent : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.profile.displayName)
                    .font(themeStore.uiFont(.body, weight: item.isCurrent ? .semibold : .regular))
                // 档案名称保持首要层级；连接设置属于详情层，第二行才展示
                // MagicDNS、IP 回退和当前实际路由，便于现场诊断改名后的回退行为。
                Text(connectionProfileRouteDetail(item))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    // 地址尾部的端口比协议头更有诊断价值，超长时从中间截断。
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if item.isCurrent {
                Label(L10n.text("ui.current_label"), systemImage: "checkmark.circle.fill")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).success)
            } else if profileOperationID == item.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(L10n.text("ui.switch")) {
                    Task { await switchConnectionProfile(id: item.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSavingConnection || profileOperationID != nil)
                .accessibilityIdentifier("settings.profile.switch.\(item.id)")
            }

            Button {
                copyConnectionInfo(for: item.profile)
            } label: {
                Group {
                    if copyingConnectionProfileID == item.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: copiedConnectionProfileID == item.id ? "checkmark" : "doc.on.doc")
                            .font(themeStore.uiFont(.body, weight: .semibold))
                            .foregroundStyle(
                                copiedConnectionProfileID == item.id
                                    ? themeStore.tokens(for: colorScheme).success
                                    : themeStore.tokens(for: colorScheme).secondaryText
                            )
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(copyingConnectionProfileID != nil)
            .accessibilityLabel(
                copiedConnectionProfileID == item.id
                    ? L10n.text("ui.connection_info_copied")
                    : L10n.format("ui.copy_connection_info_for_value", item.profile.displayName)
            )
            .accessibilityHint(L10n.text("ui.connection_info_copy_security_notice"))
            .accessibilityIdentifier("settings.profile.copy.\(item.id)")

            Menu {
                Button(L10n.text("ui.rename")) {
                    localError = nil
                    onRequestProfileRename(item.profile)
                }
                .accessibilityIdentifier("settings.profile.rename.\(item.id)")

                if item.isCurrent {
                    Button(L10n.text("ui.scan_the_qr_code_again_to_pair")) {
                        beginRepairingCurrentProfile()
                    }
                    .accessibilityIdentifier("settings.connection.repairQRCode")
                    Divider()
                    Button(L10n.text("ui.forget_this_mac"), role: .destructive) {
                        pendingRemovalConfirmation = .forgettingCurrent(item.profile)
                    }
                    .accessibilityIdentifier("settings.connection.forget")
                } else {
                    Button(L10n.text("ui.delete"), role: .destructive) {
                        pendingRemovalConfirmation = .deletingSavedProfile(item.profile)
                    }
                    .accessibilityIdentifier("settings.profile.delete.\(item.id)")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(themeStore.uiFont(.body))
                    .frame(width: 30, height: 30)
            }
            .disabled(isSavingConnection || profileOperationID != nil)
            .accessibilityLabel(L10n.format("ui.manage_value", item.profile.displayName))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.profile.\(item.id)")
    }

    /// 第二行只承担"这台机器实际走哪条线路"的诊断价值。当前连接与档案首选地址一致时，
    /// 这段文字与前面的 MagicDNS/IP 完全重复，折行后还会留下一个孤立的"当前"，
    /// 与行尾的当前徽章撞车；只有真的回退到别的地址时才值得单独列出来。
    private func connectionProfileRouteDetail(_ item: ConnectionProfileSettingsItem) -> String {
        var details: [String] = []
        if let dnsName = item.profile.tailscaleDNSName {
            details.append("MagicDNS \(dnsName)")
        }
        let fallbackHost = URLComponents(string: item.profile.endpoint)?.host ?? item.profile.endpoint
        details.append("IP \(fallbackHost)")
        if item.isCurrent, isRoutedAwayFromPreferredEndpoint(item.profile) {
            details.append("\(L10n.text("ui.current_connection")) \(appStore.connectionEndpoint)")
        }
        return details.joined(separator: " · ")
    }

    private func isRoutedAwayFromPreferredEndpoint(_ profile: ConnectionProfile) -> Bool {
        AgentAPIClient.normalizedEndpoint(appStore.connectionEndpoint)
            != AgentAPIClient.normalizedEndpoint(profile.preferredEndpoint)
    }

    private var endpointTransportAssessment: EndpointTransportAssessment {
        EndpointTransportPolicy.assess(endpoint)
    }

    private var isConnectionTesting: Bool {
        if case .testing = appStore.connectionStatus {
            return true
        }
        return false
    }

    private var connectionTestDurationText: String? {
        guard let milliseconds = appStore.lastConnectionTestDurationMillis else {
            return nil
        }
        return AppStore.connectionTestDurationText(milliseconds: milliseconds)
    }

    private func connectionStageSummaryRow(title: String, stage: ConnectionTestStageTiming, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(stage.kind.title) · \(AppStore.connectionTestDurationText(milliseconds: stage.durationMillis))")
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func connectionStabilityRow(_ stability: ConnectionTestStageStability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.text("ui.recent_fluctuations"))
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(stability.kind.title)
                    .foregroundStyle(themeStore.tokens(for: colorScheme).warning)
                Text(connectionStabilityDetailText(stability))
                    .font(themeStore.uiFont(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func connectionStabilityDetailText(_ stability: ConnectionTestStageStability) -> String {
        let spread = AppStore.connectionTestDurationText(milliseconds: stability.spreadMillis)
        let max = AppStore.connectionTestDurationText(milliseconds: stability.maxMillis)
        if stability.failureCount > 0 {
            return L10n.format(
                "ui.connection_test_stability_failure_summary",
                L10n.plural("ui.connection_test_samples_count", count: stability.sampleCount),
                L10n.plural("ui.connection_test_failures_count", count: stability.failureCount),
                max
            )
        }
        return L10n.format(
            "ui.connection_test_stability_summary",
            L10n.plural("ui.connection_test_samples_count", count: stability.sampleCount),
            spread,
            max
        )
    }

    private func connectionStageRow(_ stage: ConnectionTestStageTiming) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(stage.kind.title)
                    if case .failed = stage.status {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
                Text(stage.kind.detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(stageDurationText(stage))
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(connectionStageColor(stage))
                .lineLimit(1)
        }
    }

    private func stageDurationText(_ stage: ConnectionTestStageTiming) -> String {
        let duration = AppStore.connectionTestDurationText(milliseconds: stage.durationMillis)
        switch stage.status {
        case .succeeded:
            return duration
        case .failed:
            return L10n.format("ui.failure_value", duration)
        }
    }

    private func connectionStageColor(_ stage: ConnectionTestStageTiming) -> Color {
        switch stage.status {
        case .succeeded:
            return .secondary
        case .failed:
            return .red
        }
    }

    @ViewBuilder
    private func connectionGatewayDiagnosticsRows(_ diagnostics: ConnectionTestGatewayDiagnostics) -> some View {
        connectionGatewaySummaryRow(diagnostics)

        if diagnostics.failedUpstreamDialsDelta > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.upstream_dialup_failed"),
                detail: L10n.text("ui.this_test_failed_to_add_a_new_addition"),
                value: L10n.format(
                    "ui.connection_test_upstream_dial_failures",
                    L10n.plural("ui.upstream_dial_failures_count", count: diagnostics.failedUpstreamDialsDelta),
                    AppStore.connectionTestDurationText(milliseconds: diagnostics.upstreamDialMillisMax)
                ),
                color: .red
            )
        }

        if let connection = diagnostics.relatedConnection {
            connectionGatewayMetricRow(
                title: L10n.text("ui.mac_upstream_dialing"),
                detail: L10n.text("ui.agentd_to_local_app_server"),
                value: AppStore.connectionTestDurationText(milliseconds: connection.upstreamDialMillis),
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }

        if let rpc = diagnostics.latestRPC {
            connectionGatewayMetricRow(
                title: L10n.text("ui.recent_rpcs"),
                detail: rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method,
                value: AppStore.connectionTestDurationText(milliseconds: rpc.latencyMillis),
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }

        if diagnostics.rpcOutstandingRequests > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.waiting_for_upstream"),
                detail: L10n.text("ui.app_server_still_hasn_t_returned_a_response"),
                value: L10n.format("ui.value_value", diagnostics.rpcOutstandingRequests, AppStore.connectionTestDurationText(milliseconds: diagnostics.rpcOutstandingMillisMax)),
                color: themeStore.tokens(for: colorScheme).warning
            )
        }

        if diagnostics.writeBackMillisMax > 0 {
            connectionGatewayMetricRow(
                title: L10n.text("ui.write_back_to_ipad"),
                detail: L10n.text("ui.agentd_gateway_is_written_to_the_current_device"),
                value: AppStore.connectionTestDurationText(milliseconds: diagnostics.writeBackMillisMax),
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }

        if let closeReason = diagnostics.relatedConnection?.closeReason,
           !closeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connectionGatewayMetricRow(
                title: L10n.text("ui.recently_disconnected"),
                detail: closeReason,
                value: nil,
                color: .secondary
            )
        }

        if let hint = diagnostics.hints.first {
            Text(hint)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(.secondary)
        }
    }

    private func connectionGatewaySummaryRow(_ diagnostics: ConnectionTestGatewayDiagnostics) -> some View {
        let summary = gatewayDiagnosticSummary(diagnostics)
        return HStack(alignment: .top, spacing: 12) {
            Text(L10n.text("ui.gateway_judgment"))
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(summary.title)
                    .foregroundStyle(summary.color)
                    .lineLimit(1)
                Text(summary.detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func connectionGatewayMetricRow(title: String, detail: String, value: String?, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if let value {
                Text(value)
                    .font(themeStore.uiFont(.footnote, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }

    private func connectionGatewayDiagnosticsErrorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.text("ui.gateway_diagnostics"))
            Spacer(minLength: 12)
            Text(error)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func gatewayMetricColor(milliseconds: Int) -> Color {
        if milliseconds >= 2_000 {
            return .red
        }
        if milliseconds >= 500 {
            return themeStore.tokens(for: colorScheme).warning
        }
        return .secondary
    }

    private func gatewayDiagnosticSummary(_ diagnostics: ConnectionTestGatewayDiagnostics) -> GatewayDiagnosticSummary {
        let warning = themeStore.tokens(for: colorScheme).warning
        if diagnostics.failedUpstreamDialsDelta > 0 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.upstream_dialup_failed"),
                detail: L10n.text("ui.agentd_failed_to_connect_to_local_app_server"),
                color: .red
            )
        }
        if diagnostics.rpcOutstandingRequests > 0 && diagnostics.rpcOutstandingMillisMax >= 2_000 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.upstream_did_not_return"),
                detail: L10n.text("ui.the_request_has_been_sent_to_app_server"),
                color: warning
            )
        }
        if let rpc = diagnostics.latestRPC,
           rpc.latencyMillis >= 1_000 {
            let method = rpc.method.isEmpty ? "app-server JSON-RPC" : rpc.method
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.rpc_returns_slowly"),
                detail: L10n.format("ui.value_return_time_is_high", method),
                color: gatewayMetricColor(milliseconds: rpc.latencyMillis)
            )
        }
        if diagnostics.writeBackMillisMax >= 500 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.write_back_link_slow"),
                detail: L10n.text("ui.prioritize_checking_ipads_and_tailscale_networks"),
                color: gatewayMetricColor(milliseconds: diagnostics.writeBackMillisMax)
            )
        }
        if let connection = diagnostics.relatedConnection,
           connection.upstreamDialMillis >= 500 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.local_dialing_is_slow"),
                detail: L10n.text("ui.agentd_is_slow_to_establish_a_connection_to"),
                color: gatewayMetricColor(milliseconds: connection.upstreamDialMillis)
            )
        }
        if diagnostics.totalConnectionsDelta > 0 {
            return GatewayDiagnosticSummary(
                title: L10n.text("ui.there_is_a_new_connection_this_time"),
                detail: L10n.text("ui.no_obvious_gateway_bottleneck_found"),
                color: .secondary
            )
        }
        return GatewayDiagnosticSummary(
            title: L10n.text("ui.no_new_samples"),
            detail: L10n.text("ui.continue_to_reproduce_the_slow_scene_and_look"),
            color: .secondary
        )
    }

    private var statusColor: Color {
        switch appStore.connectionStatus {
        case .connected:
            return themeStore.tokens(for: colorScheme).success
        case .failed:
            return .red
        case .testing:
            return themeStore.tokens(for: colorScheme).warning
        case .idle:
            return .secondary
        }
    }

    private var displayErrorMessage: String? {
        guard let raw = appStore.lastError ?? localError else {
            return nil
        }
        return friendlyConnectionMessage(raw)
    }

    private func friendlyConnectionMessage(_ raw: String) -> String {
        if let termination = appStore.connectionTermination {
            return termination.message
        }
        let lowercased = raw.lowercased()
        if lowercased.contains("expired") || raw.contains("过期") {
            return L10n.text("ui.the_pairing_qr_code_has_expired_please_re")
        }
        if InitialConnectionErrorClassifier.isCredentialRejection(raw) {
            return L10n.text("ui.this_device_has_not_been_verified_by_mac")
        }
        if lowercased.contains("timed out") || lowercased.contains("cannot connect") || raw.contains("无法连接") {
            if appStore.isTailcatExperimentModeEnabled {
                return L10n.text("ui.please_check_mac_assistant_and_network_connections")
            }
            return L10n.text("ui.the_current_device_cannot_find_this_mac_at")
        }
        if raw == L10n.text("ui.the_connection_credentials_have_been_saved_safely_but") ||
            raw.contains("连接凭据已安全保存") {
            // Old builds persisted this message in Chinese. Always return the current locale's
            // copy so an English screen never echoes that legacy raw value.
            return L10n.text("ui.the_connection_credentials_have_been_saved_safely_but")
        }
        let localizedConnectionLinkKeys = [
            "ui.clipboard_does_not_contain_connection_info",
            "ui.invalid_connection_link",
            "ui.the_connection_link_is_missing_the_access_code",
            "ui.the_link_is_missing_an_address",
            "ui.the_connection_address_format_is_invalid",
            "ui.the_connection_address_is_invalid_please_enter_the"
        ]
        if localizedConnectionLinkKeys.contains(where: { raw == L10n.text($0) }) || raw.contains("Endpoint") {
            return raw
        }
        if raw.contains("连接链接缺少访问码") {
            return L10n.text("ui.the_connection_link_is_missing_the_access_code")
        }
        if raw.contains("连接链接缺少地址") {
            return L10n.text("ui.the_link_is_missing_an_address")
        }
        if raw.contains("连接地址格式无效") {
            return L10n.text("ui.the_connection_address_format_is_invalid")
        }
        if raw.contains("连接地址") || raw.contains("连接链接") {
            return L10n.text("ui.invalid_connection_link")
        }
        return L10n.text("ui.the_connection_was_not_completed_please_confirm_that")
    }

    private func loadInitialConnectionIfNeeded() {
        guard !didLoadInitialConnection else {
            return
        }
        didLoadInitialConnection = true
        endpoint = appStore.endpoint
        token = appStore.token
    }

    private func prepareAddingConnectionProfile() {
        isAddingConnectionProfile = true
        profileDisplayName = ""
        endpoint = ""
        token = ""
        localError = nil
    }

    private func beginScanningHost() {
        let intent: ConnectionQRCodeScanIntent = appStore.activeConnectionProfile == nil
            ? .initialConnection
            : .addConnectionProfile
        pendingManualConnectionIntent = nil
        qrScannerPresentation.request(intent)
    }

    private func pasteConnectionInfo() {
        guard let rawValue = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            localError = L10n.text("ui.clipboard_does_not_contain_connection_info")
            return
        }
        let intent: ConnectionQRCodeScanIntent = appStore.activeConnectionProfile == nil
            ? .initialConnection
            : .addConnectionProfile
        Task {
            _ = await applyScannedConnection(rawValue, intent: intent)
        }
    }

    private func copyConnectionInfo(for profile: ConnectionProfile) {
        copyConnectionTask?.cancel()
        copyingConnectionProfileID = profile.id
        copyConnectionTask = Task {
            defer {
                if copyingConnectionProfileID == profile.id {
                    copyingConnectionProfileID = nil
                }
            }
            do {
                let link = try await appStore.connectionTransferLink(profileID: profile.id)
                try Task.checkCancellation()
                // 不设置 localOnly，才能通过系统通用剪贴板交给用户自己的另一台设备。
                // 同时设置系统过期时间，减少长期访问码在剪贴板中停留的窗口。
                UIPasteboard.general.setItems(
                    [[UTType.plainText.identifier: link.url.absoluteString]],
                    options: [.expirationDate: link.expiresAt]
                )
                localError = nil
                copiedConnectionProfileID = profile.id
                copyFeedbackTask?.cancel()
                copyFeedbackTask = Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    guard !Task.isCancelled, copiedConnectionProfileID == profile.id else {
                        return
                    }
                    copiedConnectionProfileID = nil
                }
            } catch is CancellationError {
                return
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func configureQRCodeScannerPresentation() {
        qrScannerPresentation.configure(
            onSubmit: { rawValue, intent in
                await applyScannedConnection(rawValue, intent: intent)
            },
            onChooseManualConnection: { intent in
                pendingManualConnectionIntent = intent
            },
            onDismiss: finishQRCodeScannerPresentation
        )
    }

    private func beginRepairingCurrentProfile() {
        guard let activeProfileID = appStore.activeConnectionProfileID else {
            localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
            return
        }
        pendingManualConnectionIntent = nil
        qrScannerPresentation.request(
            .repairCurrentProfile(expectedProfileID: activeProfileID)
        )
    }

    private func finishQRCodeScannerPresentation() {
        defer {
            pendingManualConnectionIntent = nil
        }
        guard let intent = pendingManualConnectionIntent else {
            isShowingAdvancedManualConnection = false
            return
        }
        guard intent.isValid(activeProfileID: appStore.activeConnectionProfileID) else {
            localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
            isShowingAdvancedManualConnection = false
            return
        }

        switch intent {
        case .initialConnection:
            isAddingConnectionProfile = false
            profileDisplayName = ""
            endpoint = ""
            token = ""
            localError = nil
        case .addConnectionProfile:
            prepareAddingConnectionProfile()
        case .repairCurrentProfile:
            isAddingConnectionProfile = false
            profileDisplayName = appStore.activeConnectionProfile?.displayName ?? ""
            endpoint = appStore.endpoint
            token = ""
            localError = nil
        }
        isShowingAdvancedManualConnection = true
    }

    private func switchConnectionProfile(id: String) async {
        profileOperationID = id
        defer { profileOperationID = nil }
        do {
            _ = try await sessionStore.switchConnectionProfile(id: id)
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            guard await refreshCommittedConnection(maxWait: 10) else {
                return
            }
        } catch is CancellationError {
            // App 退后台或任务被系统取消时不把仍可用的旧连接标成失败。
            localError = nil
        } catch {
            // prepare/commit 失败时 SessionStore 尚未退役旧连接，这里只展示错误。
            localError = error.localizedDescription
        }
    }

    private func deleteConnectionProfile(id: String) async {
        do {
            try await sessionStore.deleteConnectionProfile(id: id)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func performCredentialRemoval(_ confirmation: ConnectionCredentialRemovalConfirmation) async {
        pendingRemovalConfirmation = nil
        switch confirmation.target {
        case .current(let expectedProfileID):
            guard expectedProfileID == appStore.activeConnectionProfileID else {
                // 弹窗展示期间连接可能被 URL Scheme 或其它入口切换；不能误删后来成为当前的档案。
                localError = L10n.text("ui.the_current_mac_has_changed_please_try_again")
                return
            }
            await clearPairing()
        case .savedProfile(let profileID):
            await deleteConnectionProfile(id: profileID)
        }
    }

    private func removalConfirmationAccessibilityIdentifier(
        _ confirmation: ConnectionCredentialRemovalConfirmation
    ) -> String {
        switch confirmation.target {
        case .current:
            return "settings.connection.forget.confirm"
        case .savedProfile(let profileID):
            return "settings.profile.delete.confirm.\(profileID)"
        }
    }

    private func save() async {
        isSavingConnection = true
        defer { isSavingConnection = false }
        do {
            let wasConfigured = appStore.isConfigured
            if isAddingConnectionProfile {
                _ = try await sessionStore.addConnectionProfile(
                    endpoint: endpoint,
                    token: token,
                    displayName: profileDisplayName
                )
            } else {
                _ = try await sessionStore.applyConnectionSettings(
                    endpoint: endpoint,
                    token: token
                )
            }
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            guard await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45) else {
                return
            }
        } catch is CancellationError {
            localError = nil
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
        }
    }

    private func applyScannedConnection(
        _ rawValue: String,
        intent: ConnectionQRCodeScanIntent
    ) async -> QRCodeScannerSubmissionResult {
        isSavingConnection = true
        guard intent.isValid(activeProfileID: appStore.activeConnectionProfileID) else {
            isSavingConnection = false
            let message = L10n.text("ui.the_current_mac_has_changed_please_try_again")
            localError = message
            return .rejected(message)
        }
        do {
            let wasConfigured = appStore.isConfigured
            let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else {
                throw PairingLinkError.unsupportedURL
            }
            let wasAddingConnectionProfile = intent.addsConnectionProfile
            if wasAddingConnectionProfile {
                _ = try await sessionStore.addConnectionProfile(
                    pairingURL: url,
                    displayName: ""
                )
            } else {
                _ = try await sessionStore.applyPairingURL(url)
            }
            endpoint = appStore.endpoint
            token = appStore.token
            isAddingConnectionProfile = false
            // 二维码在这里已经完成真实连接验证并提交。首屏数据继续后台加载，
            // 不让扫码页额外卡住最多 45 秒，也不要求用户重复扫描配对码。
            Task { @MainActor in
                defer { isSavingConnection = false }
                _ = await refreshCommittedConnection(maxWait: wasConfigured ? 10 : 45)
            }
            return .accepted(
                wasAddingConnectionProfile
                    ? L10n.text("ui.added_and_switched_to_this_mac")
                    : L10n.text("ui.this_mac_is_connected")
            )
        } catch is CancellationError {
            isSavingConnection = false
            localError = nil
            return .rejected(L10n.text("ui.the_code_scan_has_been_cancelled_please_scan"))
        } catch {
            isSavingConnection = false
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            localError = error.localizedDescription
            return .rejected(error.localizedDescription)
        }
    }

    private func refreshCommittedConnection(maxWait: TimeInterval) async -> Bool {
        let didLoad = await sessionStore.refreshAfterConnectionCommit(maxWait: maxWait)
        if didLoad {
            localError = nil
        } else if Task.isCancelled {
            localError = nil
        } else {
            localError = appStore.lastError ?? sessionStore.errorMessage
        }
        return didLoad
    }

    private func clearPairing() async {
        do {
            try await sessionStore.clearCurrentConnectionProfile()
            endpoint = appStore.endpoint
            token = appStore.token
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
}

struct ConnectionDiagnosticsNetworkPathRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let networkPath: TailscaleNetworkPathResponse

    var body: some View {
        // iOS 26/27 的 Form 会把带自定义内容的 LabeledContent 拉伸到剩余整屏高度。
        // 改用固有高度布局，让网络路径与后续诊断行始终连续排列。
        Group {
            // 常规字号下保留短 DERP 摘要的紧凑单行；其余路径必须完整测量后再决定是否换行。
            if networkPath.kind == .derp, !dynamicTypeSize.isAccessibilitySize {
                compactDERPContent
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalContent
                    verticalContent
                }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.connection.diagnostics.networkPath")
    }

    private var compactDERPContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.text("ui.tailscale_network_path"))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 12)

            networkPathLabel
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.text("ui.tailscale_network_path"))
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 12)

            networkPathLabel
                .font(.subheadline)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("ui.tailscale_network_path"))

            networkPathLabel
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var networkPathLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: networkPath.kind.settingsSystemImage)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(networkPath.localizedSummary)
        }
    }
}

import SwiftUI

/// 设备首页与添加电脑页共用这一份页面外壳，避免标题、内容宽度和滚动留白各自演进。
struct ConnectionSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @Environment(\.workbenchBottomChromeClearance) private var bottomChromeClearance
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar
    @Environment(\.settingsSheetDismiss) private var settingsSheetDismiss
    @Environment(\.enterWorkbenchFromInitialSetup) private var enterWorkbenchFromInitialSetup
    @EnvironmentObject private var lockScreenApprovalStore: LockScreenApprovalStore
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage(WorkspaceSessionRuntimeChoice.preferenceKey)
    private var preferredRuntimeRawValue = WorkspaceSessionRuntimeChoice.codex.rawValue
    @AppStorage(WorkspaceSessionRuntimeChoice.enabledRuntimesPreferenceKey)
    private var enabledRuntimesRawValue = WorkspaceSessionRuntimeChoice.defaultEnabledRuntimesRawValue
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    // 重命名 sheet 与扫码 Cover 同样必须由当前显示的连接页持有：紧凑布局把这一页
    // push 进导航栈后，设置根层已经不在被呈现的层级里，挂在那里的 presenter 不会呈现。
    // 这里是整页而不是 Form.Section，Section 刷新不会销毁它（MIM-63）。
    @StateObject private var navigation: SettingsNavigationState
    // 扫码回落到手动连接时推出添加电脑页；用 isPresented 形式不依赖所在的是哪条导航栈。
    @State private var isPresentingAddComputerForManualConnection = false
    var isDevicesTab = false
    /// 快照测试传 false：线路行保持「未检测」，也不在进入页面时重新探测连接状态，
    /// 不让网络耗时、时间戳和探测结果进基线。
    var probesRouteAutomatically = true

    init(
        qrScannerPresentation: ConnectionQRCodeScannerPresentation,
        navigation: SettingsNavigationState? = nil,
        isDevicesTab: Bool = false,
        probesRouteAutomatically: Bool = true
    ) {
        self.qrScannerPresentation = qrScannerPresentation
        _navigation = StateObject(wrappedValue: navigation ?? SettingsNavigationState())
        self.isDevicesTab = isDevicesTab
        self.probesRouteAutomatically = probesRouteAutomatically
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            InitialConnectionSettingsSections(
                qrScannerPresentation: qrScannerPresentation,
                draft: navigation.connectionDraft,
                transientPreferences: navigation.transientPreferences,
                mode: .deviceHome,
                onRequestProfileRename: { navigation.profileRenamePresentation.present($0) },
                onRequestManualConnection: {
                    navigation.connectionDraft.beginAddingComputer()
                    isPresentingAddComputerForManualConnection = true
                },
                onPairingCompleted: { opensManagedConnection in
                    if !opensManagedConnection, let settingsSheetDismiss {
                        settingsSheetDismiss()
                    }
                },
                probesRouteAutomatically: probesRouteAutomatically
            )

            if isDevicesTab || showsAddComputerEntry {
                Section {
                    if showsAddComputerEntry {
                        NavigationLink(value: SettingsDestination.lockScreenApproval) {
                            ConnectionRowLabel(
                                title: L10n.text("ui.push_lock_screen_approval"),
                                value: lockScreenApprovalStore.notificationStatusDescription,
                                systemImage: "bell"
                            )
                        }
                        .settingsStandardListRow()
                        .accessibilityIdentifier("settings.lockScreenApproval")
                    }

                    // 模型启用开关、优先使用与各通道默认模型/推理强度已统一收进二级页面，
                    // 首页仅保留单行入口并外显当前优先使用的模型摘要。
                    NavigationLink(value: SettingsDestination.defaultModels) {
                        ConnectionRowLabel(
                            title: L10n.text("ui.default_model"),
                            value: preferredRuntimeSummary,
                            systemImage: "cpu"
                        )
                    }
                    .settingsStandardListRow()
                    .accessibilityIdentifier("settings.defaultModels")
                } header: {
                    SettingsGroupHeader(title: L10n.text("ui.device_preferences"))
                }
                .settingsGroupRowStyle()
            }
        }
        .navigationDestination(isPresented: $isPresentingAddComputerForManualConnection) {
            AddComputerView(qrScannerPresentation: qrScannerPresentation, navigation: navigation)
        }
        .themedSettingsForm(tokens: tokens)
        // 普通操作和展开箭头保持中性；扫码按钮单独使用主操作色。
        .tint(tokens.secondaryText)
        .frame(maxWidth: isDevicesTab ? 920 : 720)
        .frame(maxWidth: .infinity)
        .settingsCanvasBackground(tokens: tokens)
        .contentMargins(
            .bottom,
            hasCompactTabBar ? bottomChromeClearance : WorkbenchPageLayout.regularPadding,
            for: .scrollContent
        )
        .navigationTitle(L10n.text(navigationTitleKey))
        .accessibilityIdentifier("settings.devices.page")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(
            ConnectionSettingsExitToolbarModifier(
                draft: navigation.connectionDraft,
                isDevicesTab: isDevicesTab,
                settingsSheetDismiss: settingsSheetDismiss,
                enterWorkbenchFromInitialSetup: enterWorkbenchFromInitialSetup
            )
        )
        // 扫码 Cover 必须挂在当前真正显示的连接页上。挂在 SettingsView 根层时，
        // 紧凑布局把连接页 push 进导航栈后，根层已不在被呈现的层级里，点击扫码不会有任何反应。
        // 这一层是整页而不是 Form.Section，权限弹窗引起的 Section 重建不会销毁它。
        // 扫码失败页点了「开通托管连接」后从这里推出开通页，不依赖所在的是哪条导航栈。
        .navigationDestination(isPresented: qrScannerPresentation.managedConnectionBinding(for: .connectionSettings)) {
            ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
        }
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .connectionSettings),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
                onOpenManagedConnection: { qrScannerPresentation.openManagedConnection() },
                onCode: { rawValue in
                    await qrScannerPresentation.submit(rawValue, intent: intent)
                }
            )
        }
        .sheet(
            item: profileRenameRouteBinding,
            onDismiss: { navigation.profileRenamePresentation.dismiss() }
        ) { route in
            ConnectionProfileRenameSheet(route: route) { displayName in
                try appStore.renameConnectionProfile(id: route.profileID, displayName: displayName)
            }
        }
        // 「发送下载链接」的分享面板同理挂在整页上。挂在 Form.Section 上时，启动后第一次
        // 点击会弹出又立刻收回（#424 真机验收）。只有这一页真的显示安装说明时才挂：
        // 添加电脑页 push 上来后两处同时绑同一个请求，会重新出现重复呈现。
        .modifier(
            HostInstallerSharePresenter(
                preferences: navigation.transientPreferences,
                isEnabled: !showsAddComputerEntry
            )
        )
    }

    /// 已经存过电脑时添加才是次要操作，收到导航栏；一台都没有时首页直接就是添加流程。
    private var showsAddComputerEntry: Bool {
        let model = appStore.connectionProfileSettingsModel
        return model.current != nil || !model.others.isEmpty
    }

    /// 无条件在首次连接导航栏暴露「稍后连接」的功能门控。
    /// UI-7 无主机真实空态已就绪，允许未配对用户在首次连接页随时选择「稍后连接」进入工作台。
    static let allowsUnconditionalInitialSetupConnectLater = true

    /// 首次连接根页提供「稍后连接」回到工作台的出口；
    /// 当调用方显式关闭 `allowsUnconditionalConnectLater` 时仅在已开通 Mimi 中转或配对失败后暴露。
    static func showsInitialSetupWorkbenchExit(
        isDevicesTab: Bool,
        hasSheetDismiss: Bool,
        hasActiveMimiEntitlement: Bool,
        hasPairingError: Bool,
        hasEnterWorkbenchAction: Bool = true,
        allowsUnconditionalConnectLater: Bool = allowsUnconditionalInitialSetupConnectLater
    ) -> Bool {
        guard !isDevicesTab, !hasSheetDismiss, hasEnterWorkbenchAction else {
            return false
        }
        if allowsUnconditionalConnectLater {
            return true
        }
        return hasActiveMimiEntitlement || hasPairingError
    }

    /// 一台电脑都没有时这一页是首次连接引导，Windows 用户也会看到，标题不写「Mac」（#554）。
    private var navigationTitleKey: String {
        if isDevicesTab {
            return "ui.devices"
        }
        return showsAddComputerEntry ? "ui.mac_connection" : "ui.connect_computer"
    }

    private var preferredRuntimeSummary: String {
        WorkspaceSessionRuntimeChoice.resolvedPreferred(
            preferredRawValue: preferredRuntimeRawValue,
            enabledRawValue: enabledRuntimesRawValue
        ).choiceTitle
    }

    private var profileRenameRouteBinding: Binding<ConnectionProfileRenameRoute?> {
        Binding(
            get: { navigation.profileRenamePresentation.route },
            set: { route in
                // item-driven sheet 关闭时由 SwiftUI 写回 nil；新目标只允许经 present(_:) 进入。
                if route == nil {
                    navigation.profileRenamePresentation.dismiss()
                }
            }
        )
    }
}

/// 单独观察 `ConnectionSettingsDraft`，确保首次配对失败写入 `addComputerError` 时
/// 导航栏右上角的「稍后连接」按钮能即时出现，且始终绑定 `@StateObject navigation` 的同一份草稿。
private struct ConnectionSettingsExitToolbarModifier: ViewModifier {
    @EnvironmentObject private var managedConnectionEntitlementStore: ManagedConnectionEntitlementStore
    @ObservedObject var draft: ConnectionSettingsDraft
    let isDevicesTab: Bool
    let settingsSheetDismiss: (() -> Void)?
    let enterWorkbenchFromInitialSetup: (() -> Void)?

    func body(content: Content) -> some View {
        content.toolbar {
            if !isDevicesTab, let settingsSheetDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.complete")) {
                        settingsSheetDismiss()
                    }
                    .accessibilityLabel(L10n.text("ui.close_settings"))
                    .accessibilityIdentifier("settings.connection.close")
                }
            } else if let enterWorkbenchFromInitialSetup,
                      ConnectionSettingsView.showsInitialSetupWorkbenchExit(
                          isDevicesTab: isDevicesTab,
                          hasSheetDismiss: settingsSheetDismiss != nil,
                          hasActiveMimiEntitlement: managedConnectionEntitlementStore.hasActiveEntitlement,
                          hasPairingError: draft.addComputerError != nil,
                          hasEnterWorkbenchAction: true
                      ) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        enterWorkbenchFromInitialSetup()
                    } label: {
                        Text(L10n.text("ui.connect_later"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("settings.firstConnection.enterWorkbench")
                }
            }
        }
    }
}

/// 添加电脑独立成一页：设备首页只留一个入口，安装说明、命令行方式和手动地址
/// 不再常驻日常管理页。已经连接成功的用户不用每次管理设备都重看一遍安装教程。
struct AddComputerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsSheetDismiss) private var settingsSheetDismiss
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var qrScannerPresentation: ConnectionQRCodeScannerPresentation
    @ObservedObject var navigation: SettingsNavigationState

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            InitialConnectionSettingsSections(
                qrScannerPresentation: qrScannerPresentation,
                draft: navigation.connectionDraft,
                transientPreferences: navigation.transientPreferences,
                mode: .addComputer,
                onRequestProfileRename: { navigation.profileRenamePresentation.present($0) },
                onPairingCompleted: { opensManagedConnection in
                    if let settingsSheetDismiss {
                        if !opensManagedConnection {
                            settingsSheetDismiss()
                        }
                    } else {
                        dismiss()
                    }
                }
            )
        }
        .themedSettingsForm(tokens: tokens)
        // 普通操作和展开箭头保持中性；扫码按钮单独使用主操作色。
        .tint(tokens.secondaryText)
        .settingsDetailPage(tokens: tokens)
        .navigationTitle(L10n.text("ui.add_mac"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let settingsSheetDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.complete")) {
                        settingsSheetDismiss()
                    }
                    .accessibilityLabel(L10n.text("ui.close_settings"))
                    .accessibilityIdentifier("settings.addComputer.close")
                }
            }
        }
        .accessibilityIdentifier("settings.addComputer.page")
        // 扫码 Cover 必须由当前真正显示的页面持有。这一页 push 在设备页之上，
        // 设备页已经不在被呈现的层级里，仍挂在那里的 presenter 不会呈现。
        // 扫码失败页点了「开通托管连接」后从这里推出开通页，不依赖所在的是哪条导航栈。
        .navigationDestination(isPresented: qrScannerPresentation.managedConnectionBinding(for: .addComputer)) {
            ManagedConnectionSubscriptionView(qrScannerPresentation: qrScannerPresentation)
        }
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .addComputer),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
                onOpenManagedConnection: { qrScannerPresentation.openManagedConnection() },
                onCode: { rawValue in
                    await qrScannerPresentation.submit(rawValue, intent: intent)
                }
            )
        }
        // 安装说明只在这一页，分享面板同理只由这一页呈现（#424 真机验收）。
        .modifier(HostInstallerSharePresenter(preferences: navigation.transientPreferences))
    }
}

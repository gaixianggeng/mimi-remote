import SwiftUI

/// 设备首页与添加电脑页共用这一份页面外壳，避免标题、内容宽度和滚动留白各自演进。
struct ConnectionSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appStore: AppStore
    @Environment(\.workbenchBottomChromeClearance) private var bottomChromeClearance
    @Environment(\.workbenchHasCompactTabBar) private var hasCompactTabBar
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage(WorkspaceSessionRuntimeChoice.preferenceKey)
    private var preferredRuntimeRawValue = WorkspaceSessionRuntimeChoice.codex.rawValue
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
                onRequestManualConnection: { isPresentingAddComputerForManualConnection = true },
                probesRouteAutomatically: probesRouteAutomatically
            )

            if isDevicesTab || showsAddComputerEntry {
                Section {
                    // 只有两个运行时，值不值得为它弹一层菜单：不值得。两个名字并排摆出来，
                    // 当前用哪个一眼可见，点一下即生效——和语言、外观那几行是同一套写法。
                    SettingsChoiceRow(
                        title: L10n.text("ui.preferred_runtime"),
                        systemImage: "sparkles",
                        options: WorkspaceSessionRuntimeChoice.allCases,
                        selection: preferredRuntimeBinding
                    )
                    .settingsRow()
                    .accessibilityIdentifier("settings.preferredRuntime")
                } footer: {
                    Text(L10n.text("ui.preferred_runtime_description"))
                        .settingsSectionFooterStyle()
                }
                .listRowBackground(tokens.settingsGroupBackground)
            }
        }
        .navigationDestination(isPresented: $isPresentingAddComputerForManualConnection) {
            AddComputerView(qrScannerPresentation: qrScannerPresentation, navigation: navigation)
        }
        .themedSettingsForm(tokens: tokens)
        // 普通操作和展开箭头保持中性；扫码按钮单独使用主操作色。
        .tint(tokens.secondaryText)
        .listSectionSpacing(SettingsLayoutMetrics.sectionSpacing)
        .frame(maxWidth: isDevicesTab ? 920 : 720)
        .frame(maxWidth: .infinity)
        .settingsCanvasBackground(tokens: tokens)
        .contentMargins(
            .bottom,
            hasCompactTabBar ? bottomChromeClearance : WorkbenchPageLayout.regularPadding,
            for: .scrollContent
        )
        .navigationTitle(L10n.text(isDevicesTab ? "ui.devices" : "ui.mac_connection"))
        .accessibilityIdentifier("settings.devices.page")
        .navigationBarTitleDisplayMode(.inline)
        // 扫码 Cover 必须挂在当前真正显示的连接页上。挂在 SettingsView 根层时，
        // 紧凑布局把连接页 push 进导航栈后，根层已不在被呈现的层级里，点击扫码不会有任何反应。
        // 这一层是整页而不是 Form.Section，权限弹窗引起的 Section 重建不会销毁它。
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .connectionSettings),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
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

    private var preferredRuntimeBinding: Binding<WorkspaceSessionRuntimeChoice> {
        Binding(
            get: { .stored(preferredRuntimeRawValue) },
            set: { preferredRuntimeRawValue = $0.rawValue }
        )
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

/// 添加电脑独立成一页：设备首页只留一个入口，安装说明、命令行方式和手动地址
/// 不再常驻日常管理页。已经连接成功的用户不用每次管理设备都重看一遍安装教程。
struct AddComputerView: View {
    @Environment(\.colorScheme) private var colorScheme
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
                onRequestProfileRename: { navigation.profileRenamePresentation.present($0) }
            )
        }
        .themedSettingsForm(tokens: tokens)
        // 普通操作和展开箭头保持中性；扫码按钮单独使用主操作色。
        .tint(tokens.secondaryText)
        .settingsDetailPage()
        .navigationTitle(L10n.text("ui.add_mac"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.addComputer.page")
        // 扫码 Cover 必须由当前真正显示的页面持有。这一页 push 在设备页之上，
        // 设备页已经不在被呈现的层级里，仍挂在那里的 presenter 不会呈现。
        .fullScreenCover(
            item: qrScannerPresentation.presentationBinding(for: .addComputer),
            onDismiss: qrScannerPresentation.didDismiss
        ) { intent in
            QRCodeScannerSheet(
                onDismiss: qrScannerPresentation.dismiss,
                onChooseManualConnection: {
                    qrScannerPresentation.chooseManualConnection(for: intent)
                },
                onCode: { rawValue in
                    await qrScannerPresentation.submit(rawValue, intent: intent)
                }
            )
        }
        // 安装说明只在这一页，分享面板同理只由这一页呈现（#424 真机验收）。
        .modifier(HostInstallerSharePresenter(preferences: navigation.transientPreferences))
    }
}

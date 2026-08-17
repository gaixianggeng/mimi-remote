import SwiftUI
import UIKit

struct ConnectionProfileRenameRoute: Identifiable, Equatable {
    let profileID: String
    let initialDisplayName: String

    var id: String { profileID }

    init(profile: ConnectionProfile) {
        profileID = profile.id
        initialDisplayName = profile.displayName
    }
}

struct ConnectionProfileRenamePresentationState: Equatable {
    private(set) var route: ConnectionProfileRenameRoute?

    mutating func present(_ profile: ConnectionProfile) {
        // 一个根级 item 只对应一个 presenter；Sheet 未关闭前不替换编辑目标。
        guard route == nil else { return }
        route = ConnectionProfileRenameRoute(profile: profile)
    }

    mutating func dismiss() {
        route = nil
    }
}

enum ConnectionProfileRenameAction {
    case cancel
    case save
}

@MainActor
struct ConnectionProfileRenameDraft: Equatable {
    private(set) var displayName: String
    private(set) var submitError: String?

    init(displayName: String) {
        self.displayName = displayName
    }

    var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationMessage: String? {
        if normalizedDisplayName.isEmpty {
            return ConnectionProfileError.invalidDisplayName.localizedDescription
        }
        if normalizedDisplayName.count > AppStore.connectionProfileDisplayNameLimit {
            return ConnectionProfileError.displayNameTooLong(
                maximum: AppStore.connectionProfileDisplayNameLimit
            ).localizedDescription
        }
        return nil
    }

    var canSubmit: Bool {
        validationMessage == nil
    }

    mutating func updateDisplayName(_ nextValue: String) {
        displayName = nextValue
        submitError = nil
    }

    /// 返回值只表示 Sheet 是否应关闭；取消不会触发保存，保存失败则保留草稿和错误。
    mutating func perform(
        _ action: ConnectionProfileRenameAction,
        onRename: (String) throws -> Void
    ) -> Bool {
        switch action {
        case .cancel:
            return true
        case .save:
            guard canSubmit else { return false }
            do {
                try onRename(displayName)
                return true
            } catch {
                submitError = error.localizedDescription
                return false
            }
        }
    }
}

// 设置详情组件只持有局部值草稿、Binding 与回调，不引入额外引用状态层。
struct ConnectionProfileRenameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let route: ConnectionProfileRenameRoute
    let onRename: (String) throws -> Void
    @State private var draft: ConnectionProfileRenameDraft

    init(route: ConnectionProfileRenameRoute, onRename: @escaping (String) throws -> Void) {
        self.route = route
        self.onRename = onRename
        _draft = State(initialValue: ConnectionProfileRenameDraft(displayName: route.initialDisplayName))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ConnectionProfileNameTextField(
                        placeholder: L10n.text("ui.mac_name"),
                        text: Binding(
                            get: { draft.displayName },
                            set: { draft.updateDisplayName($0) }
                        ),
                        onSubmit: { perform(.save) }
                    )
                        .frame(minHeight: 28)
                        .accessibilityIdentifier("settings.profile.rename.name")
                } footer: {
                    Text(draft.validationMessage ?? L10n.format("ui.up_to_value_characters_only_the_local_display", AppStore.connectionProfileDisplayNameLimit))
                        .foregroundStyle(draft.validationMessage == nil ? Color.secondary : Color.red)
                }

                if let submitError = draft.submitError {
                    Section {
                        Text(submitError)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings.profile.rename.error")
                    }
                }
            }
            .navigationTitle(L10n.text("ui.rename_mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { perform(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.save")) { perform(.save) }
                        .disabled(!draft.canSubmit)
                        .accessibilityIdentifier("settings.profile.rename.save")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func perform(_ action: ConnectionProfileRenameAction) {
        if draft.perform(action, onRename: onRename) {
            dismiss()
        }
    }
}

/// 只服务 Mac 名称重命名：editingChanged 会包含输入法仍在组合中的可见文本。
/// Coordinator 先写回 SwiftUI 草稿，并阻止 updateUIView 反写 marked text，避免打断候选输入。
struct ConnectionProfileNameTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.text = text
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.autocapitalizationType = .words
        textField.returnKeyType = .done
        textField.clearButtonMode = .whileEditing
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        context.coordinator.lastSyncedText = text
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        textField.placeholder = placeholder

        // 拼音等输入法的预编辑文本已经可见，但系统尚未提交；此时反写会破坏 marked range。
        guard textField.markedTextRange == nil,
              context.coordinator.lastSyncedText != text
        else {
            return
        }
        textField.text = text
        context.coordinator.lastSyncedText = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ConnectionProfileNameTextField
        var lastSyncedText = ""

        init(_ parent: ConnectionProfileNameTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let visibleText = textField.text ?? ""
            guard visibleText != lastSyncedText else { return }
            lastSyncedText = visibleText
            parent.text = visibleText
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            textField.resignFirstResponder()
            return true
        }
    }
}

struct EndpointTransportNotice: View {
    let assessment: EndpointTransportAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(assessment.title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(assessment.guidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.endpointTransportNotice")
    }

    private var systemImage: String {
        switch assessment.status {
        case .empty:
            return "network"
        case .invalid, .blockedPublicHTTP:
            return "exclamationmark.shield.fill"
        case .allowedPrivateHTTP:
            return "lock.shield"
        case .allowedHTTPS:
            return "lock.fill"
        }
    }

    private var tint: Color {
        switch assessment.status {
        case .empty:
            return .secondary
        case .invalid, .blockedPublicHTTP:
            return .red
        case .allowedPrivateHTTP:
            return .orange
        case .allowedHTTPS:
            return .green
        }
    }
}

struct CapabilitiesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                if let path = sessionStore.capabilityList?.path, !path.isEmpty {
                    CapabilityValueRow(title: L10n.text("ui.workspace"), value: path)
                } else {
                    CapabilityValueRow(title: L10n.text("ui.workspace"), value: sessionStore.selectedCommandActionPath ?? L10n.text("ui.user_level_configuration_only"))
                }
                Button {
                    Task { await sessionStore.refreshCapabilities(forceReload: true) }
                } label: {
                    if sessionStore.isRefreshingCapabilities {
                        Label(L10n.text("ui.refreshing_21eaf737"), systemImage: "arrow.clockwise")
                    } else {
                        Label(L10n.text("ui.refresh_ability"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(sessionStore.isRefreshingCapabilities)
            } footer: {
                Text(L10n.text("ui.here_the_local_skills_and_mcp_configurations_discoverable"))
            }
            .listRowBackground(tokens.elevatedSurface)

            if let error = sessionStore.capabilityErrorMessage {
                Section(L10n.text("ui.error")) {
                    Text(error)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(.red)
                }
                .listRowBackground(tokens.elevatedSurface)
            }

            Section(L10n.text("ui.skills")) {
                let skills = sessionStore.capabilityList?.skills ?? []
                if skills.isEmpty {
                    ContentUnavailableView(L10n.text("ui.skills_not_found"), systemImage: "wand.and.stars")
                        .font(themeStore.uiFont(.caption))
                } else {
                    ForEach(skills) { skill in
                        CapabilityItemRow(
                            symbolName: "wand.and.stars",
                            title: skill.name,
                            subtitle: skill.description,
                            detail: "\(scopeText(skill.scope)) · \(skill.path)",
                            isEnabled: skill.enabled
                        )
                    }
                }
            }
            .listRowBackground(tokens.elevatedSurface)

            Section("MCP") {
                let servers = sessionStore.capabilityList?.mcpServers ?? []
                if servers.isEmpty {
                    ContentUnavailableView(L10n.text("ui.mcp_server_not_found"), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(themeStore.uiFont(.caption))
                } else {
                    ForEach(servers) { server in
                        CapabilityItemRow(
                            symbolName: "point.3.connected.trianglepath.dotted",
                            title: serverTitle(server),
                            subtitle: serverSubtitle(server),
                            detail: serverDetail(server),
                            isEnabled: serverIsUsable(server),
                            statusText: serverStatusText(server),
                            statusColor: serverStatusColor(server)
                        )
                    }
                }
            }
            .listRowBackground(tokens.elevatedSurface)
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.ability"))
        .tint(tokens.accent)
        .task {
            if sessionStore.capabilityList == nil {
                await sessionStore.refreshCapabilities()
            }
        }
    }

    private func serverTitle(_ server: MCPCapability) -> String {
        if let plugin = server.plugin, !plugin.isEmpty {
            return "\(server.name) · \(plugin)"
        }
        return server.name
    }

    private func serverSubtitle(_ server: MCPCapability) -> String? {
        if let url = server.url, !url.isEmpty {
            return url
        }
        if let command = server.command, !command.isEmpty {
            return command
        }
        return transportText(server.transport)
    }

    private func serverDetail(_ server: MCPCapability) -> String {
        let base = "\(scopeText(server.scope)) · \(server.configPath)"
        guard let note = localizedStatusNote(server) else {
            return base
        }
        return "\(base)\n\(note)"
    }

    /// `status_note` is server diagnostics currently authored in Chinese. The status and
    /// transport codes are stable, so render those locally and keep raw details out of UI.
    private func localizedStatusNote(_ server: MCPCapability) -> String? {
        switch (server.status, server.transport) {
        case ("disabled", _):
            return L10n.text("ui.mcp_status_disabled")
        case ("ready", "stdio"):
            return L10n.text("ui.mcp_status_command_available")
        case ("missing_command", "stdio"):
            return L10n.text("ui.mcp_status_command_missing")
        case ("invalid", "stdio"):
            return L10n.text("ui.mcp_status_stdio_command_required")
        case ("invalid", "http"):
            return L10n.text("ui.mcp_status_http_url_required")
        case ("configured", "http"):
            return L10n.text("ui.mcp_status_http_not_probed")
        case ("invalid", _):
            return L10n.text("ui.mcp_status_command_or_url_required")
        case ("ready", _), ("configured", _):
            return L10n.text("ui.mcp_status_ready")
        case (nil, _):
            return server.enabled ? L10n.text("ui.mcp_status_unknown") : L10n.text("ui.mcp_status_disabled")
        default:
            return L10n.text("ui.mcp_status_unknown")
        }
    }

    private func serverStatusText(_ server: MCPCapability) -> String? {
        switch server.status {
        case "ready":
            return L10n.text("ui.available")
        case "configured":
            return L10n.text("ui.configured")
        case "missing_command":
            return L10n.text("ui.missing_command")
        case "invalid":
            return L10n.text("ui.configuration_exception")
        case "disabled":
            return L10n.text("ui.deactivated")
        default:
            return server.enabled ? nil : L10n.text("ui.deactivated")
        }
    }

    private func serverStatusColor(_ server: MCPCapability) -> Color {
        switch server.status {
        case "ready":
            return themeStore.tokens(for: colorScheme).success
        case "missing_command", "invalid":
            return themeStore.tokens(for: colorScheme).warning
        default:
            return .secondary
        }
    }

    private func serverIsUsable(_ server: MCPCapability) -> Bool {
        server.enabled && server.status != "missing_command" && server.status != "invalid"
    }

    private func scopeText(_ scope: String) -> String {
        switch scope {
        case "repo":
            return L10n.text("ui.project")
        case "user":
            return L10n.text("ui.user")
        case "admin":
            return L10n.text("ui.system")
        default:
            return L10n.text("ui.unknown_scope")
        }
    }

    private func transportText(_ transport: String?) -> String? {
        switch transport {
        case "stdio": return L10n.text("ui.mcp_transport_stdio")
        case "http": return L10n.text("ui.mcp_transport_http")
        case nil, "": return nil
        default: return L10n.text("ui.mcp_transport_unknown")
        }
    }
}

struct CapabilityValueRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(themeStore.uiFont(.caption, weight: .medium))
            Text(value)
                .font(themeStore.codeFont(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct CapabilityItemRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let symbolName: String
    let title: String
    let subtitle: String?
    let detail: String
    let isEnabled: Bool
    let statusText: String?
    let statusColor: Color

    init(
        symbolName: String,
        title: String,
        subtitle: String?,
        detail: String,
        isEnabled: Bool,
        statusText: String? = nil,
        statusColor: Color = .secondary
    ) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.isEnabled = isEnabled
        self.statusText = statusText
        self.statusColor = statusColor
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(isEnabled ? tokens.accent : Color.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .lineLimit(2)
                    if let statusText {
                        Text(statusText)
                            .font(themeStore.uiFont(.caption2, weight: .medium))
                            .foregroundStyle(statusColor)
                    } else if !isEnabled {
                        Text(L10n.text("ui.deactivated"))
                            .font(themeStore.uiFont(.caption2, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(detail)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

enum WorkspaceIconStylePickerLayout {
    /// iPhone 竖屏的 Form 内容区通常低于此宽度；iPad 详情区即使带侧栏，
    /// 也会进入单行横滑，避免因为 8 项无法一次放下就退回两行并留下大片空白。
    static let minimumSingleRowViewportWidth: CGFloat = 480

    /// 按真实容器宽度决定信息密度，不按设备型号判断。单行不要求全部项目同时放下，
    /// 超出的内容交给原生横向滚动；辅助功能字号继续两行，避免标题被过度压缩。
    static func usesSingleRow(
        viewportWidth: CGFloat,
        itemCount: Int,
        isAccessibilitySize: Bool
    ) -> Bool {
        guard viewportWidth > 0, itemCount > 0, !isAccessibilitySize else { return false }
        return viewportWidth >= minimumSingleRowViewportWidth
    }
}

struct AppearanceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var workspaceAppearanceStore: WorkspaceAppearanceStore

    let profileID: String
    @State private var workspaceIconStyleViewportWidth: CGFloat = 0

    var body: some View {
        let systemColorScheme = themeSystemColorScheme ?? colorScheme
        let resolvedColorScheme = themeStore.resolvedColorScheme(for: systemColorScheme)
        let tokens = themeStore.tokens(for: systemColorScheme)
        let selectedWorkspaceIconStyle = workspaceAppearanceStore.style(profileID: profileID)

        Form {
            Section {
                Picker(L10n.text("ui.appearance"), selection: $themeStore.mode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: iconName(for: mode))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.text("ui.dark_and_light_colors"))
            } footer: {
                Text(L10n.text("ui.system_mode_follows_the_current_device_appearance_light"))
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        LazyHGrid(
                            rows: workspaceIconStyleRows,
                            alignment: .center,
                            spacing: workspaceIconStyleColumnSpacing
                        ) {
                            ForEach(selectableWorkspaceIconStyles) { style in
                                workspaceIconStyleOption(
                                    style: style,
                                    selectedStyle: selectedWorkspaceIconStyle,
                                    tokens: tokens,
                                    fixedWidth: workspaceIconStyleItemWidth
                                )
                            }
                        }
                        // 单行与双行都使用同一滚动容器；末端留白让最后一项完整停靠。
                        .padding(.vertical, 6)
                        .padding(.trailing, 12)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .onAppear {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            // 只在进入页面时定位一次；避免双向 scrollPosition 在拖动期间
                            // 持续写回状态并让整个 Form 重绘，保持手指与内容 1:1 跟随。
                            scrollProxy.scrollTo(selectedWorkspaceIconStyle.id, anchor: .center)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        guard width > 0, workspaceIconStyleViewportWidth != width else { return }
                        workspaceIconStyleViewportWidth = width
                    }
                    .accessibilityIdentifier("settings.workspaceIconStyle")
                }
            } header: {
                Text(L10n.text("ui.workspace_avatar_style"))
            } footer: {
                Text(L10n.text("ui.workspace_avatar_style_description"))
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                ForEach(ThemePreset.allCases) { preset in
                    ThemePresetRow(
                        preset: preset,
                        isSelected: themeStore.preset == preset,
                        tokens: tokens
                    ) {
                        themeStore.preset = preset
                    }
                }
            } header: {
                Text(L10n.text("ui.topic"))
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                Picker(L10n.text("ui.ui_font"), selection: $themeStore.uiFontPreset) {
                    ForEach(ThemeUIFontPreset.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }

                Picker(L10n.text("ui.code_font"), selection: $themeStore.codeFontPreset) {
                    ForEach(ThemeCodeFontPreset.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("ui.font_size"))
                        Spacer()
                        Text(fontScaleText)
                            .foregroundStyle(tokens.secondaryText)
                    }
                    .font(themeStore.uiFont(size: 15, weight: .medium))

                    Slider(
                        value: Binding(
                            get: { themeStore.fontScale },
                            set: { themeStore.setFontScale($0) }
                        ),
                        in: ThemeStore.minimumFontScale...ThemeStore.maximumFontScale,
                        step: 0.05
                    )

                    HStack(alignment: .firstTextBaseline) {
                        Text("Aa")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                        Spacer()
                        Text("Aa")
                            .font(themeStore.uiFont(size: 22, weight: .semibold))
                    }
                    .foregroundStyle(tokens.secondaryText)
                }
                .padding(.vertical, 4)
            } header: {
                Text(L10n.text("ui.font"))
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                AppearanceConversationPreview()
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text(L10n.text("ui.chat_preview"))
            }
            .listRowBackground(tokens.elevatedSurface)

            Section {
                Button(role: .destructive) {
                    themeStore.reset()
                    workspaceAppearanceStore.setStyle(
                        .journey,
                        profileID: profileID
                    )
                } label: {
                    Label(L10n.text("ui.restore_default_appearance"), systemImage: "arrow.counterclockwise")
                }
            }
            .listRowBackground(tokens.elevatedSurface)
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.personalization"))
        .preferredColorScheme(resolvedColorScheme)
        .environment(\.colorScheme, resolvedColorScheme)
        .tint(tokens.accent)
    }

    private var fontScaleText: String {
        "\(Int((themeStore.fontScale * 100).rounded()))%"
    }

    private var workspaceIconStyleRows: [GridItem] {
        let rowHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 142 : 96
        let rowSpacing: CGFloat = dynamicTypeSize.isAccessibilitySize ? 14 : 10
        if WorkspaceIconStylePickerLayout.usesSingleRow(
            viewportWidth: workspaceIconStyleViewportWidth,
            itemCount: selectableWorkspaceIconStyles.count,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        ) {
            return [GridItem(.fixed(rowHeight), spacing: 0)]
        }
        return [
            GridItem(.fixed(rowHeight), spacing: rowSpacing),
            GridItem(.fixed(rowHeight), spacing: 0)
        ]
    }

    private var workspaceIconStyleColumnSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 12 : 8
    }

    private var workspaceIconStyleItemWidth: CGFloat {
        // 普通字号压缩到接近头像实际宽度，在 iPhone 上展示四列并露出下一列；
        // 辅助功能字号仍保留两行标题所需空间和充足触控区域。
        dynamicTypeSize.isAccessibilitySize ? 132 : 88
    }

    private var selectableWorkspaceIconStyles: [WorkspaceIconStyle] {
        WorkspaceIconStyle.selectableStyles(
            currentStyle: workspaceAppearanceStore.style(profileID: profileID)
        )
    }

    private var workspaceIconStyleBinding: Binding<WorkspaceIconStyle> {
        Binding(
            get: {
                workspaceAppearanceStore.style(profileID: profileID)
            },
            set: {
                workspaceAppearanceStore.setStyle(
                    $0,
                    profileID: profileID
                )
            }
        )
    }

    private func workspaceIconStyleOption(
        style: WorkspaceIconStyle,
        selectedStyle: WorkspaceIconStyle,
        tokens: ThemeTokens,
        fixedWidth: CGFloat?
    ) -> some View {
        let isSelected = selectedStyle == style
        return Button {
            workspaceIconStyleBinding.wrappedValue = style
        } label: {
            WorkspaceIconStyleOptionLabel(
                style: style,
                isSelected: isSelected,
                tokens: tokens
            )
        }
        .buttonStyle(WorkspaceIconStylePressButtonStyle(reduceMotion: reduceMotion))
        .frame(width: fixedWidth)
        .accessibilityLabel(style.title)
        .accessibilityValue(isSelected ? L10n.text("ui.selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.workspaceIconStyle.option.\(style.rawValue)")
        .id(style.id)
    }

    private func iconName(for mode: ThemeMode) -> String {
        switch mode {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}

private struct WorkspaceIconStyleOptionLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore
    @ScaledMetric(relativeTo: .caption) private var dynamicCaptionSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var dynamicAvatarSize: CGFloat = 56

    let style: WorkspaceIconStyle
    let isSelected: Bool
    let tokens: ThemeTokens

    var body: some View {
        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 9 : 7) {
            representativeImage

            Text(style.compactTitle)
                .font(
                    themeStore.uiFont(
                        size: dynamicCaptionSize,
                        weight: isSelected ? .semibold : .medium
                    )
                )
                .foregroundStyle(isSelected ? tokens.primaryAction : tokens.primaryText)
                // 完整英文作品名需要两行空间；短标题仍自然保持单行。
                .lineLimit(2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.72)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 112 : 88,
            alignment: .top
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var representativeImage: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let assetName = style.representativeAssetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(verbatim: "🦧")
                        .font(.system(size: avatarDiameter * 0.58))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            Color(red: 0.88, green: 0.72, blue: 0.34).opacity(0.22)
                        )
                }
            }
            .frame(width: avatarDiameter, height: avatarDiameter)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(
                        isSelected ? tokens.primaryAction : tokens.border.opacity(0.55),
                        lineWidth: isSelected ? 2.5 : 0.75
                    )
            }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tokens.primaryAction, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(tokens.elevatedSurface, lineWidth: 2)
                    }
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var avatarDiameter: CGFloat {
        min(dynamicAvatarSize, dynamicTypeSize.isAccessibilitySize ? 68 : 60)
    }
}

private struct WorkspaceIconStylePressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 普通模式用轻微缩放提供按下即时反馈；Reduce Motion 下只改变透明度。
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

struct ThemePresetRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let preset: ThemePreset
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(preset.swatchBackground)
                    Text("Aa")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(preset.swatchForeground)
                }
                .frame(width: 42, height: 42)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? tokens.accent : tokens.border, lineWidth: isSelected ? 2 : 1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(preset.subtitle)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(tokens.accent)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct AppearanceConversationPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeSystemColorScheme) private var themeSystemColorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: themeSystemColorScheme ?? colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(themeStore.preset.title, systemImage: "sparkles")
                    .font(themeStore.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                Spacer()
                Text(themeStore.mode.title)
                    .font(themeStore.uiFont(size: 12, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
            }

            PreviewBubble(
                text: L10n.text("ui.help_me_check_the_risks_of_this_pr"),
                alignment: .trailing,
                fill: tokens.userBubble,
                textColor: tokens.primaryText,
                font: themeStore.uiFont(size: 15)
            )

            PreviewBubble(
                text: L10n.text("ui.checking_started_found_2_changes_that_need_to"),
                alignment: .leading,
                fill: tokens.assistantBubble,
                textColor: tokens.primaryText,
                font: themeStore.uiFont(size: 15)
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    Text(L10n.text("ui.command_summary"))
                    Spacer()
                    Text("go test ./...")
                        .lineLimit(1)
                }
                .font(themeStore.uiFont(size: 13, weight: .medium))

                Text("let theme = ThemePreset.\(themeStore.preset.rawValue)")
                    .font(themeStore.codeFont(size: 13))
                    .foregroundStyle(tokens.codeText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tokens.codeBlock, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .foregroundStyle(tokens.secondaryText)
            .padding(10)
            .background(tokens.systemBubble)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tokens.border, lineWidth: 1)
            }
        }
        .padding(12)
        .background(tokens.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tokens.border, lineWidth: 1)
        }
    }
}

struct StableEndpointTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.text = text
        context.coordinator.lastSyncedText = text
        textField.delegate = context.coordinator
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .done
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        uiView.placeholder = placeholder

        guard context.coordinator.lastSyncedText != text else {
            return
        }

        let previousText = uiView.text ?? ""
        let selectedRange = context.coordinator.selectedRange(in: uiView)
        uiView.text = text
        context.coordinator.lastSyncedText = text
        context.coordinator.setSelectedRange(
            TextSelectionPolicy.rangeAfterExternalTextSync(
                previousText: previousText,
                nextText: text,
                previousRange: selectedRange
            ),
            in: uiView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: StableEndpointTextField
        var lastSyncedText = ""

        init(_ parent: StableEndpointTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let next = textField.text ?? ""
            guard next != lastSyncedText else {
                return
            }
            lastSyncedText = next
            parent.text = next
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func selectedRange(in textField: UITextField) -> NSRange {
            guard let selectedTextRange = textField.selectedTextRange else {
                let length = ((textField.text ?? "") as NSString).length
                return NSRange(location: length, length: 0)
            }
            let location = textField.offset(from: textField.beginningOfDocument, to: selectedTextRange.start)
            let length = textField.offset(from: selectedTextRange.start, to: selectedTextRange.end)
            return NSRange(location: location, length: length)
        }

        func setSelectedRange(_ range: NSRange, in textField: UITextField) {
            guard
                let start = textField.position(from: textField.beginningOfDocument, offset: range.location),
                let end = textField.position(from: start, offset: range.length)
            else {
                return
            }
            textField.selectedTextRange = textField.textRange(from: start, to: end)
        }
    }
}

struct PreviewBubble: View {
    enum AlignmentSide {
        case leading
        case trailing
    }

    let text: String
    let alignment: AlignmentSide
    let fill: Color
    let textColor: Color
    let font: Font

    var body: some View {
        HStack {
            if alignment == .trailing {
                Spacer(minLength: 36)
            }

            Text(text)
                .font(font)
                .foregroundStyle(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if alignment == .leading {
                Spacer(minLength: 36)
            }
        }
    }
}

struct DefaultModelSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let runtimes = DefaultModelRuntime.allCases

        Form {
            // 两个 runtime 各自一段，不再用分段控件互相遮挡：
            // 这一页要回答的是「现在两边分别是什么」，切换器会把一半答案藏起来。
            ForEach(runtimes) { runtime in
                DefaultModelRuntimeSection(
                    runtime: runtime,
                    allOptions: sessionStore.appServerModelOptions,
                    tokens: tokens,
                    footer: runtime == runtimes.last
                        ? L10n.text("ui.default_model_settings_description")
                        : nil
                )
            }
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.default_model"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(tokens.accent)
        .onAppear {
            normalizeStoredEfforts()
        }
        .onChange(of: sessionStore.appServerModelOptions) { _, _ in
            normalizeStoredEfforts()
        }
        .task {
            await sessionStore.refreshAppServerModelOptions()
            normalizeStoredEfforts()
        }
    }

    private func normalizeStoredEfforts() {
        for runtime in DefaultModelRuntime.allCases {
            normalizeStoredEffort(for: runtime)
        }
    }

    private func normalizeStoredEffort(for runtime: DefaultModelRuntime) {
        // 模型目录为空时可能暂时只显示内置兜底；保留未知的历史模型与档位，
        // 等 model/list 返回 canonical id 后再恢复，避免网络短暂失败覆盖用户配置。
        let allOptions = sessionStore.appServerModelOptions
        let candidates = DefaultModelPreferences.options(
            for: runtime.rawValue,
            allOptions: allOptions
        )
        let storedID = DefaultModelPreferences.storedModelOptionID(for: runtime.rawValue)
        guard storedID == nil || candidates.contains(where: { $0.id == storedID }) else {
            return
        }
        guard let storedEffort = DefaultModelPreferences.storedReasoningEffort(for: runtime.rawValue),
              let option = DefaultModelPreferences.resolvedSelection(
                  for: runtime.rawValue,
                  allOptions: allOptions
              )?.option
        else {
            return
        }
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtime.rawValue,
            options: candidates
        )
        let visibleEfforts = ModelReasoningGridCatalog.visibleEfforts(for: option, layout: layout)
        if !visibleEfforts.contains(storedEffort) {
            UserDefaults.standard.removeObject(
                forKey: DefaultModelPreferences.reasoningEffortKey(for: runtime.rawValue)
            )
        }
    }
}

private struct DefaultModelRuntimeSection: View {
    let runtime: DefaultModelRuntime
    let allOptions: [CodexAppServerModelOption]
    let tokens: ThemeTokens
    let footer: String?

    @AppStorage private var modelOptionID: String
    @AppStorage private var reasoningEffortRawValue: String

    init(
        runtime: DefaultModelRuntime,
        allOptions: [CodexAppServerModelOption],
        tokens: ThemeTokens,
        footer: String?
    ) {
        self.runtime = runtime
        self.allOptions = allOptions
        self.tokens = tokens
        self.footer = footer
        _modelOptionID = AppStorage(
            wrappedValue: "",
            DefaultModelPreferences.modelOptionIDKey(for: runtime.rawValue)
        )
        _reasoningEffortRawValue = AppStorage(
            wrappedValue: "",
            DefaultModelPreferences.reasoningEffortKey(for: runtime.rawValue)
        )
    }

    var body: some View {
        Section {
            Picker(L10n.text("ui.model"), selection: modelSelectionBinding) {
                Text(L10n.text("ui.use_built_in_default"))
                    .tag("")
                ForEach(modelOptions) { option in
                    Text(option.menuTitle)
                        .tag(option.id)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("settings.defaultModels.model.\(runtime.rawValue)")

            if availableEfforts.isEmpty {
                LabeledContent(L10n.text("ui.reasoning_effort")) {
                    Text(L10n.text("ui.no_reasoning_effort_available"))
                        .foregroundStyle(tokens.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier(
                    "settings.defaultModels.reasoning.\(runtime.rawValue).unavailable"
                )
            } else {
                Picker(L10n.text("ui.reasoning_effort"), selection: reasoningEffortSelectionBinding) {
                    ForEach(availableEfforts) { effort in
                        Text(ModelReasoningGridCatalog.effortTitle(effort))
                            .tag(effort.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("settings.defaultModels.reasoning.\(runtime.rawValue)")
            }

            // 没改过就没什么可恢复的，常驻一个红字按钮只是噪音。
            if hasCustomDefault {
                Button {
                    modelOptionID = ""
                    reasoningEffortRawValue = ""
                } label: {
                    Label(
                        L10n.text("ui.reset_to_built_in_default"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .foregroundStyle(tokens.warning)
                .accessibilityIdentifier("settings.defaultModels.reset.\(runtime.rawValue)")
            }
        } header: {
            Text(runtime.settingsTitle)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
        .listRowBackground(tokens.elevatedSurface)
    }

    private var hasCustomDefault: Bool {
        !modelOptionID.isEmpty || !reasoningEffortRawValue.isEmpty
    }

    private var modelOptions: [CodexAppServerModelOption] {
        DefaultModelPreferences.options(for: runtime.rawValue, allOptions: allOptions)
    }

    private var selectedModelOption: CodexAppServerModelOption? {
        if !modelOptionID.isEmpty,
           let storedOption = modelOptions.first(where: { $0.id == modelOptionID }) {
            return storedOption
        }
        return DefaultModelPreferences.resolvedSelection(
            for: runtime.rawValue,
            allOptions: allOptions
        )?.option
    }

    private var availableEfforts: [CodexAppServerReasoningEffort] {
        guard let selectedModelOption else {
            return []
        }
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtime.rawValue,
            options: modelOptions
        )
        return ModelReasoningGridCatalog.visibleEfforts(for: selectedModelOption, layout: layout)
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: {
                guard !modelOptionID.isEmpty,
                      modelOptions.contains(where: { $0.id == modelOptionID })
                else {
                    return ""
                }
                return modelOptionID
            },
            set: { newValue in
                modelOptionID = newValue
                // 换模型后旧档位可能不在新模型的可见档位里，交给页面级归一化清掉。
                if let storedEffort = CodexAppServerReasoningEffort(rawValue: reasoningEffortRawValue),
                   !availableEfforts.contains(storedEffort) {
                    reasoningEffortRawValue = ""
                }
            }
        )
    }

    private var reasoningEffortSelectionBinding: Binding<String> {
        Binding(
            get: {
                if let storedEffort = CodexAppServerReasoningEffort(rawValue: reasoningEffortRawValue),
                   availableEfforts.contains(storedEffort) {
                    return storedEffort.rawValue
                }
                let layout = ModelReasoningGridCatalog.layout(
                    runtimeProvider: runtime.rawValue,
                    options: modelOptions
                )
                return ModelReasoningGridCatalog.preferredDefaultEffort(
                    runtimeProvider: runtime.rawValue,
                    option: selectedModelOption,
                    layout: layout
                )?.rawValue ?? availableEfforts.first?.rawValue ?? ""
            },
            set: { reasoningEffortRawValue = $0 }
        )
    }
}

private extension DefaultModelRuntime {
    var settingsTitle: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        }
    }
}

/// iOS 只能说明和引导，不能伪装成能够修改 Mac launchd 环境的远程开关。
/// 真正的启用入口继续由 Mimi Remote Mac 持有，确保配置、Desktop 重启与失败回滚在同一台电脑完成。
enum CodexDesktopExperimentGuide {
    static let stepKeys = [
        "ui.codex_experiment_step_open_mimi_menu",
        "ui.codex_experiment_step_choose_experiments",
        "ui.codex_experiment_step_enable_sharing",
        "ui.codex_experiment_step_restart_desktop",
        "ui.codex_experiment_step_verify_session",
    ]
}

struct ExperimentalFeaturesSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(L10n.text("ui.share_codex_desktop_sessions_experimental"))
                            .font(themeStore.uiFont(.headline, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                    } icon: {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(tokens.accent)
                    }

                    Text(L10n.text("ui.codex_experiment_summary"))
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.experimentalFeatures.codexSharing")
            } footer: {
                Text(L10n.text("ui.codex_experiment_warning"))
            }

            Section {
                ForEach(Array(CodexDesktopExperimentGuide.stepKeys.enumerated()), id: \.offset) { index, key in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(index + 1))
                            .font(themeStore.uiFont(.footnote, weight: .semibold))
                            .foregroundStyle(tokens.accent)
                            .frame(width: 28, height: 28)
                            .background(tokens.accent.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)

                        Text(L10n.text(key))
                            .font(themeStore.uiFont(.body))
                            .foregroundStyle(tokens.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        L10n.format(
                            "ui.step_value_value",
                            index + 1,
                            L10n.text(key)
                        )
                    )
                    .accessibilityIdentifier("settings.experimentalFeatures.step.\(index + 1)")
                }
            } header: {
                Text(L10n.text("ui.how_to_enable_on_mac"))
                    .textCase(nil)
            } footer: {
                Text(L10n.text("ui.codex_experiment_mac_only_note"))
            }

            Section {
                Label {
                    Text(L10n.text("ui.codex_experiment_service_note"))
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(tokens.accent)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.experimentalFeatures.serviceNote")
            } header: {
                Text(L10n.text("ui.before_you_use_it"))
                    .textCase(nil)
            }
        }
        .themedSettingsForm(tokens: tokens)
        .navigationTitle(L10n.text("ui.experimental_features"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.experimentalFeatures.detail")
    }
}

extension View {
    func themedSettingsForm(tokens: ThemeTokens) -> some View {
        scrollContentBackground(.hidden)
            .background(tokens.background.ignoresSafeArea())
    }
}

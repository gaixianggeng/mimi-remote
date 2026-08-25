import AVFoundation
import PhotosUI
import SwiftUI

// 权限选择、能力降级和队列边界属于输入状态协作，不让 ComposerView 主体继续增长。
extension ComposerView {
    func applyDefaultPermissionMode() {
        let stored = ComposerPermissionMode.stored(defaultPermissionModeID)
        composerState.applyPermissionMode(safePermissionMode(stored))
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: activeComposerDraftScope
        )
    }

    func applyDefaultPermissionModeForActiveScope() {
        // 设置页的“默认权限”只面向新会话。已有 Thread 在用户未点击当前输入区的
        // 权限按钮时必须继续沿用服务端设置，不能因全局偏好变化而被静默覆盖。
        switch activeComposerDraftScope {
        case .newSession:
            applyDefaultPermissionMode()
        case .session(let sessionID) where sessionID.hasPrefix("local:"):
            applyDefaultPermissionMode()
        case .none, .session:
            break
        }
    }

    func setPermissionMode(_ mode: ComposerPermissionMode) {
        let safeMode = safePermissionMode(mode)
        // Claude 的安全降级只影响当前会话，不覆盖用户为 Codex 保存的“完全访问”默认值。
        if selectedSessionRuntimeProviderForModelMenu != "claude" {
            defaultPermissionModeID = safeMode.rawValue
        }
        composerState.applyPermissionMode(
            safeMode,
            sessionIsRunning: sessionStore.selectedSessionRequiresFreshPermissionTurn
        )
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: activeComposerDraftScope
        )
    }

    func setPermissionProfile(_ profile: CodexAppServerPermissionProfileSummary) {
        if let builtInMode = ComposerPermissionMode(builtInPermissionProfileID: profile.id) {
            setPermissionMode(builtInMode)
            return
        }
        composerState.updatePermissionSelection(
            sessionIsRunning: sessionStore.selectedSessionRequiresFreshPermissionTurn
        ) { options in
            options.preservesThreadPermissionSettings = false
            options.permissionProfileID = profile.id
            options.approvalPolicy = .forPermissionProfileID(profile.id)
            options.approvalsReviewer = "user"
            options.networkAccess = false
        }
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: activeComposerDraftScope
        )
    }

    var permissionProfileCWD: String? {
        let path = sessionStore.selectedSession?.dir ?? sessionStore.selectedProject?.path
        return path?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
    }

    var availablePermissionProfiles: [CodexAppServerPermissionProfileSummary] {
        guard selectedSessionRuntimeProviderForModelMenu != "claude",
              sessionStore.permissionProfilesCWD == permissionProfileCWD
        else {
            return []
        }
        // 三个内建档案与上方用户权限模式完全重复，只把真正的自定义档案放进高级入口。
        return sessionStore.appServerPermissionProfiles.filter {
            ComposerPermissionMode(builtInPermissionProfileID: $0.id) == nil
        }
    }

    var selectedPermissionProfileID: String? {
        if let profileID = composerState.turnOptions.permissionProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty {
            return profileID
        }
        return composerState.turnOptions.preservesThreadPermissionSettings
            ? activePermissionProfile?.id
            : nil
    }

    var activePermissionProfile: CodexAppServerActivePermissionProfile? {
        guard let sessionID = sessionStore.selectedSessionID else {
            return nil
        }
        return sessionStore.activePermissionProfileBySessionID[sessionID]
    }

    func clampPermissionProfileToAvailableOptions() {
        guard let explicitProfileID = composerState.turnOptions.permissionProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty else { return }
        if let builtInMode = ComposerPermissionMode(builtInPermissionProfileID: explicitProfileID) {
            composerState.applyPermissionMode(
                builtInMode,
                sessionIsRunning: sessionStore.selectedSessionRequiresFreshPermissionTurn
            )
            sessionStore.saveComposerPermissionSelection(
                composerState.permissionSelectionSnapshot(),
                for: activeComposerDraftScope
            )
            return
        }
        guard availablePermissionProfiles.contains(where: { $0.id == explicitProfileID }) else {
            composerState.resetUnavailablePermissionProfile(
                sessionIsRunning: sessionStore.selectedSessionRequiresFreshPermissionTurn
            )
            sessionStore.saveComposerPermissionSelection(
                composerState.permissionSelectionSnapshot(),
                for: activeComposerDraftScope
            )
            return
        }
    }

    var availablePermissionModes: [ComposerPermissionMode] {
        if selectedSessionRuntimeProviderForModelMenu == "claude" {
            return [.requestApproval, .readOnly, .autoApprove]
        }
        return ComposerPermissionMode.allCases
    }

    func safePermissionMode(_ mode: ComposerPermissionMode) -> ComposerPermissionMode {
        // Claude 不支持“完全访问”，也不持久化自己的默认；当共享默认落在 fullAccess 时，
        // 降级到“自动批准低风险操作”作为 Claude 的安全默认，而不是每轮都请求审批。
        // autoApprove 仍是安全档（workspaceWrite + auto_review），绝不映射 bypassPermissions。
        selectedSessionRuntimeProviderForModelMenu == "claude" && mode == .fullAccess
            ? .autoApprove
            : mode
    }

    func clampPermissionSelectionToSelectedSessionRuntime() {
        let safeMode = safePermissionMode(composerState.permissionMode)
        guard safeMode != composerState.permissionMode else {
            return
        }
        composerState.applyPermissionMode(
            safeMode,
            sessionIsRunning: sessionStore.selectedSessionRequiresFreshPermissionTurn
        )
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: activeComposerDraftScope
        )
    }
}
import UIKit

enum ComposerTextLayoutPolicy {
    static func minimumHeight(
        isPhone: Bool,
        usesCompactMetrics: Bool,
        fontLineHeight: CGFloat
    ) -> CGFloat {
        guard isPhone else {
            return usesCompactMetrics ? 72 : 92
        }
        // 36pt 只承载一行正文；外围卡片 padding 继续提供可点击余量。
        // 大字号按真实行高增长，避免 Dynamic Type 首行被裁切。
        return max(36, ceil(fontLineHeight) + 8)
    }

    static func maximumHeight(
        isPhone: Bool,
        usesCompactMetrics: Bool,
        fontLineHeight: CGFloat
    ) -> CGFloat {
        guard isPhone else {
            return usesCompactMetrics ? 220 : 300
        }
        let minimum = minimumHeight(
            isPhone: true,
            usesCompactMetrics: usesCompactMetrics,
            fontLineHeight: fontLineHeight
        )
        // 标准字号约五行后转为内部滚动；辅助功能字号最多增至 180pt，
        // 避免输入区吞掉整块会话阅读空间。
        return max(minimum, min(180, ceil(fontLineHeight * 5.2)))
    }
}

struct ComposerToolbarControlLabel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let title: String?
    let systemImage: String?
    let trailingSystemImage: String?
    let isSelected: Bool
    let tint: Color?
    let titleMaxWidth: CGFloat?
    let accessibilityLabel: String
    var showsRestingSurface = true
    var usesPhoneStyle = false
    var usesCondensedTitle = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let cornerRadius: CGFloat = title == nil ? 22 : (usesPhoneStyle ? 20 : 12)
        let surfaceInset: CGFloat = usesPhoneStyle ? 2 : 4
        // 品牌紫只表达选中/运行状态；普通输入控件保持中性，降低底部工具区的视觉噪声。
        let restingForeground = usesPhoneStyle ? tokens.conversationPrimaryText : tokens.primaryText
        let foreground = isSelected ? tokens.primaryActionForeground : (tint ?? restingForeground)

        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(
                        themeStore.uiFont(
                            size: usesPhoneStyle ? 17 : 16,
                            weight: usesPhoneStyle ? .medium : .semibold
                        )
                    )
            }
            if let title {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: titleMaxWidth, alignment: .leading)
            }
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(themeStore.uiFont(size: 13, weight: .bold))
                    .accessibilityHidden(true)
            }
        }
        .font(
            usesPhoneStyle && usesCondensedTitle
                ? themeStore.uiFont(size: 15, weight: .medium)
                : themeStore.uiFont(
                    usesPhoneStyle ? .body : .caption,
                    weight: usesPhoneStyle ? .medium : .semibold
                )
        )
        .foregroundStyle(foreground)
        .frame(height: 44)
        .padding(
            .horizontal,
            title == nil ? 0 : (usesPhoneStyle ? (usesCondensedTitle ? 12 : 14) : 12)
        )
        .frame(minWidth: 44)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSelected ? tokens.accent : Color.clear)
                .padding(surfaceInset)
        }
        .modifier(
            ComposerFlatControlSurface(
                tokens: tokens,
                cornerRadius: cornerRadius,
                isEmphasized: isSelected,
                showsRestingFill: showsRestingSurface,
                surfaceInset: surfaceInset,
                usesNeutralControlSurface: usesPhoneStyle
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 权限配置菜单单独形成泛型边界，避免继续放大 ComposerView 已经很长的视图类型。
struct ComposerPermissionMenu: View {
    let permissionModes: [ComposerPermissionMode]
    let permissionProfiles: [CodexAppServerPermissionProfileSummary]
    let selectedMode: ComposerPermissionMode
    let selectedProfileID: String?
    let activeProfileID: String?
    let permissionAccessibilityValue: String
    let tint: Color
    let reduceMotion: Bool
    let usesPhoneStyle: Bool
    let onSelectMode: (ComposerPermissionMode) -> Void
    let onSelectProfile: (CodexAppServerPermissionProfileSummary) -> Void

    var body: some View {
        Menu {
            Section(L10n.text("ui.permission_mode")) {
                ForEach(permissionModes) { mode in
                    Button {
                        onSelectMode(mode)
                    } label: {
                        Label(mode.title, systemImage: modeIcon(mode))
                    }
                    .accessibilityHint(mode.detail)
                }
            }
            if !permissionProfiles.isEmpty {
                Section(L10n.text("ui.advanced_permission_profiles")) {
                    ForEach(permissionProfiles) { profile in
                        Button {
                            onSelectProfile(profile)
                        } label: {
                            Label(profile.id, systemImage: profileIcon(profile))
                        }
                        .accessibilityHint(profile.description ?? L10n.text("ui.use_named_permission_profile"))
                    }
                }
            }
            Section(L10n.text("ui.permission_status")) {
                if let activeProfileID {
                    Text(L10n.format("ui.current_turn_permission_value", displayName(for: activeProfileID)))
                }
                Text(L10n.format("ui.next_turn_permission_value", selectedPermissionName))
            }
        } label: {
            ComposerToolbarControlLabel(
                title: selectedProfileID ?? selectedMode.title,
                systemImage: selectedProfileID == nil ? selectedMode.systemImage : "shield.lefthalf.filled",
                trailingSystemImage: nil,
                isSelected: false,
                tint: tint,
                titleMaxWidth: nil,
                accessibilityLabel: L10n.text("ui.permission_mode"),
                showsRestingSurface: true,
                usesPhoneStyle: usesPhoneStyle,
                usesCondensedTitle: false
            )
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.permission_mode"))
        .accessibilityValue(permissionAccessibilityValue)
    }

    private func modeIcon(_ mode: ComposerPermissionMode) -> String {
        selectedProfileID == nil && selectedMode == mode ? "checkmark" : mode.systemImage
    }

    private func profileIcon(_ profile: CodexAppServerPermissionProfileSummary) -> String {
        selectedProfileID == profile.id ? "checkmark" : "shield.lefthalf.filled"
    }

    private var selectedPermissionName: String {
        selectedProfileID.map { displayName(for: $0) } ?? selectedMode.title
    }

    private func displayName(for profileID: String) -> String {
        ComposerPermissionMode(builtInPermissionProfileID: profileID)?.title ?? profileID
    }
}

/// 紧凑工具栏只持有已经擦除的子控件，避免父 View 的泛型类型继续聚合多个
/// Menu/Popover。真正的复杂子树由 ComposerView 的独立非内联方法逐个构建。
struct CompactComposerToolbarShell: View {
    let leadingControls: AnyView
    let toolControls: AnyView
    let submitControl: AnyView
    var spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            leadingControls
            Spacer(minLength: 0)
            toolControls
            submitControl
        }
        .frame(maxWidth: .infinity)
    }
}

/// 设置与语音各自保留 44pt 命中区和独立键帽；6pt 间隔表达同组关系，
/// 不再用一整块胶囊把两个不同动作粘在一起。
struct CompactComposerToolControlsShell: View {
    let optionsControl: AnyView
    let microphoneControl: AnyView

    var body: some View {
        HStack(spacing: 6) {
            optionsControl
            microphoneControl
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 左侧控件保持固定类型，但视觉上各自成面；每个复杂控件先在独立栈帧里擦除，
/// 再传入这里组合，防止真机在收集泛型元数据时触发 __chkstk_darwin。
struct CompactComposerLeadingControlsShell: View {
    let addControl: AnyView
    let modelControl: AnyView
    let deliveryControl: AnyView?

    var body: some View {
        HStack(spacing: 6) {
            addControl
            modelControl
            if let deliveryControl {
                deliveryControl
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// ComposerView 的输入、语音和附件动作集中在这里；状态仍由主 View 持有，避免新增镜像 ViewModel。
extension ComposerView {
    @ViewBuilder
    var addContentButton: some View {
        ZStack {
            Button {
                showsAddContentPanel.toggle()
            } label: {
                composerToolbarControlLabel(
                    title: nil,
                    systemImage: "plus",
                    accessibilityLabel: L10n.text("ui.add_content")
                )
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(L10n.text("ui.add_content"))
            .accessibilityIdentifier("composer.addContent")
            .help(L10n.text("ui.add_an_image_plugin_skill_or_shortcut_phrase"))
            .disabled(isRequestingCameraAuthorization)
        }
        // Popover 必须挂在不会参与按压缩放的固定锚点上；否则系统可能在 spring
        // 回弹途中读取 source rect，让箭头与“+”入口出现瞬时偏移。
        .frame(width: 44, height: 44)
        .popover(isPresented: $showsAddContentPanel, arrowEdge: .bottom) {
            AddContentPanel(
                skillShortcuts: enabledSkillShortcuts,
                pluginShortcuts: installedPluginShortcuts,
                capabilityErrorMessage: sessionStore.capabilityErrorMessage,
                isRefreshingCapabilities: sessionStore.isRefreshingCapabilities,
                showsPermissionSettings: isPhoneComposer,
                permissionModes: availablePermissionModes,
                selectedPermissionMode: composerState.permissionMode,
                showsCameraAction: showsCameraAttachmentAction,
                selectedSkillPaths: selectedSkillPaths,
                onPickFile: {
                    presentFileImporter()
                },
                onCapturePhoto: {
                    presentCameraAttachmentPicker()
                },
                onPickPhotos: {
                    presentPhotoLibraryPicker()
                },
                onToggleSkill: { skill in
                    toggleSkillAttachment(skill)
                },
                onManualAddSkill: {
                    showsAddContentPanel = false
                    showsManualSkillInputSheet = true
                },
                onPluginShortcut: { plugin in
                    composerState.insertPluginMention(plugin.presentationName)
                    clearVoiceTransientStatus()
                    showsAddContentPanel = false
                    UISelectionFeedbackGenerator().selectionChanged()
                },
                onRefreshCapabilities: {
                    Task { await sessionStore.refreshCapabilities(forceReload: true) }
                },
                onPermissionMode: { mode in
                    setPermissionMode(mode)
                },
                onShortcut: { shortcut in
                    composerState.insertShortcut(shortcut)
                    clearVoiceTransientStatus()
                    showsAddContentPanel = false
                }
            )
            .environmentObject(themeStore)
            .onDisappear {
                consumePendingAddContentAction()
            }
            .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
        }
    }

    var showsCameraAttachmentAction: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        true
#endif
    }

    // 悬浮控件底衬：与 composerContainerBackground 同源，只是换成胶囊轮廓，
    // 保证语音状态与底部输入面板属于同一层材质语言。
    @ViewBuilder
    func composerFloatingControlBackground(tokens: ThemeTokens) -> some View {
        let shape = Capsule(style: .continuous)
        if reduceTransparency {
            shape.fill(tokens.elevatedSurface)
        } else {
            shape
                .fill(WorkbenchMaterial.surface)
                .overlay {
                    shape.fill(tokens.elevatedSurface.opacity(colorScheme == .light ? 0.58 : 0.46))
                }
        }
    }

    // 宽屏设备直接平铺发送上下文。横向滚动只为大字号与极窄分屏兜底，
    // 不改变“无需先点开开关即可操作”的默认形态。
    var composerContextControlsRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    skillPickerButton
                    permissionMenu
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            if canCollapseIPadComposer {
                Button(action: collapseIPadComposer) {
                    Image(systemName: "chevron.down")
                        .font(themeStore.uiFont(.caption, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(L10n.text("ui.collapse_input_box"))
                .accessibilityIdentifier("composer.collapse")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// iPad 收起态是独立的一行卡片，不保留 iPad 完整 Composer 的工具栏。
    /// 附件条位于外层 `body`，因此这里仅替换输入卡本身，不会清理附件状态。
    func collapsedIPadComposerCard(tokens: ThemeTokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return Button(action: expandIPadComposer) {
            HStack(spacing: 8) {
                Text(collapsedComposerText)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(composerState.draft.isEmpty ? tokens.tertiaryText : tokens.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up")
                    .font(themeStore.uiFont(.caption2, weight: .bold))
                    .foregroundStyle(tokens.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .padding(8)
        .frame(maxWidth: .infinity)
        .background {
            composerContainerBackground(shape: shape, tokens: tokens)
        }
        .overlay {
            shape.strokeBorder(composerCardBorderColor(tokens), lineWidth: composerCardBorderWidth)
        }
        .tint(tokens.accent)
        .accessibilityLabel(L10n.text("ui.expand_input_box"))
        .accessibilityValue(collapsedComposerText)
        .accessibilityIdentifier("composer.expand")
    }

    var selectedVoiceInputProvider: VoiceInputProvider {
        VoiceInputProvider.resolved(rawValue: voiceInputProviderRawValue)
    }

    var isPhoneComposer: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var isIPadComposer: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        UIDevice.current.userInterfaceIdiom == .pad
#endif
    }

    /// iPad 可保留附件并收起；正在录音、转写、等待语音确认或 Skill 自动完成时，
    /// 必须继续展示完整编辑器，避免移除 UITextView 破坏进行中的输入上下文。
    var canCollapseIPadComposer: Bool {
        isIPadComposer &&
            !composerState.voiceDraftNeedsReview &&
            !isVoicePressActive &&
            !voiceInput.isPreparing &&
            !voiceInput.isRecording &&
            !isVoiceTranscribing &&
            activeSkillQuery == nil
    }

    var usesCollapsedIPadComposer: Bool {
        isComposerCollapsed && canCollapseIPadComposer
    }

    var collapsedComposerText: String {
        let text = composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? composerPlaceholderText : text
    }

    func expandIPadComposer() {
        guard isIPadComposer else { return }
        expandComposer()
    }

    func expandComposer() {
        isComposerCollapsed = false
        // 焦点请求只服务于这一次“点开输入框”；UITextView 消费后会清空 token，
        // 后续因附件或语音状态重建完整输入框时不会再次误弹键盘。
        composerTextFocusRequestID = UUID()
    }

    func collapseIPadComposer() {
        guard canCollapseIPadComposer else { return }
        collapseComposer()
    }

    func collapseComposer() {
        // 先让输入法提交 marked text，再把最终文本同步回草稿；折叠只改变展示，不丢编辑状态。
        composerTextSubmitBridge.resignFirstResponder()
        synchronizeComposerTextBeforeDraftScopeChange()
        composerTextSubmitBridge.prepareForRemoval(text: composerState.draft)
        activeSkillQuery = nil
        isComposerCollapsed = true
    }

    func resetPhoneComposerAfterSubmit() {
        guard isPhoneComposer else { return }
        // takeDraftForSubmit 已清空稳定草稿；iPhone 不再移除编辑器，而是同步清空同一个
        // UITextView 并回到一行。先清 UIKit 再失焦，防止旧正文被结束编辑回调写回。
        composerTextExternalRevision += 1
        composerTextSubmitBridge.resetTextAfterSubmit(to: composerState.draft)
        measuredComposerTextHeight = 0
        activeSkillQuery = nil
    }

    @ViewBuilder
    var attachmentStrip: some View {
        if !composerState.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(composerState.attachments.enumerated()), id: \.offset) { index, item in
                        attachmentChip(item, index: index)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func attachmentChip(_ item: CodexAppServerUserInput, index: Int) -> some View {
        if case .skill(let name, let path) = item {
            let capability = enabledSkillShortcuts.first { $0.path == path || $0.name == name }
            SkillAttachmentToken(
                metadata: SkillVisualMetadata(name: name, path: path, capability: capability),
                onOpen: canPreviewAttachment(item) ? { previewingAttachment = item } : nil,
                onRemove: { removeAttachment(item, at: index) }
            )
            .environmentObject(themeStore)
        } else {
            HStack(spacing: 6) {
                Button {
                    previewingAttachment = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: attachmentSymbol(for: item))
                        Text(item.previewText)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canPreviewAttachment(item))

                Button {
                    removeAttachment(item, at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .accessibilityLabel(L10n.text("ui.remove"))
                }
                .buttonStyle(.plain)
            }
            .font(themeStore.uiFont(.caption))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(themeStore.tokens(for: colorScheme).elevatedSurface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(themeStore.tokens(for: colorScheme).border)
            }
        }
    }

    func removeAttachment(_ item: CodexAppServerUserInput, at index: Int) {
        composerState.removeAttachment(at: index)
        if previewingAttachment?.id == item.id {
            previewingAttachment = nil
        }
    }

    @ViewBuilder
    var attachmentErrorNotice: some View {
        if let attachmentErrorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(attachmentErrorMessage)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    var voiceErrorMessage: some View {
        if let errorMessage = voiceInput.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .lineLimit(2)
                    .layoutPriority(1)
                    .foregroundStyle(.red)
                Spacer(minLength: 0)
                if retryableVoiceTranscription != nil {
                    Button {
                        retryVoiceTranscription()
                    } label: {
                        if isVoiceTranscribing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.text("ui.try_transcribing_again"), systemImage: "arrow.clockwise")
                        }
                    }
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isVoiceTranscribing)
                    .accessibilityLabel(L10n.text("ui.retry_speech_transcription"))
                    .help(L10n.text("ui.resubmit_the_recording_you_just_made"))
                }
                if selectedVoiceInputProvider == .apple, retryableVoiceTranscription == nil {
                    Button {
                        voiceInputProviderRawValue = VoiceInputProvider.codex.rawValue
                        clearVoiceTransientStatus()
                    } label: {
                        Label(L10n.text("ui.use_codex_voice_input"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier("composer.voice.useCodex")
                }
                Button {
                    clearVoiceTransientStatus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.red.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.turn_off_speech_transcription_error_prompts"))
                .help(L10n.text("ui.close_prompt"))
            }
            .font(themeStore.uiFont(.caption))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    var voiceNoticeMessage: some View {
        if let noticeMessage = voiceInput.noticeMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                Text(noticeMessage)
                    .lineLimit(2)
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    var pendingApprovalAction: some View {
        if !sessionStore.isSelectedSessionObserving,
           let session = sessionStore.selectedSession,
           let approval = session.pendingApproval {
            PendingApprovalActionCard(
                approval: approval,
                runtimePresentation: SessionRuntimePresentation(session: session),
                isSendingDecision: sessionStore.isApprovalDecisionPending(approval),
                onDecision: { decision in
                    sessionStore.decideApproval(approval, decision: decision)
                }
            )
        }
    }

    @ViewBuilder
    var pendingUserInputAction: some View {
        if !sessionStore.isSelectedSessionObserving,
           let session = sessionStore.selectedSession,
           let request = session.pendingUserInput {
            let runtimePresentation = SessionRuntimePresentation(session: session)
            if isPhoneComposer {
                PendingUserInputResumeButton(
                    request: request,
                    runtimePresentation: runtimePresentation,
                    isSubmitting: sessionStore.isUserInputResponsePending(request),
                    action: { presentPendingUserInputSheet(request) }
                )
            } else {
                PendingUserInputActionCard(
                    request: request,
                    runtimePresentation: runtimePresentation,
                    isSubmitting: sessionStore.isUserInputResponsePending(request),
                    draft: pendingUserInputDraftBinding,
                    onSubmit: { answers in
                        sessionStore.respondToUserInput(request, answers: answers)
                    }
                )
                .id(PendingUserInputPresentation.id(for: request))
            }
        }
    }

    var pendingUserInputSelectionIdentity: PendingUserInputSelectionIdentity {
        let requestPresentationID = sessionStore.selectedSession?.pendingUserInput.map {
            PendingUserInputPresentation.id(for: $0)
        }
        return PendingUserInputSelectionIdentity(
            sessionID: sessionStore.selectedSessionID,
            requestPresentationID: requestPresentationID
        )
    }

    var pendingUserInputDraftBinding: Binding<PendingUserInputDraft> {
        Binding(
            get: { pendingUserInputFormState.draft },
            set: { draft in
                pendingUserInputFormState.draft = draft
                persistPendingUserInputFormState()
            }
        )
    }

    func restorePendingUserInputFormStateFromCache() {
        pendingUserInputFormState = sessionStore.pendingUserInputFormStateCache
    }

    func persistPendingUserInputFormState() {
        sessionStore.pendingUserInputFormStateCache = pendingUserInputFormState
    }

    func synchronizePendingUserInputPresentation(
        previous: PendingUserInputSelectionIdentity?,
        current: PendingUserInputSelectionIdentity
    ) {
        if pendingUserInputFormState.resetIfSessionChanged(
            from: previous?.sessionID,
            to: current.sessionID
        ) {
            // 会话切换意味着表单语境已经变化，旧选择不能带入另一条 thread。
            persistPendingUserInputFormState()
            presentedPendingUserInput = nil
        }

        guard !sessionStore.isSelectedSessionObserving,
              let request = sessionStore.selectedSession?.pendingUserInput
        else {
            // 乐观提交会暂时移除请求。保留 draft 和 identity，异步失败恢复同一请求时
            // 可以自动重开并继续填写；真正的新请求会在下面按新 identity 重置。
            presentedPendingUserInput = nil
            return
        }

        guard let session = sessionStore.selectedSession else {
            return
        }
        let presentation = PendingUserInputPresentation(
            request: request,
            runtimePresentation: SessionRuntimePresentation(session: session)
        )
        guard presentation.id == current.requestPresentationID else {
            return
        }
        pendingUserInputFormState.activate(presentation.id)
        persistPendingUserInputFormState()
        if isPhoneComposer {
            presentedPendingUserInput = presentation
        }
    }

    func presentPendingUserInputSheet(_ request: AgentUserInputRequest) {
        guard let session = sessionStore.selectedSession else {
            return
        }
        let presentation = PendingUserInputPresentation(
            request: request,
            runtimePresentation: SessionRuntimePresentation(session: session)
        )
        pendingUserInputFormState.activate(presentation.id)
        persistPendingUserInputFormState()
        presentedPendingUserInput = presentation
    }

    @ViewBuilder
    func sendButton(showLabels: Bool) -> some View {
        Group {
            if primaryComposerAction == .stopCurrentReply {
                stopCurrentReplyButton
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            } else {
                submitDraftButton(showLabels: showLabels)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .animation(composerMotionAnimation, value: primaryComposerAction)
    }

    func submitDraftButton(showLabels: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isGoalMode = composerState.isGoalModeSelected
        let isPlanMode = composerState.isPlanModeSelected
        let isGuidedFollowUp = !isGoalMode && !isPlanMode && canUseGuidedFollowUp && guidedFollowUpEnabled
        let title: String
        if composerState.voiceDraftNeedsReview {
            title = isGoalMode ? L10n.text("ui.confirm_target") : isPlanMode ? L10n.text("ui.confirm_plan") : isGuidedFollowUp ? L10n.text("ui.confirm_boot") : L10n.text("ui.confirm_sending")
        } else {
            title = isGoalMode ? L10n.text("ui.send_target") : isPlanMode ? L10n.text("ui.generate_plan") : isGuidedFollowUp ? L10n.text("ui.guide") : L10n.text("ui.send")
        }
        let usesPhonePrimaryStyle = isPhoneComposer && !showLabels
        let standardSendSymbol = usesPhonePrimaryStyle ? "arrow.up" : "paperplane.fill"
        let symbol = composerState.voiceDraftNeedsReview ? "checkmark.circle.fill" : (isGoalMode ? "target" : isPlanMode ? "list.clipboard" : isGuidedFollowUp ? "text.bubble.fill" : standardSendSymbol)
        let enabled = canSubmitDraft
        let cornerRadius: CGFloat = showLabels ? 12 : 22
        let surfaceInset: CGFloat = usesPhonePrimaryStyle ? 2 : 4
        let foreground: Color = enabled
            ? tokens.primaryActionForeground
            : (usesPhonePrimaryStyle ? tokens.composerInactiveActionForeground : tokens.tertiaryText)
        let fill: Color = enabled
            ? tokens.primaryAction
            : (usesPhonePrimaryStyle ? tokens.composerInactiveActionSurface : .clear)

        // 自绘成与“按住说话”同高同圆角的实心主按钮，让语音/发送成为右侧一组协调的主操作，
        // 而不是一个系统 prominent 小按钮配一个自定义大胶囊那种割裂感。
        return Button {
            submitDraft()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(
                        themeStore.uiFont(
                            size: usesPhonePrimaryStyle ? 17 : 16,
                            weight: usesPhonePrimaryStyle ? .semibold : .bold
                        )
                    )
                if showLabels {
                    Text(title)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .frame(height: 44)
            .padding(.horizontal, showLabels ? 18 : 0)
            .frame(minWidth: 44)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .padding(surfaceInset)
            }
            .modifier(
                ComposerFlatControlSurface(
                    tokens: tokens,
                    cornerRadius: cornerRadius,
                    isEmphasized: enabled || usesPhonePrimaryStyle,
                    surfaceInset: surfaceInset,
                    usesNeutralControlSurface: usesPhonePrimaryStyle
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!enabled)
        .accessibilityLabel(isGoalMode ? L10n.text("ui.send_target_task") : (composerState.voiceDraftNeedsReview ? L10n.text("ui.confirm_sending_voice_draft") : L10n.text("ui.send")))
        .accessibilityIdentifier("composer.send")
    }

    var stopCurrentReplyButton: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Button {
            sessionStore.interruptSelectedTurn()
        } label: {
            ZStack {
                Circle()
                    .fill(tokens.primaryText)
                    .frame(width: 36, height: 36)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(tokens.inputBackground)
                    .frame(width: 11, height: 11)
            }
            // 视觉尺寸与 Mac Codex 接近，同时保留 Apple 平台要求的 44pt 触控区域。
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(!canInterruptSelectedSession)
        .opacity(canInterruptSelectedSession ? 1 : 0.52)
        .accessibilityLabel(L10n.text("ui.stop_current_reply"))
        .accessibilityHint(L10n.text("ui.stop_current_reply_hint"))
        .accessibilityIdentifier("composer.stopCurrentReply")
    }

    var permissionTitle: String {
        if composerState.turnOptions.preservesThreadPermissionSettings,
           activePermissionProfile == nil {
            return L10n.text("ui.follow_the_current_thread_permissions")
        }
        if let profileID = selectedPermissionProfileID {
            return activePermissionProfile.map {
                L10n.format("ui.current_turn_permission_value", $0.id)
            } ?? L10n.format("ui.next_turn_permission_value", profileID)
        }
        return "\(composerState.permissionMode.title) · \(composerState.turnOptions.sandboxMode.title)"
    }

    var permissionTint: Color {
        if selectedPermissionProfileID != nil {
            return themeStore.tokens(for: colorScheme).accent
        }
        switch composerState.permissionMode {
        case .requestApproval:
            return themeStore.tokens(for: colorScheme).accent
        case .readOnly:
            return .secondary
        case .autoApprove:
            return themeStore.tokens(for: colorScheme).success
        case .fullAccess:
            return .red
        }
    }

    var composerMinHeight: CGFloat {
        ComposerTextLayoutPolicy.minimumHeight(
            isPhone: isPhoneComposer,
            usesCompactMetrics: usesCompactComposerMetrics,
            fontLineHeight: composerUIFont.lineHeight
        )
    }

    var composerMaxHeight: CGFloat {
        ComposerTextLayoutPolicy.maximumHeight(
            isPhone: isPhoneComposer,
            usesCompactMetrics: usesCompactComposerMetrics,
            fontLineHeight: composerUIFont.lineHeight
        )
    }

    var composerTextHeight: CGFloat {
        if usesCollapsedComposerTextHeight {
            return composerMinHeight
        }
        let measured = measuredComposerTextHeight > 0 ? measuredComposerTextHeight : composerMinHeight
        return min(max(measured, composerMinHeight), composerMaxHeight)
    }

    var usesCollapsedComposerTextHeight: Bool {
        // 清空草稿时忽略 UIKit 上一次测得的长文本高度，立即回到稳定的起始画布。
        composerState.isEmpty && !composerState.voiceDraftNeedsReview
    }

    var composerCardPadding: CGFloat {
        usesCompactComposerMetrics ? 12 : 14
    }

    var composerCardSpacing: CGFloat {
        12
    }

    var composerUIFont: UIFont {
        let size = themeStore.scaledFontSize(17)
        let base = UIFont.systemFont(ofSize: size)
        let design: UIFontDescriptor.SystemDesign
        switch themeStore.uiFontPreset {
        case .system:
            design = .default
        case .rounded:
            design = .rounded
        case .serif:
            design = .serif
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    func beginHoldToTalk() {
        guard !isVoicePressActive &&
            !voiceInput.isPreparing &&
            !voiceInput.isRecording &&
            !isVoiceTranscribing &&
            voiceTranscriptionTask == nil
        else {
            return
        }
        clearVoiceTransientStatus()
        isVoicePressActive = true
        composerState.beginVoiceInput()
        let context = VoiceTranscriptionContext(sessionID: sessionStore.selectedSessionID)
        activeVoiceTranscriptionContext = context
        if selectedVoiceInputProvider == .apple, #available(iOS 26.0, *) {
            voiceInput.startAppleTranscription(
                locale: .autoupdatingCurrent,
                onTranscript: { transcript in
                    guard isVoiceTranscriptionContextCurrent(context) else { return }
                    composerState.applyRealtimeVoiceTranscript(transcript)
                },
                onFinish: {
                    isVoicePressActive = false
                    isVoiceTranscribing = false
                    if activeVoiceTranscriptionContext == context {
                        activeVoiceTranscriptionContext = nil
                    }
                    composerState.endVoiceInput()
                }
            )
            return
        }
        voiceInput.start { recording in
            isVoicePressActive = false
            guard let recording else {
                if activeVoiceTranscriptionContext == context {
                    activeVoiceTranscriptionContext = nil
                }
                composerState.endVoiceInput()
                return
            }
            guard isVoiceTranscriptionContextCurrent(context) else {
                try? FileManager.default.removeItem(at: recording.fileURL)
                composerState.endVoiceInput()
                return
            }
            voiceTranscriptionTask = Task {
                await transcribeVoiceRecording(recording, context: context)
            }
        }
    }

    func endHoldToTalk() {
        guard isVoicePressActive || voiceInput.isPreparing || voiceInput.isRecording else {
            return
        }
        let releasedBeforeRecording = voiceInput.isPreparing && !voiceInput.isRecording
        isVoicePressActive = false
        if releasedBeforeRecording {
            // 点按模式下第二次点按发生在权限/录音准备期间，按取消处理，避免空录音进入转写。
            voiceInput.cancel()
            activeVoiceTranscriptionContext = nil
            composerState.endVoiceInput()
            return
        }
        if selectedVoiceInputProvider == .apple, #available(iOS 26.0, *) {
            // Apple 在录音过程中已持续写入草稿；停止后只等待最后一个稳定结果。
            isVoiceTranscribing = true
        }
        voiceInput.stop()
    }

    func toggleVoiceInput() {
        switch VoiceInputToggleAction.resolve(
            isPressActive: isVoicePressActive,
            isPreparing: voiceInput.isPreparing,
            isRecording: voiceInput.isRecording,
            isTranscribing: isVoiceTranscribing
        ) {
        case .start:
            beginHoldToTalk()
        case .end:
            endHoldToTalk()
        case .ignore:
            break
        }
    }

    func toggleVoiceInputFromKeyboard() {
        toggleVoiceInput()
    }

    @MainActor
    func clearVoiceTransientStatus() {
        retryableVoiceTranscription = nil
        voiceInput.setErrorMessage(nil)
        voiceInput.setNoticeMessage(nil)
    }

    @MainActor
    func cancelVoiceInteraction(clearStatus: Bool) {
        // 切会话、离开页面或发送草稿时取消当前录音/转写；旧请求即使晚返回，也不能写入新会话的输入框。
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = nil
        activeVoiceTranscriptionContext = nil
        if isVoicePressActive || voiceInput.isPreparing || voiceInput.isRecording || isVoiceTranscribing {
            voiceInput.cancel()
        }
        isVoicePressActive = false
        isVoiceTranscribing = false
        composerState.endVoiceInput()
        if clearStatus {
            clearVoiceTransientStatus()
        }
    }

    func isVoiceTranscriptionContextCurrent(_ context: VoiceTranscriptionContext) -> Bool {
        activeVoiceTranscriptionContext == context && sessionStore.selectedSessionID == context.sessionID
    }

    @MainActor
    func autoDismissVoiceErrorIfNeeded(_ message: String?) async {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let delay = voiceErrorAutoDismissDelaySeconds(for: message)
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        guard !Task.isCancelled,
              voiceInput.errorMessage == message,
              !isVoiceTranscribing else {
            return
        }
        clearVoiceTransientStatus()
    }

    func voiceErrorAutoDismissDelaySeconds(for message: String) -> UInt64 {
        if let retryAfter = Self.retryAfterSeconds(from: message) {
            // 429/临时不可用会给出 retry-after；提示至少保留到可重试窗口之后，
            // 但也设上限，避免底部红条永久占位。
            return UInt64(min(max(retryAfter + 5, 12), 45))
        }
        return 12
    }

    @MainActor
    func transcribeVoiceRecording(
        _ recording: VoiceRecordingResult,
        context: VoiceTranscriptionContext
    ) async {
        guard isVoiceTranscriptionContextCurrent(context) else {
            try? FileManager.default.removeItem(at: recording.fileURL)
            return
        }
        isVoiceTranscribing = true
        retryableVoiceTranscription = nil
        voiceInput.setErrorMessage(nil)
        var retryCandidate: RetryableVoiceTranscription?
        defer {
            if isVoiceTranscriptionContextCurrent(context) {
                isVoiceTranscribing = false
                activeVoiceTranscriptionContext = nil
                voiceTranscriptionTask = nil
                composerState.endVoiceInput()
            }
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        do {
            async let dataTask = Self.voiceRecordingData(recording.fileURL)
            async let durationTask = Self.safeVoiceRecordingDuration(recording.fileURL)
            let data = try await dataTask
            let assetDuration = await durationTask
            try Task.checkCancellation()
            guard isVoiceTranscriptionContextCurrent(context) else {
                return
            }
            let usableDuration = max(recording.recordedDuration, assetDuration)
            if data.count < 1_024 || usableDuration < Self.minimumUsableVoiceDuration {
                voiceInput.setErrorMessage(shortVoiceRecordingMessage(recording: recording, usableDuration: usableDuration))
                return
            }
            retryCandidate = RetryableVoiceTranscription(
                filename: recording.fileURL.lastPathComponent,
                contentType: "audio/mp4",
                audioData: data,
                recordedDuration: usableDuration,
                pressDuration: recording.pressDuration,
                sessionID: context.sessionID
            )
            let response = try await sessionStore.transcribeVoice(
                filename: recording.fileURL.lastPathComponent,
                contentType: "audio/mp4",
                audioData: data,
                language: VoiceTranscriptionDefaults.languageCode
            )
            try Task.checkCancellation()
            guard isVoiceTranscriptionContextCurrent(context) else {
                return
            }
            composerState.applyVoiceTranscript(response.text)
            retryableVoiceTranscription = nil
        } catch is CancellationError {
            retryableVoiceTranscription = nil
        } catch {
            voiceInput.setErrorMessage(userFacingVoiceTranscriptionError(error, recording: recording))
            if let retryCandidate, Self.isRetryableVoiceTranscriptionError(error) {
                // 临时上游错误时保留这次录音的内存副本，用户点一次即可重发；
                // 成功、录音过短、权限错误等场景不保留，避免错误按钮误导用户。
                retryableVoiceTranscription = retryCandidate
            } else {
                retryableVoiceTranscription = nil
            }
        }
    }

    func retryVoiceTranscription() {
        guard let retryableVoiceTranscription, !isVoiceTranscribing, voiceTranscriptionTask == nil else {
            return
        }
        guard retryableVoiceTranscription.sessionID == sessionStore.selectedSessionID else {
            self.retryableVoiceTranscription = nil
            voiceInput.setErrorMessage(L10n.text("ui.the_session_has_been_switched_please_record_again"))
            return
        }
        let context = VoiceTranscriptionContext(sessionID: retryableVoiceTranscription.sessionID)
        activeVoiceTranscriptionContext = context
        voiceTranscriptionTask = Task {
            await transcribeCachedVoiceRecording(retryableVoiceTranscription, context: context)
        }
    }

    @MainActor
    func transcribeCachedVoiceRecording(_ cached: RetryableVoiceTranscription, context: VoiceTranscriptionContext) async {
        guard isVoiceTranscriptionContextCurrent(context) else {
            return
        }
        isVoiceTranscribing = true
        composerState.beginVoiceInput()
        voiceInput.setErrorMessage(nil)
        defer {
            if isVoiceTranscriptionContextCurrent(context) {
                isVoiceTranscribing = false
                activeVoiceTranscriptionContext = nil
                voiceTranscriptionTask = nil
                composerState.endVoiceInput()
            }
        }
        do {
            let response = try await sessionStore.transcribeVoice(
                filename: cached.filename,
                contentType: cached.contentType,
                audioData: cached.audioData,
                language: VoiceTranscriptionDefaults.languageCode
            )
            try Task.checkCancellation()
            guard isVoiceTranscriptionContextCurrent(context) else {
                return
            }
            composerState.applyVoiceTranscript(response.text)
            if retryableVoiceTranscription?.id == cached.id {
                retryableVoiceTranscription = nil
            }
            voiceInput.setNoticeMessage(L10n.text("ui.the_voice_has_been_re_transcribed_please_confirm"))
        } catch is CancellationError {
            if retryableVoiceTranscription?.id == cached.id {
                retryableVoiceTranscription = nil
            }
        } catch {
            voiceInput.setErrorMessage(userFacingVoiceTranscriptionError(error))
            if Self.isRetryableVoiceTranscriptionError(error) {
                retryableVoiceTranscription = cached
            } else if retryableVoiceTranscription?.id == cached.id {
                retryableVoiceTranscription = nil
            }
        }
    }

    nonisolated static func voiceRecordingData(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    nonisolated static func safeVoiceRecordingDuration(_ url: URL) async -> TimeInterval {
        (try? await voiceRecordingDuration(url)) ?? 0
    }

    func shortVoiceRecordingMessage(recording: VoiceRecordingResult, usableDuration: TimeInterval) -> String {
        // 区分“用户真的很快松手”和“按住了但录音器实际采样很短”，避免把启动延迟误报成没按够 1 秒。
        if recording.pressDuration >= 0.9 && usableDuration < Self.minimumUsableVoiceDuration {
            return L10n.text("ui.the_microphone_starts_slowly_the_sound_just_recorded")
        }
        return L10n.text("ui.the_press_is_a_bit_short_please_hold")
    }

    nonisolated static func voiceRecordingDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    func userFacingVoiceTranscriptionError(_ error: Error, recording: VoiceRecordingResult? = nil) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return L10n.text("ui.voice_transcription_failed_please_try_again_later")
        }
        if message.contains("没有识别到语音内容") || message.contains("按住说话至少 1 秒") {
            if let recording, recording.pressDuration >= 0.9 {
                return L10n.text("ui.no_clear_voice_is_recognized_please_move_closer")
            }
            return L10n.text("ui.no_clear_voice_was_recognized_please_hold_down")
        }
        if Self.isTemporaryUnavailableVoiceErrorMessage(message) {
            if let seconds = Self.retryAfterSeconds(from: message) {
                return L10n.plural("ui.speech_retry_seconds_count", count: seconds)
            }
            return L10n.text("ui.speech_transcription_is_currently_unavailable_please_try_again_9e0e4eee")
        }
        if Self.isTimeoutVoiceErrorMessage(message) {
            return L10n.text("ui.the_speech_transcription_request_timed_out_please_try")
        }
        return L10n.format("ui.speech_transcription_failed", message)
    }

    nonisolated static func isRetryableVoiceTranscriptionError(_ error: Error) -> Bool {
        if let apiError = error as? AgentAPIError,
           case AgentAPIError.server(let status, let message) = apiError {
            if isNonRetryableVoiceErrorMessage(message) {
                return false
            }
            if status == 408 || status == 429 {
                return true
            }
            if status == 500 || status == 502 || status == 503 || status == 504 {
                return true
            }
            return isTemporaryUnavailableVoiceErrorMessage(message) || isTimeoutVoiceErrorMessage(message)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                break
            }
        }
        let message = error.localizedDescription
        if isNonRetryableVoiceErrorMessage(message) {
            return false
        }
        return isTemporaryUnavailableVoiceErrorMessage(message) || isTimeoutVoiceErrorMessage(message)
    }

    nonisolated static func isNonRetryableVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("codex login")
            || message.contains("登录态已失效")
            || message.contains("麦克风权限")
            || message.contains("没有识别到语音内容")
            || message.contains("按住说话至少")
    }

    nonisolated static func isTemporaryUnavailableVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("http 429")
            || lower.contains("429")
            || lower.contains("temporarily unavailable")
            || lower.contains("retry_after")
            || lower.contains("rate limit")
            || lower.contains("try again")
            || message.contains("暂不可用")
            || message.contains("稍后重试")
    }

    nonisolated static func isTimeoutVoiceErrorMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || message.contains("超时")
    }

    nonisolated static func retryAfterSeconds(from message: String) -> Int? {
        let patterns = [
            #""retry_after_seconds"\s*:\s*(\d+)"#,
            #"请\s*(\d+)\s*秒后重试"#
        ]
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            guard let match = regex.firstMatch(in: message, range: range),
                  let secondsRange = Range(match.range(at: 1), in: message),
                  let seconds = Int(message[secondsRange]) else {
                continue
            }
            return seconds
        }
        return nil
    }

    func presentPhotoLibraryPicker() {
        let targetScope = activeComposerDraftScope
        guard targetScope != .none else {
            attachmentErrorMessage = L10n.text("ui.select_a_workspace_before_adding_files")
            showsAddContentPanel = false
            return
        }
        let availableCount = remainingImageAttachmentCapacity(for: targetScope)
        guard availableCount > 0 else {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            showsAddContentPanel = false
            return
        }

        pendingAddContentAction = .photos(
            targetScope: targetScope,
            selectionLimit: availableCount
        )
        showsAddContentPanel = false
    }

    func presentCameraAttachmentPicker() {
        let targetScope = activeComposerDraftScope
        guard targetScope != .none else {
            attachmentErrorMessage = L10n.text("ui.select_a_workspace_before_adding_files")
            showsAddContentPanel = false
            return
        }
        guard remainingImageAttachmentCapacity(for: targetScope) > 0 else {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            showsAddContentPanel = false
            return
        }

        pendingAddContentAction = .camera(targetScope: targetScope)
        showsAddContentPanel = false
    }

    func presentFileImporter() {
        let targetScope = activeComposerDraftScope
        guard targetScope != .none else {
            attachmentErrorMessage = L10n.text("ui.select_a_workspace_before_adding_files")
            showsAddContentPanel = false
            return
        }
        guard !hasFileAttachment(for: targetScope),
              sessionStore.fileUploadStore.jobs(for: targetScope).isEmpty
        else {
            attachmentErrorMessage = L10n.text("ui.only_one_file_can_be_added_to_each_message")
            showsAddContentPanel = false
            return
        }
        pendingAddContentAction = .files(targetScope: targetScope)
        showsAddContentPanel = false
    }

    @MainActor
    func consumePendingAddContentAction() {
        guard let action = pendingAddContentAction,
              photoLibraryPickerRequest == nil,
              cameraAttachmentPickerRequest == nil,
              cameraAttachmentAccessIssue == nil,
              !fileImporterPresentation.isPresented,
              !isRequestingCameraAuthorization
        else {
            return
        }
        pendingAddContentAction = nil
        switch action {
        case .camera(let targetScope):
            beginCameraAttachmentCapture(for: targetScope)
        case .photos(let targetScope, let selectionLimit):
            photoLibraryPickerRequest = PhotoLibraryPickerRequest(
                selectionLimit: selectionLimit,
                targetScope: targetScope
            )
        case .files(let targetScope):
            Task {
                let decision = await sessionStore.appStore.refreshCapabilityNegotiationForCurrentHost(
                    capability: "file_upload_v1"
                )
                guard !Task.isCancelled else {
                    return
                }
                guard let capabilityLease = sessionStore.appStore.capabilityLease(
                    for: "file_upload_v1"
                ) else {
                    attachmentErrorMessage = MobileFileUploadError(decision: decision).localizedDescription
                    return
                }
                fileImporterPresentation.present(
                    FileImporterRequest(
                        targetScope: targetScope,
                        capabilityLease: capabilityLease
                    )
                )
            }
        }
    }

    @MainActor
    func beginCameraAttachmentCapture(for targetScope: ComposerDraftScopeKey) {
        guard targetScope != .none,
              remainingImageAttachmentCapacity(for: targetScope) > 0
        else {
            attachmentErrorMessage = targetScope == .none
                ? L10n.text("ui.select_a_workspace_before_adding_files")
                : L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            return
        }

        switch CameraAttachmentAccess.currentAvailability {
        case .ready:
            cameraAttachmentPickerRequest = CameraAttachmentPickerRequest(targetScope: targetScope)
        case .needsAuthorization:
            requestCameraAttachmentAuthorization(for: targetScope)
        case .denied:
            cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                kind: .denied,
                targetScope: targetScope
            )
        case .restricted:
            cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                kind: .restricted,
                targetScope: targetScope
            )
        case .unavailable:
            cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                kind: .unavailable,
                targetScope: targetScope
            )
        }
    }

    @MainActor
    func requestCameraAttachmentAuthorization(for targetScope: ComposerDraftScopeKey) {
        guard !isRequestingCameraAuthorization else {
            return
        }
        isRequestingCameraAuthorization = true

        Task { @MainActor in
            _ = await CameraAttachmentAccess.requestAccess()
            // TCC 的回调会早于权限弹窗完全退场；等待系统过渡结束后再呈现全屏相机。
            try? await Task.sleep(for: .milliseconds(550))
            isRequestingCameraAuthorization = false

            guard photoLibraryPickerRequest == nil,
                  cameraAttachmentPickerRequest == nil,
                  cameraAttachmentAccessIssue == nil,
                  !fileImporterPresentation.isPresented
            else {
                return
            }

            switch CameraAttachmentAccess.currentAvailability {
            case .ready:
                cameraAttachmentPickerRequest = CameraAttachmentPickerRequest(targetScope: targetScope)
            case .denied, .needsAuthorization:
                cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                    kind: .denied,
                    targetScope: targetScope
                )
            case .restricted:
                cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                    kind: .restricted,
                    targetScope: targetScope
                )
            case .unavailable:
                cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                    kind: .unavailable,
                    targetScope: targetScope
                )
            }
        }
    }

    @MainActor
    func handleCameraAttachmentCapture(
        _ result: Result<Data?, Error>,
        targetScope: ComposerDraftScopeKey
    ) {
        cameraAttachmentPickerRequest = nil

        switch result {
        case .success(nil):
            return
        case .failure(let error):
            attachmentErrorMessage = userFacingAttachmentError(error)
        case .success(.some(let data)):
            Task {
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentEncoder.prepare(data)
                    }.value
                    let input = CodexAppServerUserInput.image(url: prepared.dataURL, detail: .auto)
                    let addedCount = addPreparedImageAttachments([input], to: targetScope)
                    updateBatchAttachmentNotice(
                        addedCount: addedCount,
                        failedCount: 0,
                        skippedCount: max(0, 1 - addedCount),
                        firstError: nil
                    )
                } catch {
                    attachmentErrorMessage = userFacingAttachmentError(error)
                }
            }
        }
    }

    @MainActor
    func choosePhotosAfterCameraIssue(_ issue: CameraAttachmentAccessIssue) {
        cameraAttachmentAccessIssue = nil

        Task { @MainActor in
            // confirmationDialog 仍在执行关闭动画；稍后再交给 PHPicker，避免 presenter 冲突。
            try? await Task.sleep(for: .milliseconds(350))
            guard photoLibraryPickerRequest == nil,
                  cameraAttachmentPickerRequest == nil,
                  !fileImporterPresentation.isPresented
            else {
                return
            }

            let availableCount = remainingImageAttachmentCapacity(for: issue.targetScope)
            guard issue.targetScope != .none, availableCount > 0 else {
                attachmentErrorMessage = issue.targetScope == .none
                    ? L10n.text("ui.select_a_workspace_before_adding_files")
                    : L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
                return
            }
            photoLibraryPickerRequest = PhotoLibraryPickerRequest(
                selectionLimit: availableCount,
                targetScope: issue.targetScope
            )
        }
    }

    @MainActor
    func openCameraPrivacySettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    func handleSelectedFile(
        _ result: Result<[URL], Error>,
        request: FileImporterRequest
    ) {
        switch result {
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else {
                return
            }
            attachmentErrorMessage = error.localizedDescription
        case .success(let urls):
            guard sessionStore.appStore.isCurrentCapabilityLease(request.capabilityLease) else {
                attachmentErrorMessage = MobileFileUploadError.hostChanged.localizedDescription
                return
            }
            guard let url = urls.first else {
                return
            }
            guard FileAttachmentPreparer.isSupportedFilename(url.lastPathComponent) else {
                attachmentErrorMessage = L10n.text("ui.only_pdf_text_and_source_files_are_supported")
                return
            }
            attachmentErrorMessage = nil
            sessionStore.fileUploadStore.start(
                selectedURL: url,
                targetScope: request.targetScope,
                endpoint: sessionStore.appStore.connectionEndpoint,
                token: sessionStore.appStore.token
            ) { [weak sessionStore] attachment, scope in
                sessionStore?.storeCompletedFileUpload(attachment, for: scope)
            }
        }
    }

    func hasFileAttachment(for scope: ComposerDraftScopeKey) -> Bool {
        func containsFile(_ attachments: [CodexAppServerUserInput]) -> Bool {
            attachments.contains { input in
                if case .uploadedFile = input {
                    return true
                }
                return false
            }
        }
        // 上传完成时 SessionStore 会先写稳定草稿，再发布 completion 给当前 View。
        // 同时检查两处可关闭这一个发布帧内再次选择第二个文件的竞态。
        if scope == activeComposerDraftScope, containsFile(composerState.attachments) {
            return true
        }
        return containsFile(sessionStore.composerDraft(for: scope).attachments)
    }

    func loadPhotoAttachments(
        _ results: [PHPickerResult],
        targetScope: ComposerDraftScopeKey
    ) {
        let availableCount = remainingImageAttachmentCapacity(for: targetScope)
        let selectedResults = Array(results.prefix(availableCount))
        let skippedCount = max(0, results.count - selectedResults.count)
        guard !selectedResults.isEmpty else {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            return
        }

        Task {
            var preparedInputs: [CodexAppServerUserInput] = []
            var failedCount = 0
            var firstError: Error?

            // 串行读取和下采样，避免多张 iPad 截图同时完整解码造成瞬时内存峰值。
            for result in selectedResults {
                do {
                    let data = try await Self.loadImageData(from: result.itemProvider)
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentEncoder.prepare(data)
                    }.value
                    preparedInputs.append(.image(url: prepared.dataURL, detail: .auto))
                } catch {
                    failedCount += 1
                    firstError = firstError ?? error
                }
            }

            let addedCount = addPreparedImageAttachments(preparedInputs, to: targetScope)
            updateBatchAttachmentNotice(
                addedCount: addedCount,
                failedCount: failedCount,
                skippedCount: skippedCount + max(0, preparedInputs.count - addedCount),
                firstError: firstError
            )
        }
    }

    static func loadImageData(from provider: NSItemProvider) async throws -> Data {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            throw PhotoLibraryPickerError.unsupportedImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotoLibraryPickerError.unreadableImage)
                }
            }
        }
    }

    @MainActor
    func addPreparedImageAttachments(
        _ inputs: [CodexAppServerUserInput],
        to targetScope: ComposerDraftScopeKey
    ) -> Int {
        guard targetScope != .none, !inputs.isEmpty else {
            return 0
        }

        if targetScope == activeComposerDraftScope {
            let allowed = Array(inputs.prefix(remainingImageAttachmentCapacity(in: composerState.attachments)))
            composerState.attachments.append(contentsOf: allowed)
            // 异步图片任务可能在旧 ComposerView 已消失后才完成，必须直接写稳定仓，不能只依赖 onChange。
            sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: targetScope)
            return allowed.count
        }

        // 图片处理期间如果用户切了会话，结果仍写回发起选择时的草稿，不能串到当前会话。
        var snapshot = sessionStore.composerDraft(for: targetScope)
        let allowed = Array(inputs.prefix(remainingImageAttachmentCapacity(in: snapshot.attachments)))
        snapshot.attachments.append(contentsOf: allowed)
        sessionStore.saveComposerDraft(snapshot, for: targetScope)
        return allowed.count
    }

    func remainingImageAttachmentCapacity(for scope: ComposerDraftScopeKey) -> Int {
        if scope == activeComposerDraftScope {
            return remainingImageAttachmentCapacity(in: composerState.attachments)
        }
        return remainingImageAttachmentCapacity(in: sessionStore.composerDraft(for: scope).attachments)
    }

    func remainingImageAttachmentCapacity(in attachments: [CodexAppServerUserInput]) -> Int {
        let imageCount = attachments.reduce(into: 0) { count, input in
            switch input {
            case .image, .localImage:
                count += 1
            case .text, .uploadedFile, .skill, .mention:
                break
            }
        }
        return max(0, Self.maximumImageAttachmentCount - imageCount)
    }

    @MainActor
    func updateBatchAttachmentNotice(
        addedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        firstError: Error?
    ) {
        if failedCount == 0, skippedCount == 0 {
            attachmentErrorMessage = nil
        } else if addedCount > 0 {
            let omitted = failedCount + skippedCount
            attachmentErrorMessage = L10n.format("ui.pictures_have_been_added_and_have_not_been", addedCount, omitted)
        } else if skippedCount > 0, failedCount == 0 {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
        } else if let firstError {
            attachmentErrorMessage = userFacingAttachmentError(firstError)
        } else {
            attachmentErrorMessage = L10n.text("ui.image_reading_failed")
        }
    }

    func canPreviewAttachment(_ item: CodexAppServerUserInput) -> Bool {
        switch item {
        case .image, .localImage, .uploadedFile:
            return true
        case .text, .skill, .mention:
            return false
        }
    }

    func userFacingAttachmentError(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L10n.text("ui.image_reading_failed") : L10n.format("ui.image_reading_failed_20ce920a", message)
    }

    func attachmentSymbol(for item: CodexAppServerUserInput) -> String {
        switch item {
        case .image, .localImage:
            return "photo"
        case .uploadedFile:
            return "doc"
        case .skill:
            return "wand.and.stars"
        case .mention:
            return "at"
        case .text:
            return "text.alignleft"
        }
    }
}

enum VoiceInputToggleAction: Equatable {
    case start
    case end
    case ignore

    static func resolve(
        isPressActive: Bool,
        isPreparing: Bool,
        isRecording: Bool,
        isTranscribing: Bool
    ) -> Self {
        if isTranscribing {
            return .ignore
        }
        if isPressActive || isPreparing || isRecording {
            return .end
        }
        return .start
    }
}

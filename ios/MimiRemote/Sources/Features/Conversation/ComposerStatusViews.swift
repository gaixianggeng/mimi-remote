import SwiftUI

struct QueuedTurnEditorDraft: Identifiable {
    let id: ClientMessageID
    let turn: QueuedTurnEntry
    let text: String
    let attachments: [CodexAppServerUserInput]

    init(turn: QueuedTurnEntry) {
        self.id = turn.id
        self.turn = turn
        self.text = turn.payload.textPrompt
        self.attachments = turn.payload.input.filter { input in
            if case .text = input {
                return false
            }
            return true
        }
    }

    func payload(text: String, attachments: [CodexAppServerUserInput]) -> CodexAppServerTurnPayload {
        var input = CodexAppServerTurnPayload.defaultInput(for: text)
        input.append(contentsOf: attachments)
        return CodexAppServerTurnPayload(input: input, options: turn.payload.options)
    }
}

struct QueuedTurnEditorSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let draft: QueuedTurnEditorDraft
    let onSave: (CodexAppServerTurnPayload) -> Void
    @State private var text: String
    @State private var attachments: [CodexAppServerUserInput]

    init(draft: QueuedTurnEditorDraft, onSave: @escaping (CodexAppServerTurnPayload) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _text = State(initialValue: draft.text)
        _attachments = State(initialValue: draft.attachments)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            Form {
                Section(L10n.text("ui.news")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                        .font(themeStore.uiFont(.body))
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(tokens.primaryText)
                }
                if !attachments.isEmpty {
                    Section(L10n.text("ui.accessories")) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, item in
                            HStack(spacing: 10) {
                                Image(systemName: queuedAttachmentIcon(item))
                                    .foregroundStyle(tokens.accent)
                                Text(item.previewText)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    attachments.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.text("ui.delete_attachment"))
                            }
                        }
                    }
                }
                Section {
                    Text(L10n.text("ui.editing_only_affects_the_local_content_to_be"))
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
            .navigationTitle(L10n.text("ui.edit_message_to_send"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.save")) {
                        onSave(draft.payload(text: text, attachments: attachments))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return draft.turn.intent.startsGoal ? hasText : (hasText || !attachments.isEmpty)
    }

    private func queuedAttachmentIcon(_ item: CodexAppServerUserInput) -> String {
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

struct QueuedTurnManagerSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let turns: [QueuedTurnEntry]
    var showsGuideCurrentTurn: Bool = true
    let canGuideCurrentTurn: Bool
    let onUpdate: (QueuedTurnEntry, CodexAppServerTurnPayload) -> Void
    let onDelete: (QueuedTurnEntry) -> Void
    let onRetry: (QueuedTurnEntry) -> Void
    let onGuideNow: (QueuedTurnEntry) -> Void
    let onMove: (IndexSet, Int) -> Void
    @State private var editingTurn: QueuedTurnEditorDraft?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            Group {
                if turns.isEmpty {
                    ContentUnavailableView(L10n.text("ui.no_messages_to_send"), systemImage: "tray")
                } else {
                    List {
                        Section {
                            ForEach(turns) { turn in
                                HStack(spacing: 10) {
                                    Image(systemName: turn.displayIcon)
                                        .foregroundStyle(turn.displayTint(tokens: tokens))
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(turn.previewText.isEmpty ? L10n.text("ui.accessories_only") : turn.previewText)
                                            .lineLimit(2)
                                            .font(themeStore.uiFont(.body, weight: .medium))
                                        Text(turn.displayStatusText)
                                            .font(themeStore.uiFont(.caption))
                                            .foregroundStyle(turn.displayTint(tokens: tokens))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Menu {
                                        Button(L10n.text("ui.edit"), systemImage: "pencil") {
                                            editingTurn = QueuedTurnEditorDraft(turn: turn)
                                        }
                                        .disabled(turn.dispatchState == .dispatching)
                                        if showsGuideCurrentTurn && turn.intent.canGuideCurrentTurn {
                                            Button(L10n.text("ui.direct_current_reply_now"), systemImage: "text.bubble") {
                                                onGuideNow(turn)
                                            }
                                            .disabled(!canGuideCurrentTurn || turn.dispatchState != .waiting)
                                        }
                                        if turn.dispatchState == .needsConfirmation {
                                            Button(L10n.text("ui.confirm_and_try_again"), systemImage: "arrow.clockwise") {
                                                onRetry(turn)
                                            }
                                        }
                                        Divider()
                                        Button(L10n.text("ui.delete"), systemImage: "trash", role: .destructive) {
                                            onDelete(turn)
                                        }
                                        .disabled(turn.dispatchState == .dispatching)
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                }
                            }
                            .onMove(perform: onMove)
                        } footer: {
                            Text(L10n.text("ui.press_and_drag_on_the_right_side_to"))
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("ui.queue_to_be_sent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.complete")) { dismiss() }
                }
                if turns.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        EditButton()
                    }
                }
            }
            .sheet(item: $editingTurn) { draft in
                QueuedTurnEditorSheet(draft: draft) { payload in
                    onUpdate(draft.turn, payload)
                }
                .environmentObject(themeStore)
            }
        }
    }

}

// 待发送条目的图标、色彩和状态文案由 Composer 预览行和管理面板共用，
// 集中在一处避免两侧文案漂移。
extension QueuedTurnEntry {
    var displayIcon: String {
        switch dispatchState {
        case .waiting:
            return intent.startsGoal ? "target" : "clock"
        case .dispatching:
            return "paperplane"
        case .needsConfirmation:
            return "exclamationmark.triangle"
        }
    }

    func displayTint(tokens: ThemeTokens) -> Color {
        switch dispatchState {
        case .waiting:
            return tokens.secondaryText
        case .dispatching:
            return tokens.accent
        case .needsConfirmation:
            return tokens.warning
        }
    }

    var displayStatusText: String {
        switch dispatchState {
        case .waiting:
            if waitsForAcceptedTurnStart == true {
                return L10n.format("ui.confirming_the_status_of_the_previous_round_value", intent.title)
            }
            return expectedTurnID == nil ? L10n.format("ui.send_after_waiting_for_connection_value", intent.title) : L10n.format("ui.sent_after_current_reply_is_complete_value", intent.title)
        case .dispatching:
            return L10n.format("ui.sending_value", intent.title)
        case .needsConfirmation:
            return lastError ?? L10n.text("ui.sending_results_requires_confirmation")
        }
    }
}

enum ComposerStatusTrayMaterialStrength: Equatable {
    case opaque
    /// 全 App 唯一的磨砂档位，见 `WorkbenchMaterial.surface`。
    /// 过去这里按展开/收起分成 thin / regular 两档，结果是同一枚托盘在两个状态下
    /// 是两种质感，展开时还比旁边的输入卡更浓。遮蔽交给 tint，不再换档位。
    case frosted
}

enum ComposerStatusTrayPlacement: Equatable {
    case standalone
    case embedded

    var usesIndependentSurface: Bool {
        self == .standalone
    }

    var expandedContentPadding: CGFloat {
        self == .embedded ? 2 : 10
    }

    var collapsedLeadingPadding: CGFloat {
        self == .embedded ? 0 : 10
    }

    var usesEmbeddedStatusChip: Bool {
        self == .embedded
    }

    /// 内嵌状态栏只占 36pt 的视觉高度；独立托盘沿用 44pt 行高。
    var visualHeight: CGFloat {
        self == .embedded ? 36 : 44
    }

    /// disclosure 的命中框恒为 44×44。它是托盘上的一层 overlay，不参与父布局，
    /// 所以在 36pt 的内嵌状态条上也不会把输入卡撑高。
    var disclosureHitSize: CGSize {
        CGSize(width: 44, height: 44)
    }

    /// 命中框相对托盘顶部的纵向偏移：按钮中心必须落在首行视觉高度的中点，
    /// 收起态和展开态才会是同一个位置。
    ///
    /// 内嵌时 44pt 的命中框比 36pt 的状态条高，上下各溢出 4pt——这 4pt 是真的能点中的：
    /// `ComposerView.phoneComposerCard` 里状态条上方是输入卡自己的 8pt 内距，
    /// 下方是 VStack 的 4pt spacing，溢出落在空白里，没有兄弟视图会先接走点击。
    /// 曾经这里把命中框缩到 36pt 去迁就"渲染事实"，等于白白丢掉这 8pt。
    var disclosureVerticalOffset: CGFloat {
        (visualHeight - disclosureHitSize.height) / 2
    }

    /// disclosure 恒定锚在托盘右上角，收起态和展开态共用同一个内距。
    /// 两态之间箭头不再平移，连点两下就不会第二下落空。
    var disclosureTrailingInset: CGFloat {
        expandedContentPadding
    }

    /// 内容需要为 disclosure 让开的宽度，从内容自身的右边缘算起：命中框 + 一个 8pt 间距。
    var disclosureClearance: CGFloat {
        disclosureHitSize.width + 8
    }
}

struct ComposerStatusTraySurfaceStyle: Equatable {
    let materialStrength: ComposerStatusTrayMaterialStrength
    let surfaceTintOpacity: Double
    let borderOpacity: Double

    /// 只有 `.standalone` 会真正绘制这套表面。iPhone 恒定使用 `.embedded`，
    /// 状态直接长在 Composer 外壳里，材质由 Composer 自身提供，因此这里不需要
    /// 也不应该再有一条 phone 专用分支——那只会让样式看起来被覆盖，实际却渲染不到。
    ///
    /// 同理，这里不再接收展开状态：材质、tint 和描边在两个状态下完全相同，
    /// 留一个不影响任何返回值的参数只会让调用方以为展开态另有一套样式。
    static func resolve(
        scheme: ThemeResolvedScheme,
        reduceTransparency: Bool,
        increasedContrast: Bool = false
    ) -> Self {
        if scheme == .light {
            // 浅色独立托盘使用确定性的暖白实色，保证长状态内容可读。
            return Self(
                materialStrength: .opaque,
                surfaceTintOpacity: 1,
                borderOpacity: increasedContrast ? 0.5 : (reduceTransparency ? 0.08 : 0.05)
            )
        }

        guard !reduceTransparency else {
            return Self(
                materialStrength: .opaque,
                surfaceTintOpacity: 1,
                borderOpacity: 0.58
            )
        }

        // 深色继续保留功能材质；长内容的可读性由 tint 保证，
        // 不再靠阴影、彩色双描边或多层高光制造实体卡片感。
        return Self(
            materialStrength: .frosted,
            surfaceTintOpacity: 0.46,
            borderOpacity: 0.58
        )
    }
}

/// 输入卡顶部内嵌药丸（状态胶囊、模型选择器、模型锁）共用的轻透表面色板。
/// 叠在玻璃输入卡上时使用低透明中性底衬与细描边，避免打出一块实色灰块；开启减少透明度时回退实色。
enum ComposerEmbeddedPillPalette {
    static func fill(
        tokens: ThemeTokens,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Color {
        if reduceTransparency {
            return tokens.elevatedSurface
        }
        let base = tokens.resolvedScheme == .light ? Color.black : Color.white
        if increasedContrast {
            return base.opacity(tokens.resolvedScheme == .light ? 0.10 : 0.14)
        }
        return base.opacity(tokens.resolvedScheme == .light ? 0.045 : 0.085)
    }

    static func border(
        tokens: ThemeTokens,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Color {
        if reduceTransparency {
            return tokens.border.opacity(increasedContrast ? 0.85 : 0.65)
        }
        let base = tokens.resolvedScheme == .light ? Color.black : Color.white
        if increasedContrast {
            return base.opacity(0.24)
        }
        return base.opacity(tokens.resolvedScheme == .light ? 0.09 : 0.14)
    }
}

struct ComposerStatusTray: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let sessionControlNotice: String?
    /// 会话原工作目录已移动或删除时的显式只读原因（C14/C15 round4），首屏直接可见而非藏在折叠/无障碍提示内。
    var missingDirectoryNotice: String? = nil
    /// Claude 会话被 Mac 上的终端 / 桌面版持有。和 Codex 的「仅观察」同处一个位置，
    /// 两者同时存在时由调用方只传这一个，避免同一个只读原因出现两枚 chip。
    var ownershipNotice: SessionOwnershipNotice? = nil
    let quotaNotice: CodexQuotaNotice?
    let usage: CodexUsageDisplaySummary?
    let goal: ThreadGoal?
    let placement: ComposerStatusTrayPlacement
    /// iPhone 内嵌态同排附带的小组件（如模型选择器 / 模型锁药丸）。
    /// 收起态与状态胶囊并排展示；展开详情或缺失目录长横幅时退到下方独立行。
    var inlineAccessory: AnyView? = nil
    let isGoalExpanded: Bool
    let isGoalUpdating: Bool
    let goalErrorMessage: String?
    let isRefreshDisabled: Bool
    let allowsTakeOver: Bool
    let onTakeOver: () -> Void
    /// 接管 Claude 会话会结束 Mac 上的进程，调用方负责二次确认。
    var onTakeOverHeldSession: () -> Void = {}
    let onRefreshUsage: () -> Void
    let onEditGoal: () -> Void
    let onTogglePauseGoal: () -> Void
    let onCompleteGoal: () -> Void
    let onClearGoal: () -> Void
    let onToggleGoalExpanded: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let surfaceStyle = surfaceStyle(tokens: tokens)
        let shape = RoundedRectangle(cornerRadius: showsExpandedLayout ? 20 : 16, style: .continuous)

        VStack(alignment: .leading, spacing: showsExpandedLayout ? 8 : 0) {
            // 展开态把状态内容和收起按钮放到同一行，避免先出现一整行空白按钮区。
            if showsExpandedLayout {
                expandedTrayContent(tokens: tokens)
            } else {
                collapsedHeader(tokens: tokens)
            }

            // 收起态只表达“发生了什么”；详细错误随展开内容渐进披露，避免状态条
            // 因两行错误信息重新长成一张常驻卡片。
            if showsExpandedLayout, let trimmedGoalError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(trimmedGoalError)
                        .lineLimit(2)
                }
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.warning)
            }

            if showsExpandedLayout, let inlineAccessory {
                inlineAccessory
                    .padding(.top, 2)
            }
        }
        .padding(isGoalExpanded ? placement.expandedContentPadding : 0)
        // 状态栏和输入卡共用同一条 composer 轨道；展开后也不要另设宽度上限，
        // 否则 iPad 宽屏下会出现上窄下宽、左右边界不一致的视觉断层。
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if placement.usesIndependentSurface {
                traySurface(shape: shape, tokens: tokens, surfaceStyle: surfaceStyle)
            }
        }
        .overlay {
            if placement.usesIndependentSurface {
                shape.strokeBorder(
                    tokens.resolvedScheme == .light
                        ? Color.black.opacity(surfaceStyle.borderOpacity)
                        : tokens.border.opacity(surfaceStyle.borderOpacity),
                    lineWidth: 0.75
                )
            }
        }
        // disclosure 挂在托盘上而不是挂在两套内容里：内容内距在收起/展开之间怎么变，
        // 箭头都停在同一个点。必须排在描边 overlay 之后，否则卡片边缘那圈 stroke
        // 会先于按钮接住靠边的点击。
        .overlay(alignment: .topTrailing) {
            if hasExpandableDetail {
                disclosureButton(isExpanded: showsExpandedLayout, tint: tokens.secondaryText)
                    .padding(.trailing, placement.disclosureTrailingInset)
                    // offset 只挪渲染和命中，不参与布局：44pt 命中框仍然居中压在首行上，
                    // 状态条的视觉高度不受影响。
                    .offset(y: placement.disclosureVerticalOffset)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func collapsedHeader(tokens: ThemeTokens) -> some View {
        // 只剩一个子视图，但这层 HStack 仍然要留着：它负责把 chip 行在
        // `visualHeight` 的行高里居中；直接给 ScrollView 加 minHeight 会让它自己撑满，
        // 内容随之顶到行首。
        HStack(spacing: 8) {
            if showsMissingDirectoryOnlyBanner, let missingDirectoryNotice {
                VStack(alignment: .leading, spacing: 6) {
                    missingDirectoryBanner(missingDirectoryNotice, tokens: tokens)
                    if let inlineAccessory {
                        inlineAccessory
                    }
                }
                .layoutPriority(1)
            } else if inlineAccessory != nil {
                // 同排含交互药丸（模型选择/模型锁）时优先无滚动直排，避免 UIScrollView
                // delaysContentTouches 拖慢点击；极窄屏或大字号溢出时自动回落横向滚动。
                ViewThatFits(in: .horizontal) {
                    collapsedChipRow(tokens: tokens)
                        .fixedSize(horizontal: true, vertical: false)
                    ScrollView(.horizontal, showsIndicators: false) {
                        collapsedChipRow(tokens: tokens)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    collapsedChipRow(tokens: tokens)
                }
                .layoutPriority(1)
            }
        }
        // 内嵌时与编辑器文字共享左边缘；独立托盘继续保留原有卡片内距。
        .padding(.leading, placement.collapsedLeadingPadding)
        // 右侧只让位，不再自己摆按钮：disclosure 由托盘级 overlay 统一定位，
        // 这里从托盘边缘算起留出「内距 + 命中框 + 间距」。
        .padding(.trailing, hasExpandableDetail
            ? placement.disclosureTrailingInset + placement.disclosureClearance
            : 2)
        // 内嵌托盘是输入卡顶部的一条状态注解，不是一条独立列表行：视觉高度 36pt
        // 会让一枚 28pt 的 chip 顶着一整行空白，读成"这里少了点什么"。
        // 命中区由托盘级 overlay 的 Button 保证，不参与这条视觉栏的高度。
        .frame(minHeight: placement.visualHeight)
    }

    private func collapsedChipRow(tokens: ThemeTokens) -> some View {
        HStack(spacing: inlineAccessory != nil ? 6 : 10) {
            if let missingDirectoryNotice {
                missingDirectoryBanner(missingDirectoryNotice, tokens: tokens)
            } else if let ownershipNotice {
                collapsedChip(title: ownershipNotice.title, systemImage: "desktopcomputer", tint: tokens.secondaryText, tokens: tokens)
            } else if sessionControlNotice != nil {
                collapsedChip(title: L10n.text("ui.observe"), systemImage: "eye", tint: tokens.secondaryText, tokens: tokens)
            }
            if quotaNotice != nil {
                collapsedChip(title: L10n.text("ui.quota"), systemImage: "speedometer", tint: tokens.warning, tokens: tokens)
            } else if usage != nil {
                collapsedChip(title: L10n.text("ui.quota"), systemImage: "speedometer", tint: tokens.warning, tokens: tokens)
            }
            if let goal {
                collapsedChip(title: collapsedGoalChipTitle(for: goal.status), systemImage: "target", tint: goalStatusTint(goal, tokens: tokens), tokens: tokens)
            }
            if let inlineAccessory {
                inlineAccessory
            }
        }
    }

    @ViewBuilder
    private func expandedTrayContent(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            expandedHeaderRow(tokens: tokens)
            if let goal {
                expandedGoalDetails(goal, tokens: tokens)
            }
        }
    }

    private func expandedHeaderRow(tokens: ThemeTokens) -> some View {
        expandedHeaderSummary(tokens: tokens)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 展开内容已经被托盘的 expandedContentPadding 内缩过，这里只需要再让开命中框本身。
            .padding(.trailing, hasExpandableDetail ? placement.disclosureClearance : 0)
    }

    @ViewBuilder
    private func expandedHeaderSummary(tokens: ThemeTokens) -> some View {
        if hasStatusModules {
            adaptiveStatusModules(tokens: tokens)
        } else if let goal {
            collapsedChip(
                title: collapsedGoalChipTitle(for: goal.status),
                systemImage: "target",
                tint: goalStatusTint(goal, tokens: tokens),
                tokens: tokens
            )
        }
    }

    private var hasStatusModules: Bool {
        missingDirectoryNotice != nil || ownershipNotice != nil || sessionControlNotice != nil || quotaNotice != nil || usage != nil
    }

    /// 展开只为真正的次级内容或操作保留：目标详情、额度完整文案和刷新入口，
    /// 以及观察态中可执行的接管操作。不可接管的只读观察没有下文，继续隐藏 disclosure。
    /// Claude 持有态即使主机不支持接管也有下文：谁持有、对方退出后可在此继续。
    var hasExpandableDetail: Bool {
        goal != nil || quotaNotice != nil || usage != nil || ownershipNotice != nil ||
            (sessionControlNotice != nil && allowsTakeOver)
    }

    /// 没有可展开内容时忽略外部的展开状态，避免目标被清空后停在一个收不回去的展开态。
    private var showsExpandedLayout: Bool {
        isGoalExpanded && hasExpandableDetail
    }

    private var showsMissingDirectoryOnlyBanner: Bool {
        missingDirectoryNotice != nil && ownershipNotice == nil && quotaNotice == nil && usage == nil && goal == nil
    }

    /// 收起态且非独占多行缺失目录横幅时，把外部附带的小组件合并到首行与状态胶囊同排展示。
    var mergesInlineAccessoryInCollapsedRow: Bool {
        inlineAccessory != nil && !showsExpandedLayout && !showsMissingDirectoryOnlyBanner
    }

    private func collapsedChip(title: String, systemImage: String, tint: Color, tokens: ThemeTokens) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
        }
        .frame(minHeight: 28)
        .padding(.horizontal, placement.usesEmbeddedStatusChip ? 8 : 2)
        .background {
            if placement.usesEmbeddedStatusChip {
                // 内嵌状态用一枚轻量 tonal chip 提供身份，不使用 Material 或阴影，
                // 避免重新长成一张悬浮卡片，也不再用横线切断整个 Composer。
                Capsule(style: .continuous)
                    .fill(embeddedStatusChipFill(tokens: tokens))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(embeddedStatusChipBorder(tokens: tokens), lineWidth: 0.5)
                    }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func embeddedStatusChipFill(tokens: ThemeTokens) -> Color {
        ComposerEmbeddedPillPalette.fill(
            tokens: tokens,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private func embeddedStatusChipBorder(tokens: ThemeTokens) -> Color {
        ComposerEmbeddedPillPalette.border(
            tokens: tokens,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    /// 展开和收起共用同一枚按钮：同一个字号、同一个命中框、同一个锚点，方向只靠旋转表达。
    ///
    /// 这里曾经是两个各写各的函数——收起态 12pt 图标、没有 contentShape，展开态 16pt 图标、
    /// 有 contentShape——于是箭头在两态之间平移，而且收起态实际只有图标字形那么大能点中：
    /// `.frame` 只负责布局，Button 的命中区取自 label 真正绘制的内容，
    /// `MimiPressButtonStyle` 又只做缩放和透明度、不画背景，补不上这块面积。
    private func disclosureButton(isExpanded: Bool, tint: Color) -> some View {
        let title = isExpanded ? L10n.text("ui.collapse_state") : L10n.text("ui.expanded_state")
        let motion = MimiMotion.stateTransition.resolve(reduceMotion: reduceMotion)

        return Button(action: onToggleGoalExpanded) {
            Image(systemName: "chevron.down")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .animation(motion.animation, value: isExpanded)
                .frame(
                    width: placement.disclosureHitSize.width,
                    height: placement.disclosureHitSize.height
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .help(title)
        .accessibilityLabel(title)
    }

    private func adaptiveStatusModules(tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                statusModuleContent(tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 6) {
                statusModuleContent(tokens: tokens)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusModuleContent(tokens: ThemeTokens) -> some View {
        if let missingDirectoryNotice {
            missingDirectorySegment(missingDirectoryNotice, tokens: tokens)
        } else if let ownershipNotice {
            ownershipSegment(ownershipNotice, tokens: tokens)
        } else if let sessionControlNotice {
            observingSegment(sessionControlNotice, tokens: tokens)
        }
        if let quotaNotice {
            quotaSegment(quotaNotice, tokens: tokens)
        } else if let usage {
            usageSegment(usage, tokens: tokens)
        }
    }

    private func missingDirectoryBanner(_ notice: String, tokens: ThemeTokens) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.questionmark")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.warning)
            Text(notice)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, placement.usesEmbeddedStatusChip ? 8 : 4)
        .background {
            if placement.usesEmbeddedStatusChip {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(embeddedStatusChipFill(tokens: tokens))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(embeddedStatusChipBorder(tokens: tokens), lineWidth: 0.5)
                    }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer.missingDirectoryNotice")
    }

    private func missingDirectorySegment(_ notice: String, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, minWidth: 160, layoutPriority: 1) {
            HStack(spacing: 7) {
                segmentIcon("folder.badge.questionmark", tint: tokens.warning)
                Text(notice)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
        .accessibilityIdentifier("composer.missingDirectoryNotice")
    }

    private func observingSegment(_ notice: String, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, minWidth: 132) {
            HStack(spacing: 7) {
                segmentIcon("eye", tint: tokens.secondaryText)
                Text(L10n.text("ui.just_observe"))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .accessibilityHint(notice)
                if allowsTakeOver {
                    Button(action: onTakeOver) {
                        Text(L10n.text("ui.take_over"))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .accessibilityHint(notice)
                }
            }
        }
    }

    /// 与 `observingSegment` 同一套结构和「接管」按钮；多出的一行说明谁持有、为什么只读，
    /// 主机不支持接管时这行就是展开后的全部下文。
    private func ownershipSegment(_ notice: SessionOwnershipNotice, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, minWidth: 132, layoutPriority: 1) {
            HStack(spacing: 7) {
                segmentIcon("desktopcomputer", tint: tokens.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(notice.title)
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                        if notice.isBusy {
                            Text(L10n.text("ui.session_owned_elsewhere_busy"))
                                .font(themeStore.uiFont(.caption2, weight: .medium))
                                .foregroundStyle(tokens.accent)
                        }
                    }
                    .lineLimit(1)
                    Text(notice.message)
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(notice.failureMessage == nil ? 3 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                if notice.canTakeOver {
                    Button(action: onTakeOverHeldSession) {
                        Group {
                            if notice.isTakingOver {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(L10n.text("ui.take_over"))
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .disabled(notice.isTakingOver)
                    .accessibilityHint(notice.message)
                }
            }
        }
    }

    private func quotaSegment(_ notice: CodexQuotaNotice, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, minWidth: 230, layoutPriority: 1) {
            HStack(spacing: 8) {
                segmentIcon("speedometer", tint: tokens.warning)
                Text(notice.title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
                Text(notice.message)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .layoutPriority(1)
                refreshButton(tint: tokens.warning)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func usageSegment(_ usage: CodexUsageDisplaySummary, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, minWidth: 250, layoutPriority: 1) {
            HStack(spacing: 8) {
                segmentIcon("speedometer", tint: tokens.warning)
                Text(usage.nearLimitTitle)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(usage.secondaryText)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .layoutPriority(1)
                refreshButton(tint: tokens.warning)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func expandedGoalDetails(_ goal: ThreadGoal, tokens: ThemeTokens) -> some View {
        let tint = goalStatusTint(goal, tokens: tokens)
        return VStack(alignment: .leading, spacing: 8) {
            Text(goal.objective)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    tokens.background,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            if let progress = goal.budgetProgressFraction {
                ProgressView(value: progress)
                    .tint(tint)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(L10n.text("ui.target_token_budget_progress"))
                    .accessibilityValue(goal.budgetPercentText ?? goal.progressText)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    goalMetrics(goal, tokens: tokens)
                    Spacer(minLength: 8)
                    goalActionRow(goal, tint: tint, tokens: tokens)
                }
                VStack(alignment: .leading, spacing: 8) {
                    goalMetrics(goal, tokens: tokens)
                    goalActionRow(goal, tint: tint, tokens: tokens)
                }
            }
        }
    }

    private func goalMetrics(_ goal: ThreadGoal, tokens: ThemeTokens) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                goalDetailText(L10n.format("ui.status_value", goal.status.displayText), symbol: "circle.dashed", tokens: tokens)
                goalDetailText(L10n.format("ui.progress_value", goal.progressText), symbol: "gauge.with.dots.needle.33percent", tokens: tokens)
                if let percent = goal.budgetPercentText {
                    goalDetailText(L10n.format("ui.budget_value", percent), symbol: "percent", tokens: tokens)
                }
                goalDetailText(L10n.format("ui.time_taken_value", goal.elapsedText), symbol: "timer", tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 4) {
                goalDetailText(L10n.format("ui.status_value", goal.status.displayText), symbol: "circle.dashed", tokens: tokens)
                goalDetailText(L10n.format("ui.progress_value", goal.progressText), symbol: "gauge.with.dots.needle.33percent", tokens: tokens)
                if let percent = goal.budgetPercentText {
                    goalDetailText(L10n.format("ui.budget_value", percent), symbol: "percent", tokens: tokens)
                }
                goalDetailText(L10n.format("ui.time_taken_value", goal.elapsedText), symbol: "timer", tokens: tokens)
            }
        }
    }

    private func goalActionRow(_ goal: ThreadGoal, tint: Color, tokens: ThemeTokens) -> some View {
        HStack(spacing: 6) {
            iconButton(title: L10n.text("ui.edit_target"), systemImage: "pencil", tint: tokens.secondaryText, isDisabled: isGoalUpdating, action: onEditGoal)
            iconButton(title: primaryGoalActionTitle(for: goal.status), systemImage: primaryGoalActionSymbol(for: goal.status), tint: tint, isDisabled: isGoalUpdating, action: onTogglePauseGoal)
            iconButton(title: L10n.text("ui.mark_complete"), systemImage: "checkmark.circle", tint: tokens.success, isDisabled: isGoalUpdating || goal.status == .complete, action: onCompleteGoal)
            iconButton(title: L10n.text("ui.clear_target"), systemImage: "trash", tint: .red, isDisabled: isGoalUpdating, action: onClearGoal)
        }
    }

    private func traySegment<Content: View>(
        tokens: ThemeTokens,
        minWidth: CGFloat? = nil,
        layoutPriority: Double = 0,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .frame(minWidth: minWidth, minHeight: 44)
            .background(
                tokens.background,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .layoutPriority(layoutPriority)
    }

    private func segmentIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(themeStore.uiFont(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }

    private func refreshButton(tint: Color) -> some View {
        Button(action: onRefreshUsage) {
            Image(systemName: "arrow.clockwise")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .frame(width: 44, height: 44)
                // 和 disclosure 同一个坑：没有 contentShape 时这 44×44 只是布局框，
                // 真正能点中的只有那枚 13pt 图标。
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .foregroundStyle(isRefreshDisabled ? themeStore.tokens(for: colorScheme).tertiaryText : tint)
        .disabled(isRefreshDisabled)
        .help(L10n.text("ui.refresh_codex_usage"))
        .accessibilityLabel(L10n.text("ui.refresh_codex_usage"))
    }

    private func iconButton(
        title: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 16, weight: .semibold))
                .foregroundStyle(isDisabled ? tokens.tertiaryText : tint)
                .frame(width: 44, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func goalDetailText(_ text: String, symbol: String, tokens: ThemeTokens) -> some View {
        Label(text, systemImage: symbol)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(1)
    }

    private var trimmedGoalError: String? {
        let trimmed = goalErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    @ViewBuilder
    private func traySurface(
        shape: RoundedRectangle,
        tokens: ThemeTokens,
        surfaceStyle: ComposerStatusTraySurfaceStyle
    ) -> some View {
        switch surfaceStyle.materialStrength {
        case .opaque:
            if tokens.resolvedScheme == .light {
                // 与侧栏、输入卡逐像素共享同一白色；额度条只保留很短的接触阴影，
                // 让它贴近页面，同时与下方略微浮起的输入卡保持主次。
                shape
                    .fill(tokens.inputBackground)
                    .shadow(
                        color: Color.black.opacity(reduceTransparency ? 0.04 : 0.025),
                        radius: 2,
                        y: 1
                    )
            } else {
                shape.fill(tokens.elevatedSurface)
            }
        case .frosted:
            // 只在深色出现；浅色独立托盘一律走 `.opaque`。
            shape
                .fill(WorkbenchMaterial.surface)
                .overlay {
                    shape.fill(tokens.elevatedSurface.opacity(surfaceStyle.surfaceTintOpacity))
                }
        }
    }

    private func surfaceStyle(tokens: ThemeTokens) -> ComposerStatusTraySurfaceStyle {
        ComposerStatusTraySurfaceStyle.resolve(
            scheme: tokens.resolvedScheme,
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private func goalStatusTint(_ goal: ThreadGoal, tokens: ThemeTokens) -> Color {
        switch goal.status {
        case .active:
            return tokens.goalActive
        case .paused:
            return .secondary
        case .blocked, .usageLimited, .budgetLimited:
            return tokens.warning
        case .complete:
            return tokens.accent
        }
    }

    private func primaryGoalActionTitle(for status: ThreadGoalStatus) -> String {
        status == .active ? L10n.text("ui.pause_target") : L10n.text("ui.continue_target")
    }

    private func primaryGoalActionSymbol(for status: ThreadGoalStatus) -> String {
        status == .active ? "pause.circle" : "play.circle"
    }

    private func collapsedGoalChipTitle(for status: ThreadGoalStatus) -> String {
        switch status {
        case .active:
            return L10n.text("ui.target")
        case .paused:
            return L10n.text("ui.pause")
        case .blocked:
            return L10n.text("ui.blocked")
        case .usageLimited:
            return L10n.text("ui.quota")
        case .budgetLimited:
            return L10n.text("ui.budget")
        case .complete:
            return L10n.text("ui.complete")
        }
    }
}

/// 输入卡与模型切换面板共用的表面材质解析结果：
/// 生产渲染直接按此枚举分支绘制，测试与视图共享同一套判定，不再由外层修饰符二次推演。
enum ComposerCardResolvedSurface: Equatable {
    case solidCard
    case liquidGlass
    case ultraThinMaterial

    static func resolve(
        usesFloatingGlass: Bool,
        interfaceStyle: ThemeInterfaceStyle,
        reduceTransparency: Bool,
        increasedContrast: Bool,
        supportsLiquidGlass: Bool = WorkbenchGlassChromeStyle.supportsSystemLiquidGlass
    ) -> Self {
        guard usesFloatingGlass,
              interfaceStyle == .glass,
              !reduceTransparency,
              !increasedContrast
        else {
            return .solidCard
        }
        return supportsLiquidGlass ? .liquidGlass : .ultraThinMaterial
    }
}

/// 输入框及其弹出面板（「+」添加内容、模型九宫格）共用的表面策略与回退色板：
/// - iOS 26+ 玻璃模式下直接复用系统原生单层 Liquid Glass Popover/Sheet，
///   避免在系统玻璃容器之上再叠第二层 `.glassEffect` 造成浅色发白、深色发雾或双重边框；
/// - iOS 18–25 玻璃模式下使用 `.ultraThinMaterial`，与悬浮输入卡保持一致；
/// - 经典风格、降低透明度、增强对比度在 iPhone 与 iPad 上统一回退到与输入卡逐像素一致的实色底板。
enum ComposerPopupPresentationSurface {
    static func solidFillColor(
        tokens: ThemeTokens,
        colorScheme: ColorScheme
    ) -> Color {
        colorScheme == .light ? tokens.inputBackground : tokens.elevatedSurface
    }

    static func solidBorderColor(
        tokens: ThemeTokens,
        colorScheme: ColorScheme,
        increasedContrast: Bool
    ) -> Color {
        if increasedContrast {
            return tokens.primaryText.opacity(colorScheme == .light ? 0.5 : 0.68)
        }
        if colorScheme == .light {
            return Color.black.opacity(0.09)
        }
        return tokens.border.opacity(0.58)
    }

    static func innerCardFill(
        tokens: ThemeTokens,
        colorScheme: ColorScheme,
        usesTranslucentChrome: Bool,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Color {
        if usesTranslucentChrome {
            return ComposerEmbeddedPillPalette.fill(
                tokens: tokens,
                reduceTransparency: false,
                increasedContrast: false
            )
        }
        if tokens.preset == .codex && colorScheme == .light {
            return tokens.elevatedSurface
        }
        return tokens.surface
    }

    static func innerCardBorder(
        tokens: ThemeTokens,
        colorScheme: ColorScheme,
        usesTranslucentChrome: Bool,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Color {
        if usesTranslucentChrome {
            return ComposerEmbeddedPillPalette.border(
                tokens: tokens,
                reduceTransparency: false,
                increasedContrast: false
            )
        }
        if increasedContrast {
            return solidBorderColor(
                tokens: tokens,
                colorScheme: colorScheme,
                increasedContrast: true
            )
        }
        return tokens.border.opacity(colorScheme == .light ? 0.72 : 0.68)
    }
}

/// 弹出面板（模型九宫格、「+」添加内容）共用的展示层背景修饰符。
struct ComposerPopupPresentationBackgroundModifier: ViewModifier {
    let resolvedSurface: ComposerCardResolvedSurface
    let tokens: ThemeTokens
    let colorScheme: ColorScheme
    let cornerRadius: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = applyCornerRadius(to: content)
        switch resolvedSurface {
        case .liquidGlass:
            if #available(iOS 26.0, *) {
                // iOS 26+ 原生 Popover/Sheet 本身即是单层 Liquid Glass，与悬浮输入卡同源；
                // 不再覆写自定义 `.presentationBackground { .glassEffect(...) }`，杜绝双层玻璃叠雾。
                base
            } else {
                base.presentationBackground(.ultraThinMaterial)
            }
        case .ultraThinMaterial:
            base.presentationBackground(.ultraThinMaterial)
        case .solidCard:
            base.presentationBackground(
                ComposerPopupPresentationSurface.solidFillColor(
                    tokens: tokens,
                    colorScheme: colorScheme
                )
            )
        }
    }

    @ViewBuilder
    private func applyCornerRadius(to content: Content) -> some View {
        if let cornerRadius {
            content.presentationCornerRadius(cornerRadius)
        } else {
            content
        }
    }
}

/// 输入卡与待发送浮层共用的表面修饰符：直接消费 `ComposerCardResolvedSurface` 材质判定，
/// 并始终收敛为单层 `ModifiedContent` 以守住真机栈预算。
struct ComposerCardSurfaceModifier<CardShape: InsettableShape>: ViewModifier {
    let shape: CardShape
    let tokens: ThemeTokens
    let colorScheme: ColorScheme
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let usesFloatingGlass: Bool
    let voiceAccentBorderColor: Color?
    let solidBorderColor: Color
    let borderWidth: CGFloat
    var explicitResolvedSurface: ComposerCardResolvedSurface? = nil
    /// 宽档卡片放进 `GlassEffectContainer`，与顶栏胶囊同一套采样。
    /// 手机集成底栏不包：那里的玻璃已经能折射正文，多一层容器会改掉现有效果。
    var presentsInGlassContainer: Bool = false

    @Environment(\.themeInterfaceStyle) private var interfaceStyle

    private var solidFillColor: Color {
        colorScheme == .light ? tokens.inputBackground : tokens.elevatedSurface
    }

    private var resolvedSurface: ComposerCardResolvedSurface {
        explicitResolvedSurface ?? ComposerCardResolvedSurface.resolve(
            usesFloatingGlass: usesFloatingGlass,
            interfaceStyle: interfaceStyle,
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast
        )
    }

    private var defaultMaterialBorderColor: Color {
        colorScheme == .light
            ? Color.black.opacity(0.08)
            : Color.white.opacity(0.16)
    }

    func body(content: Content) -> some View {
        switch resolvedSurface {
        case .liquidGlass:
            if #available(iOS 26.0, *) {
                liquidGlassSurface(content)
            } else {
                ultraThinMaterialSurface(content)
            }
        case .ultraThinMaterial:
            ultraThinMaterialSurface(content)
        case .solidCard:
            let usesFloatingFallbackShadow = usesFloatingGlass
                && interfaceStyle == .glass
                && (reduceTransparency || increasedContrast)
            let shadowOpacity: Double = increasedContrast
                ? 0.05
                : (usesFloatingFallbackShadow
                    ? (colorScheme == .light ? 0.10 : 0.30)
                    : (colorScheme == .light ? 0.06 : 0.22))
            let shadowRadius: CGFloat = usesFloatingFallbackShadow ? 8 : 6
            let shadowY: CGFloat = usesFloatingFallbackShadow ? 3 : 2
            content
                .background {
                    shape
                        .fill(solidFillColor)
                        .shadow(color: Color.black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
                }
                .overlay {
                    shape.strokeBorder(voiceAccentBorderColor ?? solidBorderColor, lineWidth: borderWidth)
                }
        }
    }

    @ViewBuilder
    private func liquidGlassSurface(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // 手机集成底栏继续把正文放进 glassEffect，保持现有 iPhone 观感。
            // 宽档容器不能这样：系统色（完全访问的 `.red`）在 GlassEffectContainer 里
            // 离屏快照会收成黑色，实机仍是红色。玻璃只做底，文字留在普通图层。
            if presentsInGlassContainer {
                GlassEffectContainer(spacing: 0) {
                    wideGlassContent(content)
                }
            } else {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay {
                        if let voiceAccentBorderColor {
                            shape.strokeBorder(voiceAccentBorderColor, lineWidth: borderWidth)
                        }
                    }
            }
        } else {
            ultraThinMaterialSurface(content)
        }
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private func wideGlassContent(_ content: Content) -> some View {
        content
            .background {
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular, in: shape)
            }
            .overlay {
                if let voiceAccentBorderColor {
                    shape.strokeBorder(voiceAccentBorderColor, lineWidth: borderWidth)
                }
            }
    }

    private func ultraThinMaterialSurface(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape
                    .strokeBorder(
                        voiceAccentBorderColor ?? defaultMaterialBorderColor,
                        lineWidth: voiceAccentBorderColor != nil ? borderWidth : 0.75
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .light ? 0.08 : 0.28),
                radius: 10,
                x: 0,
                y: 4
            )
    }
}

extension ComposerView {
    var hasComposerStatusTrayContent: Bool {
        let missingDirectoryNotice = sessionStore.selectedSession?.cwdMissing == true
            ? sessionStore.selectedSessionControlNotice
            : nil
        let ownershipNotice = sessionStore.selectedOwnershipNotice
        let sessionControlNotice = (ownershipNotice == nil && missingDirectoryNotice == nil)
            ? sessionStore.selectedSessionControlNotice
            : nil
        return missingDirectoryNotice != nil ||
            ownershipNotice != nil ||
            sessionControlNotice != nil ||
            selectedComposerUsageNotice != nil ||
            selectedVisibleThreadGoal != nil
    }

    /// 透明玻璃输入卡在常态下由系统 Liquid Glass 提供边缘高光，只在语音准备/录音/转写态叠回状态色描边。
    func composerActiveVoiceBorderColor(_ tokens: ThemeTokens) -> Color? {
        guard voiceInput.isRecording || voiceInput.isPreparing || isVoicePressActive || isVoiceTranscribing else {
            return nil
        }
        return composerCardBorderColor(tokens)
    }

    @ViewBuilder
    func composerStatusTray(inlineAccessory: AnyView?) -> some View {
        let visibleGoal = selectedVisibleThreadGoal
        let usageNotice = selectedComposerUsageNotice
        let ownershipNotice = sessionStore.selectedOwnershipNotice
        let missingDirectoryNotice = sessionStore.selectedSession?.cwdMissing == true
            ? sessionStore.selectedSessionControlNotice
            : nil
        // Claude 被 Mac 持有或原工作目录缺失本身就是明确的只读原因，避免叠加通用「仅观察」chip。
        let sessionControlNotice = (ownershipNotice == nil && missingDirectoryNotice == nil)
            ? sessionStore.selectedSessionControlNotice
            : nil
        if missingDirectoryNotice != nil ||
            ownershipNotice != nil ||
            sessionControlNotice != nil ||
            usageNotice != nil ||
            visibleGoal != nil {
            ComposerStatusTray(
                sessionControlNotice: sessionControlNotice,
                missingDirectoryNotice: missingDirectoryNotice,
                ownershipNotice: ownershipNotice,
                // 阻断额度已经由 Conversation 顶部唯一状态区展示，Composer 不再重复一份。
                quotaNotice: nil,
                usage: usageNotice,
                goal: visibleGoal,
                placement: usesNarrowComposerLayout ? .embedded : .standalone,
                inlineAccessory: inlineAccessory,
                isGoalExpanded: isGoalStatusExpanded,
                isGoalUpdating: sessionStore.isUpdatingThreadGoal,
                goalErrorMessage: sessionStore.threadGoalErrorMessage,
                isRefreshDisabled: sessionStore.isRefreshingSelectedSession || sessionStore.isLoading,
                allowsTakeOver: sessionStore.selectedSessionAllowsTakeOver,
                onTakeOver: {
                    sessionStore.takeOverSelectedSession()
                },
                onTakeOverHeldSession: {
                    isClaudeTakeoverConfirmationPresented = true
                },
                onRefreshUsage: {
                    Task {
                        await sessionStore.refreshCurrentContext(origin: .routine)
                    }
                },
                onEditGoal: {
                    if let goal = visibleGoal {
                        goalEditor = ThreadGoalEditorDraft(sessionID: goal.threadID, existing: goal)
                    }
                },
                onTogglePauseGoal: {
                    if let goal = visibleGoal {
                        Task { await sessionStore.updateSelectedThreadGoalStatus(nextPrimaryGoalStatus(for: goal.status)) }
                    }
                },
                onCompleteGoal: {
                    Task { await sessionStore.updateSelectedThreadGoalStatus(.complete) }
                },
                onClearGoal: {
                    Task { await sessionStore.clearSelectedThreadGoal() }
                },
                onToggleGoalExpanded: {
                    withAnimation(composerMotionAnimation) {
                        isGoalStatusExpanded.toggle()
                    }
                }
            )
            .environmentObject(themeStore)
            // 只在出现持有态时探测一次主机是否支持 thread/takeover，老主机不出现接管按钮。
            .task(id: ownershipNotice?.sessionID) {
                guard let sessionID = ownershipNotice?.sessionID else {
                    return
                }
                await sessionStore.refreshClaudeTakeoverSupportIfNeeded(sessionID: sessionID)
            }
            // 接管会结束 Mac 上的一个进程，必须二次确认；失败后按钮保留可重试。
            .confirmationDialog(
                L10n.text("ui.take_over_claude_session_confirm_title"),
                isPresented: $isClaudeTakeoverConfirmationPresented,
                titleVisibility: .visible,
                presenting: ownershipNotice
            ) { notice in
                Button(L10n.text("ui.take_over_claude_session_confirm_action"), role: .destructive) {
                    let sessionID = notice.sessionID
                    Task { await sessionStore.takeOverHeldClaudeSession(sessionID: sessionID) }
                }
            } message: { notice in
                Text(notice.takeOverConfirmationMessage)
            }
            .transition(
                reduceMotion || usesNarrowComposerLayout
                    ? .opacity
                    : .move(edge: .top).combined(with: .opacity)
            )
        }
    }
}

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
                                        if turn.intent.canGuideCurrentTurn {
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
    case thin
    case regular
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
}

struct ComposerStatusTraySurfaceStyle: Equatable {
    let materialStrength: ComposerStatusTrayMaterialStrength
    let surfaceTintOpacity: Double
    let borderOpacity: Double

    static func resolve(
        isExpanded: Bool,
        scheme: ThemeResolvedScheme,
        reduceTransparency: Bool,
        isPhone: Bool = false,
        increasedContrast: Bool = false
    ) -> Self {
        if scheme == .light {
            // iPhone 状态条和输入框必须共享同一套材质与 tint；否则两块相邻表面即使
            // 只差少量白色覆盖，也会被看成两种不同的卡片。层级只交给边框和阴影。
            if isPhone && !reduceTransparency && !increasedContrast {
                return Self(
                    materialStrength: .thin,
                    surfaceTintOpacity: 0.14,
                    borderOpacity: 0.09
                )
            }

            // iPad 以及辅助功能模式继续使用确定性的暖白实色，保证长状态内容可读。
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

        // 深色继续保留功能材质；展开时只增加模糊厚度保证长内容可读，
        // 不再靠阴影、彩色双描边或多层高光制造实体卡片感。
        return Self(
            materialStrength: isExpanded ? .regular : .thin,
            surfaceTintOpacity: 0.46,
            borderOpacity: 0.58
        )
    }
}

struct ComposerStatusTray: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let sessionControlNotice: String?
    let quotaNotice: CodexQuotaNotice?
    let usage: CodexUsageDisplaySummary?
    let goal: ThreadGoal?
    let placement: ComposerStatusTrayPlacement
    let isGoalExpanded: Bool
    let isGoalUpdating: Bool
    let goalErrorMessage: String?
    let isRefreshDisabled: Bool
    let allowsTakeOver: Bool
    let onTakeOver: () -> Void
    let onRefreshUsage: () -> Void
    let onEditGoal: () -> Void
    let onTogglePauseGoal: () -> Void
    let onCompleteGoal: () -> Void
    let onClearGoal: () -> Void
    let onToggleGoalExpanded: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let surfaceStyle = surfaceStyle(tokens: tokens)
        let shape = RoundedRectangle(cornerRadius: isGoalExpanded ? 20 : 16, style: .continuous)

        VStack(alignment: .leading, spacing: isGoalExpanded ? 8 : 0) {
            // 展开态把状态内容和收起按钮放到同一行，避免先出现一整行空白按钮区。
            if isGoalExpanded {
                expandedTrayContent(tokens: tokens)
            } else {
                collapsedHeader(tokens: tokens)
            }

            // 收起态只表达“发生了什么”；详细错误随展开内容渐进披露，避免状态条
            // 因两行错误信息重新长成一张常驻卡片。
            if isGoalExpanded, let trimmedGoalError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(trimmedGoalError)
                        .lineLimit(2)
                }
                .font(themeStore.uiFont(.caption2, weight: .medium))
                .foregroundStyle(tokens.warning)
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
        .accessibilityElement(children: .contain)
    }

    private func collapsedHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if sessionControlNotice != nil {
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
                }
            }
            .layoutPriority(1)

            collapsedDisclosureButton(
                title: L10n.text("ui.expanded_state"),
                systemImage: "chevron.down",
                tint: tokens.secondaryText,
                action: onToggleGoalExpanded
            )
        }
        // 内嵌时与编辑器文字共享左边缘；独立托盘继续保留原有卡片内距。
        .padding(.leading, placement.collapsedLeadingPadding)
        .padding(.trailing, 2)
        .frame(minHeight: 44)
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
        HStack(alignment: .top, spacing: 8) {
            expandedHeaderSummary(tokens: tokens)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            iconButton(
                title: L10n.text("ui.collapse_state"),
                systemImage: "chevron.up",
                tint: tokens.secondaryText,
                isDisabled: false,
                action: onToggleGoalExpanded
            )
        }
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
        sessionControlNotice != nil || quotaNotice != nil || usage != nil
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
        .frame(height: 28)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    /// 收起态只保留一个 44pt 命中区，视觉上不再叠一层独立方形按钮。
    /// 这样状态 rail 保持紧凑，同时仍满足触控和 VoiceOver 的可达性。
    private func collapsedDisclosureButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
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
        if let sessionControlNotice {
            observingSegment(sessionControlNotice, tokens: tokens)
        }
        if let quotaNotice {
            quotaSegment(quotaNotice, tokens: tokens)
        } else if let usage {
            usageSegment(usage, tokens: tokens)
        }
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

    private func quotaSegment(_ notice: CodexQuotaNotice, tokens: ThemeTokens) -> some View {
        traySegment(tokens: tokens, minWidth: 230, layoutPriority: 1) {
            HStack(spacing: 8) {
                segmentIcon("speedometer", tint: tokens.warning)
                Text(notice.blocksSending ? L10n.text("ui.quota_has_been_exhausted") : notice.title)
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
                Text(L10n.format("ui.quota_value", usage.primaryText))
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
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
                .modifier(
                    ComposerFlatControlSurface(
                        tokens: tokens,
                        cornerRadius: 12,
                        isEmphasized: false
                    )
                )
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
        case .regular:
            // 深色展开态内容更多，只增加材质模糊厚度。
            shape
                .fill(.regularMaterial)
                .overlay {
                    shape.fill(tokens.elevatedSurface.opacity(surfaceStyle.surfaceTintOpacity))
                }
        case .thin:
            if tokens.resolvedScheme == .light {
                // 与 iPhone Composer 逐项复用 thinMaterial + 14% input tint；这里不叠
                // 第二层 Material，避免相邻表面出现不同色温或模糊厚度。
                shape
                    .fill(.thinMaterial)
                    .overlay {
                        shape.fill(tokens.inputBackground.opacity(surfaceStyle.surfaceTintOpacity))
                    }
                    .shadow(color: Color.black.opacity(0.025), radius: 2, y: 1)
            } else {
                // 深色收起态维持薄材质，不再额外抬高层级。
                shape
                    .fill(.thinMaterial)
                    .overlay {
                        shape.fill(tokens.elevatedSurface.opacity(surfaceStyle.surfaceTintOpacity))
                    }
            }
        }
    }

    private func surfaceStyle(tokens: ThemeTokens) -> ComposerStatusTraySurfaceStyle {
        ComposerStatusTraySurfaceStyle.resolve(
            isExpanded: isGoalExpanded,
            scheme: tokens.resolvedScheme,
            reduceTransparency: reduceTransparency,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
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

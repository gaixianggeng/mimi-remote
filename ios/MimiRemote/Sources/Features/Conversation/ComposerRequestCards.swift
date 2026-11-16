import SwiftUI

extension Notification.Name {
    static let agentQuestionInputFocusDidChange = Notification.Name("MimiRemote.agentQuestionInputFocusDidChange")
}

/// 审批和补充信息属于同一类“Agent 等待用户处理”的卡片。
/// 统一 Codex、Claude Code 与 DeepSeek 的头部标识、卡片底板、分步切换器、编号选项行与自由输入框风格。
struct AgentRequestRuntimeIcon: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let presentation: SessionRuntimePresentation
    var size: CGFloat = 28

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        RuntimeBrandMarkIcon(mark: presentation.brandMark, size: size * 0.56)
            .frame(width: size, height: size)
            .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.75), lineWidth: 0.75)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.title)
    }
}

struct AgentRequestCardSurface: ViewModifier {
    let tokens: ThemeTokens
    let borderColor: Color

    func body(content: Content) -> some View {
        content
            .background(
                tokens.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }
}

/// 与 Desktop 一致的多题分步切换器（`< 1 / 2 >`）。
struct AgentQuestionStepPager: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Binding var stepIndex: Int
    let totalSteps: Int
    var onStepWillChange: (() -> Void)?

    var body: some View {
        if totalSteps > 1 {
            let clamped = min(max(stepIndex, 0), totalSteps - 1)
            let tokens = themeStore.tokens(for: colorScheme)

            HStack(spacing: 2) {
                Button {
                    guard clamped > 0 else { return }
                    onStepWillChange?()
                    stepIndex = clamped - 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(themeStore.uiFont(.caption2, weight: .bold))
                        .foregroundStyle(clamped > 0 ? tokens.secondaryText : tokens.tertiaryText.opacity(0.45))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(clamped <= 0)
                .accessibilityIdentifier("conversation.questionPager.previous")

                Text("\(clamped + 1) / \(totalSteps)")
                    .font(themeStore.uiFont(.caption2, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tokens.secondaryText)
                    .padding(.horizontal, 2)

                Button {
                    guard clamped < totalSteps - 1 else { return }
                    onStepWillChange?()
                    stepIndex = clamped + 1
                } label: {
                    Image(systemName: "chevron.right")
                        .font(themeStore.uiFont(.caption2, weight: .bold))
                        .foregroundStyle(clamped < totalSteps - 1 ? tokens.secondaryText : tokens.tertiaryText.opacity(0.45))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(clamped >= totalSteps - 1)
                .accessibilityIdentifier("conversation.questionPager.next")
            }
            .padding(.horizontal, 4)
            .frame(height: 26)
            .background(tokens.elevatedSurface, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tokens.border.opacity(0.75), lineWidth: 0.75)
            }
        }
    }
}

/// 与 Desktop 一致的编号选项行（[1] 苹果 / [2] 香蕉，选中后切换为高亮勾选）。
struct AgentQuestionOptionRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let index: Int
    let label: String
    let description: String?
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button(action: action) {
            HStack(alignment: description == nil ? .center : .top, spacing: 10) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                        .frame(width: 24, height: 24)
                } else {
                    Text("\(index + 1)")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(
                            tokens.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(tokens.border.opacity(0.8), lineWidth: 1)
                        }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(tokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !description.isEmpty {
                        Text(description)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(
                isSelected ? tokens.selectionFill : tokens.inputBackground,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? tokens.accent.opacity(0.55) : tokens.border.opacity(0.75),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// 与 Desktop 一致的 `[✏️] 或自行撰写回复 / 回复…` 单行自由输入框。
/// 使用标准单行 UITextField 而非 axis: .vertical，避免 List Cell 在横竖屏弹出键盘时发生高度抖动与错位。
struct AgentQuestionOtherField: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var localFocused: Bool

    let questionID: String
    var placeholder: String = L10n.text("ui.other")
    let isSecret: Bool
    let isDisabled: Bool
    var submitLabel: SubmitLabel = .done
    @Binding var text: String
    var focusedQuestionID: FocusState<String?>.Binding?
    var onSubmit: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFocused = localFocused || focusedQuestionID?.wrappedValue == questionID
        let isHighlighted = !trimmed.isEmpty || isFocused

        HStack(spacing: 10) {
            Image(systemName: isSecret ? "lock" : "pencil")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(isHighlighted ? tokens.accent : tokens.tertiaryText)
                .frame(width: 24, height: 24)

            Group {
                if isSecret {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.primaryText)
                        .submitLabel(submitLabel)
                        .onSubmit {
                            localFocused = false
                            focusedQuestionID?.wrappedValue = nil
                            onSubmit?()
                        }
                } else {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.primaryText)
                        .submitLabel(submitLabel)
                        .onSubmit {
                            localFocused = false
                            focusedQuestionID?.wrappedValue = nil
                            onSubmit?()
                        }
                }
            }
            .focused($localFocused)
            .modifier(
                PendingUserInputQuestionFocusModifier(
                    questionID: questionID,
                    focusedQuestionID: focusedQuestionID
                )
            )
            .disabled(isDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(
            isHighlighted ? tokens.selectionFill : tokens.inputBackground.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? tokens.accent.opacity(0.75) : (isHighlighted ? tokens.accent.opacity(0.5) : tokens.border.opacity(0.7)),
                    lineWidth: isFocused ? 1.25 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !isDisabled else { return }
            localFocused = true
            focusedQuestionID?.wrappedValue = questionID
        }
        .onChange(of: localFocused) { _, focused in
            NotificationCenter.default.post(
                name: .agentQuestionInputFocusDidChange,
                object: nil,
                userInfo: ["isFocused": focused]
            )
        }
        .onDisappear {
            if localFocused {
                NotificationCenter.default.post(
                    name: .agentQuestionInputFocusDidChange,
                    object: nil,
                    userInfo: ["isFocused": false]
                )
            }
        }
    }
}

/// 分步提问主体（每次展示当前步骤的一道题，和 Mac Codex Desktop `< 1 of N >` 交互完全对齐）。
struct AgentQuestionStepBody: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let request: AgentUserInputRequest
    let stepIndex: Int
    let isDisabled: Bool
    @Binding var draft: PendingUserInputDraft
    let focusedQuestionID: FocusState<String?>.Binding?
    var onPrimaryStepAction: (() -> Void)?

    var body: some View {
        if !request.questions.isEmpty {
            let clamped = min(max(stepIndex, 0), request.questions.count - 1)
            let question = request.questions[clamped]
            let isLastStep = clamped >= request.questions.count - 1
            let tokens = themeStore.tokens(for: colorScheme)
            let titles = resolvedTitles(for: question)

            VStack(alignment: .leading, spacing: 10) {
                if let badge = titles.badge {
                    Text(badge)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                }
                if let title = titles.title {
                    Text(title)
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !question.options.isEmpty {
                    if question.allowsMultipleSelection {
                        Text(L10n.text("ui.multiple_selections_possible"))
                            .font(themeStore.uiFont(.caption2))
                            .foregroundStyle(tokens.secondaryText)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                            AgentQuestionOptionRow(
                                index: index,
                                label: option.label,
                                description: option.description,
                                isSelected: draft.isSelected(option.label, for: question.id),
                                isDisabled: isDisabled
                            ) {
                                focusedQuestionID?.wrappedValue = nil
                                draft.toggleOption(option.label, for: question)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if question.isOther || question.options.isEmpty {
                    AgentQuestionOtherField(
                        questionID: question.id,
                        placeholder: question.options.isEmpty
                            ? L10n.text("ui.question_reply_placeholder")
                            : L10n.text("ui.question_custom_reply_placeholder"),
                        isSecret: question.isSecret,
                        isDisabled: isDisabled,
                        submitLabel: isLastStep ? .send : .next,
                        text: Binding(
                            get: { draft.freeformAnswer(for: question.id) },
                            set: { draft.setFreeformAnswer($0, for: question) }
                        ),
                        focusedQuestionID: focusedQuestionID,
                        onSubmit: {
                            guard !isDisabled, draft.hasAnswer(for: question) else { return }
                            onPrimaryStepAction?()
                        }
                    )
                }
            }
            .id(question.id)
        }
    }

    private func resolvedTitles(for question: AgentUserInputQuestion) -> (badge: String?, title: String?) {
        let header = question.header.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !header.isEmpty && !prompt.isEmpty && header != prompt {
            return (header, prompt)
        }
        let singleTitle = !prompt.isEmpty ? prompt : (header.isEmpty ? nil : header)
        return (nil, singleTitle)
    }
}

/// 分步提问底部操作栏：非末题为 `[跳过] [下一步]`，末题为 `[跳过] [提交]`，与桌面端操作流一致。
struct AgentQuestionStepActionBar: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let request: AgentUserInputRequest
    @Binding var stepIndex: Int
    let isSubmitting: Bool
    var isDisabled: Bool = false
    var allowsEmptySubmission: Bool = true
    var skipAccessibilityIdentifier: String?
    var primaryAccessibilityIdentifier: String?
    @Binding var draft: PendingUserInputDraft
    let onPrepareAction: () -> Void
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let totalSteps = max(1, request.questions.count)
        let clamped = min(max(stepIndex, 0), totalSteps - 1)
        let isLastStep = clamped >= totalSteps - 1
        let currentQuestion = request.questions.indices.contains(clamped) ? request.questions[clamped] : nil
        let hasCurrentAnswer = currentQuestion.map { draft.hasAnswer(for: $0) } ?? true
        let canAdvanceOrSubmit = !isSubmitting && !isDisabled && (
            isLastStep
                ? (hasCurrentAnswer || (!allowsEmptySubmission && draft.hasAnyAnswer(in: request)))
                : hasCurrentAnswer
        )
        let canSkipCurrentStep = !isSubmitting && !isDisabled && (
            !isLastStep
                || allowsEmptySubmission
                || draft.hasAnyAnswer(in: request, excluding: currentQuestion?.id)
        )
        let primaryTitle: String = {
            if isSubmitting {
                return L10n.text("ui.submitting")
            }
            return isLastStep ? L10n.text("ui.submit") : L10n.text("ui.turn_hint_next_step")
        }()

        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button {
                onPrepareAction()
                if let currentQuestion {
                    draft.clearAnswer(for: currentQuestion.id)
                }
                if isLastStep {
                    _ = onSubmit(draft.answerPayload(for: request))
                } else {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        stepIndex = clamped + 1
                    }
                }
            } label: {
                Text(L10n.text("ui.skip"))
                    .font(themeStore.uiFont(.subheadline, weight: .medium))
                    .foregroundStyle(canSkipCurrentStep ? tokens.primaryText : tokens.tertiaryText)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .background(
                        tokens.elevatedSurface,
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(tokens.border.opacity(0.85), lineWidth: 1)
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .frame(minHeight: 44)
            .disabled(!canSkipCurrentStep)
            .modifier(OptionalAccessibilityIdentifierModifier(identifier: skipAccessibilityIdentifier))

            Button {
                onPrepareAction()
                if isLastStep {
                    _ = onSubmit(draft.answerPayload(for: request))
                } else {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        stepIndex = clamped + 1
                    }
                }
            } label: {
                Text(primaryTitle)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(canAdvanceOrSubmit ? tokens.primaryActionForeground : tokens.tertiaryText)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 38)
                    .background(
                        canAdvanceOrSubmit ? tokens.primaryAction : tokens.selectionFill,
                        in: Capsule(style: .continuous)
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .frame(minHeight: 44)
            .disabled(!canAdvanceOrSubmit)
            .modifier(OptionalAccessibilityIdentifierModifier(identifier: primaryAccessibilityIdentifier))
        }
    }
}

private struct OptionalAccessibilityIdentifierModifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

struct PendingApprovalActionCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let approval: ApprovalSummary
    let runtimePresentation: SessionRuntimePresentation
    let isSendingDecision: Bool
    let onDecision: (String) -> Void

    @State private var persistentGrant: PersistentPermissionGrant?
    @State private var isDetailsExpanded = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            approvalHeader(tokens: tokens)
            approvalSummary(tokens: tokens)
            if let previewText {
                approvalDetailsDisclosure(previewText, tokens: tokens)
            }
            if !approval.hasDecisionContext {
                missingContextWarning(tokens: tokens)
            }
            if isSendingDecision {
                sendingDecisionStatus(tokens: tokens)
            }
            approvalButtons(tokens: tokens)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            AgentRequestCardSurface(
                tokens: tokens,
                borderColor: tokens.border
            )
        )
        // 审批卡位于输入框上方，用户无需跳转到 Inspector 才能作出决定。
        .accessibilityElement(children: .contain)
        .sheet(item: $persistentGrant) { grant in
            PersistentPermissionConfirmationSheet(grant: grant) {
                onDecision("acceptWithPermissionUpdate")
            }
            .environmentObject(themeStore)
        }
    }

    private var previewText: String? {
        if let body = approval.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            return body
        }
        let title = approval.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title == summaryTitle ? nil : title
    }

    private var summaryTitle: String {
        switch approval.kind {
        case "command":
            return L10n.text("ui.agent_requests_to_execute_a_command")
        case "file_change":
            return L10n.text("ui.agent_requests_to_modify_a_file")
        case "permission":
            return L10n.text("ui.agent_requests_elevated_privileges")
        default:
            return approval.title
        }
    }

    private var kindLabel: String {
        switch approval.kind {
        case "command":
            return L10n.text("ui.command")
        case "file_change":
            return L10n.text("ui.file_changes")
        case "permission":
            return L10n.text("ui.permissions_request_approval")
        case "mcp_elicitation", CodexMCPToolApprovalProtocol.kind:
            return L10n.text("ui.mcp_service")
        default:
            return approval.kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var riskLabel: String? {
        guard let risk = approval.risk?.trimmingCharacters(in: .whitespacesAndNewlines), !risk.isEmpty else {
            return nil
        }
        return L10n.format("ui.risk_badge_value", ApprovalRiskText.localized(risk))
    }

    private func riskTone(tokens: ThemeTokens) -> Color {
        switch approval.risk?.lowercased() {
        case "high", "critical", "danger":
            return .red
        case "low":
            return tokens.success
        default:
            return tokens.warning
        }
    }

    private func approvalHeader(tokens: ThemeTokens) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Label(L10n.text("ui.waiting_for_approval"), systemImage: "exclamationmark.shield")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)

            Text(kindLabel)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tokens.elevatedSurface, in: Capsule())
                .fixedSize(horizontal: true, vertical: false)

            if let riskLabel {
                Text(riskLabel)
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(riskTone(tokens: tokens))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(riskTone(tokens: tokens).opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(riskTone(tokens: tokens).opacity(0.24), lineWidth: 1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 0)

            if let count = approval.count {
                Text(L10n.plural("ui.items_count", count: count))
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.tertiaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }

            AgentRequestRuntimeIcon(presentation: runtimePresentation, size: 26)
        }
    }

    private func approvalSummary(tokens: ThemeTokens) -> some View {
        Text(summaryTitle)
            .font(themeStore.uiFont(.body, weight: .semibold))
            .foregroundStyle(tokens.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func approvalDetailsDisclosure(_ text: String, tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.92)) {
                    isDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(
                            tokens.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(tokens.border.opacity(0.8), lineWidth: 1)
                        }
                    Text(L10n.text("ui.approval_details"))
                        .font(themeStore.uiFont(.subheadline, weight: .medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(themeStore.uiFont(.caption, weight: .bold))
                        .foregroundStyle(tokens.secondaryText)
                        .rotationEffect(.degrees(isDetailsExpanded ? 180 : 0))
                }
                .foregroundStyle(tokens.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityIdentifier("approval.details")
            .accessibilityHint(L10n.text(isDetailsExpanded ? "ui.hide_details" : "ui.show_details"))

            if isDetailsExpanded {
                Divider()
                    .overlay(tokens.border.opacity(0.7))

                ScrollView {
                    Text(text)
                        .font(themeStore.codeFont(.footnote))
                        .foregroundStyle(tokens.codeText)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                // 详情默认折叠；展开后也限制高度，避免长命令把决策按钮推离触手可及的位置。
                .frame(maxHeight: horizontalSizeClass == .compact ? 170 : 230)
                .background(tokens.codeBlock)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(tokens.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.75), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func missingContextWarning(tokens: ThemeTokens) -> some View {
        Label(
            L10n.text("ui.claude_bridge_provides_no_verifiable_command_path_or"),
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(themeStore.uiFont(.footnote, weight: .medium))
        .foregroundStyle(tokens.warning)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sendingDecisionStatus(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.text("ui.approval_decision_is_being_sent"))
                .font(themeStore.uiFont(.footnote, weight: .medium))
        }
        .foregroundStyle(tokens.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func approvalButtons(tokens: ThemeTokens) -> some View {
        if approval.canPersistPermission, let rules = approval.persistentPermissionRules {
            Button {
                persistentGrant = PersistentPermissionGrant(
                    id: approval.id,
                    approvalTitle: approval.title,
                    rules: rules
                )
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                        .frame(width: 24, height: 24)
                        .background(
                            tokens.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(tokens.border.opacity(0.8), lineWidth: 1)
                        }
                    Text(L10n.text("ui.always_allowed"))
                        .font(themeStore.uiFont(.subheadline, weight: .medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(themeStore.uiFont(.caption, weight: .bold))
                        .foregroundStyle(tokens.secondaryText)
                }
                .foregroundStyle(tokens.primaryText)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(tokens.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tokens.border.opacity(0.75), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .disabled(isSendingDecision || !approval.hasDecisionContext)
            .accessibilityIdentifier("approval.alwaysAllow")
            .accessibilityHint(L10n.text("ui.after_confirmation_write_the_precise_rules_suggested_by"))
        }

        if approval.canAcceptMCPToolForSession {
            mcpTrustButton(
                title: L10n.text("ui.allow_for_this_session"),
                systemImage: "clock.badge.checkmark",
                decision: "acceptForSession",
                identifier: "approval.allowMCPForSession",
                tokens: tokens
            )
        }

        if approval.canAlwaysAllowMCPTool {
            mcpTrustButton(
                title: L10n.text("ui.always_allow_this_tool"),
                systemImage: "checkmark.shield",
                decision: "acceptAlways",
                identifier: "approval.alwaysAllowMCPTool",
                tokens: tokens
            )
        }

        if approval.canAcceptMCPToolForSession || approval.canAlwaysAllowMCPTool {
            Label(
                L10n.text("ui.codex_saves_this_choice_on_the_mac"),
                systemImage: "macbook.and.iphone"
            )
            .font(themeStore.uiFont(.footnote))
            .foregroundStyle(tokens.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                approveButton(tokens: tokens)
                rejectButton(tokens: tokens)
            }

            VStack(spacing: 10) {
                approveButton(tokens: tokens)
                rejectButton(tokens: tokens)
            }
        }
    }

    private func mcpTrustButton(
        title: String,
        systemImage: String,
        decision: String,
        identifier: String,
        tokens: ThemeTokens
    ) -> some View {
        Button {
            onDecision(decision)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 24, height: 24)
                    .background(
                        tokens.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tokens.border.opacity(0.8), lineWidth: 1)
                    }
                Text(title)
                    .font(themeStore.uiFont(.subheadline, weight: .medium))
                    .foregroundStyle(tokens.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(tokens.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.75), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(isSendingDecision || !approval.hasDecisionContext)
        .accessibilityIdentifier(identifier)
        .accessibilityHint(L10n.text("ui.codex_saves_this_choice_on_the_mac"))
    }

    private func rejectButton(tokens: ThemeTokens) -> some View {
        Button(role: .destructive) {
            onDecision("decline")
        } label: {
            Label(L10n.text("ui.reject"), systemImage: "xmark.circle")
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(Color.red)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.34), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(isSendingDecision)
        .accessibilityIdentifier("approval.reject")
        .accessibilityLabel(L10n.text("ui.deny_approval"))
        .accessibilityHint(L10n.text("ui.deny_is_always_available"))
    }

    private func approveButton(tokens: ThemeTokens) -> some View {
        let isEnabled = !isSendingDecision && approval.hasDecisionContext
        let title = approval.kind == CodexMCPToolApprovalProtocol.kind
            ? L10n.text("ui.allow_once")
            : L10n.text("ui.approve_once")
        return Button {
            onDecision("accept")
        } label: {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(isEnabled ? tokens.primaryActionForeground : tokens.tertiaryText)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    isEnabled ? tokens.primaryAction : tokens.selectionFill,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(!isEnabled)
        .accessibilityIdentifier("approval.approveOnce")
        .accessibilityLabel(L10n.text("ui.approval_36f0d72e"))
        .accessibilityValue(approval.hasDecisionContext ? L10n.text("ui.available") : L10n.text("ui.approval_details_not_available"))
        .accessibilityHint(approval.hasDecisionContext ? L10n.text("ui.approve_this_request") : L10n.text("ui.approval_details_are_missing_and_cannot_be_approved"))
    }
}

struct PersistentPermissionGrant: Identifiable {
    let id: String
    let approvalTitle: String
    let rules: [String]
}

struct PersistentPermissionConfirmationSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let grant: PersistentPermissionGrant
    let onConfirm: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.text("ui.current_request"), systemImage: "exclamationmark.shield")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                        Text(grant.approvalTitle)
                            .font(themeStore.uiFont(.body, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(AgentRequestCardSurface(tokens: tokens, borderColor: tokens.border))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("ui.will_always_be_allowed"))
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                        ForEach(Array(grant.rules.enumerated()), id: \.offset) { index, rule in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(themeStore.uiFont(.caption, weight: .semibold))
                                    .foregroundStyle(tokens.secondaryText)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        tokens.elevatedSurface,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(tokens.border.opacity(0.8), lineWidth: 1)
                                    }
                                Text(rule)
                                    .font(themeStore.codeFont(.footnote))
                                    .foregroundStyle(tokens.primaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                tokens.inputBackground,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(tokens.border.opacity(0.75), lineWidth: 1)
                            }
                        }
                        Text(L10n.text("ui.claude_will_append_the_above_precise_rules_to"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .padding(.top, 2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(AgentRequestCardSurface(tokens: tokens, borderColor: tokens.border))
                }
                .padding(16)
            }
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.confirm_always_allow"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.confirm_permission")) {
                        onConfirm()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct PendingUserInputDraft: Equatable {
    private(set) var selectedAnswers: [String: Set<String>] = [:]
    private(set) var freeformAnswers: [String: String] = [:]

    mutating func toggleOption(_ label: String, for question: AgentUserInputQuestion) {
        if question.allowsMultipleSelection {
            if selectedAnswers[question.id, default: []].contains(label) {
                selectedAnswers[question.id, default: []].remove(label)
            } else {
                selectedAnswers[question.id, default: []].insert(label)
            }
        } else {
            selectedAnswers[question.id] = [label]
            // 单选题选中预设项时清空同一题的自定义文本，避免无意间拼接两份回答。
            freeformAnswers.removeValue(forKey: question.id)
        }
    }

    mutating func setFreeformAnswer(_ answer: String, for questionID: String) {
        freeformAnswers[questionID] = answer
    }

    mutating func setFreeformAnswer(_ answer: String, for question: AgentUserInputQuestion) {
        freeformAnswers[question.id] = answer
        if !question.allowsMultipleSelection,
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedAnswers.removeValue(forKey: question.id)
        }
    }

    mutating func clearAnswer(for questionID: String) {
        selectedAnswers.removeValue(forKey: questionID)
        freeformAnswers.removeValue(forKey: questionID)
    }

    func isSelected(_ label: String, for questionID: String) -> Bool {
        selectedAnswers[questionID, default: []].contains(label)
    }

    func freeformAnswer(for questionID: String) -> String {
        freeformAnswers[questionID] ?? ""
    }

    func hasAnswer(for question: AgentUserInputQuestion) -> Bool {
        !answers(for: question).isEmpty
    }

    func hasAnyAnswer(in request: AgentUserInputRequest, excluding excludedQuestionID: String? = nil) -> Bool {
        request.questions.contains { question in
            guard question.id != excludedQuestionID else { return false }
            return hasAnswer(for: question)
        }
    }

    func answerPayload(for request: AgentUserInputRequest) -> [String: [String]] {
        var payload: [String: [String]] = [:]
        for question in request.questions {
            let values = answers(for: question)
            if !values.isEmpty {
                payload[question.id] = values
            }
        }
        return payload
    }

    func canSubmit(_ request: AgentUserInputRequest) -> Bool {
        guard !request.questions.isEmpty else { return true }
        return request.questions.allSatisfy { hasAnswer(for: $0) }
    }

    private func answers(for question: AgentUserInputQuestion) -> [String] {
        let selected = selectedAnswers[question.id] ?? []
        // 选项按服务端给出的顺序生成 payload；Set 只用于去重和快速切换，不能决定传输顺序。
        var values = question.options.map(\.label).filter { selected.contains($0) }
        let freeform = freeformAnswer(for: question.id).trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeform.isEmpty {
            values.append(freeform)
        }
        return values
    }
}

struct PendingUserInputPresentation: Identifiable, Equatable {
    let request: AgentUserInputRequest
    let runtimePresentation: SessionRuntimePresentation

    var id: String {
        Self.id(for: request)
    }

    static func id(for request: AgentUserInputRequest) -> String {
        "\(request.threadID):\(request.id)"
    }
}

struct PendingUserInputFormState: Equatable {
    private(set) var activePresentationID: String?
    var draft = PendingUserInputDraft()

    @discardableResult
    mutating func resetIfSessionChanged(from previousSessionID: SessionID?, to currentSessionID: SessionID?) -> Bool {
        // previous 为 nil 也可能只是横竖屏导致 View 重建，不能据此清空刚从内存缓存恢复的答案。
        guard let previousSessionID, previousSessionID != currentSessionID else {
            return false
        }
        resetForSessionChange()
        return true
    }

    mutating func activate(_ presentationID: String) {
        guard activePresentationID != presentationID else {
            return
        }
        // 同一请求关闭再打开要保留答案；只有 thread/request 真正变化时才清空。
        activePresentationID = presentationID
        draft = PendingUserInputDraft()
    }

    mutating func resetForSessionChange() {
        activePresentationID = nil
        draft = PendingUserInputDraft()
    }
}

struct PendingUserInputSelectionIdentity: Equatable {
    let sessionID: SessionID?
    let requestPresentationID: String?
}

struct PendingUserInputActionCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedQuestionID: String?
    @State private var stepIndex = 0
    let request: AgentUserInputRequest
    let runtimePresentation: SessionRuntimePresentation
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let totalSteps = max(1, request.questions.count)
        let clampedStep = min(max(stepIndex, 0), totalSteps - 1)
        let allowsEmptySubmission = runtimePresentation.brandMark != .deepSeek

        VStack(alignment: .leading, spacing: 14) {
            PendingUserInputHeader(
                request: request,
                runtimePresentation: runtimePresentation,
                isSubmitting: isSubmitting,
                showsSectionLabel: true,
                stepIndex: $stepIndex,
                onStepWillChange: { focusedQuestionID = nil }
            )
            AgentQuestionStepBody(
                request: request,
                stepIndex: clampedStep,
                isDisabled: isSubmitting,
                draft: $draft,
                focusedQuestionID: $focusedQuestionID,
                onPrimaryStepAction: {
                    if clampedStep >= totalSteps - 1 {
                        _ = onSubmit(draft.answerPayload(for: request))
                    } else {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                            stepIndex = clampedStep + 1
                        }
                    }
                }
            )
            AgentQuestionStepActionBar(
                request: request,
                stepIndex: $stepIndex,
                isSubmitting: isSubmitting,
                allowsEmptySubmission: allowsEmptySubmission,
                draft: $draft,
                onPrepareAction: { focusedQuestionID = nil },
                onSubmit: onSubmit
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            AgentRequestCardSurface(
                tokens: tokens,
                borderColor: tokens.border
            )
        )
        .onChange(of: request.id) { _, _ in
            stepIndex = 0
        }
        .onChange(of: request.questions.count) { _, newCount in
            if stepIndex >= max(1, newCount) {
                stepIndex = max(0, newCount - 1)
            }
        }
    }
}

struct PendingUserInputResumeButton: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: AgentUserInputRequest
    let runtimePresentation: SessionRuntimePresentation
    let isSubmitting: Bool
    let action: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        tokens.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("ui.continue_filling_supplementary_information"))
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(request.title)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AgentRequestRuntimeIcon(presentation: runtimePresentation, size: 26)
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.up")
                        .font(themeStore.uiFont(.caption2, weight: .bold))
                        .foregroundStyle(tokens.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .modifier(
            AgentRequestCardSurface(
                tokens: tokens,
                borderColor: tokens.border
            )
        )
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(isSubmitting)
        .accessibilityLabel(L10n.text("ui.continue_filling_supplementary_information"))
        .accessibilityValue(request.title)
    }
}

struct PendingUserInputSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedQuestionID: String?
    @State private var stepIndex = 0
    let presentation: PendingUserInputPresentation
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let request = presentation.request
        let totalSteps = max(1, request.questions.count)
        let clampedStep = min(max(stepIndex, 0), totalSteps - 1)
        let allowsEmptySubmission = presentation.runtimePresentation.brandMark != .deepSeek

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PendingUserInputHeader(
                        request: request,
                        runtimePresentation: presentation.runtimePresentation,
                        isSubmitting: isSubmitting,
                        showsSectionLabel: true,
                        stepIndex: $stepIndex,
                        onStepWillChange: { focusedQuestionID = nil }
                    )
                    AgentQuestionStepBody(
                        request: request,
                        stepIndex: clampedStep,
                        isDisabled: isSubmitting,
                        draft: $draft,
                        focusedQuestionID: $focusedQuestionID,
                        onPrimaryStepAction: {
                            if clampedStep >= totalSteps - 1 {
                                _ = submitAndDismiss(draft.answerPayload(for: request))
                            } else {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                    stepIndex = clampedStep + 1
                                }
                            }
                        }
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(
                    AgentRequestCardSurface(
                        tokens: tokens,
                        borderColor: tokens.border
                    )
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AgentQuestionStepActionBar(
                    request: request,
                    stepIndex: $stepIndex,
                    isSubmitting: isSubmitting,
                    allowsEmptySubmission: allowsEmptySubmission,
                    draft: $draft,
                    onPrepareAction: { focusedQuestionID = nil },
                    onSubmit: submitAndDismiss
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background {
                    if reduceTransparency {
                        tokens.background
                    } else {
                        Rectangle()
                            .fill(WorkbenchMaterial.surface)
                            .overlay(tokens.background.opacity(colorScheme == .light ? 0.76 : 0.62))
                    }
                }
                .shadow(color: .black.opacity(tokens.resolvedScheme == .light ? 0.08 : 0.24), radius: 12, y: -3)
            }
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.supplementary_information"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.close")) {
                        focusedQuestionID = nil
                        dismiss()
                    }
                }
            }
            .onChange(of: request.id) { _, _ in
                stepIndex = 0
            }
        }
        // 只使用 .large，杜绝横屏 .medium 半高把底部输入框和按钮裁切遮挡。
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func submitAndDismiss(_ answers: [String: [String]]) -> Bool {
        focusedQuestionID = nil
        let accepted = onSubmit(answers)
        if accepted {
            dismiss()
        }
        return accepted
    }
}

private struct PendingUserInputHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let runtimePresentation: SessionRuntimePresentation
    let isSubmitting: Bool
    let showsSectionLabel: Bool
    @Binding var stepIndex: Int
    var onStepWillChange: (() -> Void)?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        HStack(alignment: .center, spacing: 8) {
            Label(
                showsSectionLabel ? L10n.text("ui.supplementary_information") : request.title,
                systemImage: "questionmark.bubble"
            )
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)

            if isSubmitting {
                Label(L10n.text("ui.answer_sent"), systemImage: "hourglass")
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
            }

            Spacer(minLength: 0)

            AgentQuestionStepPager(
                stepIndex: $stepIndex,
                totalSteps: request.questions.count,
                onStepWillChange: onStepWillChange
            )

            AgentRequestRuntimeIcon(presentation: runtimePresentation, size: 26)
        }
    }
}

struct PendingUserInputQuestionFocusModifier: ViewModifier {
    let questionID: String
    let focusedQuestionID: FocusState<String?>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focusedQuestionID {
            content.focused(focusedQuestionID, equals: questionID)
        } else {
            content
        }
    }
}

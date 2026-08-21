import SwiftUI

/// 审批和补充信息属于同一类“Agent 等待用户处理”的卡片。
/// 这里仅统一品牌标识与外层材质，内部仍按请求语义保留审批按钮或选项表单。
private struct AgentRequestRuntimeIcon: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let presentation: SessionRuntimePresentation
    var size: CGFloat = 34

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Image(presentation.brandAssetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .padding(size * 0.22)
            .frame(width: size, height: size)
            .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.72), lineWidth: 0.75)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.title)
    }
}

private struct AgentRequestCardSurface: ViewModifier {
    let tokens: ThemeTokens
    let borderColor: Color

    func body(content: Content) -> some View {
        content
            .background(
                tokens.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
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

        VStack(alignment: .leading, spacing: 14) {
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
        .padding(horizontalSizeClass == .compact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            AgentRequestCardSurface(
                tokens: tokens,
                // “等待审批”是待处理状态而非警告。外框保持中性，
                // 具体风险继续由摘要里的红/绿风险标签单独表达。
                borderColor: tokens.border.opacity(colorScheme == .dark ? 0.72 : 0.82)
            )
        )
        // 审批卡位于输入框上方，用户无需跳转到 Inspector 才能作出决定。
        .accessibilityElement(children: .contain)
        .sheet(item: $persistentGrant) { grant in
            PersistentPermissionConfirmationSheet(grant: grant) {
                onDecision("acceptWithPermissionUpdate")
            }
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
        let localizedRisk: String
        switch risk.lowercased() {
        case "high":
            localizedRisk = L10n.text("ui.high")
        case "low":
            localizedRisk = L10n.text("ui.low")
        default:
            localizedRisk = risk
        }
        return L10n.format("ui.risk_badge_value", localizedRisk)
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
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(themeStore.uiFont(size: 19, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 36, height: 36)
                .background(tokens.accent.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            Text(L10n.text("ui.waiting_for_approval"))
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            AgentRequestRuntimeIcon(presentation: runtimePresentation)
        }
    }

    private func approvalSummary(tokens: ThemeTokens) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(kindLabel)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(tokens.selectionFill, in: Capsule())
                .fixedSize(horizontal: true, vertical: false)

            Text(summaryTitle)
                .font(themeStore.uiFont(.subheadline, weight: .medium))
                .foregroundStyle(tokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let count = approval.count {
                Text(L10n.plural("ui.items_count", count: count))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let riskLabel {
                Text(riskLabel)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(riskTone(tokens: tokens))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .background(riskTone(tokens: tokens).opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(riskTone(tokens: tokens).opacity(0.24), lineWidth: 1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
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
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                    Text(L10n.text("ui.approval_details"))
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(themeStore.uiFont(.caption, weight: .bold))
                        .rotationEffect(.degrees(isDetailsExpanded ? 180 : 0))
                }
                .foregroundStyle(tokens.primaryText)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52)
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
                        .padding(14)
                }
                // 详情默认折叠；展开后也限制高度，避免长命令把决策按钮推离触手可及的位置。
                .frame(maxHeight: horizontalSizeClass == .compact ? 170 : 230)
                .background(tokens.codeBlock)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.72), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                rejectButton(tokens: tokens)
                approveButton(tokens: tokens)
            }

            VStack(spacing: 10) {
                approveButton(tokens: tokens)
                rejectButton(tokens: tokens)
            }
        }

        if approval.canPersistPermission, let rules = approval.persistentPermissionRules {
            Button {
                persistentGrant = PersistentPermissionGrant(
                    id: approval.id,
                    approvalTitle: approval.title,
                    rules: rules
                )
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.shield")
                    Text(L10n.text("ui.always_allowed"))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(themeStore.uiFont(.caption, weight: .bold))
                }
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Label(title, systemImage: systemImage)
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.34), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(isEnabled ? tokens.primaryActionForeground : tokens.tertiaryText)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    isEnabled ? tokens.primaryAction : tokens.selectionFill,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    @Environment(\.dismiss) private var dismiss

    let grant: PersistentPermissionGrant
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.current_request")) {
                    Text(grant.approvalTitle)
                }
                Section(L10n.text("ui.will_always_be_allowed")) {
                    ForEach(grant.rules, id: \.self) { rule in
                        Text(rule)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Text(L10n.text("ui.claude_will_append_the_above_precise_rules_to"))
                        .foregroundStyle(.secondary)
                }
            }
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
        .presentationDetents([.medium, .large])
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
        }
    }

    mutating func setFreeformAnswer(_ answer: String, for questionID: String) {
        freeformAnswers[questionID] = answer
    }

    func isSelected(_ label: String, for questionID: String) -> Bool {
        selectedAnswers[questionID, default: []].contains(label)
    }

    func freeformAnswer(for questionID: String) -> String {
        freeformAnswers[questionID] ?? ""
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
        request.questions.isEmpty || request.questions.allSatisfy { !answers(for: $0).isEmpty }
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
    @FocusState private var focusedQuestionID: String?
    let request: AgentUserInputRequest
    let runtimePresentation: SessionRuntimePresentation
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            PendingUserInputHeader(
                request: request,
                runtimePresentation: runtimePresentation,
                isSubmitting: isSubmitting,
                showsSectionLabel: true
            )
            PendingUserInputQuestions(
                request: request,
                isSubmitting: isSubmitting,
                usesFullWidthOptions: false,
                draft: $draft,
                focusedQuestionID: $focusedQuestionID
            )
            PendingUserInputActionBar(
                request: request,
                isSubmitting: isSubmitting,
                draft: $draft,
                onPrepareAction: { focusedQuestionID = nil },
                onSubmit: onSubmit
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            AgentRequestCardSurface(
                tokens: tokens,
                borderColor: tokens.accent.opacity(colorScheme == .dark ? 0.38 : 0.28)
            )
        )
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.text("ui.complete")) {
                    focusedQuestionID = nil
                }
                Button(L10n.text("ui.submit")) {
                    focusedQuestionID = nil
                    _ = onSubmit(draft.answerPayload(for: request))
                }
                .disabled(isSubmitting || !draft.canSubmit(request))
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
                AgentRequestRuntimeIcon(presentation: runtimePresentation, size: 34)
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
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.up")
                        .font(themeStore.uiFont(.caption2, weight: .bold))
                        .foregroundStyle(tokens.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .modifier(
            AgentRequestCardSurface(
                tokens: tokens,
                borderColor: tokens.accent.opacity(colorScheme == .dark ? 0.38 : 0.28)
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
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedQuestionID: String?
    let presentation: PendingUserInputPresentation
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PendingUserInputHeader(
                        request: presentation.request,
                        runtimePresentation: presentation.runtimePresentation,
                        isSubmitting: isSubmitting,
                        showsSectionLabel: false
                    )
                    PendingUserInputQuestions(
                        request: presentation.request,
                        isSubmitting: isSubmitting,
                        usesFullWidthOptions: true,
                        draft: $draft,
                        focusedQuestionID: $focusedQuestionID
                    )
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PendingUserInputActionBar(
                    request: presentation.request,
                    isSubmitting: isSubmitting,
                    draft: $draft,
                    onPrepareAction: { focusedQuestionID = nil },
                    onSubmit: submitAndDismiss
                )
                .padding(.horizontal, 18)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.submit")) {
                        _ = submitAndDismiss(draft.answerPayload(for: presentation.request))
                    }
                    .disabled(isSubmitting || !draft.canSubmit(presentation.request))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.text("ui.complete")) {
                        focusedQuestionID = nil
                    }
                    Button(L10n.text("ui.submit")) {
                        _ = submitAndDismiss(draft.answerPayload(for: presentation.request))
                    }
                    .disabled(isSubmitting || !draft.canSubmit(presentation.request))
                }
            }
        }
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

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                if showsSectionLabel {
                    Text(L10n.text("ui.supplementary_information"))
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                }
                Text(request.title)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if isSubmitting {
                    Label(L10n.text("ui.answer_sent"), systemImage: "hourglass")
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AgentRequestRuntimeIcon(presentation: runtimePresentation)
        }
    }
}

private struct PendingUserInputQuestions: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    let usesFullWidthOptions: Bool
    @Binding var draft: PendingUserInputDraft
    let focusedQuestionID: FocusState<String?>.Binding?

    var body: some View {
        VStack(alignment: .leading, spacing: usesFullWidthOptions ? 14 : 12) {
            ForEach(request.questions) { question in
                questionBlock(question)
                    .padding(usesFullWidthOptions ? 14 : 0)
                    .background {
                        if usesFullWidthOptions {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(themeStore.tokens(for: colorScheme).elevatedSurface)
                        }
                    }
            }
        }
    }

    private func questionBlock(_ question: AgentUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !question.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.header)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            }
            if !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.question)
                    .font(themeStore.uiFont(.subheadline))
                    .foregroundStyle(themeStore.tokens(for: colorScheme).primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                if question.allowsMultipleSelection {
                    Text(L10n.text("ui.multiple_selections_possible"))
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
                }
                optionButtons(for: question)
            }
            if question.isOther || question.options.isEmpty {
                answerField(for: question)
            }
        }
    }

    @ViewBuilder
    private func optionButtons(for question: AgentUserInputQuestion) -> some View {
        if usesFullWidthOptions {
            // iPhone 本来就是单列。直接使用 VStack，避免 iOS 27 在
            // ScrollView + LazyVGrid + Button 组合下错误裁掉按钮背景和选择图标。
            VStack(alignment: .leading, spacing: 8) {
                ForEach(question.options) { option in
                    optionButton(option, for: question)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(question.options) { option in
                    optionButton(option, for: question)
                }
            }
        }
    }

    private func optionButton(
        _ option: AgentUserInputOption,
        for question: AgentUserInputQuestion
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let isSelected = draft.isSelected(option.label, for: question.id)

        return Button {
            focusedQuestionID?.wrappedValue = nil
            draft.toggleOption(option.label, for: question)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(isSelected ? tokens.accent : tokens.tertiaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                        Text(description)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: usesFullWidthOptions ? .infinity : 220, minHeight: 44, alignment: .leading)
            .background(
                isSelected ? tokens.selectionFill : tokens.inputBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? tokens.accent.opacity(0.5) : tokens.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    @ViewBuilder
    private func answerField(for question: AgentUserInputQuestion) -> some View {
        if question.isSecret {
            SecureField(L10n.text("ui.other"), text: binding(for: question.id))
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { focusedQuestionID?.wrappedValue = nil }
                .modifier(
                    PendingUserInputQuestionFocusModifier(
                        questionID: question.id,
                        focusedQuestionID: focusedQuestionID
                    )
                )
                .disabled(isSubmitting)
        } else {
            TextField(L10n.text("ui.other"), text: binding(for: question.id), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .submitLabel(.done)
                .onSubmit { focusedQuestionID?.wrappedValue = nil }
                .modifier(
                    PendingUserInputQuestionFocusModifier(
                        questionID: question.id,
                        focusedQuestionID: focusedQuestionID
                    )
                )
                .disabled(isSubmitting)
        }
    }

    private func binding(for questionID: String) -> Binding<String> {
        Binding(
            get: { draft.freeformAnswer(for: questionID) },
            set: { draft.setFreeformAnswer($0, for: questionID) }
        )
    }
}

private struct PendingUserInputQuestionFocusModifier: ViewModifier {
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

private struct PendingUserInputActionBar: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    @Binding var draft: PendingUserInputDraft
    let onPrepareAction: () -> Void
    let onSubmit: ([String: [String]]) -> Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        HStack(spacing: 10) {
            Button(L10n.text("ui.skip")) {
                onPrepareAction()
                _ = onSubmit([:])
            }
            .buttonStyle(.bordered)
            .tint(tokens.accent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(isSubmitting)

            Button {
                onPrepareAction()
                _ = onSubmit(draft.answerPayload(for: request))
            } label: {
                if isSubmitting {
                    Label(L10n.text("ui.submitting"), systemImage: "hourglass")
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                } else {
                    Label(L10n.text("ui.submit_additional_information"), systemImage: "arrow.up.circle.fill")
                        .font(themeStore.uiFont(.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.accent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(isSubmitting || !draft.canSubmit(request))
        }
    }
}

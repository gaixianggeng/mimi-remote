import SwiftUI

/// Claude 回合提示卡片：下一步提示框（回顾 + 问题 + 按钮）和新任务提议（标题 + 说明）。
/// 按钮是否可点由时间线决定：只有最后一回合、会话可直接输入且没有在运行时才可点。
struct ConversationTurnHintCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let hint: ConversationTurnHint
    let layout: ConversationLayout
    let canAct: Bool
    /// 同步返回 Task，保证调用方在异步调度前捕获 host/session/turn/connection。
    let onAction: (ConversationTurnHint.UserAction) -> Task<Bool, Never>?

    @State private var isBriefExpanded = false
    @State private var interaction = ConversationTurnHintInteractionState()

    @ViewBuilder
    var body: some View {
        if !interaction.isDismissed {
            let tokens = themeStore.tokens(for: colorScheme)
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    hint.kind == .taskProposal ? L10n.text("ui.turn_hint_task_proposal") : L10n.text("ui.turn_hint_next_step"),
                    systemImage: hint.kind == .taskProposal ? "arrow.up.right.square" : "arrow.turn.down.right"
                )
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)

                switch hint.kind {
                case .nextStep:
                    nextStepContent(tokens: tokens)
                case .taskProposal:
                    proposalContent(tokens: tokens)
                }

                if interaction.submission == .idle {
                    Button(L10n.text("ui.turn_hint_dismiss")) {
                        _ = interaction.dismiss()
                    }
                    .font(themeStore.uiFont(.footnote, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .buttonStyle(.plain)
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("conversation.turnHint.dismiss")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: layout.runtimeCardMaxWidth, alignment: .leading)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tokens.border, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.turnHint.\(hint.kind.rawValue)")
        }
    }

    @ViewBuilder
    private func nextStepContent(tokens: ThemeTokens) -> some View {
        if let recap = hint.recap {
            Text(recap)
                .font(themeStore.uiFont(.subheadline))
                .foregroundStyle(tokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if let question = hint.question {
            Text(question)
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, hint.recap == nil ? 0 : 2)
        }
        if !hint.actions.isEmpty {
            // 宽度不够时竖排，按钮文案不截断。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons(tokens: tokens) }
                VStack(alignment: .leading, spacing: 8) { actionButtons(tokens: tokens) }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func actionButtons(tokens: ThemeTokens) -> some View {
        ForEach(Array(hint.actions.enumerated()), id: \.offset) { index, action in
            let isEnabled = interaction.canSubmit(cardCanAct: canAct)
            Button {
                submit(.reply(action), index: index)
            } label: {
                Text(action.label)
                    .font(themeStore.uiFont(.subheadline, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .foregroundStyle(index == 0 ? Color.white : tokens.primaryText)
                    .background(
                        index == 0 ? AnyShapeStyle(tokens.accent) : AnyShapeStyle(tokens.selectionFill),
                        in: Capsule()
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled || interaction.isSelected(actionIndex: index) ? 1 : 0.45)
            .accessibilityHint(Text(action.message))
            .accessibilityIdentifier("conversation.turnHint.action.\(index)")
        }
    }

    @ViewBuilder
    private func proposalContent(tokens: ThemeTokens) -> some View {
        if let title = hint.title {
            Text(title)
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let brief = hint.brief {
            Text(brief)
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(isBriefExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button(isBriefExpanded ? L10n.text("ui.turn_hint_hide_brief") : L10n.text("ui.turn_hint_show_brief")) {
                isBriefExpanded.toggle()
            }
            .font(themeStore.uiFont(.footnote, weight: .medium))
            .foregroundStyle(tokens.accent)
            .buttonStyle(.plain)
            .frame(minHeight: 32)
        }
        if hint.mimiProposalID != nil {
            let isEnabled = interaction.canSubmit(cardCanAct: canAct)
            Button {
                submit(.startTask, index: 0)
            } label: {
                Label(L10n.text("ui.turn_hint_start_task"), systemImage: "arrow.up.right.square")
                    .font(themeStore.uiFont(.subheadline, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .foregroundStyle(Color.white)
                    .background(tokens.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled || interaction.isSelected(actionIndex: 0) ? 1 : 0.45)
            .accessibilityIdentifier("conversation.turnHint.startTask")
        } else {
            Text(L10n.text("ui.turn_hint_desktop_only"))
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.tertiaryText)
        }
    }

    private func submit(_ action: ConversationTurnHint.UserAction, index: Int) {
        guard interaction.begin(actionIndex: index) else { return }
        guard let task = onAction(action) else {
            interaction.finish(actionIndex: index, succeeded: false)
            return
        }
        Task { @MainActor in
            interaction.finish(actionIndex: index, succeeded: await task.value)
        }
    }
}

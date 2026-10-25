import SwiftUI

/// 改动面板的审查备注区：把备注放进目标会话的输入框（不自动发送），以及一键清除。
struct GitReviewNotesAgentBox: View {
    /// 卡片里的说明行。已放入的反馈和当前不能发送的原因可以同时出现：
    /// 发过之后目标变得不可用（切了会话、被接管等），用户仍要知道「再次发送」为什么是灰的。
    enum StatusLine: Hashable {
        case ready(sessionTitle: String)
        case sent(sessionTitle: String)
        case unavailable(ReviewNotesAgentUnavailableReason)
    }

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let commentCount: Int
    let target: ReviewNotesAgentTarget
    /// 当前备注已全部放进过某个会话的输入框时，那个会话的标题。
    let sentSessionTitle: String?
    /// 可以发送时显示目标会话标题。
    let targetSessionTitle: String
    let onSend: () -> Void
    let onClear: () -> Void
    @State private var isShowingClearConfirmation = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(L10n.plural("ui.review_comments_count", count: commentCount), systemImage: "text.bubble")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Spacer()
                Button {
                    // 放进输入框之后备注已有去处，一键清除；还没发过的备注清除前先确认。
                    if sentSessionTitle != nil {
                        onClear()
                    } else {
                        isShowingClearConfirmation = true
                    }
                } label: {
                    Label(L10n.text("ui.review_notes_clear"), systemImage: "trash")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tokens.warning)
                .accessibilityIdentifier("diffPanel.reviewNotes.clear")
            }

            ForEach(statusLines, id: \.self) { line in
                statusLineView(line, tokens: tokens)
            }

            Button(action: onSend) {
                Label(sendTitle, systemImage: "paperplane")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canSend ? tokens.accent : tokens.tertiaryText)
            .disabled(!canSend)
            .accessibilityIdentifier("diffPanel.reviewNotes.sendToAgent")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.22), lineWidth: 1)
        }
        .confirmationDialog(
            L10n.text("ui.review_notes_clear_confirmation_title"),
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("ui.review_notes_clear"), role: .destructive, action: onClear)
            Button(L10n.text("ui.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("ui.review_notes_clear_confirmation_message"))
        }
    }

    var canSend: Bool {
        if case .session = target {
            return true
        }
        return false
    }

    var statusLines: [StatusLine] {
        var lines: [StatusLine] = []
        if let sentSessionTitle {
            lines.append(.sent(sessionTitle: sentSessionTitle))
        }
        if case .unavailable(let reason) = target {
            lines.append(.unavailable(reason))
        } else if sentSessionTitle == nil {
            lines.append(.ready(sessionTitle: targetSessionTitle))
        }
        return lines
    }

    private var sendTitle: String {
        if sentSessionTitle != nil {
            return L10n.text("ui.review_notes_send_to_agent_again")
        }
        return L10n.text("ui.review_notes_send_to_agent")
    }

    @ViewBuilder
    private func statusLineView(_ line: StatusLine, tokens: ThemeTokens) -> some View {
        switch line {
        case .ready(let sessionTitle):
            Text(L10n.format("ui.review_notes_agent_ready", sessionTitle))
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .sent(let sessionTitle):
            Label(L10n.format("ui.review_notes_agent_sent", sessionTitle), systemImage: "checkmark.circle")
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.success)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("diffPanel.reviewNotes.sentFeedback")
        case .unavailable(let reason):
            Label(reason.message, systemImage: "exclamationmark.circle")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("diffPanel.reviewNotes.unavailableReason")
        }
    }
}

import SwiftUI

/// 改动面板的审查备注区：把备注放进目标会话的输入框（不自动发送），以及一键清除。
struct GitReviewNotesAgentBox: View {
    enum Status: Equatable {
        /// 可以发送，会追加到这个会话的输入框。
        case ready(sessionTitle: String)
        /// 备注都已放进输入框，等用户确认后发送。
        case sent(sessionTitle: String)
        case unavailable(ReviewNotesAgentUnavailableReason)
    }

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let commentCount: Int
    let status: Status
    let canSend: Bool
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
                    if case .sent = status {
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

            statusLine(tokens: tokens)

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

    private var sendTitle: String {
        if case .sent = status {
            return L10n.text("ui.review_notes_send_to_agent_again")
        }
        return L10n.text("ui.review_notes_send_to_agent")
    }

    @ViewBuilder
    private func statusLine(tokens: ThemeTokens) -> some View {
        switch status {
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

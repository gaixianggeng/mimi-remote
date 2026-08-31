import SwiftUI

struct WriterConflictCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let sourceIsRunning: Bool
    let availability: WriterConflictForkAvailability?
    let errorMessage: String?
    let isDuplicating: Bool
    let isRetrying: Bool
    let onFork: () -> Void
    let onRecheck: () -> Void
    let onRetry: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                message(tokens: tokens)
                Spacer(minLength: 12)
                wideActions(tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 12) {
                message(tokens: tokens)
                compactActions(tokens: tokens)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.elevatedSurface, in: shape)
        .overlay {
            // 这条边框表达 writer 冲突，而不是装饰性抬升；保留克制的 warning 语义。
            shape.strokeBorder(tokens.warning.opacity(0.36), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func message(tokens: ThemeTokens) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock")
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(tokens.writerConflictWarningIcon)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("ui.codex_active_writer_conflict_title"))
                    .font(themeStore.uiFont(.body, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(messageBody)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.writerConflictBodyText)
                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.writerConflictErrorText)
                        .padding(.top, 2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var messageBody: String {
        guard let availability else {
            return L10n.text("ui.codex_active_writer_conflict")
        }
        if availability == .unavailableNoTerminalTurn {
            return L10n.text("ui.writer_conflict_fork_no_terminal_turn")
        }
        if sourceIsRunning {
            return L10n.text("ui.writer_conflict_fork_running_explanation")
        }
        return L10n.text("ui.writer_conflict_fork_idle_explanation")
    }

    @ViewBuilder
    private func wideActions(tokens: ThemeTokens) -> some View {
        HStack(spacing: 12) {
            retryButton(tokens: tokens)
            if availability != nil {
                primaryButton(tokens: tokens)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func compactActions(tokens: ThemeTokens) -> some View {
        if availability != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    retryButton(tokens: tokens)
                    primaryButton(tokens: tokens)
                }
                VStack(spacing: 8) {
                    primaryButton(tokens: tokens)
                        .frame(maxWidth: .infinity)
                    retryButton(tokens: tokens)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            retryButton(tokens: tokens)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func retryButton(tokens: ThemeTokens) -> some View {
        Button(action: onRetry) {
            Group {
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.text("ui.retry"))
                }
            }
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(tokens.primaryText)
        .disabled(isBusy)
        .accessibilityLabel(L10n.text("ui.retry_writer_access"))
        .accessibilityHint(L10n.text("ui.codex_active_writer_conflict"))
    }

    private func primaryButton(tokens: ThemeTokens) -> some View {
        Button(action: primaryAction) {
            HStack(spacing: 7) {
                if isDuplicating || availability == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.writerConflictPrimaryActionForeground)
                } else {
                    Image(systemName: "doc.on.doc")
                        .accessibilityHidden(true)
                }
                Text(primaryTitle)
            }
            .font(themeStore.uiFont(.callout, weight: .semibold))
            .foregroundStyle(tokens.writerConflictPrimaryActionForeground)
            .frame(minHeight: 44)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(tokens.primaryAction)
        .disabled(primaryDisabled)
        .accessibilityHint(messageBody)
        .accessibilitySortPriority(1)
    }

    private var isBusy: Bool {
        isRetrying || isDuplicating || availability == .checking
    }

    private var primaryDisabled: Bool {
        isBusy || availability == .unavailableNoTerminalTurn
    }

    private var primaryTitle: String {
        if isDuplicating {
            return L10n.text("ui.writer_conflict_fork_copying")
        }
        if availability == .checking {
            return L10n.text("ui.writer_conflict_fork_checking")
        }
        if availability == .failed {
            return L10n.text("ui.writer_conflict_fork_recheck")
        }
        return L10n.text("ui.writer_conflict_fork_continue")
    }

    private func primaryAction() {
        if availability == .failed {
            onRecheck()
        } else {
            onFork()
        }
    }
}

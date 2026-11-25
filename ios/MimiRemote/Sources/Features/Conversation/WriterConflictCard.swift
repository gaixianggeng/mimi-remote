import SwiftUI

struct WriterConflictCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeInterfaceStyle) private var interfaceStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var showingSharedGuide = false

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
        let shape = RoundedRectangle(cornerRadius: interfaceStyle == .glass ? 22 : 16, style: .continuous)
        let borderColor = tokens.warning.opacity(colorScheme == .dark ? 0.32 : 0.36)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                message(tokens: tokens)
                Spacer(minLength: 8)
                wideActions(tokens: tokens)
            }
            VStack(alignment: .leading, spacing: 9) {
                message(tokens: tokens)
                compactActions(tokens: tokens)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            WriterConflictCardChromeModifier(
                shape: shape,
                tokens: tokens,
                colorScheme: colorScheme,
                interfaceStyle: interfaceStyle,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased,
                borderColor: borderColor
            )
        )
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showingSharedGuide) {
            WriterConflictSharedGuideSheet()
        }
    }

    @ViewBuilder
    private func message(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    headerTitle(tokens: tokens)
                    Spacer(minLength: 8)
                    sharedGuideButton(tokens: tokens)
                }
                VStack(alignment: .leading, spacing: 3) {
                    headerTitle(tokens: tokens)
                    sharedGuideButton(tokens: tokens)
                }
            }

            Text(messageBody)
                .font(themeStore.uiFont(.caption, weight: .regular))
                .foregroundStyle(tokens.writerConflictBodyText)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.writerConflictErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerTitle(tokens: ThemeTokens) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "lock")
                .font(themeStore.uiFont(.footnote, weight: .semibold))
                .foregroundStyle(tokens.writerConflictWarningIcon)
                .accessibilityHidden(true)

            Text(L10n.text("ui.codex_active_writer_conflict_title"))
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sharedGuideButton(tokens: ThemeTokens) -> some View {
        Button {
            showingSharedGuide = true
        } label: {
            HStack(spacing: 3) {
                Text(L10n.text("ui.writer_conflict_shared_guide_link"))
                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(tokens.writerConflictBodyText)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("ui.writer_conflict_shared_guide_title"))
        .accessibilityIdentifier("writerConflict.sharedGuideButton")
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
        HStack(spacing: 8) {
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
                // 两个紧凑胶囊操作等分整行；文案保留固有宽度，空间不足时自动改为纵向。
                HStack(spacing: 8) {
                    retryButton(tokens: tokens, fillsAvailableWidth: true)
                    primaryButton(tokens: tokens, fillsAvailableWidth: true)
                }
                VStack(spacing: 6) {
                    primaryButton(tokens: tokens, fillsAvailableWidth: true)
                    retryButton(tokens: tokens, fillsAvailableWidth: true)
                }
            }
        } else {
            retryButton(tokens: tokens)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func retryButton(
        tokens: ThemeTokens,
        fillsAvailableWidth: Bool = false
    ) -> some View {
        let fillOpacity: Double = colorScheme == .dark ? 0.14 : 0.08
        return Button(action: onRetry) {
            Group {
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.text("ui.retry"))
                }
            }
            .font(themeStore.uiFont(.subheadline, weight: .medium))
            .foregroundStyle(tokens.primaryText)
            .fixedSize(horizontal: fillsAvailableWidth, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(
                minWidth: 64,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 36
            )
            .background(tokens.primaryText.opacity(fillOpacity), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .accessibilityLabel(L10n.text("ui.retry_writer_access"))
        .accessibilityHint(L10n.text("ui.codex_active_writer_conflict"))
    }

    private func primaryButton(
        tokens: ThemeTokens,
        fillsAvailableWidth: Bool = false
    ) -> some View {
        Button(action: primaryAction) {
            HStack(spacing: 6) {
                if isDuplicating || availability == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.writerConflictPrimaryActionForeground)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(themeStore.uiFont(.footnote, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(primaryTitle)
            }
            .font(themeStore.uiFont(.subheadline, weight: .semibold))
            .foregroundStyle(tokens.writerConflictPrimaryActionForeground)
            .fixedSize(horizontal: fillsAvailableWidth, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 36
            )
            .background(tokens.primaryAction, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(primaryDisabled)
        .opacity(primaryDisabled ? 0.48 : 1)
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

private struct WriterConflictCardChromeModifier: ViewModifier {
    let shape: RoundedRectangle
    let tokens: ThemeTokens
    let colorScheme: ColorScheme
    let interfaceStyle: ThemeInterfaceStyle
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let borderColor: Color

    func body(content: Content) -> some View {
        if interfaceStyle == .glass {
            content.modifier(
                PhoneFloatingGlassChromeModifier(
                    shape: shape,
                    tokens: tokens,
                    colorScheme: colorScheme,
                    reduceTransparency: reduceTransparency,
                    interactive: false,
                    increasedContrast: increasedContrast,
                    opaqueFillColor: tokens.elevatedSurface,
                    accentBorderColor: borderColor,
                    accentBorderWidth: 0.75,
                    opaqueBorderColor: borderColor,
                    opaqueBorderWidth: 0.75
                )
            )
        } else {
            content
                .background(tokens.elevatedSurface, in: shape)
                .overlay {
                    shape.strokeBorder(borderColor, lineWidth: 0.75)
                }
        }
    }
}

struct WriterConflictSharedGuideSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionCard(
                        icon: "lock",
                        iconColor: tokens.writerConflictWarningIcon,
                        title: L10n.text("ui.writer_conflict_shared_guide_why_title"),
                        body: L10n.text("ui.writer_conflict_shared_guide_why_body"),
                        tokens: tokens
                    )
                    sectionCard(
                        icon: "arrow.triangle.2.circlepath",
                        iconColor: tokens.primaryText,
                        title: L10n.text("ui.writer_conflict_shared_guide_mac_title"),
                        body: L10n.text("ui.writer_conflict_shared_guide_mac_body"),
                        tokens: tokens
                    )
                    sectionCard(
                        icon: "arrow.branch",
                        iconColor: tokens.primaryText,
                        title: L10n.text("ui.writer_conflict_shared_guide_now_title"),
                        body: L10n.text("ui.writer_conflict_shared_guide_now_body"),
                        tokens: tokens
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.writer_conflict_shared_guide_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("writerConflict.sharedGuideDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sectionCard(
        icon: String,
        iconColor: Color,
        title: String,
        body: String,
        tokens: ThemeTokens
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(themeStore.uiFont(.body, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(body)
                    .font(themeStore.uiFont(.footnote, weight: .regular))
                    .foregroundStyle(tokens.writerConflictBodyText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(tokens.elevatedSurface, in: shape)
        .overlay {
            shape.strokeBorder(tokens.border.opacity(0.6), lineWidth: 0.75)
        }
    }
}

import SwiftUI

struct WriterConflictCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeInterfaceStyle) private var interfaceStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingSharedGuide = false

    let sourceIsRunning: Bool
    let availability: WriterConflictForkAvailability?
    let errorMessage: String?
    let isDuplicating: Bool
    let isRetrying: Bool
    let onFork: () -> Void
    let onRecheck: () -> Void
    let onRetry: () -> Void
    let onOpenSharedGuide: (() -> Void)?

    init(
        sourceIsRunning: Bool,
        availability: WriterConflictForkAvailability?,
        errorMessage: String?,
        isDuplicating: Bool,
        isRetrying: Bool,
        onFork: @escaping () -> Void,
        onRecheck: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onOpenSharedGuide: (() -> Void)? = nil
    ) {
        self.sourceIsRunning = sourceIsRunning
        self.availability = availability
        self.errorMessage = errorMessage
        self.isDuplicating = isDuplicating
        self.isRetrying = isRetrying
        self.onFork = onFork
        self.onRecheck = onRecheck
        self.onRetry = onRetry
        self.onOpenSharedGuide = onOpenSharedGuide
    }

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
            // 按钮自带 44pt 命中高度（相对 36pt 可见胶囊上下各 4pt 透明余量），
            // 标准字号下收紧 4pt 间距以维持用户已验收的紧凑视觉比例；大字号下胶囊本身已超过 44pt，保留完整间距。
            VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 10 : 5) {
                message(tokens: tokens)
                compactActions(tokens: tokens)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 10 : 6)
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
            WriterConflictSharedGuideSheet(
                sourceIsRunning: sourceIsRunning,
                availability: availability
            )
        }
    }

    @ViewBuilder
    private func message(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    headerTitle(tokens: tokens)
                    Spacer(minLength: 8)
                    sharedGuideButton(
                        tokens: tokens,
                        alignment: .trailing,
                        preventsTextWrapping: true
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    headerTitle(tokens: tokens)
                    sharedGuideButton(
                        tokens: tokens,
                        alignment: .leading,
                        preventsTextWrapping: false
                    )
                }
            }

            Text(messageBody)
                .writerConflictFont(.caption, weight: .regular)
                .foregroundStyle(tokens.writerConflictBodyText)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .writerConflictFont(.caption2, weight: .medium)
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
                .writerConflictFont(.footnote, weight: .semibold)
                .foregroundStyle(tokens.writerConflictWarningIcon)
                .accessibilityHidden(true)

            Text(L10n.text("ui.codex_active_writer_conflict_title"))
                .writerConflictFont(.subheadline, weight: .semibold)
                .foregroundStyle(tokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sharedGuideButton(
        tokens: ThemeTokens,
        alignment: Alignment,
        preventsTextWrapping: Bool
    ) -> some View {
        Button {
            if let onOpenSharedGuide {
                onOpenSharedGuide()
            } else {
                showingSharedGuide = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(L10n.text("ui.writer_conflict_shared_guide_link"))
                Image(systemName: "chevron.right")
                    .writerConflictFont(.caption2, weight: .semibold)
                    .accessibilityHidden(true)
            }
            .writerConflictFont(.caption, weight: .medium)
            .foregroundStyle(tokens.writerConflictBodyText)
            .fixedSize(horizontal: preventsTextWrapping, vertical: !preventsTextWrapping)
            // 按钮自身保持至少 44×44pt 矩形命中区域；标准字号下由外层负纵向边距维持紧凑行高，
            // 大字号辅助功能模式下保留完整排版高度避免文字重叠。
            .frame(minWidth: 44, minHeight: 44, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 0 : -10)
        .accessibilityLabel(L10n.text("ui.writer_conflict_shared_guide_link"))
        .accessibilityHint(L10n.text("ui.writer_conflict_shared_guide_title"))
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
                    retryButton(
                        tokens: tokens,
                        fillsAvailableWidth: true,
                        preventsTextWrapping: true
                    )
                    primaryButton(
                        tokens: tokens,
                        fillsAvailableWidth: true,
                        preventsTextWrapping: true
                    )
                }
                VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 8 : 0) {
                    primaryButton(
                        tokens: tokens,
                        fillsAvailableWidth: true,
                        preventsTextWrapping: false
                    )
                    retryButton(
                        tokens: tokens,
                        fillsAvailableWidth: true,
                        preventsTextWrapping: false
                    )
                }
            }
        } else {
            retryButton(tokens: tokens)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func retryButton(
        tokens: ThemeTokens,
        fillsAvailableWidth: Bool = false,
        preventsTextWrapping: Bool = false
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
            .writerConflictFont(.subheadline, weight: .medium)
            .foregroundStyle(tokens.primaryText)
            .fixedSize(horizontal: preventsTextWrapping, vertical: !preventsTextWrapping)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(
                minWidth: 64,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 36
            )
            .background(tokens.primaryText.opacity(fillOpacity), in: Capsule())
            .frame(
                minWidth: 44,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 44
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .accessibilityLabel(L10n.text("ui.retry_writer_access"))
        .accessibilityHint(L10n.text("ui.codex_active_writer_conflict"))
        .accessibilityIdentifier("writerConflict.retryButton")
    }

    private func primaryButton(
        tokens: ThemeTokens,
        fillsAvailableWidth: Bool = false,
        preventsTextWrapping: Bool = false
    ) -> some View {
        Button(action: primaryAction) {
            HStack(spacing: 6) {
                if isDuplicating || availability == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.writerConflictPrimaryActionForeground)
                } else {
                    Image(systemName: "doc.on.doc")
                        .writerConflictFont(.footnote, weight: .semibold)
                        .accessibilityHidden(true)
                }
                Text(primaryTitle)
                    .multilineTextAlignment(.center)
            }
            .writerConflictFont(.subheadline, weight: .semibold)
            .foregroundStyle(tokens.writerConflictPrimaryActionForeground)
            .fixedSize(horizontal: preventsTextWrapping, vertical: !preventsTextWrapping)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(
                minWidth: 44,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 36
            )
            .background(tokens.primaryAction, in: Capsule())
            .frame(
                minWidth: 44,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 44
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(primaryDisabled)
        .opacity(primaryDisabled ? 0.48 : 1)
        .accessibilityHint(messageBody)
        .accessibilitySortPriority(1)
        .accessibilityIdentifier("writerConflict.primaryButton")
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
    @ScaledMetric(relativeTo: .body) private var sectionIconSlot: CGFloat = 22

    let sourceIsRunning: Bool
    let availability: WriterConflictForkAvailability?
    let conflictResolved: Bool

    init(
        sourceIsRunning: Bool = false,
        availability: WriterConflictForkAvailability? = .available(lastTurnID: nil),
        conflictResolved: Bool = false
    ) {
        self.sourceIsRunning = sourceIsRunning
        self.availability = availability
        self.conflictResolved = conflictResolved
    }

    static func nowSectionBodyKey(
        sourceIsRunning: Bool,
        availability: WriterConflictForkAvailability?,
        conflictResolved: Bool = false
    ) -> String {
        if conflictResolved {
            return "ui.writer_conflict_shared_guide_now_resolved_body"
        }
        guard let availability else {
            return "ui.writer_conflict_shared_guide_now_no_fork_body"
        }
        switch availability {
        case .unavailableNoTerminalTurn:
            return "ui.writer_conflict_shared_guide_now_no_terminal_turn_body"
        case .checking, .failed:
            return "ui.writer_conflict_shared_guide_now_pending_body"
        case .available:
            return sourceIsRunning
                ? "ui.writer_conflict_shared_guide_now_running_body"
                : "ui.writer_conflict_shared_guide_now_body"
        }
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let nowBodyKey = Self.nowSectionBodyKey(
            sourceIsRunning: sourceIsRunning,
            availability: availability,
            conflictResolved: conflictResolved
        )

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
                        body: L10n.text(nowBodyKey),
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
                .writerConflictFont(.body, weight: .semibold)
                .foregroundStyle(iconColor)
                .frame(width: sectionIconSlot, height: sectionIconSlot)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .writerConflictFont(.subheadline, weight: .semibold)
                    .foregroundStyle(tokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(body)
                    .writerConflictFont(.footnote, weight: .regular)
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

/// ThemeStore.uiFont 只处理应用内字号倍率；冲突卡与共享引导另外跟随系统动态字体。
private struct WriterConflictDynamicFontModifier: ViewModifier {
    @EnvironmentObject private var themeStore: ThemeStore
    @ScaledMetric private var pointSize: CGFloat
    let weight: Font.Weight

    init(style: Font.TextStyle, weight: Font.Weight) {
        _pointSize = ScaledMetric(
            wrappedValue: Self.baseSize(for: style),
            relativeTo: style
        )
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(themeStore.uiFont(size: pointSize, weight: weight))
    }

    private static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .body:
            17
        case .subheadline:
            15
        case .footnote:
            13
        case .caption:
            12
        case .caption2:
            11
        default:
            17
        }
    }
}

private extension View {
    func writerConflictFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(WriterConflictDynamicFontModifier(style: style, weight: weight))
    }
}

import SwiftUI

/// 侧栏标题旁的 AI 账号剩余用量入口。与设置页共享三环和窗口选择规则，
/// 在窄侧栏里只缩小图形，仍保留完整的 44pt 点击区。
struct AIUsageRingsControl: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let codexDisplay: CodexUsageWindowsDisplay
    let claudeDisplay: CodexUsageWindowsDisplay
    let includesClaude: Bool
    let usesCondensedVisual: Bool
    let onRefresh: () async -> Void

    init(
        codexDisplay: CodexUsageWindowsDisplay,
        claudeDisplay: CodexUsageWindowsDisplay,
        includesClaude: Bool,
        usesCondensedVisual: Bool = false,
        onRefresh: @escaping () async -> Void
    ) {
        self.codexDisplay = codexDisplay
        self.claudeDisplay = claudeDisplay
        self.includesClaude = includesClaude
        self.usesCondensedVisual = usesCondensedVisual
        self.onRefresh = onRefresh
    }

    @State private var showsDetails = false
    @State private var isRefreshing = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let metrics = CodexUsageRingMetrics(
            isCompact: horizontalSizeClass == .compact,
            usesCondensedVisual: usesCondensedVisual
        )
        let items = usageItems(tokens: tokens)

        CombinedUsageRingsGraphic(
            items: items,
            // 三环也是稳定的品牌识别；额度未接入时保留灰色轨道，不退化成单环。
            expectedRingCount: 3,
            diameter: metrics.diameter,
            lineWidth: metrics.lineWidth,
            ringSpacing: metrics.ringSpacing
        )
        .frame(width: metrics.hitSize, height: metrics.hitSize)
        .contentShape(Rectangle())
        .onTapGesture {
            showsDetails.toggle()
        }
        .hoverEffect(.highlight)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L10n.text("ui.token_quota"))
        .accessibilityValue(accessibilityValue(items: items))
        .accessibilityIdentifier("sidebar.codexUsageRings")
        .accessibilityAction {
            showsDetails.toggle()
        }
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            usageDetails(tokens: tokens)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.height(360), .medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func usageDetails(tokens: ThemeTokens) -> some View {
        let items = usageItems(tokens: tokens)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("ui.token_quota"))
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(windowSummaryText)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await refreshUsage() }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.secondaryText)
                .background(tokens.surface.opacity(0.72), in: Circle())
                .overlay {
                    Circle()
                        .stroke(tokens.border.opacity(0.72), lineWidth: 1)
                }
                .disabled(isRefreshing)
                .accessibilityLabel(L10n.format("ui.refresh_value_usage", "AI"))
            }

            VStack(spacing: 14) {
                if items.isEmpty {
                    Text(L10n.text("ui.after_refreshing_the_account_window_currently_returned_by"))
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().overlay(tokens.border.opacity(0.72))
                        }
                        usageWindowRow(item: item, tokens: tokens)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                usageCreditLine(name: "Codex", display: codexDisplay)
                if includesClaude {
                    usageCreditLine(name: "Claude", display: claudeDisplay)
                }
            }
            .foregroundStyle(tokens.secondaryText)
        }
        .padding(16)
        .frame(width: horizontalSizeClass == .compact ? nil : 320)
        .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil, alignment: .leading)
    }

    private func usageWindowRow(item: CombinedUsageItem, tokens: ThemeTokens) -> some View {
        let progress = item.window.remainingProgress ?? 0

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .stroke(item.tint, lineWidth: 2.5)
                    .frame(width: 12, height: 12)
                Text("\(item.providerName) · \(item.window.label)")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .monospacedDigit()
                Text(item.window.title)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)

                Spacer(minLength: 8)

                Text(item.window.remainingText)
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(
                        item.window.remainingProgress == nil ? tokens.secondaryText : item.tint
                    )
                    .monospacedDigit()
            }

            ProgressView(value: progress)
                .tint(item.tint)
                .opacity(item.window.remainingProgress == nil ? 0.3 : 1)

            Text(item.window.resetText)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.format("ui.value_remaining_usage", item.window.accessibilityName)
        )
        .accessibilityValue(
            L10n.format(
                "ui.usage_window_accessibility_value",
                item.window.remainingText,
                item.window.resetText
            )
        )
    }

    private func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await onRefresh()
    }

    private func usageItems(tokens: ThemeTokens) -> [CombinedUsageItem] {
        CombinedUsageItem.make(
            codexDisplay: codexDisplay,
            claudeDisplay: claudeDisplay,
            includesClaude: includesClaude,
            claudeShortTint: tokens.accent
        )
    }

    private var windowSummaryText: String {
        var summaries = [codexDisplay.windowSummaryText]
        if includesClaude {
            summaries.append(claudeDisplay.windowSummaryText)
        }
        return summaries.joined(separator: " · ")
    }

    private func usageCreditLine(
        name: String,
        display: CodexUsageWindowsDisplay
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: display.hasLiveData ? "checkmark.seal" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
            // name 与 creditText 已分别完成本地化；按原文组合，避免 Xcode 抽取裸 `%@: %@` key。
            Text(verbatim: "\(name): \(display.creditText)")
                .font(themeStore.uiFont(.caption, weight: .medium))
                .lineLimit(2)
        }
    }

    private func accessibilityValue(items: [CombinedUsageItem]) -> String {
        guard !items.isEmpty else {
            return L10n.text("ui.account_usage_has_not_been_obtained_yet")
        }
        return items
            .map { "\($0.providerName)\($0.window.accessibilityName)\($0.window.remainingText)" }
            .joined(separator: L10n.text("ui.list_separator"))
    }
}

/// 顶层导航只维护语义与 outline / fill 配对，避免 iPhone Tab 与 iPad 侧栏各自挑选图标。
enum WorkbenchNavigationIcon {
    case sessions
    case workspaces
    case me

    var normalSystemName: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .workspaces: return "folder"
        case .me: return "person.crop.circle"
        }
    }

    var selectedSystemName: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right.fill"
        case .workspaces: return "folder.fill"
        case .me: return "person.crop.circle.fill"
        }
    }

    func systemName(isSelected: Bool) -> String {
        isSelected ? selectedSystemName : normalSystemName
    }
}

/// 固定导航入口自绘选中态，避免 iOS 26 SidebarListStyle 自动套用过圆的胶囊背景。
struct WorkbenchSidebarDestinationButton: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let icon: WorkbenchNavigationIcon
    let isSelected: Bool
    let tokens: ThemeTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon.systemName(isSelected: isSelected))
                    .font(themeStore.uiFont(size: 18, weight: isSelected ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.primaryAction)
                    .frame(width: 24)

                Text(title)
                    .font(themeStore.uiFont(.body, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tokens.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                isSelected ? tokens.selectionFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tokens.primaryAction)
                        .frame(width: 3, height: 22)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
    }
}

/// 宽屏浮动侧栏让列表铺满整列，底部操作只作为局部玻璃控件叠加；
/// 其他布局仍保留稳定 Footer，避免改变 iPhone 与覆盖式侧栏行为。
struct WorkbenchSidebarContentLayout<Content: View, Footer: View>: View {
    let usesFloatingSurface: Bool
    private let content: Content
    private let footer: Footer

    init(
        usesFloatingSurface: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.usesFloatingSurface = usesFloatingSurface
        self.content = content()
        self.footer = footer()
    }

    @ViewBuilder
    var body: some View {
        if usesFloatingSurface {
            content
                // 最后一行可以滚到按钮上方，但列表视口与背景仍完整延伸到底部。
                .contentMargins(.bottom, 64, for: .scrollContent)
                .overlay(alignment: .bottom) {
                    footer
                }
        } else {
            VStack(spacing: 0) {
                content
                footer
            }
        }
    }
}

/// 全局配置放左侧，主创建动作放右侧；两端布局在侧栏高度变化时保持稳定。
struct WorkbenchSidebarFooter: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let tokens: ThemeTokens
    let usesFloatingSurface: Bool
    let bottomSafeAreaInset: CGFloat
    let isMeSelected: Bool
    let onOpenSettings: () -> Void
    let onNewSession: () -> Void
    let newSessionPresentationNamespace: Namespace.ID?

    init(
        tokens: ThemeTokens,
        usesFloatingSurface: Bool = false,
        bottomSafeAreaInset: CGFloat = 0,
        isMeSelected: Bool = false,
        onOpenSettings: @escaping () -> Void,
        onNewSession: @escaping () -> Void,
        newSessionPresentationNamespace: Namespace.ID? = nil
    ) {
        self.tokens = tokens
        self.usesFloatingSurface = usesFloatingSurface
        self.bottomSafeAreaInset = bottomSafeAreaInset
        self.isMeSelected = isMeSelected
        self.onOpenSettings = onOpenSettings
        self.onNewSession = onNewSession
        self.newSessionPresentationNamespace = newSessionPresentationNamespace
    }

    var body: some View {
        // footer 下方还包含系统安全区；向下补偿其一半（最多 10pt），让控件在整块可见底栏中视觉居中，
        // 同时仍把完整触控区域留在安全区之上。
        let safeAreaVisualOffset = min(max(bottomSafeAreaInset, 0) / 2, 10)

        Group {
            if #available(iOS 26.0, *), usesFloatingSurface, !reduceTransparency {
                // 两个按钮由系统统一合成，但间距足够大，不会在静止状态下粘连成一整块玻璃。
                GlassEffectContainer(spacing: 16) {
                    footerButtonRow
                }
            } else {
                // iOS 18–25 直接使用同一行普通按钮，不额外模拟玻璃合成。
                footerButtonRow
            }
        }
        .offset(y: safeAreaVisualOffset)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if !usesFloatingSurface {
                Rectangle()
                    .fill(tokens.border.opacity(0.55))
                    .frame(height: 1)
            }
        }
    }

    private var footerButtonRow: some View {
        HStack {
            meButton

            Spacer(minLength: 0)

            newSessionButton
        }
    }

    @ViewBuilder
    private var meButton: some View {
        Group {
            if #available(iOS 26.0, *), usesFloatingSurface, !reduceTransparency {
                Button(action: onOpenSettings) {
                    compactMeButtonLabel
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .foregroundStyle(isMeSelected ? tokens.primaryAction : tokens.secondaryText)
                // 视觉胶囊使用系统紧凑尺寸，外层仍保留 44pt 触控高度。
                .frame(minHeight: 44)
                .contentShape(Capsule())
            } else {
                Button(action: onOpenSettings) {
                    meButtonLabel
                }
                .buttonStyle(.plain)
                .foregroundStyle(isMeSelected ? tokens.primaryAction : tokens.secondaryText)
                .background {
                    if usesFloatingSurface, !reduceTransparency {
                        // 旧系统的浮动侧栏使用普通材质，保留层级但不仿制 Liquid Glass。
                        Capsule().fill(.regularMaterial)
                    } else {
                        Capsule().fill(
                            isMeSelected ? tokens.selectionFill : tokens.surface.opacity(0.72)
                        )
                    }
                }
                .overlay {
                    Capsule()
                        .stroke(tokens.border.opacity(0.6), lineWidth: 1)
                }
            }
        }
        .accessibilityLabel(L10n.text("ui.me"))
        .accessibilityValue(
            isMeSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected")
        )
        .accessibilityAddTraits(isMeSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.me")
    }

    private var meButtonLabel: some View {
        compactMeButtonLabel
            .padding(.horizontal, 12)
            .frame(height: 44)
    }

    private var compactMeButtonLabel: some View {
        Label {
            Text(L10n.text("ui.me"))
                .font(themeStore.uiFont(.subheadline, weight: .medium))
        } icon: {
            WorkbenchChromeIcon(
                systemName: WorkbenchNavigationIcon.me.systemName(
                    isSelected: isMeSelected
                )
            )
        }
    }

    @ViewBuilder
    private var newSessionButton: some View {
        if let newSessionPresentationNamespace {
            newSessionButtonContent
                .matchedTransitionSource(
                    id: NewSessionPresentationSource
                        .sidebarNewSession
                        .transitionSourceID,
                    in: newSessionPresentationNamespace
                )
        } else {
            newSessionButtonContent
        }
    }

    @ViewBuilder
    private var newSessionButtonContent: some View {
        Group {
            if #available(iOS 26.0, *), usesFloatingSurface, !reduceTransparency {
                Button(action: onNewSession) {
                    newSessionIcon
                }
                // 只让系统 ButtonStyle 绘制一层主题色玻璃，不再在 label 内叠材质和白色描边。
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                // 视觉尺寸交给系统控件，44pt 仅作为可点击区域，避免玻璃圆面被二次放大。
                .frame(
                    minWidth: WorkbenchChromeIconMetrics.minimumHitTarget,
                    minHeight: WorkbenchChromeIconMetrics.minimumHitTarget
                )
                .contentShape(Circle())
                .tint(tokens.primaryAction)
                .foregroundStyle(tokens.primaryActionForeground)
            } else {
                // iOS 18–25 与 Reduce Transparency 共用清晰的实色主操作按钮。
                Button(action: onNewSession) {
                    newSessionIcon
                        .frame(width: 36, height: 36)
                        .background(tokens.primaryAction, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(tokens.primaryAction.opacity(0.72), lineWidth: 1)
                        }
                        .contentShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.primaryActionForeground)
            }
        }
        .accessibilityLabel(L10n.text("ui.new_session_3da224c4"))
        .accessibilityIdentifier("sidebar.newSession")
    }

    private var newSessionIcon: some View {
        // 加号在通用 15pt 规格下实际墨迹偏小且略向下；主创建动作单独做光学校正，避免误伤其他图标。
        Image(systemName: "plus")
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 20, height: 20)
            .offset(y: -0.5)
    }
}

/// 侧边栏是任务监视器，不重复主列表的路径和完整状态；形状先表达优先级，
/// 文字只补充“为什么需要回来”与紧凑时间，灰阶和窄栏下仍可扫读。
struct SessionSidebarMonitorRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: AgentSession
    let kind: SessionSidebarSectionKind
    let isSelected: Bool
    let isRecentlyCompleted: Bool
    let completionObservedAt: Date?
    var showsStateMarker: Bool = true
    let projectIcon: WorkspaceProjectIconContent?
    let runtimeActivitySnapshot: RuntimeActivitySnapshot?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 6) {
            // 所有状态共用固定 leading 槽；同项目后续行只隐藏视觉菊花，
            // 仍保留“进行中”无障碍语义，同时避免标题横向跳动。
            Group {
                if showsStateMarker {
                    stateMarker(tokens: tokens)
                } else if kind == .running {
                    Color.clear
                        .accessibilityLabel(L10n.text("ui.in_progress"))
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
                .frame(width: 12, height: 12)

            Group {
                if let projectIcon {
                    WorkspaceProjectIconTile(content: projectIcon, size: 18, tokens: tokens)
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 18, height: 18)

            Text(SessionListPresentation.titleDisplayText(for: session))
                .font(themeStore.uiFont(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)
            detail(tokens: tokens)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill(tokens: tokens))
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(tokens.primaryAction)
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 1)
            }
        }
        .animation(
            MimiMotion.stateTransition.animation(reduceMotion: reduceMotion),
            value: isRecentlyCompleted
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stateMarker(tokens: ThemeTokens) -> some View {
        switch kind {
        case .needYou:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tokens.warning.opacity(0.20))
                .overlay {
                    Image(systemName: "exclamationmark")
                        .font(themeStore.uiFont(size: 7, weight: .bold))
                        .foregroundStyle(tokens.warning)
                }
                .accessibilityLabel(L10n.text("ui.needs_you"))
        case .running:
            // 运行态直接使用系统不定进度菊花：由系统负责持续动画、Reduce Motion
            // 与前后台恢复，避免自绘缺口圆环停留在静态帧。
            ProgressView()
                .controlSize(.mini)
                .tint(tokens.primaryAction)
                .accessibilityLabel(L10n.text("ui.in_progress"))
        case .justCompleted, .pinned, .recent:
            Color.clear
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func detail(tokens: ThemeTokens) -> some View {
        Group {
            switch kind {
            case .needYou:
                Text(
                    session.pendingApproval != nil
                        ? L10n.text("ui.pending_approval")
                        : L10n.text("ui.waiting_for_input")
                )
            case .running:
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(runningDuration(at: context.date))
                }
            case .justCompleted:
                if let date = completionObservedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(compactRelativeDuration(from: date, to: context.date))
                    }
                }
            case .pinned, .recent:
                if let date = session.recencyAt ?? session.updatedAt ?? session.createdAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(compactRelativeDuration(from: date, to: context.date))
                    }
                }
            }
        }
        .font(themeStore.uiFont(size: 10.5, weight: .regular))
        .foregroundStyle(tokens.tertiaryText)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func rowFill(tokens: ThemeTokens) -> Color {
        if isRecentlyCompleted {
            return tokens.success.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
        if isSelected {
            return tokens.selectionFill
        }
        return .clear
    }

    private func runningDuration(at now: Date) -> String {
        let start = runtimeActivitySnapshot?.turnStartedAt
            ?? session.updatedAt
            ?? session.createdAt
            ?? now
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    private func compactRelativeDuration(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

struct CodexUsageRingMetrics {
    let diameter: CGFloat
    let lineWidth: CGFloat
    let ringSpacing: CGFloat
    let hitSize: CGFloat

    init(isCompact: Bool, usesCondensedVisual: Bool = false) {
        if usesCondensedVisual {
            diameter = 30
            lineWidth = 3
            ringSpacing = 1.4
        } else {
            diameter = isCompact ? 32 : 36
            lineWidth = isCompact ? 3 : 3.2
            ringSpacing = isCompact ? 1.5 : 1.8
        }
        // 图形在 iPhone 上收紧，但点击区始终保持 44pt，兼顾窄屏排版和触控可用性。
        hitSize = 44
    }
}

#if DEBUG
#Preview(L10n.text("ui.token_quota")) {
    let codex = CodexUsageWindowsDisplay.make(
        rateLimit: RateLimitSummary(
            limitName: "Codex",
            secondaryUsedPercent: 44,
            secondaryWindowDurationMins: 10_080
        )
    )
    let claude = CodexUsageWindowsDisplay.make(
        rateLimit: RateLimitSummary(
            limitName: "Claude",
            primaryUsedPercent: 48,
            secondaryUsedPercent: 0,
            primaryWindowDurationMins: 10_080,
            secondaryWindowDurationMins: 300
        ),
        fallbackDisplayName: "Claude"
    )
    let pending = CodexUsageWindowsDisplay.make(rateLimit: nil)

    HStack(spacing: 24) {
        AIUsageRingsControl(
            codexDisplay: codex,
            claudeDisplay: claude,
            includesClaude: true,
            onRefresh: {}
        )
            .environment(\.horizontalSizeClass, .regular)
        AIUsageRingsControl(
            codexDisplay: codex,
            claudeDisplay: claude,
            includesClaude: true,
            onRefresh: {}
        )
            .environment(\.horizontalSizeClass, .compact)
        AIUsageRingsControl(
            codexDisplay: pending,
            claudeDisplay: pending,
            includesClaude: true,
            onRefresh: {}
        )
            .environment(\.horizontalSizeClass, .compact)
    }
    .environmentObject(ThemeStore())
    .padding(20)
}
#endif

import SwiftUI

/// 会话行的几何档位。
///
/// 只保留 `compact` 与 `table` 两档：`rail` 曾经为侧栏准备，但 `resolved` 从不返回它、
/// 也没有任何调用点显式传入，留着只会让人以为侧栏复用了这个组件（侧栏有自己的
/// `ProjectSidebarView.SessionRow`）。
///
/// 两档共用字号和基础轨道。工作区总览另外压低视觉密度，但命中高度仍超过 44pt。
enum SessionIndexRowDensity: Equatable {
    case compact
    case table

    /// 行高。两行内容加上下留白后仍要留出呼吸量——过去 60/44 的行高把两行文字压在
    /// 一起，配合逐行分隔线读成一张表格；列表需要的是可扫读的条目，不是表格。
    ///
    /// 工作区行与带摘要的 iPad 会话行保持 68pt；手机会话行另收敛到 52pt。
    var minimumHeight: CGFloat { 68 }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 12
        case .table: 14
        }
    }

    /// 标题与元数据行之间的间距。比行与行之间的留白小得多，两行才会读成一个整体。
    var contentSpacing: CGFloat { 4 }

    // 字号不属于密度档位：密度只回答"这么宽能不能排下一条固定的身份列"，正文多大与屏幕
    // 宽窄无关。会话行与设置行、侧栏共用同一套字号（#563），见 `SessionIndexRow` 的
    // `titlePointSize` 等 `@ScaledMetric`。

    /// 前导槽。宽度恒定预留，标题因此在所有行上落在同一条竖线上。
    ///
    /// 与设置行的图标槽同宽（`SettingsLayoutMetrics.iconSlot`），四个 Tab 的行文字
    /// 落在同一条竖线上（#563）。
    var stateGutterWidth: CGFloat { 24 }

    /// 状态字形在槽内的绘制尺寸，比槽略小以便居中。
    var stateGlyphSize: CGFloat { 16 }

    var stateGutterSpacing: CGFloat {
        switch self {
        case .compact: 8
        case .table: 10
        }
    }

    /// 第二行末端身份槽的宽度（分支或项目名）。定宽让它成为一条右轨，
    /// 而不是跟着文字长度在每行漂移。
    ///
    /// 分支只是丰富信息、不是判断依据，因此紧凑宽度刻意压到可用宽度的四分之一上下：
    /// 116pt 在 iPhone 上会把分支图标顶到行的正中间，读起来像是一列主要信息。
    var identityColumnWidth: CGFloat {
        switch self {
        case .compact: 92
        case .table: 180
        }
    }

    /// 宽屏优先表格密度；辅助功能字号必须回退紧凑布局，避免固定列截断状态和时间。
    static func resolved(
        prefersTable: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) -> SessionIndexRowDensity {
        prefersTable && !dynamicTypeSize.isAccessibilitySize ? .table : .compact
    }

    /// 会话 tab 与工作区共用的宽度判据。
    ///
    /// 过去两边各用一套信号——会话 tab 读页面身份 (`prefersSessionTableDensity`)、
    /// 工作区量实际宽度——同一个窗口宽度可能得到两个不同的密度答案，Split View
    /// 拖动过程中尤其明显。判据必须只有一个。
    /// 阈值必须把手机和窄分栏留在 compact 一侧。
    ///
    /// 曾经取 360，结果 393pt 的 iPhone 落进 `.table`：那一档用 180pt 的定宽身份列，
    /// 在手机上接近半行宽度，分支被顶到行的正中间、摘要被压成两三个字。
    /// 600 复现了页面身份时代的意图——iPhone 390 与分栏 375 走 compact，
    /// iPad mini 竖屏 744 及以上走 table。
    static let tableWidthThreshold: CGFloat = 600

    static func resolved(
        availableWidth: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> SessionIndexRowDensity {
        resolved(
            prefersTable: availableWidth >= tableWidthThreshold,
            dynamicTypeSize: dynamicTypeSize
        )
    }
}

struct SessionRuntimePresentation: Equatable {
    enum Kind: Equatable {
        case codex
        case claude
    }

    let kind: Kind

    init(session: AgentSession) {
        self.init(runtimeProvider: session.runtimeProvider, source: session.source)
    }

    init(runtimeProvider: String?, source: String) {
        let provider = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = provider?.isEmpty == false ? provider : source
        kind = CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue) == "claude"
            ? .claude
            : .codex
    }

    var title: String {
        switch kind {
        case .codex:
            return L10n.text("ui.runtime_default")
        case .claude:
            return L10n.text("ui.runtime_optional")
        }
    }

    var brandMark: RuntimeBrandMark {
        switch kind {
        case .codex:
            return .openAI
        case .claude:
            return .claude
        }
    }
}

/// 未读只是一条历史结果的轻量提示，不承担进行状态，也不参与点击命中区域。
/// 视觉点隐藏给 VoiceOver，完整语义由会话行的 accessibilityValue 提供。
///
/// 会话行本身已经改用合并后的 `SessionRowStateGlyph`；这个组件保留给侧栏
/// (`ProjectSidebarView`) 继续使用。
struct SessionUnreadIndicator: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Circle()
            .fill(tokens.primaryAction)
            .frame(width: 7, height: 7)
            .overlay {
                Circle()
                    .stroke(tokens.background.opacity(0.72), lineWidth: 0.75)
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// 会话行前导槽里那一枚字形所表达的状态。
///
/// 过去这些信息散落在三个位置：左侧导轨（只画失败/等待，普通行恒空）、第二行的状态
/// 图标、第一行末尾的未读点。未读点尤其糟——它跟在变宽的时间后面，每行落在不同的
/// 横坐标上，根本没法当成一列来扫。
///
/// 合并成一枚字形放在固定横坐标上之后，顺着一条竖线就能读完整列状态。
enum SessionRowState: Equatable {
    case failed
    case waiting
    case running
    case unread

    /// 优先级：失败 > 等待 > 运行中 > 未读。一行只画一枚，越需要人介入的越靠前。
    static func resolve(
        status: AgentSessionDisplayStatus,
        isUnread: Bool
    ) -> SessionRowState? {
        switch status.tone {
        case .danger:
            return .failed
        case .warning:
            return .waiting
        case .active:
            return .running
        case .complete, .neutral:
            return isUnread ? .unread : nil
        }
    }
}

/// 会话行前导槽放什么。
///
/// - 会话 tab 汇集两种来源，槽里放来源标记；未读小点跟在标题后面，不占用正文起点。
/// - 工作区顶部已经按 Codex / Claude 筛选，每行来源都一样，不画前导槽（`.none`），
///   标题直接与分组标题对齐。
/// - `.state` 是旧式详细行，槽里放会话状态字形。
enum SessionIndexRowLeadingSlot: Equatable {
    case state
    case runtimeIcon
    case none
}

/// 身份槽没有可展示分支时使用什么信息。
///
/// 会话 tab 跨项目，项目名是必要身份；工作区已经固定项目，目录末段更能区分不同 worktree。
enum SessionIndexRowIdentityFallback: Equatable {
    case project
    case directory
    /// 当前列表只有一个项目时，身份已由页面上下文说明。
    case none
}

/// 前导状态字形。需要处理与运行中的状态保留独立形状；
/// 未读只用小点与 VoiceOver 文案提示，不改变整行标题的视觉权重。
struct SessionRowStateGlyph: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: SessionRowState?
    let size: CGFloat
    /// 无状态时是否画一枚灰色空心环兜底。
    ///
    /// 这一列要能当作小节标题的基准线，前提是它**每一行都有东西**——否则整段完成态
    /// 会话会让标题悬在空白左边。系统之外的参照是 Linear：待办行同样画一枚空心灰环，
    /// 那一列因此从不缺席。
    var drawsIdlePlaceholder = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let animatesRunningRing = Self.shouldAnimate(state: state, reduceMotion: reduceMotion)

        Group {
            switch state {
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(themeStore.uiFont(size: size, weight: .semibold))
                    .foregroundStyle(Color.red)
            case .waiting:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(themeStore.uiFont(size: size - 1, weight: .semibold))
                    .foregroundStyle(tokens.warning)
            case .running:
                // 旋转角度只由当前时间决定，不从 onAppear 反复提交 repeatForever。
                // 行视图即使被列表重复复用，也始终只有一个动画时间源，不会叠加加速。
                TimelineView(.animation(paused: !animatesRunningRing)) { context in
                    Circle()
                        .trim(from: 0.08, to: 0.86)
                        .stroke(
                            tokens.primaryAction,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(
                            .degrees(
                                Self.runningRotation(
                                    at: context.date,
                                    animates: animatesRunningRing
                                )
                            )
                        )
                        .frame(width: size, height: size)
                }
            case .unread:
                Circle()
                    .fill(tokens.sessionUnreadAccent)
                    .frame(width: 6, height: 6)
            case nil:
                if drawsIdlePlaceholder {
                    // 虚线环。和"运行中"那枚缺口环的区别落在**形状**上，而不是靠颜色深浅——
                    // 虚实之分即使在色觉障碍或纯灰度下也读得出来，这是细一档描边做不到的。
                    //
                    // 描边不能再细了：1.25pt 配 border 色在实机上糊成一团灰雾，读不出是个环。
                    // 这一列是小节标题的基准线，它必须看得清才立得住。
                    Circle()
                        .strokeBorder(
                            tokens.tertiaryText,
                            style: StrokeStyle(lineWidth: 1.75, dash: [2, 2.5])
                        )
                        .frame(width: size - 2, height: size - 2)
                } else {
                    Color.clear
                }
            }
        }
        // 宽度恒定：普通行也占同样的槽位，标题才不会因为有没有状态而左右跳。
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static let runningCycleDuration = 0.9

    static func runningRotation(at date: Date, animates: Bool) -> Double {
        guard animates else { return 0 }

        let elapsedInCycle = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: runningCycleDuration)
        return elapsedInCycle / runningCycleDuration * 360
    }

    static func shouldAnimate(
        state: SessionRowState?,
        reduceMotion: Bool
    ) -> Bool {
        state == .running && !reduceMotion
    }
}

/// 会话列表里的运行时标识使用中性胶囊承载品牌图标和名称。
/// 它需要比普通元数据更容易扫读，但不能抢过会话标题和需要处理的状态。
struct SessionRuntimeBadge: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let presentation: SessionRuntimePresentation
    var compact = false

    init(session: AgentSession, compact: Bool = false) {
        presentation = SessionRuntimePresentation(session: session)
        self.compact = compact
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let iconSize: CGFloat = compact ? 10 : 12

        HStack(spacing: compact ? 3 : 4) {
            RuntimeBrandMarkIcon(mark: presentation.brandMark, size: iconSize)

            Text(presentation.title)
                .lineLimit(1)
        }
        .font(themeStore.uiFont(size: compact ? 9 : 10, weight: .medium))
        .foregroundStyle(tokens.secondaryText)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1.5 : 2)
        .background(tokens.elevatedSurface.opacity(0.76), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tokens.border.opacity(0.54), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 置顶属于用户主动设置的稳定状态，用品牌紫实底与白色钉子提升扫读辨识度。
/// 组件统一服务规划 Tab、工作区最近规划和侧栏，避免三个入口各自使用不同强调方式。
struct SessionPinnedBadge: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var compact = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        // 色块只承担置顶强调，不应比同一列表中的运行时图标更抢眼。
        let side: CGFloat = compact ? 14 : 17
        let cornerRadius: CGFloat = compact ? 4 : 5

        Image(systemName: "pin.fill")
            .font(themeStore.uiFont(size: compact ? 7 : 8, weight: .bold))
            .foregroundStyle(tokens.primaryActionForeground)
            .frame(width: side, height: side)
            .background(
                tokens.primaryAction,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(tokens.primaryActionForeground.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("ui.pinned"))
            .fixedSize()
    }
}

/// 使用 Codex 与 Claude Code 桌面端都采用的经典三节点分支拓扑。
/// 自绘可以避免 SF Symbol 的三角轮廓，同时维持小尺寸下的圆角描边与清晰度。
struct SessionBranchIcon: View {
    let size: CGFloat

    var body: some View {
        SessionBranchGlyph()
            .stroke(
                style: StrokeStyle(
                    lineWidth: max(0.75, size * 0.08125),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .fixedSize()
    }
}

private struct SessionBranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2
        )
        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(x: origin.x + side * x, y: origin.y + side * y)
        }
        let nodeRadius = side * 0.11875
        let upperNode = point(0.296875, 0.234375)
        let lowerNode = point(0.296875, 0.765625)
        let branchNode = point(0.75, 0.65625)

        var path = Path()
        for center in [upperNode, lowerNode, branchNode] {
            path.addEllipse(
                in: CGRect(
                    x: center.x - nodeRadius,
                    y: center.y - nodeRadius,
                    width: nodeRadius * 2,
                    height: nodeRadius * 2
                )
            )
        }

        path.move(to: point(0.296875, 0.353125))
        path.addLine(to: point(0.296875, 0.646875))
        path.move(to: point(0.296875, 0.40625))
        path.addCurve(
            to: point(0.63125, 0.65625),
            control1: point(0.296875, 0.5875),
            control2: point(0.44375, 0.65625)
        )
        return path
    }
}

/// 会话行的按压反馈。会话 tab 与工作区共用同一套扁平行语言，按压手感也必须是同一份，
/// 否则同一个对象在两页里连"按下去什么感觉"都不一样。
struct SessionIndexRowButtonStyle: ButtonStyle {
    let pressedFill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? pressedFill.opacity(0.72) : .clear)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// 会话库与工作区共用同一种会话行：来源图标 + 标题 + 时间（宽屏 iPad 多一行摘要）。
/// 同一个对象在两页里长得不一样，是四个 Tab 读起来像两个系统的原因之一（#563）。
struct SessionIndexRow: View {
    /// 会话库单行的最小高度；工作区骨架屏按同一高度占位，加载前后行距不跳。
    static let libraryRowMinimumHeight: CGFloat = 52
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var environmentLocale
    @Environment(\.timeZone) private var environmentTimeZone
    /// 行内文字与设置行走同一条字号通路：先跟随系统字号（Dynamic Type），再叠应用内比例。
    /// 档位与设置页一致——标题 body 17、摘要 subheadline 15、时间与状态 footnote 13；
    /// 只放大分组标题而不放大行文字时，辅助功能字号下层级会倒过来（#563）。
    @ScaledMetric(relativeTo: .body) private var titlePointSize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var previewPointSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var metadataPointSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var statusIconPointSize: CGFloat = 9

    let session: AgentSession
    let foregroundActivity: SessionForegroundActivity?
    let isSelected: Bool
    let isPinned: Bool
    let isArchived: Bool
    let reminder: SessionReminder?
    let isObserving: Bool
    var isUnread = false
    let density: SessionIndexRowDensity
    var searchSnippet: String? = nil
    /// 详细行可选的 Git 分支；为 nil 时身份槽按调用方指定的规则回退。
    var branch: String? = nil
    /// 会话库默认回退项目名；目录身份仍可用于辅助技术说明 worktree。
    var identityFallback: SessionIndexRowIdentityFallback = .project
    /// 前导槽承载什么。会话 tab 与工作区都传 `.runtimeIcon`；`.state` 留给旧式详细行。
    var leadingSlot: SessionIndexRowLeadingSlot = .state
    /// 会话 tab 只在宽屏保留一行摘要；手机固定为来源、标题、时间三列。
    var showsSessionPreview = false
    /// `.state` 槽在无状态时是否画灰环兜底；工作区总览关闭它来降低重复噪声。
    var showsIdleStateGlyph = false
    var drawsSelectionBackground = true
    var showsNeutralHistoryStatus = false
    /// 默认读取系统时钟；工作区和确定性快照可注入固定时间，避免行内时间漂移。
    var currentDate: () -> Date = Date.init
    var calendar: Calendar? = nil
    var locale: Locale? = nil
    var timeZone: TimeZone? = nil

    static func metadataDirectoryText(for session: AgentSession) -> String {
        // 同一项目可能同时存在多个 worktree；优先展示真实工作目录，
        // 只有旧数据缺少 dir 时才回退项目名，避免列表行失去区分度。
        session.dir.isEmpty ? session.project : session.dir
    }

    static func identityFallbackText(
        for session: AgentSession,
        fallback: SessionIndexRowIdentityFallback
    ) -> String {
        switch fallback {
        case .project:
            return session.project
        case .directory:
            return SessionListPresentation.directoryDisplayText(for: session)
        case .none:
            return ""
        }
    }

    static func identityFallbackAccessibilityLabel(
        for session: AgentSession,
        fallback: SessionIndexRowIdentityFallback
    ) -> String {
        switch fallback {
        case .project:
            return "\(L10n.text("ui.project")) \(session.project)"
        case .directory:
            return L10n.format("ui.directory_value", metadataDirectoryText(for: session))
        case .none:
            return ""
        }
    }

    static func compactSupplementaryPreviewLineLimit(
        hasSearchSnippet: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) -> Int? {
        if dynamicTypeSize.isAccessibilitySize {
            return nil
        }
        return hasSearchSnippet ? 2 : 1
    }

    /// 视觉上省略的默认状态仍要交给 VoiceOver；已经显示在行内的状态不重复朗读。
    static func accessibilityValue(
        status: AgentSessionDisplayStatus,
        sessionStatus: String,
        isUnread: Bool,
        showsNeutralHistoryStatus: Bool,
        statusIsVisible: Bool = true,
        runtime: String? = nil,
        identity: String? = nil
    ) -> String {
        var values: [String] = []
        if let runtime, !runtime.isEmpty {
            values.append(runtime)
        }
        if !statusIsVisible || !showsStatusLabel(
            status: status,
            sessionStatus: sessionStatus,
            showsNeutralHistoryStatus: showsNeutralHistoryStatus
        ) {
            values.append(status.title)
        }
        if isUnread {
            values.append(L10n.text("ui.unread_result"))
        }
        if let identity, !identity.isEmpty {
            values.append(identity)
        }
        return values.joined(separator: ", ")
    }

    private static func showsStatusLabel(
        status: AgentSessionDisplayStatus,
        sessionStatus: String,
        showsNeutralHistoryStatus: Bool
    ) -> Bool {
        if showsNeutralHistoryStatus {
            return true
        }
        switch status.tone {
        case .warning, .danger, .active:
            return true
        case .complete:
            return false
        case .neutral:
            return sessionStatus != SessionStatus.history.rawValue
        }
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .center, spacing: density.stateGutterSpacing) {
            leadingGutter()

            VStack(alignment: .leading, spacing: density.contentSpacing) {
                titleLine(tokens: tokens)
                if !isSessionLibrary || showsSessionPreview {
                    metadataLine(tokens: tokens)
                }

                if !isSessionLibrary, let searchSnippet, !searchSnippet.isEmpty {
                    supplementaryPreviewText(searchSnippet, tokens: tokens, hasSearchSnippet: true)
                }
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .padding(.vertical, isSessionLibrary && !showsSessionPreview ? 4 : 8)
        .frame(maxWidth: .infinity, minHeight: rowMinimumHeight, alignment: .leading)
        .background {
            if isSelected && drawsSelectionBackground {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tokens.selectionFill)
            }
        }
        // 选中态过去还在最左画一条 3pt 胶囊。前导状态槽占的正是同一个位置，
        // 两者叠在一起会读成"状态变了"；选中只留背景填充。
    }

    private func titleLine(tokens: ThemeTokens) -> some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .firstTextBaseline, spacing: 7) {
            if isPinned && !isSessionLibrary {
                SessionPinnedBadge(compact: true)
            }

            Text(visibleTitle)
                .font(themeStore.uiFont(size: titlePointSize, weight: isSelected && !isSessionLibrary ? .semibold : .regular))
                .foregroundStyle(isSelected && !isSessionLibrary ? tokens.primaryText : tokens.listTitleText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

            if isSessionLibrary, isUnread {
                // 单行布局的未读小点跟在标题后面，不占用正文起点。
                unreadTitleIndicator(tokens: tokens)
                    .layoutPriority(2)
            }

            Spacer(minLength: 12)

            if isSessionLibrary {
                // 单行里没有第二行可放状态：需要处理或仍在运行时，状态文字占据时间的位置；
                // 提醒、只看等标记跟在它前面。普通历史行照常显示时间。
                stableStateIcons(tokens: tokens)
                if shouldShowStatusLabel {
                    animatedStatusLabel(tokens: tokens)
                } else {
                    timestamp(tokens: tokens)
                }
            } else {
                timestamp(tokens: tokens)
            }
        }
    }

    @ViewBuilder
    private func metadataLine(tokens: ThemeTokens) -> some View {
        if isSessionLibrary {
            sessionLibraryPreviewLine(tokens: tokens)
        } else {
            standardMetadataLine(tokens: tokens)
        }
    }

    @ViewBuilder
    private func sessionLibraryPreviewLine(tokens: ThemeTokens) -> some View {
        let preview = searchSnippet?.isEmpty == false
            ? searchSnippet ?? ""
            : SessionListPresentation.distinctPreviewDisplayText(for: session)
        if !preview.isEmpty {
            Text(preview)
                .font(themeStore.uiFont(size: previewPointSize))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
        }
    }

    private func standardMetadataLine(tokens: ThemeTokens) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let preview = SessionListPresentation.distinctPreviewDisplayText(for: session)
            if !preview.isEmpty {
                Text(preview)
                    .font(themeStore.uiFont(size: previewPointSize))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    // 标准省略号而不是渐隐蒙版：蒙版过去无条件施加，没溢出的短摘要
                    // 末尾也被洗淡，而且没截断时用户失去"还有更多"的提示。
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            stableStateIcons(tokens: tokens)
            animatedStatusLabel(tokens: tokens)
            identityColumn(tokens: tokens)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 会话库第二行末端的身份槽。
    ///
    /// 定宽 + 右对齐，让它在所有行上形成一条右轨。
    @ViewBuilder
    private func identityColumn(tokens: ThemeTokens) -> some View {
        if branch != nil || !Self.identityFallbackText(
            for: session,
            fallback: identityFallback
        ).isEmpty {
            identityColumnBody(tokens: tokens)
        }
    }

    private func identityColumnBody(tokens: ThemeTokens) -> some View {
        HStack(spacing: 5) {
            if let branch {
                SessionBranchIcon(size: density == .table ? 11 : 10)
                    .foregroundStyle(tokens.tertiaryText)
                    .accessibilityHidden(true)

                Text(branch)
                    .font(themeStore.uiFont(size: metadataPointSize))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    // 头部截断而不是中间截断。`codex/` `feature/` 这类命名空间前缀在
                    // 一页里恒定、零信息量，中间截断恰好把唯一有区分度的尾段吃掉。
                    // 这一列本来就右对齐，从头部截断也和视觉方向一致。
                    .truncationMode(.head)
            } else {
                Text(Self.identityFallbackText(for: session, fallback: identityFallback))
                    .font(
                        themeStore.uiFont(
                            size: metadataPointSize,
                            weight: identityFallback == .project ? .medium : .regular
                        )
                    )
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(identityFallback == .project ? .head : .tail)
            }
        }
        .frame(width: identityColumnWidth, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identityAccessibilityLabel)
    }

    private var identityColumnWidth: CGFloat {
        // 辅助功能字号下放开定宽，让文字自己换行而不是把两个字塞进固定列里。
        dynamicTypeSize.isAccessibilitySize
            ? density.identityColumnWidth * 1.4
            : density.identityColumnWidth
    }

    private var identityAccessibilityLabel: String {
        if let branch {
            return "\(L10n.text("ui.branch")) \(branch)"
        }
        return Self.identityFallbackAccessibilityLabel(for: session, fallback: identityFallback)
    }

    @ViewBuilder
    private func leadingGutter() -> some View {
        switch leadingSlot {
        case .state:
            SessionRowStateGlyph(
                state: rowState,
                size: density.stateGlyphSize,
                drawsIdlePlaceholder: showsIdleStateGlyph
            )
            .frame(width: density.stateGutterWidth, alignment: .center)
        case .runtimeIcon:
            RuntimeBrandMarkIcon(
                mark: SessionRuntimePresentation(session: session).brandMark,
                size: 11
            )
            .frame(width: density.stateGutterWidth, height: density.stateGutterWidth)
        case .none:
            // 不占位：HStack 不会为空视图留间距，标题从行内边距处开始。
            EmptyView()
        }
    }

    private func unreadTitleIndicator(tokens: ThemeTokens) -> some View {
        Circle()
            .fill(tokens.sessionUnreadAccent)
            .frame(width: 6, height: 6)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stableStateIcons(tokens: ThemeTokens) -> some View {
        if isArchived {
            Image(systemName: "archivebox.fill")
                .font(themeStore.uiFont(size: statusIconPointSize, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel(L10n.text("ui.archived"))
        }
        if reminder != nil {
            Image(systemName: "bell.fill")
                .font(themeStore.uiFont(size: statusIconPointSize, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .accessibilityLabel(L10n.text("ui.reminder"))
        }
        if isObserving {
            Image(systemName: "eye")
                .font(themeStore.uiFont(size: statusIconPointSize, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel(L10n.text("ui.just_observe"))
        }
    }

    private func supplementaryPreviewText(
        _ text: String,
        tokens: ThemeTokens,
        hasSearchSnippet: Bool
    ) -> some View {
        Text(text)
            .font(themeStore.uiFont(size: metadataPointSize))
            .foregroundStyle(tokens.secondaryText)
            .lineLimit(
                Self.compactSupplementaryPreviewLineLimit(
                    hasSearchSnippet: hasSearchSnippet,
                    dynamicTypeSize: dynamicTypeSize
                )
            )
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
    }

    @ViewBuilder
    private func animatedStatusLabel(tokens: ThemeTokens) -> some View {
        ZStack(alignment: .trailing) {
            if shouldShowStatusLabel {
                statusLabel(tokens: tokens)
                    .id(status)
                    .transition(.opacity)
            }
        }
        .animation(
            MimiMotion.stateTransition.animation(reduceMotion: reduceMotion),
            value: status
        )
    }

    /// 状态只出文案，不再自带图标或 spinner——前导槽已经画了同一件事的字形，
    /// 在同一行里重复一遍既占横向空间又是两份需要同步的真相。
    private func statusLabel(tokens: ThemeTokens) -> some View {
        Text(status.title)
            .font(themeStore.uiFont(size: metadataPointSize, weight: .semibold))
            .foregroundStyle(statusColor(tokens: tokens))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(status.title)
    }

    @ViewBuilder
    private func timestamp(tokens: ThemeTokens) -> some View {
        if !timestampText.isEmpty {
            Text(timestampText)
                .font(themeStore.uiFont(size: metadataPointSize))
                .foregroundStyle(tokens.tertiaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var visibleTitle: String {
        SessionListPresentation.titleDisplayText(for: session)
    }

    /// 会话 tab 与工作区共用的单行布局（有无来源标记都算）。
    private var isSessionLibrary: Bool {
        leadingSlot != .state
    }

    private var rowMinimumHeight: CGFloat {
        if isSessionLibrary && !showsSessionPreview { return Self.libraryRowMinimumHeight }
        return density.minimumHeight
    }

    private var status: AgentSessionDisplayStatus {
        session.displayStatus(foregroundActivity: foregroundActivity)
    }

    private var rowState: SessionRowState? {
        SessionRowState.resolve(status: status, isUnread: isUnread)
    }

    /// `.complete` 不再出文案。
    ///
    /// 历史列表里绝大多数行都是完成态，逐行写一遍"完成"等于把默认值念 15 遍——
    /// 恒定即无信息。需要人处理的等待与失败、以及仍在跑的活动态才值得占位置。
    private var shouldShowStatusLabel: Bool {
        Self.showsStatusLabel(
            status: status,
            sessionStatus: session.status,
            showsNeutralHistoryStatus: showsNeutralHistoryStatus
        )
    }

    private func statusColor(tokens: ThemeTokens) -> Color {
        switch status.tone {
        case .active: return tokens.secondaryText
        case .warning: return tokens.warning
        case .danger: return .red
        case .complete, .neutral: return tokens.tertiaryText
        }
    }

    private var timestampText: String {
        SessionListPresentation.timestampText(
            for: session.recencyAt ?? session.updatedAt ?? session.createdAt,
            now: currentDate(),
            calendar: resolvedCalendar,
            locale: resolvedLocale,
            timeZone: resolvedTimeZone
        )
    }

    private var resolvedCalendar: Calendar {
        var value = calendar ?? environmentCalendar
        if let timeZone {
            value.timeZone = timeZone
        } else if calendar == nil {
            value.timeZone = environmentTimeZone
        }
        return value
    }

    private var resolvedLocale: Locale {
        locale ?? environmentLocale
    }

    private var resolvedTimeZone: TimeZone {
        timeZone ?? resolvedCalendar.timeZone
    }
}

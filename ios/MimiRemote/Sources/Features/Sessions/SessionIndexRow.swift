import SwiftUI

/// 会话行的几何档位。
///
/// 只保留 `compact` 与 `table` 两档：`rail` 曾经为侧栏准备，但 `resolved` 从不返回它、
/// 也没有任何调用点显式传入，留着只会让人以为侧栏复用了这个组件（侧栏有自己的
/// `ProjectSidebarView.SessionRow`）。
///
/// 两档共用同一套骨架，差别只在字号、留白和身份列宽度。会话 tab 与工作区因此不会
/// 因为所处页面不同而拿到不同的读法。
enum SessionIndexRowDensity: Equatable {
    case compact
    case table

    /// 行高。两行内容加上下留白后仍要留出呼吸量——过去 60/44 的行高把两行文字压在
    /// 一起，配合逐行分隔线读成一张表格；列表需要的是可扫读的条目，不是表格。
    ///
    /// 两档同高：装的是同样字号的两行文字，没有理由因为屏幕窄就压扁。
    var minimumHeight: CGFloat { 76 }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 12
        case .table: 14
        }
    }

    /// 标题与元数据行之间的间距。比行与行之间的留白小得多，两行才会读成一个整体。
    var contentSpacing: CGFloat { 4 }

    /// 字号在两档之间**不变**。
    ///
    /// 密度档位回答的是"这么宽能不能排下一条固定的身份列"，那是几何问题；
    /// 正文该多大是可读性问题，与屏幕宽窄无关——iPhone 上的邮件和 iPad 上用的是
    /// 同一套正文字号。两者绑在一起时，为了让手机上的分支列收窄，整页字都会跟着缩一号。
    var titleFontSize: CGFloat { 16 }

    var metadataFontSize: CGFloat { 12 }

    /// 摘要比标题低一档、比元数据高一档，同样不随密度变化。
    var previewFontSize: CGFloat { 13.5 }

    var statusIconSize: CGFloat { 9 }

    /// 前导槽。宽度恒定预留，标题因此在所有行上落在同一条竖线上。
    ///
    /// 两个 tab 放不同的东西（会话 tab 放项目图标、工作区放状态字形），但槽宽必须相同，
    /// 否则同一条会话在两页里的标题起点会差几个点。
    var stateGutterWidth: CGFloat { 20 }

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

    var brandAssetName: String {
        switch kind {
        case .codex:
            return "ChatGPT"
        case .claude:
            return "Claude"
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
/// 两个 tab 的区分符不同，前导槽应当承载各自那一个：
///
/// - 会话 tab 是所有项目的汇集区，"这条属于哪个项目"是第一位的问题，槽里放项目图标；
///   未读退化成图标右上角的角标，与顶部项目胶囊上的徽标同一种语言。
/// - 工作区内项目恒定，那个问题不存在，槽里放会话状态字形。
enum SessionIndexRowLeadingSlot: Equatable {
    case state
    case projectIcon
}

/// 身份槽没有可展示分支时使用什么信息。
///
/// 会话 tab 跨项目，项目名是必要身份；工作区已经固定项目，目录末段更能区分不同 worktree。
enum SessionIndexRowIdentityFallback: Equatable {
    case project
    case directory
}

/// 前导状态字形。
///
/// 四种状态用**形状**区分而不只是颜色：实心圆带感叹号 / 三角 / 空心环 / 实心点。
/// 色觉障碍下这一列仍然可读，这是把状态收进单一色点的方案做不到的。
struct SessionRowStateGlyph: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

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
                Circle()
                    .strokeBorder(tokens.success, lineWidth: 2)
                    .frame(width: size, height: size)
            case .unread:
                Circle()
                    .fill(tokens.primaryAction)
                    .frame(width: size - 2, height: size - 2)
            case nil:
                if drawsIdlePlaceholder {
                    // 虚线环。和"运行中"那枚实心绿环的区别落在**形状**上，而不是靠颜色深浅——
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
            Image(presentation.brandAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)

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

/// 会话在列表中的统一表示。
///
/// 会话 tab 与工作区使用**同一种排布**，不再各自一套：
///
/// ```
/// [状态槽] 标题 ……………………………………………… 时间
///          摘要 ……………… 状态文案   身份（分支 / 项目）
/// ```
///
/// 两页真正的差异只有第二行末端身份槽的取值——工作区里项目恒定、区分符是分支；
/// 会话 tab 默认跨项目、区分符是项目。差异收敛成一个槽，其余几何完全一致。
///
/// 曾经存在 `contentLayout` 开关，让两页在 `.table` 下走两套完全不同的排布
/// （摘要在第一行还是第二行、时间在第一行还是第二行都不一样）。它把"同一个对象
/// 两种读法"固化进了组件内部，与共用组件的初衷相反，已移除。
struct SessionIndexRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var environmentLocale
    @Environment(\.timeZone) private var environmentTimeZone

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
    var projectIcon: WorkspaceProjectIconContent? = nil
    /// 工作区在多分支时注入当前行的 Git 分支；为 nil 时身份槽按调用方指定的规则回退。
    var branch: String? = nil
    /// 会话 tab 默认回退项目名；工作区传 `.directory`，在没有区分价值的分支时展示目录末段。
    var identityFallback: SessionIndexRowIdentityFallback = .project
    /// 前导槽承载什么。会话 tab 传 `.projectIcon`，工作区保持 `.state`。
    var leadingSlot: SessionIndexRowLeadingSlot = .state
    /// `.state` 槽在无状态时是否画灰环兜底。工作区传 true，让这一列每行都有内容，
    /// 小节标题才能拿它当基准线。
    var showsIdleStateGlyph = false
    /// 仅在一段连续同项目会话的首行展示项目图标，后续行保留同宽空槽维持对齐。
    ///
    /// 折叠不丢信息：第二行末端的项目名每一行都在，图标只承担段首的视觉锚点。
    /// 逐行重复同一枚图标反而会让连续同项目的一段看起来很吵。
    var showsProjectAnchor = false
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
        showsNeutralHistoryStatus: Bool
    ) -> String {
        var values: [String] = []
        if !showsStatusLabel(
            status: status,
            sessionStatus: sessionStatus,
            showsNeutralHistoryStatus: showsNeutralHistoryStatus
        ) {
            values.append(status.title)
        }
        if isUnread {
            values.append(L10n.text("ui.unread_result"))
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

        HStack(alignment: .top, spacing: density.stateGutterSpacing) {
            leadingGutter(tokens: tokens)
                // 与标题首行基线对齐；字形是几何居中的，需要往下压一点点。
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 2)

            VStack(alignment: .leading, spacing: density.contentSpacing) {
                titleLine(tokens: tokens)
                metadataLine(tokens: tokens)

                if let searchSnippet, !searchSnippet.isEmpty {
                    supplementaryPreviewText(searchSnippet, tokens: tokens, hasSearchSnippet: true)
                }
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: density.minimumHeight, alignment: .leading)
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
            if isPinned {
                SessionPinnedBadge(compact: true)
            }

            Text(visibleTitle)
                .font(themeStore.uiFont(size: density.titleFontSize, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

            // 12pt 而不是 6pt：长标题过去会一路顶到时间上，两段文字之间没有间隙。
            Spacer(minLength: 12)

            timestamp(tokens: tokens)
        }
    }

    private func metadataLine(tokens: ThemeTokens) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let preview = SessionListPresentation.distinctPreviewDisplayText(for: session)
            if !preview.isEmpty {
                Text(preview)
                    .font(themeStore.uiFont(size: density.previewFontSize, weight: .regular))
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

    /// 第二行末端的身份槽：工作区给分支或目录，会话 tab 给项目。
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
                    .font(themeStore.uiFont(size: density.metadataFontSize, weight: .regular))
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
                            size: density.metadataFontSize,
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
    private func leadingGutter(tokens: ThemeTokens) -> some View {
        switch leadingSlot {
        case .state:
            SessionRowStateGlyph(
                state: rowState,
                size: density.stateGlyphSize,
                drawsIdlePlaceholder: showsIdleStateGlyph
            )
            .frame(width: density.stateGutterWidth, alignment: .center)
        case .projectIcon:
            projectIconGutter(tokens: tokens)
        }
    }

    @ViewBuilder
    private func projectIconGutter(tokens: ThemeTokens) -> some View {
        let drawsIcon = showsProjectAnchor && projectIcon != nil

        Group {
            if drawsIcon, let projectIcon {
                WorkspaceProjectIconTile(
                    content: projectIcon,
                    size: density.stateGutterWidth,
                    tokens: tokens
                )
            } else if isUnread {
                // 段中行没有图标可挂角标，未读退回槽位居中的独立圆点。
                // 位置仍然在同一条竖线上，扫读时和角标读成同一列。
                Circle()
                    .fill(tokens.primaryAction)
                    .frame(width: 7, height: 7)
            } else {
                Color.clear
            }
        }
        .frame(width: density.stateGutterWidth, height: density.stateGutterWidth)
        // 段首行的未读挂在图标右上角。项目图标占住了这一列，未读不能再要一个位置；
        // 叠在角上既保住信号，又不让它重新变成一个跟着时间漂移的独立元素。
        .overlay(alignment: .topTrailing) {
            if drawsIcon, isUnread {
                Circle()
                    .fill(tokens.primaryAction)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(tokens.background, lineWidth: 1.5)
                    }
                    .offset(x: 3, y: -3)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stableStateIcons(tokens: ThemeTokens) -> some View {
        if isArchived {
            Image(systemName: "archivebox.fill")
                .font(themeStore.uiFont(size: density.statusIconSize, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText)
                .accessibilityLabel(L10n.text("ui.archived"))
        }
        if reminder != nil {
            Image(systemName: "bell.fill")
                .font(themeStore.uiFont(size: density.statusIconSize, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .accessibilityLabel(L10n.text("ui.reminder"))
        }
        if isObserving {
            Image(systemName: "eye")
                .font(themeStore.uiFont(size: density.statusIconSize, weight: .semibold))
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
            .font(themeStore.uiFont(size: 11, weight: .regular))
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
            .font(themeStore.uiFont(size: density.metadataFontSize, weight: .semibold))
            .foregroundStyle(statusColor(tokens: tokens))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(status.title)
    }

    @ViewBuilder
    private func timestamp(tokens: ThemeTokens) -> some View {
        if !timestampText.isEmpty {
            Text(timestampText)
                .font(themeStore.uiFont(size: density.metadataFontSize, weight: .regular))
                .foregroundStyle(tokens.tertiaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var visibleTitle: String {
        SessionListPresentation.titleDisplayText(for: session)
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

import SwiftUI

/// 侧栏分成两层，读法不同（#547，方案 A）：
/// - 值班表（待你处理 / 正在运行 / 刚完成）回答「现在有什么在等我」。它与详情正交：看着 A 项目
///   也要看见 B 项目的审批，所以分组标题用正文墨色，排在最前。
/// - 跳转器（置顶 / 最近）回答「刚才那条在哪」。它是回到已完成会话的主路径，条数不减；
///   但分组标题降到三级灰、条目标题降一档，并用一条细线和值班表隔开。
/// 值班表全空时显示「一切安静」，不拿历史会话填位：空本身就是信息。
extension SessionSidebarSectionKind {
    var isDutyBoard: Bool {
        switch self {
        case .needYou, .running, .justCompleted:
            return true
        case .pinned, .recent:
            return false
        }
    }
}

enum WorkbenchSidebarDutyBoardLayout {
    /// 值班表全空、跳转器已有会话时才说「一切安静」。跳转器也空时多半是首屏还在加载，
    /// 或新配对还没有会话，这时说「一切安静」会误导。
    static func showsQuietState(sectionKinds: [SessionSidebarSectionKind]) -> Bool {
        !sectionKinds.contains(where: \.isDutyBoard) && sectionKinds.contains { !$0.isDutyBoard }
    }

    /// 细线画在跳转器第一组的标题上方；它上面总有值班表的分组或「一切安静」。
    static func dividerKind(sectionKinds: [SessionSidebarSectionKind]) -> SessionSidebarSectionKind? {
        sectionKinds.first { !$0.isDutyBoard }
    }
}

/// 侧栏分组标题。字号字重与 `pageSectionHeaderStyle()` 同一套（#563），只按层级换墨色。
struct WorkbenchSidebarSectionHeader: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .footnote) private var pointSize: CGFloat = 13

    let title: String
    let count: Int
    let kind: SessionSidebarSectionKind
    let showsDivider: Bool

    @Environment(\.workbenchSidebarListGlobalFrame) private var listFrame
    @State private var headerFrame: CGRect?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            if showsDivider {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: 1 / max(displayScale, 1))
                    .padding(
                        .trailing,
                        -Self.dividerTrailingExtension(headerFrame: headerFrame, listFrame: listFrame)
                    )
                    .accessibilityHidden(true)
            }
            Text("\(title) \(count)")
                .font(themeStore.uiFont(size: pointSize, weight: .medium))
                .foregroundStyle(kind.isDutyBoard ? tokens.primaryText : tokens.tertiaryText)
                .textCase(nil)
        }
        .padding(.top, showsDivider ? 6 : 0)
        .onGeometryChange(for: CGRect?.self) { proxy in
            showsDivider ? proxy.frame(in: .global) : nil
        } action: { frame in
            headerFrame = frame
        }
    }

    /// SidebarListStyle 的分组标题右侧比左侧多留一截（实测约 8pt，疑为可折叠分组的尾部预留），
    /// 对标题设 `listRowInsets` 不生效，标题里也拿不到 `.scrollView` 坐标。这里用列表与标题的
    /// 全局边框量出左右实际距离，只把细线右端补齐到与左侧对称；不写死系统预留值，文字位置不变（#993）。
    static func dividerTrailingExtension(headerFrame: CGRect?, listFrame: CGRect?) -> CGFloat {
        guard let headerFrame, let listFrame else { return 0 }
        let leadingGap = headerFrame.minX - listFrame.minX
        let trailingGap = listFrame.maxX - headerFrame.maxX
        return max(0, (trailingGap - leadingGap).rounded())
    }
}

private struct WorkbenchSidebarListGlobalFrameKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    /// 侧栏 List 的全局边框，供分组标题对齐细线；标题位于 List 单元内，量不到滚动视图坐标。
    var workbenchSidebarListGlobalFrame: CGRect? {
        get { self[WorkbenchSidebarListGlobalFrameKey.self] }
        set { self[WorkbenchSidebarListGlobalFrameKey.self] = newValue }
    }
}

private struct WorkbenchSidebarListGlobalFrameReader: ViewModifier {
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .environment(\.workbenchSidebarListGlobalFrame, frame)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newFrame in
                frame = newFrame
            }
    }
}

extension View {
    /// 挂在侧栏 List 上，让分组标题的细线能按列表实际左右边缘对称（#993）。
    func workbenchSidebarListGlobalFrameReader() -> some View {
        modifier(WorkbenchSidebarListGlobalFrameReader())
    }
}

/// 值班表全空时的静默态，占一行。月亮落在状态标记那一列，文字与会话标题对齐。
struct WorkbenchSidebarQuietRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var titlePointSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var iconPointSize: CGFloat = 12

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 8) {
            Image(systemName: "moon")
                .font(themeStore.uiFont(size: iconPointSize, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
                .frame(width: 12, height: 12)
            Color.clear
                .frame(width: 20, height: 20)
            Text(L10n.text("ui.sidebar_all_quiet"))
                .font(themeStore.uiFont(size: titlePointSize))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.sidebar_all_quiet_accessibility"))
        .accessibilityIdentifier("sidebar.allQuiet")
        .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

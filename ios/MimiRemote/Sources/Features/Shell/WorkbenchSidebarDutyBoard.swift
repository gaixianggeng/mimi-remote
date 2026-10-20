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

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            if showsDivider {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: 1 / max(displayScale, 1))
                    .accessibilityHidden(true)
            }
            Text("\(title) \(count)")
                .font(themeStore.uiFont(size: pointSize, weight: .medium))
                .foregroundStyle(kind.isDutyBoard ? tokens.primaryText : tokens.tertiaryText)
                .textCase(nil)
        }
        .padding(.top, showsDivider ? 6 : 0)
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

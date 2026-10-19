import SwiftUI

/// 父会话的展开状态。所有列表共用同一份：在侧栏收起，会话页也收起。
/// 默认全部展开，与 Claude 桌面版一致；只在内存里保存，不跨启动。
@MainActor
final class SessionHierarchyExpansionStore: ObservableObject {
    @Published private(set) var collapsedRootIDs: Set<SessionID> = []

    func toggle(_ rootID: SessionID) {
        if collapsedRootIDs.contains(rootID) {
            collapsedRootIDs.remove(rootID)
        } else {
            collapsedRootIDs.insert(rootID)
        }
    }
}

/// 把一段会话按派生关系展开成列表行。层级在这里一次算好，每一行只拿到自己的角色，
/// 不再各自订阅整个 SessionStore 或在 body 里遍历全部会话。
/// 子会话是独立的列表行，复用调用方原有的行组件、点击、横滑和长按菜单。
struct SessionHierarchyForEach<Row: View>: View {
    @ObservedObject var expansion: SessionHierarchyExpansionStore
    let families: [SessionFamily]
    @ViewBuilder let row: (SessionHierarchyRow, _ previous: AgentSession?) -> Row

    init(
        families: [SessionFamily],
        expansion: SessionHierarchyExpansionStore,
        @ViewBuilder row: @escaping (SessionHierarchyRow, _ previous: AgentSession?) -> Row
    ) {
        self.families = families
        self.expansion = expansion
        self.row = row
    }

    init(
        sessions: [AgentSession],
        expansion: SessionHierarchyExpansionStore,
        @ViewBuilder row: @escaping (SessionHierarchyRow, _ previous: AgentSession?) -> Row
    ) {
        self.init(families: SessionHierarchy.families(sessions), expansion: expansion, row: row)
    }

    var body: some View {
        let rows = SessionHierarchy.rows(families, collapsedRootIDs: expansion.collapsedRootIDs)
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
            row(entry, index > 0 ? rows[index - 1].session : nil)
        }
    }
}

extension View {
    /// 给会话行加上层级装饰：有子会话的父行在尾部加展开按钮，子行缩进并画连接线。
    /// 必须放在 `listRowInsets`、`swipeActions` 等列表行修饰之前，否则它们会被包进容器里失效。
    /// - Parameters:
    ///   - guideX: 连接线竖线相对行左缘的位置，通常对齐父行的图标中心或标题起点。
    ///   - contentInset: 行组件自带的左内边距；横线停在子行内容前面，不压住图标或文字。
    func sessionHierarchyRow(
        _ row: SessionHierarchyRow,
        expansion: SessionHierarchyExpansionStore,
        guideX: CGFloat,
        contentInset: CGFloat
    ) -> some View {
        modifier(SessionHierarchyRowDecoration(
            row: row,
            expansion: expansion,
            guideX: guideX,
            contentInset: contentInset
        ))
    }
}

enum SessionHierarchyMetrics {
    /// 子行整体右移的距离；连接线画在这段空白里。
    static let childIndent: CGFloat = 22
}

private struct SessionHierarchyRowDecoration: ViewModifier {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 12
    let row: SessionHierarchyRow
    let expansion: SessionHierarchyExpansionStore
    let guideX: CGFloat
    let contentInset: CGFloat

    func body(content: Content) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        switch row.role {
        case .root(let childCount, let isExpanded) where childCount > 0:
            // 父行与展开按钮是相邻的独立控件，点箭头不会同时打开父会话。
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, alignment: .leading)
                toggleButton(childCount: childCount, isExpanded: isExpanded, tokens: tokens)
            }
        case .root:
            content
        case .child(let parent, let isLast):
            content
                .padding(.leading, SessionHierarchyMetrics.childIndent)
                // 连接线只跟随行高，不参与布局，避免 Shape 吞掉剩余高度撑大子行。
                .overlay(alignment: .leading) {
                    let lineEnd = SessionHierarchyMetrics.childIndent + contentInset - 4
                    SessionHierarchyConnector(guideX: min(guideX, lineEnd - 6), isLast: isLast)
                        .stroke(tokens.border, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: lineEnd)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .accessibilityHint(Text(L10n.format(
                    "ui.child_session_of",
                    SessionListPresentation.titleDisplayText(for: parent)
                )))
        }
    }

    private func toggleButton(childCount: Int, isExpanded: Bool, tokens: ThemeTokens) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                expansion.toggle(row.session.id)
            }
        } label: {
            HStack(spacing: 4) {
                Text(childCount, format: .number)
                    .monospacedDigit()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
            }
            .font(themeStore.uiFont(size: detailSize))
            .foregroundStyle(tokens.secondaryText)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded
            ? L10n.format("ui.collapse_child_sessions_count", childCount)
            : L10n.format("ui.expand_child_sessions_count", childCount))
        .accessibilityValue(L10n.text(isExpanded ? "ui.expanded_state" : "ui.collapse_state"))
        .accessibilityIdentifier("sessionHierarchy.toggle.\(row.session.id)")
    }
}

private struct SessionHierarchyConnector: Shape {
    let guideX: CGFloat
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            let x = guideX
            path.move(to: CGPoint(x: x, y: 0))
            if isLast {
                let radius = min(6, rect.midY)
                path.addLine(to: CGPoint(x: x, y: rect.midY - radius))
                path.addQuadCurve(
                    to: CGPoint(x: x + radius, y: rect.midY),
                    control: CGPoint(x: x, y: rect.midY)
                )
            } else {
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: x, y: rect.midY))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

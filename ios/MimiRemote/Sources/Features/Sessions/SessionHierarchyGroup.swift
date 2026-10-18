import SwiftUI

/// 父行与展开按钮是相邻的独立控件，避免点击箭头同时打开父会话。
struct SessionHierarchyGroup<ParentRow: View>: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 12
    @Binding var isExpanded: Bool
    let parent: AgentSession
    let children: [SessionHierarchyChild]
    let unreadIDs: Set<SessionID>
    var leadingInset: CGFloat = 12
    let onOpenChild: (SessionContextSubagent) -> Void
    @ViewBuilder let parentRow: () -> ParentRow

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                parentRow()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !children.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(children.count, format: .number)
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
                        ? L10n.format("ui.collapse_child_sessions_count", children.count)
                        : L10n.format("ui.expand_child_sessions_count", children.count))
                    .accessibilityValue(L10n.text(isExpanded ? "ui.expanded_state" : "ui.collapse_state"))
                    .accessibilityIdentifier("sessionHierarchy.toggle.\(parent.id)")
                }
            }

            if isExpanded {
                ForEach(children) { child in
                    childButton(child, tokens: tokens)
                        .padding(.leading, leadingInset + 26)
                        // 连接线只跟随正文高度；Shape 参与 HStack 布局会吞掉剩余高度，撑大子行。
                        .overlay(alignment: .leading) {
                            SessionHierarchyConnector(isLast: child.id == children.last?.id)
                                .stroke(tokens.border, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: 18)
                                .padding(.leading, leadingInset)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                }
            }
        }
    }

    private func childButton(_ child: SessionHierarchyChild, tokens: ThemeTokens) -> some View {
        let status = child.session.displayStatus(foregroundActivity: nil)
        let isUnread = unreadIDs.contains(child.session.id) || unreadIDs.contains(child.id)
        return Button {
            onOpenChild(child.relation)
        } label: {
            HStack(spacing: 8) {
                Text(child.session.title)
                    .font(themeStore.uiFont(size: titleSize))
                    .foregroundStyle(tokens.listTitleText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isUnread { SessionUnreadIndicator() }
                if status.showsSpinner {
                    ProgressView().controlSize(.mini).tint(tokens.tint(for: status.tone))
                } else {
                    Image(systemName: status.systemImage)
                        .font(themeStore.uiFont(size: detailSize))
                        .foregroundStyle(tokens.tint(for: status.tone))
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionIndexRowButtonStyle(pressedFill: tokens.selectionFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(child.session.title)
        .accessibilityValue([
            L10n.format("ui.child_session_of", SessionListPresentation.titleDisplayText(for: parent)),
            status.title,
            isUnread ? L10n.text("ui.unread_result") : nil,
            child.relation.canAcceptDirectInput == true ? nil : L10n.text("ui.read_only")
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("sessionHierarchy.child.\(child.id)")
    }
}

private struct SessionHierarchyConnector: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            let x: CGFloat = 4
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

private struct SessionHierarchyModifier: ViewModifier {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var contextStore: SessionContextStore
    let parent: AgentSession
    let leadingInset: CGFloat
    let showsSwipeActions: Bool
    @State private var isExpanded = true
    @State private var selectedChild: SessionContextSubagent?

    func body(content: Content) -> some View {
        let children = SessionHierarchyPresentation.children(
            of: parent,
            sessions: sessionStore.sessions,
            context: contextStore.context(for: parent.id)
        )
        Group {
            if children.isEmpty {
                if showsSwipeActions {
                    content.sessionRowSwipeActions(parent)
                } else {
                    content
                }
            } else {
                // List 的 swipeActions 作用于整格。父子共用一格时只保留父行菜单，
                // 防止横滑子行却触发父会话的归档或已读操作。
                SessionHierarchyGroup(
                    isExpanded: $isExpanded,
                    parent: parent,
                    children: children,
                    unreadIDs: sessionStore.unreadHistorySessionIDs,
                    leadingInset: leadingInset,
                    onOpenChild: { selectedChild = $0 },
                    parentRow: { content }
                )
            }
        }
        // 复用既有子会话读取与观察链路；列表切换与父会话的选中状态不受影响。
        .sheet(item: $selectedChild) { relation in
            SessionHierarchyDetailSheet(relation: relation, parentSessionID: parent.id)
        }
        .onChange(of: sessionStore.appStore.activeHostScope) { _, _ in
            // 不同电脑可能使用相同会话 ID，不能把旧电脑的详情选择带过去。
            selectedChild = nil
            isExpanded = true
        }
    }
}

private struct SessionHierarchyDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let relation: SessionContextSubagent
    let parentSessionID: SessionID

    var body: some View {
        NavigationStack {
            RelatedSessionConversationView(
                relation: relation,
                parentSessionID: parentSessionID,
                showsCloseButton: true,
                onClose: { dismiss() }
            )
        }
    }
}

extension View {
    func sessionHierarchy(
        _ session: AgentSession,
        store: SessionStore,
        leadingInset: CGFloat = 12,
        showsSwipeActions: Bool = false
    ) -> some View {
        modifier(SessionHierarchyModifier(
            sessionStore: store,
            contextStore: store.contextStore,
            parent: session,
            leadingInset: leadingInset,
            showsSwipeActions: showsSwipeActions
        ))
    }
}

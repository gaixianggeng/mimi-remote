import SwiftUI

/// ⌘O / ⌘F 会话跳转面板的数据：空查询时沿用侧栏的分组与读法（#547 跨项目跳转器的键盘入口）；
/// 输入后在已加载的全部会话里按标题、项目名和目录名匹配，不发新的网络请求。
enum SessionJumpPanelModel {
    struct Group: Equatable, Identifiable {
        let id: String
        let title: String?
        let sessions: [AgentSession]
    }

    static let searchResultLimit = 50

    static func groups(
        sections: [SessionSidebarSection],
        allSessions: [AgentSession],
        query: String
    ) -> [Group] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return sections
                .filter { !$0.sessions.isEmpty }
                .map { Group(id: $0.kind.rawValue, title: $0.kind.localizedTitle, sessions: $0.sessions) }
        }
        var seen = Set<SessionID>()
        let matches = allSessions.filter { session in
            guard seen.insert(session.id).inserted else {
                return false
            }
            return matches(session, query: trimmed)
        }
        guard !matches.isEmpty else {
            return []
        }
        return [Group(id: "search", title: nil, sessions: Array(matches.prefix(searchResultLimit)))]
    }

    static func matches(_ session: AgentSession, query: String) -> Bool {
        let directoryName = (session.dir as NSString).lastPathComponent
        return [session.title, session.project, directoryName].contains {
            $0.localizedStandardContains(query)
        }
    }

    /// 键盘上下移动用的扁平顺序，与列表从上到下的显示顺序一致。
    static func flattened(_ groups: [Group]) -> [AgentSession] {
        groups.flatMap(\.sessions)
    }
}

struct SessionJumpPanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let sections: [SessionSidebarSection]
    let allSessions: [AgentSession]
    let onOpen: (AgentSession) -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let groups = SessionJumpPanelModel.groups(sections: sections, allSessions: allSessions, query: query)
        let ordered = SessionJumpPanelModel.flattened(groups)

        NavigationStack {
            VStack(spacing: 0) {
                searchField(tokens: tokens, ordered: ordered)
                if ordered.isEmpty {
                    ContentUnavailableView(L10n.text("ui.no_matching_session"), systemImage: "magnifyingglass")
                        .frame(maxHeight: .infinity)
                } else {
                    resultList(groups: groups, ordered: ordered, tokens: tokens)
                }
            }
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.go_to_session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private func searchField(tokens: ThemeTokens, ordered: [AgentSession]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(tokens.secondaryText)
                .accessibilityHidden(true)
            TextField(L10n.text("ui.search_all_sessions_placeholder"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .submitLabel(.go)
                .onSubmit { openHighlighted(in: ordered) }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1, count: ordered.count)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1, count: ordered.count)
                    return .handled
                }
                .accessibilityIdentifier("sessionJump.search")
        }
        .font(themeStore.uiFont(.body))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func resultList(groups: [SessionJumpPanelModel.Group], ordered: [AgentSession], tokens: ThemeTokens) -> some View {
        let highlightedID = ordered.indices.contains(highlightedIndex) ? ordered[highlightedIndex].id : nil
        return ScrollViewReader { proxy in
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            row(session, isHighlighted: session.id == highlightedID, tokens: tokens)
                                .id(session.id)
                        }
                    } header: {
                        if let title = group.title {
                            Text(title)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: highlightedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ session: AgentSession, isHighlighted: Bool, tokens: ThemeTokens) -> some View {
        Button {
            open(session)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text("\(session.project) · \(session.displayStatusText)")
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isHighlighted ? tokens.accent.opacity(0.14) : Color.clear)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private func moveHighlight(by delta: Int, count: Int) {
        guard count > 0 else { return }
        highlightedIndex = min(max(highlightedIndex + delta, 0), count - 1)
    }

    private func openHighlighted(in ordered: [AgentSession]) {
        guard ordered.indices.contains(highlightedIndex) else { return }
        open(ordered[highlightedIndex])
    }

    private func open(_ session: AgentSession) {
        dismiss()
        onOpen(session)
    }
}

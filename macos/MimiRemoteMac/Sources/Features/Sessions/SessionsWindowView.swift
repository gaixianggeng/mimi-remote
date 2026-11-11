import AppKit
import SwiftUI

/// 电脑端会话窗口（#991）：找到手机上用过的会话，后续在这里一键交给桌面版。
/// 列表与手机端一致，只展示和查找，不显示聊天内容。
struct SessionsWindowView: View {
    let host: HostStore
    @State private var store: SessionsStore

    /// store 只在测试与预览里注入；默认读本机服务。
    @MainActor
    init(host: HostStore, store: SessionsStore? = nil) {
        self.host = host
        _store = State(initialValue: store ?? SessionsStore())
    }

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 420)
            .navigationTitle("会话")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("助手", selection: $store.filter) {
                        ForEach(SessionsStore.RuntimeFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("sessions.filter")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isRefreshing)
                    .help("刷新会话列表（⌘R）")
                }
            }
            .searchable(text: $store.query, placement: .toolbar, prompt: "搜索会话或项目")
            .task(id: loadKey) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView("正在读取会话…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("读不到会话", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await reload() } }
            }
        case .loaded:
            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("在手机或电脑上开始一段 Codex 或 Claude 对话后，会出现在这里。")
                )
            } else if store.isEmptyAfterFiltering {
                ContentUnavailableView.search(text: store.query)
            } else {
                sessionList
            }
        }
    }

    private var sessionList: some View {
        List {
            if !store.notices.isEmpty {
                Section {
                    ForEach(store.notices, id: \.self) { notice in
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(store.visibleSections) { section in
                Section(section.title) {
                    ForEach(section.sessions) { session in
                        SessionRow(session: session)
                            .contextMenu { contextMenu(for: session) }
                    }
                }
            }
            if store.hasMore {
                Button {
                    Task { await store.loadMore(endpoint: host.status?.endpoint, runtimes: enabledRuntimes) }
                } label: {
                    Text(store.isRefreshing ? "正在读取…" : "加载更早的会话")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .padding(.vertical, 6)
                .accessibilityIdentifier("sessions.loadMore")
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("sessions.list")
    }

    @ViewBuilder
    private func contextMenu(for session: DesktopSession) -> some View {
        Button("复制会话 ID") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(session.threadID, forType: .string)
        }
        if !session.cwd.isEmpty {
            Button("在访达中显示项目") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
            }
        }
    }

    private var enabledRuntimes: [SessionRuntime] {
        SessionRuntime.allCases.filter { runtime in
            switch runtime {
            case .codex: host.moduleEnabled(.codex)
            case .claude: host.moduleEnabled(.claude)
            }
        }
    }

    /// 服务地址或已启用的助手变化时重新加载。
    private var loadKey: String {
        let endpoint = host.status?.processOK == true ? (host.status?.endpoint ?? "") : ""
        return endpoint + "|" + enabledRuntimes.map(\.rawValue).joined(separator: ",")
    }

    private func reload() async {
        let endpoint = host.status?.processOK == true ? host.status?.endpoint : nil
        await store.reload(endpoint: endpoint, runtimes: enabledRuntimes)
    }
}

private struct SessionRow: View {
    let session: DesktopSession

    var body: some View {
        HStack(spacing: 10) {
            RuntimeBrandMarkIcon(mark: session.runtime.brandMark, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            ForEach(SessionRowBadge.badges(for: session), id: \.self) { badge in
                Text(badge.title)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(badge.isWarning ? Color.orange : Color.secondary)
                    .background(
                        (badge.isWarning ? Color.orange : Color.secondary).opacity(0.12),
                        in: Capsule()
                    )
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.row.\(session.id)")
    }

    private var subtitle: String {
        let time = SessionRowBadge.timeText(for: session.updatedAt)
        return [session.projectName, time].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 行尾的状态标记与时间文字，单独拆出便于测试。
enum SessionRowBadge: Hashable {
    case activity(DesktopSession.Activity)
    case holder(DesktopSession.Holder)

    var title: String {
        switch self {
        case .activity(.running): "运行中"
        case .activity(.waitingForApproval): "等待审批"
        case .activity(.waitingForInput): "等待回复"
        case .activity(.failed): "出错"
        case .activity(.idle): ""
        case .holder(.otherCodexProcess), .holder(.otherClaudeProcess): "电脑上已打开"
        case .holder(.claudeDesktop): "Claude 桌面版已打开"
        case .holder(.claudeTerminal): "终端里已打开"
        }
    }

    var isWarning: Bool {
        if case .activity(let activity) = self { return activity != .idle }
        return false
    }

    static func badges(for session: DesktopSession) -> [SessionRowBadge] {
        var badges: [SessionRowBadge] = []
        if session.activity != .idle { badges.append(.activity(session.activity)) }
        if let holder = session.holder { badges.append(.holder(holder)) }
        return badges
    }

    /// 今天用相对时间（12 分钟前），更早的写日期和时间（昨天 21:40），与分组标题对得上。
    static func timeText(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if calendar.isDate(date, inSameDayAs: now), date <= now {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}

import AppKit
import SwiftUI

/// 电脑端会话窗口（#991）：找到手机上用过的会话，后续在这里一键交给桌面版。
/// 列表与手机端一致，只展示和查找，不显示聊天内容。
struct SessionsWindowView: View {
    let host: HostStore
    @State private var store: SessionsStore
    @State private var installedApps: Set<String> = []
    /// Codex 和 Claude 各记各的「打开」去处，因为两边的桌面版不同。
    @AppStorage("sessions.openTarget.codex") private var codexOpenTarget = ""
    @AppStorage("sessions.openTarget.claude") private var claudeOpenTarget = ""
    @AppStorage("sessions.codexSharedHintMuted") private var codexSharedHintMuted = false
    /// 桌面版没在运行时无从判断接没接共用服务，沿用上一次看到的结果。
    @AppStorage("sessions.codexDesktopSharedSeen") private var codexDesktopSharedSeen = false
    @State private var showsSharedSetup = false

    /// store 只在测试与预览里注入；默认读本机服务。
    @MainActor
    init(host: HostStore, store: SessionsStore? = nil) {
        self.host = host
        _store = State(initialValue: store ?? SessionsStore())
    }

    var body: some View {
        // 筛选放在内容顶部常驻显示。放在工具栏时，搜索框获得焦点后会变宽，
        // 把筛选和刷新挤进溢出菜单（#991 实机走查）。
        VStack(spacing: 0) {
            filterBar
            noticeBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(minWidth: 560, minHeight: 420)
            .navigationTitle("会话")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await manualReload() }
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
            .alert(
                "没能完成",
                isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })
            ) {
                Button("好") { store.actionError = nil }
            } message: {
                Text(store.actionError ?? "")
            }
            .sheet(isPresented: $showsSharedSetup) {
                CodexSharedSetupView()
            }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("助手", selection: $store.filter) {
                ForEach(SessionsStore.RuntimeFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("sessions.filter")
            Spacer(minLength: 0)
            if store.isRefreshing, store.phase == .loaded {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 读取失败的说明放在内容外面：列表为空或搜索无结果时也要看得到原因。
    @ViewBuilder
    private var noticeBar: some View {
        if store.phase == .loaded, !store.visibleNotices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.visibleNotices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier("sessions.notices")
        }
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
                Button("重试") { Task { await manualReload() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let emptyState = store.emptyState {
                emptyStateView(emptyState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
            }
        }
    }

    @ViewBuilder
    private func emptyStateView(_ emptyState: SessionsStore.EmptyState) -> some View {
        switch emptyState {
        case .runtimeDisabled(let runtime):
            let presentation = RuntimeDisabledPresentation.resolve(for: runtime, host: host)
            let isUpdating = runtime == .claude ? host.isUpdatingClaude : (host.updatingModule == .codex)
            ContentUnavailableView {
                Label(presentation.title, systemImage: "exclamationmark.bubble")
            } description: {
                Text(presentation.description)
            } actions: {
                HStack(spacing: 8) {
                    Button(isUpdating ? "正在启用…" : presentation.primaryButtonTitle) {
                        Task { await enableRuntime(runtime) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUpdating || !host.canChangeModule(runtime == .claude ? .claude : .codex))

                    if presentation.showsClaudeLoginActions {
                        Button("复制登录命令") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(presentation.loginCommand, forType: .string)
                        }
                        Button("打开终端") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        case .runtimeFailed(let runtime, let message):
            ContentUnavailableView {
                Label("暂时读不到 \(runtime.title) 会话", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await manualReload() } }
            }
        case .noSessions(let runtime, let hasMore):
            // 空页也可能带着后续页（子任务或网关裁掉的条目占满了前几页），
            // 所以空状态里同样要能继续加载，不能把唯一的入口藏起来。
            let title = runtime.map { "还没有 \($0.title) 会话" } ?? "还没有会话"
            let runtimeText = runtime?.title ?? "Codex 或 Claude"
            ContentUnavailableView {
                Label(title, systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(hasMore
                    ? "最近的记录里没有可显示的\(runtime.map { " \($0.title)" } ?? "")会话，可以继续读取更早的。"
                    : "在手机或电脑上开始一段 \(runtimeText) 对话后，会出现在这里。")
            } actions: {
                if hasMore { loadMoreButton }
            }
        case .noMatches(let hasMore):
            ContentUnavailableView {
                Label("没有匹配的会话", systemImage: "magnifyingglass")
            } description: {
                Text(hasMore
                    ? "已读取的会话里没有匹配的，更早的会话还没有读取。"
                    : "换个关键词或助手试试。")
            } actions: {
                if hasMore { loadMoreButton }
            }
        }
    }

    private var sessionList: some View {
        List {
            ForEach(store.visibleSections) { section in
                Section(section.title) {
                    ForEach(section.sessions) { session in
                        SessionRow(session: session) {
                            openControl(for: session)
                        }
                        .contextMenu { sessionMenu(for: session) }
                    }
                }
            }
            if store.hasMore {
                loadMoreButton
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("sessions.list")
        .safeAreaInset(edge: .bottom) {
            if store.sessions.contains(where: { $0.runtime == .claude }) {
                // Claude 桌面版、终端各自只在打开时读一次记录，互不同步（#991 实机发现，属上游行为）。
                Text("同一条 Claude 会话在桌面版、终端等多处打开时，各处不会互相同步，旧窗口里继续发消息会让记录分叉。换到另一处继续前，先关掉原来那处；回到原来那处时重新打开这条会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private func candidates(for session: DesktopSession) -> [SessionOpenTarget] {
        SessionOpenTarget.candidates(for: session.runtime, installedBundleIDs: installedApps)
    }

    private func preferredTarget(for session: DesktopSession) -> SessionOpenTarget? {
        SessionOpenTarget.preferred(
            stored: session.runtime == .codex ? codexOpenTarget : claudeOpenTarget,
            candidates: candidates(for: session),
            installedBundleIDs: installedApps
        )
    }

    /// 行尾的「打开 ▾」：左半边用上次选的 App 直接打开，右半边选别的 App。
    @ViewBuilder
    private func openControl(for session: DesktopSession) -> some View {
        if store.workingSessionID == session.id {
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 28)
        } else if let target = preferredTarget(for: session) {
            let reason = target.unavailableReason(for: session, installedBundleIDs: installedApps)
            Menu {
                sessionMenu(for: session)
            } label: {
                Label {
                    Text(target.buttonTitle(for: session))
                } icon: {
                    if let icon = SessionOpenApps.icon(for: target) { Image(nsImage: icon) }
                }
                .labelStyle(.titleAndIcon)
            } primaryAction: {
                open(session, with: target, remember: false)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(store.workingSessionID != nil)
            .help(reason ?? "用 \(target.title) 打开这条会话。")
            .accessibilityIdentifier("sessions.open.\(session.id)")
        }
    }

    private func open(_ session: DesktopSession, with target: SessionOpenTarget, remember: Bool) {
        if let reason = target.unavailableReason(for: session, installedBundleIDs: installedApps) {
            store.actionError = reason
            return
        }
        if remember {
            if session.runtime == .codex { codexOpenTarget = target.storageValue } else { claudeOpenTarget = target.storageValue }
        }
        switch target {
        case .codexDesktop:
            Task { await openInCodexDesktop(session) }
        case .terminal(let app):
            let command = host.agent.terminalHandoffCommand
            Task {
                await store.continueInTerminal(session, command: command) {
                    try await TerminalLauncher.launch($0, in: app, title: session.title)
                }
            }
        }
    }

    /// 桌面版没接本机 SSH 时先建议配置；用户选「仍然打开」就不管会话是否被占用，直接打开。
    private func openInCodexDesktop(_ session: DesktopSession) async {
        let connection = await CodexDesktopLink.connection()
        if connection != .notRunning { codexDesktopSharedSeen = connection == .shared }
        if !codexDesktopSharedSeen, !codexSharedHintMuted {
            switch CodexSharedHint.present() {
            case .cancel: return
            case .showGuide:
                showsSharedSetup = true
                return
            case .openAnyway(let mute):
                codexSharedHintMuted = mute
            }
        }
        await store.openInCodexDesktop(session) { try await CodexDesktopLink.open(threadID: $0) }
    }

    private var loadMoreButton: some View {
        Button(store.isRefreshing ? "正在读取…" : "加载更早的会话") {
            Task { await store.loadMore(endpoint: host.status?.endpoint, runtimes: enabledRuntimes) }
        }
        .disabled(store.isRefreshing)
        .accessibilityIdentifier("sessions.loadMore")
    }

    @ViewBuilder
    private func sessionMenu(for session: DesktopSession) -> some View {
        ForEach(candidates(for: session), id: \.self) { target in
            let reason = target.unavailableReason(for: session, installedBundleIDs: installedApps)
            Button {
                open(session, with: target, remember: true)
            } label: {
                Label {
                    Text(reason.map { "\(target.title)（\($0.trimmingCharacters(in: CharacterSet(charactersIn: "。")))）" } ?? target.title)
                } icon: {
                    if let icon = SessionOpenApps.icon(for: target) { Image(nsImage: icon) }
                }
            }
            .disabled(reason != nil)
        }
        if session.runtime == .codex, !codexDesktopSharedSeen {
            Button("让 Codex 桌面版和手机同时使用…") { showsSharedSetup = true }
        }
        Divider()
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
        SessionRuntime.enabled(in: host.status?.moduleStatus)
    }

    /// 服务地址或已启用的助手变化时重新加载。
    private var loadKey: String {
        let endpoint = host.status?.processOK == true ? (host.status?.endpoint ?? "") : ""
        return endpoint + "|" + enabledRuntimes.map(\.rawValue).joined(separator: ",")
    }

    private func reload() async {
        installedApps = SessionOpenApps.installedBundleIDs()
        let endpoint = host.status?.processOK == true ? host.status?.endpoint : nil
        await store.reload(endpoint: endpoint, runtimes: enabledRuntimes)
    }

    private func manualReload() async {
        if let runtime = store.filter.singleRuntime,
           runtime == .claude,
           !enabledRuntimes.contains(.claude),
           host.claudeConfiguration?.preference != .disabled,
           host.canChangeModule(.claude)
        {
            await enableRuntime(.claude)
            return
        }
        await host.refreshIfNeeded()
        await reload()
    }

    private func enableRuntime(_ runtime: SessionRuntime) async {
        switch runtime {
        case .codex:
            await host.setCodexEnabled(true)
        case .claude:
            await host.setClaudeEnabled(true)
        }
        await reload()
    }
}

/// 助手未启用时的标题、原因说明与动作按钮（#1039）。
struct RuntimeDisabledPresentation: Equatable {
    let title: String
    let description: String
    let primaryButtonTitle: String
    let showsClaudeLoginActions: Bool
    let loginCommand: String

    @MainActor
    static func resolve(for runtime: SessionRuntime, host: HostStore) -> RuntimeDisabledPresentation {
        switch runtime {
        case .claude:
            let errorText = host.claudeError?.trimmingCharacters(in: .whitespacesAndNewlines)
            let configMessage = host.claudeConfiguration?.enabled == false
                ? host.claudeConfiguration?.message.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let reason = host.claudeConfiguration?.reason
            let signedOut = reason == "claude_signed_out"
                || reason == "claude_auth_status_failed"
                || host.runtime(for: .claude)?.state == .signedOut
                || (errorText?.contains("登录") == true)
            let detail: String
            if let errorText, !errorText.isEmpty {
                detail = errorText
            } else if let configMessage, !configMessage.isEmpty {
                detail = configMessage
            } else if signedOut {
                detail = "已检测到 Claude Code，但尚未登录。请先在 Claude Code 中完成登录。"
            } else {
                detail = "Claude 通道当前已关闭。开启后可在这里查看并打开 Claude 会话。"
            }
            let loginCommand = host.runtime(for: .claude)?.effectiveLoginCommand ?? "claude"
            return RuntimeDisabledPresentation(
                title: "Claude 尚未启用",
                description: detail,
                primaryButtonTitle: signedOut ? "重新检测并启用" : "启用 Claude",
                showsClaudeLoginActions: signedOut,
                loginCommand: loginCommand
            )
        case .codex:
            let errorText = host.codexError?.trimmingCharacters(in: .whitespacesAndNewlines)
            let guidance = MenuRuntimePresentation.codexUnavailableGuidance(for: host.runtime(for: .codex))
            let detail: String
            if let errorText, !errorText.isEmpty {
                detail = errorText
            } else if let guidance, !guidance.isEmpty {
                detail = guidance
            } else {
                detail = "Codex 通道当前已关闭。开启后可在这里查看并打开 Codex 会话。"
            }
            return RuntimeDisabledPresentation(
                title: "Codex 尚未启用",
                description: detail,
                primaryButtonTitle: "启用 Codex",
                showsClaudeLoginActions: false,
                loginCommand: "codex login"
            )
        }
    }
}

private struct SessionRow<Actions: View>: View {
    let session: DesktopSession
    @ViewBuilder let actions: () -> Actions

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
            actions()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 行内有按钮，不能合并成一个无障碍元素，否则按钮读不到也点不到。
        .accessibilityElement(children: .contain)
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

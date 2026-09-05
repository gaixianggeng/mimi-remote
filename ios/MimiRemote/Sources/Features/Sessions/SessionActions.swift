import SwiftUI
import UIKit

/// 会话行的快捷动作统一从这里读取当前状态并提交，避免菜单、滑动和 VoiceOver
/// 分别维护 toggle 逻辑，尤其防止异步归档因重复 Task 回到旧状态。
@MainActor
private struct SessionRowActionController {
    let sessionStore: SessionStore
    let session: AgentSession

    var isPinned: Bool {
        sessionStore.isSessionPinned(session.id)
    }

    var isArchived: Bool {
        sessionStore.isSessionArchived(session.id)
    }

    var isUnread: Bool {
        sessionStore.isHistorySessionUnread(session)
    }

    var canChangePinState: Bool {
        !isArchived && !sessionStore.isSessionArchiveMutationPending(session.id)
    }

    var canChangeReadState: Bool {
        sessionStore.canChangeHistoryReadState(session)
    }

    var canChangeArchiveState: Bool {
        !sessionStore.isProtocolReadOnlySession(session)
            && !sessionStore.isSessionArchiveMutationPending(session.id)
    }

    var pinTitle: String {
        isPinned ? L10n.text("ui.unpin") : L10n.text("ui.pin_to_top")
    }

    var pinSystemImage: String {
        isPinned ? "pin.slash.fill" : "pin.fill"
    }

    var readTitle: String {
        isUnread ? L10n.text("ui.mark_as_read") : L10n.text("ui.mark_as_unread")
    }

    var readSystemImage: String {
        isUnread ? "envelope.open.fill" : "envelope.badge.fill"
    }

    var archiveTitle: String {
        isArchived ? L10n.text("ui.unarchive") : L10n.text("ui.archive")
    }

    var archiveSystemImage: String {
        isArchived ? "archivebox.fill" : "archivebox"
    }

    func togglePinned() {
        guard canChangePinState else { return }
        sessionStore.toggleSessionPinned(session)
        MimiHaptics.fire(.commit)
    }

    func toggleReadState() {
        guard canChangeReadState else { return }

        if isUnread {
            sessionStore.markHistorySessionRead(session.id)
        } else {
            sessionStore.markHistorySessionUnread(session.id)
        }
        MimiHaptics.fire(.commit)
    }

    func toggleArchived() {
        // 归档是远端异步写入：先锁定一次目标态，并在 pending 时拒绝再创建 Task。
        // 状态层也会按 session ID 串行化，覆盖菜单与滑动动作紧邻触发的边界情况。
        guard canChangeArchiveState else { return }
        let archived = !isArchived
        MimiHaptics.fire(.commit)
        Task {
            await sessionStore.setSessionArchivedRemote(session, archived: archived)
        }
    }
}

/// 会话管理 Sheet 使用单一枚举路由，避免重命名和 Review 各自维护布尔状态。
enum SessionActionPresentation: Identifiable {
    case rename(AgentSession)
    case review(AgentSession)

    var id: String {
        switch self {
        case .rename(let session):
            return "rename:\(session.id)"
        case .review(let session):
            return "review:\(session.id)"
        }
    }
}

/// 列表、项目侧栏和详情工具栏共用同一组会话动作。
///
/// 页面级的“刷新”和“显示详情”由各页面放在这组动作之前，避免刷新紧邻归档。
struct SessionActionMenuContent: View {
    @EnvironmentObject private var sessionStore: SessionStore

    let session: AgentSession
    @Binding var presentation: SessionActionPresentation?

    var body: some View {
        let actions = SessionRowActionController(sessionStore: sessionStore, session: session)
        let reminder = sessionStore.sessionReminder(for: session.id)
        let fullDirectoryPath = session.dir.trimmingCharacters(in: .whitespacesAndNewlines)

        Group {
            Button {
                UIPasteboard.general.string = fullDirectoryPath
            } label: {
                Label(L10n.text("ui.copy_path"), systemImage: "folder")
            }
            .disabled(fullDirectoryPath.isEmpty)
            .accessibilityValue(fullDirectoryPath)

            Button {
                UIPasteboard.general.string = session.id
            } label: {
                Label(L10n.text("ui.copy_session_id"), systemImage: "number")
            }
            .accessibilityValue(session.id)

            Divider()

            Button {
                actions.togglePinned()
            } label: {
                Label(
                    actions.pinTitle,
                    systemImage: actions.pinSystemImage
                )
            }
            .disabled(!actions.canChangePinState)

            // 条件动作留在子菜单，保持顶层条数稳定，降低按记忆位置点击时误触归档的风险。
            Menu {
                managementActions(actions: actions, reminder: reminder)
            } label: {
                Label(L10n.text("ui.more_actions"), systemImage: "ellipsis")
            }
            .menuOrder(.fixed)

            Divider()

            Button(role: actions.isArchived ? nil : .destructive) {
                actions.toggleArchived()
            } label: {
                Label(actions.archiveTitle, systemImage: actions.archiveSystemImage)
            }
            .disabled(!actions.canChangeArchiveState)
        }
    }

    @ViewBuilder
    private func managementActions(actions: SessionRowActionController, reminder: SessionReminder?) -> some View {
        Group {
            if sessionStore.isSessionObserving(session) {
                Button {
                    sessionStore.takeOverSession(session)
                } label: {
                    Label(L10n.text("ui.take_over_to_ipad"), systemImage: "hand.raised.fill")
                }
            }

            if actions.canChangeReadState {
                Button {
                    actions.toggleReadState()
                } label: {
                    Label(actions.readTitle, systemImage: actions.readSystemImage)
                }
            }

            if sessionStore.supportsCodexThreadManagement(session) {
                Divider()

                Button {
                    presentation = .rename(session)
                } label: {
                    Label(L10n.text("ui.rename"), systemImage: "pencil")
                }

                Button {
                    Task { await sessionStore.duplicateSessionInCurrentWorkspace(session) }
                } label: {
                    Label(L10n.text("ui.duplicate_session"), systemImage: "doc.on.doc")
                }
                .disabled(
                    session.isRunning || sessionStore.duplicatingSessionIDs.contains(session.id)
                )

                Button {
                    Task { await sessionStore.compactSessionContext(session) }
                } label: {
                    Label(
                        L10n.text("ui.compression_context"),
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                }
                .disabled(session.isRunning)

                Button {
                    presentation = .review(session)
                } label: {
                    Label(L10n.text("ui.start_code_review"), systemImage: "checklist.checked")
                }
                .disabled(session.isRunning)
            }

            Divider()

            Button {
                Task { await sessionStore.handoffSessionToWorktree(session) }
            } label: {
                Label(
                    L10n.text("ui.go_to_the_new_git_worktree"),
                    systemImage: "arrow.triangle.branch"
                )
            }
            .disabled(session.isRunning || sessionStore.isCreatingWorktree)

            Menu {
                Button {
                    Task { await sessionStore.scheduleSessionReminder(session, after: 30 * 60) }
                } label: {
                    Label(L10n.text("ui.30_minutes_later"), systemImage: "timer")
                }
                Button {
                    Task { await sessionStore.scheduleSessionReminder(session, after: 2 * 60 * 60) }
                } label: {
                    Label(L10n.text("ui.2_hours_later"), systemImage: "clock")
                }
                Button {
                    Task { await sessionStore.scheduleSessionReminder(session, after: 24 * 60 * 60) }
                } label: {
                    Label(L10n.text("ui.tomorrow"), systemImage: "calendar")
                }
                if reminder != nil {
                    Button(role: .destructive) {
                        sessionStore.clearSessionReminder(session)
                    } label: {
                        Label(L10n.text("ui.clear_reminder"), systemImage: "bell.slash")
                    }
                }
            } label: {
                Label(
                    L10n.text("ui.reminder"),
                    systemImage: reminder == nil ? "bell" : "bell.fill"
                )
            }
        }
    }
}

/// 两种详情布局共用刷新入口，禁用条件与刷新目标保持一致。
struct CurrentSessionRefreshMenuButton: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        Button {
            Task { await sessionStore.refreshCurrentContext() }
        } label: {
            Label(L10n.text("ui.refresh_current_session"), systemImage: "arrow.clockwise")
        }
        .disabled(sessionStore.isRefreshingSelectedSession || sessionStore.isLoading)
    }
}

private struct SessionActionSheetsModifier: ViewModifier {
    @Binding var presentation: SessionActionPresentation?

    func body(content: Content) -> some View {
        content.sheet(item: $presentation) { destination in
            switch destination {
            case .rename(let session):
                SessionRenameSheet(session: session)
            case .review(let session):
                SessionReviewSheet(session: session)
            }
        }
    }
}

private struct SessionActionsContextMenuModifier: ViewModifier {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var presentation: SessionActionPresentation?
    let session: AgentSession

    func body(content: Content) -> some View {
        let actions = SessionRowActionController(sessionStore: sessionStore, session: session)

        content
            .contextMenu {
                SessionActionMenuContent(
                    session: session,
                    presentation: $presentation
                )
            }
            // 自定义动作与上下文菜单使用同一控制器；标签始终反映当前状态，
            // regular iPad 即使不启用 swipe 也保留完整的 VoiceOver 等价入口。
            .accessibilityActions {
                Button(actions.pinTitle) {
                    actions.togglePinned()
                }
                .disabled(!actions.canChangePinState)

                if actions.canChangeReadState {
                    Button(actions.readTitle) {
                        actions.toggleReadState()
                    }
                }

                Button(actions.archiveTitle) {
                    actions.toggleArchived()
                }
                .disabled(!actions.canChangeArchiveState)
            }
            .sessionActionSheets(presentation: $presentation)
    }
}

private struct SessionRowSwipeActionsModifier: ViewModifier {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    let session: AgentSession

    @ViewBuilder
    func body(content: Content) -> some View {
        if horizontalSizeClass == .compact {
            let actions = SessionRowActionController(sessionStore: sessionStore, session: session)
            let tokens = themeStore.tokens(for: colorScheme)

            content
                // LTR 下从左向右滑动揭示 leading；显式禁止 full swipe，避免误提交状态。
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        actions.togglePinned()
                    } label: {
                        Label(actions.pinTitle, systemImage: actions.pinSystemImage)
                    }
                    .tint(actions.isPinned ? tokens.sessionUnpinActionTint : tokens.sessionPinActionTint)
                    .disabled(!actions.canChangePinState)

                    if actions.canChangeReadState {
                        Button {
                            actions.toggleReadState()
                        } label: {
                            Label(actions.readTitle, systemImage: actions.readSystemImage)
                        }
                        .tint(
                            actions.isUnread
                                ? tokens.sessionMarkReadActionTint
                                : tokens.sessionMarkUnreadActionTint
                        )
                    }
                }
                // LTR 下从右向左滑动揭示 trailing；永久删除、停止和取消不进入滑动入口。
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: actions.isArchived ? nil : .destructive) {
                        actions.toggleArchived()
                    } label: {
                        Label(actions.archiveTitle, systemImage: actions.archiveSystemImage)
                    }
                    .tint(actions.isArchived ? Color.blue : Color.red)
                    .disabled(!actions.canChangeArchiveState)
                }
        } else {
            content
        }
    }
}

extension View {
    func sessionActionSheets(
        presentation: Binding<SessionActionPresentation?>
    ) -> some View {
        modifier(SessionActionSheetsModifier(presentation: presentation))
    }

    func sessionRowActions(_ session: AgentSession) -> some View {
        modifier(SessionActionsContextMenuModifier(session: session))
    }

    func sessionRowSwipeActions(_ session: AgentSession) -> some View {
        modifier(SessionRowSwipeActionsModifier(session: session))
    }
}

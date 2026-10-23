import XCTest
@testable import MimiRemote

/// #683：会话活动状态的唯一分类，以及电脑端（终端 / Claude 桌面端）正在处理的会话在三个表面的读法。
final class SessionActivityStateTests: XCTestCase {
    private let busyOwner = ClaudeSessionOwner(
        entrypoint: "cli", kind: "interactive", status: "busy", pid: 4242,
        statusUpdatedAt: Date(timeIntervalSince1970: 1_000)
    )
    private let idleOwner = ClaudeSessionOwner(entrypoint: "claude-desktop", kind: "interactive", status: "idle", pid: 4343)

    func testComputerHeldSessionIsRunningOnlyWhileTheHolderIsBusy() {
        var held = makeSession(id: "held", projectID: "p", title: "held", status: "history", source: "claude", runtimeProvider: "claude")
        held.canAcceptDirectInput = false

        held.claudeOwner = busyOwner
        XCTAssertEqual(held.activityState, .running(.computer(busyOwner)))
        XCTAssertTrue(held.isRunning, "电脑端在跑的会话要进「进行中」，不能当成历史")
        XCTAssertTrue(held.isRunningOnComputer)
        XCTAssertTrue(held.isHeldOnComputer)

        // 适配器把持有方执行中的会话在 thread/list 里报成 active；两条路径殊途同归。
        held.status = SessionStatus.running.rawValue
        XCTAssertEqual(held.activityState, .running(.computer(busyOwner)))

        held.status = "history"
        held.claudeOwner = idleOwner
        XCTAssertEqual(held.activityState, .idle)
        XCTAssertFalse(held.isRunning)
        XCTAssertTrue(held.isHeldOnComputer, "空闲持有仍是只读，但不是进行中")

        // 没有 canAcceptDirectInput=false 的 owner 摘要不算持有（旧协议 / 残留字段）。
        held.canAcceptDirectInput = true
        held.claudeOwner = busyOwner
        XCTAssertEqual(held.activityState, .idle)
        XCTAssertFalse(held.isRunningOnComputer)
    }

    func testActivityStatePriorityMatchesTheDisplayStatusPriority() {
        let approval = ApprovalSummary(id: "a", title: "Approve", kind: "command", count: nil)
        var session = makeSession(id: "s", projectID: "p", title: "s", status: SessionStatus.running.rawValue, source: "codex")
        session.activeTurnID = "turn-1"
        XCTAssertEqual(session.activityState, .running(.mimi(hasActiveTurn: true)))
        XCTAssertEqual(session.displayStatus(foregroundActivity: nil).title, L10n.text("ui.processing"))

        session.activeTurnID = nil
        XCTAssertEqual(session.activityState, .running(.mimi(hasActiveTurn: false)))
        XCTAssertEqual(session.displayStatus(foregroundActivity: nil).title, L10n.text("ui.running"))

        session.pendingApproval = approval
        XCTAssertEqual(session.activityState, .needsYou(.approval))
        XCTAssertTrue(session.activityState.needsYou)
        XCTAssertEqual(session.displayStatus(foregroundActivity: nil).tone, .warning)

        session.pendingApproval = nil
        session.status = SessionStatus.waitingForInput.rawValue
        XCTAssertEqual(session.activityState, .needsYou(.userInput), "没有请求载荷的等待输入态同样是待你处理")
        XCTAssertTrue(session.isRunning)

        session.status = SessionStatus.failed.rawValue
        XCTAssertEqual(session.activityState, .failed)
        XCTAssertTrue(session.activityState.needsAttention)
        XCTAssertEqual(session.displayStatus(foregroundActivity: nil).tone, .danger)

        session.status = SessionStatus.completed.rawValue
        XCTAssertEqual(session.activityState, .idle)
        XCTAssertEqual(session.displayStatus(foregroundActivity: nil).title, L10n.text("ui.complete"))

        let draft = AgentSession(
            id: "local:draft", projectID: "p", project: "p", dir: "/tmp/p", title: "", status: "draft",
            source: "local", runtimeProvider: nil, resumeID: nil, createdAt: nil, updatedAt: nil, recencyAt: nil,
            preview: nil
        )
        XCTAssertEqual(draft.activityState, .draft)
    }

    func testComputerRunDisplaysWhereItRunsAndFeedsEverySurfaceTheSameWay() {
        var held = makeSession(id: "held", projectID: "p", title: "held", status: "history", source: "claude", runtimeProvider: "claude")
        held.canAcceptDirectInput = false
        held.claudeOwner = busyOwner

        let status = held.displayStatus(foregroundActivity: nil)
        XCTAssertEqual(status.title, L10n.text("ui.running_on_computer"))
        XCTAssertEqual(status.tone, .active)
        XCTAssertTrue(status.showsSpinner)
        // 列表字形：进行中环；它压过未读点。
        XCTAssertEqual(SessionRowState.resolve(status: status, isUnread: true), .running)
        // 工作区分组与侧栏分区都读到「进行中」。
        XCTAssertEqual(WorkspaceSessionGroup.of(held), .running)
        let sections = SessionListPresentation.sidebarSections(sessions: [held])
        XCTAssertEqual(sections.map(\.kind), [.running])
        // 前台刷新提示仍优先于"在哪跑"，与本端会话一致。
        XCTAssertEqual(held.displayStatus(foregroundActivity: .refreshing).title, L10n.text("ui.synchronizing"))

        held.claudeOwner = idleOwner
        XCTAssertEqual(WorkspaceSessionGroup.of(held), .recent)
        XCTAssertEqual(SessionListPresentation.sidebarSections(sessions: [held]).map(\.kind), [.recent])
        XCTAssertEqual(
            SessionRowState.resolve(status: held.displayStatus(foregroundActivity: nil), isUnread: true),
            .unread,
            "空闲持有的会话可以标未读"
        )
    }

    func testComputerWaitingShowsReasonWithoutAnActionableRequestOnEverySurface() throws {
        var held = makeSession(id: "held", projectID: "p", title: "held", status: "running", source: "claude", runtimeProvider: "claude")
        held.canAcceptDirectInput = false
        for reason in ClaudeSessionOwner.WaitingKind.allCases {
            held.claudeOwner = ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "waiting", pid: 7, waitingKind: reason)
            XCTAssertEqual(held.activityState, .needsYou(.computer(reason)))
            XCTAssertTrue(held.isRunning)
            XCTAssertTrue(held.isWaitingOnComputer)
            XCTAssertFalse(held.isRunningOnComputer)
            XCTAssertFalse(held.allowsDirectInput)
            XCTAssertNil(held.pendingApproval)
            XCTAssertNil(held.pendingUserInput)
            let status = held.displayStatus(foregroundActivity: nil)
            XCTAssertEqual(status.title, reason.title)
            XCTAssertEqual(status.tone, .warning)
            XCTAssertFalse(status.showsSpinner)
            XCTAssertEqual(WorkspaceSessionGroup.of(held), .needsAttention)
            XCTAssertEqual(SessionListPresentation.sidebarSections(sessions: [held]).map(\.kind), [.needYou])
            for language in [AppLanguage.simplifiedChinese, .english] {
                for suffix in ["title", "message"] {
                    let key = "ui.computer_waiting_\(reason.rawValue)_\(suffix)"
                    XCTAssertNotEqual(L10n.text(key, language: language), key)
                }
            }
        }
        let legacy = try JSONDecoder().decode(ClaudeSessionOwner.self, from: Data(#"{"status":"waiting"}"#.utf8))
        held.claudeOwner = legacy
        XCTAssertEqual(held.activityState, .needsYou(.computer(.other)))
        let future = try JSONDecoder().decode(ClaudeSessionOwner.self, from: Data(#"{"status":"waiting","waitingKind":"future_reason"}"#.utf8))
        XCTAssertEqual(future.waitingReason, .other)
    }

    func testWorkspaceGroupsShareTheSidebarVocabulary() {
        XCTAssertEqual(WorkspaceSessionGroup.needsAttention.title, L10n.text("ui.needs_you"))
        XCTAssertEqual(WorkspaceSessionGroup.running.title, L10n.text("ui.in_progress"))
        XCTAssertEqual(WorkspaceSessionGroup.recent.title, L10n.text("ui.recently"))
        var failed = makeSession(id: "f", projectID: "p", title: "f", status: SessionStatus.failed.rawValue, source: "codex")
        let soonAfter = Date(timeIntervalSince1970: 2 + 60)
        XCTAssertEqual(WorkspaceSessionGroup.of(failed, now: soonAfter), .needsAttention)
        failed.status = SessionStatus.waitingForApproval.rawValue
        XCTAssertEqual(WorkspaceSessionGroup.of(failed), .needsAttention, "等待审批不受时间窗口限制")
    }

    /// #546：失败计入「待你处理」只保留 12 小时，侧栏与工作区页同一判定、同一成员。
    func testFailedSessionsNeedAttentionForTwelveHoursInBothSidebarAndWorkspace() {
        let failed = makeSession(id: "f", projectID: "p", title: "f", status: SessionStatus.failed.rawValue, source: "codex")
        let failedAt = SessionIndexStore.orderingDate(for: failed)
        let fresh = failedAt.addingTimeInterval(SessionAttentionPolicy.failedAttentionWindow - 1)
        let stale = failedAt.addingTimeInterval(SessionAttentionPolicy.failedAttentionWindow + 1)

        XCTAssertEqual(WorkspaceSessionGroup.of(failed, now: fresh), .needsAttention)
        XCTAssertEqual(SessionListPresentation.sidebarSections(sessions: [failed], now: fresh).map(\.kind), [.needYou])
        XCTAssertEqual(WorkspaceSessionGroup.of(failed, now: stale), .recent)
        XCTAssertEqual(SessionListPresentation.sidebarSections(sessions: [failed], now: stale).map(\.kind), [.recent])
    }

    func testNextExpiryOnlyConsidersFailedSessionsStillInsideTheWindow() {
        let failed = makeSession(id: "f", projectID: "p", title: "f", status: SessionStatus.failed.rawValue, source: "codex")
        let idle = makeSession(id: "i", projectID: "p", title: "i", status: SessionStatus.idle.rawValue, source: "codex")
        let failedAt = SessionIndexStore.orderingDate(for: failed)
        XCTAssertEqual(
            SessionAttentionPolicy.nextExpiry(in: [idle, failed], now: failedAt.addingTimeInterval(60)),
            failedAt.addingTimeInterval(SessionAttentionPolicy.failedAttentionWindow)
        )
        XCTAssertNil(
            SessionAttentionPolicy.nextExpiry(in: [idle, failed], now: failedAt.addingTimeInterval(SessionAttentionPolicy.failedAttentionWindow + 1)),
            "已过期的失败会话不再安排刷新"
        )
    }

    /// #546：侧栏「待你处理」行的状态文案与会话页同一份 displayStatus。
    func testNeedsYouStatusTextComesFromSharedDisplayStatus() {
        var waiting = makeSession(id: "w", projectID: "p", title: "w", status: SessionStatus.waitingForApproval.rawValue, source: "codex")
        XCTAssertNil(waiting.pendingApproval, "审批载荷还没到")
        XCTAssertEqual(waiting.displayStatus(foregroundActivity: nil).title, L10n.text("ui.pending_approval"))
        waiting.status = SessionStatus.failed.rawValue
        XCTAssertEqual(waiting.displayStatus(foregroundActivity: nil).title, L10n.text("ui.failed_status"))
    }

    func testClaudeOwnerDecodesWithoutTheStatusTimestamp() throws {
        let legacy = try JSONDecoder().decode(
            ClaudeSessionOwner.self,
            from: Data(#"{"entrypoint":"cli","kind":"interactive","status":"idle","pid":7}"#.utf8)
        )
        XCTAssertEqual(legacy, ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "idle", pid: 7))
        XCTAssertNil(legacy.statusUpdatedAt)
    }

    @MainActor
    func testLiveIndexUpdateMovesAComputerRunIntoRunningAndBackToUnread() {
        let project = makeProject(id: "proj_live_index")
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: []) }
        )
        var held = makeSession(
            id: "live-index", projectID: project.id, title: "held", status: "history",
            source: "claude", runtimeProvider: "claude", updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        held.canAcceptDirectInput = false
        held.claudeOwner = idleOwner
        store.upsert(held)
        store.synchronizeHistoryReadStates()
        XCTAssertFalse(store.isHistorySessionUnread(held), "首次见到的历史建立已读基线")

        // 终端里的 Claude 开始处理：适配器广播 active + busy，列表进「进行中」。
        var running = held
        running.status = SessionStatus.running.rawValue
        running.claudeOwner = busyOwner
        store.applyLiveSessionIndexUpdate(running)
        let live = store.sessions.first { $0.id == held.id }
        XCTAssertEqual(live?.activityState, .running(.computer(busyOwner)))
        XCTAssertEqual(live?.canAcceptDirectInput, false)
        XCTAssertFalse(store.isHistorySessionUnread(running), "进行中不标未读")

        // 处理结束：idle + 新的最后活动时间，不刷新列表也要变成未读并记为刚完成。
        var done = held
        done.claudeOwner = idleOwner
        done.updatedAt = Date(timeIntervalSince1970: 2_000)
        store.applyLiveSessionIndexUpdate(done)
        let settled = store.sessions.first { $0.id == held.id }
        XCTAssertEqual(settled?.activityState, .idle)
        XCTAssertEqual(settled?.updatedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertTrue(store.isHistorySessionUnread(done))
        XCTAssertNotNil(store.historyCompletionObservedAtBySessionID[held.id])

        // 别的客户端答复了审批：快照转为运行，旧的待处理请求必须一起清掉，不能继续归在「待你处理」。
        var awaiting = done
        awaiting.status = SessionStatus.waitingForApproval.rawValue
        awaiting.pendingApproval = ApprovalSummary(id: "approval-1", title: "Run tests", kind: "command", count: nil)
        store.applyLiveSessionIndexUpdate(awaiting)
        XCTAssertEqual(store.sessions.first { $0.id == held.id }?.activityState, .needsYou(.approval))
        // 仍在等待、但快照不带请求正文时保留已有的可操作请求。
        var stillWaiting = awaiting
        stillWaiting.pendingApproval = nil
        store.applyLiveSessionIndexUpdate(stillWaiting)
        XCTAssertEqual(store.sessions.first { $0.id == held.id }?.pendingApproval?.id, "approval-1")
        var answered = done
        answered.status = SessionStatus.running.rawValue
        answered.claudeOwner = busyOwner
        store.applyLiveSessionIndexUpdate(answered)
        let resumed = store.sessions.first { $0.id == held.id }
        XCTAssertNil(resumed?.pendingApproval)
        XCTAssertEqual(resumed?.activityState, .running(.computer(busyOwner)))
        store.applyLiveSessionIndexUpdate(done)

        // 不在 Store 里的会话不会被插进来；更旧的时间不会倒退。
        var stranger = makeSession(id: "stranger", projectID: project.id, title: "x", status: "running", source: "claude", runtimeProvider: "claude")
        stranger.canAcceptDirectInput = false
        store.applyLiveSessionIndexUpdate(stranger)
        XCTAssertNil(store.sessions.first { $0.id == "stranger" })
        var stale = done
        stale.updatedAt = Date(timeIntervalSince1970: 500)
        store.applyLiveSessionIndexUpdate(stale)
        XCTAssertEqual(store.sessions.first { $0.id == held.id }?.updatedAt, Date(timeIntervalSince1970: 2_000))
    }
}

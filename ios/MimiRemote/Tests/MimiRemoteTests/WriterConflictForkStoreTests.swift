import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class WriterConflictForkStoreTests: XCTestCase {
    func testIdleWriterConflictForksLatestStateAndKeepsSourceLock() async {
        let fixture = makeFixture(sourceStatus: "history")
        fixture.store.setErrorMessage(
            "app-server 错误 -32600: thread source-thread already has an active writer",
            sessionID: fixture.source.id
        )
        XCTAssertEqual(fixture.store.errorMessage, L10n.text("ui.codex_active_writer_conflict"))

        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: nil)
        )

        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertTrue(duplicated)
        XCTAssertEqual(fixture.client.requestedSessionForks, [
            RequestedSessionFork(
                threadID: fixture.source.resumeID ?? fixture.source.id,
                workspaceID: fixture.workspace.id,
                reason: .duplicate,
                lastTurnID: nil
            )
        ])
        XCTAssertEqual(fixture.store.selectedSessionID, fixture.forked.id)
        XCTAssertNil(fixture.store.errorMessage, "原会话的占用提示不能留在复制出的新会话中。")
        XCTAssertFalse(fixture.store.selectedSessionHasActiveWriterConflict)
        XCTAssertTrue(
            fixture.store.hasActiveWriterConflict(sessionID: fixture.source.id),
            "复制成功只能打开新 Thread，不能清除原会话的 writer 结论。"
        )
        XCTAssertNil(
            fixture.store.writerConflictForkAvailabilityByLease[fixture.sourceLease]
        )
    }

    func testRunningWriterConflictForksFromLatestTerminalTurn() async {
        let fixture = makeFixture(
            sourceStatus: "running",
            historyPage: HistoryMessagesPage(
                messages: [],
                loadMode: .economy,
                latestForkableTurnID: "turn-last-terminal"
            )
        )
        fixture.store.setErrorMessage(
            "app-server 错误 -32600: thread source-thread already has an active writer",
            sessionID: fixture.source.id
        )

        await fixture.store.prepareSelectedWriterConflictForkAvailability()

        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: "turn-last-terminal")
        )
        XCTAssertEqual(fixture.client.requestedMessageSessionIDs, [fixture.source.resumeID ?? fixture.source.id])
        XCTAssertEqual(fixture.client.requestedMessageLimits, [2])

        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertTrue(duplicated)
        XCTAssertEqual(fixture.client.requestedSessionForks.first?.lastTurnID, "turn-last-terminal")
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertFalse(fixture.store.selectedSessionHasActiveWriterConflict)
        XCTAssertTrue(fixture.store.hasActiveWriterConflict(sessionID: fixture.source.id))
    }

    func testWriterConflictCopyCanSendFirstPromptToNewSession() async throws {
        let fixture = makeFixture(sourceStatus: "history")
        fixture.store.setErrorMessage(
            "app-server 错误 -32600: thread source-thread already has an active writer",
            sessionID: fixture.source.id
        )
        fixture.client.createSessionResults = [
            .success(try makeCreateSessionResponse(session: fixture.forked))
        ]

        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()
        XCTAssertTrue(duplicated)
        XCTAssertNil(fixture.store.errorMessage)

        let sent = await fixture.store.sendTurn(CodexAppServerTurnPayload(
            prompt: "继续这个副本",
            options: .init(model: "gpt-test", modelProvider: "openai")
        ))

        XCTAssertTrue(sent)
        XCTAssertEqual(fixture.client.createPayloads.count, 1)
        XCTAssertEqual(fixture.client.createPayloads.first?.resumeID, fixture.forked.id)
        XCTAssertEqual(fixture.client.createPayloads.first?.prompt, "继续这个副本")
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertFalse(fixture.store.selectedSessionHasActiveWriterConflict)
        XCTAssertTrue(fixture.store.hasActiveWriterConflict(sessionID: fixture.source.id))
        fixture.store.clearConnectionData()
    }

    func testRetryReloadsLatestMessagesBeforeRecheckingWriterAccess() async throws {
        let project = makeProject(id: "proj-writer-retry-refresh")
        let source = makeSession(
            id: "source-writer-retry-refresh",
            projectID: project.id,
            title: "Desktop source",
            status: "running",
            source: "codex",
            resumeID: "source-writer-retry-refresh"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [source])
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "writer-retry-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        select(source: source, project: project, in: store)

        let staleHistoryTask = Task {
            await store.loadHistory(
                for: source,
                quiet: true,
                loadMode: .full,
                reason: .automatic
            )
        }
        await client.waitForHistoryRequestCount(1)

        let retryTask = Task { await store.retrySelectedSessionWriterAccess() }
        await client.waitForHistoryRequestCount(2)

        XCTAssertTrue(store.isRetryingSelectedWriterConflict)
        XCTAssertTrue(sockets.isEmpty, "最新历史返回前不能提前重判 writer。")
        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: source.id))

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    id: "rollout:writer-retry-stale",
                    role: "assistant",
                    content: "后台旧快照",
                    createdAt: Date(timeIntervalSince1970: 207)
                )
            ])
        )
        _ = await staleHistoryTask.value
        XCTAssertTrue(sockets.isEmpty, "被替换的旧历史请求完成后不能开始 writer 重判。")
        XCTAssertTrue(conversationStore.messages(for: source.id).isEmpty)

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    id: "rollout:writer-retry-latest",
                    role: "assistant",
                    content: "Desktop 最新回复",
                    createdAt: Date(timeIntervalSince1970: 208)
                )
            ])
        )
        await retryTask.value

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .full])
        XCTAssertEqual(
            conversationStore.messages(for: source.id).map(\.content),
            ["Desktop 最新回复"]
        )
        XCTAssertEqual(sockets.count, 1)
        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: source.id))

        let retrySocket = try XCTUnwrap(sockets.first)
        retrySocket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        XCTAssertFalse(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertFalse(store.isRetryingSelectedWriterConflict)
    }

    func testRetryKeepsWriterConflictWhenLatestMessagesFailToLoad() async {
        let project = makeProject(id: "proj-writer-retry-failure")
        let source = makeSession(
            id: "source-writer-retry-failure",
            projectID: project.id,
            title: "Desktop source",
            status: "running",
            source: "codex",
            resumeID: "source-writer-retry-failure"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [source])
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "writer-retry-failure-token"
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        select(source: source, project: project, in: store)

        let retryTask = Task { await store.retrySelectedSessionWriterAccess() }
        await client.waitForHistoryRequestCount(1)
        client.failHistoryRequest(at: 0, with: MockError.timeout)
        await retryTask.value

        XCTAssertTrue(sockets.isEmpty, "历史刷新失败时不能用旧快照继续重判 writer。")
        XCTAssertTrue(store.hasActiveWriterConflict(sessionID: source.id))
        XCTAssertFalse(store.isRetryingSelectedWriterConflict)
        XCTAssertEqual(
            store.selectedWriterConflictForkErrorMessage,
            L10n.text("ui.writer_conflict_retry_refresh_failed")
        )
    }

    func testWriterConflictChangingFromIdleToRunningRefreshesForkBoundary() async {
        let fixture = makeFixture(
            sourceStatus: "history",
            historyPage: HistoryMessagesPage(
                messages: [],
                loadMode: .economy,
                latestForkableTurnID: "turn-before-new-run"
            )
        )
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)

        await fixture.store.prepareSelectedWriterConflictForkAvailability()
        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: nil)
        )

        var runningSource = fixture.source
        runningSource.status = "running"
        fixture.store.sessions = [runningSource]

        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .checking,
            "空闲转为运行中后、重新探测完成前不能继续暴露空闲缓存的 .available(lastTurnID: nil)"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: fixture.store.selectedWriterConflictForkAvailability
            ),
            "ui.writer_conflict_shared_guide_now_pending_body",
            "过渡期间共享引导不能短暂承诺可分支到最近已完成回合"
        )
        let blockedBeforeProbe = await fixture.store.duplicateSelectedWriterConflictSession()
        XCTAssertFalse(blockedBeforeProbe)
        XCTAssertTrue(fixture.client.requestedSessionForks.isEmpty)

        await fixture.store.prepareSelectedWriterConflictForkAvailability()

        XCTAssertEqual(fixture.client.requestedMessageLimits, [2])
        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: "turn-before-new-run")
        )
    }

    func testRunningWriterConflictWithoutTerminalTurnCannotFork() async {
        let fixture = makeFixture(
            sourceStatus: "running",
            historyPage: HistoryMessagesPage(messages: [], loadMode: .economy)
        )
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)

        await fixture.store.prepareSelectedWriterConflictForkAvailability()
        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .unavailableNoTerminalTurn
        )
        XCTAssertFalse(duplicated)
        XCTAssertTrue(fixture.client.requestedSessionForks.isEmpty)
    }

    func testRunningOrReadOnlySessionCannotBypassForkGuard() async {
        let running = makeFixture(sourceStatus: "running")

        let ordinaryDuplicate = await running.store.duplicateSessionInCurrentWorkspace(running.source)

        XCTAssertFalse(ordinaryDuplicate)
        XCTAssertTrue(running.client.requestedSessionForks.isEmpty)

        var readOnlySource = running.source
        readOnlySource.canAcceptDirectInput = false
        let readOnly = makeFixture(source: readOnlySource)
        readOnly.store.setActiveWriterConflict(true, sessionID: readOnly.source.id)

        XCTAssertNil(readOnly.store.selectedWriterConflictForkAvailability)
        let readOnlyDuplicate = await readOnly.store.duplicateSelectedWriterConflictSession()
        XCTAssertFalse(readOnlyDuplicate)
        XCTAssertTrue(readOnly.client.requestedSessionForks.isEmpty)
    }

    func testForkFailureStaysInlineAndConcurrentOperationIsRejected() async {
        let failure = AgentAPIError.server(status: 409, message: "fork rejected")
        let fixture = makeFixture(
            sourceStatus: "history",
            forkResult: .failure(failure)
        )
        fixture.store.setErrorMessage(
            "app-server 错误 -32600: thread source-thread already has an active writer",
            sessionID: fixture.source.id
        )
        fixture.store.duplicatingSessionIDs.insert(fixture.source.id)

        let blocked = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertFalse(blocked)
        XCTAssertTrue(fixture.client.requestedSessionForks.isEmpty)
        fixture.store.duplicatingSessionIDs.remove(fixture.source.id)

        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertFalse(duplicated)
        XCTAssertEqual(fixture.client.requestedSessionForks.count, 1)
        XCTAssertTrue(
            fixture.store.selectedWriterConflictForkErrorMessage?.contains("fork rejected") == true
        )
        XCTAssertTrue(fixture.store.hasActiveWriterConflict(sessionID: fixture.source.id))
        XCTAssertEqual(fixture.store.selectedSessionID, fixture.source.id)
        XCTAssertEqual(fixture.store.errorMessage, L10n.text("ui.codex_active_writer_conflict"))
    }

    func testOldHostCompletionDoesNotReleaseNewHostDuplicateLock() async throws {
        let project = makeProject(id: "proj-host-scoped-fork")
        let source = makeSession(
            id: "same-session-id",
            projectID: project.id,
            title: "Shared source",
            status: "history",
            source: "codex",
            resumeID: "same-thread-id"
        )
        let workspace = AgentWorkspace(project: project)
        let forked = makeSession(
            id: "forked-thread",
            projectID: project.id,
            title: "Forked",
            status: "history",
            source: "codex",
            resumeID: "forked-thread"
        )
        let firstGate = WriterConflictWorkspaceResolveGate()
        let secondGate = WriterConflictWorkspaceResolveGate()
        let firstClient = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: ["same-thread-id": .success(forked)],
            resolveWorkspaceHandler: { _ in try await firstGate.response() }
        )
        let secondClient = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: ["same-thread-id": .success(forked)],
            resolveWorkspaceHandler: { _ in try await secondGate.response() }
        )
        let appStore = makeIsolatedAppStore()
        var activeClient = firstClient
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { activeClient }
        )

        select(source: source, project: project, in: store)
        let firstTask = Task { await store.duplicateSelectedWriterConflictSession() }
        await firstGate.waitUntilRequested()

        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.208:8787",
            token: "host-b-token",
            profileTarget: .newProfile(id: "writer-host-b", displayName: "Writer Host B"),
            installationID: "writer-host-b-installation"
        ))
        store.clearConnectionData()
        activeClient = secondClient
        select(source: source, project: project, in: store)

        let secondTask = Task { await store.duplicateSelectedWriterConflictSession() }
        await secondGate.waitUntilRequested()

        firstGate.resolve(workspace)
        let firstResult = await firstTask.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(
            store.duplicatingSessionIDs.contains(source.id),
            "旧 Host 的 defer 不能释放新 Host 上同名 Session 的操作锁。"
        )

        secondGate.resolve(workspace)
        let secondResult = await secondTask.value
        XCTAssertTrue(secondResult)
        XCTAssertFalse(store.duplicatingSessionIDs.contains(source.id))
    }

    func testSharedGuideNowBodyMatchesConflictState() {
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil)
            ),
            "ui.writer_conflict_shared_guide_now_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: .available(lastTurnID: "turn-1")
            ),
            "ui.writer_conflict_shared_guide_now_running_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: .unavailableNoTerminalTurn
            ),
            "ui.writer_conflict_shared_guide_now_no_terminal_turn_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: false,
                availability: nil
            ),
            "ui.writer_conflict_shared_guide_now_no_fork_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: .checking
            ),
            "ui.writer_conflict_shared_guide_now_pending_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: .failed
            ),
            "ui.writer_conflict_shared_guide_now_pending_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: .available(lastTurnID: nil)
            ),
            "ui.writer_conflict_shared_guide_now_pending_body",
            "运行中但尚未确认终态 Turn 时不得承诺可分支"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: .available(lastTurnID: "turn-1"),
                status: .resolvedWritable,
                hostPlatform: .apple
            ),
            "ui.writer_conflict_shared_guide_now_resolved_body"
        )
        for nonMacOrUnknown in [HostPlatform.windows, .linux, .unknown] {
            XCTAssertEqual(
                WriterConflictSharedGuideSheet.nowSectionBodyKey(
                    sourceIsRunning: true,
                    availability: .available(lastTurnID: "turn-1"),
                    status: .resolvedWritable,
                    hostPlatform: nonMacOrUnknown
                ),
                "ui.writer_conflict_shared_guide_now_resolved_non_mac_body",
                "\(nonMacOrUnknown.rawValue) 平台恢复可写后不应提示 Mac 配置步骤"
            )
        }
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil),
                status: .offline
            ),
            "ui.writer_conflict_shared_guide_now_offline_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil),
                status: .retrying
            ),
            "ui.writer_conflict_shared_guide_now_retrying_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil),
                status: .duplicating
            ),
            "ui.writer_conflict_shared_guide_now_duplicating_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: true,
                availability: .available(lastTurnID: "turn-1"),
                status: .connectionTerminated(.credentialsInvalid)
            ),
            "ui.writer_conflict_shared_guide_now_credentials_invalid_body"
        )
        XCTAssertEqual(
            WriterConflictSharedGuideSheet.nowSectionBodyKey(
                sourceIsRunning: false,
                availability: nil,
                status: .unavailable
            ),
            "ui.writer_conflict_shared_guide_now_unavailable_body"
        )
    }

    func testConflictCardMessageBodyOnlyPromisesTurnBoundaryWhenConfirmed() {
        XCTAssertEqual(
            WriterConflictCard.messageBodyKey(sourceIsRunning: false, availability: nil),
            "ui.codex_active_writer_conflict"
        )
        XCTAssertEqual(
            WriterConflictCard.messageBodyKey(sourceIsRunning: true, availability: .unavailableNoTerminalTurn),
            "ui.writer_conflict_fork_no_terminal_turn"
        )
        XCTAssertEqual(
            WriterConflictCard.messageBodyKey(sourceIsRunning: true, availability: .checking),
            "ui.writer_conflict_fork_checking_explanation"
        )
        XCTAssertEqual(
            WriterConflictCard.messageBodyKey(sourceIsRunning: true, availability: .failed),
            "ui.writer_conflict_fork_failed_explanation"
        )
        XCTAssertEqual(
            WriterConflictCard.messageBodyKey(sourceIsRunning: true, availability: .available(lastTurnID: nil)),
            "ui.writer_conflict_fork_checking_explanation"
        )
        XCTAssertEqual(
            WriterConflictCard.messageBodyKey(sourceIsRunning: true, availability: .available(lastTurnID: "turn-1")),
            "ui.writer_conflict_fork_running_explanation"
        )
        XCTAssertEqual(
            WriterConflictCard.messageBodyKey(sourceIsRunning: false, availability: .available(lastTurnID: nil)),
            "ui.writer_conflict_fork_idle_explanation"
        )
    }

    func testSharedGuideSectionsAdaptToHostPlatform() {
        let appleSections = WriterConflictSharedGuideSheet.sections(
            sourceIsRunning: false,
            availability: .available(lastTurnID: nil),
            hostPlatform: .apple
        )
        XCTAssertEqual(appleSections.map(\.id), ["why", "mac", "now"])
        XCTAssertTrue(appleSections[1].body.contains("让 Codex 桌面版和手机同时使用…"))
        XCTAssertTrue(appleSections[1].body.contains("打开 Codex 桌面版"))
        XCTAssertTrue(appleSections[1].body.contains("允许本机免密登录"))
        XCTAssertTrue(appleSections[1].body.contains("退出占锁的 Codex 进程"))
        XCTAssertFalse(appleSections[1].body.contains("~/.ssh"))
        XCTAssertFalse(appleSections[1].body.contains("复制命令"))
        XCTAssertFalse(appleSections[1].body.contains("一键配置本机 SSH"))

        for nonMac in [HostPlatform.windows, .linux] {
            let sections = WriterConflictSharedGuideSheet.sections(
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil),
                hostPlatform: nonMac
            )
            XCTAssertEqual(sections.map(\.id), ["why", "nonMac", "now"])
            XCTAssertEqual(sections[1].title, L10n.text("ui.writer_conflict_shared_guide_non_mac_title"))
            XCTAssertFalse(
                sections[1].body.contains("让 Codex 桌面版和手机同时使用…"),
                "\(nonMac.rawValue) 主机不应展示 Mac 专用的配置入口"
            )
            XCTAssertFalse(
                sections[1].body.contains("打开 Codex 桌面版"),
                "\(nonMac.rawValue) 主机不应展示 Mac 专用步骤"
            )
            XCTAssertFalse(
                sections[1].body.contains("一键"),
                "\(nonMac.rawValue) 主机不应引用尚未合入的一键配置文案"
            )
            XCTAssertFalse(
                sections[1].body.contains("分支复制"),
                "\(nonMac.rawValue) 平台说明不应写死分支恢复动作，应统一由实时状态段给出"
            )
            XCTAssertFalse(
                sections[1].body.contains("重试"),
                "\(nonMac.rawValue) 平台说明不应写死重试恢复动作，应统一由实时状态段给出"
            )
        }

        let unknownSections = WriterConflictSharedGuideSheet.sections(
            sourceIsRunning: false,
            availability: .available(lastTurnID: nil),
            hostPlatform: .unknown
        )
        XCTAssertEqual(unknownSections.map(\.id), ["why", "unknownPlatform", "now"])
        XCTAssertEqual(unknownSections[1].title, L10n.text("ui.writer_conflict_shared_guide_non_mac_title"))
        XCTAssertFalse(
            unknownSections[1].body.contains("让 Codex 桌面版和手机同时使用…"),
            "缺少平台元数据的旧档案不应默认展示 Mac 专用配置入口"
        )
        XCTAssertFalse(
            unknownSections[1].body.contains("打开共享设置"),
            "缺少平台元数据的旧档案不应默认展示 Mac 专用配置步骤"
        )
        XCTAssertFalse(
            unknownSections[1].body.contains("当前连接的电脑不是 Mac"),
            "缺少平台元数据时的中性提示不应武断宣称主机不是 Mac"
        )
    }

    func testWriterConflictCardHitTargetsAndSharedGuideAccessibilityLabel() async throws {
        let suiteName = "WriterConflictCardHitTargets.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)
        let bridge = WriterConflictInteractionBridge()

        let card = WriterConflictCard(
            sourceIsRunning: false,
            availability: .available(lastTurnID: nil),
            errorMessage: nil,
            isDuplicating: false,
            isRetrying: false,
            onFork: {},
            onRecheck: {},
            onRetry: {}
        )
        .environmentObject(themeStore)
        .environment(\.writerConflictInteractionBridge, bridge)
        .padding(16)
        .frame(width: 390, alignment: .top)

        let hosted = try makeTestWindow(rootView: card, size: CGSize(width: 390, height: 320))
        defer { hosted.tearDown() }

        let requiredIdentifiers = [
            WriterConflictCard.sharedGuideAccessibility.identifier,
            "writerConflict.retryButton",
            "writerConflict.primaryButton"
        ]
        try await waitUntil(
            description: "冲突卡按钮完成真实布局尺寸上报",
            window: hosted.window
        ) {
            requiredIdentifiers.allSatisfy { bridge.buttonSizes[$0] != nil }
        }

        for identifier in requiredIdentifiers {
            let size = try XCTUnwrap(bridge.buttonSizes[identifier], "缺少按钮命中区尺寸：\(identifier)")
            XCTAssertGreaterThanOrEqual(size.width, 43.5, "\(identifier) 宽度不足 44pt: \(size)")
            XCTAssertGreaterThanOrEqual(size.height, 43.5, "\(identifier) 高度不足 44pt: \(size)")
        }

        let sharedGuideA11y = WriterConflictCard.sharedGuideAccessibility
        XCTAssertEqual(
            sharedGuideA11y.label,
            sharedGuideA11y.visibleTitle,
            "共享入口无障碍名称必须与可见标签一致"
        )
        XCTAssertEqual(
            sharedGuideA11y.label,
            L10n.text("ui.writer_conflict_shared_guide_link"),
            "共享入口无障碍名称必须与可见标签一致"
        )
        XCTAssertEqual(
            sharedGuideA11y.hint,
            L10n.text("ui.writer_conflict_shared_guide_title"),
            "共享入口无障碍提示应保留完整引导标题说明"
        )

        let cardSource = try writerConflictCardSource()
        XCTAssertTrue(
            cardSource.contains(".accessibilityLabel(accessibility.label)"),
            "WriterConflictCard 必须将共享入口无障碍名称绑定到 sharedGuideAccessibility.label"
        )
        XCTAssertTrue(
            cardSource.contains(".accessibilityHint(accessibility.hint)"),
            "WriterConflictCard 必须将共享入口无障碍提示绑定到 sharedGuideAccessibility.hint"
        )

        // 当运行环境（如 iOS 27+ 或开启系统辅助功能时）暴露实时 SwiftUI 无障碍节点时，顺带复核节点帧与标签。
        if let guideButton = findAccessibilityObject(
            identifier: sharedGuideA11y.identifier,
            in: hosted.window
        ) {
            XCTAssertEqual(
                guideButton.accessibilityLabel,
                L10n.text("ui.writer_conflict_shared_guide_link"),
                "共享入口无障碍名称必须与可见标签一致"
            )
            XCTAssertGreaterThanOrEqual(guideButton.accessibilityFrame.width, 43.5)
            XCTAssertGreaterThanOrEqual(guideButton.accessibilityFrame.height, 43.5)
        }
    }

    func testSharedGuideSheetSupportsDynamicTypeAndHeaderTraits() async throws {
        let suiteName = "WriterConflictGuideA11y.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)

        let largeHeight = try await measureGuideScrollContentHeight(
            themeStore: themeStore,
            dynamicTypeSize: .large
        )
        let accessibilityHeight = try await measureGuideScrollContentHeight(
            themeStore: themeStore,
            dynamicTypeSize: .accessibility3
        )
        XCTAssertGreaterThan(
            accessibilityHeight,
            largeHeight * 1.35,
            "共享引导在系统大字号下必须随动态字体明显放大（large=\(largeHeight), ax3=\(accessibilityHeight)）"
        )

        let bridge = WriterConflictInteractionBridge()
        let view = WriterConflictSharedGuideSheet(
            sourceIsRunning: true,
            availability: .available(lastTurnID: "turn-1"),
            hostPlatform: .apple
        )
        .environmentObject(themeStore)
        .environment(\.dynamicTypeSize, .accessibility3)
        .environment(\.writerConflictInteractionBridge, bridge)

        let hosted = try makeTestWindow(rootView: view, size: CGSize(width: 320, height: 640))
        defer { hosted.tearDown() }

        let expectedHeaders = [
            L10n.text("ui.writer_conflict_shared_guide_why_title"),
            L10n.text("ui.writer_conflict_shared_guide_mac_title"),
            L10n.text("ui.writer_conflict_shared_guide_now_title")
        ]
        try await waitUntil(
            description: "共享引导页完成挂载并渲染段落标题",
            window: hosted.window
        ) {
            bridge.guideIsMounted && bridge.latestGuideHeaderTitles == expectedHeaders
        }

        let sections = WriterConflictSharedGuideSheet.sections(
            sourceIsRunning: true,
            availability: .available(lastTurnID: "turn-1"),
            hostPlatform: .apple
        )
        XCTAssertEqual(
            sections.filter(\.isAccessibilityHeader).map(\.title),
            expectedHeaders,
            "共享引导段落标题必须具备 VoiceOver 标题语义"
        )
        let cardSource = try writerConflictCardSource()
        XCTAssertTrue(
            cardSource.contains(".accessibilityAddTraits(section.isAccessibilityHeader ? .isHeader : [])"),
            "WriterConflictSharedGuideSheet 必须为段落标题写入 .isHeader 无障碍特征"
        )

        // 若当前模拟器运行时暴露了 SwiftUI 无障碍节点，再校验每个段落标题的实时 UIKit .header 特征。
        let liveObjects = collectAccessibilityObjects(from: hosted.window)
        let liveMatchingLabels = liveObjects.compactMap(\.accessibilityLabel).filter { expectedHeaders.contains($0) }
        if !liveMatchingLabels.isEmpty {
            let liveHeaders = Set(
                liveObjects.compactMap { obj -> String? in
                    guard let label = obj.accessibilityLabel,
                          expectedHeaders.contains(label),
                          obj.accessibilityTraits.contains(.header)
                    else { return nil }
                    return label
                }
            )
            XCTAssertEqual(liveHeaders, Set(expectedHeaders), "共享引导段落标题必须具备 VoiceOver 标题语义")
        }
    }

    func testOpenAndDismissSharedGuideFromConflictCardReturnsToOriginalActions() async throws {
        let suiteName = "WriterConflictGuideRoundTrip.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)
        let bridge = WriterConflictInteractionBridge()

        var retryCount = 0
        var forkCount = 0

        let card = WriterConflictCard(
            sourceIsRunning: false,
            availability: .available(lastTurnID: nil),
            errorMessage: nil,
            isDuplicating: false,
            isRetrying: false,
            onFork: { forkCount += 1 },
            onRecheck: {},
            onRetry: { retryCount += 1 }
        )
        .environmentObject(themeStore)
        .environment(\.writerConflictInteractionBridge, bridge)
        .padding(16)
        .frame(width: 390, alignment: .top)

        let hosted = try makeTestWindow(
            rootView: card,
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.tearDown() }

        try await waitUntil(
            description: "冲突卡完成挂载并就绪",
            window: hosted.window
        ) {
            bridge.cardIsMounted && bridge.openSharedGuide != nil
        }
        bridge.openSharedGuide?()

        let presented = try await waitForPresentedViewController(on: hosted.controller)
        try await waitUntil(
            description: "引导弹层完成挂载并就绪",
            window: hosted.window,
            extraView: presented.view
        ) {
            bridge.guideIsMounted && bridge.dismissSharedGuide != nil
        }

        bridge.dismissSharedGuide?()
        try await waitForPresentedViewControllerDismissal(on: hosted.controller)

        XCTAssertTrue(bridge.cardIsMounted, "关闭引导后原冲突卡必须保持挂载")
        let retryAction = try XCTUnwrap(bridge.retry, "关闭引导后原冲突卡的重试操作必须继续可用")
        let primaryAction = try XCTUnwrap(bridge.primary, "关闭引导后原冲突卡的分支操作必须继续可用")
        retryAction()
        primaryAction()
        XCTAssertEqual(retryCount, 1, "关闭引导后原冲突卡的重试操作必须继续可用")
        XCTAssertEqual(forkCount, 1, "关闭引导后原冲突卡的分支操作必须继续可用")
    }

    func testConflictResolutionWhileSharedGuideSheetIsOpenUpdatesSheetAndDismissesCleanly() async throws {
        let project = makeProject(id: "proj-writer-guide-resolve")
        let source = makeSession(
            id: "source-writer-guide-resolve",
            projectID: project.id,
            title: "Desktop source",
            status: "history",
            source: "codex",
            resumeID: "source-writer-guide-resolve"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [source])
        let appStore = makeIsolatedAppStore()
        appStore.token = "writer-guide-resolve-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        select(source: source, project: project, in: store)
        let originLease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: source.id)

        let suiteName = "WriterConflictGuideResolve.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            store.returnToSessionList()
        }
        let themeStore = ThemeStore(defaults: defaults)
        let bridge = WriterConflictInteractionBridge()

        let view = ConversationView()
            .environmentObject(store)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.writerConflictInteractionBridge, bridge)

        let hosted = try makeTestWindow(
            rootView: view,
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.tearDown() }

        try await waitUntil(
            description: "会话页冲突卡完成挂载并就绪",
            window: hosted.window
        ) {
            bridge.cardIsMounted && bridge.openSharedGuide != nil
        }
        bridge.openSharedGuide?()

        let presented = try await waitForPresentedViewController(on: hosted.controller)
        XCTAssertTrue(store.selectedSessionShowsWriterConflictCard)
        try await waitUntil(
            description: "引导弹层显示冲突态恢复文案",
            window: hosted.window,
            extraView: presented.view
        ) {
            bridge.guideIsMounted
                && bridge.latestGuideNowBody == L10n.text("ui.writer_conflict_shared_guide_now_body")
        }

        // 仅清除冲突标记但尚未建立可写连接时，不能误报已解除锁定。
        store.setActiveWriterConflict(false, sessionID: source.id)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .unavailable)
        let unavailableCopy = L10n.text("ui.writer_conflict_shared_guide_now_unavailable_body")
        try await waitUntil(
            description: "尚未恢复可写连接时引导弹层不误报已解锁",
            window: hosted.window,
            extraView: presented.view
        ) {
            !bridge.cardIsMounted && bridge.latestGuideNowBody == unavailableCopy
        }

        // 同一会话的前台 WebSocket 确认连上后（.live），才切换为已解除锁定说明。
        store.connectWebSocket(source, replayBufferedEvents: false, allowNonRunning: true)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .resolvedWritable)

        // 未带平台元数据的旧档案恢复可写时，使用平台中性的已解锁说明，不默认引导 Mac 配置。
        let resolvedCopy = L10n.text("ui.writer_conflict_shared_guide_now_resolved_non_mac_body")
        try await waitUntil(
            description: "同一会话恢复可写后引导弹层更新为已解锁说明",
            window: hosted.window,
            extraView: presented.view
        ) {
            !bridge.cardIsMounted && bridge.latestGuideNowBody == resolvedCopy
        }
        XCTAssertNotNil(hosted.controller.presentedViewController, "冲突解除不应导致引导弹层异常销毁")
        XCTAssertEqual(bridge.latestGuideNowBody, resolvedCopy, "冲突解除后引导弹层应更新为已解锁说明")

        let dismissAction = try XCTUnwrap(bridge.dismissSharedGuide, "引导弹层完成按钮应保持可关闭")
        dismissAction()
        try await waitForPresentedViewControllerDismissal(on: hosted.controller)
        XCTAssertFalse(bridge.cardIsMounted, "冲突已解除且关闭引导后，冲突卡不应再显示")
        XCTAssertFalse(store.selectedSessionShowsWriterConflictCard)
    }

    func testCredentialInvalidationWhileSharedGuideSheetIsOpenShowsRePairGuidanceInsteadOfUnlocked() async throws {
        let project = makeProject(id: "proj-writer-guide-cred-invalid")
        let source = makeSession(
            id: "source-writer-guide-cred-invalid",
            projectID: project.id,
            title: "Desktop source",
            status: "history",
            source: "codex",
            resumeID: "source-writer-guide-cred-invalid"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [source])
        let appStore = makeIsolatedAppStore()
        appStore.token = "writer-guide-cred-token"
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )
        select(source: source, project: project, in: store)
        let originLease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: source.id)

        let suiteName = "WriterConflictGuideCredInvalid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            store.returnToSessionList()
        }
        let themeStore = ThemeStore(defaults: defaults)
        let bridge = WriterConflictInteractionBridge()

        let view = ConversationView()
            .environmentObject(store)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.writerConflictInteractionBridge, bridge)

        let hosted = try makeTestWindow(
            rootView: view,
            size: CGSize(width: 390, height: 844)
        )
        defer { hosted.tearDown() }

        // 重试重连期间用户打开共享引导弹层。
        store.connectWebSocket(source, replayBufferedEvents: false, allowNonRunning: true)
        let socket = try XCTUnwrap(sockets.first)

        try await waitUntil(
            description: "重连期间会话页冲突卡完成挂载并可打开引导",
            window: hosted.window
        ) {
            bridge.cardIsMounted && bridge.openSharedGuide != nil
        }
        bridge.openSharedGuide?()

        let presented = try await waitForPresentedViewController(on: hosted.controller)
        try await waitUntil(
            description: "引导弹层打开并完成挂载",
            window: hosted.window,
            extraView: presented.view
        ) {
            bridge.guideIsMounted
        }

        // 重连过程中 WebSocket 因凭据失效终止：连接逻辑会清除冲突标记并保留当前会话，
        // 弹层绝不能误报「已解除锁定」，而应显示需要重新配对的恢复提示。
        socket.emitStatus(.terminated(.credentialsInvalid))
        let credInvalidCopy = L10n.text("ui.writer_conflict_shared_guide_now_credentials_invalid_body")
        let unlockedCopy = L10n.text("ui.writer_conflict_shared_guide_now_resolved_body")
        try await waitUntil(
            description: "凭据失效后引导弹层显示重新配对提示而非已解锁",
            window: hosted.window,
            extraView: presented.view
        ) {
            store.connectionTermination == .credentialsInvalid
                && bridge.latestGuideNowBody == credInvalidCopy
        }
        XCTAssertEqual(store.selectedSessionID, source.id)
        XCTAssertFalse(store.selectedSessionShowsWriterConflictCard)
        XCTAssertEqual(
            store.writerConflictSharedGuideStatus(originLease: originLease),
            .connectionTerminated(.credentialsInvalid)
        )
        XCTAssertNotEqual(bridge.latestGuideNowBody, unlockedCopy)

        let dismissAction = try XCTUnwrap(bridge.dismissSharedGuide)
        dismissAction()
        try await waitForPresentedViewControllerDismissal(on: hosted.controller)
    }

    func testRetryingIdleConflictShowsRetryingGuideInsteadOfImmediateFork() async throws {
        let project = makeProject(id: "proj-writer-guide-retrying")
        let source = makeSession(
            id: "source-writer-guide-retrying",
            projectID: project.id,
            title: "Idle conflict source",
            status: "history",
            source: "codex",
            resumeID: "source-writer-guide-retrying"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [source])
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "writer-guide-retrying-token"
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        select(source: source, project: project, in: store)
        let originLease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: source.id)

        let suiteName = "WriterConflictGuideRetrying.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            store.returnToSessionList()
        }
        let themeStore = ThemeStore(defaults: defaults)
        let bridge = WriterConflictInteractionBridge()

        let view = ConversationView()
            .environmentObject(store)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.writerConflictInteractionBridge, bridge)

        let hosted = try makeTestWindow(rootView: view, size: CGSize(width: 390, height: 844))
        defer { hosted.tearDown() }

        try await waitUntil(
            description: "空闲冲突卡完成挂载并可打开引导",
            window: hosted.window
        ) {
            bridge.cardIsMounted && bridge.openSharedGuide != nil
        }

        // 空闲冲突卡点击「重试」后、历史刷新尚未返回时，卡片已禁用分支；
        // 此时打开共享引导必须提示等待重试完成，不能误报可马上分支。
        let retryTask = Task { await store.retrySelectedSessionWriterAccess() }
        await client.waitForHistoryRequestCount(1)

        XCTAssertTrue(store.isRetryingSelectedWriterConflict)
        XCTAssertEqual(store.selectedWriterConflictForkAvailability, .available(lastTurnID: nil))
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .retrying)

        bridge.openSharedGuide?()
        let presented = try await waitForPresentedViewController(on: hosted.controller)
        let retryingCopy = L10n.text("ui.writer_conflict_shared_guide_now_retrying_body")
        let immediateForkCopy = L10n.text("ui.writer_conflict_shared_guide_now_body")
        try await waitUntil(
            description: "重试刷新期间引导弹层显示等待重试文案而非可马上分支",
            window: hosted.window,
            extraView: presented.view
        ) {
            bridge.guideIsMounted && bridge.latestGuideNowBody == retryingCopy
        }
        XCTAssertNotEqual(bridge.latestGuideNowBody, immediateForkCopy)

        client.failHistoryRequest(at: 0, with: MockError.timeout)
        await retryTask.value

        try await waitUntil(
            description: "重试失败结束后引导弹层恢复为空闲可分支文案",
            window: hosted.window,
            extraView: presented.view
        ) {
            !store.isRetryingSelectedWriterConflict && bridge.latestGuideNowBody == immediateForkCopy
        }

        let dismissAction = try XCTUnwrap(bridge.dismissSharedGuide)
        dismissAction()
        try await waitForPresentedViewControllerDismissal(on: hosted.controller)
    }

    func testOfflineWriterConflictShowsOfflineGuideAndRecoversWhenBackOnline() async throws {
        let project = makeProject(id: "proj-writer-guide-offline")
        let source = makeSession(
            id: "source-writer-guide-offline",
            projectID: project.id,
            title: "Offline conflict source",
            status: "history",
            source: "codex",
            resumeID: "source-writer-guide-offline"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [source])
        let appStore = makeIsolatedAppStore()
        appStore.token = "writer-guide-offline-token"
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.219:8787",
            token: "writer-guide-offline-token",
            profileTarget: .newProfile(id: "writer-host-windows", displayName: "Windows PC"),
            installationID: "writer-host-windows-installation",
            hostPlatform: .windows
        ))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        select(source: source, project: project, in: store)
        let originLease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: source.id)

        // 断网后冲突标记仍保留，但复制分支需要远端请求；引导必须提示先恢复网络，且 Windows 主机不显示 Mac 专用步骤。
        store.networkReachabilityStatus = .unsatisfied
        XCTAssertTrue(store.isNetworkUnavailable)
        XCTAssertTrue(store.selectedSessionShowsWriterConflictCard)
        XCTAssertEqual(store.writerConflictSharedGuideStatus(originLease: originLease), .offline)
        XCTAssertEqual(store.activeHostPlatform, .windows)

        let suiteName = "WriterConflictGuideOffline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            store.returnToSessionList()
        }
        let themeStore = ThemeStore(defaults: defaults)
        let bridge = WriterConflictInteractionBridge()

        let view = ConversationView()
            .environmentObject(store)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.writerConflictInteractionBridge, bridge)

        let hosted = try makeTestWindow(rootView: view, size: CGSize(width: 390, height: 844))
        defer { hosted.tearDown() }

        try await waitUntil(
            description: "断网状态冲突卡完成挂载并可打开引导",
            window: hosted.window
        ) {
            bridge.cardIsMounted && bridge.openSharedGuide != nil
        }
        bridge.openSharedGuide?()

        let presented = try await waitForPresentedViewController(on: hosted.controller)
        let offlineCopy = L10n.text("ui.writer_conflict_shared_guide_now_offline_body")
        let immediateForkCopy = L10n.text("ui.writer_conflict_shared_guide_now_body")
        let expectedWindowsHeaders = [
            L10n.text("ui.writer_conflict_shared_guide_why_title"),
            L10n.text("ui.writer_conflict_shared_guide_non_mac_title"),
            L10n.text("ui.writer_conflict_shared_guide_now_title")
        ]
        try await waitUntil(
            description: "断网时引导弹层显示恢复网络提示，且 Windows 主机展示非 Mac 段落标题",
            window: hosted.window,
            extraView: presented.view
        ) {
            bridge.guideIsMounted
                && bridge.latestGuideNowBody == offlineCopy
                && bridge.latestGuideHeaderTitles == expectedWindowsHeaders
        }
        XCTAssertNotEqual(bridge.latestGuideNowBody, immediateForkCopy)

        store.networkReachabilityStatus = .satisfied
        try await waitUntil(
            description: "恢复网络后引导弹层切回冲突可分支文案",
            window: hosted.window,
            extraView: presented.view
        ) {
            bridge.latestGuideNowBody == immediateForkCopy
        }

        let dismissAction = try XCTUnwrap(bridge.dismissSharedGuide)
        dismissAction()
        try await waitForPresentedViewControllerDismissal(on: hosted.controller)
    }

    private struct WriterConflictTestTimeoutError: Error, CustomStringConvertible {
        let description: String
    }

    private struct HostedTestWindow<V: View> {
        let window: UIWindow
        let controller: UIHostingController<V>
        let previousKeyWindow: UIWindow?

        @MainActor
        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }

    private func makeTestWindow<V: View>(
        rootView: V,
        size: CGSize
    ) throws -> HostedTestWindow<V> {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: rootView)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        return HostedTestWindow(
            window: window,
            controller: controller,
            previousKeyWindow: previousKeyWindow
        )
    }

    private func writerConflictCardSource() throws -> String {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        let path = root
            .appendingPathComponent("ios")
            .appendingPathComponent("MimiRemote")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Features")
            .appendingPathComponent("Conversation")
            .appendingPathComponent("WriterConflictCard.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func waitUntil(
        description: String,
        window: UIWindow,
        extraView: UIView? = nil,
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.layoutIfNeeded()
            extraView?.layoutIfNeeded()
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("等待超时：\(description)")
        throw WriterConflictTestTimeoutError(description: description)
    }

    private func measureGuideScrollContentHeight(
        themeStore: ThemeStore,
        dynamicTypeSize: DynamicTypeSize
    ) async throws -> CGFloat {
        let view = WriterConflictSharedGuideSheet(
            sourceIsRunning: true,
            availability: .available(lastTurnID: "turn-1")
        )
        .environmentObject(themeStore)
        .environment(\.dynamicTypeSize, dynamicTypeSize)

        let hosted = try makeTestWindow(rootView: view, size: CGSize(width: 320, height: 640))
        defer { hosted.tearDown() }

        for _ in 0..<40 {
            hosted.window.layoutIfNeeded()
            if let scrollView = findFirstScrollView(in: hosted.window), scrollView.contentSize.height > 100 {
                return scrollView.contentSize.height
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("未能在引导页中找到可测量的 ScrollView")
        return 0
    }

    private func findFirstScrollView(in root: UIView) -> UIScrollView? {
        if let scrollView = root as? UIScrollView {
            return scrollView
        }
        for subview in root.subviews {
            if let found = findFirstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func waitForPresentedViewController(
        on controller: UIViewController,
        timeout: TimeInterval = 5
    ) async throws -> UIViewController {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            controller.view.window?.layoutIfNeeded()
            if let presented = controller.presentedViewController,
               !presented.isBeingPresented,
               presented.transitionCoordinator == nil {
                presented.view.layoutIfNeeded()
                return presented
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("等待引导弹层出现超时")
        throw WriterConflictTestTimeoutError(description: "等待引导弹层出现超时")
    }

    private func waitForPresentedViewControllerDismissal(
        on controller: UIViewController,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            controller.view.window?.layoutIfNeeded()
            if controller.presentedViewController == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("等待引导弹层关闭超时")
        throw WriterConflictTestTimeoutError(description: "等待引导弹层关闭超时")
    }

    private func findAccessibilityObject(identifier: String, in root: UIView) -> NSObject? {
        collectAccessibilityObjects(from: root).first { object in
            accessibilityIdentifier(of: object) == identifier
        }
    }

    private func accessibilityIdentifier(of object: NSObject) -> String? {
        if let identification = object as? UIAccessibilityIdentification,
           let identifier = identification.accessibilityIdentifier,
           !identifier.isEmpty {
            return identifier
        }
        let selector = Selector(("accessibilityIdentifier"))
        if object.responds(to: selector),
           let value = object.perform(selector)?.takeUnretainedValue() as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }

    private func collectAccessibilityObjects(from root: Any) -> [NSObject] {
        var result: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []

        func visit(_ candidate: Any) {
            guard let object = candidate as? NSObject else { return }
            let oid = ObjectIdentifier(object)
            guard visited.insert(oid).inserted else { return }
            result.append(object)

            if let elements = object.accessibilityElements {
                for element in elements {
                    visit(element)
                }
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) {
                        visit(child)
                    }
                }
            }
            if let view = object as? UIView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }

        visit(root)
        return result
    }

    private func select(source: AgentSession, project: AgentProject, in store: SessionStore) {
        store.projects = [project]
        store.sidebarProjects = [project]
        store.sessions = [source]
        store.selectedProjectID = project.id
        store.selectedSessionID = source.id
        store.setActiveWriterConflict(true, sessionID: source.id)
    }

    private func makeFixture(
        sourceStatus: String,
        historyPage: HistoryMessagesPage? = nil,
        forkResult: Result<AgentSession, Error>? = nil
    ) -> WriterConflictForkFixture {
        let project = makeProject(id: "proj-writer-fork")
        let source = makeSession(
            id: "source-thread",
            projectID: project.id,
            title: "Desktop source",
            status: sourceStatus,
            source: "codex",
            resumeID: "source-resume"
        )
        return makeFixture(
            source: source,
            project: project,
            historyPage: historyPage,
            forkResult: forkResult
        )
    }

    private func makeFixture(source: AgentSession) -> WriterConflictForkFixture {
        makeFixture(
            source: source,
            project: makeProject(id: source.projectID),
            historyPage: nil,
            forkResult: nil
        )
    }

    private func makeFixture(
        source: AgentSession,
        project: AgentProject,
        historyPage: HistoryMessagesPage?,
        forkResult: Result<AgentSession, Error>?
    ) -> WriterConflictForkFixture {
        let workspace = AgentWorkspace(project: project)
        let forked = makeSession(
            id: "forked-thread",
            projectID: project.id,
            title: "Forked",
            status: "history",
            source: "codex",
            resumeID: "forked-thread"
        )
        let sourceThreadID = source.resumeID ?? source.id
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: [sourceThreadID: forkResult ?? .success(forked)],
            historyPages: historyPage.map { [sourceThreadID: $0] } ?? [:],
            resolveResults: [project.path: .success(workspace)]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sidebarProjects = [project]
        store.sessions = [source]
        store.selectedProjectID = project.id
        store.selectedSessionID = source.id

        return WriterConflictForkFixture(
            store: store,
            client: client,
            source: source,
            forked: forked,
            workspace: workspace,
            sourceLease: HostSessionLease(
                hostScope: appStore.activeHostScope,
                sessionID: source.id
            )
        )
    }
}

@MainActor
private struct WriterConflictForkFixture {
    let store: SessionStore
    let client: MockSessionStoreClient
    let source: AgentSession
    let forked: AgentSession
    let workspace: AgentWorkspace
    let sourceLease: HostSessionLease
}

private final class WriterConflictWorkspaceResolveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AgentWorkspace, Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func response() async throws -> AgentWorkspace {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = lock.withLock {
                self.continuation = continuation
                let waiters = requestWaiters
                requestWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard self.continuation == nil else { return true }
                requestWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resolve(_ workspace: AgentWorkspace) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: workspace)
    }
}

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
                availability: .available(lastTurnID: "turn-1"),
                conflictResolved: true
            ),
            "ui.writer_conflict_shared_guide_now_resolved_body"
        )
    }

    func testWriterConflictCardHitTargetsAndSharedGuideAccessibilityLabel() async throws {
        let suiteName = "WriterConflictCardHitTargets.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)

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
        .padding(16)
        .frame(width: 390, alignment: .top)

        let (window, _) = try makeTestWindow(rootView: card, size: CGSize(width: 390, height: 320))
        defer { window.isHidden = true }

        let guideButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.sharedGuideButton",
            in: window
        )
        let retryButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.retryButton",
            in: window
        )
        let primaryButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.primaryButton",
            in: window
        )

        for (name, element) in [
            ("sharedGuideButton", guideButton),
            ("retryButton", retryButton),
            ("primaryButton", primaryButton)
        ] {
            let frame = element.accessibilityFrame
            XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(name) 宽度不足 44pt: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(name) 高度不足 44pt: \(frame)")
        }
        XCTAssertEqual(
            guideButton.accessibilityLabel,
            L10n.text("ui.writer_conflict_shared_guide_link"),
            "共享入口无障碍名称必须与可见标签一致"
        )
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

        let view = WriterConflictSharedGuideSheet(
            sourceIsRunning: true,
            availability: .available(lastTurnID: "turn-1")
        )
        .environmentObject(themeStore)
        .environment(\.dynamicTypeSize, .accessibility3)

        let (window, _) = try makeTestWindow(rootView: view, size: CGSize(width: 320, height: 640))
        defer { window.isHidden = true }

        let expectedHeaders = [
            L10n.text("ui.writer_conflict_shared_guide_why_title"),
            L10n.text("ui.writer_conflict_shared_guide_mac_title"),
            L10n.text("ui.writer_conflict_shared_guide_now_title")
        ]
        var foundHeaders: Set<String> = []
        for _ in 0..<40 {
            window.layoutIfNeeded()
            for obj in collectAccessibilityObjects(from: window) {
                guard let label = obj.accessibilityLabel,
                      expectedHeaders.contains(label),
                      obj.accessibilityTraits.contains(.header)
                else { continue }
                foundHeaders.insert(label)
            }
            if foundHeaders.count == expectedHeaders.count {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(foundHeaders, Set(expectedHeaders), "共享引导段落标题必须具备 VoiceOver 标题语义")
    }

    func testOpenAndDismissSharedGuideFromConflictCardReturnsToOriginalActions() async throws {
        let suiteName = "WriterConflictGuideRoundTrip.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)

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
        .padding(16)
        .frame(width: 390, alignment: .top)

        let (window, rootController) = try makeTestWindow(
            rootView: card,
            size: CGSize(width: 390, height: 844)
        )
        defer { window.isHidden = true }

        let guideButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.sharedGuideButton",
            in: window
        )
        XCTAssertTrue(activateAccessibilityObject(guideButton))

        let presented = try await waitForPresentedViewController(on: rootController)
        let doneButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.sharedGuideDoneButton",
            in: presented.view
        )
        XCTAssertTrue(activateAccessibilityObject(doneButton))
        try await waitForPresentedViewControllerDismissal(on: rootController)

        let retryButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.retryButton",
            in: window
        )
        let primaryButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.primaryButton",
            in: window
        )
        XCTAssertTrue(activateAccessibilityObject(retryButton))
        XCTAssertTrue(activateAccessibilityObject(primaryButton))
        XCTAssertEqual(retryCount, 1, "关闭引导后原冲突卡的重试操作必须继续可用")
        XCTAssertEqual(forkCount, 1, "关闭引导后原冲突卡的分支操作必须继续可用")
    }

    func testConflictResolutionWhileSharedGuideSheetIsOpenUpdatesSheetAndDismissesCleanly() async throws {
        let fixture = makeFixture(sourceStatus: "history")
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)
        let suiteName = "WriterConflictGuideResolve.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            fixture.store.returnToSessionList()
        }
        let themeStore = ThemeStore(defaults: defaults)
        let conversationStore = ConversationStore()

        let view = ConversationView()
            .environmentObject(fixture.store)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)

        let (window, rootController) = try makeTestWindow(
            rootView: view,
            size: CGSize(width: 390, height: 844)
        )
        defer { window.isHidden = true }

        let guideButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.sharedGuideButton",
            in: window
        )
        XCTAssertTrue(activateAccessibilityObject(guideButton))

        let presented = try await waitForPresentedViewController(on: rootController)
        XCTAssertTrue(fixture.store.selectedSessionShowsWriterConflictCard)

        // 弹层打开期间冲突解除：冲突卡替换为 ComposerView，挂载在稳定 ConversationView 上的引导弹层保持完好并更新为已解锁提示。
        fixture.store.setActiveWriterConflict(false, sessionID: fixture.source.id)
        XCTAssertFalse(fixture.store.selectedSessionShowsWriterConflictCard)

        let resolvedCopy = L10n.text("ui.writer_conflict_shared_guide_now_resolved_body")
        var sawResolvedCopy = false
        for _ in 0..<40 {
            window.layoutIfNeeded()
            presented.view.layoutIfNeeded()
            if collectAccessibilityObjects(from: presented.view).contains(where: { $0.accessibilityLabel == resolvedCopy }) {
                sawResolvedCopy = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(rootController.presentedViewController, "冲突解除不应导致引导弹层异常销毁")
        XCTAssertTrue(sawResolvedCopy, "冲突解除后引导弹层应更新为已解锁说明")

        let doneButton = try await waitForAccessibilityObject(
            identifier: "writerConflict.sharedGuideDoneButton",
            in: presented.view
        )
        XCTAssertTrue(activateAccessibilityObject(doneButton))
        try await waitForPresentedViewControllerDismissal(on: rootController)
        XCTAssertNil(
            findAccessibilityObject(identifier: "writerConflict.sharedGuideButton", in: window),
            "冲突已解除且关闭引导后，冲突卡不应再显示"
        )
    }

    private func makeTestWindow<V: View>(
        rootView: V,
        size: CGSize
    ) throws -> (UIWindow, UIHostingController<V>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: rootView)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        return (window, controller)
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

        let (window, _) = try makeTestWindow(rootView: view, size: CGSize(width: 320, height: 640))
        defer { window.isHidden = true }

        for _ in 0..<40 {
            window.layoutIfNeeded()
            if let scrollView = findFirstScrollView(in: window), scrollView.contentSize.height > 100 {
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
        throw CancellationError()
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
    }

    private func waitForAccessibilityObject(
        identifier: String,
        in root: UIView,
        timeout: TimeInterval = 5
    ) async throws -> NSObject {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            root.window?.layoutIfNeeded()
            root.layoutIfNeeded()
            if let found = findAccessibilityObject(identifier: identifier, in: root) {
                return found
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("未找到无障碍元素：\(identifier)")
        throw CancellationError()
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

            if let view = object as? UIView {
                if let elements = view.accessibilityElements {
                    for element in elements {
                        visit(element)
                    }
                }
                let count = view.accessibilityElementCount()
                if count != NSNotFound && count > 0 {
                    for index in 0..<count {
                        if let child = view.accessibilityElement(at: index) {
                            visit(child)
                        }
                    }
                }
                for subview in view.subviews {
                    visit(subview)
                }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound && count > 0 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) {
                            visit(child)
                        }
                    }
                }
            }
        }

        visit(root)
        return result
    }

    private func activateAccessibilityObject(_ object: NSObject) -> Bool {
        if let control = object as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }
        return object.accessibilityActivate()
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

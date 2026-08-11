import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testBootstrapRetriesUntilProjectsLoadAfterTransientFailures() async {
        let project = makeProject(id: "proj_1")
        let session = makeSession(id: "codex_1", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = FlakyBootstrapClient(failuresBeforeSuccess: 2, projects: [project], sessions: [session])
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token" // 让 isConfigured 为真，否则 bootstrap 直接返回。
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.bootstrap()

        XCTAssertEqual(client.projectsCallCount, 3) // 失败 2 次 + 成功 1 次
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertNil(store.errorMessage)
    }

    func testRefreshAfterConnectionCommitRetriesUntilProjectsLoad() async {
        let project = makeProject(id: "proj_pairing_projects_recovery")
        let client = FlakyBootstrapClient(
            failuresBeforeSuccess: 2,
            projects: [project],
            sessions: []
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "committed-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionListSleep: { _ in }
        )

        let didLoad = await store.refreshAfterConnectionCommit(maxWait: 45)

        XCTAssertTrue(didLoad)
        XCTAssertEqual(client.projectsCallCount, 3)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertNil(store.errorMessage)
    }

    func testRefreshAfterConnectionCommitRetriesUntilGatewaySessionsLoad() async {
        let project = makeProject(id: "proj_pairing_gateway_recovery")
        let session = makeSession(
            id: "thread_pairing_gateway_recovery",
            projectID: project.id,
            title: "首配恢复",
            status: "history",
            source: "codex"
        )
        let client = FlakyBootstrapClient(
            failuresBeforeSuccess: 0,
            sessionFailuresBeforeSuccess: 2,
            projects: [project],
            sessions: [session]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "committed-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            sessionListSleep: { _ in }
        )

        let didLoad = await store.refreshAfterConnectionCommit(maxWait: 45)

        XCTAssertTrue(didLoad)
        XCTAssertEqual(client.sessionsCallCount, 3)
        XCTAssertEqual(store.filteredSessions.map(\.id), [session.id])
        XCTAssertNil(store.errorMessage)
    }

    func testRefreshAfterConnectionCommitTimeoutKeepsCommittedCredentials() async throws {
        let suiteName = "ConversationDataFlowTests.PairingRefreshTimeout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TestKeychainOperations()
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let client = FlakyBootstrapClient(
            failuresBeforeSuccess: 1,
            projects: [],
            sessions: []
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionListSleep: { _ in }
        )
        let endpoint = "http://100.64.0.88:8787"
        let token = "committed-after-pairing"
        let didCommit = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: endpoint,
            token: token
        ))
        XCTAssertTrue(didCommit)

        let didLoad = await store.refreshAfterConnectionCommit(maxWait: 0)

        XCTAssertFalse(didLoad)
        XCTAssertEqual(client.projectsCallCount, 1)
        XCTAssertEqual(appStore.endpoint, endpoint)
        XCTAssertEqual(appStore.token, token)
        XCTAssertTrue(appStore.isConfigured)
        XCTAssertEqual(appStore.lastError, L10n.text("ui.the_connection_credentials_have_been_saved_safely_but"))
        XCTAssertEqual(store.errorMessage, appStore.lastError)

        // 重建 AppStore 验证凭据仍在持久化档案和 Keychain 中，而不是只留在当前内存。
        let reloaded = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        XCTAssertEqual(reloaded.endpoint, endpoint)
        XCTAssertEqual(reloaded.token, token)
        XCTAssertTrue(reloaded.isConfigured)

        // 设置页 preflight 恢复健康后会再次进入同一短恢复入口；下一次成功必须清掉首配错误。
        let retryDidLoad = await store.refreshAfterConnectionCommit(maxWait: 10)
        XCTAssertTrue(retryDidLoad)
        XCTAssertEqual(client.projectsCallCount, 2)
        XCTAssertNil(store.errorMessage)
    }

    func testBootstrapStopsImmediatelyWhenCredentialsAreRejected() async {
        let client = CredentialRejectingBootstrapClient(status: 401)
        let appStore = makeIsolatedAppStore()
        appStore.token = "expired-token"
        var requestedSleeps: [UInt64] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionListSleep: { requestedSleeps.append($0) }
        )

        await store.bootstrap()

        XCTAssertEqual(client.projectsCallCount, 1, "确定性的鉴权失败不能进入 45 秒冷启动轮询")
        XCTAssertTrue(requestedSleeps.isEmpty)
        XCTAssertEqual(store.connectionTermination, .credentialsInvalid)
        XCTAssertEqual(store.webSocketStatus, .terminated(.credentialsInvalid))
        XCTAssertTrue(appStore.requiresRePairing)
        XCTAssertEqual(store.errorMessage, ConnectionTerminationStatus.credentialsInvalid.message)
    }

    func testStaleCredentialRejectionAfterForegroundRestoreDoesNotTerminateConnection() async {
        let staleToken = ""
        let activeToken = "restored-token"
        let client = CredentialRejectingBootstrapClient(
            status: 401,
            credentialFingerprint: connectionCredentialFingerprint(staleToken)
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = activeToken
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll()

        XCTAssertEqual(client.projectsCallCount, 1)
        XCTAssertNil(store.connectionTermination)
        XCTAssertFalse(appStore.requiresRePairing)
        XCTAssertNotEqual(store.webSocketStatus, .terminated(.credentialsInvalid))
    }

    func testWebSocketClientPublishesCredentialTerminalStatusForHandshakeRejection() async throws {
        let project = makeProject(id: "proj_ws_auth_rejected")

        for status in [401, 403] {
            let runtime = CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "expired-token",
                transportFactory: { CredentialRejectingCodexAppServerTransport(status: status) },
                configProvider: { makeDirectAppServerConfig(project: project) }
            )
            let socket = CodexAppServerSessionWebSocketClient(runtime: runtime)
            var statuses: [WebSocketStatus] = []
            socket.onStatus = { statuses.append($0) }

            socket.connect(sessionID: "thread_auth_\(status)")
            try await waitForStatus(.terminated(.credentialsInvalid), in: { statuses })

            XCTAssertEqual(statuses.first, .connecting)
            XCTAssertTrue(statuses.contains(.terminated(.credentialsInvalid)))
            XCTAssertFalse(statuses.contains { value in
                if case .failed = value { return true }
                return false
            })
            socket.disconnect()
        }
    }

    func testCredentialTerminalStatusStopsReconnectAndPreservesLocalSessionState() async throws {
        let project = makeProject(id: "proj_ws_auth_terminal")
        let running = makeSession(
            id: "sess_ws_auth_terminal",
            projectID: project.id,
            title: "保留中的会话",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "expired-token"
        let conversationStore = ConversationStore()
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
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
            },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        conversationStore.appendSystem("访问码失效前已经保存在本地的消息", sessionID: running.id)
        let messagesBeforeTermination = conversationStore.messages(for: running.id)

        socket.emitStatus(.terminated(.credentialsInvalid))
        try await waitForWebSocketStatus(.terminated(.credentialsInvalid), store: store)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(sockets.count, 1, "访问码失效后不能继续创建 WebSocket 重连")
        XCTAssertEqual(socket.disconnectCallCount, 1)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.sessions.map(\.id), [running.id])
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, running.id)
        XCTAssertEqual(conversationStore.messages(for: running.id), messagesBeforeTermination)
        XCTAssertEqual(store.connectionTermination, .credentialsInvalid)
        XCTAssertTrue(appStore.requiresRePairing)
    }

    func testLateOlderNetworkPathUpdateCannotOverwriteSatisfiedState() async throws {
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let pathSource = TestNetworkPathStatusSource(initialStatus: .unsatisfied)
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: [], messagesResult: []) },
            networkPathStatusSource: pathSource
        )

        // monitor 先观察到离线(1)、再观察到在线(2)，这里只把主线程交付顺序反转，
        // 确定性模拟旧 Task 在新 Task 之后才执行。
        pathSource.deliver(.satisfied, sequence: 2)
        try await waitForNetworkReachability(.satisfied, store: store)
        pathSource.deliver(.unsatisfied, sequence: 1)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.networkReachabilityStatus, .satisfied)
        XCTAssertFalse(store.isNetworkUnavailable)
        XCTAssertNotEqual(store.statusMessage, L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
    }

    func testUnknownToSatisfiedRecoversExistingNetworkErrorExactlyOnce() async throws {
        let project = makeProject(id: "proj_unknown_network_recovery")
        let running = makeSession(
            id: "sess_unknown_network_recovery",
            projectID: project.id,
            title: "首次网络状态恢复",
            status: "history",
            source: "codex"
        )
        let page = SessionsPage(sessions: [running])
        let client = SequencedSessionListClient(
            projects: [project],
            results: [
                .success(page),
                .failure(CodexAppServerSessionRuntimeError.gatewayUnavailable),
                .success(page)
            ]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let pathSource = TestNetworkPathStatusSource(initialStatus: .unknown)
        var now = Date(timeIntervalSince1970: 0)
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: now)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            networkPathStatusSource: pathSource,
            sessionListNow: { now }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        now = Date(timeIntervalSince1970: 10) // 让下一次请求绕过 2 秒首屏短缓存。
        await store.refreshSelectedProjectSessions()
        XCTAssertEqual(client.sessionsPageCallCount, 2)
        XCTAssertNotNil(store.errorMessage)

        pathSource.emit(.satisfied)
        pathSource.emit(.satisfied) // 重复在线事件不能启动第二个恢复任务。
        for _ in 0..<80 where client.sessionsPageCallCount < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.networkReachabilityStatus, .satisfied)
        XCTAssertEqual(client.sessionsPageCallCount, 3)
        XCTAssertNil(store.errorMessage)
    }

    func testOfflineSuspendsReconnectAndPreservesSessionQueueAndMessages() async throws {
        let project = makeProject(id: "proj_network_offline")
        let running = makeSession(
            id: "sess_network_offline",
            projectID: project.id,
            title: "离线保留",
            status: "running",
            source: "codex",
            activeTurnID: "turn_network_active"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let conversationStore = ConversationStore()
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
        let pathSource = TestNetworkPathStatusSource(initialStatus: .satisfied)
        let delayRecorder = ReconnectDelayRecorder()
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
            },
            webSocketReconnectSleep: { delay in await delayRecorder.record(delay) },
            networkPathStatusSource: pathSource
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        let socket = try XCTUnwrap(sockets.first)
        socket.emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let queued = await store.sendTurn(CodexAppServerTurnPayload(prompt: "网络恢复后仍等待当前 Turn 完成"))
        XCTAssertTrue(queued)
        conversationStore.appendSystem("离线前本地消息", sessionID: running.id)
        let messagesBeforeOffline = conversationStore.messages(for: running.id)

        pathSource.emit(.unsatisfied)
        try await waitForNetworkReachability(.unsatisfied, store: store)
        try await waitForWebSocketStatus(.disconnected, store: store)
        socket.emitStatus(.failed("late network callback"))
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(socket.disconnectCallCount, 1)
        let offlineDelays = await delayRecorder.snapshot()
        XCTAssertEqual(offlineDelays, [], "离线后不能继续安排 WebSocket 退避")
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.sessions.map(\.id), [running.id])
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, running.id)
        XCTAssertEqual(conversationStore.messages(for: running.id), messagesBeforeOffline)
        XCTAssertNil(conversationStore.messages(for: running.id).first { $0.content == "网络恢复后仍等待当前 Turn 完成" })
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["网络恢复后仍等待当前 Turn 完成"])
        XCTAssertEqual(store.statusMessage, L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
    }

    func testNetworkRecoveryReconnectsExactlyOnce() async throws {
        let project = makeProject(id: "proj_network_recovery")
        let running = makeSession(
            id: "sess_network_recovery",
            projectID: project.id,
            title: "恢复一次",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let pathSource = TestNetworkPathStatusSource(initialStatus: .satisfied)
        let client = MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: [])
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
            },
            networkPathStatusSource: pathSource
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        pathSource.emit(.unsatisfied)
        try await waitForNetworkReachability(.unsatisfied, store: store)
        pathSource.emit(.satisfied)
        pathSource.emit(.satisfied) // NWPathMonitor 可能重复报告同一状态，恢复逻辑必须去重。
        try await waitForNetworkReachability(.satisfied, store: store)
        for _ in 0..<80 where sockets.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets[1].connectedSessionIDs, [running.id])
    }

    func testCredentialTerminalStateDoesNotRecoverWhenNetworkReturns() async throws {
        let project = makeProject(id: "proj_auth_before_network_recovery")
        let running = makeSession(
            id: "sess_auth_before_network_recovery",
            projectID: project.id,
            title: "认证终态",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "expired-token"
        let pathSource = TestNetworkPathStatusSource(initialStatus: .satisfied)
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            networkPathStatusSource: pathSource
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitStatus(.terminated(.credentialsInvalid))
        try await waitForWebSocketStatus(.terminated(.credentialsInvalid), store: store)

        pathSource.emit(.unsatisfied)
        pathSource.emit(.satisfied)
        try await waitForNetworkReachability(.satisfied, store: store)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(store.webSocketStatus, .terminated(.credentialsInvalid))
        XCTAssertEqual(store.connectionTermination, .credentialsInvalid)
        XCTAssertTrue(appStore.requiresRePairing)
    }

    func testTransientReconnectUsesExponentialJitterAndMaximumDelay() async throws {
        let project = makeProject(id: "proj_reconnect_jitter")
        let running = makeSession(
            id: "sess_reconnect_jitter",
            projectID: project.id,
            title: "退避",
            status: "running",
            source: "codex"
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let delayRecorder = ReconnectDelayRecorder()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            },
            webSocketReconnectRandom: { 1.0 },
            webSocketReconnectSleep: { delay in await delayRecorder.record(delay) },
            networkPathStatusSource: TestNetworkPathStatusSource(initialStatus: .satisfied)
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        for attempt in 0..<6 {
            sockets[attempt].emitStatus(.failed("transient \(attempt)"))
            for _ in 0..<100 where sockets.count < attempt + 2 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(sockets.count, attempt + 2)
        }

        let recordedDelays = await delayRecorder.snapshot()
        XCTAssertEqual(
            recordedDelays,
            [1_200_000_000, 2_400_000_000, 4_800_000_000, 9_600_000_000, 19_200_000_000, 30_000_000_000]
        )
    }

    func testBootstrapRetriesUntilSessionsLoadWhenGatewayStartsLate() async {
        let project = makeProject(id: "proj_late_gateway")
        let session = makeSession(id: "codex_late", projectID: project.id, title: "首启恢复", status: "history", source: "codex", resumeID: "history")
        // projects 立刻可用（agentd HTTP 已就绪），但 app-server gateway 上游晚 2 次才接受连接，
        // sessions 前两次抛错。冷启动 bootstrap 必须继续重试，而不能一拿到 projects 就收手。
        let client = FlakyBootstrapClient(
            failuresBeforeSuccess: 0,
            sessionFailuresBeforeSuccess: 2,
            projects: [project],
            sessions: [session]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )

        await store.bootstrap()

        XCTAssertEqual(client.sessionsCallCount, 3) // 会话失败 2 次 + 成功 1 次
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [session.id])
        XCTAssertNil(store.errorMessage)
    }

    func testBootstrapDoesNotRetryWhenBackendHasNoProjects() async {
        let client = FlakyBootstrapClient(failuresBeforeSuccess: 0, projects: [], sessions: [])
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.bootstrap()

        // 成功但后端确实没有项目时不应空转重试。
        XCTAssertEqual(client.projectsCallCount, 1)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testConcurrentSelectedProjectRefreshesShareOneListRequest() async throws {
        let project = makeProject(id: "proj_coalesced_list")
        let session = makeSession(id: "thread_coalesced_list", projectID: project.id, title: "合并列表", status: "history", source: "codex")
        let client = BlockingSessionListRefreshClient(projects: [project], page: SessionsPage(sessions: [session]))
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        let first = Task { await store.refreshSelectedProjectSessions(showLoading: true) }
        let second = Task { await store.refreshSelectedProjectSessions(showLoading: true) }
        await client.waitForBlockedSessionListRefresh()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.sessionsPageCallCount, 2, "bootstrap 后的两个并发刷新必须共享一个上游 thread/list")
        client.releaseBlockedSessionListRefresh()
        await first.value
        await second.value
    }

    func testRefreshAllAndSelectedProjectRefreshShareOneListRequest() async throws {
        let project = makeProject(id: "proj_cross_refresh_list")
        let session = makeSession(
            id: "thread_cross_refresh_list",
            projectID: project.id,
            title: "跨入口合并列表",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [session]),
            blockOnCall: 1
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        let refreshAll = Task { await store.refreshAll(autoAttach: false) }
        await client.waitForBlockedSessionListRefresh()
        let selectedRefresh = Task { await store.refreshSelectedProjectSessions(showLoading: false) }
        try await Task.sleep(nanoseconds: 50_000_000)

        // refreshAll 与列表轮询共用同一个 thread/list；否则 gateway 会把后发请求拒绝为 -32080。
        XCTAssertEqual(client.sessionsPageCallCount, 1)
        client.releaseBlockedSessionListRefresh()
        await refreshAll.value
        await selectedRefresh.value
        XCTAssertNil(store.errorMessage)
    }

    func testRefreshAllLateResponseDoesNotReplaceNewSelectionInSameProject() async {
        let project = makeProject(id: "proj_refresh_selection_lease")
        let first = makeSession(
            id: "thread_refresh_first",
            projectID: project.id,
            title: "A",
            status: "history",
            source: "codex"
        )
        let second = makeSession(
            id: "thread_refresh_second",
            projectID: project.id,
            title: "B",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [first, second])
        )
        let socket = MockWebSocketClient()
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket }
        )
        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(first)

        let refreshTask = Task { await store.refreshAll(autoAttach: true) }
        await client.waitForBlockedSessionListRefresh()
        await store.selectSession(second)
        client.releaseBlockedSessionListRefresh()
        await refreshTask.value

        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.connectedSessionID, second.id)
        XCTAssertEqual(socket.connectedSessionIDs.last, second.id)
    }

    func testRefreshAllLateResponseMergesOldProjectWithoutReplacingNewProjectSelection() async {
        let firstProject = makeProject(id: "proj_refresh_old")
        let secondProject = makeProject(id: "proj_refresh_new")
        let first = makeSession(
            id: "thread_refresh_old",
            projectID: firstProject.id,
            title: "A",
            status: "history",
            source: "codex"
        )
        let second = makeSession(
            id: "thread_refresh_new",
            projectID: secondProject.id,
            title: "B",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [firstProject, secondProject],
            page: SessionsPage(sessions: [first])
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )
        store.selectedProjectID = firstProject.id
        await store.refreshAll(autoAttach: false)
        _ = store.ensureWorkspace(for: secondProject)
        store.upsert(second)
        await store.selectSession(first)

        let refreshTask = Task { await store.refreshAll(autoAttach: true) }
        await client.waitForBlockedSessionListRefresh()
        await store.selectSession(second)
        client.releaseBlockedSessionListRefresh()
        await refreshTask.value

        XCTAssertEqual(store.selectedProjectID, secondProject.id)
        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.connectedSessionID, second.id)
        XCTAssertTrue(store.sessions.contains { $0.id == first.id })
    }

    func testForegroundResumeLateRefreshKeepsUserSelectionAndSocket() async {
        let project = makeProject(id: "proj_foreground_selection_lease")
        let first = makeSession(
            id: "thread_foreground_first",
            projectID: project.id,
            title: "A",
            status: "history",
            source: "codex"
        )
        let second = makeSession(
            id: "thread_foreground_second",
            projectID: project.id,
            title: "B",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [first, second])
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let socket = MockWebSocketClient()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket }
        )
        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(first)
        store.suspendForBackground()

        let resumeTask = Task { await store.resumeFromForeground() }
        await client.waitForBlockedSessionListRefresh()
        await store.selectSession(second)
        client.releaseBlockedSessionListRefresh()
        await resumeTask.value

        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.connectedSessionID, second.id)
        XCTAssertEqual(socket.connectedSessionIDs.last, second.id)
    }

    func testBootstrapHonorsThreadListRetryAfterBeforeRetrying() async {
        let project = makeProject(id: "proj_list_retry_after")
        let session = makeSession(id: "thread_list_retry_after", projectID: project.id, title: "限流恢复", status: "history", source: "codex")
        let client = SequencedSessionListClient(
            projects: [project],
            results: [
                .failure(sessionListPolicyError(retryAfterMs: 15_000)),
                .success(SessionsPage(sessions: [session]))
            ]
        )
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        var now = Date(timeIntervalSince1970: 1_780_000_000)
        var requestedSleeps: [UInt64] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            sessionListNow: { now },
            sessionListSleep: { nanoseconds in
                requestedSleeps.append(nanoseconds)
                now = now.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
            }
        )

        await store.bootstrap()

        XCTAssertEqual(client.sessionsPageCallCount, 2)
        XCTAssertEqual(requestedSleeps, [15_000_000_000])
        XCTAssertEqual(store.filteredSessions.map(\.id), [session.id])
        XCTAssertNil(store.errorMessage)
    }

    func testThreadListRateLimitKeepsExistingSessionsAndSuppressesGlobalError() async {
        let project = makeProject(id: "proj_list_cooldown")
        let existing = makeSession(id: "thread_existing", projectID: project.id, title: "已有会话", status: "history", source: "codex")
        let refreshed = makeSession(id: "thread_refreshed", projectID: project.id, title: "恢复后会话", status: "history", source: "codex")
        let client = SequencedSessionListClient(
            projects: [project],
            results: [
                .success(SessionsPage(sessions: [existing])),
                .failure(sessionListPolicyError(retryAfterMs: 15_000)),
                .success(SessionsPage(sessions: [refreshed]))
            ]
        )
        let appStore = makeIsolatedAppStore()
        var now = Date(timeIntervalSince1970: 1_780_000_000)
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            sessionListNow: { now },
            sessionListSleep: { _ in }
        )
        store.selectedProjectID = project.id

        await store.refreshAll(autoAttach: false)
        await store.refreshSelectedProjectSessions(showLoading: true)

        XCTAssertEqual(store.filteredSessions.map(\.id), [existing.id])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, L10n.plural("ui.session_list_retry_seconds_count", count: 15))
        XCTAssertFalse(store.statusMessage?.contains("itemsView") == true)

        // 冷却窗口内的后台刷新必须复用旧页，不能再撞 gateway。
        await store.refreshSelectedProjectSessions(showLoading: false)
        XCTAssertEqual(client.sessionsPageCallCount, 2)

        now = now.addingTimeInterval(15)
        await store.refreshSelectedProjectSessions(showLoading: true)
        XCTAssertEqual(client.sessionsPageCallCount, 3)
        XCTAssertEqual(store.filteredSessions.map(\.id), [refreshed.id])
        XCTAssertNil(store.errorMessage)
    }

    func testWorkspaceManualRefreshWaitsOutCooldownAndFetchesFreshPage() async throws {
        let project = makeProject(id: "proj_workspace_manual_cooldown")
        let existing = makeSession(id: "thread_workspace_existing", projectID: project.id, title: "旧列表", status: "history", source: "codex")
        let refreshed = makeSession(id: "thread_workspace_refreshed", projectID: project.id, title: "运行中会话", status: "running", source: "codex")
        let client = SequencedSessionListClient(
            projects: [project],
            results: [
                .success(SessionsPage(sessions: [existing])),
                .failure(sessionListPolicyError(retryAfterMs: 15_000)),
                .success(SessionsPage(sessions: [refreshed]))
            ]
        )
        let appStore = makeIsolatedAppStore()
        var now = Date(timeIntervalSince1970: 1_780_000_000)
        var requestedSleeps: [UInt64] = []
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            sessionListNow: { now },
            sessionListSleep: { nanoseconds in
                requestedSleeps.append(nanoseconds)
                now = now.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
            }
        )
        store.selectedProjectID = project.id

        await store.refreshAll(autoAttach: false)
        do {
            try await store.refreshWorkspaceSessions(projectID: project.id)
            XCTFail("第一次手动刷新应记录 gateway 冷却窗口")
        } catch {
            // 预期的 thread/list 短期限流；下一次手动刷新负责等待并真正重试。
        }

        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(requestedSleeps, [15_000_000_000])
        XCTAssertEqual(client.sessionsPageCallCount, 3)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [refreshed.id])
    }

    func testSessionLibrarySkipsSelectedWorkspaceAlreadyLoadedByRefreshAll() async {
        let project = makeProject(id: "proj_library_reuse")
        let session = makeSession(id: "thread_library_reuse", projectID: project.id, title: "已加载", status: "history", source: "codex")
        let client = SequencedSessionListClient(
            projects: [project],
            results: [.success(SessionsPage(sessions: [session]))]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )
        store.selectedProjectID = project.id

        await store.refreshAll(autoAttach: false)
        await store.refreshSessionLibraryIndex()

        XCTAssertEqual(client.sessionsPageCallCount, 1)
        XCTAssertEqual(store.filteredSessions.map(\.id), [session.id])
    }

    func testSessionLibraryGlobalDiscoveryPreservesKnownWorkspaceIdentityWhenSelectedRefreshIsSkipped() async {
        let rootProject = AgentProject(
            id: "proj_library_identity_root",
            name: "proj_library_identity_root",
            path: "/Users/test/code/proj_library_identity_root"
        )
        let workspace = makeChildWorkspace(
            id: "ws_library_identity",
            name: "identity-worktree",
            root: rootProject
        )
        let canonical = AgentSession(
            id: "thread_library_identity_existing",
            projectID: rootProject.id,
            project: rootProject.name,
            dir: workspace.path,
            title: "已加载工作区会话",
            status: "history",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let globalExisting = AgentSession(
            id: canonical.id,
            projectID: rootProject.id,
            project: rootProject.name,
            dir: "/tmp/unknown-root-dir",
            title: canonical.title,
            status: canonical.status,
            source: canonical.source,
            resumeID: canonical.resumeID,
            createdAt: canonical.createdAt,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let globalPathMatched = AgentSession(
            id: "thread_library_identity_by_path",
            projectID: rootProject.id,
            project: rootProject.name,
            dir: workspace.path,
            title: "按目录命中的会话",
            status: "history",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let globalUnknownExternal = AgentSession(
            id: "thread_library_identity_unknown_external",
            projectID: rootProject.id,
            project: rootProject.name,
            dir: "/Users/test/code/another-worktree",
            title: "未知外部工作树",
            status: "history",
            source: "codex",
            resumeID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        let client = MockSessionStoreClient(
            projects: [rootProject],
            sessions: [],
            projectPages: [rootProject.id: SessionsPage(sessions: [canonical])],
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: [globalExisting, globalPathMatched, globalUnknownExternal])
            }
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [workspace],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )
        store.selectedProjectID = workspace.id

        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.sessions(forProjectID: workspace.id).map(\.id), [canonical.id])
        XCTAssertEqual(store.alignSessionToKnownWorkspace(globalPathMatched).projectID, workspace.id)

        await store.refreshSessionLibraryIndex()

        // 当前工作区首屏已有结果，因此精确 workspace 请求被跳过；不能依靠后写的精确页
        // 把全局响应“修正”回来，两个全局结果本身都必须在 merge 前稳定到 workspace.id。
        XCTAssertEqual(client.requestedWorkspaceIDs, [workspace.id])
        XCTAssertEqual(store.recentWorkspaces.map(\.id), [workspace.id])
        XCTAssertEqual(store.sessionsByID[canonical.id]?.projectID, workspace.id)
        XCTAssertEqual(store.sessionsByID[globalPathMatched.id]?.projectID, workspace.id)
        // 没有 recent workspace 或 dir 命中的受控外部 worktree 仍保留 root projectID，
        // 不能因为统一 identity 而误删或伪造工作区归属。
        XCTAssertEqual(store.sessionsByID[globalUnknownExternal.id]?.projectID, rootProject.id)
    }

    func testSessionLibrarySerializesBackgroundWorkspaceRequests() async throws {
        let firstProject = makeProject(id: "proj_library_serial_first")
        let secondProject = makeProject(id: "proj_library_serial_second")
        let client = BlockingSessionListRefreshClient(
            projects: [firstProject, secondProject],
            page: SessionsPage(sessions: []),
            blockOnCall: 1
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [
                    AgentWorkspace(project: firstProject),
                    AgentWorkspace(project: secondProject)
                ],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )
        store.reloadRecentWorkspaces()

        let refreshTask = Task { await store.refreshSessionLibraryIndex() }
        await client.waitForBlockedSessionListRefresh()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(client.sessionsPageCallCount, 1, "第一条后台 thread/list 未完成前不应启动第二条")

        client.releaseBlockedSessionListRefresh()
        for _ in 0..<100 where client.sessionsPageCallCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(client.sessionsPageCallCount, 2)
        client.releaseBlockedSessionListRefresh()
        await refreshTask.value
    }

    func testConcurrentSessionLibraryRefreshesShareControlledGlobalTraversal() async throws {
        let project = makeProject(id: "proj_library_global_singleflight")
        let gate = SessionLibraryGlobalRequestGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { _, _ in
                await gate.blockUntilReleased()
                return SessionsPage(sessions: [])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let first = Task { await store.refreshSessionLibraryIndex() }
        await gate.waitForEntryCount(1)
        let second = Task { await store.refreshSessionLibraryIndex() }
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(
            client.requestedControlledGlobalCursors.count,
            1,
            "两个 View 同时挂载时必须共享同一轮无 cwd thread/list"
        )

        await gate.releaseAll()
        await first.value
        await second.value
        XCTAssertEqual(client.requestedControlledGlobalCursors.count, 1)
    }

    func testAuthoritativeSessionLibraryRefreshRunsAfterSharedFastTraversal() async throws {
        let project = makeProject(id: "proj_library_global_authoritative_upgrade")
        let gate = SessionLibraryGlobalRequestGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { _, _ in
                await gate.blockUntilReleased()
                return SessionsPage(sessions: [])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let fast = Task { await store.refreshSessionLibraryIndex() }
        await gate.waitForEntryCount(1)
        let authoritative = Task {
            await store.refreshSessionLibraryIndex(authoritative: true)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(client.requestedControlledGlobalCursors.count, 1)

        await gate.releaseAll()
        await fast.value
        await authoritative.value
        XCTAssertEqual(
            client.requestedControlledGlobalCursors.count,
            2,
            "权威刷新必须先共享在途弱刷新，再独立执行一轮，不能把弱结果冒充完成"
        )
    }

    func testRecentSessionsUsesLatestActivityAcrossEveryWorkspace() async {
        let projects = (0..<9).map { makeProject(id: "proj_recent_\($0)") }
        let workspaces = projects.enumerated().map { index, project in
            AgentWorkspace(
                project: project,
                lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let projectSessions = Dictionary(uniqueKeysWithValues: projects.enumerated().map { index, project in
            let updatedAt = index == 8 ? 1_000 : 100 + index
            return (
                project.id,
                [makeSession(
                    id: "thread_recent_\(index)",
                    projectID: project.id,
                    title: "最近会话 \(index)",
                    status: "history",
                    source: "codex",
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
                )]
            )
        })
        let client = MockSessionStoreClient(
            projects: projects,
            sessions: [],
            projectSessions: projectSessions
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: workspaces,
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: true)
        await store.refreshSessionLibraryIndex()

        // 第 9 个工作区虽然更早打开，但它的会话活动时间最新，必须排在全局“最近”第一位。
        XCTAssertEqual(
            store.recentSessions.map(\.id),
            (1...8).reversed().map { "thread_recent_\($0)" }
        )
        XCTAssertEqual(Set(client.requestedWorkspaceIDs), Set(projects.map(\.id)))
    }

    func testSidebarKeepsEveryActiveSessionAndLimitsOnlyHistory() async {
        let project = makeProject(id: "proj_sidebar_lifecycle")
        let active = (0..<10).map { index in
            makeSession(
                id: "thread_active_\(index)",
                projectID: project.id,
                title: "进行中 \(index)",
                status: SessionStatus.running.rawValue,
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let history = (0..<10).map { index in
            makeSession(
                id: "thread_history_\(index)",
                projectID: project.id,
                title: "历史 \(index)",
                status: SessionStatus.history.rawValue,
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 + index))
            )
        }
        let client = MockSessionStoreClient(projects: [project], sessions: active + history)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectProject(project)

        // 进行中任务不能因为更新时间较早或超过 8 条而从侧栏消失；只限制历史预览数量。
        XCTAssertEqual(Set(store.activeSessions.map(\.id)), Set(active.map(\.id)))
        XCTAssertEqual(store.activeSessions.count, 10)
        XCTAssertEqual(store.recentHistorySessions.map(\.id), (2...9).reversed().map { "thread_history_\($0)" })
    }

    func testRefreshingGlobalIndexMovesNonSelectedWorkspaceSessionIntoHistory() async {
        let selectedProject = makeProject(id: "proj_selected_refresh")
        let backgroundProject = makeProject(id: "proj_background_refresh")
        let selectedHistory = makeSession(
            id: "selected_history",
            projectID: selectedProject.id,
            title: "当前工作区历史",
            status: SessionStatus.history.rawValue,
            source: "codex"
        )
        let backgroundRunning = makeSession(
            id: "background_running",
            projectID: backgroundProject.id,
            title: "后台任务",
            status: SessionStatus.running.rawValue,
            source: "codex"
        )
        var now = Date(timeIntervalSince1970: 1_000)
        let client = MutableSessionPageClient(
            projects: [selectedProject, backgroundProject],
            page: SessionsPage(sessions: []),
            projectPages: [
                selectedProject.id: SessionsPage(sessions: [selectedHistory]),
                backgroundProject.id: SessionsPage(sessions: [backgroundRunning])
            ]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [
                    AgentWorkspace(project: selectedProject),
                    AgentWorkspace(project: backgroundProject)
                ],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client },
            sessionListNow: { now }
        )

        store.selectedProjectID = selectedProject.id
        await store.refreshAll(autoAttach: false)
        await store.refreshSessionLibraryIndex()
        XCTAssertTrue(store.activeSessions.contains { $0.id == backgroundRunning.id })

        client.projectPages[backgroundProject.id] = SessionsPage(sessions: [
            makeSession(
                id: backgroundRunning.id,
                projectID: backgroundProject.id,
                title: backgroundRunning.title,
                status: SessionStatus.completed.rawValue,
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: 1_001)
            )
        ])
        now = now.addingTimeInterval(3)
        await store.refreshSessionLibraryIndex()

        XCTAssertFalse(store.activeSessions.contains { $0.id == backgroundRunning.id })
        XCTAssertTrue(store.recentHistorySessions.contains { $0.id == backgroundRunning.id })
    }

    func testSessionStoreStartsOnlyValidatedInlineReviewTargets() async {
        let project = makeProject(id: "proj_review")
        let session = makeSession(
            id: "thread_review",
            projectID: project.id,
            title: "发布前检查",
            status: "idle",
            source: "codex",
            runtimeProvider: "codex"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [session])
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project)],
                endpoint: appStore.endpoint
            ),
            clientFactory: { client }
        )

        let startedBaseBranch = await store.startReview(session, target: .baseBranch(" main "))
        XCTAssertTrue(startedBaseBranch)
        XCTAssertEqual(client.requestedSessionReviews, [
            RequestedSessionReview(
                threadID: session.id,
                target: .baseBranch("main"),
                delivery: .inline
            )
        ])

        let startedCompatibilityReview = await store.reviewUncommittedChanges(session)
        XCTAssertTrue(startedCompatibilityReview)
        XCTAssertEqual(client.requestedSessionReviews.last?.target, .uncommittedChanges)
        XCTAssertEqual(client.requestedSessionReviews.last?.delivery, .inline)

        let rejectedEmptyCommit = await store.startReview(session, target: .commit(sha: " \n "))
        let rejectedCustom = await store.startReview(session, target: .custom("绕过安全入口"))
        let running = makeSession(
            id: "thread_running_review",
            projectID: project.id,
            title: "正在运行",
            status: "running",
            source: "codex",
            runtimeProvider: "codex"
        )
        let rejectedRunning = await store.startReview(running, target: .uncommittedChanges)

        XCTAssertFalse(rejectedEmptyCommit)
        XCTAssertFalse(rejectedCustom)
        XCTAssertFalse(rejectedRunning)
        XCTAssertEqual(client.requestedSessionReviews.count, 2)
    }

    func testRecoveryGenerationFailureDoesNotReuseOlderFullSnapshot() async {
        let project = makeProject(id: "proj_recovery_failed_history")
        let session = makeSession(
            id: "thread_recovery_failed_history",
            projectID: project.id,
            title: "恢复历史失败",
            status: SessionStatus.running.rawValue,
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            messagesError: AgentAPIError.server(status: 504, message: "thread/read timeout")
        )
        let conversationStore = ConversationStore()
        conversationStore.replaceHistorySnapshot([
            CodexHistoryMessage(
                role: "assistant",
                content: "旧的完整历史快照",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ], sessionID: session.id)
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        store.historyLoadedQualityBySessionID[session.id] = .full

        let generation = store.beginRecoveryHistoryGeneration()
        let firstResult = await store.reconcileHistoryForRecovery(
            sessionID: session.id,
            generation: generation
        )
        let repeatedResult = await store.reconcileHistoryForRecovery(
            sessionID: session.id,
            generation: generation
        )

        XCTAssertFalse(firstResult)
        XCTAssertFalse(repeatedResult, "本代 thread/read 失败后不能复用旧 full snapshot 冒充成功")
        XCTAssertEqual(client.requestedMessageSessionIDs, [session.id], "同一恢复代次只强制对账一次")
    }

    func testRecoveryEconomyFallbackKeepsFullReplayEnabled() async {
        let project = makeProject(id: "proj_recovery_economy_fallback")
        let session = makeSession(
            id: "thread_recovery_economy_fallback",
            projectID: project.id,
            title: "恢复时完整历史过大",
            status: SessionStatus.running.rawValue,
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [session])
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]

        let generation = store.beginRecoveryHistoryGeneration()
        let recovery = Task {
            await store.reconcileHistoryForRecovery(
                sessionID: session.id,
                generation: generation
            )
        }
        await client.waitForHistoryRequestCount(1)
        client.failHistoryRequest(
            at: 0,
            with: historyPolicyError(reason: "history_response_too_large")
        )
        await client.waitForHistoryRequestCount(2)
        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(
                        id: "economy-only",
                        role: "assistant",
                        content: "缩略结果",
                        createdAt: Date(timeIntervalSince1970: 20)
                    )
                ],
                loadMode: .economy
            )
        )

        let recoveredFullHistory = await recovery.value
        XCTAssertFalse(
            recoveredFullHistory,
            "economy 只用于界面兜底，不能证明 detached 期间的完整内容已对账"
        )
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
    }

    func testRecoveryForceLoadReplacesOlderReuseRecentRequest() async {
        let project = makeProject(id: "proj_recovery_replaces_cached_job")
        let session = makeSession(
            id: "thread_recovery_replaces_cached_job",
            projectID: project.id,
            title: "恢复请求换代",
            status: SessionStatus.running.rawValue,
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [session])
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]

        let olderLoad = Task {
            await store.loadHistory(
                for: session,
                quiet: true,
                loadMode: .full,
                force: false
            )
        }
        await client.waitForHistoryRequestCount(1)

        let generation = store.beginRecoveryHistoryGeneration()
        let recovery = Task {
            await store.reconcileHistoryForRecovery(
                sessionID: session.id,
                generation: generation
            )
        }
        await client.waitForHistoryRequestCount(2)
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .full])

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    id: "new-authoritative",
                    role: "assistant",
                    content: "恢复时的新权威结果",
                    createdAt: Date(timeIntervalSince1970: 30)
                )
            ])
        )
        let recovered = await recovery.value
        XCTAssertTrue(recovered)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    id: "older-cached",
                    role: "assistant",
                    content: "恢复前的旧快照",
                    createdAt: Date(timeIntervalSince1970: 10)
                )
            ])
        )
        let olderLoaded = await olderLoad.value
        XCTAssertTrue(
            olderLoaded,
            "旧 waiter 可复用已完成的新权威快照，但它自己的迟到响应不能覆盖界面"
        )
        XCTAssertEqual(
            conversationStore.messages(for: session.id).map(\.content),
            ["恢复时的新权威结果"]
        )
    }

    func testNewRecoveryGenerationReplacesOlderEconomyFallback() async {
        let project = makeProject(id: "proj_recovery_replaces_old_economy")
        let session = makeSession(
            id: "thread_recovery_replaces_old_economy",
            projectID: project.id,
            title: "恢复代次跨模式换代",
            status: SessionStatus.running.rawValue,
            source: "claude",
            runtimeProvider: "claude"
        )
        let client = OrderedHistoryPageClient(
            projects: [project],
            page: SessionsPage(sessions: [session])
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        store.historyLoadedQualityBySessionID[session.id] = .full

        let olderGeneration = store.beginRecoveryHistoryGeneration()
        let olderEconomy = Task {
            await store.loadHistory(
                for: session,
                quiet: true,
                loadMode: .economy,
                force: true,
                recoveryGeneration: olderGeneration
            )
        }
        await client.waitForHistoryRequestCount(1)

        let currentGeneration = store.beginRecoveryHistoryGeneration()
        let currentRecovery = Task {
            await store.reconcileHistoryForRecovery(
                sessionID: session.id,
                generation: currentGeneration
            )
        }
        await client.waitForHistoryRequestCount(2)
        XCTAssertEqual(client.requestedMessageLoadModes, [.economy, .full])

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(
                    id: "new-full",
                    role: "assistant",
                    content: "新代完整权威历史",
                    createdAt: Date(timeIntervalSince1970: 40)
                )
            ])
        )
        let recoveredCurrentGeneration = await currentRecovery.value
        XCTAssertTrue(recoveredCurrentGeneration)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(
                        id: "old-economy",
                        role: "assistant",
                        content: "旧代缩略历史",
                        createdAt: Date(timeIntervalSince1970: 20)
                    )
                ],
                loadMode: .economy
            )
        )
        _ = await olderEconomy.value
        XCTAssertEqual(
            conversationStore.messages(for: session.id).map(\.content),
            ["新代完整权威历史"]
        )
    }

    func testMultiRuntimeHistoryPreservesEconomyAndFullLoadModes() async throws {
        let project = AgentProject(id: "proj_multi_history_mode", name: "History Mode", path: "/tmp/multi-history-mode")
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: [
                "initialize", "initialized", "thread/list", "thread/start", "thread/read",
                "thread/turns/list", "turn/start", "turn/interrupt"
            ]
        )
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let client = CodexAppServerRuntimeRoutingSessionAPIClient(
            codexRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                transportFactory: { codexTransport },
                configProvider: { config }
            ),
            claudeRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "claude",
                transportFactory: { claudeTransport },
                configProvider: { config }
            )
        )

        let listTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 20) }
        let initialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let list = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        transportResponse(codexTransport, id: list.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "thread_history_mode", cwd: project.path, source: "appServer", updatedAt: 1780493000)
        ], nextCursor: nil))
        _ = try await listTask.value

        let economyTask = Task {
            try await client.messagesPage(sessionID: "thread_history_mode", before: nil, limit: 20, loadMode: .economy)
        }
        let economyRequest = try await waitForFakeAppServerRequest(codexTransport, method: "thread/turns/list", after: 2)
        XCTAssertEqual(economyRequest.params?.objectValue?["itemsView"]?.stringValue, "summary")
        transportResponse(codexTransport, id: economyRequest.id, result: #"{"data":[],"nextCursor":null}"#)
        let economyPage = try await economyTask.value
        XCTAssertEqual(economyPage.loadMode, .economy)

        let fullTask = Task {
            try await client.messagesPage(sessionID: "thread_history_mode", before: nil, limit: 20, loadMode: .full)
        }
        // sentMessages[3] 仍是上一条 economy 请求；full 请求从下一个下标开始等待。
        let fullRequest = try await waitForFakeAppServerRequest(codexTransport, method: "thread/turns/list", after: 4)
        XCTAssertEqual(fullRequest.params?.objectValue?["itemsView"]?.stringValue, "full")
        transportResponse(codexTransport, id: fullRequest.id, result: #"{"data":[],"nextCursor":null}"#)
        let fullPage = try await fullTask.value
        XCTAssertEqual(fullPage.loadMode, .full)
    }

    // 回归：Claude bridge 的 turn/completed 可能先于 turn/start ACK。终态通知必须胜出，
    // 否则迟到 ACK 会复活旧 turn，后续输入只能等到刷新 thread 才能继续。
    func testClaudeTerminalNotificationBeforeTurnStartACKDoesNotReviveCompletedTurn() async throws {
        let project = AgentProject(id: "proj_claude_terminal_ack", name: "Claude Terminal ACK", path: "/tmp/claude-terminal-ack")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            runtimeProvider: "claude",
            transportFactory: { transport },
            turnInterruptRecoveryDelaysNanoseconds: [],
            configProvider: {
                makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let createTask = Task {
            try await client.createSession(CreateSessionRequest(
                projectID: project.id,
                prompt: "快速完成",
                resumeID: "",
                clientMessageID: "client_claude_terminal_1"
            ))
        }

        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-claude-bridge","platformFamily":"macos"}"#
        )

        let threadStart = try await waitForFakeAppServerRequest(transport, method: "thread/start", after: 1)
        transportResponse(
            transport,
            id: threadStart.id,
            result: #"{"thread":{"id":"thr_claude_terminal_ack","sessionId":"thr_claude_terminal_ack","preview":"快速完成","ephemeral":false,"modelProvider":"anthropic","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"idle"},"path":null,"cwd":"/tmp/claude-terminal-ack","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Claude 快速完成","turns":[]}}"#
        )

        let firstTurnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: 2)
        XCTAssertEqual(firstTurnStart.params?.objectValue?["threadId"]?.stringValue, "thr_claude_terminal_ack")

        // bridge 使用嵌套 turn.id，且完成通知先于对应 RPC response 到达。
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_claude_terminal_ack","turn":{"id":"turn_claude_terminal_1","status":"completed"}}}"#)
        transportResponse(
            transport,
            id: firstTurnStart.id,
            result: #"{"turn":{"id":"turn_claude_terminal_1","items":[],"itemsView":{"type":"complete"},"status":"completed","error":null,"startedAt":1780490902,"completedAt":1780490903,"durationMs":1}}"#
        )

        let created = try await createTask.value
        XCTAssertNil(created.session.activeTurnID, "迟到 ACK 不得把已完成 turn 重新写回 activeTurnID")

        // 第一轮已终态后应能立即发起下一轮，无需刷新 thread。
        let messagesBeforeFollowUp = await transport.sentMessages()
        let followUpTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_claude_terminal_ack",
                payload: CodexAppServerTurnPayload(prompt: "继续"),
                clientMessageID: "client_claude_terminal_2"
            )
        }
        let followUpStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: messagesBeforeFollowUp.count
        )
        transportResponse(
            transport,
            id: followUpStart.id,
            result: #"{"turn":{"id":"turn_claude_terminal_2","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490904,"completedAt":null,"durationMs":null}}"#
        )
        let followUpTurnID = try await followUpTask.value
        XCTAssertEqual(followUpTurnID, "turn_claude_terminal_2")

        // 若 ACK 等待期间已经观察到另一轮 turn/started，旧 ACK 同样不能覆盖较新的 active turn。
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_claude_terminal_ack","turnId":"turn_claude_terminal_2"}}"#)
        for _ in 0..<200 {
            let activeTurnID = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
            if activeTurnID == nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 即使 completion 通知丢失，ACK 自身已经是 completed 也必须直接收敛为终态。
        let messagesBeforeTerminalACK = await transport.sentMessages()
        let terminalACKTask = Task {
            try await runtime.startTurnOutcome(
                sessionID: "thr_claude_terminal_ack",
                payload: CodexAppServerTurnPayload(prompt: "ACK 已终态"),
                clientMessageID: "client_claude_terminal_3"
            )
        }
        let terminalACKStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: messagesBeforeTerminalACK.count
        )
        transportResponse(
            transport,
            id: terminalACKStart.id,
            result: #"{"turn":{"id":"turn_claude_terminal_3","items":[],"itemsView":{"type":"complete"},"status":"completed","error":null,"startedAt":1780490905,"completedAt":1780490906,"durationMs":1}}"#
        )
        let terminalACKOutcome = try await terminalACKTask.value
        XCTAssertEqual(
            terminalACKOutcome,
            .terminal(turnID: "turn_claude_terminal_3")
        )
        let activeAfterTerminalACK = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
        XCTAssertNil(activeAfterTerminalACK)

        // pending start 窗口里的无 ID completion 可能是连接重放，不能伪造新 turn 已完成。
        let messagesBeforeUnidentifiedReplay = await transport.sentMessages()
        let unidentifiedReplayTask = Task {
            try await runtime.startTurnOutcome(
                sessionID: "thr_claude_terminal_ack",
                payload: CodexAppServerTurnPayload(prompt: "忽略旧重放"),
                clientMessageID: "client_claude_terminal_4"
            )
        }
        let unidentifiedReplayStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: messagesBeforeUnidentifiedReplay.count
        )
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_claude_terminal_ack"}}"#)
        transportResponse(
            transport,
            id: unidentifiedReplayStart.id,
            result: #"{"turn":{"id":"turn_claude_unidentified_replay","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490907,"completedAt":null,"durationMs":null}}"#
        )
        let unidentifiedReplayOutcome = try await unidentifiedReplayTask.value
        XCTAssertEqual(
            unidentifiedReplayOutcome,
            .active(turnID: "turn_claude_unidentified_replay")
        )
        let activeAfterUnidentifiedReplay = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
        XCTAssertEqual(activeAfterUnidentifiedReplay, "turn_claude_unidentified_replay")
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_claude_terminal_ack","turnId":"turn_claude_unidentified_replay"}}"#)
        for _ in 0..<200 {
            let current = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
            if current == nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let messagesBeforeRacingTurn = await transport.sentMessages()
        let racingTurnTask = Task {
            try await runtime.startTurn(
                sessionID: "thr_claude_terminal_ack",
                payload: CodexAppServerTurnPayload(prompt: "第三轮"),
                clientMessageID: "client_claude_terminal_5"
            )
        }
        let racingTurnStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: messagesBeforeRacingTurn.count
        )
        transport.enqueue(#"{"method":"turn/started","params":{"threadId":"thr_claude_terminal_ack","turn":{"id":"turn_claude_external_new","status":"inProgress"}}}"#)
        transportResponse(
            transport,
            id: racingTurnStart.id,
            result: #"{"turn":{"id":"turn_claude_terminal_5","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490908,"completedAt":null,"durationMs":null}}"#
        )
        let racingTurnID = try await racingTurnTask.value
        XCTAssertNil(racingTurnID, "迟到 ACK 不应向上层暴露可复活旧状态的 turnID")

        // 更旧 turn 的平铺 turnId 完成通知也不能清掉已经开始的新 turn。
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_claude_terminal_ack","turnId":"turn_claude_older"}}"#)
        for _ in 0..<200 {
            let activeTurnID = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
            if activeTurnID == "turn_claude_external_new" {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var activeTurnID = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
        XCTAssertEqual(activeTurnID, "turn_claude_external_new", "旧完成通知不得清掉当前新 turn")

        // 无 turn ID 的旧协议 completion 也不能再猜测并清空当前新 turn。
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_claude_terminal_ack"}}"#)
        try await Task.sleep(nanoseconds: 50_000_000)
        activeTurnID = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
        XCTAssertEqual(activeTurnID, "turn_claude_external_new")

        // thread/closed 是不可继续边界，迟到的 ACK 既不能复活 thread，也不能让 FIFO 自动续发。
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_claude_terminal_ack","turnId":"turn_claude_external_new"}}"#)
        for _ in 0..<200 {
            let current = await runtime.contextsBySessionID["thr_claude_terminal_ack"]?.activeTurnID
            if current == nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let messagesBeforeClosedTurn = await transport.sentMessages()
        let closedTurnTask = Task {
            try await runtime.startTurnOutcome(
                sessionID: "thr_claude_terminal_ack",
                payload: CodexAppServerTurnPayload(prompt: "关闭边界"),
                clientMessageID: "client_claude_terminal_6"
            )
        }
        let closedTurnStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: messagesBeforeClosedTurn.count
        )
        transport.enqueue(#"{"method":"thread/closed","params":{"threadId":"thr_claude_terminal_ack"}}"#)
        transportResponse(
            transport,
            id: closedTurnStart.id,
            result: #"{"turn":{"id":"turn_claude_terminal_6","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490909,"completedAt":null,"durationMs":null}}"#
        )
        let closedTurnOutcome = try await closedTurnTask.value
        XCTAssertEqual(
            closedTurnOutcome,
            .threadClosed(turnID: "turn_claude_terminal_6")
        )
        let closedContext = await runtime.contextsBySessionID["thr_claude_terminal_ack"]
        XCTAssertEqual(closedContext?.session.status, "closed")
        XCTAssertNil(closedContext?.activeTurnID)
    }

    // archive→unarchive 释放 writer 时，agentd 会用结构化 rejected 响应表示“本次 RPC
    // 尚未转发”。resume 可以在 helper 内发送新请求；turn/start 则必须回到外层重新 resume，
    // 避免同一旧 frame 与 executing handoff 重叠。生命周期通知也不能取消 pending resume。
    func testDirectRuntimeRetriesStructuredThreadHandoffForResumeAndTurnStart() async throws {
        let project = AgentProject(id: "proj_thread_handoff_retry", name: "Thread Handoff Retry", path: "/tmp/thread-handoff-retry")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { pool.make() },
            // 两次结构化拒绝（resume、turn/start）共用同一 outer 预算；若 helper 嵌套重试，
            // 下面的请求顺序/次数断言会暴露额外 frame。
            threadHandoffRetryDelaysNanoseconds: [0, 0],
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/list", "thread/read", "thread/resume", "turn/start"]
                )
            }
        )

        let listTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: nil)
        }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        assertInitializeEnablesExperimentalAPI(initialize)
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let threadList = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: threadList.id, result: #"{"data":[{"id":"thr_thread_handoff_retry","sessionId":"thr_thread_handoff_retry","preview":"handoff retry","ephemeral":false,"modelProvider":"openai","createdAt":1780490840,"updatedAt":1780490841,"status":{"type":"idle"},"path":null,"cwd":"/tmp/thread-handoff-retry","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"handoff retry","turns":[]}],"nextCursor":null}"#)
        _ = try await listTask.value

        let enqueueHandoffInProgress: (CodexAppServerRequestID) throws -> Void = { requestID in
            transport.enqueue(#"{"id":\#(try jsonFragment(for: requestID)),"error":{"code":-32000,"message":"thread handoff in progress","data":{"accepted":false,"retryable":true,"reason":"thread_handoff_in_progress"}}}"#)
        }

        let startTask = Task {
            try await runtime.startTurnOutcome(
                sessionID: "thr_thread_handoff_retry",
                payload: CodexAppServerTurnPayload(prompt: "handoff 完成后继续"),
                clientMessageID: "client_thread_handoff_retry"
            )
        }
        let beforeResumeMessages = await transport.sentMessages()
        let firstResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: beforeResumeMessages.count)
        // 第一次拒绝期间真实 handoff 会先把 thread 标成 notLoaded；先注入生命周期通知，
        // 再注入 rejected response，确保 pending resume task 真的经历这段交错。
        transport.enqueue(#"{"method":"thread/status/changed","params":{"threadId":"thr_thread_handoff_retry","status":{"type":"notLoaded"}}}"#)
        try enqueueHandoffInProgress(firstResume.id)
        // 只从首个 resume 之后开始扫描，否则 helper 的第一次请求会被重复匹配。
        let afterFirstResumeMessages = await transport.sentMessages()
        let retryResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: afterFirstResumeMessages.count)
        XCTAssertNotEqual(retryResume.id, firstResume.id)
        transportResponse(transport, id: retryResume.id, result: #"{"thread":{"id":"thr_thread_handoff_retry","sessionId":"thr_thread_handoff_retry","preview":"handoff retry","ephemeral":false,"modelProvider":"openai","createdAt":1780490840,"updatedAt":1780490842,"status":{"type":"idle"},"path":null,"cwd":"/tmp/thread-handoff-retry","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"handoff retry","turns":[]}}"#)

        let beforeTurnMessages = await transport.sentMessages()
        let firstTurnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: beforeTurnMessages.count)
        // turn/start 的旧 frame 也被 handoff 拒绝；先让 thread/closed 到达，再回 rejected，
        // 外层随后必须重新 resume，不能沿用旧 observation/binding。
        transport.enqueue(#"{"method":"thread/closed","params":{"threadId":"thr_thread_handoff_retry"}}"#)
        try enqueueHandoffInProgress(firstTurnStart.id)
        let afterFirstTurnMessages = await transport.sentMessages()
        let finalResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: afterFirstTurnMessages.count)
        XCTAssertNotEqual(finalResume.id, firstResume.id)
        XCTAssertNotEqual(finalResume.id, retryResume.id)
        transportResponse(transport, id: finalResume.id, result: #"{"thread":{"id":"thr_thread_handoff_retry","sessionId":"thr_thread_handoff_retry","preview":"handoff retry","ephemeral":false,"modelProvider":"openai","createdAt":1780490840,"updatedAt":1780490843,"status":{"type":"idle"},"path":null,"cwd":"/tmp/thread-handoff-retry","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"handoff retry","turns":[]}}"#)

        let afterFinalResumeMessages = await transport.sentMessages()
        let finalTurnStart = try await waitForFakeAppServerRequest(transport, method: "turn/start", after: afterFinalResumeMessages.count)
        XCTAssertNotEqual(finalTurnStart.id, firstTurnStart.id)
        transportResponse(transport, id: finalTurnStart.id, result: #"{"turn":{"id":"turn_thread_handoff_retry","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780490843,"completedAt":null,"durationMs":null}}"#)

        let outcome = try await startTask.value
        XCTAssertEqual(outcome, .active(turnID: "turn_thread_handoff_retry"))
        let sentMessages = await transport.sentMessages()
        let sentRequests = sentMessages.compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(sentRequests.map(\.method), ["initialize", "thread/list", "thread/resume", "thread/resume", "turn/start", "thread/resume", "turn/start"])
        XCTAssertEqual(sentRequests.filter { $0.method == "thread/resume" }.count, 3)
        XCTAssertEqual(sentRequests.filter { $0.method == "turn/start" }.count, 2)
    }

    // agentd 收到 turn/completed 后会延迟 archive→unarchive，详情页仍在当前连接时也会
    // 推送 notLoaded。这个通知必须使下一次发送重新 thread/resume，不能沿用旧绑定直接 turn/start。
    func testNotLoadedNotificationClearsResumeBindingBeforeNextTurn() async throws {
        let project = AgentProject(id: "proj_auto_handoff_not_loaded", name: "Auto Handoff", path: "/tmp/auto-handoff-not-loaded")
        let threadID = "thread_auto_handoff_not_loaded"
        let threadJSON = appServerThreadJSON(
            id: threadID,
            cwd: project.path,
            source: "appServer",
            updatedAt: 1780494000
        )
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: [
                "initialize", "initialized", "thread/read", "thread/resume", "turn/start"
            ]
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )

        let connectTask = Task {
            try await runtime.connectForEvents(sessionID: threadID)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: 1)
        transportResponse(transport, id: read.id, result: #"{"thread":\#(threadJSON)}"#)
        let initialResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: initialResume.id, result: #"{"thread":\#(threadJSON)}"#)
        try await connectTask.value
        let didResumeInitially = await runtime.threadsResumedOnConnection.contains(threadID)
        XCTAssertTrue(didResumeInitially)

        // 通过真实 FakeTransport 通知泵注入 agentd 的终态状态变化。
        transport.enqueue(#"{"method":"thread/status/changed","params":{"threadId":"\#(threadID)","status":{"type":"notLoaded"}}}"#)
        for _ in 0..<200 {
            if await runtime.threadsResumedOnConnection.contains(threadID) == false {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didResumeAfterNotLoaded = await runtime.threadsResumedOnConnection.contains(threadID)
        XCTAssertFalse(didResumeAfterNotLoaded)

        let messagesBeforeNextTurn = await transport.sentMessages()
        let nextTurnTask = Task {
            try await runtime.startTurnOutcome(
                sessionID: threadID,
                payload: CodexAppServerTurnPayload(prompt: "自动 handoff 后继续"),
                clientMessageID: "client_auto_handoff_not_loaded"
            )
        }
        let resumedBeforeTurn = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: messagesBeforeNextTurn.count
        )
        XCTAssertEqual(resumedBeforeTurn.params?.objectValue?["threadId"]?.stringValue, threadID)
        transportResponse(transport, id: resumedBeforeTurn.id, result: #"{"thread":\#(threadJSON)}"#)
        let nextTurnStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: messagesBeforeNextTurn.count
        )
        let messagesAfterNextTurn = await transport.sentMessages()
        let nextResumeIndex = try XCTUnwrap(messagesAfterNextTurn.firstIndex { text in
            (try? decodeAppServerRequest(text).method) == "thread/resume"
        })
        let nextTurnIndex = try XCTUnwrap(messagesAfterNextTurn.firstIndex { text in
            (try? decodeAppServerRequest(text).method) == "turn/start"
        })
        XCTAssertLessThan(nextResumeIndex, nextTurnIndex)
        transportResponse(
            transport,
            id: nextTurnStart.id,
            result: #"{"turn":{"id":"turn_auto_handoff_not_loaded","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780494001,"completedAt":null,"durationMs":null}}"#
        )
        let nextTurnOutcome = try await nextTurnTask.value
        XCTAssertEqual(nextTurnOutcome, .active(turnID: "turn_auto_handoff_not_loaded"))
    }

    // handoff coordinator 产生的私有 lifecycle 不能被当成普通 thread/closed：它只清理
    // 当前连接的 resume binding，保留会话/交互状态，并让下一次发送重新走 resume→turn/start。
    func testPrivateThreadHandoffLifecycleOnlyClearsBindingBeforeNextTurn() async throws {
        let project = AgentProject(id: "proj_private_handoff_lifecycle", name: "Private Handoff", path: "/tmp/private-handoff-lifecycle")
        let threadID = "thread_private_handoff_lifecycle"
        let threadJSON = appServerThreadJSON(
            id: threadID,
            cwd: project.path,
            source: "appServer",
            updatedAt: 1780494100
        )
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: [
                "initialize", "initialized", "thread/read", "thread/resume", "turn/start"
            ]
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )

        let connectTask = Task {
            try await runtime.connectForEvents(sessionID: threadID)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read", after: 1)
        transportResponse(transport, id: read.id, result: #"{"thread":\#(threadJSON)}"#)
        let initialResume = try await waitForFakeAppServerRequest(transport, method: "thread/resume", after: 2)
        transportResponse(transport, id: initialResume.id, result: #"{"thread":\#(threadJSON)}"#)
        try await connectTask.value
        let didResumeInitially = await runtime.threadsResumedOnConnection.contains(threadID)
        XCTAssertTrue(didResumeInitially)

        // params 保留原 lifecycle 字段，并由 gateway 追加 originalMethod；Runtime 只消费 threadId。
        transport.enqueue(#"{"method":"_mimi/threadHandoff/lifecycle","params":{"threadId":"\#(threadID)","originalMethod":"thread/closed"}}"#)
        for _ in 0..<200 {
            if await runtime.threadsResumedOnConnection.contains(threadID) == false {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didResumeAfterPrivateLifecycle = await runtime.threadsResumedOnConnection.contains(threadID)
        XCTAssertFalse(didResumeAfterPrivateLifecycle)
        let contextAfterPrivateLifecycle = await runtime.contextsBySessionID[threadID]
        XCTAssertNotEqual(contextAfterPrivateLifecycle?.session.status, "closed")

        let messagesBeforeNextTurn = await transport.sentMessages()
        let nextTurnTask = Task {
            try await runtime.startTurnOutcome(
                sessionID: threadID,
                payload: CodexAppServerTurnPayload(prompt: "私有 handoff 后继续"),
                clientMessageID: "client_private_handoff_lifecycle"
            )
        }
        let resumedBeforeTurn = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: messagesBeforeNextTurn.count
        )
        transportResponse(transport, id: resumedBeforeTurn.id, result: #"{"thread":\#(threadJSON)}"#)
        let nextTurnStart = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/start",
            after: messagesBeforeNextTurn.count
        )
        transportResponse(
            transport,
            id: nextTurnStart.id,
            result: #"{"turn":{"id":"turn_private_handoff_lifecycle","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null,"startedAt":1780494101,"completedAt":null,"durationMs":null}}"#
        )
        let outcome = try await nextTurnTask.value
        XCTAssertEqual(outcome, .active(turnID: "turn_private_handoff_lifecycle"))
        let sentMessages = await transport.sentMessages()
        let sentRequests = sentMessages.compactMap { try? decodeAppServerRequest($0) }
        let methods = sentRequests.map(\.method)
        XCTAssertEqual(methods.suffix(2), ["thread/resume", "turn/start"])
    }

    // MIM-120 根因侧：Claude 常驻 bridge 的回放环里可能还留着上一条连接的响应帧。
    // 只要新连接的请求 id 从 1 重来，旧 model/list 响应就可能兑现新的 thread/list。
    func testRequestIDsNeverRepeatAcrossConnections() async throws {
        let firstTransport = FakeCodexAppServerTransport()
        let firstConnection = CodexAppServerConnection(transport: firstTransport)
        try await connectFakeAppServer(firstConnection, transport: firstTransport)
        let firstTask = Task { try await firstConnection.send(CodexAppServerRequestSpec(method: "thread/list")) }
        let firstRequest = try await waitForFakeAppServerRequest(firstTransport, method: "thread/list")
        await firstConnection.disconnect()
        _ = try? await firstTask.value

        let secondTransport = FakeCodexAppServerTransport()
        let secondConnection = CodexAppServerConnection(transport: secondTransport)
        try await connectFakeAppServer(secondConnection, transport: secondTransport)
        let secondTask = Task { try await secondConnection.send(CodexAppServerRequestSpec(method: "thread/list")) }
        let secondRequest = try await waitForFakeAppServerRequest(secondTransport, method: "thread/list")

        XCTAssertNotEqual(firstRequest.id, secondRequest.id, "重连后的请求 id 不能复用上一条连接的编号")

        // 回放过来的陈旧 model/list 响应带着旧连接的 id，必须无人认领地落地。
        await secondConnection.ingestTextForTesting(
            #"{"id":\#(try jsonFragment(for: firstRequest.id)),"result":{"data":[{"id":"sonnet"}],"nextCursor":null}}"#
        )
        transportResponse(secondTransport, id: secondRequest.id, result: #"{"data":[],"nextCursor":null}"#)

        let page = try await secondTask.value
        XCTAssertEqual(page?.objectValue?["data"]?.arrayValue?.count, 0, "thread/list 只能被自己的响应兑现")
        await secondConnection.disconnect()
    }
}

private actor SessionLibraryGlobalRequestGate {
    private var entryCount = 0
    private var isReleased = false
    private var blockedContinuations: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func blockUntilReleased() async {
        entryCount += 1
        let readyWaiters = entryWaiters.filter { entryCount >= $0.count }
        entryWaiters.removeAll { entryCount >= $0.count }
        readyWaiters.forEach { $0.continuation.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            blockedContinuations.append(continuation)
        }
    }

    func waitForEntryCount(_ count: Int) async {
        guard entryCount < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        isReleased = true
        let continuations = blockedContinuations
        blockedContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

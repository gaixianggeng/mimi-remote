import XCTest
@testable import MimiRemote

@MainActor
final class NewSessionBufferedReplyTests: XCTestCase {
    func testCompletedFirstTurnBeforeAckReplaysAfterNotLoaded() async throws {
        try await verifyFirstReply(status: "notLoaded")
    }

    func testCompletedFirstTurnBeforeAckReplaysAfterIdle() async throws {
        try await verifyFirstReply(status: "idle")
    }

    private func verifyFirstReply(status: String) async throws {
        let project = AgentProject(id: "proj_store_direct", name: "Store Direct", path: "/tmp/store-direct")
        let config = makeDirectAppServerConfig(project: project)
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)
        let suiteName = "ConversationDataFlowTests.StoreDirect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "store-direct",
            displayName: "Store Direct",
            endpoint: "http://127.0.0.1:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("test-token".utf8), account: "agentd-profile.\(profile.id)")
        let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
        let conversationStore = ConversationStore()
        let logStore = LogStore()
        let contextStore = SessionContextStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: logStore,
            contextStore: contextStore,
            clientFactory: { client },
            webSocketFactory: { CodexAppServerSessionWebSocketClient(runtime: runtime) },
            webSocketReconnectDelayNanoseconds: { _ in 1_000_000 }
        )

        store.selectedProjectID = project.id
        let refreshTask = Task { await store.refreshAll(autoAttach: false) }
        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
        let listMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let listRequest = try decodeAppServerRequest(listMessages[2])
        XCTAssertEqual(listRequest.method, "thread/list")
        // 主动刷新先查索引；空页还需普通扫描确认，之后才能进入新会话的 model/list 链路。
        XCTAssertEqual(listRequest.params?.objectValue?["useStateDbOnly"]?.boolValue, true)
        transport.enqueue(#"{"id":\#(try jsonFragment(for: listRequest.id)),"result":{"data":[],"nextCursor":null,"backwardsCursor":null}}"#)
        let verifiedListMessages = try await waitForFakeAppServerMessages(transport, count: 4)
        let verifiedListRequest = try decodeAppServerRequest(verifiedListMessages[3])
        XCTAssertEqual(verifiedListRequest.method, "thread/list")
        XCTAssertEqual(verifiedListRequest.params?.objectValue?["useStateDbOnly"]?.boolValue, false)
        transportResponse(transport, id: verifiedListRequest.id, result: #"{"data":[],"nextCursor":null}"#)
        await refreshTask.value
        XCTAssertEqual(store.selectedProjectID, project.id)

        let sendTask = Task { await store.sendPrompt("帮我验收 direct Store") }
        let threadMessages = try await waitForFakeAppServerMessages(transport, count: 5)
        let modelList = try decodeAppServerRequest(threadMessages[4])
        XCTAssertEqual(modelList.method, "model/list")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: modelList.id)),"result":{"models":[{"id":"gpt-store-default","name":"Store Default","provider":"openai","isDefault":true}]}}"#)

        let threadStartMessages = try await waitForFakeAppServerMessages(transport, count: 6)
        let threadStart = try decodeAppServerRequest(threadStartMessages[5])
        XCTAssertEqual(threadStart.method, "thread/start")
        XCTAssertNil(threadStart.params?.objectValue?["model"]?.stringValue)
        XCTAssertNil(threadStart.params?.objectValue?["modelProvider"])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: threadStart.id)),"result":{"thread":{"id":"thr_store_direct","sessionId":"thr_store_direct","preview":"帮我验收 direct Store","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490101,"status":{"type":"idle"},"path":null,"cwd":"/tmp/store-direct","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"Store 直连","turns":[]}}}"#)

        let turnMessages = try await waitForFakeAppServerMessages(transport, count: 7)
        let turnStart = try decodeAppServerRequest(turnMessages[6])
        XCTAssertEqual(turnStart.method, "turn/start")
        XCTAssertEqual(turnStart.params?.objectValue?["model"]?.stringValue, "gpt-store-default")
        let collaborationMode = try XCTUnwrap(turnStart.params?.objectValue?["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "default")
        XCTAssertEqual(collaborationMode["settings"]?.objectValue?["model"]?.stringValue, "gpt-store-default")
        // 首轮完整回复、终态和空闲状态均先于发送确认，复现快速任务的接入窗口。
        transport.enqueue(#"{"method":"item/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct","item":{"type":"agentMessage","id":"assistant_store","text":"最终回答"}}}"#)
        transport.enqueue(#"{"method":"turn/completed","params":{"threadId":"thr_store_direct","turnId":"turn_store_direct"}}"#)
        transport.enqueue(#"{"method":"thread/status/changed","params":{"threadId":"thr_store_direct","status":{"type":"\#(status)"}}}"#)
        transportResponse(transport, id: turnStart.id, result: #"{"turn":{"id":"turn_store_direct","items":[],"status":"inProgress","error":null}}"#)
        let didSend = await sendTask.value
        XCTAssertTrue(didSend)
        XCTAssertEqual(store.selectedSessionID, "thr_store_direct")
        XCTAssertEqual(store.connectedSessionID, "thr_store_direct", "已完成的首轮仍需接入缓存事件流")
        defer { store.disconnectWebSocket() }
        let messages = try await waitForConversationMessages(in: conversationStore, sessionID: "thr_store_direct") {
            $0.contains { $0.role == .assistant && $0.content == "最终回答" }
                && store.selectedForegroundActivity == nil
        }
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
        XCTAssertNil(store.selectedForegroundActivity, "迟到 ACK 不能留下等待回复状态")
        XCTAssertNil(store.selectedSession?.activeTurnID)
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertFalse(requests.contains { ["thread/read", "thread/turns/list", "thread/resume"].contains($0.method) }, "首轮应直接回放；只读空闲线程不额外获取 writer 或补拉历史")
    }
}

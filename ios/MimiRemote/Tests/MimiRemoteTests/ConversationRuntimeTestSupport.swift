import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

extension XCTestCase {
    /// 为普通单元/UI 测试提供与 App 运行态完全隔离的 AppStore。
    ///
    /// 生产 AppStore 默认读取 UserDefaults.standard 和系统 Keychain；测试不能依赖
    /// 这些跨测试、跨工作区的持久状态。每次调用都创建新的 suite 和内存 Keychain，
    /// 并通过 XCTest teardown 删除 suite，避免测试结束后留下测试专属持久域。
    @MainActor
    func makeIsolatedAppStore() -> AppStore {
        let suiteName = "MimiRemoteTests.AppStore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离测试 UserDefaults suite: \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
    }
}

// 直连 app-server、连接档案与通用 fixture 支持。
// 冷启动重试用的客户端：前 N 次 projects() 抛错模拟隧道未就绪，之后成功返回。
final class CredentialRejectingBootstrapClient: SessionStoreAPIClient {
    private let status: Int
    private let credentialFingerprint: String?
    private(set) var projectsCallCount = 0

    init(status: Int, credentialFingerprint: String? = nil) {
        self.status = status
        self.credentialFingerprint = credentialFingerprint
    }

    func projects() async throws -> [AgentProject] {
        projectsCallCount += 1
        throw AgentAPIError.credentialsInvalid(
            status: status,
            credentialFingerprint: credentialFingerprint
        )
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        throw MockError.unimplemented
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}

final class FlakyBootstrapClient: SessionStoreAPIClient {
    private let failuresBeforeSuccess: Int
    private let sessionFailuresBeforeSuccess: Int
    private let projectsResult: [AgentProject]
    private let sessionsResult: [AgentSession]
    private(set) var projectsCallCount = 0
    private(set) var sessionsCallCount = 0

    init(
        failuresBeforeSuccess: Int,
        sessionFailuresBeforeSuccess: Int = 0,
        projects: [AgentProject],
        sessions: [AgentSession]
    ) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.sessionFailuresBeforeSuccess = sessionFailuresBeforeSuccess
        self.projectsResult = projects
        self.sessionsResult = sessions
    }

    func projects() async throws -> [AgentProject] {
        projectsCallCount += 1
        if projectsCallCount <= failuresBeforeSuccess {
            throw AgentAPIError.server(status: 503, message: "tunnel not ready")
        }
        return projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        sessionsCallCount += 1
        if sessionsCallCount <= sessionFailuresBeforeSuccess {
            // 模拟 agentd HTTP 已就绪、但 app-server gateway 上游还没接受连接的冷启动窗口。
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        return sessionsResult
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}

enum MockError: Error {
    case unimplemented
    case timeout
}

enum FakeCodexAppServerTransportError: LocalizedError {
    case receiveFailed

    var errorDescription: String? {
        "fake app-server receive failed"
    }
}

final class CredentialRejectingCodexAppServerTransport: CodexAppServerTransport {
    private let status: Int

    init(status: Int) {
        self.status = status
    }

    func connect(url: URL, token: String) async throws {
        throw AgentAPIError.credentialsInvalid(status: status)
    }

    func send(_ text: String) async throws {
        throw AgentAPIError.credentialsInvalid(status: status)
    }

    func receive() async throws -> String? {
        throw AgentAPIError.credentialsInvalid(status: status)
    }

    func close() async {}
}

func occurrenceCount(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

final class FakeCodexAppServerTransport: CodexAppServerTransport {
    private let sentStore = FakeCodexAppServerSentStore()
    private let lifecycleStore = FakeCodexAppServerLifecycleStore()
    private var receiveContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var receiveIterator: AsyncThrowingStream<String, Error>.Iterator

    init() {
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> {
            continuation = $0
        }
        self.receiveContinuation = continuation
        self.receiveIterator = stream.makeAsyncIterator()
    }

    func connect(url: URL, token: String) async throws {}

    func send(_ text: String) async throws {
        await sentStore.append(text)
    }

    func receive() async throws -> String? {
        try await receiveIterator.next()
    }

    func close() async {
        await lifecycleStore.recordClose()
        receiveContinuation?.finish()
    }

    func enqueue(_ text: String) {
        receiveContinuation?.yield(text)
    }

    func failReceive(_ error: Error = FakeCodexAppServerTransportError.receiveFailed) {
        receiveContinuation?.finish(throwing: error)
    }

    func sentMessages() async -> [String] {
        await sentStore.snapshot()
    }

    func closeCallCount() async -> Int {
        await lifecycleStore.closeCallCount
    }
}

final class FakeCodexAppServerTransportPool {
    private let lock = NSLock()
    private var transports: [FakeCodexAppServerTransport] = []

    func make() -> CodexAppServerTransport {
        let transport = FakeCodexAppServerTransport()
        lock.lock()
        transports.append(transport)
        lock.unlock()
        return transport
    }

    func transport(at index: Int) -> FakeCodexAppServerTransport? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard transports.indices.contains(index) else {
            return nil
        }
        return transports[index]
    }
}

final class SequencedDirectConfigProvider {
    private let lock = NSLock()
    private let configs: [CodexAppServerConfigResponse]
    private var index = 0

    init(_ configs: [CodexAppServerConfigResponse]) {
        self.configs = configs
    }

    var callCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return index
    }

    func next() async throws -> CodexAppServerConfigResponse {
        takeNext()
    }

    private func takeNext() -> CodexAppServerConfigResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        let config = configs[min(index, max(0, configs.count - 1))]
        index += 1
        return config
    }
}

actor FakeCodexAppServerSentStore {
    private var messages: [String] = []

    func append(_ text: String) {
        messages.append(text)
    }

    func snapshot() -> [String] {
        messages
    }
}

actor FakeCodexAppServerLifecycleStore {
    private(set) var closeCallCount = 0

    func recordClose() {
        closeCallCount += 1
    }
}

func waitForFakeAppServerTransport(
    in pool: FakeCodexAppServerTransportPool,
    index: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> FakeCodexAppServerTransport {
    for _ in 0..<200 {
        if let transport = pool.transport(at: index) {
            return transport
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server transport \(index)", file: file, line: line)
    throw MockError.unimplemented
}

func waitForFakeAppServerMessages(
    _ transport: FakeCodexAppServerTransport,
    count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> [String] {
    for _ in 0..<200 {
        let messages = await transport.sentMessages()
        if messages.count >= count {
            return messages
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(count) app-server messages", file: file, line: line)
    return await transport.sentMessages()
}

func waitForFakeAppServerRequest(
    _ transport: FakeCodexAppServerTransport,
    method: String,
    after startIndex: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> CodexAppServerRequest {
    for _ in 0..<200 {
        let messages = await transport.sentMessages()
        if startIndex < messages.count {
            for text in messages[startIndex...] {
                guard let request = try? decodeAppServerRequest(text) else {
                    continue
                }
                if request.method == method {
                    return request
                }
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server request \(method)", file: file, line: line)
    throw MockError.unimplemented
}

func assertInitializeEnablesExperimentalAPI(
    _ initialize: CodexAppServerRequest,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(initialize.method, "initialize", file: file, line: line)
    let params = initialize.params?.objectValue
    let capabilities = params?["capabilities"]?.objectValue
    // collaborationMode 是 app-server 的 experimental turn/start 字段；
    // 初始化时必须声明 experimentalApi，否则计划模式会被真实服务端拒绝或降级。
    XCTAssertEqual(capabilities?["experimentalApi"]?.boolValue, true, file: file, line: line)
    XCTAssertEqual(capabilities?["requestAttestation"]?.boolValue, false, file: file, line: line)
    XCTAssertEqual(capabilities?["mimiThreadHandoff"]?.boolValue, true, file: file, line: line)
}

func waitForFakeAppServerResponse(
    _ transport: FakeCodexAppServerTransport,
    id: CodexAppServerRequestID,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> CodexAppServerResponse {
    for _ in 0..<200 {
        let messages = await transport.sentMessages()
        for text in messages {
            guard
                let response = try? AgentAPIClient.decoder.decode(
                    CodexAppServerResponse.self,
                    from: Data(text.utf8)
                ),
                response.id == id,
                response.result != nil || response.error != nil
            else {
                continue
            }
            return response
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server response \(id)", file: file, line: line)
    throw MockError.unimplemented
}

func connectFakeAppServer(
    _ connection: CodexAppServerConnection,
    transport: FakeCodexAppServerTransport
) async throws {
    let connectTask = Task {
        try await connection.connect(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:7777/api/app-server/ws")), token: "test-token")
    }
    let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
    let initialize = try decodeAppServerRequest(initializeMessages[0])
    assertInitializeEnablesExperimentalAPI(initialize)
    transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)
    try await connectTask.value

    let connectedMessages = try await waitForFakeAppServerMessages(transport, count: 2)
    let initialized = try AgentAPIClient.decoder.decode(
        CodexAppServerNotification.self,
        from: Data(connectedMessages[1].utf8)
    )
    XCTAssertEqual(initialized.method, "initialized")
}

func waitForRuntimeConnectionToBecomeUnavailable(
    _ runtime: CodexAppServerSessionRuntime,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<200 {
        let ready = await runtime.hasReadyConnectionForTesting()
        if !ready {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for app-server runtime connection to become unavailable", file: file, line: line)
}

func waitForThreadSearchQueries(
    _ gate: ThreadSearchResponseGate,
    count: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<100 {
        if gate.queries.count >= count {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(count) thread/search requests", file: file, line: line)
}

func makeDirectAppServerConfig(
    project: AgentProject,
    gatewayAvailable: Bool = true,
    allowedMethods: [String]? = nil,
    channels: [CodexAppServerChannelMetadata] = []
) -> CodexAppServerConfigResponse {
    let defaultAllowedMethods = ["initialize", "initialized", "thread/list", "thread/start", "thread/read", "turn/start", "turn/interrupt"]
    return CodexAppServerConfigResponse(
        gatewayWSURL: gatewayAvailable ? "ws://127.0.0.1:7777/api/app-server/ws" : "",
        runtime: CodexAppServerRuntimeMetadata(
            type: "codex_app_server",
            transport: "ws",
            managed: true,
            gatewayAvailable: gatewayAvailable,
        upstreamConfigured: gatewayAvailable,
        running: gatewayAvailable,
        initialized: false,
        pendingRequests: 0
        ),
        channels: channels,
        projects: [project],
        policy: CodexAppServerPolicyMetadata(
            allowedMethods: allowedMethods ?? defaultAllowedMethods,
            projectsSource: "agentd_allowlist"
        )
    )
}

func makeClaudeChannelMetadata() -> CodexAppServerChannelMetadata {
    CodexAppServerChannelMetadata(
        id: "claude",
        runtimeID: "claude",
        title: "Claude Code",
        provider: "anthropic",
        type: "claude_code_bridge",
        protocolName: "app_server_jsonrpc_stdio_v1",
        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=claude",
        gatewayAvailable: true,
        managed: false,
        experimental: true,
        lifecycle: "per_connection",
        bridge: nil,
        methods: ["initialize", "initialized", "thread/list", "thread/start", "turn/start", "model/list"],
        capabilities: ["history": true, "streaming": true]
    )
}

func appServerThreadListResult(_ rows: [String], nextCursor: String?) -> String {
    let encodedCursor = nextCursor.map { #","nextCursor":"\#($0)""# } ?? #","nextCursor":null"#
    return #"{"data":[\#(rows.joined(separator: ","))]\#(encodedCursor)}"#
}

func appServerThreadJSON(id: String, cwd: String, source: String, updatedAt: Int) -> String {
    """
    {"id":"\(id)","sessionId":"\(id)","preview":"\(id)","ephemeral":false,"modelProvider":"openai","createdAt":\(updatedAt - 10),"updatedAt":\(updatedAt),"status":{"type":"idle"},"path":null,"cwd":"\(cwd)","cliVersion":"0.0.0","source":"\(source)","threadSource":"user","name":"\(id)","turns":[]}
    """
}

func decodeAppServerRequest(_ text: String) throws -> CodexAppServerRequest {
    try AgentAPIClient.decoder.decode(CodexAppServerRequest.self, from: Data(text.utf8))
}

func decodeAppServerNotification(_ text: String) throws -> CodexAppServerNotification {
    try AgentAPIClient.decoder.decode(CodexAppServerNotification.self, from: Data(text.utf8))
}

func loadDirectAppServerEventStreamFixture(
    named fixtureName: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [AgentEvent] {
    // 实体机无法访问 Mac 的源码绝对路径，因此优先读取测试 Bundle；
    // 源码路径仅作为本地旧工程的兼容回退，避免设备回归产生假失败。
    let fixturePath = URL(fileURLWithPath: fixtureName)
    let bundledFixtureURL = Bundle(for: ConversationDataFlowTests.self).url(
        forResource: fixturePath.deletingPathExtension().lastPathComponent,
        withExtension: fixturePath.pathExtension
    )
    let testFileURL = URL(fileURLWithPath: String(describing: file))
    let sourceFixtureURL = testFileURL
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(fixtureName)
    let fixtureURL = bundledFixtureURL ?? sourceFixtureURL
    let content = try String(contentsOf: fixtureURL, encoding: .utf8)
    var projector = CodexAppServerEventProjector()
    var events: [AgentEvent] = []

    for (index, rawLine) in content.split(whereSeparator: \.isNewline).enumerated() {
        let lineText = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lineText.isEmpty else {
            continue
        }
        let message = try AgentAPIClient.decoder.decode(CodexAppServerMessage.self, from: Data(lineText.utf8))
        let event: AgentEvent?
        switch message {
        case .notification(let notification):
            event = projector.project(notification)
        case .serverRequest(let request):
            event = projector.project(request)
        case .response:
            event = nil
        }
        guard let event else {
            XCTFail("fixture 第 \(index + 1) 行无法投影为 AgentEvent: \(lineText)", file: file, line: line)
            throw MockError.unimplemented
        }
        events.append(event)
    }

    return events
}

func jsonFragment(for id: CodexAppServerRequestID) throws -> String {
    let data = try JSONEncoder().encode(id)
    return String(decoding: data, as: UTF8.self)
}

func transportResponse(_ transport: FakeCodexAppServerTransport, id: CodexAppServerRequestID, result: String) {
    let encodedID = (try? jsonFragment(for: id)) ?? "null"
    transport.enqueue(#"{"id":\#(encodedID),"result":\#(result)}"#)
}

func transportErrorResponse(_ transport: FakeCodexAppServerTransport, id: CodexAppServerRequestID, code: Int, message: String) {
    let encodedID = (try? jsonFragment(for: id)) ?? "null"
    let encodedMessage = (try? String(decoding: JSONEncoder().encode(message), as: UTF8.self)) ?? #""app-server error""#
    transport.enqueue(#"{"id":\#(encodedID),"error":{"code":\#(code),"message":\#(encodedMessage)}}"#)
}

func historyPolicyError(
    reason: String,
    retryAfterMs: Int? = nil,
    responseBytes: Int? = nil,
    maxResponseBytes: Int? = nil,
    method: String = "thread/turns/list",
    itemsView: String? = nil
) -> Error {
    let resolvedItemsView = itemsView ?? (reason == "history_response_too_large" ? "full" : "summary")
    var data: [String: CodexAppServerJSONValue] = [
        "reason": .string(reason),
        "method": .string(method),
        "threadId": .string("codex_history_policy_test"),
        "itemsView": .string(resolvedItemsView)
    ]
    if let retryAfterMs {
        data["retryAfterMs"] = .int(Int64(retryAfterMs))
        data["retryAfterSeconds"] = .int(Int64(max(1, (retryAfterMs + 999) / 1_000)))
    }
    if let responseBytes {
        data["responseBytes"] = .int(Int64(responseBytes))
    }
    if let maxResponseBytes {
        data["maxResponseBytes"] = .int(Int64(maxResponseBytes))
    }
    let message: String
    switch reason {
    case "history_response_too_large":
        message = "\(method) history response 过大，gateway 已阻断；请降低 limit/itemsView 或改用分页读取"
    default:
        message = "\(method) 同一 thread/method 正在临时限流，请稍后重试或降低 limit/itemsView"
    }
    return CodexAppServerConnectionError.appServer(CodexAppServerError(
        code: -32080,
        message: message,
        data: .object(data)
    ))
}

func sessionListPolicyError(retryAfterMs: Int) -> Error {
    CodexAppServerConnectionError.appServer(CodexAppServerError(
        code: -32080,
        message: "thread/list 同一 thread/method 正在临时限流，请稍后重试或降低 limit/itemsView（itemsView=list）",
        data: .object([
            "reason": .string("history_budget_limited"),
            "method": .string("thread/list"),
            "itemsView": .string("list"),
            "retryAfterMs": .int(Int64(retryAfterMs)),
            "retryAfterSeconds": .int(Int64(max(1, (retryAfterMs + 999) / 1_000)))
        ])
    ))
}

struct ConnectedProfileFixture {
    let suiteName: String
    let defaults: UserDefaults
    let appStore: AppStore
    let store: SessionStore
    let session: AgentSession
    let socket: MockWebSocketClient
}

actor PreparedConnectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
func makeConnectedProfileFixture(testName: String) async throws -> ConnectedProfileFixture {
    let suiteName = "ConversationDataFlowTests.ProfileState.\(testName).\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let profiles = [
        ConnectionProfile(id: "mac-a", displayName: "Mac A", endpoint: "http://100.64.0.10:8787", lastSuccessfulAt: nil),
        ConnectionProfile(id: "mac-b", displayName: "Mac B", endpoint: "http://100.64.0.20:8787", lastSuccessfulAt: nil)
    ]
    defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v1")
    defaults.set("mac-a", forKey: "agentd.activeConnectionProfileID.v1")
    defaults.set(profiles[0].endpoint, forKey: "agentd.endpoint")
    let keychain = TestKeychainOperations()
    keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
    keychain.setData(Data("token-b".utf8), account: "agentd-profile.mac-b")
    let appStore = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))
    appStore.connectionStatus = .connected("旧 Mac")
    let project = makeProject(id: "proj_profile_state_\(testName)")
    let session = makeSession(
        id: "sess_profile_state_\(testName)",
        projectID: project.id,
        title: "旧 Mac 会话",
        status: "running",
        source: "codex"
    )
    let client = MockSessionStoreClient(projects: [project], sessions: [session])
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
    await store.refreshAll(autoAttach: false)
    store.takeOverSession(session)
    await store.selectSession(session)
    let socket = try XCTUnwrap(sockets.first)
    socket.emitStatus(.connected)
    try await waitForWebSocketStatus(.connected, store: store)
    return ConnectedProfileFixture(
        suiteName: suiteName,
        defaults: defaults,
        appStore: appStore,
        store: store,
        session: session,
        socket: socket
    )
}

func makeProject(id: String) -> AgentProject {
    AgentProject(id: id, name: id, path: "/tmp/\(id)")
}

func makeWorktreeCleanupItem(
    project: AgentProject,
    workspaceID: String,
    name: String,
    eligible: Bool,
    blockers: [WorktreeCleanupBlocker] = []
) -> WorktreeCleanupItem {
    let path = "/tmp/mimi-worktrees/\(project.id)/\(name)"
    let workspace = AgentWorkspace(
        id: workspaceID,
        name: name,
        path: path,
        rootProjectID: project.id,
        rootProjectName: project.name,
        rootProjectPath: project.path
    )
    return WorktreeCleanupItem(
        workspace: workspace,
        worktree: WorktreeDescriptor(
            path: path,
            repositoryPath: project.path,
            base: "main",
            branch: "mimi/\(name)",
            gitState: eligible ? "clean" : "dirty",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        ),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastUsedAt: Date(timeIntervalSince1970: 1_700_086_400),
        eligible: eligible,
        blockers: blockers
    )
}

func makeWorktreeCleanupResponse(
    items: [WorktreeCleanupItem],
    candidatePaths: [String],
    deletedPaths: [String] = [],
    failedPath: String? = nil,
    error: String? = nil
) -> WorktreeCleanupResponse {
    WorktreeCleanupResponse(
        dryRun: deletedPaths.isEmpty && failedPath == nil && error == nil,
        planID: "wtc_test_plan",
        policy: WorktreeCleanupPolicy(
            autoDelete: false,
            candidateAfterDays: 30,
            keepLatestPerProject: 3
        ),
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        worktrees: items,
        candidatePaths: candidatePaths,
        deletedPaths: deletedPaths,
        failedPath: failedPath,
        error: error
    )
}

func makeChildWorkspace(id: String, name: String, root: AgentProject) -> AgentWorkspace {
    AgentWorkspace(
        id: id,
        name: name,
        path: "\(root.path)/\(name)",
        rootProjectID: root.id,
        rootProjectName: root.name,
        rootProjectPath: root.path,
        lastOpenedAt: Date(timeIntervalSince1970: 10)
    )
}

func makeRecentWorkspaceStore(workspaces: [AgentWorkspace], endpoint: String) -> RecentWorkspaceStore {
    let suiteName = "RecentWorkspaceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    let store = RecentWorkspaceStore(defaults: defaults)
    store.save(workspaces, endpoint: endpoint)
    return store
}

func makeSessionListPreferenceStore() -> SessionListPreferenceStore {
    let suiteName = "SessionListPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return SessionListPreferenceStore(defaults: defaults)
}

func makeSessionControlStateStore() -> SessionControlStateStore {
    let suiteName = "SessionControlStateStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return SessionControlStateStore(defaults: defaults)
}

func makeSessionReminderStore() -> SessionReminderStore {
    let suiteName = "SessionReminderStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return SessionReminderStore(defaults: defaults)
}

func makeCreateSessionResponse(session: AgentSession, firstMessageJSON: String? = nil) throws -> CreateSessionResponse {
    let firstMessageField = firstMessageJSON.map { ",\n      \($0)" } ?? ""
    let json = """
    {
      "session": {
        "id": "\(session.id)",
        "project_id": "\(session.projectID)",
        "project": "\(session.project)",
        "dir": "\(session.dir)",
        "title": "\(session.title)",
        "status": "\(session.status)",
        "source": "\(session.source)",
        "resume_id": "\(session.resumeID ?? "")",
        "created_at": "2026-06-01T10:00:00Z",
        "updated_at": "2026-06-01T10:00:01Z"
      },
      "ws_url": "/api/app-server/ws?thread_id=\(session.id)"\(firstMessageField)
    }
    """
    return try AgentAPIClient.decoder.decode(CreateSessionResponse.self, from: Data(json.utf8))
}

func makeSessionResponse(session: AgentSession, recentOutput: String?, lastSeq: EventSequence? = nil) throws -> SessionResponse {
    let escapedRecentOutput: String
    if let recentOutput {
        let data = try JSONEncoder().encode(recentOutput)
        escapedRecentOutput = String(decoding: data, as: UTF8.self)
    } else {
        escapedRecentOutput = "null"
    }
    let encodedLastSeq = lastSeq.map(String.init) ?? "null"
    let json = """
    {
      "session": {
        "id": "\(session.id)",
        "project_id": "\(session.projectID)",
        "project": "\(session.project)",
        "dir": "\(session.dir)",
        "title": "\(session.title)",
        "status": "\(session.status)",
        "source": "\(session.source)",
        "resume_id": "\(session.resumeID ?? "")",
        "created_at": "2026-06-01T10:00:00Z",
        "updated_at": "2026-06-01T10:00:01Z"
      },
      "recent_output": \(escapedRecentOutput),
      "last_seq": \(encodedLastSeq)
    }
    """
    return try AgentAPIClient.decoder.decode(SessionResponse.self, from: Data(json.utf8))
}

func makeSession(
    id: String,
    projectID: String,
    title: String,
    status: String,
	source: String,
	runtimeProvider: String? = nil,
	resumeID: String? = nil,
    preview: String? = nil,
    activeTurnID: TurnID? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 2),
    recencyAt: Date? = nil
) -> AgentSession {
    AgentSession(
        id: id,
        projectID: projectID,
        project: projectID,
        dir: "/tmp/\(projectID)",
        title: title,
	status: status,
	source: source,
	runtimeProvider: runtimeProvider,
	resumeID: resumeID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: updatedAt,
        recencyAt: recencyAt,
        preview: preview,
        activeTurnID: activeTurnID
    )
}

@MainActor
func conversationTimelineScrollView(in rootView: UIView) -> UIScrollView? {
    var candidates: [UIScrollView] = []

    func collect(from view: UIView) {
        if let scrollView = view as? UIScrollView,
           scrollView.bounds.width >= rootView.bounds.width * 0.75,
           scrollView.contentSize.height > scrollView.bounds.height + 80 {
            candidates.append(scrollView)
        }
        view.subviews.forEach(collect)
    }

    collect(from: rootView)
    // Composer 里也可能包含 UIScrollView；时间线的内容高度最大，按此稳定选中 List。
    return candidates.max { lhs, rhs in
        lhs.contentSize.height < rhs.contentSize.height
    }
}

@MainActor
func distanceFromBottom(_ scrollView: UIScrollView) -> CGFloat {
    let maximumOffsetY = max(
        -scrollView.adjustedContentInset.top,
        scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    )
    return abs(maximumOffsetY - scrollView.contentOffset.y)
}

@MainActor
func waitForConversationTimelineAtBottom(
    in rootView: UIView,
    tolerance: CGFloat = 4,
    timeout: TimeInterval = 5
) async throws -> UIScrollView {
    let deadline = Date().addingTimeInterval(timeout)
    var latestScrollView: UIScrollView?

    repeat {
        rootView.layoutIfNeeded()
        if let scrollView = conversationTimelineScrollView(in: rootView) {
            latestScrollView = scrollView
            if distanceFromBottom(scrollView) <= tolerance {
                return scrollView
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    } while Date() < deadline

    return try XCTUnwrap(latestScrollView)
}

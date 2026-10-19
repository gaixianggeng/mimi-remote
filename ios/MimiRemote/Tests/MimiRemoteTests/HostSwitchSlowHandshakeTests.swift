import XCTest
@testable import MimiRemote

/// #801：一台电脑的网关握手挂起时，切换到其他电脑不能被它拖住；连续切换始终可用，
/// 被改选或失败的候选不能拆掉当前电脑的链路，提交后的 Runtime 也不能继承预热剩余时间。
/// 用例走真实的切换预热（version + config + 网关 initialize），只把 REST 与网关传输换成假主机。
@MainActor
final class HostSwitchSlowHandshakeTests: XCTestCase {
    func testSlowHostHandshakeDoesNotBlockSwitchingToAnotherHost() async throws {
        let fixture = try await makeHostSwitchFixture(testName: "SupersedeSlowHost")
        defer { fixture.tearDown() }
        fixture.gateway.setBehavior(.b, FakeHostBehavior(hangsHandshake: true))

        let slowSwitch = Task { @MainActor in
            try await fixture.store.switchConnectionProfile(id: FakeHost.b.profileID)
        }
        defer { slowSwitch.cancel() }
        try await waitUntil { fixture.gateway.connectCount(.b) == 1 }
        XCTAssertEqual(fixture.store.connectionSwitchTargetProfileID, FakeHost.b.profileID)

        let startedAt = Date()
        let committed: Bool
        do {
            committed = try await fixture.store.switchConnectionProfile(id: FakeHost.c.profileID)
        } catch {
            return XCTFail("另一台电脑握手挂起时，改选其他电脑不应被拒绝：\(error)")
        }
        XCTAssertTrue(committed)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3, "改选不能等满挂起主机的握手时限")
        XCTAssertEqual(fixture.appStore.activeConnectionProfileID, FakeHost.c.profileID)

        do {
            _ = try await slowSwitch.value
            XCTFail("被改选的切换不能提交")
        } catch is CancellationError {
            // 被新选择取代的切换以取消结束，界面不弹失败。
        } catch {
            XCTFail("被改选的切换应以取消结束：\(error)")
        }
        XCTAssertEqual(fixture.appStore.activeConnectionProfileID, FakeHost.c.profileID, "迟到的旧候选不能覆盖新选择")
        XCTAssertFalse(fixture.store.isConnectionSwitchInProgress)
        try await waitUntil { fixture.gateway.openConnectionCount(.b) == 0 }

        let refreshed = await fixture.store.refreshAfterConnectionCommit(maxWait: 2)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(fixture.store.sessions.contains { $0.id == FakeHost.c.sessionID })
        XCTAssertFalse(fixture.store.sessions.contains { $0.id == FakeHost.a.sessionID })
    }

    func testRepeatedSwitchingStaysAvailableWhileOneHostHangs() async throws {
        let fixture = try await makeHostSwitchFixture(testName: "RepeatedSwitching")
        defer { fixture.tearDown() }
        fixture.gateway.setBehavior(.b, FakeHostBehavior(hangsHandshake: true))

        for round in 0..<20 {
            let target: FakeHost = round.isMultiple(of: 2) ? .c : .a
            let other: FakeHost = target == .c ? .a : .c
            var slowSwitch: Task<Bool, Error>?
            if round.isMultiple(of: 5) {
                let attemptsBefore = fixture.gateway.connectCount(.b)
                slowSwitch = Task { @MainActor in
                    try await fixture.store.switchConnectionProfile(id: FakeHost.b.profileID)
                }
                try await waitUntil { fixture.gateway.connectCount(.b) == attemptsBefore + 1 }
            }
            do {
                let committed = try await fixture.store.switchConnectionProfile(id: target.profileID)
                XCTAssertTrue(committed, "第 \(round) 次切换")
            } catch {
                slowSwitch?.cancel()
                return XCTFail("第 \(round) 次切换到 \(target.profileID) 失败：\(error)")
            }
            if let slowSwitch {
                let outcome = await slowSwitch.result
                XCTAssertThrowsError(try outcome.get(), "第 \(round) 次：挂起的候选不能提交") { error in
                    XCTAssertTrue(error is CancellationError, "第 \(round) 次：\(error)")
                }
            }
            XCTAssertEqual(fixture.appStore.activeConnectionProfileID, target.profileID, "第 \(round) 次")
            XCTAssertFalse(fixture.store.isConnectionSwitchInProgress, "第 \(round) 次")
            let refreshed = await fixture.store.refreshAfterConnectionCommit(maxWait: 2)
            XCTAssertTrue(refreshed, "第 \(round) 次刷新")
            XCTAssertTrue(fixture.store.sessions.contains { $0.id == target.sessionID }, "第 \(round) 次列表")
            XCTAssertFalse(fixture.store.sessions.contains { $0.id == other.sessionID }, "第 \(round) 次列表串写")
        }

        // 每次提交都退役上一台的 Bundle，挂起的候选也已关闭：最后只剩当前电脑的一条网关连接。
        try await waitUntil {
            fixture.gateway.openConnectionCount(.a) == 1
                && fixture.gateway.openConnectionCount(.b) == 0
                && fixture.gateway.openConnectionCount(.c) == 0
        }
    }

    func testSlowPreparationDoesNotShortenRequestTimeoutAfterSwitch() async throws {
        let fixture = try await makeHostSwitchFixture(testName: "RequestTimeout", preparationTimeout: 3)
        defer { fixture.tearDown() }
        // 预热 REST 用掉 1.5 秒，只剩约 1.5 秒；提交后的普通请求需要 2.5 秒才返回。
        fixture.gateway.setBehavior(.c, FakeHostBehavior(restDelay: 1.5, rpcDelay: 2.5))

        let committed = try await fixture.store.switchConnectionProfile(id: FakeHost.c.profileID)
        XCTAssertTrue(committed)
        let bundle = try XCTUnwrap(fixture.appStore.activeRuntimeBundle)

        let startedAt = Date()
        do {
            _ = try await bundle.codex.modelOptions()
        } catch {
            return XCTFail("提交后的请求不能沿用预热剩余的几秒作为超时：\(error)")
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 2.4)
    }

    func testHungHandshakeFailsWithinDeadlineAndKeepsCurrentHost() async throws {
        let fixture = try await makeHostSwitchFixture(testName: "HandshakeDeadline", preparationTimeout: 1.5)
        defer { fixture.tearDown() }
        fixture.gateway.setBehavior(.b, FakeHostBehavior(hangsHandshake: true))

        let startedAt = Date()
        do {
            _ = try await fixture.store.switchConnectionProfile(id: FakeHost.b.profileID)
            XCTFail("握手挂起的电脑不能提交")
        } catch is CancellationError {
            XCTFail("握手超时应作为失败报告，不能当成取消吞掉")
        } catch {
            // 预期：网关 initialize 在预热时限内超时。
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3, "握手必须受预热总时限约束")
        XCTAssertEqual(fixture.appStore.activeConnectionProfileID, FakeHost.a.profileID)
        XCTAssertEqual(fixture.initialSocket.disconnectCallCount, 0, "失败的候选不能拆掉当前电脑的链路")
        XCTAssertEqual(fixture.store.webSocketStatus, .connected)
        XCTAssertFalse(fixture.store.isConnectionSwitchInProgress)
        try await waitUntil { fixture.gateway.openConnectionCount(.b) == 0 }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - 假主机

private enum FakeHost: String, CaseIterable {
    case a, b, c

    var profileID: String { "mac-\(rawValue)" }
    var displayName: String { "Mac \(rawValue.uppercased())" }
    var ip: String {
        switch self {
        case .a: return "100.64.0.10"
        case .b: return "100.64.0.20"
        case .c: return "100.64.0.30"
        }
    }
    var endpoint: String { "http://\(ip):8787" }
    var installationID: String { "installation-\(rawValue)" }
    var project: AgentProject { makeProject(id: "proj_host_switch_\(rawValue)") }
    var sessionID: String { "sess_host_switch_\(rawValue)" }
    var session: AgentSession {
        makeSession(id: sessionID, projectID: project.id, title: displayName, status: "running", source: "codex")
    }

    static func matching(host: String?) -> FakeHost? {
        allCases.first { $0.ip == host }
    }
}

private struct FakeHostBehavior {
    var restDelay: TimeInterval = 0
    /// 模拟 TCP 已建立但 HTTP Upgrade 不回：URLSessionWebSocketTask 的 send 一直挂到任务被关闭。
    var hangsHandshake = false
    /// 握手完成后普通 RPC（这里用 model/list）的响应延迟。
    var rpcDelay: TimeInterval = 0
}

private final class FakeHostGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var behaviors: [FakeHost: FakeHostBehavior] = [:]
    private var connects: [FakeHost: Int] = [:]
    private var closes: [FakeHost: Int] = [:]

    func setBehavior(_ host: FakeHost, _ behavior: FakeHostBehavior) {
        lock.withLock { behaviors[host] = behavior }
    }

    func behavior(_ host: FakeHost?) -> FakeHostBehavior {
        guard let host else { return FakeHostBehavior() }
        return lock.withLock { behaviors[host] ?? FakeHostBehavior() }
    }

    func recordConnect(_ host: FakeHost?) {
        guard let host else { return }
        lock.withLock { connects[host, default: 0] += 1 }
    }

    func recordClose(_ host: FakeHost?) {
        guard let host else { return }
        lock.withLock { closes[host, default: 0] += 1 }
    }

    func connectCount(_ host: FakeHost) -> Int {
        lock.withLock { connects[host] ?? 0 }
    }

    func openConnectionCount(_ host: FakeHost) -> Int {
        lock.withLock { (connects[host] ?? 0) - (closes[host] ?? 0) }
    }
}

/// 每条网关连接一个实例；connect 时按 URL 主机决定扮演哪台电脑。
private final class FakeHostGatewayTransport: CodexAppServerTransport, @unchecked Sendable {
    private let gateway: FakeHostGateway
    private let lock = NSLock()
    private var host: FakeHost?
    private var isClosed = false
    private var handshakeWaiters: [CheckedContinuation<Void, Error>] = []
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.Iterator

    init(gateway: FakeHostGateway) {
        self.gateway = gateway
        var captured: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> { captured = $0 }
        continuation = captured!
        iterator = stream.makeAsyncIterator()
    }

    func connect(url: URL, token: String) async throws {
        let host = FakeHost.matching(host: url.host)
        lock.withLock { self.host = host }
        gateway.recordConnect(host)
    }

    func send(_ text: String) async throws {
        let host = lock.withLock { self.host }
        let behavior = gateway.behavior(host)
        if behavior.hangsHandshake {
            try await waitUntilClosed()
        }
        guard let request = try? decodeAppServerRequest(text) else { return }
        let id = try jsonFragment(for: request.id)
        switch request.method {
        case "initialize":
            continuation.yield(#"{"id":\#(id),"result":{"userAgent":"fake-host","platformFamily":"macos"}}"#)
        default:
            let continuation = continuation
            let delay = behavior.rpcDelay
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continuation.yield(#"{"id":\#(id),"result":{"data":[],"nextCursor":null}}"#)
            }
        }
    }

    func receive() async throws -> String? {
        try await iterator.next()
    }

    func close() async {
        let (wasClosed, waiters, host) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Error>], FakeHost?) in
            let wasClosed = isClosed
            isClosed = true
            let waiters = handshakeWaiters
            handshakeWaiters.removeAll()
            return (wasClosed, waiters, self.host)
        }
        guard !wasClosed else { return }
        gateway.recordClose(host)
        continuation.finish()
        for waiter in waiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
    }

    private func waitUntilClosed() async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            let alreadyClosed = lock.withLock { () -> Bool in
                if isClosed { return true }
                handshakeWaiters.append(waiter)
                return false
            }
            if alreadyClosed {
                waiter.resume(throwing: URLError(.cancelled))
            }
        }
    }
}

/// 假主机的 `/api/version` 与 `/api/app-server/config`，可按主机延迟返回。
private final class FakeHostURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var gateway: FakeHostGateway?
    private var pending: DispatchWorkItem?

    static func install(_ gateway: FakeHostGateway) {
        lock.withLock { self.gateway = gateway }
    }

    static func uninstall(_ gateway: FakeHostGateway) {
        lock.withLock {
            if self.gateway === gateway { self.gateway = nil }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let gateway = Self.lock.withLock { Self.gateway }
        guard let url = request.url, let host = FakeHost.matching(host: url.host), let gateway else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body: Data
        do {
            body = try Self.responseBody(path: url.path, host: host)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + gateway.behavior(host).restDelay, execute: work)
    }

    override func stopLoading() {
        pending?.cancel()
        pending = nil
    }

    private static func responseBody(path: String, host: FakeHost) throws -> Data {
        switch path {
        case "/api/version":
            return try JSONSerialization.data(withJSONObject: [
                "name": "agentd",
                "version": "test",
                "installation_id": host.installationID,
                "platform": "macos",
                "protocol_revision": 2,
                "minimum_client_protocol_revision": 1
            ])
        case "/api/app-server/config":
            return try JSONEncoder().encode(makeDirectAppServerConfig(project: host.project))
        default:
            throw URLError(.fileDoesNotExist)
        }
    }
}

// MARK: - 夹具

private struct HostSwitchFixture {
    let suiteName: String
    let defaults: UserDefaults
    let appStore: AppStore
    let store: SessionStore
    let gateway: FakeHostGateway
    let initialSocket: MockWebSocketClient

    func tearDown() {
        FakeHostURLProtocol.uninstall(gateway)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// 三台已保存的电脑，当前连着 A，且 A 的会话事件 WebSocket 已连接。
@MainActor
private func makeHostSwitchFixture(
    testName: String,
    preparationTimeout: TimeInterval = 8
) async throws -> HostSwitchFixture {
    let suiteName = "HostSwitchSlowHandshakeTests.\(testName).\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let profiles = FakeHost.allCases.map { host in
        ConnectionProfile(
            id: host.profileID,
            displayName: host.displayName,
            endpoint: host.endpoint,
            lastSuccessfulAt: nil,
            installationID: host.installationID
        )
    }
    defaults.set(try JSONEncoder().encode(profiles), forKey: "agentd.connectionProfiles.v2")
    defaults.set(FakeHost.a.profileID, forKey: "agentd.activeConnectionProfileID.v1")
    defaults.set(FakeHost.a.endpoint, forKey: "agentd.endpoint")
    let keychain = TestKeychainOperations()
    for host in FakeHost.allCases {
        keychain.setData(Data("token-\(host.rawValue)".utf8), account: "agentd-profile.\(host.profileID)")
    }

    let gateway = FakeHostGateway()
    FakeHostURLProtocol.install(gateway)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeHostURLProtocol.self]
    let appStore = AppStore(
        defaults: defaults,
        tokenStore: TokenStore(keychain: keychain),
        prefersLocalConnection: false,
        agentAPISession: URLSession(configuration: configuration),
        gatewayTransportFactory: { FakeHostGatewayTransport(gateway: gateway) },
        hostSwitchPreparationTimeout: preparationTimeout
    )
    appStore.connectionStatus = .connected(FakeHost.a.displayName)

    var clients: [String: MockSessionStoreClient] = [:]
    for host in FakeHost.allCases {
        clients[host.profileID] = MockSessionStoreClient(projects: [host.project], sessions: [host.session])
    }
    var sockets: [MockWebSocketClient] = []
    let store = SessionStore(
        appStore: appStore,
        conversationStore: ConversationStore(),
        logStore: LogStore(),
        clientFactory: { [unowned appStore] in
            // 列表永远来自当前电脑：串写会让另一台的会话出现在列表里。
            try XCTUnwrap(clients[appStore.activeConnectionProfileID ?? ""])
        },
        webSocketFactory: {
            let socket = MockWebSocketClient()
            sockets.append(socket)
            return socket
        }
    )
    await store.refreshAll(autoAttach: false)
    store.takeOverSession(FakeHost.a.session)
    await store.selectSession(FakeHost.a.session)
    let socket = try XCTUnwrap(sockets.first)
    socket.emitStatus(.connected)
    try await waitForWebSocketStatus(.connected, store: store)
    return HostSwitchFixture(
        suiteName: suiteName,
        defaults: defaults,
        appStore: appStore,
        store: store,
        gateway: gateway,
        initialSocket: socket
    )
}

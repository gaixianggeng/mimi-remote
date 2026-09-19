import XCTest
@testable import MimiRemote

@MainActor
final class DeepSeekSessionLifecycleTests: XCTestCase {
    func testLastObserverDetachInvalidatesBindingAndNextConnectFollowsAgain() async throws {
        let fixture = makeFixture(name: "detach")
        try await createThread(fixture, prompt: "")

        let firstEvents = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        let firstConnect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let firstFollow = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list"
        )
        XCTAssertEqual(firstFollow.params?.objectValue?["_mimi_observe"]?.boolValue, true)
        transportResponse(fixture.transport, id: firstFollow.id, result: #"{"data":[],"nextCursor":null}"#)
        try await firstConnect.value
        let initiallyResumed = await fixture.runtime.threadsResumedOnConnection.contains(fixture.threadID)
        XCTAssertTrue(initiallyResumed)

        try await detachEvents(firstEvents, fixture: fixture)
        let detachedLease = await fixture.runtime.threadSubscriptionLeaseBySessionID[fixture.threadID]
        XCTAssertEqual(detachedLease?.wantsEvents, false)

        let secondEvents = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        let sentBeforeSecondConnect = await fixture.transport.sentMessages().count
        let secondConnect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let secondFollow = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list",
            after: sentBeforeSecondConnect
        )
        transportResponse(fixture.transport, id: secondFollow.id, result: #"{"data":[],"nextCursor":null}"#)
        try await secondConnect.value

        let requests = await fixture.transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 2)
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 1)
        try await detachEvents(secondEvents, fixture: fixture)
    }

    func testIdleFollowInvalidationClearsBindingWithoutReconnectLoop() async throws {
        let fixture = makeFixture(name: "idle-invalidation", threadID: "session-a")
        try await createThread(fixture, prompt: "")
        let events = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        let connect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let follow = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list"
        )
        transportResponse(fixture.transport, id: follow.id, result: #"{"data":[],"nextCursor":null}"#)
        try await connect.value

        let invalidation = try deepSeekContractData("deepseek-follow-invalidated.json")
        fixture.transport.enqueue(String(decoding: invalidation, as: UTF8.self))
        try await waitUntil {
            await fixture.runtime.threadsResumedOnConnection.contains(fixture.threadID) == false
        }
        for _ in 0..<20 { await Task.yield() }

        let requests = await fixture.transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        let observers = await fixture.runtime.eventMailboxesBySessionID[fixture.threadID]
        let lease = await fixture.runtime.threadSubscriptionLeaseBySessionID[fixture.threadID]
        let remainsObserved = await fixture.runtime.deepSeekThreadsObservedOnConnection.contains(fixture.threadID)
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 1)
        XCTAssertFalse(observers?.isEmpty ?? true)
        XCTAssertEqual(lease?.wantsEvents, true)
        XCTAssertFalse(remainsObserved)
        events.cancel()
    }

    func testThreadStartBindingStillPinsFirstEventObserver() async throws {
        let fixture = makeFixture(name: "start-binding")
        try await createThread(fixture, prompt: "开始", turnID: "turn-a")
        let resumedBeforeConnect = await fixture.runtime.threadsResumedOnConnection.contains(fixture.threadID)
        let observedBeforeConnect = await fixture.runtime.deepSeekThreadsObservedOnConnection.contains(fixture.threadID)
        XCTAssertTrue(resumedBeforeConnect)
        XCTAssertFalse(observedBeforeConnect)

        let events = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        let sentBeforeConnect = await fixture.transport.sentMessages().count
        let connect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let observe = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list",
            after: sentBeforeConnect
        )
        XCTAssertEqual(observe.params?.objectValue?["_mimi_observe"]?.boolValue, true)
        transportResponse(
            fixture.transport,
            id: observe.id,
            result: #"{"data":[{"id":"turn-a","status":"inProgress","items":[]}],"nextCursor":null}"#
        )
        try await connect.value

        let observedAfterConnect = await fixture.runtime.deepSeekThreadsObservedOnConnection.contains(fixture.threadID)
        XCTAssertTrue(observedAfterConnect)
        try await detachEvents(events, fixture: fixture)
    }

    func testDetachDuringObserveLeavesUnsubscribedAfterLateObserveResponse() async throws {
        let fixture = makeFixture(name: "observe-detach-race")
        try await createThread(fixture, prompt: "")
        let events = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        let connect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let observe = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list"
        )
        XCTAssertEqual(observe.params?.objectValue?["_mimi_observe"]?.boolValue, true)

        let sentBeforeDetach = await fixture.transport.sentMessages().count
        events.cancel()
        let unsubscribe = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/unsubscribe",
            after: sentBeforeDetach
        )
        transportResponse(fixture.transport, id: unsubscribe.id, result: #"{"status":"unsubscribed"}"#)
        transportResponse(fixture.transport, id: observe.id, result: #"{"data":[],"nextCursor":null}"#)
        do {
            try await connect.value
            XCTFail("被最后一个 observer 取消的 observe 不应恢复成功")
        } catch is CancellationError {
            // 取消是预期结果；迟到的 observe ACK 不能重新写回本地 pin。
        }
        try await waitUntil {
            let resumed = await fixture.runtime.threadsResumedOnConnection.contains(fixture.threadID)
            let observed = await fixture.runtime.deepSeekThreadsObservedOnConnection.contains(fixture.threadID)
            return !resumed && !observed
        }
        let lease = await fixture.runtime.threadSubscriptionLeaseBySessionID[fixture.threadID]
        XCTAssertEqual(lease?.wantsEvents, false)
    }

    func testReconnectReconcilesOfflineCompletionForCapturedActiveTurn() async throws {
        let fixture = makeFixture(name: "completion")
        try await createThread(fixture, prompt: "开始", turnID: "turn-a")
        let initialEvents = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        try await detachEvents(initialEvents, fixture: fixture)

        let events = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        var recoveredMetadata: AgentEventMetadata?
        let recovered = expectation(description: "DeepSeek reconnect 补回 turn/completed")
        let eventTask = Task { @MainActor in
            for await event in events {
                guard case .turnCompleted(let metadata) = event else { continue }
                recoveredMetadata = metadata
                recovered.fulfill()
                return
            }
        }
        let sentBeforeReconnect = await fixture.transport.sentMessages().count
        let reconnect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let follow = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list",
            after: sentBeforeReconnect
        )
        transportResponse(
            fixture.transport,
            id: follow.id,
            result: #"{"data":[{"id":"turn-a","status":"completed","completedAt":1780490310,"items":[]}],"nextCursor":null}"#
        )
        try await reconnect.value
        await fulfillment(of: [recovered], timeout: 5)

        XCTAssertEqual(recoveredMetadata?.sessionID, fixture.threadID)
        XCTAssertEqual(recoveredMetadata?.turnID, "turn-a")
        XCTAssertEqual(recoveredMetadata?.turnLifecycle, .completed)
        let activeTurnID = await fixture.runtime.contextsBySessionID[fixture.threadID]?.activeTurnID
        XCTAssertNil(activeTurnID)
        try await detachEvents(events, fixture: fixture)
        eventTask.cancel()
    }

    func testReconnectPagesUntilCapturedTurnAndReconcilesItsCompletion() async throws {
        let fixture = makeFixture(name: "paged-completion")
        try await createThread(fixture, prompt: "开始", turnID: "turn-1")
        let initialEvents = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        try await detachEvents(initialEvents, fixture: fixture)

        let events = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        var recoveredTurnID: TurnID?
        let recovered = expectation(description: "分页找到 captured active turn 后补完成")
        let eventTask = Task { @MainActor in
            for await event in events {
                guard case .turnCompleted(let metadata) = event else { continue }
                recoveredTurnID = metadata.turnID
                recovered.fulfill()
                return
            }
        }
        let sentBeforeReconnect = await fixture.transport.sentMessages().count
        let reconnect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let latest = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list",
            after: sentBeforeReconnect
        )
        transportResponse(
            fixture.transport,
            id: latest.id,
            result: #"{"data":[{"id":"turn-2","status":"completed","completedAt":1780490320,"items":[]}],"nextCursor":"older-turns"}"#
        )
        let older = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list",
            after: sentBeforeReconnect + 1
        )
        XCTAssertEqual(older.params?.objectValue?["cursor"]?.stringValue, "older-turns")
        transportResponse(
            fixture.transport,
            id: older.id,
            result: #"{"data":[{"id":"turn-1","status":"completed","completedAt":1780490310,"items":[]}],"nextCursor":null}"#
        )
        try await reconnect.value
        await fulfillment(of: [recovered], timeout: 5)

        let activeTurnID = await fixture.runtime.contextsBySessionID[fixture.threadID]?.activeTurnID
        let requests = await fixture.transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        XCTAssertEqual(recoveredTurnID, "turn-1")
        XCTAssertNil(activeTurnID)
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 2)
        try await detachEvents(events, fixture: fixture)
        eventTask.cancel()
    }

    func testReconnectAdoptsNewActiveTurnWithoutCompletingCapturedTurn() async throws {
        let fixture = makeFixture(name: "new-active")
        try await createThread(fixture, prompt: "开始", turnID: "turn-a")
        let initialEvents = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        try await detachEvents(initialEvents, fixture: fixture)

        let events = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        var completedTurnID: TurnID?
        var recoveredSession: AgentSession?
        let adopted = expectation(description: "采用 reconnect 返回的新 active turn")
        let eventTask = Task { @MainActor in
            for await event in events {
                switch event {
                case .turnCompleted(let metadata):
                    completedTurnID = metadata.turnID
                case .session(let session) where session.activeTurnID == "turn-b":
                    recoveredSession = session
                    adopted.fulfill()
                    return
                default:
                    continue
                }
            }
        }
        let sentBeforeReconnect = await fixture.transport.sentMessages().count
        let reconnect = Task { try await fixture.runtime.connectForEvents(sessionID: fixture.threadID) }
        let follow = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/turns/list",
            after: sentBeforeReconnect
        )
        transportResponse(
            fixture.transport,
            id: follow.id,
            result: #"{"data":[{"id":"turn-b","status":"inProgress","items":[]}],"nextCursor":null}"#
        )
        try await reconnect.value
        await fulfillment(of: [adopted], timeout: 5)

        XCTAssertEqual(recoveredSession?.activeTurnID, "turn-b")
        let activeTurnID = await fixture.runtime.contextsBySessionID[fixture.threadID]?.activeTurnID
        XCTAssertEqual(activeTurnID, "turn-b")
        XCTAssertNil(completedTurnID)
        try await detachEvents(events, fixture: fixture)
        eventTask.cancel()
    }

    private func makeFixture(name: String, threadID: SessionID? = nil) -> DeepSeekLifecycleFixture {
        let project = AgentProject(
            id: "proj-\(name)",
            name: name,
            path: "/tmp/deepseek-\(name)"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "token",
            runtimeProvider: "deepseek",
            transportFactory: { transport },
            configProvider: { makeLifecycleDeepSeekConfig(project: project) }
        )
        return DeepSeekLifecycleFixture(
            project: project,
            transport: transport,
            runtime: runtime,
            threadID: threadID ?? "thread-\(name)"
        )
    }

    private func createThread(
        _ fixture: DeepSeekLifecycleFixture,
        prompt: String,
        turnID: TurnID? = nil
    ) async throws {
        let task = Task {
            try await fixture.runtime.createSession(CreateSessionRequest(
                projectID: fixture.project.id,
                prompt: prompt,
                turnOptions: .init(runtimeProvider: "deepseek", modelProvider: "provider-a"),
                resumeID: ""
            ))
        }
        let initialize = try await waitForFakeAppServerRequest(fixture.transport, method: "initialize")
        transportResponse(fixture.transport, id: initialize.id, result: #"{"userAgent":"fake-deepseek"}"#)
        let start = try await waitForFakeAppServerRequest(fixture.transport, method: "thread/start")
        let thread = #"{"id":"\#(fixture.threadID)","sessionId":"\#(fixture.threadID)","preview":"","ephemeral":false,"modelProvider":"provider-a","createdAt":1780490200,"updatedAt":1780490201,"status":{"type":"idle"},"path":null,"cwd":"\#(fixture.project.path)","cliVersion":"0.0.0","source":"deepseek","threadSource":"user","name":"Lifecycle","turns":[]}"#
        transportResponse(fixture.transport, id: start.id, result: #"{"thread":\#(thread)}"#)
        if let turnID {
            let turnStart = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/start")
            transportResponse(
                fixture.transport,
                id: turnStart.id,
                result: #"{"turn":{"id":"\#(turnID)","items":[],"status":"inProgress","error":null}}"#
            )
        }
        _ = try await task.value
    }

    private func detachEvents(
        _ events: CodexAppServerEventStream,
        fixture: DeepSeekLifecycleFixture
    ) async throws {
        let sentBeforeDetach = await fixture.transport.sentMessages().count
        events.cancel()
        let unsubscribe = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/unsubscribe",
            after: sentBeforeDetach
        )
        transportResponse(fixture.transport, id: unsubscribe.id, result: #"{"status":"unsubscribed"}"#)
        try await waitUntil {
            let resumed = await fixture.runtime.threadsResumedOnConnection.contains(fixture.threadID)
            let observed = await fixture.runtime.deepSeekThreadsObservedOnConnection.contains(fixture.threadID)
            return !resumed && !observed
        }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () async -> Bool
    ) async throws {
        // 轮询预算从 2s 放宽到 4s：与 waitForFakeAppServerRequest 同步，避免 CI 负载下偶发超时。
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for DeepSeek lifecycle state", file: file, line: line)
    }
}

private struct DeepSeekLifecycleFixture {
    let project: AgentProject
    let transport: FakeCodexAppServerTransport
    let runtime: CodexAppServerSessionRuntime
    let threadID: SessionID
}

private func makeLifecycleDeepSeekConfig(project: AgentProject) -> CodexAppServerConfigResponse {
    let methods = [
        "initialize", "initialized", "thread/start", "thread/read", "thread/turns/list", "thread/unsubscribe",
        "turn/start", "turn/interrupt"
    ]
    let channel = CodexAppServerChannelMetadata(
        id: "deepseek",
        runtimeID: "deepseek",
        title: "DeepSeek Harness",
        provider: "deepseek",
        type: "deepseek_harness_service",
        protocolName: "app_server_jsonrpc_stdio_v1",
        gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=deepseek",
        gatewayAvailable: true,
        managed: false,
        experimental: true,
        lifecycle: "per_connection",
        bridge: nil,
        methods: methods,
        capabilities: ["history": true, "streaming": true]
    )
    return makeDirectAppServerConfig(project: project, allowedMethods: methods, channels: [channel])
}

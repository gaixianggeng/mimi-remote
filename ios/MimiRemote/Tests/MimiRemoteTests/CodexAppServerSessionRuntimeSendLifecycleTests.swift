import XCTest
@testable import MimiRemote

private struct RuntimeSendLifecycleFixture {
    let runtime: CodexAppServerSessionRuntime
    let transport: FakeCodexAppServerTransport
    let transportPool: FakeCodexAppServerTransportPool
    let threadID: SessionID
    let threadJSON: String
    let events: CodexAppServerEventStream
}

private func makeRuntimeSendLifecycleFixture(
    suffix: String,
    activeTurnID: TurnID? = nil,
    connectsForEvents: Bool = true
) async throws -> RuntimeSendLifecycleFixture {
    let project = AgentProject(
        id: "proj_send_lifecycle_\(suffix)",
        name: "Send Lifecycle",
        path: "/tmp/send-lifecycle-\(suffix)"
    )
    let threadID = "thr_send_lifecycle_\(suffix)"
    let threadJSON: String
    if let activeTurnID {
        threadJSON = #"{"id":"\#(threadID)","sessionId":"\#(threadID)","preview":"guidance","ephemeral":false,"modelProvider":"openai","createdAt":1780499990,"updatedAt":1780500000,"status":{"type":"active"},"cwd":"\#(project.path)","source":"appServer","threadSource":"user","turns":[{"id":"\#(activeTurnID)","status":"inProgress","items":[]}]}"#
    } else {
        threadJSON = appServerThreadJSON(
            id: threadID,
            cwd: project.path,
            source: "appServer",
            updatedAt: 1_780_500_000
        )
    }
    let transportPool = FakeCodexAppServerTransportPool()
    let runtime = CodexAppServerSessionRuntime(
        endpoint: "http://127.0.0.1:8787",
        token: "test-token",
        transportFactory: { transportPool.make() },
        configProvider: {
            makeDirectAppServerConfig(
                project: project,
                allowedMethods: [
                    "initialize", "initialized", "thread/list", "thread/resume",
                    "thread/unsubscribe", "turn/start", "turn/steer"
                ]
            )
        }
    )

    let pageTask = Task {
        try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
    }
    let transport = try await waitForFakeAppServerTransport(in: transportPool, index: 0)
    let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
    transportResponse(
        transport,
        id: initialize.id,
        result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
    )
    let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
    transportResponse(
        transport,
        id: list.id,
        result: appServerThreadListResult([threadJSON], nextCursor: nil)
    )
    _ = try await pageTask.value

    let events = await runtime.attachEvents(sessionID: threadID)
    if connectsForEvents {
        try await runtime.connectForEvents(sessionID: threadID)
    }
    return RuntimeSendLifecycleFixture(
        runtime: runtime,
        transport: transport,
        transportPool: transportPool,
        threadID: threadID,
        threadJSON: threadJSON,
        events: events
    )
}

private func waitForRuntimeSendObserverDetach(
    _ fixture: RuntimeSendLifecycleFixture,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<200 {
        let observerCount = await fixture.runtime.eventMailboxesBySessionID[fixture.threadID]?.count
        let lease = await fixture.runtime.threadSubscriptionLeaseBySessionID[fixture.threadID]
        if observerCount == nil, lease?.wantsEvents == false {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for the runtime observer to detach", file: file, line: line)
    throw MockError.timeout
}

private func runtimeSendRequestCount(
    _ transport: FakeCodexAppServerTransport,
    method: String
) async -> Int {
    await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }
        .filter { $0.method == method }
        .count
}

private func acknowledgeRuntimeSendResume(
    _ request: CodexAppServerRequest,
    fixture: RuntimeSendLifecycleFixture
) {
    transportResponse(
        fixture.transport,
        id: request.id,
        result: #"{"thread":\#(fixture.threadJSON)}"#
    )
}

private func acknowledgeRuntimeTurnStart(
    _ request: CodexAppServerRequest,
    turnID: TurnID,
    fixture: RuntimeSendLifecycleFixture
) {
    transportResponse(
        fixture.transport,
        id: request.id,
        result: #"{"turn":{"id":"\#(turnID)","items":[],"itemsView":{"type":"complete"},"status":"inProgress","error":null}}"#
    )
}

private func acknowledgeRuntimeUnsubscribe(
    after startIndex: Int,
    fixture: RuntimeSendLifecycleFixture
) async throws {
    let unsubscribe = try await waitForFakeAppServerRequest(
        fixture.transport,
        method: "thread/unsubscribe",
        after: startIndex
    )
    transportResponse(
        fixture.transport,
        id: unsubscribe.id,
        result: #"{"status":"unsubscribed"}"#
    )
}

@MainActor
extension ConversationDataFlowTests {
    func testSteerTurnSurvivesLastObserverLeavingWhileThreadResumeIsPending() async throws {
        let activeTurnID = "turn_guidance_active"
        let fixture = try await makeRuntimeSendLifecycleFixture(
            suffix: "steer_resume_pending",
            activeTurnID: activeTurnID,
            connectsForEvents: false
        )
        let beforeSend = await fixture.transport.sentMessages().count
        let steerTask = Task {
            try await fixture.runtime.steerTurn(
                sessionID: fixture.threadID,
                payload: CodexAppServerTurnPayload(prompt: "补充指导"),
                clientMessageID: "message-steer-resume-pending",
                expectedTurnID: activeTurnID
            )
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume",
            after: beforeSend
        )

        fixture.events.cancel()
        try await waitForRuntimeSendObserverDetach(fixture)
        let resumeStillPending = await fixture.runtime.threadResumeTasksBySessionID[fixture.threadID] != nil
        XCTAssertTrue(resumeStillPending, "主动离开页面不能取消 guidance 正在等待的 thread/resume")

        acknowledgeRuntimeSendResume(resume, fixture: fixture)
        let steer = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "turn/steer",
            after: beforeSend
        )
        let beforeSteerAcknowledgement = await fixture.transport.sentMessages().count
        transportResponse(fixture.transport, id: steer.id, result: #"{}"#)
        try await steerTask.value
        try await acknowledgeRuntimeUnsubscribe(
            after: beforeSteerAcknowledgement,
            fixture: fixture
        )
    }

    func testStartTurnSurvivesLastObserverLeavingWhileThreadResumeIsPending() async throws {
        let fixture = try await makeRuntimeSendLifecycleFixture(suffix: "resume_pending")
        let beforeSend = await fixture.transport.sentMessages().count
        let sendTask = Task {
            try await fixture.runtime.startTurn(
                sessionID: fixture.threadID,
                prompt: "继续发送",
                clientMessageID: "message-resume-pending"
            )
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume",
            after: beforeSend
        )

        fixture.events.cancel()
        try await waitForRuntimeSendObserverDetach(fixture)
        let resumeStillPending = await fixture.runtime.threadResumeTasksBySessionID[fixture.threadID] != nil
        XCTAssertTrue(resumeStillPending, "主动离开页面不能取消发送正在等待的 thread/resume")

        acknowledgeRuntimeSendResume(resume, fixture: fixture)
        let turnStart = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "turn/start",
            after: beforeSend
        )
        let beforeTurnAcknowledgement = await fixture.transport.sentMessages().count
        acknowledgeRuntimeTurnStart(turnStart, turnID: "turn_resume_pending", fixture: fixture)
        let turnID = try await sendTask.value
        XCTAssertEqual(turnID, "turn_resume_pending")

        try await acknowledgeRuntimeUnsubscribe(after: beforeTurnAcknowledgement, fixture: fixture)
    }

    func testStartTurnSurvivesLastObserverLeavingWhileTurnStartAcknowledgementIsPending() async throws {
        let fixture = try await makeRuntimeSendLifecycleFixture(suffix: "ack_pending")
        let beforeSend = await fixture.transport.sentMessages().count
        let sendTask = Task {
            try await fixture.runtime.startTurn(
                sessionID: fixture.threadID,
                prompt: "等待确认",
                clientMessageID: "message-ack-pending"
            )
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume",
            after: beforeSend
        )
        acknowledgeRuntimeSendResume(resume, fixture: fixture)
        let turnStart = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "turn/start",
            after: beforeSend
        )

        fixture.events.cancel()
        try await waitForRuntimeSendObserverDetach(fixture)
        let earlyUnsubscribeCount = await runtimeSendRequestCount(
            fixture.transport,
            method: "thread/unsubscribe"
        )
        XCTAssertEqual(earlyUnsubscribeCount, 0)

        let beforeTurnAcknowledgement = await fixture.transport.sentMessages().count
        acknowledgeRuntimeTurnStart(turnStart, turnID: "turn_ack_pending", fixture: fixture)
        let turnID = try await sendTask.value
        XCTAssertEqual(turnID, "turn_ack_pending")
        try await acknowledgeRuntimeUnsubscribe(after: beforeTurnAcknowledgement, fixture: fixture)
    }

    func testStartTurnDeferredUnsubscribeDoesNotOverrideObserverReentry() async throws {
        let fixture = try await makeRuntimeSendLifecycleFixture(suffix: "observer_reentry")
        let beforeSend = await fixture.transport.sentMessages().count
        let sendTask = Task {
            try await fixture.runtime.startTurn(
                sessionID: fixture.threadID,
                prompt: "重新进入",
                clientMessageID: "message-observer-reentry"
            )
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume",
            after: beforeSend
        )
        acknowledgeRuntimeSendResume(resume, fixture: fixture)
        let turnStart = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "turn/start",
            after: beforeSend
        )

        fixture.events.cancel()
        try await waitForRuntimeSendObserverDetach(fixture)
        let reopenedEvents = await fixture.runtime.attachEvents(sessionID: fixture.threadID)
        try await fixture.runtime.connectForEvents(sessionID: fixture.threadID)

        acknowledgeRuntimeTurnStart(turnStart, turnID: "turn_observer_reentry", fixture: fixture)
        let turnID = try await sendTask.value
        XCTAssertEqual(turnID, "turn_observer_reentry")
        for _ in 0..<20 { await Task.yield() }
        let earlyUnsubscribeCount = await runtimeSendRequestCount(
            fixture.transport,
            method: "thread/unsubscribe"
        )
        XCTAssertEqual(
            earlyUnsubscribeCount,
            0,
            "发送结束后的旧退订意图不能覆盖新页面订阅"
        )

        let beforeFinalDetach = await fixture.transport.sentMessages().count
        reopenedEvents.cancel()
        try await waitForRuntimeSendObserverDetach(fixture)
        try await acknowledgeRuntimeUnsubscribe(after: beforeFinalDetach, fixture: fixture)
    }

    func testStartTurnDoesNotRetryAfterConnectionDropsDuringThreadResume() async throws {
        let fixture = try await makeRuntimeSendLifecycleFixture(suffix: "real_disconnect")
        defer { fixture.events.cancel() }
        let beforeSend = await fixture.transport.sentMessages().count
        let sendTask = Task {
            try await fixture.runtime.startTurn(
                sessionID: fixture.threadID,
                prompt: "断网发送",
                clientMessageID: "message-real-disconnect"
            )
        }
        _ = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume",
            after: beforeSend
        )

        fixture.transport.failReceive()
        do {
            _ = try await sendTask.value
            XCTFail("真实断线应终止发送")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        for _ in 0..<20 { await Task.yield() }
        let turnStartCount = await runtimeSendRequestCount(fixture.transport, method: "turn/start")
        XCTAssertEqual(turnStartCount, 0)
        XCTAssertNil(fixture.transportPool.transport(at: 1), "未知结果不能通过新连接盲目重发")
    }
}

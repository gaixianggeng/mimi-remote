import XCTest
@testable import MimiRemote

@MainActor
final class GuidanceSendLifecycleTests: XCTestCase {
    func testMultiRuntimeGuidanceAcknowledgementSurvivesWrapperRelease() async throws {
        try await assertGuidanceResultSurvivesWrapperRelease(
            suffix: "ack",
            response: .acknowledged
        )
    }

    func testMultiRuntimeGuidanceFailureSurvivesWrapperRelease() async throws {
        try await assertGuidanceResultSurvivesWrapperRelease(
            suffix: "failure",
            response: .rejected
        )
    }

    func testDefaultSendMethodFallsBackToQueueWhenPreferenceIsMissingOrUnknown() {
        // 没存过偏好、或旧版本写进去的值读不出来时，必须保持既有行为：排队。
        XCTAssertEqual(RunningTurnDelivery.fallbackDefault, .queued)
        XCTAssertEqual(RunningTurnDelivery.stored(""), .queued)
        XCTAssertEqual(RunningTurnDelivery.stored("steer"), .queued)
        XCTAssertEqual(RunningTurnDelivery.stored(RunningTurnDelivery.queued.rawValue), .queued)
        XCTAssertEqual(RunningTurnDelivery.stored(RunningTurnDelivery.guided.rawValue), .guided)
        // 设置页按这个顺序排两个胶囊；排队在前，保持与今天的默认一致。
        XCTAssertEqual(RunningTurnDelivery.allCases, [.queued, .guided])
    }

    func testGuidedDefaultOnlyAppliesWhileSteeringIsAvailable() {
        // 切换会话、发送成功和可用性变化都走这一个入口；两个运行时共用同一份偏好，
        // 因此这里不按 runtime 分叉，只看当前 turn 能不能被引导。
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .guided, canUseGuidedFollowUp: true),
            .guided
        )
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .guided, canUseGuidedFollowUp: false),
            .queued,
            "没有可引导的活动 turn 时，偏好选了引导也必须回落排队"
        )
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .queued, canUseGuidedFollowUp: true),
            .queued
        )
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .queued, canUseGuidedFollowUp: false),
            .queued
        )
    }

    func testSendMethodMenuMarksThePreferredOptionAsDefault() {
        XCTAssertEqual(
            RunningTurnDelivery.queued.menuTitle(isDefault: true, isGuidedAvailable: true),
            L10n.text("ui.queue_default")
        )
        XCTAssertEqual(
            RunningTurnDelivery.queued.menuTitle(isDefault: false, isGuidedAvailable: true),
            L10n.text("ui.queue_for_next_round"),
            "默认改成引导后，「（默认）」不能继续钉在排队项上"
        )
        XCTAssertEqual(
            RunningTurnDelivery.guided.menuTitle(isDefault: true, isGuidedAvailable: true),
            L10n.text("ui.steer_current_reply_default")
        )
        XCTAssertEqual(
            RunningTurnDelivery.guided.menuTitle(isDefault: false, isGuidedAvailable: true),
            L10n.text("ui.lead_current_reply")
        )
        XCTAssertEqual(
            RunningTurnDelivery.guided.menuTitle(isDefault: true, isGuidedAvailable: false),
            L10n.text("ui.guide_current_reply_no_active_round_currently"),
            "引导不可用时先说明原因，默认标记让位"
        )
    }

    private enum GuidanceResponse {
        case acknowledged
        case rejected
    }

    private func assertGuidanceResultSurvivesWrapperRelease(
        suffix: String,
        response: GuidanceResponse
    ) async throws {
        let project = AgentProject(
            id: "proj_guidance_lifecycle_\(suffix)",
            name: "Guidance Lifecycle",
            path: "/tmp/guidance-lifecycle-\(suffix)"
        )
        let threadID = "thread_guidance_lifecycle_\(suffix)"
        let turnID = "turn_guidance_lifecycle_\(suffix)"
        let clientMessageID = "message_guidance_lifecycle_\(suffix)"
        let thread = #"{"id":"\#(threadID)","sessionId":"\#(threadID)","preview":"guidance","ephemeral":false,"modelProvider":"openai","createdAt":1780500000,"updatedAt":1780500001,"status":{"type":"active"},"cwd":"\#(project.path)","source":"appServer","threadSource":"user","turns":[{"id":"\#(turnID)","status":"inProgress","items":[]}]}"#
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: [
                "initialize", "initialized", "thread/list", "thread/resume",
                "thread/unsubscribe", "turn/steer"
            ]
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let unusedClaudeRuntime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { config }
        )
        let bundle = AppServerRuntimeBundle(
            codexRuntime: runtime,
            claudeRuntime: unusedClaudeRuntime
        )
        bundle.routes.remember("codex", for: threadID)

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
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
            result: appServerThreadListResult([thread], nextCursor: nil)
        )
        _ = try await pageTask.value

        var socket: MultiRuntimeSessionWebSocketClient? = MultiRuntimeSessionWebSocketClient(bundle: bundle)
        weak var releasedSocket = socket
        var connected = false
        var receivedClientMessageID: ClientMessageID?
        var receivedOutcome: TurnSendOutcome?
        socket?.onStatus = { status in
            if status == .connected {
                connected = true
            }
        }
        socket?.onTurnSendOutcome = { clientMessageID, outcome in
            receivedClientMessageID = clientMessageID
            receivedOutcome = outcome
        }
        socket?.connect(sessionID: threadID)
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume")
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        for _ in 0..<200 where !connected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(connected)

        XCTAssertTrue(socket?.sendGuidance(
            CodexAppServerTurnPayload(prompt: "继续当前回复"),
            clientMessageID: clientMessageID,
            expectedTurnID: turnID
        ) == true)
        let steer = try await waitForFakeAppServerRequest(transport, method: "turn/steer")

        // 模拟切页释放前台 wrapper；底层 RPC 保持在途，结果仍应送到提交时的 generation handler。
        socket?.disconnect()
        socket = nil
        XCTAssertNil(releasedSocket)

        switch response {
        case .acknowledged:
            transportResponse(transport, id: steer.id, result: #"{}"#)
        case .rejected:
            transportErrorResponse(
                transport,
                id: steer.id,
                code: -32602,
                message: "guidance rejected"
            )
        }
        for _ in 0..<200 where receivedOutcome == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(receivedClientMessageID, clientMessageID)
        switch (response, receivedOutcome) {
        case (.acknowledged, .some(.guidanceAccepted)):
            break
        case (.rejected, .some(.rejected(let message))):
            XCTAssertTrue(message.contains("guidance rejected"))
        default:
            XCTFail("unexpected guidance result: \(String(describing: receivedOutcome))")
        }
        await runtime.shutdownForHostSwitch()
    }
}

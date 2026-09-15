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

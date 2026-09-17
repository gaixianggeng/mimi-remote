import XCTest
@testable import MimiRemote

@MainActor
final class DeepSeekCrossRuntimeContractTests: XCTestCase {
    func testGoEmptyProgressPagesContinueThroughRealHistoryParser() async throws {
        let pages = try JSONDecoder().decode(
            [CodexAppServerJSONValue].self,
            from: deepSeekContractData("deepseek-turn-progress-pages.json")
        )
        let project = AgentProject(id: "contract", name: "Contract", path: "/tmp/contract")
        let methods = ["initialize", "initialized", "thread/read", "thread/turns/list"]
        let config = makeDirectAppServerConfig(project: project, allowedMethods: methods, channels: [
            CodexAppServerChannelMetadata(
                id: "deepseek", runtimeID: "deepseek", title: "DeepSeek Harness", provider: "deepseek",
                type: "deepseek_harness_service", protocolName: "app_server_jsonrpc_stdio_v1",
                gatewayWSURL: "ws://127.0.0.1:7777/api/app-server/ws?runtime=deepseek",
                gatewayAvailable: true, managed: false, experimental: true, lifecycle: "per_connection",
                bridge: nil, methods: methods, capabilities: ["history": true]
            )
        ])
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "fixture", runtimeProvider: "deepseek",
            transportFactory: { transport }, configProvider: { config }
        )
        var cursor: String?
        for (index, response) in pages.enumerated() {
            let requestedCursor = cursor
            let sentBefore = await transport.sentMessages().count
            let task = Task {
                try await runtime.messagesPage(sessionID: "session-a", before: requestedCursor, limit: 1)
            }
            if index == 0 {
                let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
                transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fixture"}"#)
                let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
                transportResponse(transport, id: read.id, result: #"{"thread":{"id":"session-a","cwd":"/tmp/contract","source":"deepseek","status":{"type":"idle"},"turns":[]}}"#)
            }
            let request = try await waitForFakeAppServerRequest(
                transport, method: "thread/turns/list", after: sentBefore
            )
            XCTAssertEqual(request.params?["cursor"]?.stringValue,
                           CodexAppServerSessionRuntime.decodeThreadTurnsCursor(requestedCursor))
            let encoded = try JSONEncoder().encode(response)
            transportResponse(transport, id: request.id, result: String(decoding: encoded, as: UTF8.self))
            let page = try await task.value
            if index < 2 {
                XCTAssertTrue(page.messages.isEmpty)
                XCTAssertTrue(page.hasMoreBefore)
                XCTAssertNotNil(page.previousCursor)
                XCTAssertNotEqual(page.previousCursor, requestedCursor)
            } else {
                XCTAssertFalse(page.hasMoreBefore)
                XCTAssertNil(page.previousCursor)
                XCTAssertEqual(page.turnStates.map(\.id), ["t1"])
                XCTAssertEqual(page.turnStates.first?.lifecycle, .completed)
            }
            cursor = page.previousCursor
        }
    }

    func testGoModelListPreservesProviderAndReasoningChoices() throws {
        // Go 测试将真实 deepSeekModelListWire 输出与同一 JSON 比对；这里走真实 iOS 解析器。
        let result = try JSONDecoder().decode(
            CodexAppServerJSONValue.self, from: deepSeekContractData("deepseek-model-list.json")
        )
        let models = CodexAppServerModelOption.parseListResult(result)
        XCTAssertEqual(models.count, 2)
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.model, "harness-model")
        XCTAssertEqual(model.provider, "provider-a")
        XCTAssertEqual(model.supportedReasoningEfforts, ["low", "high"])
        XCTAssertEqual(model.defaultReasoningEffort, "high")
        XCTAssertEqual(models.last?.provider, "provider-b")
        XCTAssertEqual(models.last?.supportedReasoningEfforts, [])
        XCTAssertNil(models.last?.defaultReasoningEffort)
    }
}

func deepSeekContractData(_ name: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("contracts/mimi-protocol/fixtures")
        .appendingPathComponent(name))
}

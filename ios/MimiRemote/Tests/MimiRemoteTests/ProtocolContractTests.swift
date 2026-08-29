import Foundation
import XCTest
@testable import MimiRemote

final class ProtocolContractTests: XCTestCase {
    func testSharedServerFixturesCoverCurrentPreviousAndIncompatibleWindows() throws {
        let current = try decodeVersionFixture("version-current.json")
        XCTAssertEqual(current.protocolRevision, MimiProtocolContract.currentRevision)
        XCTAssertEqual(
            current.minimumClientProtocolRevision,
            MimiProtocolContract.minimumSupportedClientRevision
        )
        XCTAssertEqual(current.platform, "darwin")
        XCTAssertEqual(Set(current.capabilities), MimiProtocolContract.declaredCapabilities)
        XCTAssertEqual(
            current.capabilityNegotiation.decision(for: "file_upload_v1"),
            .enabled
        )
        XCTAssertEqual(
            current.capabilityNegotiation.decision(
                for: SessionStore.codexRemoteFullAccessCapability
            ),
            .enabled
        )
        XCTAssertNoThrow(try current.requireCompatible())

        let previous = try decodeVersionFixture("version-previous.json")
        XCTAssertEqual(previous.protocolRevision, MimiProtocolContract.legacyServerRevision)
        XCTAssertEqual(
            previous.minimumClientProtocolRevision,
            MimiProtocolContract.minimumSupportedClientRevision
        )
        XCTAssertNil(previous.platform)
        XCTAssertTrue(previous.capabilities.isEmpty, "旧服务缺少 capability 时必须安全降级为空集合")
        XCTAssertEqual(
            previous.capabilityNegotiation.decision(for: "file_upload_v1"),
            .serverUnsupported
        )
        XCTAssertEqual(
            previous.capabilityNegotiation.decision(
                for: SessionStore.codexRemoteFullAccessCapability
            ),
            .serverUnsupported
        )
        XCTAssertNoThrow(try previous.requireCompatible())

        let incompatible = try decodeVersionFixture("version-incompatible.json")
        XCTAssertThrowsError(try incompatible.requireCompatible()) { error in
            guard case ProtocolCompatibilityError.clientTooOld(
                let clientRevision,
                let minimumClientRevision,
                let serverRevision
            ) = error else {
                return XCTFail("不兼容服务端应返回可诊断的版本错误，实际为 \(error)")
            }
            XCTAssertEqual(clientRevision, MimiProtocolContract.currentRevision)
            XCTAssertEqual(minimumClientRevision, 3)
            XCTAssertEqual(serverRevision, 3)
            XCTAssertTrue(error.localizedDescription.contains("3"))
        }

        let future = try decodeVersionFixture("version-unknown-capability.json")
        XCTAssertNoThrow(try future.requireCompatible())
        XCTAssertEqual(future.capabilities, ["future_safe_path_v2"])
        XCTAssertEqual(
            future.capabilityNegotiation.decision(for: "file_upload_v1"),
            .serverUnsupported,
            "未知 capability/state 不能意外打开当前客户端的文件上传路径"
        )
    }

    @MainActor
    func testLegacyAgentDOnlyDowngradesNoApprovalPolicy() {
        var fullAccess = CodexAppServerTurnOptions.default
        fullAccess.approvalPolicy = .never
        fullAccess.approvalsReviewer = "user"
        fullAccess.sandboxMode = .dangerFullAccess

        let legacy = fullAccess.adjustedForRemoteNoApprovalSupport(false)
        XCTAssertEqual(legacy.approvalPolicy, .onRequest)
        XCTAssertEqual(legacy.sandboxMode, .dangerFullAccess)
        XCTAssertEqual(legacy.approvalsReviewer, "user")

        let current = fullAccess.adjustedForRemoteNoApprovalSupport(true)
        XCTAssertEqual(current.approvalPolicy, .never)
        XCTAssertEqual(current.sandboxMode, .dangerFullAccess)

        var workspace = CodexAppServerTurnOptions.default
        workspace.approvalPolicy = .onRequest
        workspace.sandboxMode = .workspaceWrite
        XCTAssertEqual(
            workspace.adjustedForRemoteNoApprovalSupport(false),
            workspace
        )

        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        appStore.replaceCapabilityNegotiation(
            HostCapabilityNegotiation(wasNegotiated: true, declared: [], statuses: []),
            preserving: appStore.activeHostState
        )
        let legacyPayload = store.payloadApplyingRemoteNoApprovalCompatibility(
            CodexAppServerTurnPayload(prompt: "兼容旧 Mac", options: fullAccess)
        )
        XCTAssertEqual(legacyPayload.options.approvalPolicy, .onRequest)
        XCTAssertEqual(legacyPayload.options.sandboxMode, .dangerFullAccess)

        appStore.replaceCapabilityNegotiation(
            HostCapabilityNegotiation(
                wasNegotiated: true,
                declared: [SessionStore.codexRemoteFullAccessCapability],
                statuses: []
            ),
            preserving: appStore.activeHostState
        )
        let currentPayload = store.payloadApplyingRemoteNoApprovalCompatibility(
            CodexAppServerTurnPayload(prompt: "使用新版 Mac", options: fullAccess)
        )
        XCTAssertEqual(currentPayload.options.approvalPolicy, .never)
        XCTAssertEqual(currentPayload.options.sandboxMode, .dangerFullAccess)
    }

    func testVersionAndPairingResponsesDecodeOptionalTailscaleMetadata() throws {
        let current = try AgentAPIClient.decoder.decode(
            VersionResponse.self,
            from: Data(
                #"{"name":"agentd","version":"test","installation_id":"installation-a","tailscale_dns_name":"Studio.tailnet.ts.net.","tailscale_device_name":"Studio","protocol_revision":2,"minimum_client_protocol_revision":1,"capabilities":[]}"#.utf8
            )
        )
        let legacy = try AgentAPIClient.decoder.decode(
            VersionResponse.self,
            from: Data(#"{"name":"agentd","version":"old"}"#.utf8)
        )
        let claim = try AgentAPIClient.decoder.decode(
            PairingClaimResponse.self,
            from: Data(
                #"{"endpoint":"http://100.64.0.10:8787","token":"secret","tailscale_dns_name":"studio.tailnet.ts.net","tailscale_device_name":"studio"}"#.utf8
            )
        )

        XCTAssertEqual(current.tailscaleDNSName, "studio.tailnet.ts.net")
        XCTAssertEqual(current.tailscaleDeviceName, "Studio")
        XCTAssertNil(legacy.tailscaleDNSName)
        XCTAssertNil(legacy.tailscaleDeviceName)
        XCTAssertEqual(claim.tailscaleDNSName, "studio.tailnet.ts.net")
        XCTAssertEqual(claim.tailscaleDeviceName, "studio")
    }

    func testSharedClientMatrixMatchesGeneratedRESTAndWebSocketHeaders() throws {
        let matrix = try JSONDecoder().decode(
            [ClientCompatibilityFixture].self,
            from: try fixtureData("client-matrix.json")
        )
        let current = try XCTUnwrap(matrix.first { $0.name == "current_client_current_server" })
        XCTAssertEqual(current.protocolRevision, MimiProtocolContract.currentRevision)
        XCTAssertEqual(
            current.minimumServerProtocolRevision,
            MimiProtocolContract.minimumSupportedServerRevision
        )
        XCTAssertEqual(current.expectedStatus, 200)

        var request = URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:8787/api/app-server/ws")))
        MimiProtocolContract.applyClientHeaders(to: &request)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: MimiProtocolContract.clientRevisionHeader),
            String(try XCTUnwrap(current.protocolRevision))
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: MimiProtocolContract.minimumServerRevisionHeader),
            String(try XCTUnwrap(current.minimumServerProtocolRevision))
        )

        let previous = try XCTUnwrap(matrix.first { $0.name == "previous_client_current_server" })
        XCTAssertNil(previous.protocolRevision)
        XCTAssertNil(previous.minimumServerProtocolRevision)
        XCTAssertEqual(previous.expectedStatus, 200)

        let rejected = try XCTUnwrap(matrix.first { $0.name == "newer_client_requires_newer_server" })
        XCTAssertEqual(rejected.expectedStatus, 426)
        XCTAssertEqual(rejected.expectedCode, "protocol_incompatible")
    }

    func testWebSocketUpgradeFailureKeepsDiagnosticProtocolWindow() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:8787/api/app-server/ws"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 426,
            httpVersion: "HTTP/1.1",
            headerFields: [
                MimiProtocolContract.serverRevisionHeader: "2",
                MimiProtocolContract.minimumClientRevisionHeader: "1",
            ]
        ))

        let mapped = URLSessionCodexAppServerTransport.mappedTaskError(
            URLError(.badServerResponse),
            response: response
        )
        guard case AgentAPIError.server(let status, let message) = mapped else {
            return XCTFail("426 WebSocket 握手应保留为可诊断协议错误，实际为 \(mapped)")
        }
        XCTAssertEqual(status, 426)
        XCTAssertTrue(message.contains("agentd revision=2"))
        XCTAssertTrue(message.contains(String(MimiProtocolContract.currentRevision)))
    }

    func testCriticalJourneyFixtureMatchesIOSRequestBuilders() throws {
        let fixture = try criticalJourneyContractFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.rest.pairClaim.method, "POST")
        XCTAssertEqual(fixture.rest.pairClaim.path, "/api/pair/claim")
        XCTAssertFalse(fixture.rest.pairClaim.requiresAuth)
        XCTAssertEqual(fixture.webSocket.path, "/api/app-server/ws")
        XCTAssertTrue(fixture.webSocket.requiresAuth)

        let project = AgentProject(
            id: "critical-journey",
            name: "Critical Journey",
            path: "/tmp/critical-journey"
        )
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        let actualClientMethods = [
            try builder.threadList(cwd: project.path).method,
            builder.threadRead(threadID: "thread-critical").method,
            try builder.threadResume(
                threadID: "thread-critical",
                cwd: project.path
            ).method,
            try builder.turnStart(
                threadID: "thread-critical",
                cwd: project.path,
                prompt: "继续"
            ).method,
            builder.turnInterrupt(
                threadID: "thread-critical",
                turnID: "turn-critical"
            ).method,
        ]
        XCTAssertEqual(actualClientMethods, fixture.webSocket.clientMethods)
        XCTAssertEqual(
            Set(fixture.webSocket.serverRequestMethods),
            [
                "item/commandExecution/requestApproval",
                "item/tool/requestUserInput",
            ]
        )
        XCTAssertEqual(
            fixture.webSocket.resolutionNotification,
            "serverRequest/resolved"
        )
    }

    private func decodeVersionFixture(_ name: String) throws -> VersionResponse {
        try AgentAPIClient.decoder.decode(VersionResponse.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return try Data(
            contentsOf: root
                .appendingPathComponent("contracts")
                .appendingPathComponent("mimi-protocol")
                .appendingPathComponent("fixtures")
                .appendingPathComponent(name)
        )
    }
}

struct CriticalJourneyContractFixture: Decodable {
    struct REST: Decodable {
        struct PairClaim: Decodable {
            let method: String
            let path: String
            let requiresAuth: Bool

            enum CodingKeys: String, CodingKey {
                case method
                case path
                case requiresAuth = "requires_auth"
            }
        }

        let pairClaim: PairClaim

        enum CodingKeys: String, CodingKey {
            case pairClaim = "pair_claim"
        }
    }

    struct WebSocket: Decodable {
        let path: String
        let requiresAuth: Bool
        let clientMethods: [String]
        let serverRequestMethods: [String]
        let resolutionNotification: String

        enum CodingKeys: String, CodingKey {
            case path
            case requiresAuth = "requires_auth"
            case clientMethods = "client_methods"
            case serverRequestMethods = "server_request_methods"
            case resolutionNotification = "resolution_notification"
        }
    }

    let schemaVersion: Int
    let rest: REST
    let webSocket: WebSocket

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rest
        case webSocket = "websocket"
    }
}

func criticalJourneyContractFixture() throws -> CriticalJourneyContractFixture {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 {
        root.deleteLastPathComponent()
    }
    let data = try Data(
        contentsOf: root
            .appendingPathComponent("contracts")
            .appendingPathComponent("mimi-protocol")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("critical-journey.json")
    )
    return try JSONDecoder().decode(CriticalJourneyContractFixture.self, from: data)
}

private struct ClientCompatibilityFixture: Decodable {
    let name: String
    let protocolRevision: Int?
    let minimumServerProtocolRevision: Int?
    let expectedStatus: Int
    let expectedCode: String

    enum CodingKeys: String, CodingKey {
        case name
        case protocolRevision = "protocol_revision"
        case minimumServerProtocolRevision = "minimum_server_protocol_revision"
        case expectedStatus = "expected_status"
        case expectedCode = "expected_code"
    }
}

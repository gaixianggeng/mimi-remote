import Foundation
import XCTest
@testable import MimiRemote

/// 这组测试锁定移动端到 agentd 的 REST 请求契约。
///
/// 上层 SessionStore 测试会注入 mock API；这里专门拦截真实 URLSession 请求，
/// 以便后端路由、鉴权、字段名或危险操作确认参数发生漂移时立即失败。
final class AgentAPIClientRequestTests: XCTestCase {
    func testEveryRESTRequestMatchesAgentDContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentAPIRequestStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let client = AgentAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "mobile-contract-token",
            session: session
        )
        let workspacePath = "/Users/demo/project"
        let criticalJourney = try criticalJourneyContractFixture()

        let contracts: [RESTRequestContract] = [
            .init("health", path: "/healthz", method: "GET", requiresAuth: false) { client in
                _ = try await client.health()
            },
            .init(
                "pair claim",
                path: criticalJourney.rest.pairClaim.path,
                method: criticalJourney.rest.pairClaim.method,
                requiresAuth: criticalJourney.rest.pairClaim.requiresAuth,
                json: [
                    "endpoint": "http://100.64.0.8:8787",
                    "issued_at": "2026-07-23T10:00:00Z",
                    "expires_at": "2026-07-23T10:10:00Z",
                    "pair_sig": "signed-ticket"
                ]
            ) { client in
                _ = try await client.claimPairing(PairingClaimRequest(
                    endpoint: "http://100.64.0.8:8787",
                    issuedAt: "2026-07-23T10:00:00Z",
                    expiresAt: "2026-07-23T10:10:00Z",
                    pairSignature: "signed-ticket"
                ))
            },
            .init(
                "local pair claim",
                path: "/api/pair/local",
                method: "POST",
                requiresAuth: false,
                timeout: 2,
                headers: ["X-Mimi-Local-Pairing": "1"]
            ) { client in
                _ = try await client.claimLocalPairing()
            },
            .init("version", path: "/api/version", method: "GET") { client in
                _ = try await client.version()
            },
            .init("app-server config", path: "/api/app-server/config", method: "GET") { client in
                _ = try await client.appServerConfig()
            },
            .init(
                "external activity",
                path: "/api/app-server/external-activity",
                method: "GET",
                timeout: 10
            ) { client in
                _ = try await client.externalActivities()
            },
            .init(
                "thread handoff",
                path: "/api/app-server/thread-handoff",
                method: "POST",
                json: ["thread_id": "thread-contract"]
            ) { client in
                _ = try await client.scheduleThreadHandoff(threadID: "thread-contract")
            },
            .init("relay diagnostics", path: "/api/diagnostics/relay", method: "GET") { client in
                _ = try await client.relayDiagnostics()
            },
            .init("tailscale path diagnostics", path: "/api/diagnostics/tailscale-path", method: "GET") { client in
                _ = try await client.tailscaleNetworkPath()
            },
            .init(
                "capability list",
                path: "/api/capabilities/list",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.capabilities(path: workspacePath)
            },
            .init("projects", path: "/api/projects", method: "GET") { client in
                _ = try await client.projects()
            },
            .init(
                "workspace resolve",
                path: "/api/workspaces/resolve",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.resolveWorkspace(path: workspacePath)
            },
            .init(
                "worktree create",
                path: "/api/worktrees/create",
                method: "POST",
                json: [
                    "path": workspacePath,
                    "name": "feature",
                    "base": "main",
                    "branch": "codex/contracts"
                ]
            ) { client in
                _ = try await client.createWorktree(
                    path: workspacePath,
                    name: "feature",
                    base: "main",
                    branch: "codex/contracts"
                )
            },
            .init(
                "worktree branches",
                path: "/api/worktrees/branches",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.worktreeBranches(path: workspacePath)
            },
            .init("worktree list", path: "/api/worktrees/list", method: "GET") { client in
                _ = try await client.listWorktrees()
            },
            .init(
                "worktree delete",
                path: "/api/worktrees/delete",
                method: "POST",
                json: ["path": workspacePath, "force": true]
            ) { client in
                _ = try await client.deleteWorktree(path: workspacePath, force: true)
            },
            .init("worktree prune", path: "/api/worktrees/prune", method: "POST") { client in
                _ = try await client.pruneMissingWorktrees()
            },
            .init(
                "worktree cleanup preview",
                path: "/api/worktrees/cleanup",
                method: "POST",
                json: [:]
            ) { client in
                _ = try await client.previewWorktreeCleanup()
            },
            .init(
                "worktree cleanup execute",
                path: "/api/worktrees/cleanup",
                method: "POST",
                json: [
                    "dry_run": false,
                    "confirm": true,
                    "paths": ["/Users/demo/worktrees/old"],
                    "plan_id": "cleanup-plan"
                ]
            ) { client in
                _ = try await client.executeWorktreeCleanup(
                    paths: ["/Users/demo/worktrees/old"],
                    planID: "cleanup-plan"
                )
            },
            .init(
                "directory list",
                path: "/api/directories/list",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.listDirectories(path: workspacePath)
            },
            .init(
                "file read",
                path: "/api/files/read",
                method: "POST",
                json: ["path": workspacePath + "/README.md"]
            ) { client in
                _ = try await client.readFile(path: workspacePath + "/README.md")
            },
            .init(
                "history media",
                path: "/api/app-server/history-media/media%2Fone%3Ftwo",
                method: "GET",
                requiresEncodedPath: true
            ) { client in
                _ = try await client.readHistoryMedia(id: "media/one?two")
            },
            .init(
                "history output",
                path: "/api/app-server/history-output/output%2Fone%3Ftwo",
                method: "GET",
                requiresEncodedPath: true
            ) { client in
                _ = try await client.readHistoryOutput(id: "output/one?two")
            },
            .init(
                "command action list",
                path: "/api/actions/list",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.commandActions(path: workspacePath)
            },
            .init(
                "command action run",
                path: "/api/actions/run",
                method: "POST",
                json: ["path": workspacePath, "id": "lint", "confirmed": true]
            ) { client in
                _ = try await client.runCommandAction(path: workspacePath, id: "lint", confirmed: true)
            },
            .init(
                "git status",
                path: "/api/git/status",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.gitStatus(path: workspacePath)
            },
            .init(
                "git status summary",
                path: "/api/git/status",
                method: "POST",
                json: ["path": workspacePath, "summary_only": true]
            ) { client in
                _ = try await client.gitStatus(path: workspacePath, summaryOnly: true)
            },
            .init(
                "git file action",
                path: "/api/git/action",
                method: "POST",
                json: ["path": workspacePath, "action": "stage", "files": ["README.md"]]
            ) { client in
                _ = try await client.gitAction(path: workspacePath, action: .stage, files: ["README.md"])
            },
            .init(
                "git patch action",
                path: "/api/git/action",
                method: "POST",
                json: [
                    "path": workspacePath,
                    "action": "stage_patch",
                    "files": [],
                    "patch": "@@ -1 +1 @@\n-old\n+new\n"
                ]
            ) { client in
                _ = try await client.gitPatchAction(
                    path: workspacePath,
                    action: .stagePatch,
                    patch: "@@ -1 +1 @@\n-old\n+new\n"
                )
            },
            .init(
                "git commit",
                path: "/api/git/commit",
                method: "POST",
                json: ["path": workspacePath, "message": "test: lock API contract"]
            ) { client in
                _ = try await client.gitCommit(path: workspacePath, message: "test: lock API contract")
            },
            .init(
                "git push",
                path: "/api/git/push",
                method: "POST",
                json: ["path": workspacePath, "remote": "origin"]
            ) { client in
                _ = try await client.gitPush(path: workspacePath, remote: "origin")
            },
            .init(
                "git quick publish",
                path: "/api/git/quick-publish",
                method: "POST",
                timeout: 90,
                json: [
                    "path": workspacePath,
                    "message": "feat: publish",
                    "remote": "origin",
                    "confirmed": true
                ]
            ) { client in
                _ = try await client.gitQuickPublish(
                    path: workspacePath,
                    message: "feat: publish",
                    remote: "origin",
                    confirmed: true
                )
            },
            .init(
                "git TestFlight status",
                path: "/api/git/testflight/status",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.gitTestFlightStatus(path: workspacePath)
            },
            .init(
                "git TestFlight run",
                path: "/api/git/testflight/run",
                method: "POST",
                json: [
                    "path": workspacePath,
                    "what_to_test": "Verify request contracts",
                    "confirmed": true
                ]
            ) { client in
                _ = try await client.gitTestFlightRun(
                    path: workspacePath,
                    whatToTest: "Verify request contracts",
                    confirmed: true
                )
            },
            .init(
                "git pull request create",
                path: "/api/git/pull-request",
                method: "POST",
                json: [
                    "path": workspacePath,
                    "title": "Contract coverage",
                    "body": "Body",
                    "draft": true
                ]
            ) { client in
                _ = try await client.gitCreatePullRequest(
                    path: workspacePath,
                    title: "Contract coverage",
                    body: "Body",
                    draft: true
                )
            },
            .init(
                "git pull request status",
                path: "/api/git/pull-request/status",
                method: "POST",
                json: ["path": workspacePath]
            ) { client in
                _ = try await client.gitPullRequestStatus(path: workspacePath)
            },
            .init(
                "voice transcription",
                path: "/api/voice/transcribe",
                method: "POST",
                timeout: 60,
                json: [
                    "filename": "voice.m4a",
                    "content_type": "audio/mp4",
                    "audio_base64": "aGVsbG8=",
                    "language": "zh-CN"
                ]
            ) { client in
                _ = try await client.transcribeVoice(
                    filename: "voice.m4a",
                    contentType: "audio/mp4",
                    audioData: Data("hello".utf8),
                    language: "zh-CN"
                )
            }
        ]

        for contract in contracts {
            AgentAPIRequestStubURLProtocol.reset()

            do {
                try await contract.perform(client)
                XCTFail("\(contract.name) 应收到测试桩的 500 响应")
            } catch let error as AgentAPIError {
                guard case .server(let status, _) = error else {
                    XCTFail("\(contract.name) 应保留 HTTP 服务端错误，实际为 \(error)")
                    continue
                }
                XCTAssertEqual(status, 500, "\(contract.name) 不应在发送前失败")
            }

            let request = try XCTUnwrap(
                AgentAPIRequestStubURLProtocol.lastRequest(),
                "\(contract.name) 没有发出 HTTP 请求"
            )
            assert(request, matches: contract)
        }
    }

    func testThreadHandoffDecodesResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadHandoffResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let client = AgentAPIClient(
            endpoint: "http://127.0.0.1:8787",
            token: "mobile-contract-token",
            session: session
        )
        let response = try await client.scheduleThreadHandoff(threadID: "thread-response")

        XCTAssertEqual(response.threadID, "thread-response")
        XCTAssertEqual(response.status, .scheduled)
        let request = try XCTUnwrap(ThreadHandoffResponseURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.path, "/api/app-server/thread-handoff")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: object).isEqual(to: ["thread_id": "thread-response"]))
    }

    private func assert(_ request: URLRequest, matches contract: RESTRequestContract) {
        XCTAssertEqual(request.url?.host, "127.0.0.1", "\(contract.name) host")
        XCTAssertEqual(request.url?.port, 8787, "\(contract.name) port")
        if contract.requiresEncodedPath {
            let percentEncodedPath = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
            }
            XCTAssertEqual(percentEncodedPath, contract.path, "\(contract.name) percent-encoded path")
        } else {
            XCTAssertEqual(request.url?.path, contract.path, "\(contract.name) path")
        }
        XCTAssertEqual(request.httpMethod, contract.method, "\(contract.name) method")
        XCTAssertEqual(request.timeoutInterval, contract.timeout, accuracy: 0.01, "\(contract.name) timeout")

        if contract.requiresAuth {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mobile-contract-token", "\(contract.name) auth")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: MimiProtocolContract.clientRevisionHeader),
                String(MimiProtocolContract.currentRevision),
                "\(contract.name) client protocol revision"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: MimiProtocolContract.minimumServerRevisionHeader),
                String(MimiProtocolContract.minimumSupportedServerRevision),
                "\(contract.name) minimum server protocol revision"
            )
        } else {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "\(contract.name) 不应携带长期访问码")
            XCTAssertNil(
                request.value(forHTTPHeaderField: MimiProtocolContract.clientRevisionHeader),
                "\(contract.name) 未认证入口不应协商业务协议"
            )
            XCTAssertNil(
                request.value(forHTTPHeaderField: MimiProtocolContract.minimumServerRevisionHeader),
                "\(contract.name) 未认证入口不应协商业务协议"
            )
        }
        for (field, value) in contract.headers {
            XCTAssertEqual(request.value(forHTTPHeaderField: field), value, "\(contract.name) \(field)")
        }

        guard let expectedJSON = contract.json else {
            XCTAssertNil(request.httpBody, "\(contract.name) 不应发送 JSON body")
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"), "\(contract.name) 不应声明 JSON body")
            return
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "\(contract.name) content type")
        let body = request.httpBody ?? Data()
        do {
            let actual = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertNotNil(actual, "\(contract.name) body 必须是 JSON object")
            if let actual {
                XCTAssertTrue(
                    NSDictionary(dictionary: actual).isEqual(to: expectedJSON),
                    "\(contract.name) JSON 不匹配，actual=\(actual), expected=\(expectedJSON)"
                )
            }
        } catch {
            XCTFail("\(contract.name) body 不能解析为 JSON：\(error)")
        }
    }
}

private struct RESTRequestContract {
    let name: String
    let path: String
    let method: String
    let requiresAuth: Bool
    let requiresEncodedPath: Bool
    let timeout: TimeInterval
    let headers: [String: String]
    let json: [String: Any]?
    let perform: (AgentAPIClient) async throws -> Void

    init(
        _ name: String,
        path: String,
        method: String,
        requiresAuth: Bool = true,
        requiresEncodedPath: Bool = false,
        timeout: TimeInterval = 20,
        headers: [String: String] = [:],
        json: [String: Any]? = nil,
        perform: @escaping (AgentAPIClient) async throws -> Void
    ) {
        self.name = name
        self.path = path
        self.method = method
        self.requiresAuth = requiresAuth
        self.requiresEncodedPath = requiresEncodedPath
        self.timeout = timeout
        self.headers = headers
        self.json = json
        self.perform = perform
    }
}

private final class AgentAPIRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func reset() {
        lock.withLock { request = nil }
    }

    func record(_ request: URLRequest) {
        lock.withLock { self.request = request }
    }

    func lastRequest() -> URLRequest? {
        lock.withLock { request }
    }
}

private final class AgentAPIRequestStubURLProtocol: URLProtocol {
    private static let recorder = AgentAPIRequestRecorder()

    static func reset() {
        recorder.reset()
    }

    static func lastRequest() -> URLRequest? {
        recorder.lastRequest()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // URLSession 在部分平台会把 JSON 放进 httpBodyStream；统一还原到 httpBody，
        // 才能让契约测试真实校验每个请求的 payload，而不是依赖平台实现细节。
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            capturedRequest.httpBody = Self.readAll(from: stream)
        }
        Self.recorder.record(capturedRequest)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"request contract captured"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// 成功响应只用于锁定 handoff DTO 的解码，不改变上面的“所有契约都必须发出请求”桩。
private final class ThreadHandoffResponseURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestStorage: URLRequest?

    static func lastRequest() -> URLRequest? {
        lock.withLock { requestStorage }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            capturedRequest.httpBody = Self.readAll(from: stream)
        }
        Self.lock.withLock { Self.requestStorage = capturedRequest }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"thread_id":"thread-response","status":"scheduled"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

import Combine
import XCTest
@testable import MimiRemote

@MainActor
final class SessionStorePermissionUpdateTests: XCTestCase {
    func testExistingCodexSessionUpdatesCapturedThreadImmediately() async throws {
        let client = PermissionUpdateClient()
        let store = makeStore(client: client)
        let updated = expectation(description: "permission update sent")
        client.onUpdate = { updated.fulfill() }
        let codex = makeSession(
            id: "thread-codex",
            projectID: "project",
            title: "Codex",
            status: "idle",
            source: "codex"
        )
        let claude = makeSession(
            id: "thread-claude",
            projectID: "project",
            title: "Claude",
            status: "idle",
            source: "claude",
            runtimeProvider: "claude"
        )
        store.upsert(codex)
        store.upsert(claude)
        store.setSelectedSessionID(codex.id)

        var options = CodexAppServerTurnOptions.default
        ComposerPermissionMode.fullAccess.apply(to: &options)
        store.updateSelectedThreadPermissionsForNextTurn(options)
        store.setSelectedSessionID(claude.id)

        await fulfillment(of: [updated], timeout: 1)
        let update = try XCTUnwrap(client.recordedUpdates.first)
        XCTAssertEqual(update.threadID, codex.id)
        XCTAssertEqual(update.options, options)
    }

    func testLocalAndClaudeSessionsDoNotUpdateRemotePermissions() async {
        let client = PermissionUpdateClient()
        let store = makeStore(client: client)
        let local = makeSession(
            id: "local:draft",
            projectID: "project",
            title: "Draft",
            status: "draft",
            source: "local"
        )
        let claude = makeSession(
            id: "thread-claude",
            projectID: "project",
            title: "Claude",
            status: "idle",
            source: "claude",
            runtimeProvider: "claude"
        )
        store.upsert(local)
        store.upsert(claude)

        store.setSelectedSessionID(local.id)
        store.updateSelectedThreadPermissionsForNextTurn(.default)
        store.setSelectedSessionID(claude.id)
        store.updateSelectedThreadPermissionsForNextTurn(.default)

        XCTAssertEqual(client.recordedUpdates.count, 0)
    }

    func testPayloadResolutionPreservesExplicitNoApprovalPermissions() async {
        let client = PermissionUpdateClient()
        let store = makeStore(client: client)
        var options = CodexAppServerTurnOptions.default
        options.model = "custom-model"
        options.modelSelectionPolicy = .allowUnlisted
        ComposerPermissionMode.fullAccess.apply(to: &options)

        let resolved = await store.payloadResolvingRequiredModel(
            CodexAppServerTurnPayload(prompt: "test", options: options)
        )

        XCTAssertEqual(resolved.options.approvalPolicy, .never)
        XCTAssertEqual(resolved.options.sandboxMode, .dangerFullAccess)
    }

    func testPermissionUpdateFailureSetsExistingErrorMessage() async {
        let client = PermissionUpdateClient()
        client.updateError = PermissionUpdateTestError.failed
        let store = makeStore(client: client)
        let codex = makeSession(
            id: "thread-codex-failure",
            projectID: "project",
            title: "Codex",
            status: "idle",
            source: "codex"
        )
        store.upsert(codex)
        store.setSelectedSessionID(codex.id)
        let errorShown = expectation(description: "permission update error shown")
        let observation = store.$errorMessage
            .compactMap { $0 }
            .filter { $0 == PermissionUpdateTestError.failed.localizedDescription }
            .sink { _ in errorShown.fulfill() }

        store.updateSelectedThreadPermissionsForNextTurn(.default)

        await fulfillment(of: [errorShown], timeout: 1)
        XCTAssertEqual(store.errorMessage, PermissionUpdateTestError.failed.localizedDescription)
        withExtendedLifetime(observation) {}
    }

    private func makeStore(client: PermissionUpdateClient) -> SessionStore {
        SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
    }
}

private final class PermissionUpdateClient: SessionStoreAPIClient {
    struct Update {
        let threadID: String
        let options: CodexAppServerTurnOptions
    }

    private let lock = NSLock()
    private var updates: [Update] = []
    var onUpdate: (() -> Void)?
    var updateError: Error?

    var recordedUpdates: [Update] {
        lock.withLock { updates }
    }

    func updateThreadPermissions(threadID: String, options: CodexAppServerTurnOptions) async throws {
        let update = Update(threadID: threadID, options: options)
        lock.withLock {
            updates.append(update)
        }
        onUpdate?()
        if let updateError {
            throw updateError
        }
    }

    func projects() async throws -> [AgentProject] { [] }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] { [] }
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw AgentAPIError.invalidResponse
    }
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw AgentAPIError.invalidResponse
    }
    func stopSession(id: String) async throws {}
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] { [] }
}

private enum PermissionUpdateTestError: LocalizedError {
    case failed

    var errorDescription: String? { "permission update failed" }
}

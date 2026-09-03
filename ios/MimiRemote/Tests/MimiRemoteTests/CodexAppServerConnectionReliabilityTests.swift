import XCTest
@testable import MimiRemote

private actor ConnectionWaiterCompletionProbe {
    private(set) var completed = false
    func markCompleted() { completed = true }
}

private actor CancelBeforeWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

final class CodexAppServerConnectionReliabilityTests: XCTestCase {
    func testCancellingOneConnectionWaiterDoesNotCancelSharedCandidate() async throws {
        let project = AgentProject(id: "reliability", name: "Reliability", path: "/tmp/reliability")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:7777",
            token: "token",
            transportFactory: { pool.make() },
            requestTimeout: 2,
            configProvider: { makeDirectAppServerConfig(project: project) }
        )

        let first = Task { try await runtime.ensureConnection() }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: 0)
        _ = try await waitForFakeAppServerMessages(transport, count: 1)
        let second = Task { try await runtime.ensureConnection() }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()

        let completionProbe = ConnectionWaiterCompletionProbe()
        let cancelledWaiter = Task {
            defer { Task { await completionProbe.markCompleted() } }
            return try await first.value
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let didCompleteCancellation = await completionProbe.completed
        let closeCountBeforeInitialize = await transport.closeCallCount()
        XCTAssertTrue(didCompleteCancellation, "cancelled waiter must return before initialize completes")
        XCTAssertEqual(closeCountBeforeInitialize, 0, "another waiter still owns the candidate")
        XCTAssertNil(pool.transport(at: 1), "single-flight must create only one transport")

        let initialize = try decodeAppServerRequest((await transport.sentMessages())[0])
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{}}"#)
        _ = try await second.value
        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected the cancelled waiter to stop")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        await runtime.cancelConnectionAttempt()
    }

    func testNullIDUpstreamErrorRetiresConnectionAndPreservesReason() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        try await connectFakeAppServer(connection, transport: transport)

        let requestTask = Task {
            try await connection.send(CodexAppServerRequestSpec(method: "thread/list"))
        }
        _ = try await waitForFakeAppServerMessages(transport, count: 3)
        transport.enqueue(#"{"id":null,"error":{"code":-32098,"message":"upstream unavailable","data":{"reason":"codex_upstream_unavailable"}}}"#)

        do {
            _ = try await requestTask.value
            XCTFail("Expected uncertain request outcome")
        } catch CodexAppServerConnectionError.outcomeUnknown(let method, _, let cause) {
            XCTAssertEqual(method, "thread/list")
            XCTAssertTrue(cause.contains(L10n.text("ui.codex_upstream_unavailable")))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let isReady = await connection.isReadyForRequests()
        let closeCallCount = await transport.closeCallCount()
        XCTAssertFalse(isReady)
        XCTAssertGreaterThanOrEqual(closeCallCount, 1)
    }

    func testCancellationAfterWriteStartedReturnsOutcomeUnknownAndIgnoresLateResponse() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        try await connectFakeAppServer(connection, transport: transport)

        let task = Task {
            try await connection.send(CodexAppServerRequestSpec(method: "turn/steer"))
        }
        let messages = try await waitForFakeAppServerMessages(transport, count: 3)
        let request = try decodeAppServerRequest(messages[2])
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected uncertain request outcome")
        } catch CodexAppServerConnectionError.outcomeUnknown(let method, let id, _) {
            XCTAssertEqual(method, "turn/steer")
            XCTAssertEqual(id, request.id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        transport.enqueue(#"{"id":\#(try jsonFragment(for: request.id)),"result":{}}"#)
        try await Task.sleep(nanoseconds: 20_000_000)
        let isReady = await connection.isReadyForRequests()
        let sentCount = await transport.sentMessages().count
        XCTAssertTrue(isReady)
        XCTAssertEqual(sentCount, 3)
        await connection.disconnect()
    }

    func testCancellationBeforeWriteDoesNotSendRequest() async throws {
        let transport = FakeCodexAppServerTransport()
        let connection = CodexAppServerConnection(transport: transport, requestTimeout: 2)
        try await connectFakeAppServer(connection, transport: transport)

        let gate = CancelBeforeWriteGate()
        let task = Task {
            await gate.wait()
            return try await connection.send(CodexAppServerRequestSpec(method: "turn/steer"))
        }
        while !(await gate.isWaiting) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before write")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 2, "cancelled request must not reach the wire")
        await connection.disconnect()
    }
}

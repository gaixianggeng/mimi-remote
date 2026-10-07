import Network
import XCTest
@testable import MimiRemote

final class TailcatLocalEndpointProbeTests: XCTestCase {
    func testReachableLoopbackListenerReturnsTrue() async throws {
        let listener = try await ProbeTestListener.start()

        let ipv4Reachable = await TailcatLocalEndpointProbe.isReachable(
            "http://127.0.0.1:\(listener.port)"
        )
        let ipv6Reachable = await TailcatLocalEndpointProbe.isReachable(
            "http://[::1]:\(listener.port)"
        )

        XCTAssertTrue(ipv4Reachable)
        XCTAssertTrue(ipv6Reachable)
        await listener.stop()
    }

    func testClosedLoopbackListenerReturnsFalse() async throws {
        let listener = try await ProbeTestListener.start()
        let port = listener.port
        await listener.stop()

        let reachable = await TailcatLocalEndpointProbe.isReachable("http://127.0.0.1:\(port)")

        XCTAssertFalse(reachable)
    }

    func testNonLoopbackAndMissingPortAreRejected() async {
        let remote = await TailcatLocalEndpointProbe.isReachable("http://192.0.2.1:8787")
        let missingPort = await TailcatLocalEndpointProbe.isReachable("http://127.0.0.1")

        XCTAssertFalse(remote)
        XCTAssertFalse(missingPort)
    }

    func testAlreadyCancelledTaskReturnsFalse() async {
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return await TailcatLocalEndpointProbe.isReachable("http://127.0.0.1:9")
        }

        let reachable = await task.value

        XCTAssertFalse(reachable)
    }
}

private final class ProbeTestListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gaixianggeng.mimi.tailcat-probe-tests")

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    private init(listener: NWListener) {
        self.listener = listener
    }

    deinit {
        listener.cancel()
    }

    static func start() async throws -> ProbeTestListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let server = ProbeTestListener(listener: listener)
        try await server.waitUntilReady()
        return server
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state else { return }
                self?.listener.stateUpdateHandler = nil
                continuation.resume()
            }
            listener.cancel()
        }
    }

    private func waitUntilReady() async throws {
        let queue = queue
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                    connection.cancel()
                }
            }
            listener.start(queue: queue)
        }
    }
}

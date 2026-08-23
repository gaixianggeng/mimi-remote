import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class AppleVoiceStartupWatchdogTests: XCTestCase {
    func testArmInvokesOnTimeoutOnceAfterShortTimeout() async {
        let watchdog = AppleVoiceStartupWatchdog(timeout: .milliseconds(20))
        let callback = expectation(description: "startup timeout callback")
        var callbackCount = 0

        let task = watchdog.arm {
            callbackCount += 1
            callback.fulfill()
        }

        await fulfillment(of: [callback], timeout: 0.25)
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()

        XCTAssertEqual(callbackCount, 1)
    }

    func testCancellingTaskPreventsTimeoutCallback() async {
        let watchdog = AppleVoiceStartupWatchdog(timeout: .milliseconds(50))
        var callbackCount = 0

        let task = watchdog.arm {
            callbackCount += 1
        }
        task.cancel()

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(callbackCount, 0)
    }

    func testStartupTimedOutHasDiagnosticCodeAndDescription() {
        let error = AppleSpeechTranscriptionError.startupTimedOut

        XCTAssertEqual(error.diagnosticCode, "startup_timeout")
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }

    func testCancelledQueuedActivationCannotOverrideImmediateRetry() async throws {
        let backend = StartupWatchdogAudioSessionBackend()
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let waitingToActivate = expectation(description: "old request waiting")
        let (gate, releaseOldRequest) = AsyncStream<Void>.makeStream()

        let oldRequest = Task {
            waitingToActivate.fulfill()
            for await _ in gate.prefix(1) {}
            return try await coordinator.activate()
        }
        await fulfillment(of: [waitingToActivate], timeout: 0.25)

        oldRequest.cancel()
        let retry = Task {
            try await coordinator.activate()
        }
        releaseOldRequest.yield(())
        releaseOldRequest.finish()

        do {
            _ = try await oldRequest.value
            XCTFail("Cancelled request must not activate the audio session")
        } catch is CancellationError {
            // 旧请求按预期失效。
        }

        let retryActivation = try await retry.value
        XCTAssertEqual(backend.operations, [.prepare, .activate])

        await coordinator.deactivate(retryActivation)
        XCTAssertEqual(backend.operations, [.prepare, .activate, .deactivate])
    }

    func testCancellationDuringActivationIsCleanedUpBeforeRetry() async throws {
        let backend = StartupWatchdogAudioSessionBackend(blocksActivation: true)
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let oldRequest = Task {
            try await coordinator.activate()
        }

        let deadline = ContinuousClock.now + .milliseconds(250)
        while !backend.hasStartedActivation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard backend.hasStartedActivation else {
            backend.releaseActivation()
            XCTFail("Audio activation did not start")
            return
        }

        oldRequest.cancel()
        backend.releaseActivation()

        do {
            _ = try await oldRequest.value
            XCTFail("Cancelled request must not retain audio activation")
        } catch is CancellationError {
            // setActive 返回后检测到取消，并立即配对停用。
        }
        XCTAssertEqual(backend.operations, [.prepare, .activate, .deactivate])

        let retryActivation = try await coordinator.activate()
        XCTAssertEqual(backend.operations, [.prepare, .activate, .deactivate, .prepare, .activate])

        await coordinator.deactivate(retryActivation)
        XCTAssertEqual(
            backend.operations,
            [.prepare, .activate, .deactivate, .prepare, .activate, .deactivate]
        )
    }

    func testRetryDoesNotWaitForBlockedActivation() async throws {
        let backend = StartupWatchdogAudioSessionBackend(blocksActivation: true)
        defer { backend.releaseActivation() }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let oldRequest = Task {
            try await coordinator.activate()
        }

        let deadline = ContinuousClock.now + .milliseconds(250)
        while !backend.hasStartedActivation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard backend.hasStartedActivation else {
            XCTFail("Audio activation did not start")
            return
        }

        oldRequest.cancel()
        let retryCompleted = expectation(description: "retry activation completed")
        var retryActivation: VoiceAudioSessionCoordinator.Activation?
        var retryError: Error?
        let retryRequest = Task {
            do {
                retryActivation = try await coordinator.activate()
            } catch {
                retryError = error
            }
            retryCompleted.fulfill()
        }

        // 第一次 setActive 仍未返回时，重试必须通过独立执行任务完成。
        await fulfillment(of: [retryCompleted], timeout: 0.25)
        XCTAssertNil(retryError)
        XCTAssertEqual(backend.operations, [.prepare, .activate, .prepare, .activate])

        await retryRequest.value
        let activation = try XCTUnwrap(retryActivation)
        await coordinator.deactivate(activation)
        let deactivationDeadline = ContinuousClock.now + .milliseconds(250)
        while backend.operations.last != .deactivate, ContinuousClock.now < deactivationDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(
            backend.operations,
            [.prepare, .activate, .prepare, .activate, .deactivate]
        )

        backend.releaseActivation()
        do {
            _ = try await oldRequest.value
            XCTFail("Cancelled request must not retain audio activation")
        } catch is CancellationError {
            // 迟到旧请求只清理自己的遗留激活。
        }
        XCTAssertEqual(
            backend.operations,
            [.prepare, .activate, .prepare, .activate, .deactivate, .deactivate]
        )
    }

    func testOldDeactivationDoesNotInterruptPendingRetry() async throws {
        let backend = StartupWatchdogAudioSessionBackend(blockedActivationCall: 2)
        defer { backend.releaseActivation() }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let oldActivation = try await coordinator.activate()
        let retryRequest = Task {
            try await coordinator.activate()
        }

        let deadline = ContinuousClock.now + .milliseconds(250)
        while !backend.hasStartedActivation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard backend.hasStartedActivation else {
            XCTFail("Retry activation did not start")
            return
        }

        await coordinator.deactivate(oldActivation)
        XCTAssertEqual(backend.operations, [.prepare, .activate, .prepare, .activate])

        backend.releaseActivation()
        let retryActivation = try await retryRequest.value
        await coordinator.deactivate(retryActivation)
        XCTAssertEqual(
            backend.operations,
            [.prepare, .activate, .prepare, .activate, .deactivate]
        )
    }
}

private final class StartupWatchdogAudioSessionBackend: VoiceAudioSessionBackend, @unchecked Sendable {
    enum Operation: Equatable {
        case prepare
        case activate
        case deactivate
    }

    private let lock = NSLock()
    private var storedOperations: [Operation] = []
    private let blockedActivationCall: Int?
    private let activationCondition = NSCondition()
    private var activationStarted = false
    private var activationReleased = false
    private var activationCallCount = 0

    init(blocksActivation: Bool = false) {
        blockedActivationCall = blocksActivation ? 1 : nil
    }

    init(blockedActivationCall: Int) {
        self.blockedActivationCall = blockedActivationCall
    }

    var operations: [Operation] {
        lock.withLock { storedOperations }
    }

    var hasStartedActivation: Bool {
        activationCondition.lock()
        defer { activationCondition.unlock() }
        return activationStarted
    }

    func prepareForRecording() throws {
        record(.prepare)
    }

    func activateForRecording() throws {
        record(.activate)
        guard let blockedActivationCall else { return }
        activationCondition.lock()
        activationCallCount += 1
        if activationCallCount == blockedActivationCall {
            activationStarted = true
            activationCondition.broadcast()
            while !activationReleased {
                activationCondition.wait()
            }
        }
        activationCondition.unlock()
    }

    func deactivateRecording() throws {
        record(.deactivate)
    }

    private func record(_ operation: Operation) {
        lock.withLock {
            storedOperations.append(operation)
        }
    }

    func releaseActivation() {
        activationCondition.lock()
        activationReleased = true
        activationCondition.broadcast()
        activationCondition.unlock()
    }
}

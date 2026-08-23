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
        try await waitForOperations([.prepare, .activate, .deactivate], in: backend)
    }

    func testActivationDoesNotWaitForBlockedPrewarm() async throws {
        let backend = StartupWatchdogAudioSessionBackend(blockedPreparationCall: 1)
        defer { backend.releasePreparation() }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let prewarmRequest = Task {
            try await coordinator.prewarm()
        }

        let deadline = ContinuousClock.now + .milliseconds(250)
        while !backend.hasStartedPreparation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard backend.hasStartedPreparation else {
            XCTFail("Audio prewarm did not start")
            return
        }

        let activation = try await coordinator.activate()
        XCTAssertEqual(backend.operations, [.prepare, .prepare, .activate])

        backend.releasePreparation()
        try await prewarmRequest.value
        await coordinator.deactivate(activation)
        try await waitForOperations([.prepare, .prepare, .activate, .deactivate], in: backend)
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
        try await waitForOperations([.prepare, .activate, .deactivate], in: backend)

        let retryActivation = try await coordinator.activate()
        XCTAssertEqual(backend.operations, [.prepare, .activate, .deactivate, .prepare, .activate])

        await coordinator.deactivate(retryActivation)
        try await waitForOperations(
            [.prepare, .activate, .deactivate, .prepare, .activate, .deactivate],
            in: backend
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
        try await waitForOperations(
            [.prepare, .activate, .prepare, .activate, .deactivate, .deactivate],
            in: backend
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
        try await waitForOperations(
            [.prepare, .activate, .prepare, .activate, .deactivate],
            in: backend
        )
    }

    func testRetryDoesNotWaitForBlockedDeactivation() async throws {
        let backend = StartupWatchdogAudioSessionBackend(blockedDeactivationCall: 1)
        defer { backend.releaseDeactivation() }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let oldActivation = try await coordinator.activate()

        await coordinator.deactivate(oldActivation)
        let deadline = ContinuousClock.now + .milliseconds(250)
        while !backend.hasStartedDeactivation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard backend.hasStartedDeactivation else {
            XCTFail("Audio deactivation did not start")
            return
        }

        let retryCompleted = expectation(description: "retry completed during deactivation")
        let captureRecovered = expectation(description: "capture recovered after late deactivation")
        var retryActivation: VoiceAudioSessionCoordinator.Activation?
        var retryError: Error?
        let retryRequest = Task {
            do {
                retryActivation = try await coordinator.activate(onRecovery: { succeeded in
                    XCTAssertTrue(succeeded)
                    captureRecovered.fulfill()
                })
            } catch {
                retryError = error
            }
            retryCompleted.fulfill()
        }

        await fulfillment(of: [retryCompleted], timeout: 0.25)
        XCTAssertNil(retryError)
        XCTAssertEqual(
            backend.operations,
            [.prepare, .activate, .deactivate, .prepare, .activate]
        )

        backend.releaseDeactivation()
        await retryRequest.value
        try await waitForOperation(.activate, count: 3, in: backend)
        await fulfillment(of: [captureRecovered], timeout: 0.25)

        let activation = try XCTUnwrap(retryActivation)
        await coordinator.deactivate(activation)
        try await waitForOperation(.deactivate, count: 2, in: backend)
    }

    func testFailedLateDeactivationStillRefreshesCurrentActivation() async throws {
        let backend = StartupWatchdogAudioSessionBackend(
            blockedDeactivationCall: 1,
            failingDeactivationCall: 1
        )
        defer { backend.releaseDeactivation() }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let oldActivation = try await coordinator.activate()

        await coordinator.deactivate(oldActivation)
        try await waitForDeactivationStart(in: backend)

        let captureRecovered = expectation(description: "capture recovered after failed late deactivation")
        let retryActivation = try await coordinator.activate(onRecovery: { succeeded in
            XCTAssertTrue(succeeded)
            captureRecovered.fulfill()
        })

        backend.releaseDeactivation()
        try await waitForOperation(.activate, count: 3, in: backend)
        await fulfillment(of: [captureRecovered], timeout: 0.25)

        await coordinator.deactivate(retryActivation)
        try await waitForOperation(.deactivate, count: 2, in: backend)
    }

    func testPendingActivationIgnoresRefreshFailureOlderThanSuccessfulAttempt() async throws {
        let backend = StartupWatchdogAudioSessionBackend(
            blockedActivationCall: 2,
            failingActivationCall: 3,
            blockedDeactivationCall: 1
        )
        defer {
            backend.releaseActivation()
            backend.releaseDeactivation()
        }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let oldActivation = try await coordinator.activate()

        await coordinator.deactivate(oldActivation)
        try await waitForDeactivationStart(in: backend)

        var recoveryResults: [Bool] = []
        let retryRequest = Task {
            try await coordinator.activate(onRecovery: { succeeded in
                recoveryResults.append(succeeded)
            })
        }
        try await waitForActivationStart(in: backend)

        // 旧停用和失败补激活都先于待发布请求的成功 setActive；迟到失败回调不能误杀该请求。
        backend.releaseDeactivation()
        try await waitForOperation(.activate, count: 3, in: backend)
        try await Task.sleep(for: .milliseconds(40))

        backend.releaseActivation()
        let retryActivation = try await retryRequest.value
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(backend.operations.filter { $0 == .activate }.count, 3)
        XCTAssertFalse(recoveryResults.contains(false))

        await coordinator.deactivate(retryActivation)
        try await waitForOperation(.deactivate, count: 2, in: backend)
    }

    func testCancellingPendingRequestDeactivatesSuccessfulRefresh() async throws {
        let backend = StartupWatchdogAudioSessionBackend(
            blockedActivationCall: 2,
            blockedDeactivationCall: 1
        )
        defer {
            backend.releaseActivation()
            backend.releaseDeactivation()
        }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let oldActivation = try await coordinator.activate()

        await coordinator.deactivate(oldActivation)
        try await waitForDeactivationStart(in: backend)

        let retryRequest = Task {
            try await coordinator.activate()
        }
        try await waitForActivationStart(in: backend)

        // 主激活继续阻塞，旧停用落地后的补激活先成功并占用全局音频会话。
        backend.releaseDeactivation()
        try await waitForOperation(.activate, count: 3, in: backend)
        try await Task.sleep(for: .milliseconds(40))

        retryRequest.cancel()
        // 不释放主激活也必须先清理补激活，不能让 .record/.duckOthers 一直保持 active。
        try await waitForOperation(.deactivate, count: 2, in: backend)

        backend.releaseActivation()
        do {
            _ = try await retryRequest.value
            XCTFail("Cancelled request must not retain audio activation")
        } catch is CancellationError {
            // 迟到的主激活成功后还会执行自己的补偿停用。
        }
        try await waitForOperation(.deactivate, count: 3, in: backend)
    }

    func testStaleRefreshFailureDoesNotStopNewerActivation() async throws {
        let backend = StartupWatchdogAudioSessionBackend(
            blockedActivationCall: 3,
            failingActivationCall: 3,
            blockedDeactivationCall: 1
        )
        defer {
            backend.releaseActivation()
            backend.releaseDeactivation()
        }
        let coordinator = VoiceAudioSessionCoordinator(backend: backend)
        let firstActivation = try await coordinator.activate()

        await coordinator.deactivate(firstActivation)
        try await waitForDeactivationStart(in: backend)

        let secondActivation = try await coordinator.activate()
        backend.releaseDeactivation()
        try await waitForActivationStart(in: backend)

        var newestRecoveryResults: [Bool] = []
        let newestActivation = try await coordinator.activate(onRecovery: { succeeded in
            newestRecoveryResults.append(succeeded)
        })

        // 第一次补激活属于第二个租约。它迟到失败时，第三个租约已经接管，不能收到 false。
        backend.releaseActivation()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(newestRecoveryResults.contains(false))

        await coordinator.deactivate(secondActivation)
        await coordinator.deactivate(newestActivation)
        try await waitForOperation(.deactivate, count: 2, in: backend)
    }

    private func waitForOperations(
        _ expected: [StartupWatchdogAudioSessionBackend.Operation],
        in backend: StartupWatchdogAudioSessionBackend
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(250)
        while backend.operations != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(backend.operations, expected)
    }

    private func waitForOperation(
        _ operation: StartupWatchdogAudioSessionBackend.Operation,
        count: Int,
        in backend: StartupWatchdogAudioSessionBackend
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(250)
        while backend.operations.filter({ $0 == operation }).count < count,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThanOrEqual(backend.operations.filter { $0 == operation }.count, count)
    }

    private func waitForActivationStart(
        in backend: StartupWatchdogAudioSessionBackend
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(250)
        while !backend.hasStartedActivation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(backend.hasStartedActivation)
    }

    private func waitForDeactivationStart(
        in backend: StartupWatchdogAudioSessionBackend
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(250)
        while !backend.hasStartedDeactivation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(backend.hasStartedDeactivation)
    }
}

private final class StartupWatchdogAudioSessionBackend: VoiceAudioSessionBackend, @unchecked Sendable {
    enum TestError: Error {
        case activationFailed
        case deactivationFailed
    }

    enum Operation: Equatable {
        case prepare
        case activate
        case deactivate
    }

    private let lock = NSLock()
    private var storedOperations: [Operation] = []
    private let blockedPreparationCall: Int?
    private let blockedActivationCall: Int?
    private let failingActivationCall: Int?
    private let blockedDeactivationCall: Int?
    private let failingDeactivationCall: Int?
    private let preparationCondition = NSCondition()
    private var preparationStarted = false
    private var preparationReleased = false
    private var preparationCallCount = 0
    private let activationCondition = NSCondition()
    private var activationStarted = false
    private var activationReleased = false
    private var activationCallCount = 0
    private let deactivationCondition = NSCondition()
    private var deactivationStarted = false
    private var deactivationReleased = false
    private var deactivationCallCount = 0

    init(blocksActivation: Bool = false) {
        blockedPreparationCall = nil
        blockedActivationCall = blocksActivation ? 1 : nil
        failingActivationCall = nil
        blockedDeactivationCall = nil
        failingDeactivationCall = nil
    }

    init(blockedActivationCall: Int) {
        blockedPreparationCall = nil
        self.blockedActivationCall = blockedActivationCall
        failingActivationCall = nil
        blockedDeactivationCall = nil
        failingDeactivationCall = nil
    }

    init(blockedDeactivationCall: Int, failingDeactivationCall: Int? = nil) {
        blockedPreparationCall = nil
        blockedActivationCall = nil
        failingActivationCall = nil
        self.blockedDeactivationCall = blockedDeactivationCall
        self.failingDeactivationCall = failingDeactivationCall
    }

    init(blockedPreparationCall: Int) {
        self.blockedPreparationCall = blockedPreparationCall
        blockedActivationCall = nil
        failingActivationCall = nil
        blockedDeactivationCall = nil
        failingDeactivationCall = nil
    }

    init(
        blockedActivationCall: Int,
        failingActivationCall: Int,
        blockedDeactivationCall: Int
    ) {
        blockedPreparationCall = nil
        self.blockedActivationCall = blockedActivationCall
        self.failingActivationCall = failingActivationCall
        self.blockedDeactivationCall = blockedDeactivationCall
        failingDeactivationCall = nil
    }

    init(
        blockedActivationCall: Int,
        blockedDeactivationCall: Int
    ) {
        blockedPreparationCall = nil
        self.blockedActivationCall = blockedActivationCall
        failingActivationCall = nil
        self.blockedDeactivationCall = blockedDeactivationCall
        failingDeactivationCall = nil
    }

    var operations: [Operation] {
        lock.withLock { storedOperations }
    }

    var hasStartedActivation: Bool {
        activationCondition.lock()
        defer { activationCondition.unlock() }
        return activationStarted
    }

    var hasStartedPreparation: Bool {
        preparationCondition.lock()
        defer { preparationCondition.unlock() }
        return preparationStarted
    }

    var hasStartedDeactivation: Bool {
        deactivationCondition.lock()
        defer { deactivationCondition.unlock() }
        return deactivationStarted
    }

    func prepareForRecording() throws {
        record(.prepare)
        guard let blockedPreparationCall else { return }
        preparationCondition.lock()
        preparationCallCount += 1
        if preparationCallCount == blockedPreparationCall {
            preparationStarted = true
            preparationCondition.broadcast()
            while !preparationReleased {
                preparationCondition.wait()
            }
        }
        preparationCondition.unlock()
    }

    func activateForRecording() throws {
        record(.activate)
        activationCondition.lock()
        activationCallCount += 1
        let currentCall = activationCallCount
        if let blockedActivationCall,
           currentCall == blockedActivationCall {
            activationStarted = true
            activationCondition.broadcast()
            while !activationReleased {
                activationCondition.wait()
            }
        }
        activationCondition.unlock()
        if let failingActivationCall,
           currentCall == failingActivationCall {
            throw TestError.activationFailed
        }
    }

    func deactivateRecording() throws {
        record(.deactivate)
        deactivationCondition.lock()
        deactivationCallCount += 1
        let currentCall = deactivationCallCount
        if currentCall == blockedDeactivationCall {
            deactivationStarted = true
            deactivationCondition.broadcast()
            while !deactivationReleased {
                deactivationCondition.wait()
            }
        }
        deactivationCondition.unlock()
        if currentCall == failingDeactivationCall {
            throw TestError.deactivationFailed
        }
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

    func releasePreparation() {
        preparationCondition.lock()
        preparationReleased = true
        preparationCondition.broadcast()
        preparationCondition.unlock()
    }

    func releaseDeactivation() {
        deactivationCondition.lock()
        deactivationReleased = true
        deactivationCondition.broadcast()
        deactivationCondition.unlock()
    }
}

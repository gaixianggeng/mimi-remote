import XCTest
@testable import MimiRemote

// #808：等不到 turn/started 时不能把 no active turn 当成已停止，也不能静默吞掉。
extension CodexTurnInterruptBeforeStartTests {
    func testInterruptWithoutTurnStartedReportsNotAcceptedAndKeepsRunning() async throws {
        let fixture = try await makeTimeoutFixture(signalTimeout: 50_000_000)
        try await startTurnWithoutStartedNotification(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: "no active turn to interrupt")
        // 超时后仍重发一次：turn/started 可能只是丢在了连接切换里。
        let retry = try await waitForFakeAppServerRequest(
            fixture.transport, method: "turn/interrupt", after: afterEarly
        )
        transportErrorResponse(fixture.transport, id: retry.id, code: -32600, message: "no active turn to interrupt")

        do {
            try await task.value
            XCTFail("停止没有被接受时必须报错，不能静默成功")
        } catch {
            XCTAssertEqual(
                error as? CodexAppServerTurnInterruptError,
                .notAcceptedBeforeTurnStarted(fixture.session.id)
            )
            XCTAssertFalse(ControlCommandFailure.classify(error).isStaleTarget, "不能被当成目标已结束")
        }
        let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        XCTAssertEqual(active, Self.turnID)
        let lifecycles = await completedLifecycles(fixture)
        XCTAssertTrue(lifecycles.isEmpty, "停止没有生效时不能合成终态：\(lifecycles)")
    }

    func testHostShutdownReleasesPendingInterruptWait() async throws {
        let fixture = try await makeFixture()
        try await startTurnWithoutStartedNotification(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: "no active turn to interrupt")
        for _ in 0..<200 {
            let waiting = await fixture.runtime.turnStartedWaitersByToken
            if !waiting.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await fixture.runtime.shutdownForHostSwitch()

        do {
            try await task.value
            XCTFail("切换主机时等待中的停止请求必须结束并报错")
        } catch {
            XCTAssertFalse(ControlCommandFailure.classify(error).isStaleTarget)
        }
        let waiters = await fixture.runtime.turnStartedWaitersByToken
        XCTAssertTrue(waiters.isEmpty)
    }

    func testTimedOutRetryRejectedByPreviousActiveTurnStillReportsNotAccepted() async throws {
        let fixture = try await makeTimeoutFixture(
            signalTimeout: 50_000_000,
            recoveryDelays: [1_000_000],
            extraMethods: ["thread/read", "thread/turns/list"]
        )
        try await startTurnWithoutStartedNotification(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        let previousStillActive = "expected active turn id \(Self.turnID) but found turn_previous"
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: previousStillActive)
        // 等满时限后重发，上一轮仍占着 active turn：与首次拒绝同类，不能当成普通错误抛出。
        let retry = try await waitForFakeAppServerRequest(
            fixture.transport, method: "turn/interrupt", after: afterEarly
        )
        let afterRetry = await fixture.transport.sentMessages().count
        transportErrorResponse(fixture.transport, id: retry.id, code: -32600, message: previousStillActive)

        do {
            try await task.value
            XCTFail("停止没有被接受时必须报错，不能静默成功")
        } catch {
            XCTAssertEqual(
                error as? CodexAppServerTurnInterruptError,
                .notAcceptedBeforeTurnStarted(fixture.session.id)
            )
        }
        // 报告未生效的同时必须安排权威快照对账，生命周期通知漏掉时才能收敛。
        let readTurns = try await waitForOptionalRequest(fixture, method: "thread/turns/list", after: afterRetry)
        let readThread = try await waitForOptionalRequest(fixture, method: "thread/read", after: afterRetry)
        XCTAssertTrue(readTurns != nil || readThread != nil, "没有安排权威快照对账")
        let active = await fixture.runtime.contextsBySessionID[fixture.session.id]?.activeTurnID
        XCTAssertEqual(active, Self.turnID)
    }

    func testThreadClosedBeforeRejectionArrivesEndsWaitImmediately() async throws {
        // 时限放长：修复后不该等到它；未修复时等满后清理任务，避免用例挂住。
        let fixture = try await makeTimeoutFixture(signalTimeout: 2_000_000_000)
        try await startTurnWithoutStartedNotification(fixture)

        let task = Task {
            try await fixture.runtime.interruptActiveTurnRecoveringStaleTarget(
                sessionID: fixture.session.id, expectedTurnID: Self.turnID
            )
        }
        let early = try await waitForFakeAppServerRequest(fixture.transport, method: "turn/interrupt")
        let afterEarly = await fixture.transport.sentMessages().count
        // thread/closed 不带 turnId，落在拒绝回包之前：此时还没有登记等待者。
        fixture.transport.enqueue(#"{"method":"thread/closed","params":{"threadId":"\#(fixture.session.id)"}}"#)
        for _ in 0..<200 {
            let status = await fixture.runtime.contextsBySessionID[fixture.session.id]?.session.status
            if status == "closed" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        transportErrorResponse(fixture.transport, id: early.id, code: -32600, message: "no active turn to interrupt")

        let outcome = InterruptOutcomeBox()
        let watcher = Task { @MainActor in
            do {
                try await task.value
                outcome.value = "ok"
            } catch {
                outcome.value = "\(error)"
            }
        }
        for _ in 0..<50 where outcome.value == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(outcome.value, "ok", "thread/closed 已经到达：停止请求要立即结束，也不能报告停止失败")
        let resent = await fixture.transport.sentMessages()[afterEarly...]
            .compactMap { try? decodeAppServerRequest($0) }
            .contains { $0.method == "turn/interrupt" }
        XCTAssertFalse(resent, "thread 已关闭，不能再重发停止")
        if outcome.value == nil {
            // 未修复时请求会挂到时限；取消让它以 abandoned 结束，避免用例拖住。
            task.cancel()
        }
        _ = await watcher.value
    }

    func makeTimeoutFixture(
        signalTimeout: UInt64,
        recoveryDelays: [UInt64] = [],
        extraMethods: [String] = []
    ) async throws -> CodexTurnInterruptBeforeStartFixture {
        try await makeFixture { options in
            options.makeRuntime = { project, transport in
                CodexAppServerSessionRuntime(
                    endpoint: "http://127.0.0.1:8787", token: "test-token",
                    transportFactory: { transport },
                    turnInterruptRecoveryDelaysNanoseconds: recoveryDelays,
                    turnStartedSignalTimeoutNanoseconds: signalTimeout,
                    configProvider: {
                        makeDirectAppServerConfig(
                            project: project,
                            allowedMethods: CodexTurnInterruptBeforeStartFixtureOptions.allowedMethods + extraMethods
                        )
                    }
                )
            }
        }
    }
}

@MainActor
final class InterruptOutcomeBox {
    var value: String?
}

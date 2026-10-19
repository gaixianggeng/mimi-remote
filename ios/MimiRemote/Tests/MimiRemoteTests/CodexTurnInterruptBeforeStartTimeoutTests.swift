import XCTest
@testable import MimiRemote

// #808：等不到 turn/started 时不能把 no active turn 当成已停止，也不能静默吞掉。
extension CodexTurnInterruptBeforeStartTests {
    func testInterruptWithoutTurnStartedReportsNotAcceptedAndKeepsRunning() async throws {
        let fixture = try await makeFixture { options in
            options.makeRuntime = { project, transport in
                CodexAppServerSessionRuntime(
                    endpoint: "http://127.0.0.1:8787", token: "test-token",
                    transportFactory: { transport },
                    turnInterruptRecoveryDelaysNanoseconds: [],
                    turnStartedSignalTimeoutNanoseconds: 50_000_000,
                    configProvider: {
                        makeDirectAppServerConfig(
                            project: project,
                            allowedMethods: CodexTurnInterruptBeforeStartFixtureOptions.allowedMethods
                        )
                    }
                )
            }
        }
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
}

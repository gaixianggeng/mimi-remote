import Foundation
import XCTest
@testable import MimiRemote

/// H10 恢复编排测试。
///
/// 用假时钟与可注入随机数：退避是时序策略，用真实 `sleep` 去赌只会测出机器忙闲。
/// 中心不变量有两条：
/// 1. **不重试的三类必须不重试**（权限/协议缺陷/业务失败）——把明确失败伪装成
///    "网络不好"会让用户一直转圈，而不是看到"需要重新授权"。
/// 2. **full jitter 落在 `[0, ceiling]`**，且 ceiling 按 factor 增长、封顶 max。
@MainActor
final class HarnessRecoveryCoordinatorTests: XCTestCase {

    /// 固定随机源：让"区间内"可断言而不依赖平台随机数。
    private func makeCoordinator(
        random: @escaping () -> Double = { 0.5 },
        recordedSleeps: SleepRecorder = SleepRecorder()
    ) -> (HarnessRecoveryCoordinator, SleepRecorder) {
        let coordinator = HarnessRecoveryCoordinator(
            random: random,
            sleep: { seconds in await recordedSleeps.record(seconds) }
        )
        return (coordinator, recordedSleeps)
    }

    // MARK: - 不重试的三类

    /// **明确失败不得重试。** 逐一验证每一个不可重连的分类。
    func testNonReconnectableFailuresSurfaceInsteadOfRetrying() {
        for error in [
            HarnessTransportError.business(
                HarnessRemoteError(code: "session/agent-busy", message: "忙", details: nil)
            ),
            .rejected(status: 403, message: "越权"),
            .malformedResponse("缺 result"),
            .unattributedResponse(rpcId: "other"),
            .carrier(HarnessRemoteError(code: "gateway/internal", message: "x", details: nil)),
            .unsupportedInteraction("weird/event"),
            .cancelled,
        ] {
            let (coordinator, _) = makeCoordinator()
            guard case .surface = coordinator.decide(for: error) else {
                XCTFail("\(error) 必须直接暴露而不是重试")
                continue
            }
            XCTAssertNil(coordinator.nextAttemptAt, "\(error) 不得排下一次重试")
            XCTAssertFalse(coordinator.isAwaitingRetry)
        }
    }

    /// 正向对照：链路层失败必须重试（证明上面的拒绝不是"一律暴露"）。
    func testLinkFailuresAreRetried() {
        for error in [
            HarnessTransportError.timedOut,
            .closed,
            .notConnected,
            .server(status: 503, message: "上游不可用"),
            .unauthorized(status: 401),
        ] {
            let (coordinator, _) = makeCoordinator()
            guard case .retry = coordinator.decide(for: error) else {
                XCTFail("\(error) 属于链路层，必须重试")
                continue
            }
        }
    }

    /// 明确失败会重置退避计数（不留残余，否则下次真实断网会等满 max）。
    func testSurfaceResetsBackoffCounter() {
        let (coordinator, _) = makeCoordinator()
        // 先积累几次链路失败。
        for _ in 0..<3 { _ = coordinator.decide(for: .timedOut) }
        XCTAssertGreaterThan(coordinator.attempt, 0)

        _ = coordinator.decide(for: .malformedResponse("协议缺陷"))

        XCTAssertEqual(coordinator.attempt, 0, "明确失败必须把计数归零")
    }

    // MARK: - 退避参数

    /// 退避按 factor 增长并封顶 max，且**第一次重试的 ceiling 就是 base**。
    ///
    /// 用 ceiling 而不是 delay 断言：delay 带抖动，断言具体值会脆。
    func testBackoffCeilingGrowsAndCaps() {
        let backoff = HarnessRecoveryCoordinator.Backoff.default
        XCTAssertEqual(backoff.ceiling(attempt: 1), 1, "首次重试的上限是 base")
        XCTAssertEqual(backoff.ceiling(attempt: 2), 2)
        XCTAssertEqual(backoff.ceiling(attempt: 3), 4)
        XCTAssertEqual(backoff.ceiling(attempt: 6), 30, "必须封顶在 max")
        XCTAssertEqual(backoff.ceiling(attempt: 20), 30, "远超也不得超过 max")
        // attempt 0 表示"还没有失败过"，不该有延迟。
        XCTAssertEqual(backoff.ceiling(attempt: 0), 0)
    }

    /// **full jitter**：实际延迟落在 `[0, ceiling]` 且确实随随机数变化。
    ///
    /// 两条都断言：只验区间的话，一个恒返回 0 的实现也会通过，
    /// 而那等于"立即重连"，退避形同虚设。
    func testBackoffUsesFullJitter() {
        let backoff = HarnessRecoveryCoordinator.Backoff.default
        XCTAssertEqual(backoff.delay(attempt: 3, random: { 0 }), 0, "下界是 0（full jitter）")
        XCTAssertEqual(backoff.delay(attempt: 3, random: { 1 }), backoff.ceiling(attempt: 3))
        XCTAssertEqual(backoff.delay(attempt: 3, random: { 0.5 }), 2)
        // 不同随机数给出不同延迟：证明真的在用随机源。
        XCTAssertNotEqual(
            backoff.delay(attempt: 3, random: { 0.1 }),
            backoff.delay(attempt: 3, random: { 0.9 })
        )
    }

    /// 连续失败的延迟单调不减（上限层面），避免"重试越来越快"。
    func testBackoffCeilingIsMonotonic() {
        let backoff = HarnessRecoveryCoordinator.Backoff.default
        var previous: TimeInterval = 0
        for attempt in 1...8 {
            let ceiling = backoff.ceiling(attempt: attempt)
            XCTAssertGreaterThanOrEqual(ceiling, previous, "attempt \(attempt) 的上限不得下降")
            previous = ceiling
        }
    }

    /// 成功后退避归零，下一次失败从最短延迟重新开始。
    func testSuccessResetsBackoff() {
        let (coordinator, _) = makeCoordinator()
        for _ in 0..<5 { _ = coordinator.decide(for: .timedOut) }
        let deepAttempt = coordinator.attempt
        XCTAssertGreaterThan(deepAttempt, 1)

        coordinator.recordSuccess()

        XCTAssertEqual(coordinator.attempt, 0)
        XCTAssertNil(coordinator.nextAttemptAt)
        guard case .retry(let delay) = coordinator.decide(for: .timedOut) else {
            XCTFail("成功后的首次失败必须重试")
            return
        }
        // 归零后第一次的 ceiling 是 base=1，因此 delay ≤ 1。
        XCTAssertLessThanOrEqual(delay, 1, "成功后退避必须从头开始，不能接着之前的深度")
    }

    // MARK: - 前后台

    /// 后台不重连（暂停），不排下一次尝试。
    func testBackgroundPausesReconnect() {
        let (coordinator, _) = makeCoordinator()
        coordinator.enterBackground()

        guard case .pausedInBackground = coordinator.decide(for: .timedOut) else {
            XCTFail("后台必须暂停重连")
            return
        }
        XCTAssertNil(coordinator.nextAttemptAt, "后台不得排重试")
    }

    /// **回到前台立即允许一次重试**（契约 D6）。
    ///
    /// 后台挂起过的连接回到前台时不该还等退避——那会让用户看到
    /// "明明回来了却还在转圈"。
    func testForegroundAllowsImmediateRetry() {
        let (coordinator, _) = makeCoordinator()
        coordinator.enterBackground()
        _ = coordinator.decide(for: .timedOut)

        let shouldRetryNow = coordinator.enterForeground()

        XCTAssertTrue(shouldRetryNow, "回到前台必须立即允许重试")
        XCTAssertNil(coordinator.nextAttemptAt, "立即重试意味着不再等退避")
    }

    /// 后台保留退避计数：切后台再回来不该让退避从零开始。
    func testBackgroundPreservesBackoffDepth() {
        let (coordinator, _) = makeCoordinator()
        for _ in 0..<4 { _ = coordinator.decide(for: .timedOut) }
        let depth = coordinator.attempt

        coordinator.enterBackground()
        coordinator.enterForeground()

        XCTAssertEqual(coordinator.attempt, depth, "后台不得重置退避深度")
    }

    /// 没有失败过时进入前台不触发重连。
    func testForegroundWithoutFailureDoesNotRetry() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertFalse(coordinator.enterForeground())
    }

    /// 等待重连：假时钟记录被 sleep 的时长，且不真等。
    func testWaitForNextAttemptUsesInjectedSleep() async {
        let recorder = SleepRecorder()
        let coordinator = HarnessRecoveryCoordinator(
            random: { 1.0 },
            sleep: { seconds in await recorder.record(seconds) }
        )
        _ = coordinator.decide(for: .timedOut)

        let waited = await coordinator.waitForNextAttempt()

        XCTAssertTrue(waited)
        let slept = await recorder.total
        XCTAssertEqual(slept, 1.0, accuracy: 0.001, "ceiling(1)=1 且 random=1，应等 1 秒")
    }

    // MARK: - 状态可观测

    /// `isAwaitingRetry` 反映"正在等待重连"，UI 据此显示 reconnecting。
    func testIsAwaitingRetryReflectsState() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertFalse(coordinator.isAwaitingRetry, "初始不处于等待")

        _ = coordinator.decide(for: .timedOut)
        XCTAssertTrue(coordinator.isAwaitingRetry)

        coordinator.recordSuccess()
        XCTAssertFalse(coordinator.isAwaitingRetry)
    }
}

// MARK: - 替身

/// 记录 sleep 时长而不真的等待。
private actor SleepRecorder {
    private(set) var total: TimeInterval = 0
    private(set) var calls: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        total += seconds
        calls.append(seconds)
    }
}

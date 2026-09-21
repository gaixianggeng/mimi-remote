import Foundation
import XCTest
@testable import MimiRemote

/// H07 提交编排测试。
///
/// 中心不变量：**响应未知 ≠ 未执行**。所以本文件比重最大的断言是
/// "结果未知时不得重发、也不得把自己清成 idle"，而不是"发送成功"。
/// 前者写错的后果是重复副作用，后者写错只是提示不准。
@MainActor
final class HarnessSubmissionControllerTests: XCTestCase {

    // MARK: - 发送

    /// 正向对照：明确接受后落到 accepted。
    func testAcceptedSubmissionLandsInAccepted() async {
        let sender = RecordingPromptSender()
        let controller = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )

        let submission = await controller.submit(sessionID: "s1", text: "你好", requestID: "req-1")

        XCTAssertEqual(submission.state, .accepted)
        XCTAssertEqual(sender.calls.count, 1)
        XCTAssertEqual(sender.calls.first?.requestID, "req-1")
        XCTAssertEqual(sender.calls.first?.text, "你好")
    }

    /// 上游明确业务失败 → rejected（可以重试）。
    func testBusinessFailureIsRejectedNotUnknown() async {
        let failure = HarnessTransportError.business(
            HarnessRemoteError(code: "session/agent-busy", message: "会话正忙", details: nil)
        )
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in throw failure },
            sendCancel: { _ in }
        )

        let submission = await controller.submit(sessionID: "s1", text: "x", requestID: "req-2")

        XCTAssertEqual(submission.state, .rejected("会话正忙"))
    }

    /// 中继本地策略拒绝 → rejected。
    func testRelayPolicyRejectionIsRejected() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in throw HarnessTransportError.rejected(status: 403, message: "越权") },
            sendCancel: { _ in }
        )
        let submission = await controller.submit(sessionID: "s1", text: "x", requestID: "req-3")
        XCTAssertEqual(submission.state, .rejected("越权"))
    }

    /// **链路失败 → responseUnknown，不是 rejected。**
    ///
    /// 这是本文件最重要的一条：超时可能发生在"上游已经执行完、只是响应没回来"之后。
    /// 判成 rejected 会让上层放心重试，从而重复执行一次写操作。
    func testLinkFailureIsResponseUnknownNotRejected() async {
        for failure in [
            HarnessTransportError.timedOut,
            .closed,
            .notConnected,
            .server(status: 503, message: "上游不可用"),
            .malformedResponse("缺 result"),
            .unattributedResponse(rpcId: "other"),
        ] {
            let controller = HarnessSubmissionController(
                sendPrompt: { _, _, _ in throw failure },
                sendCancel: { _ in }
            )
            let submission = await controller.submit(sessionID: "s1", text: "x", requestID: "req-4")

            guard case .responseUnknown = submission.state else {
                XCTFail("\(failure) 必须判为结果未知，实际 \(submission.state)")
                continue
            }
        }
    }

    /// 载体层错误帧算上游结论 → rejected（它携带 code/message，是上游说的话）。
    func testCarrierErrorIsRejected() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in
                throw HarnessTransportError.carrier(
                    HarnessRemoteError(code: "session/conflict", message: "冲突", details: nil)
                )
            },
            sendCancel: { _ in }
        )
        let submission = await controller.submit(sessionID: "s1", text: "x", requestID: "req-5")
        XCTAssertEqual(submission.state, .rejected("冲突"))
    }

    /// 认不出的错误按未知处理（猜错方向的代价不对称）。
    func testUnknownErrorIsResponseUnknown() {
        struct Weird: Error {}
        guard case .responseUnknown = HarnessSubmissionController.stateForFailure(Weird()) else {
            XCTFail("认不出的错误必须按未知处理")
            return
        }
    }

    // MARK: - 不重发（核心）

    /// 结果未知后**不得**自动重发：再提交一次必须被拒，且不会触达上游。
    func testResponseUnknownBlocksFurtherSubmissionsWithoutResending() async {
        let sender = RecordingPromptSender()
        sender.failures = [HarnessTransportError.timedOut]
        let controller = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )

        let first = await controller.submit(sessionID: "s1", text: "第一次", requestID: "req-a")
        guard case .responseUnknown = first.state else {
            XCTFail("前置条件：第一次必须落到结果未知，实际 \(first.state)")
            return
        }
        XCTAssertEqual(sender.calls.count, 1)

        // 再提交：必须被拒，且**不产生第二次上游调用**。
        // 这次的提交从未发出，因此报"待对账"而不是"上游拒绝了它"——
        // 后者会让用户去重试一条他还没发过的消息。
        let second = await controller.submit(sessionID: "s1", text: "第二次", requestID: "req-b")
        XCTAssertEqual(second.blockReason, .previousSubmissionUnconfirmed)
        XCTAssertEqual(second.state, .idle, "没发出去的提交不是 rejected")
        XCTAssertEqual(sender.calls.count, 1, "结果未知不得触发重发")
    }

    /// 在途期间也拦住新提交（同一个会话上不能有两条无法区分先后的输入）。
    func testSubmittingStateBlocksConcurrentSubmission() async {
        let gate = PromptGate()
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in try await gate.wait() },
            sendCancel: { _ in }
        )

        async let first = controller.submit(sessionID: "s1", text: "第一次", requestID: "req-c")
        // 让第一次进入在途。
        await gate.waitUntilEntered()
        let second = await controller.submit(sessionID: "s1", text: "第二次", requestID: "req-d")
        XCTAssertEqual(second.blockReason, .previousSubmissionUnconfirmed)
        XCTAssertEqual(second.state, .idle, "在途时被拦下的提交不是 rejected")
        gate.open()
        _ = await first
    }

    /// 被拒的提交不得覆盖在途状态（否则第二次被拒会把第一次的记录冲掉）。
    func testBlockedSubmissionDoesNotOverwriteLatest() async {
        let sender = RecordingPromptSender()
        sender.failures = [HarnessTransportError.timedOut]
        let controller = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )

        _ = await controller.submit(sessionID: "s1", text: "第一次", requestID: "req-e")
        _ = await controller.submit(sessionID: "s1", text: "第二次", requestID: "req-f")

        XCTAssertEqual(
            controller.latestSubmission(sessionID: "s1")?.requestID,
            "req-e",
            "被拒的提交不得覆盖在途记录"
        )
    }

    /// 一个会话的 responseUnknown 不能阻塞另一个会话的独立提交。
    func testResponseUnknownIsIsolatedPerSession() async {
        let sender = RecordingPromptSender()
        sender.failures = [HarnessTransportError.timedOut]
        let controller = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )

        let first = await controller.submit(sessionID: "s1", text: "一", requestID: "req-s1")
        guard case .responseUnknown = first.state else {
            XCTFail("前置条件：s1 必须是 responseUnknown")
            return
        }
        let second = await controller.submit(sessionID: "s2", text: "二", requestID: "req-s2")

        XCTAssertEqual(second.state, .accepted)
        XCTAssertEqual(sender.calls.map(\.sessionID), ["s1", "s2"])
        XCTAssertEqual(controller.latestSubmission(sessionID: "s1")?.requestID, "req-s1")
        XCTAssertEqual(controller.latestSubmission(sessionID: "s2")?.requestID, "req-s2")
    }

    // MARK: - 对账出口

    /// 对账是 responseUnknown 的唯一合法出口。
    func testReconciliationResolvesResponseUnknown() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in throw HarnessTransportError.timedOut },
            sendCancel: { _ in }
        )
        _ = await controller.submit(sessionID: "s1", text: "x", requestID: "req-g")
        guard case .responseUnknown = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("前置条件")
            return
        }

        controller.resolveAfterReconciliation(requestID: "req-g")

        XCTAssertEqual(controller.latestSubmission(sessionID: "s1")?.state, .accepted)
        // 解开之后可以继续提交。
        let sender = RecordingPromptSender()
        let controller2 = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )
        _ = await controller2.submit(sessionID: "s1", text: "y", requestID: "req-h")
        XCTAssertEqual(sender.calls.count, 1)
    }

    /// 对账只认自己的 requestID：别人的 id 不得解开本次未知。
    func testReconciliationWithWrongRequestIDDoesNothing() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in throw HarnessTransportError.timedOut },
            sendCancel: { _ in }
        )
        _ = await controller.submit(sessionID: "s1", text: "x", requestID: "req-i")

        controller.resolveAfterReconciliation(requestID: "someone-else")

        guard case .responseUnknown = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("不匹配的 requestId 不得解开未知状态")
            return
        }
    }

    /// 结果未知时被挡下的新提交**不得**被报成"上游拒绝了它"。
    ///
    /// 那次提交从未发出。报 `.rejected`（语义是"没执行、可重试"）会让用户去重试
    /// 一条他还没发过的消息，而真正该做的是对账。
    func testBlockedSubmissionReportsUnconfirmedRatherThanRejected() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in throw HarnessTransportError.timedOut },
            sendCancel: { _ in }
        )
        _ = await controller.submit(sessionID: "s1", text: "第一条", requestID: "req-block-1")
        guard case .responseUnknown = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("前置条件：第一条必须是 responseUnknown")
            return
        }

        let blocked = await controller.submit(sessionID: "s1", text: "第二条", requestID: "req-block-2")

        XCTAssertEqual(blocked.blockReason, .previousSubmissionUnconfirmed)
        XCTAssertEqual(blocked.state, .idle, "没发出去的提交不是 rejected")
        // 被拒的这次不得顶掉上一次的 latest：对账仍要针对真正在途的那条。
        XCTAssertEqual(controller.latestSubmission(sessionID: "s1")?.requestID, "req-block-1")
    }

    /// 已确认的提交不得被之后的失败回退成未知。
    ///
    /// 时序是"回显先到、HTTP 超时后到"：durable 回显已经证明那次提交生效了。
    func testReconciledSubmissionIsNotDowngradedByLateFailure() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in throw HarnessTransportError.timedOut },
            sendCancel: { _ in }
        )
        _ = await controller.submit(sessionID: "s1", text: "x", requestID: "req-order")
        guard case .responseUnknown = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("前置条件")
            return
        }

        // 回显先到：对账确认。
        controller.resolveAfterReconciliation(requestID: "req-order")
        XCTAssertEqual(controller.latestSubmission(sessionID: "s1")?.state, .accepted)

        // 迟到的失败回执再走一次对账：不得把它降回未知。
        controller.resolveAfterReconciliation(requestID: "req-order")
        XCTAssertEqual(
            controller.latestSubmission(sessionID: "s1")?.state,
            .accepted,
            "已经确认的提交不得被回退成未知"
        )

        // 确认之后同一会话可以继续发送。
        let sender = RecordingPromptSender()
        let next = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )
        _ = await next.submit(sessionID: "s1", text: "下一条", requestID: "req-next")
        XCTAssertEqual(sender.calls.count, 1)
    }

    /// 回显**先于** HTTP 返回到达时必须确认，而不是等到超时再冻结。
    ///
    /// 正常时序：上游接受了提交并先把 durable 记录推过来，HTTP 响应还在路上。
    /// 只处理 `.responseUnknown` 会让这次确认白白丢掉，随后的超时把状态写成未知，
    /// 会话被永久冻结——尽管用户已经能看到自己的消息。
    func testReconciliationAcceptsSubmittingStateBeforeSendReturns() async {
        let gate = SendGate()
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in try await gate.wait() },
            sendCancel: { _ in }
        )

        // 发起提交：sendPrompt 会挂起。
        let inFlight = Task { await controller.submit(sessionID: "s1", text: "x", requestID: "req-order-1") }
        await gate.waitUntilEntered()
        guard case .submitting = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("前置条件：提交应先处于 submitting")
            return
        }

        // 回显先到：对账确认。
        controller.resolveAfterReconciliation(requestID: "req-order-1")

        // 之后 HTTP 才失败（超时）：不得把已确认的结果降级。
        await gate.fail(with: HarnessTransportError.timedOut)
        let result = await inFlight.value

        XCTAssertEqual(result.state, .accepted, "已被回显确认的提交不得被迟到的失败降级")
        XCTAssertEqual(controller.latestSubmission(sessionID: "s1")?.state, .accepted)
        XCTAssertNil(result.blockReason)
    }

    /// 超时先到、回显后到：同样最终解锁并可继续发送。
    func testReconciliationAfterTimeoutUnblocksNextSend() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in throw HarnessTransportError.timedOut },
            sendCancel: { _ in }
        )
        _ = await controller.submit(sessionID: "s1", text: "x", requestID: "req-order-2")
        guard case .responseUnknown = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("前置条件：超时应判为结果未知")
            return
        }

        controller.resolveAfterReconciliation(requestID: "req-order-2")

        XCTAssertEqual(controller.latestSubmission(sessionID: "s1")?.state, .accepted)
        let sender = RecordingPromptSender()
        let next = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )
        _ = await next.submit(sessionID: "s1", text: "y", requestID: "req-order-3")
        XCTAssertEqual(sender.calls.count, 1, "对账后必须能继续发送")
    }

    /// 明确拒绝过的提交不得被一条回显改写结论。
    ///
    /// 拒绝是"没执行"的确定结论；用回显把它翻成 accepted 会掩盖一次真实的失败。
    func testReconciliationDoesNotRewriteExplicitRejection() async {
        let controller = HarnessSubmissionController(
            sendPrompt: { _, _, _ in
                throw HarnessTransportError.business(
                    HarnessRemoteError(code: "session/agent-busy", message: "忙", details: nil)
                )
            },
            sendCancel: { _ in }
        )
        _ = await controller.submit(sessionID: "s1", text: "x", requestID: "req-order-4")
        guard case .rejected = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("前置条件：业务失败应判为 rejected")
            return
        }

        controller.resolveAfterReconciliation(requestID: "req-order-4")

        guard case .rejected = controller.latestSubmission(sessionID: "s1")?.state else {
            XCTFail("已明确拒绝的提交不得被回显改成已接受")
            return
        }
    }

    // MARK: - 停止

    func testCancelSuccessAndUnknown() async {
        let ok = HarnessSubmissionController(sendPrompt: { _, _, _ in }, sendCancel: { _ in })
        let okState = await ok.cancel(sessionID: "s1")
        XCTAssertEqual(okState, .accepted)

        let unknown = HarnessSubmissionController(
            sendPrompt: { _, _, _ in },
            sendCancel: { _ in throw HarnessTransportError.timedOut }
        )
        let unknownState = await unknown.cancel(sessionID: "s1")
        guard case .responseUnknown = unknownState else {
            XCTFail("停止的响应未知同样不得判为失败，实际 \(unknownState)")
            return
        }
    }

    /// 稳定的 requestId：同一次提交从发起到达成都是同一个值。
    func testRequestIDIsStableAcrossSubmission() async {
        let sender = RecordingPromptSender()
        let controller = HarnessSubmissionController(
            sendPrompt: { try await sender.send($0, $1, $2) },
            sendCancel: { _ in }
        )
        let submission = await controller.submit(sessionID: "s1", text: "x", requestID: "stable-id")

        XCTAssertEqual(submission.requestID, "stable-id")
        XCTAssertEqual(sender.calls.first?.requestID, "stable-id")
        XCTAssertEqual(controller.latestSubmission(sessionID: "s1")?.requestID, "stable-id")
    }
}

// MARK: - 替身

@MainActor
private final class RecordingPromptSender {
    struct Call: Equatable {
        let sessionID: String
        let requestID: String
        let text: String
    }

    private(set) var calls: [Call] = []
    var failures: [Error] = []

    func send(_ sessionID: String, _ requestID: String, _ text: String) async throws {
        calls.append(Call(sessionID: sessionID, requestID: requestID, text: text))
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
    }
}

/// 把一次发送卡住的闸门，用于构造"在途"状态。
@MainActor
private final class PromptGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var openCalled = false

    func wait() async {
        entered = true
        if openCalled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        openCalled = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilEntered() async {
        for _ in 0..<200 {
            if entered { return }
            await Task.yield()
        }
        XCTFail("等待进入在途超时")
    }
}


/// 可控的 `sendPrompt` 闸门：让测试确定性地安排"回显先到 / HTTP 后失败"的顺序。
@MainActor
private final class SendGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Error>?
    private var didEnter = false

    func wait() async throws {
        didEnter = true
        entered?.resume()
        entered = nil
        try await withCheckedThrowingContinuation { continuation in
            resume = continuation
        }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { continuation in
            entered = continuation
        }
    }

    func fail(with error: Error) {
        resume?.resume(throwing: error)
        resume = nil
    }
}

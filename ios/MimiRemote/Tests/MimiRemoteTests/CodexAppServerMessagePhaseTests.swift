import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testPartialAnswerAllowsMoreItemsUntilTurnCompleted() async throws {
        let threadID = "thr_partial_answer"
        let turnID = "turn_partial_answer"
        var projector = CodexAppServerEventProjector()
        let reducer = EventReducer()
        let project = makeProject(id: "proj_partial_answer")
        let running = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Partial Answer",
            status: SessionStatus.running.rawValue,
            source: "codex",
            activeTurnID: turnID
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running]) }
        )
        store.sessions = [running]
        store.turnCompletionReconciliationDelaysNanoseconds = []
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: threadID)

        let partial = try XCTUnwrap(projector.project(try decodeAppServerNotification(
            #"{"method":"item/completed","params":{"threadId":"thr_partial_answer","turnId":"turn_partial_answer","item":{"id":"answer-partial","type":"agentMessage","text":"先给出稳定结论。","phase":"partial_answer"}}}"#
        )))
        guard case .messageCompleted(let partialMessage, _) = partial else {
            return XCTFail("partial_answer 应投影为普通正文完成事件")
        }
        XCTAssertEqual(partialMessage.kind, .message)
        let partialOutput = await reducer.reduce(
            partial,
            fallbackSessionID: threadID,
            outputIdleClearDelay: 0
        )
        XCTAssertTrue(partialOutput.statusUpdates.isEmpty)
        XCTAssertFalse(partialOutput.activeTurnMutations.contains { mutation in
            guard case .clear = mutation else { return false }
            return true
        })
        await store.applyRuntimeEvent(partial, lease: lease, sendsNotification: false)
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(store.sessionsByID[threadID]?.activeTurnID, turnID)

        let tool = try XCTUnwrap(projector.project(try decodeAppServerNotification(
            #"{"method":"item/completed","params":{"threadId":"thr_partial_answer","turnId":"turn_partial_answer","item":{"id":"tool-after-partial","type":"commandExecution","command":"echo continue","cwd":"/tmp","status":"completed","aggregatedOutput":"ok","exitCode":0}}}"#
        )))
        guard case .processItemCompleted(_, _, _) = tool else {
            return XCTFail("partial_answer 后的工具事件不能被截断")
        }
        let toolOutput = await reducer.reduce(
            tool,
            fallbackSessionID: threadID,
            outputIdleClearDelay: 0
        )
        XCTAssertTrue(toolOutput.statusUpdates.isEmpty)
        await store.applyRuntimeEvent(tool, lease: lease, sendsNotification: false)
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(store.sessionsByID[threadID]?.activeTurnID, turnID)

        let final = try XCTUnwrap(projector.project(try decodeAppServerNotification(
            #"{"method":"item/completed","params":{"threadId":"thr_partial_answer","turnId":"turn_partial_answer","item":{"id":"answer-final","type":"agentMessage","text":"工具执行后补充最终正文。","phase":"final_answer"}}}"#
        )))
        guard case .messageCompleted(let finalMessage, _) = final else {
            return XCTFail("expected final assistant message")
        }
        XCTAssertEqual(finalMessage.kind, .message)
        await store.applyRuntimeEvent(final, lease: lease, sendsNotification: false)
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.running.rawValue)
        XCTAssertEqual(store.sessionsByID[threadID]?.activeTurnID, turnID)

        let completed = try XCTUnwrap(projector.project(try decodeAppServerNotification(
            #"{"method":"turn/completed","params":{"threadId":"thr_partial_answer","turn":{"id":"turn_partial_answer","status":"completed"}}}"#
        )))
        let completedOutput = await reducer.reduce(
            completed,
            fallbackSessionID: threadID,
            outputIdleClearDelay: 0
        )
        XCTAssertEqual(completedOutput.statusUpdates.first?.1, SessionStatus.completed.rawValue)
        XCTAssertTrue(completedOutput.activeTurnMutations.contains { mutation in
            guard case .clear(let sessionID, let completedTurnID) = mutation else { return false }
            return sessionID == threadID && completedTurnID == turnID
        })
        await store.applyRuntimeEvent(completed, lease: lease, sendsNotification: false)
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.completed.rawValue)
        XCTAssertNil(store.sessionsByID[threadID]?.activeTurnID)
    }

    func testAgentMessageWithoutPhaseKeepsLegacyMessageProjection() throws {
        var projector = CodexAppServerEventProjector()
        let event = try XCTUnwrap(projector.project(try decodeAppServerNotification(
            #"{"method":"item/completed","params":{"threadId":"thr_phase_legacy","turnId":"turn_phase_legacy","item":{"id":"answer-legacy","type":"agentMessage","text":"旧服务端正文"}}}"#
        )))
        guard case .messageCompleted(let message, _) = event else {
            return XCTFail("省略 phase 的旧消息仍应投影")
        }
        XCTAssertEqual(message.kind, .message)
        XCTAssertEqual(message.content, "旧服务端正文")

        _ = projector.project(try decodeAppServerNotification(
            #"{"method":"item/started","params":{"threadId":"thr_phase_legacy","turnId":"turn_phase_legacy","item":{"id":"commentary-legacy","type":"agentMessage","text":"","phase":"commentary"}}}"#
        ))
        let commentary = try XCTUnwrap(projector.project(try decodeAppServerNotification(
            #"{"method":"item/completed","params":{"threadId":"thr_phase_legacy","turnId":"turn_phase_legacy","item":{"id":"commentary-legacy","type":"agentMessage","text":"旧服务端省略 completed phase"}}}"#
        )))
        guard case .messageCompleted(let commentaryMessage, _) = commentary else {
            return XCTFail("completed 省略 phase 时应沿用 started 的语义")
        }
        XCTAssertEqual(commentaryMessage.kind, .commentary)
    }
}

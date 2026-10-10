import XCTest
@testable import MimiRemote

private struct CollaborationModeRuntimeFixture {
    let runtime: CodexAppServerSessionRuntime
    let transport: FakeCodexAppServerTransport
    let project: AgentProject
    let threadID: SessionID
    let threadJSON: String
}

private func makeCollaborationModeRuntimeFixture(
    suffix: String
) async throws -> CollaborationModeRuntimeFixture {
    let project = AgentProject(
        id: "proj_collaboration_\(suffix)",
        name: "Collaboration Mode",
        path: "/tmp/collaboration-\(suffix)"
    )
    let threadID = "thr_collaboration_\(suffix)"
    let threadJSON = appServerThreadJSON(
        id: threadID,
        cwd: project.path,
        source: "appServer",
        updatedAt: 1_781_000_000
    )
    let transportPool = FakeCodexAppServerTransportPool()
    let runtime = CodexAppServerSessionRuntime(
        endpoint: "http://127.0.0.1:8787",
        token: "test-token",
        transportFactory: { transportPool.make() },
        configProvider: {
            makeDirectAppServerConfig(
                project: project,
                allowedMethods: [
                    "initialize", "initialized", "thread/list", "thread/resume"
                ],
                // 本机共享 runtime 会在打开空闲历史时执行 thread/resume，
                // 普通 WS 则按产品策略保持只读，不会触发本组恢复模式断言。
                transport: "local"
            )
        }
    )

    let pageTask = Task {
        try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
    }
    let transport = try await waitForFakeAppServerTransport(in: transportPool, index: 0)
    let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
    transportResponse(
        transport,
        id: initialize.id,
        result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
    )
    let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
    transportResponse(
        transport,
        id: list.id,
        result: appServerThreadListResult([threadJSON], nextCursor: nil)
    )
    _ = try await pageTask.value
    return CollaborationModeRuntimeFixture(
        runtime: runtime,
        transport: transport,
        project: project,
        threadID: threadID,
        threadJSON: threadJSON
    )
}

private func collaborationModes(
    in events: [AgentEvent]
) -> [CodexAppServerTurnOptions.CollaborationMode] {
    events.compactMap { event in
        guard case .collaborationModeUpdated(let mode, _) = event else { return nil }
        return mode
    }
}

private func collaborationModeResumeResult(
    fixture: CollaborationModeRuntimeFixture,
    mode: String?
) -> String {
    let modeJSON = mode.map {
        #", "collaborationMode":{"mode":"\#($0)","settings":{}}"#
    } ?? ""
    return #"{"thread":\#(fixture.threadJSON),"cwd":"\#(fixture.project.path)"\#(modeJSON)}"#
}

@MainActor
extension ConversationDataFlowTests {
    func testThreadResumeRestoresPlanModeWithoutWritingSharedMode() async throws {
        let fixture = try await makeCollaborationModeRuntimeFixture(suffix: "resume_plan")
        let connectTask = Task {
            try await fixture.runtime.connectForEvents(sessionID: fixture.threadID)
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume"
        )
        XCTAssertNil(
            resume.params?.objectValue?["collaborationMode"],
            "被动恢复只读取权威模式，不能写入共享设置"
        )
        transportResponse(
            fixture.transport,
            id: resume.id,
            result: collaborationModeResumeResult(fixture: fixture, mode: "plan")
        )
        try await connectTask.value

        let events = await fixture.runtime.bufferedEvents(
            sessionID: fixture.threadID,
            replayPolicy: .all
        )
        XCTAssertEqual(collaborationModes(in: events), [.plan])
        await fixture.runtime.shutdownForHostSwitch()
    }

    func testFailedThreadResumeDoesNotPublishCollaborationMode() async throws {
        let fixture = try await makeCollaborationModeRuntimeFixture(suffix: "resume_failed")
        let connectTask = Task {
            try await fixture.runtime.connectForEvents(sessionID: fixture.threadID)
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume"
        )
        transportErrorResponse(
            fixture.transport,
            id: resume.id,
            code: -32603,
            message: "resume failed"
        )
        do {
            try await connectTask.value
            XCTFail("failed resume should throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        let events = await fixture.runtime.bufferedEvents(
            sessionID: fixture.threadID,
            replayPolicy: .all
        )
        XCTAssertTrue(collaborationModes(in: events).isEmpty)
        await fixture.runtime.shutdownForHostSwitch()
    }

    func testResumeModeRequiresMatchingThreadCWD() async throws {
        let fixture = try await makeCollaborationModeRuntimeFixture(suffix: "scope_guard")
        let connectTask = Task {
            try await fixture.runtime.connectForEvents(sessionID: fixture.threadID)
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume"
        )
        let mismatchedResult = #"{"thread":\#(fixture.threadJSON),"cwd":"/tmp/another-workspace","collaborationMode":{"mode":"plan","settings":{}}}"#
        transportResponse(fixture.transport, id: resume.id, result: mismatchedResult)
        try await connectTask.value

        let events = await fixture.runtime.bufferedEvents(
            sessionID: fixture.threadID,
            replayPolicy: .all
        )
        XCTAssertTrue(collaborationModes(in: events).isEmpty)
        await fixture.runtime.shutdownForHostSwitch()
    }

    func testSettingsUpdateDuringResumeWinsOverResumeSnapshot() async throws {
        let fixture = try await makeCollaborationModeRuntimeFixture(suffix: "settings_wins")
        let connectTask = Task {
            try await fixture.runtime.connectForEvents(sessionID: fixture.threadID)
        }
        let resume = try await waitForFakeAppServerRequest(
            fixture.transport,
            method: "thread/resume"
        )
        fixture.transport.enqueue(
            #"{"method":"thread/settings/updated","params":{"threadId":"\#(fixture.threadID)","threadSettings":{"cwd":"\#(fixture.project.path)","collaborationMode":{"mode":"plan","settings":{}}}}}"#
        )
        for _ in 0..<200 {
            let generation = await fixture.runtime
                .collaborationModeGenerationBySessionID[fixture.threadID] ?? 0
            if generation > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let settingsGeneration = await fixture.runtime
            .collaborationModeGenerationBySessionID[fixture.threadID]
        XCTAssertEqual(settingsGeneration, 1)

        transportResponse(
            fixture.transport,
            id: resume.id,
            result: collaborationModeResumeResult(fixture: fixture, mode: "default")
        )
        try await connectTask.value
        let events = await fixture.runtime.bufferedEvents(
            sessionID: fixture.threadID,
            replayPolicy: .all
        )
        XCTAssertEqual(collaborationModes(in: events), [.plan])
        await fixture.runtime.shutdownForHostSwitch()
    }

    func testMissingNullAndUnknownModesDoNotReplaceAuthoritativeMode() async throws {
        let fixture = try await makeCollaborationModeRuntimeFixture(suffix: "invalid_modes")
        let metadata = { (value: CodexAppServerJSONValue?) in
            CodexAppServerNotification(method: "thread/settings/updated", params: .object([
                "threadId": .string(fixture.threadID),
                "threadSettings": .object([
                    "cwd": .string(fixture.project.path),
                    "collaborationMode": value ?? .null
                ])
            ]))
        }
        await fixture.runtime.updateContext(from: metadata(.object([
            "mode": .string("plan"),
            "settings": .object([:])
        ])))
        await fixture.runtime.updateContext(from: CodexAppServerNotification(
            method: "thread/settings/updated",
            params: .object([
                "threadId": .string(fixture.threadID),
                "threadSettings": .object([
                    "cwd": .string(fixture.project.path)
                ])
            ])
        ))
        await fixture.runtime.updateContext(from: metadata(nil))
        await fixture.runtime.updateContext(from: metadata(.object([
            "mode": .string("future_mode"),
            "settings": .object([:])
        ])))

        let events = await fixture.runtime.bufferedEvents(
            sessionID: fixture.threadID,
            replayPolicy: .all
        )
        XCTAssertEqual(collaborationModes(in: events), [.plan])
        let finalGeneration = await fixture.runtime
            .collaborationModeGenerationBySessionID[fixture.threadID]
        XCTAssertEqual(finalGeneration, 1)
        await fixture.runtime.shutdownForHostSwitch()
    }

    func testSessionStorePublishesAuthoritativeCollaborationModePerSession() async {
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        let sessionID = "thr_store_collaboration"
        let lease = HostSessionLease(hostScope: appStore.activeHostScope, sessionID: sessionID)
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )

        await store.applyRuntimeEvent(
            .collaborationModeUpdated(.plan, metadata),
            lease: lease,
            sendsNotification: false
        )
        XCTAssertEqual(store.activeCollaborationMode(for: sessionID), .plan)

        await store.applyRuntimeEvent(
            .collaborationModeUpdated(.default, metadata),
            lease: lease,
            sendsNotification: false
        )
        XCTAssertEqual(store.activeCollaborationMode(for: sessionID), .default)
    }
}

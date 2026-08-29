import XCTest
@testable import MimiRemote

@MainActor
final class WriterConflictForkStoreTests: XCTestCase {
    func testIdleWriterConflictForksLatestStateAndKeepsSourceLock() async {
        let fixture = makeFixture(sourceStatus: "history")
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)

        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: nil)
        )

        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertTrue(duplicated)
        XCTAssertEqual(fixture.client.requestedSessionForks, [
            RequestedSessionFork(
                threadID: fixture.source.resumeID ?? fixture.source.id,
                workspaceID: fixture.workspace.id,
                reason: .duplicate,
                lastTurnID: nil
            )
        ])
        XCTAssertEqual(fixture.store.selectedSessionID, fixture.forked.id)
        XCTAssertTrue(
            fixture.store.hasActiveWriterConflict(sessionID: fixture.source.id),
            "复制成功只能打开新 Thread，不能清除原会话的 writer 结论。"
        )
        XCTAssertNil(
            fixture.store.writerConflictForkAvailabilityByLease[fixture.sourceLease]
        )
    }

    func testRunningWriterConflictForksFromLatestTerminalTurn() async {
        let fixture = makeFixture(
            sourceStatus: "running",
            historyPage: HistoryMessagesPage(
                messages: [],
                loadMode: .economy,
                latestForkableTurnID: "turn-last-terminal"
            )
        )
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)

        await fixture.store.prepareSelectedWriterConflictForkAvailability()

        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: "turn-last-terminal")
        )
        XCTAssertEqual(fixture.client.requestedMessageSessionIDs, [fixture.source.resumeID ?? fixture.source.id])
        XCTAssertEqual(fixture.client.requestedMessageLimits, [2])

        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertTrue(duplicated)
        XCTAssertEqual(fixture.client.requestedSessionForks.first?.lastTurnID, "turn-last-terminal")
        XCTAssertTrue(fixture.store.hasActiveWriterConflict(sessionID: fixture.source.id))
    }

    func testWriterConflictChangingFromIdleToRunningRefreshesForkBoundary() async {
        let fixture = makeFixture(
            sourceStatus: "history",
            historyPage: HistoryMessagesPage(
                messages: [],
                loadMode: .economy,
                latestForkableTurnID: "turn-before-new-run"
            )
        )
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)

        await fixture.store.prepareSelectedWriterConflictForkAvailability()
        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: nil)
        )

        var runningSource = fixture.source
        runningSource.status = "running"
        fixture.store.sessions = [runningSource]

        await fixture.store.prepareSelectedWriterConflictForkAvailability()

        XCTAssertEqual(fixture.client.requestedMessageLimits, [2])
        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .available(lastTurnID: "turn-before-new-run")
        )
    }

    func testRunningWriterConflictWithoutTerminalTurnCannotFork() async {
        let fixture = makeFixture(
            sourceStatus: "running",
            historyPage: HistoryMessagesPage(messages: [], loadMode: .economy)
        )
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)

        await fixture.store.prepareSelectedWriterConflictForkAvailability()
        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertEqual(
            fixture.store.selectedWriterConflictForkAvailability,
            .unavailableNoTerminalTurn
        )
        XCTAssertFalse(duplicated)
        XCTAssertTrue(fixture.client.requestedSessionForks.isEmpty)
    }

    func testRunningOrReadOnlySessionCannotBypassForkGuard() async {
        let running = makeFixture(sourceStatus: "running")

        let ordinaryDuplicate = await running.store.duplicateSessionInCurrentWorkspace(running.source)

        XCTAssertFalse(ordinaryDuplicate)
        XCTAssertTrue(running.client.requestedSessionForks.isEmpty)

        var readOnlySource = running.source
        readOnlySource.canAcceptDirectInput = false
        let readOnly = makeFixture(source: readOnlySource)
        readOnly.store.setActiveWriterConflict(true, sessionID: readOnly.source.id)

        XCTAssertNil(readOnly.store.selectedWriterConflictForkAvailability)
        let readOnlyDuplicate = await readOnly.store.duplicateSelectedWriterConflictSession()
        XCTAssertFalse(readOnlyDuplicate)
        XCTAssertTrue(readOnly.client.requestedSessionForks.isEmpty)
    }

    func testForkFailureStaysInlineAndConcurrentOperationIsRejected() async {
        let failure = AgentAPIError.server(status: 409, message: "fork rejected")
        let fixture = makeFixture(
            sourceStatus: "history",
            forkResult: .failure(failure)
        )
        fixture.store.setActiveWriterConflict(true, sessionID: fixture.source.id)
        fixture.store.duplicatingSessionIDs.insert(fixture.source.id)

        let blocked = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertFalse(blocked)
        XCTAssertTrue(fixture.client.requestedSessionForks.isEmpty)
        fixture.store.duplicatingSessionIDs.remove(fixture.source.id)

        let duplicated = await fixture.store.duplicateSelectedWriterConflictSession()

        XCTAssertFalse(duplicated)
        XCTAssertEqual(fixture.client.requestedSessionForks.count, 1)
        XCTAssertTrue(
            fixture.store.selectedWriterConflictForkErrorMessage?.contains("fork rejected") == true
        )
        XCTAssertTrue(fixture.store.hasActiveWriterConflict(sessionID: fixture.source.id))
    }

    func testOldHostCompletionDoesNotReleaseNewHostDuplicateLock() async throws {
        let project = makeProject(id: "proj-host-scoped-fork")
        let source = makeSession(
            id: "same-session-id",
            projectID: project.id,
            title: "Shared source",
            status: "history",
            source: "codex",
            resumeID: "same-thread-id"
        )
        let workspace = AgentWorkspace(project: project)
        let forked = makeSession(
            id: "forked-thread",
            projectID: project.id,
            title: "Forked",
            status: "history",
            source: "codex",
            resumeID: "forked-thread"
        )
        let firstGate = WriterConflictWorkspaceResolveGate()
        let secondGate = WriterConflictWorkspaceResolveGate()
        let firstClient = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: ["same-thread-id": .success(forked)],
            resolveWorkspaceHandler: { _ in try await firstGate.response() }
        )
        let secondClient = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: ["same-thread-id": .success(forked)],
            resolveWorkspaceHandler: { _ in try await secondGate.response() }
        )
        let appStore = makeIsolatedAppStore()
        var activeClient = firstClient
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { activeClient }
        )

        select(source: source, project: project, in: store)
        let firstTask = Task { await store.duplicateSelectedWriterConflictSession() }
        await firstGate.waitUntilRequested()

        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.208:8787",
            token: "host-b-token",
            profileTarget: .newProfile(id: "writer-host-b", displayName: "Writer Host B"),
            installationID: "writer-host-b-installation"
        ))
        store.clearConnectionData()
        activeClient = secondClient
        select(source: source, project: project, in: store)

        let secondTask = Task { await store.duplicateSelectedWriterConflictSession() }
        await secondGate.waitUntilRequested()

        firstGate.resolve(workspace)
        let firstResult = await firstTask.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(
            store.duplicatingSessionIDs.contains(source.id),
            "旧 Host 的 defer 不能释放新 Host 上同名 Session 的操作锁。"
        )

        secondGate.resolve(workspace)
        let secondResult = await secondTask.value
        XCTAssertTrue(secondResult)
        XCTAssertFalse(store.duplicatingSessionIDs.contains(source.id))
    }

    private func select(source: AgentSession, project: AgentProject, in store: SessionStore) {
        store.projects = [project]
        store.sidebarProjects = [project]
        store.sessions = [source]
        store.selectedProjectID = project.id
        store.selectedSessionID = source.id
        store.setActiveWriterConflict(true, sessionID: source.id)
    }

    private func makeFixture(
        sourceStatus: String,
        historyPage: HistoryMessagesPage? = nil,
        forkResult: Result<AgentSession, Error>? = nil
    ) -> WriterConflictForkFixture {
        let project = makeProject(id: "proj-writer-fork")
        let source = makeSession(
            id: "source-thread",
            projectID: project.id,
            title: "Desktop source",
            status: sourceStatus,
            source: "codex",
            resumeID: "source-resume"
        )
        return makeFixture(
            source: source,
            project: project,
            historyPage: historyPage,
            forkResult: forkResult
        )
    }

    private func makeFixture(source: AgentSession) -> WriterConflictForkFixture {
        makeFixture(
            source: source,
            project: makeProject(id: source.projectID),
            historyPage: nil,
            forkResult: nil
        )
    }

    private func makeFixture(
        source: AgentSession,
        project: AgentProject,
        historyPage: HistoryMessagesPage?,
        forkResult: Result<AgentSession, Error>?
    ) -> WriterConflictForkFixture {
        let workspace = AgentWorkspace(project: project)
        let forked = makeSession(
            id: "forked-thread",
            projectID: project.id,
            title: "Forked",
            status: "history",
            source: "codex",
            resumeID: "forked-thread"
        )
        let sourceThreadID = source.resumeID ?? source.id
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: [sourceThreadID: forkResult ?? .success(forked)],
            historyPages: historyPage.map { [sourceThreadID: $0] } ?? [:],
            resolveResults: [project.path: .success(workspace)]
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sidebarProjects = [project]
        store.sessions = [source]
        store.selectedProjectID = project.id
        store.selectedSessionID = source.id

        return WriterConflictForkFixture(
            store: store,
            client: client,
            source: source,
            forked: forked,
            workspace: workspace,
            sourceLease: HostSessionLease(
                hostScope: appStore.activeHostScope,
                sessionID: source.id
            )
        )
    }
}

@MainActor
private struct WriterConflictForkFixture {
    let store: SessionStore
    let client: MockSessionStoreClient
    let source: AgentSession
    let forked: AgentSession
    let workspace: AgentWorkspace
    let sourceLease: HostSessionLease
}

private final class WriterConflictWorkspaceResolveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AgentWorkspace, Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func response() async throws -> AgentWorkspace {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = lock.withLock {
                self.continuation = continuation
                let waiters = requestWaiters
                requestWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard self.continuation == nil else { return true }
                requestWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resolve(_ workspace: AgentWorkspace) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: workspace)
    }
}

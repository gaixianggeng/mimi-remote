import XCTest
@testable import MimiRemote

@MainActor
final class SessionArchiveReconciliationTests: XCTestCase {
    func testWorkspaceRefreshRestoresPersistedArchiveWithoutChangingOtherPreferences() async throws {
        let f = try await fixture()
        let otherWorkspace = AgentWorkspace(project: makeProject(id: "other-workspace"))
        f.store.recentWorkspaces.append(otherWorkspace)
        let hidden = makeSession(id: "still-archived", projectID: f.project.id, title: "仍归档", status: "history", source: "codex")
        let pinned = makeSession(id: "pinned", projectID: f.project.id, title: "置顶", status: "history", source: "codex")
        f.store.toggleSessionArchived(hidden)
        f.store.toggleSessionPinned(pinned)
        f.store.sessionWorkspaceIDs = [f.project.id]
        f.store.saveSessionListPreferences()

        // 重建 Store，验证修复同样适用于已落盘的旧标记，而非只修改当前内存。
        let reloaded = makeStore(appStore: f.appStore, client: f.client, preferences: f.preferences, project: f.project, additionalWorkspace: otherWorkspace)
        XCTAssertEqual(reloaded.sessionWorkspaceIDs, [f.project.id], "刷新前先确认工作区筛选夹具有效")
        let page = try await refresh(reloaded, project: f.project)
        XCTAssertEqual(page.sessions.map(\.id), [f.session.id])
        XCTAssertEqual(reloaded.sessionLibrarySessions.map(\.id), [f.session.id])
        XCTAssertFalse(reloaded.isSessionArchived(f.session.id))
        let saved = f.preferences.load(profileID: f.appStore.notificationRoutingProfileID)
        XCTAssertEqual(saved.archivedSessionIDs, [hidden.id])
        XCTAssertEqual(saved.pinnedSessionIDs, [pinned.id])
        XCTAssertEqual(saved.sessionWorkspaceIDs, [f.project.id])
        let restarted = makeStore(appStore: f.appStore, client: f.client, preferences: f.preferences, project: f.project, additionalWorkspace: otherWorkspace)
        XCTAssertFalse(restarted.isSessionArchived(f.session.id))
        XCTAssertEqual(f.client.workspaceConsistencies, [.authoritative])
    }

    func testRestoredRowCountsTowardPresentationWindowWithoutExtraPage() async throws {
        let f = try await fixture()
        f.client.page = SessionsPage(sessions: [f.session], nextCursor: "next", hasMore: true)
        let page = try await refresh(f.store, project: f.project, limit: 1)
        XCTAssertEqual(page.sessions.map(\.id), [f.session.id])
        XCTAssertEqual(f.client.workspaceConsistencies.count, 1, "恢复后的行应直接计入展示窗口，不能多发补页请求")
        XCTAssertEqual(page.nextCursor, "next")
    }

    func testAuthoritativeLibraryRefreshRestoresGlobalAndDirectoryResults() async throws {
        for globalOnly in [true, false] {
            let f = try await fixture()
            f.client.globalPage = globalOnly ? SessionsPage(sessions: [f.session]) : SessionsPage(sessions: [])
            if globalOnly { f.store.recentWorkspaces = [] }
            await f.store.refreshSessionLibraryIndex(authoritative: true)
            XCTAssertFalse(f.store.isSessionArchived(f.session.id))
            XCTAssertTrue(f.store.sessionLibrarySessions.contains { $0.id == f.session.id })
            XCTAssertFalse(f.preferences.load(profileID: f.appStore.notificationRoutingProfileID).archivedSessionIDs.contains(f.session.id))
        }
    }

    func testWeakListsDoNotClearArchivePreferences() async throws {
        let f = try await fixture()
        let workspace = try XCTUnwrap(f.store.workspacesByID[f.project.id])
        _ = try await f.store.sessionListFirstPage(
            workspace: workspace, limit: 20, reuseRecent: false,
            consistency: .fastIndexed, source: .libraryIndex
        )
        f.client.globalPage = SessionsPage(sessions: [f.session])
        await f.store.refreshSessionLibraryIndex(authoritative: false)
        assertArchived(f)
    }

    func testMissingRowsAndFailedRequestsDoNotRestoreArchives() async throws {
        let f = try await fixture()
        f.client.page = SessionsPage(sessions: [])
        _ = try await refresh(f.store, project: f.project)
        assertArchived(f)
        f.client.pageHandler = { throw MockError.unimplemented }
        do {
            _ = try await refresh(f.store, project: f.project)
            XCTFail("请求失败必须继续上抛")
        } catch {}
        assertArchived(f)
    }

    func testSharedOldResponseCannotUndoArchiveStartedAfterRequest() async throws {
        let f = try await fixture()
        let gate = ArchiveReconciliationGate<SessionsPage>()
        f.client.pageHandler = { try await gate.response() }
        let first = Task { try await self.refresh(f.store, project: f.project) }
        await gate.waitUntilRequested()
        // 第一条请求仍在途中：本机先恢复再归档，之后第二个刷新加入同一条旧请求。
        let unarchived = await f.store.setSessionArchivedRemote(f.session, archived: false)
        let archived = await f.store.setSessionArchivedRemote(f.session, archived: true)
        XCTAssertTrue(unarchived && archived)
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await self.refresh(f.store, project: f.project)
        }
        while !secondStarted { await Task.yield() }
        await gate.resolve(SessionsPage(sessions: [f.session]))
        let firstPage = try await first.value
        let secondPage = try await second.value
        XCTAssertTrue(firstPage.sessions.isEmpty)
        XCTAssertTrue(secondPage.sessions.isEmpty)
        XCTAssertEqual(f.client.workspaceConsistencies.count, 1)
        assertArchived(f)
    }

    func testArchiveAlreadyPendingAtRequestStartRemainsProtectedAfterSuccess() async throws {
        let f = try await fixture(archived: false)
        let archiveGate = ArchiveReconciliationGate<Bool>()
        let pageGate = ArchiveReconciliationGate<SessionsPage>()
        f.client.archiveHandler = { _ = try await archiveGate.response() }
        let archive = Task { await f.store.setSessionArchivedRemote(f.session, archived: true) }
        await archiveGate.waitUntilRequested()
        f.client.pageHandler = { try await pageGate.response() }
        let refreshTask = Task { try await self.refresh(f.store, project: f.project) }
        await pageGate.waitUntilRequested()
        await archiveGate.resolve(true)
        let didArchive = await archive.value
        XCTAssertTrue(didArchive)
        await pageGate.resolve(SessionsPage(sessions: [f.session]))
        let page = try await refreshTask.value
        XCTAssertTrue(page.sessions.isEmpty)
        assertArchived(f)
    }

    func testGlobalResponseCannotUndoNewArchive() async throws {
        let f = try await fixture()
        f.store.recentWorkspaces = []
        let gate = ArchiveReconciliationGate<SessionsPage>()
        f.client.globalHandler = { try await gate.response() }
        let refreshTask = Task { await f.store.refreshSessionLibraryIndex(authoritative: true) }
        await gate.waitUntilRequested()
        _ = await f.store.setSessionArchivedRemote(f.session, archived: false)
        _ = await f.store.setSessionArchivedRemote(f.session, archived: true)
        await gate.resolve(SessionsPage(sessions: [f.session]))
        await refreshTask.value
        assertArchived(f)
    }

    func testLateResponseAfterHostSwitchDoesNotChangeEitherProfile() async throws {
        let f = try await fixture()
        let oldProfileID = f.appStore.notificationRoutingProfileID
        let gate = ArchiveReconciliationGate<SessionsPage>()
        f.client.pageHandler = { try await gate.response() }
        let request = Task { try await self.refresh(f.store, project: f.project) }
        await gate.waitUntilRequested()
        _ = try await f.appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787", token: "test-token",
            profileTarget: .newProfile(id: "other-mac", displayName: "Other Mac"), installationID: "other-installation"
        ))
        f.preferences.save(SessionListPreferences(archivedSessionIDs: [f.session.id]), profileID: "other-mac")
        f.store.reloadSessionListPreferences()
        await gate.resolve(SessionsPage(sessions: [f.session]))
        do {
            _ = try await request.value
            XCTFail("旧 Host 的刷新必须失效")
        } catch is CancellationError {} catch { XCTFail("非预期错误：\(error)") }
        XCTAssertTrue(f.preferences.load(profileID: oldProfileID).archivedSessionIDs.contains(f.session.id))
        assertArchived(f)
    }

    private struct Fixture {
        let project: AgentProject
        let session: AgentSession
        let client: ArchiveReconciliationClient
        let appStore: AppStore
        let preferences: SessionListPreferenceStore
        let store: SessionStore
    }

    private func fixture(archived: Bool = true) async throws -> Fixture {
        let project = makeProject(id: "archive-reconciliation")
        let session = makeSession(
            id: "restored-history", projectID: project.id, title: "外部恢复的会话",
            status: "history", source: "codex", runtimeProvider: "codex"
        )
        let client = ArchiveReconciliationClient(project: project, page: SessionsPage(sessions: [session]))
        let appStore = makeIsolatedAppStore()
        let suiteName = "ArchiveReconciliation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = SessionListPreferenceStore(defaults: defaults)
        let store = makeStore(appStore: appStore, client: client, preferences: preferences, project: project)
        store.sessions = [session]
        if archived {
            let didArchive = await store.setSessionArchivedRemote(session, archived: true)
            XCTAssertTrue(didArchive)
        }
        return Fixture(project: project, session: session, client: client, appStore: appStore, preferences: preferences, store: store)
    }

    private func makeStore(
        appStore: AppStore, client: ArchiveReconciliationClient,
        preferences: SessionListPreferenceStore, project: AgentProject,
        additionalWorkspace: AgentWorkspace? = nil
    ) -> SessionStore {
        let store = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            sessionListPreferenceStore: preferences, clientFactory: { client }
        )
        store.projects = [project]
        // 必须一次提交完整目录集；先设一个再追加，会把已选的单目录暂时归一成全选。
        store.recentWorkspaces = [AgentWorkspace(project: project)] + (additionalWorkspace.map { [$0] } ?? [])
        store.selectedSessionID = nil
        store.reloadSessionListPreferences()
        return store
    }

    private func refresh(_ store: SessionStore, project: AgentProject, limit: Int = 20) async throws -> SessionsPage {
        try await store.workspaceRuntimeSessionsPage(projectID: project.id, runtimeProvider: "codex", cursor: nil, limit: limit)
    }

    private func assertArchived(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(f.store.isSessionArchived(f.session.id), file: file, line: line)
        XCTAssertTrue(f.preferences.load(profileID: f.appStore.notificationRoutingProfileID).archivedSessionIDs.contains(f.session.id), file: file, line: line)
        XCTAssertFalse(f.store.sessionLibrarySessions.contains { $0.id == f.session.id }, file: file, line: line)
    }
}

private final class ArchiveReconciliationClient: SessionStoreAPIClient {
    let project: AgentProject
    var page: SessionsPage
    var globalPage = SessionsPage(sessions: [])
    var pageHandler: (() async throws -> SessionsPage)?
    var globalHandler: (() async throws -> SessionsPage)?
    var archiveHandler: (() async throws -> Void)?
    var workspaceConsistencies: [SessionListConsistency] = []

    init(project: AgentProject, page: SessionsPage) {
        self.project = project
        self.page = page
    }

    func projects() async throws -> [AgentProject] { [project] }
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] { page.sessions }
    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        workspaceConsistencies.append(consistency)
        if let pageHandler { return try await pageHandler() }
        return page
    }
    func controlledGlobalSessionsPage(runtimeProvider: String, cursor: String?, limit: Int?) async throws -> SessionsPage {
        guard runtimeProvider == "codex" else { return SessionsPage(sessions: []) }
        if let globalHandler { return try await globalHandler() }
        return globalPage
    }
    func setSessionArchived(id: String, archived: Bool) async throws { try await archiveHandler?() }
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse { throw MockError.unimplemented }
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse { throw MockError.unimplemented }
    func stopSession(id: String) async throws { throw MockError.unimplemented }
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] { [] }
}

private actor ArchiveReconciliationGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func response() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilRequested() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

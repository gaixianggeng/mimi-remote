import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testAuthoritativeLibraryRefreshReconcilesExternallyUnarchivedSession() async {
        let project = makeProject(id: "proj_external_unarchive")
        let session = makeSession(
            id: "session_external_unarchive",
            projectID: project.id,
            title: "外部取消归档",
            status: "notLoaded",
            source: "codex"
        )
        let preferences = makeSessionListPreferenceStore()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: [session])
            }
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )
        store.sessions = [session]
        store.toggleSessionArchived(session)

        await store.refreshSessionLibraryIndex()
        XCTAssertTrue(store.isSessionArchived(session.id), "后台快速刷新应继续保留本地列表状态")
        XCTAssertTrue(store.sessionLibrarySessions.isEmpty)

        await store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertFalse(store.isSessionArchived(session.id))
        XCTAssertEqual(store.sessionLibrarySessions.map(\.id), [session.id])
        XCTAssertFalse(
            preferences.load(profileID: appStore.notificationRoutingProfileID)
                .archivedSessionIDs.contains(session.id)
        )
    }

    func testAuthoritativeLibraryRefreshDoesNotOverridePendingArchive() async {
        let project = makeProject(id: "proj_pending_archive_refresh")
        let session = makeSession(
            id: "session_pending_archive_refresh",
            projectID: project.id,
            title: "归档提交中",
            status: "notLoaded",
            source: "codex"
        )
        let gate = SessionArchivePersistenceGate()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            },
            controlledGlobalSessionsHandler: { _, _ in
                SessionsPage(sessions: [session])
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]

        let archiveTask = Task { await store.setSessionArchivedRemote(session, archived: true) }
        await gate.waitUntilRequested()
        await store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertTrue(store.isSessionArchived(session.id))
        XCTAssertTrue(store.isSessionArchiveMutationPending(session.id))

        await gate.resolve()
        let didArchive = await archiveTask.value
        XCTAssertTrue(didArchive)
        XCTAssertTrue(store.isSessionArchived(session.id))
    }

    func testAuthoritativeArchiveResponseDoesNotOverrideArchiveCompletedAfterRequestStarted() async throws {
        let project = makeProject(id: "proj_archive_after_refresh_started")
        let session = makeSession(
            id: "session_archive_after_refresh_started",
            projectID: project.id,
            title: "刷新期间归档",
            status: "notLoaded",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveHandler: { _, _ in }
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.sessions = [session]
        let hostScope = appStore.activeHostScope
        let reconciliation = try XCTUnwrap(
            store.authoritativeArchiveReconciliation(true, hostScope: hostScope)
        )

        let didArchive = await store.setSessionArchivedRemote(session, archived: true)
        XCTAssertTrue(didArchive)
        store.reconcileArchivedSessionsReturnedByAuthoritativeList(
            [session],
            using: reconciliation,
            hostScope: hostScope
        )

        XCTAssertTrue(store.isSessionArchived(session.id))
    }

    func testAuthoritativeArchiveResponseFromPreviousHostDoesNotChangeCurrentHost() async throws {
        let suiteName = "ConversationDataFlowTests.ArchiveReconciliationHost.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.10:8787",
            token: "token-a",
            profileTarget: .newProfile(id: "archive-host-a", displayName: "Mac A"),
            installationID: "archive-installation-a"
        ))
        let project = makeProject(id: "proj_archive_reconciliation_host")
        let session = makeSession(
            id: "session_archive_reconciliation_host",
            projectID: project.id,
            title: "Host 隔离归档",
            status: "notLoaded",
            source: "codex"
        )
        let preferences = makeSessionListPreferenceStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [session]) }
        )
        let previousHostScope = appStore.activeHostScope
        let reconciliation = try XCTUnwrap(
            store.authoritativeArchiveReconciliation(true, hostScope: previousHostScope)
        )

        _ = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "archive-host-b", displayName: "Mac B"),
            installationID: "archive-installation-b"
        ))
        store.toggleSessionArchived(session)
        store.reconcileArchivedSessionsReturnedByAuthoritativeList(
            [session],
            using: reconciliation,
            hostScope: previousHostScope
        )

        XCTAssertTrue(store.isSessionArchived(session.id))
        XCTAssertTrue(
            preferences.load(profileID: "archive-host-b").archivedSessionIDs.contains(session.id)
        )
    }

    func testArchiveLateSuccessAfterSwitchingBackRestoresMemoryAndDurableState() async throws {
        let suiteName = "ConversationDataFlowTests.ArchiveSwitchBack.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.10:8787",
            token: "token-a",
            profileTarget: .newProfile(id: "mac-a", displayName: "Mac A"),
            installationID: "installation-a"
        ))

        let project = makeProject(id: "proj_archive_switch_back")
        let session = makeSession(
            id: "session_archive_switch_back",
            projectID: project.id,
            title: "回切后的归档",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchivePersistenceGate()
        let preferences = makeSessionListPreferenceStore()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )
        store.sessions = [session]
        store.toggleSessionPinned(session)
        let originalScope = appStore.activeHostScope

        let task = Task { await store.setSessionArchivedRemote(session, archived: true) }
        await gate.waitUntilRequested()

        _ = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.20:8787",
            token: "token-b",
            profileTarget: .newProfile(id: "mac-b", displayName: "Mac B"),
            installationID: "installation-b"
        ))
        _ = try await store.commitPreparedConnection(PreparedConnectionSettings(
            endpoint: "http://100.64.0.10:8787",
            token: "token-a",
            profileTarget: .existingProfile(id: "mac-a"),
            installationID: "installation-a"
        ))

        XCTAssertEqual(appStore.activeHostScope.profileID, originalScope.profileID)
        XCTAssertEqual(appStore.activeHostScope.installationID, originalScope.installationID)
        XCTAssertNotEqual(appStore.activeHostScope.generation, originalScope.generation)
        XCTAssertFalse(store.isSessionArchived(session.id), "回切时应先恢复 committed before")
        XCTAssertTrue(store.isSessionPinned(session.id))

        await gate.resolve()
        let didApplyToCurrentHost = await task.value

        XCTAssertTrue(didApplyToCurrentHost)
        XCTAssertTrue(store.isSessionArchived(session.id), "同安装身份的迟到成功应恢复当前内存目标态")
        XCTAssertFalse(store.isSessionPinned(session.id))
        XCTAssertFalse(store.isSessionArchiveMutationPending(session.id))

        // pending 已释放后的任意通用保存也不能再用回切时的旧内存覆盖远端成功。
        store.saveSessionListPreferences()
        let committed = preferences.load(profileID: "mac-a")
        XCTAssertTrue(committed.archivedSessionIDs.contains(session.id))
        XCTAssertFalse(committed.pinnedSessionIDs.contains(session.id))
    }

    func testDeletedProfileIgnoresLateArchiveSuccessWithoutResurrectingPreferences() async throws {
        let suiteName = "ConversationDataFlowTests.ArchiveDeletedProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "token-delete",
            profileTarget: .newProfile(id: "mac-delete", displayName: "待删除 Mac"),
            installationID: "installation-delete"
        ))

        let project = makeProject(id: "proj_archive_deleted_profile")
        let session = makeSession(
            id: "session_archive_deleted_profile",
            projectID: project.id,
            title: "删除档案时的归档",
            status: "history",
            source: "codex"
        )
        let gate = SessionArchivePersistenceGate()
        let preferences = makeSessionListPreferenceStore()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            sessionArchiveHandler: { id, archived in
                try await gate.response(id: id, archived: archived)
            }
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            sessionListPreferenceStore: preferences,
            clientFactory: { client }
        )
        store.sessions = [session]

        let task = Task { await store.setSessionArchivedRemote(session, archived: true) }
        await gate.waitUntilRequested()
        try await store.clearCurrentConnectionProfile()
        XCTAssertFalse(appStore.connectionProfiles.contains(where: { $0.id == "mac-delete" }))

        await gate.resolve()
        let didApply = await task.value

        XCTAssertFalse(didApply)
        XCTAssertTrue(preferences.load(profileID: "mac-delete").archivedSessionIDs.isEmpty)
        XCTAssertTrue(preferences.load(profileID: "mac-delete").pinnedSessionIDs.isEmpty)
    }
}

private actor SessionArchivePersistenceGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var didRequest = false

    func response(id _: SessionID, archived _: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            didRequest = true
            let waiters = requestWaiters
            requestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        if didRequest { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resolve() {
        continuation?.resume()
        continuation = nil
    }
}

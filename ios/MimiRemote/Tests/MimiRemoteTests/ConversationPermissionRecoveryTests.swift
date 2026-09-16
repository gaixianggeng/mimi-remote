import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testExplicitSessionPermissionsSurviveStoreRestartAndNewDefault() {
        let appStore = makeIsolatedAppStore()
        let persistence = makeSessionControlStateStore()
        func makeStore() -> SessionStore {
            SessionStore(
                appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
                sessionControlStateStore: persistence
            )
        }
        var store = makeStore()
        var composer = ComposerState()
        composer.applyPermissionMode(.readOnly, sessionIsRunning: true)
        store.saveComposerPermissionSelection(composer.permissionSelectionSnapshot(), for: .session("session-a"))
        composer.applyPermissionMode(.fullAccess)
        store.saveComposerPermissionSelection(composer.permissionSelectionSnapshot(), for: .session("session-b"))
        store = makeStore()

        for provider in ["claude", "codex"] {
            let restored = store.restoredComposerPermissionSelection(
                for: .session("session-a"), runtimeProvider: provider, defaultMode: .fullAccess
            )
            XCTAssertEqual(restored.mode, .readOnly)
            XCTAssertFalse(restored.preservesThreadSettings)
            XCTAssertFalse(restored.requiresNewTurn, "完成的边界不能在重启后复活")
        }
        XCTAssertEqual(store.restoredComposerPermissionSelection(
            for: .session("session-b"), runtimeProvider: "claude", defaultMode: .requestApproval
        ).mode, .fullAccess)
    }

    func testPermissionRecoveryKeepsPendingBoundaryAheadOfPersistedChoice() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            sessionControlStateStore: makeSessionControlStateStore()
        )
        var composer = ComposerState()
        composer.applyPermissionMode(.fullAccess)
        store.saveComposerPermissionSelection(composer.permissionSelectionSnapshot(), for: .session("session-a"))
        store.composerPermissionSelectionCache.removeAll()
        composer.applyPermissionMode(.readOnly, sessionIsRunning: true)
        let pending = composer.permissionSelectionSnapshot()
        store.pendingPermissionTurnBoundariesBySessionID["session-a"] = [PendingPermissionTurnBoundary(
            sessionID: "session-a", clientMessageID: "pending-client", permissionSelection: pending
        )]
        XCTAssertEqual(store.restoredComposerPermissionSelection(
            for: .session("session-a"), runtimeProvider: "claude", defaultMode: .fullAccess
        ), pending)
    }

    func testPermissionRecoveryDefaultsOnlyNewSessionsToFullAccess() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore(),
            sessionControlStateStore: makeSessionControlStateStore()
        )
        for provider in ["claude", "codex"] {
            for scope in [ComposerDraftScopeKey.newSession(projectID: "project"), .session("local:draft")] {
                let selection = store.restoredComposerPermissionSelection(
                    for: scope, runtimeProvider: provider, defaultMode: .fullAccess
                )
                XCTAssertEqual(selection.mode, .fullAccess)
                XCTAssertFalse(selection.preservesThreadSettings)
            }
        }
        XCTAssertEqual(store.restoredComposerPermissionSelection(
            for: .session("unknown-history"), runtimeProvider: "claude", defaultMode: .fullAccess
        ).mode, .requestApproval)
        XCTAssertTrue(store.restoredComposerPermissionSelection(
            for: .session("unknown-history"), runtimeProvider: "codex", defaultMode: .fullAccess
        ).preservesThreadSettings)
    }

    func testPermissionPersistenceIsolatesHostsAndRemovesDeletedProfile() {
        let persistence = makeSessionControlStateStore()
        var composer = ComposerState()
        composer.applyPermissionMode(.readOnly)
        persistence.savePermissionSelection(composer.permissionSelectionSnapshot(), sessionID: "same-id", profileID: "host-a")
        composer.applyPermissionMode(.fullAccess)
        persistence.savePermissionSelection(composer.permissionSelectionSnapshot(), sessionID: "same-id", profileID: "host-b")
        XCTAssertEqual(persistence.permissionSelection(sessionID: "same-id", profileID: "host-a")?.mode, .readOnly)
        XCTAssertEqual(persistence.permissionSelection(sessionID: "same-id", profileID: "host-b")?.mode, .fullAccess)
        persistence.remove(profileID: "host-a")
        XCTAssertNil(persistence.permissionSelection(sessionID: "same-id", profileID: "host-a"))
        XCTAssertEqual(persistence.permissionSelection(sessionID: "same-id", profileID: "host-b")?.mode, .fullAccess)
    }
}

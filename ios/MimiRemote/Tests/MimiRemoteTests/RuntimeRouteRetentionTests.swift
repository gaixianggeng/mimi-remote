import XCTest
@testable import MimiRemote

/// #784：回前台后 bundle 重建不能丢掉「会话属于哪个 Runtime」，Claude 会话的请求不能默认落到 Codex，
/// 重新授权也不能为别的 Runtime 的会话翻列表。
@MainActor
final class RuntimeRouteRetentionTests: XCTestCase {
    func testRoutesSurviveBundleRebuildAfterBackgroundCredentialSuspension() async throws {
        let suiteName = "RuntimeRouteRetentionTests.Background.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = ConnectionProfile(
            id: "mac-a",
            displayName: "当前 Mac",
            endpoint: "http://100.64.0.10:8787",
            lastSuccessfulAt: nil
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v1")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        defaults.set(profile.endpoint, forKey: "agentd.endpoint")
        let keychain = TestKeychainOperations()
        keychain.setData(Data("token-a".utf8), account: "agentd-profile.mac-a")
        let store = AppStore(defaults: defaults, tokenStore: TokenStore(keychain: keychain))

        let beforeBackground = store.runtimeBundle(endpoint: store.connectionEndpoint, token: store.token)
        beforeBackground.routes.remember("claude", for: "claude-selected")

        store.suspendCredentialsForBackground()
        try await store.restoreCredentialsForForeground()
        let afterForeground = store.runtimeBundle(endpoint: store.connectionEndpoint, token: store.token)

        XCTAssertFalse(beforeBackground === afterForeground, "回后台清凭据仍会重建 bundle")
        XCTAssertEqual(afterForeground.routes.runtimeProvider(for: "claude-selected"), "claude")
        XCTAssertTrue(try afterForeground.runtime(forSessionID: "claude-selected") === afterForeground.claude)
    }

    func testRememberMissingKeepsLearnedRoutesAndSkipsSessionsWithoutKnownRuntime() {
        let routes = AppServerRuntimeRouteStore()
        routes.remember("codex", for: "learned")
        let sessions = [
            makeSession(id: "learned", projectID: "p", title: "t", status: "history", source: "claude", runtimeProvider: "claude"),
            makeSession(id: "explicit", projectID: "p", title: "t", status: "history", source: "vscode", runtimeProvider: "claude"),
            makeSession(id: "by-source", projectID: "p", title: "t", status: "history", source: "claude"),
            makeSession(id: "unknown-source", projectID: "p", title: "t", status: "history", source: "vscode"),
            makeSession(id: "blank", projectID: "p", title: "t", status: "history", source: " ")
        ]

        routes.rememberMissing(sessions)

        XCTAssertEqual(routes.runtimeProvider(for: "learned"), "codex", "网络学到的路由不被本地快照覆盖")
        XCTAssertEqual(routes.runtimeProvider(for: "explicit"), "claude")
        XCTAssertEqual(routes.runtimeProvider(for: "by-source"), "claude")
        XCTAssertNil(routes.runtimeProvider(for: "unknown-source"), "认不出 Runtime 时不替它写成 Codex")
        XCTAssertNil(routes.runtimeProvider(for: "blank"))
    }

    func testSessionStoreFillsRoutesForSessionsKnownBeforeTheirRuntimeList() throws {
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore())

        // 冷启动恢复快照或回前台时，Claude 会话先回到 Store，Claude 列表还没拉。
        store.upsert(makeSession(
            id: "claude-restored", projectID: "proj", title: "restored", status: "history",
            source: "claude", runtimeProvider: "claude"
        ))

        XCTAssertEqual(appStore.runtimeRoutes.runtimeProvider(for: "claude-restored"), "claude")
        let bundle = appStore.runtimeBundle(endpoint: "http://127.0.0.1:8787", token: "token")
        XCTAssertTrue(try bundle.runtime(forSessionID: "claude-restored") === bundle.claude)
    }

    func testCodexRuntimeSkipsReauthorizationListingForThreadOwnedByAnotherRuntime() async throws {
        let project = AgentProject(id: "proj_route_owner", name: "Owner", path: "/tmp/proj_route_owner")
        let transport = FakeCodexAppServerTransport()
        let codex = CodexAppServerSessionRuntime(
            endpoint: "http://localhost:8787", token: "test-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: [
                    "initialize", "initialized", "thread/list", "thread/read", "thread/turns/list"
                ])
            }
        )
        let claude = CodexAppServerSessionRuntime(
            endpoint: "http://localhost:8787", token: "test-token", runtimeProvider: "claude"
        )
        let session = makeSession(
            id: "claude_owned", projectID: project.id, title: "claude", status: "history",
            source: "claude", runtimeProvider: "claude"
        )
        await codex.rememberForkedSession(session)
        let routes = AppServerRuntimeRouteStore()
        routes.remember("claude", for: session.id)
        let bundle = AppServerRuntimeBundle(codexRuntime: codex, claudeRuntime: claude, routes: routes)
        for _ in 0..<200 {
            if await codex.threadRuntimeOwnerLookup != nil { break }
            await Task.yield()
        }
        let lookupInstalled = await codex.threadRuntimeOwnerLookup != nil
        XCTAssertTrue(lookupInstalled, "bundle 应把路由查询注入 Runtime")

        let page = Task {
            try await codex.messagesPageFromTurnPages(
                sessionID: session.id, before: nil, limit: 20, loadMode: .economy, projects: [project],
                canHydrateTurnItems: false, recoveringInterruptedTurnID: nil
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake","platformFamily":"macos"}"#)
        let rejected = try await waitForFakeAppServerRequest(transport, method: "thread/turns/list")
        let sentAtRejection = await transport.sentMessages().count
        transportErrorResponse(
            transport, id: rejected.id, code: -32080,
            message: "thread/turns/list.threadId 未由当前 gateway 连接授权"
        )
        do {
            _ = try await page.value
            XCTFail("别的 Runtime 的会话应直接报原错误")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("-32080"), "\(error)")
        }
        let methods = await transport.sentMessages().dropFirst(sentAtRejection).compactMap { message -> String? in
            (try? decodeAppServerRequest(message))?.method
        }
        XCTAssertFalse(methods.contains("thread/list"), "不为 Claude 会话翻 Codex 列表：\(methods)")
        withExtendedLifetime(bundle) {}
        await codex.shutdownForHostSwitch()
    }
}

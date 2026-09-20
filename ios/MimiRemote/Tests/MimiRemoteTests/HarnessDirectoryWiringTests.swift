import Foundation
import XCTest
@testable import MimiRemote

/// H05 接线：SessionStore ←→ 原生目录协调器。
///
/// 这一层要证明四件事，每件都对应卡片的一条硬要求：
/// 1. **开关默认关**：关闭时不参与刷新，deepseek 继续走既有 app-server 路径。
/// 2. **失败保留旧页**：上游失败不得被翻译成空列表。
/// 3. **失败不落空页**：协调器不投递空结果，旧会话因此不会被冲掉。
/// 4. **工作区归属仍受控**：原生结果必须经既有归并，不能绕开目录归属登记。
///
/// 用真实 `SessionStore` + `MockSessionStoreClient`：断言的是"接线是否真的生效"，
/// 而 mock 的请求日志让"到底打了几次、打在哪个工作区"可观测。
@MainActor
final class HarnessDirectoryWiringTests: XCTestCase {

    // MARK: - 1. 开关

    /// 默认关闭。这条守住"生产默认走旧路径"这个前提——
    /// 它一旦被静默打开，deepseek 会在写路径尚未实现的阶段切到原生通道。
    func testRolloutDefaultsToDisabled() {
        XCTAssertFalse(
            HarnessNativeRollout.disabled.isEnabled,
            "原生通道必须默认关闭；打开它属于 H11"
        )
    }

    func testDisabledRolloutSkipsNativeDirectoryRefresh() async throws {
        let fixture = try makeFixture(enabled: false)
        XCTAssertFalse(fixture.store.isNativeHarnessDirectoryEnabled)

        await fixture.store.refreshNativeHarnessDirectory(
            workspace: fixture.workspace,
            consistency: .authoritative,
            restartFromFirst: true,
            hostScope: fixture.appStore.activeHostScope,
            generation: fixture.appStore.connectionGeneration
        )

        XCTAssertNil(fixture.store.nativeHarnessDirectory, "关闭时不得创建协调器")
        XCTAssertTrue(
            fixture.client.requestedWorkspaceIDs.isEmpty,
            "关闭时不得发起任何原生工作区查询"
        )
    }

    /// 打开后：真实走 client，结果经既有归并写进 sessions。
    func testEnabledRolloutRefreshesThroughClientAndMergesIntoSessions() async throws {
        let fixture = try makeFixture(
            enabled: true,
            workspacePages: ["h05-project": page([session(id: "h05-wired-1")])]
        )

        await fixture.store.refreshNativeHarnessDirectory(
            workspace: fixture.workspace,
            consistency: .authoritative,
            restartFromFirst: true,
            hostScope: fixture.appStore.activeHostScope,
            generation: fixture.appStore.connectionGeneration
        )

        XCTAssertEqual(fixture.client.requestedWorkspaceIDs, ["h05-project"])
        XCTAssertNotNil(fixture.store.nativeHarnessDirectory)
        XCTAssertTrue(
            fixture.store.sessions.contains { $0.id == "h05-wired-1" },
            "原生结果必须经既有归并写进 sessions"
        )
    }

    /// 目录协调器必须显式携带 runtime，让真实 routing facade 选择 Harness。
    ///
    /// Harness Spy 与 Codex transport Spy 相互独立：只断言结果不足以发现默认重载
    /// 偷偷落到 Codex；这里同时证明 Harness 被调用且 Codex 完全未被触碰。
    func testEnabledRolloutExplicitlyRoutesThroughNativeHarness() async throws {
        let project = AgentProject(id: "h05-project", name: "H05 Workspace", path: "/h05/workspace")
        let workspace = AgentWorkspace(project: project)
        let appStore = makeIsolatedAppStoreForHarnessWiring()
        appStore.token = "test-token"

        let harness = FakeHarnessSessionClient()
        harness.sessionsPageResult = .success(page([session(id: "h05-native-route")]))
        let codexSpy = HarnessDirectoryCodexTransportSpy()
        let config = makeDirectAppServerConfig(project: project)
        func runtime(_ provider: String, transport: CodexAppServerTransport) -> CodexAppServerSessionRuntime {
            CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "fixture",
                runtimeProvider: provider,
                transportFactory: { transport },
                configProvider: { config }
            )
        }
        let routingClient = CodexAppServerRuntimeRoutingSessionAPIClient(bundle: AppServerRuntimeBundle(
            codexRuntime: runtime("codex", transport: codexSpy),
            claudeRuntime: runtime("claude", transport: FakeCodexAppServerTransport()),
            deepseekRuntime: runtime("deepseek", transport: FakeCodexAppServerTransport()),
            harness: harness
        ))
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [workspace], endpoint: appStore.endpoint),
            clientFactory: { routingClient }
        )
        store.nativeHarnessRollout = HarnessNativeRollout(isEnabled: true)
        store.recentWorkspaces = [workspace]
        store.rebuildWorkspaceIndex()

        await store.refreshNativeHarnessDirectory(
            workspace: workspace,
            consistency: .authoritative,
            restartFromFirst: true,
            hostScope: appStore.activeHostScope,
            generation: appStore.connectionGeneration
        )

        XCTAssertEqual(harness.sessionsPageCallCount, 1, "目录刷新必须命中 Harness Spy")
        let codexTouchCount = await codexSpy.touchCount()
        XCTAssertEqual(codexTouchCount, 0, "目录刷新不得落到默认 Codex 重载")
        XCTAssertTrue(store.sessions.contains { $0.id == "h05-native-route" })
    }

    // MARK: - 2. 失败语义

    /// 上游失败时，接线层不得把它翻译成"成功但为空"。
    ///
    /// 这一条只验接线层自己的职责：失败要如实落到 `failed`，且不去动 `sessions`。
    /// "失败不投递空页"是协调器的不变量，由 `HarnessSessionDirectoryTests`
    /// 的 `testDeliverIsCalledOnlyWithSuccessfulPages` 在单元层覆盖（它断言
    /// `delivered` 不因失败增长）——两处分工，不重复断言同一个点。
    func testFailureSurfacesAsFailedStateAndLeavesSessionsUntouched() async throws {
        let fixture = try makeFixture(
            enabled: true,
            workspaceSessionsError: ["h05-project": HarnessTransportError.server(status: 503, message: "上游不可用")]
        )

        await fixture.store.refreshNativeHarnessDirectory(
            workspace: fixture.workspace,
            consistency: .authoritative,
            restartFromFirst: true,
            hostScope: fixture.appStore.activeHostScope,
            generation: fixture.appStore.connectionGeneration
        )

        let directory = try XCTUnwrap(fixture.store.nativeHarnessDirectory)
        if case .failed = directory.state {} else {
            XCTFail("上游失败必须落到 failed 状态，实际是 \(directory.state)")
        }
        XCTAssertTrue(
            fixture.store.sessions.isEmpty,
            "失败不得凭空产生会话"
        )
    }

    // MARK: - 3. 时序

    /// 手动刷新真的发新请求（而不是复用近期结果）。
    func testManualRefreshIssuesNewRequest() async throws {
        let fixture = try makeFixture(
            enabled: true,
            workspacePages: ["h05-project": page([])]
        )

        await fixture.store.refreshNativeHarnessDirectory(
            workspace: fixture.workspace,
            consistency: .authoritative,
            restartFromFirst: true,
            hostScope: fixture.appStore.activeHostScope,
            generation: fixture.appStore.connectionGeneration
        )
        let afterFirst = fixture.client.requestedWorkspaceIDs.count

        let directory = try XCTUnwrap(fixture.store.nativeHarnessDirectory)
        directory.refresh(manual: true)
        await directory.waitForInFlightRequest()

        XCTAssertGreaterThan(
            fixture.client.requestedWorkspaceIDs.count, afterFirst,
            "手动刷新必须真的再发一次请求"
        )
    }

    /// 并发触发合并成一个在途请求。
    ///
    /// 同一个协调器上连发多次刷新（同一查询身份）不得变成多次上游请求——
    /// 否则列表页的每次触发都会打一次上游。
    ///
    /// 协调器是懒建的：必须先走一次真实刷新把它建出来，再验后续触发。
    func testConcurrentTriggersCollapseIntoOneUpstreamRequest() async throws {
        let fixture = try makeFixture(
            enabled: true,
            workspacePages: ["h05-project": page([session(id: "h05-one-1")])]
        )

        // 建立协调器（同时完成第一次请求）。
        await fixture.store.refreshNativeHarnessDirectory(
            workspace: fixture.workspace,
            consistency: .authoritative,
            restartFromFirst: true,
            hostScope: fixture.appStore.activeHostScope,
            generation: fixture.appStore.connectionGeneration
        )
        let directory = try XCTUnwrap(fixture.store.nativeHarnessDirectory)
        let afterFirst = fixture.client.requestedWorkspaceIDs.count
        XCTAssertEqual(afterFirst, 1, "第一次刷新应当只发一次")

        // 在途期间连发失效信号：必须合并，结束后至多补一次尾随刷新。
        directory.refresh(manual: true)
        directory.notifyDirectoryMayHaveChanged()
        directory.notifyDirectoryMayHaveChanged()
        await directory.waitForInFlightRequest()

        let total = fixture.client.requestedWorkspaceIDs.count
        XCTAssertLessThanOrEqual(
            total, afterFirst + 2,
            "三次触发最多产生「当前这一次 + 一次尾随」；实际发了 \(total - afterFirst) 次"
        )
        XCTAssertGreaterThan(
            total, afterFirst,
            "在途期间的失效信号不能被吞掉，至少要补发一次"
        )
    }
}

// MARK: - 夹具

private struct HarnessDirectoryWiringFixture {
    let appStore: AppStore
    let store: SessionStore
    let client: MockSessionStoreClient
    let workspace: AgentWorkspace

    /// 与接线层构造的查询同形。`AppStore.activeHostScope` 是主 actor 隔离的，
    /// 因此这个查询身份也必须在主 actor 上取。
    @MainActor
    var query: HarnessSessionDirectoryQuery {
        HarnessSessionDirectoryQuery(
            hostScope: appStore.activeHostScope,
            runtimeProvider: SessionStore.nativeHarnessRuntimeProvider,
            scope: .workspace(id: workspace.id, path: workspace.path)
        )
    }
}

@MainActor
private func makeFixture(
    enabled: Bool,
    workspacePages: [String: SessionsPage] = [:],
    workspaceSessionsError: [String: Error] = [:]
) throws -> HarnessDirectoryWiringFixture {
    let project = AgentProject(id: "h05-project", name: "H05 工作区", path: "/h05/workspace")
    let workspace = AgentWorkspace(project: project)
    let appStore = makeIsolatedAppStoreForHarnessWiring()
    appStore.token = "test-token"

    let client = MockSessionStoreClient(
        projects: [project],
        sessions: [],
        workspacePages: workspacePages,
        messagesResult: [],
        workspaceSessionsError: workspaceSessionsError
    )
    let store = SessionStore(
        appStore: appStore,
        conversationStore: ConversationStore(),
        logStore: LogStore(),
        recentWorkspaceStore: makeRecentWorkspaceStore(
            workspaces: [workspace],
            endpoint: appStore.endpoint
        ),
        clientFactory: { client }
    )
    if enabled {
        store.nativeHarnessRollout = HarnessNativeRollout(isEnabled: true)
    }
    // 让工作区进入 workspacesByID：`isCurrentWorkspaceIdentity` 靠它确认归属，
    // 否则交付会被自己拒绝，测出来的是夹具没准备好而不是接线没生效。
    store.recentWorkspaces = [workspace]
    store.rebuildWorkspaceIndex()
    return HarnessDirectoryWiringFixture(
        appStore: appStore,
        store: store,
        client: client,
        workspace: workspace
    )
}

/// 隔离的 AppStore。与既有 `makeIsolatedAppStore` 同形，避免依赖测试类的实例方法。
@MainActor
private func makeIsolatedAppStoreForHarnessWiring() -> AppStore {
    let suiteName = "MimiRemoteTests.HarnessWiring.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppStore(defaults: defaults, tokenStore: TokenStore(keychain: TestKeychainOperations()))
}

private func page(_ sessions: [AgentSession]) -> SessionsPage {
    SessionsPage(sessions: sessions, nextCursor: nil, hasMore: false)
}

private func session(id: String) -> AgentSession {
    AgentSession(
        id: id,
        projectID: "h05-project",
        project: "H05 工作区",
        dir: "/h05/workspace",
        title: id,
        status: "history",
        source: "deepseek",
        runtimeProvider: "deepseek",
        resumeID: nil,
        createdAt: nil,
        updatedAt: nil
    )
}

private actor HarnessDirectoryCodexTransportSpyState {
    private(set) var count = 0

    func record() { count += 1 }
}

/// 一旦目录误入 Codex 就立即失败，避免测试等待一个永远不会到达的 app-server 回包。
private final class HarnessDirectoryCodexTransportSpy: CodexAppServerTransport {
    private let state = HarnessDirectoryCodexTransportSpyState()

    func connect(url: URL, token: String) async throws {
        await state.record()
        throw CodexAppServerSessionRuntimeError.gatewayUnavailable
    }

    func send(_ text: String) async throws {
        await state.record()
        throw CodexAppServerSessionRuntimeError.gatewayUnavailable
    }

    func receive() async throws -> String? {
        await state.record()
        throw CodexAppServerSessionRuntimeError.gatewayUnavailable
    }

    func close() async {}

    func touchCount() async -> Int { await state.count }
}

import XCTest
@testable import MimiRemote

/// #792：受控全局发现的 cursor 由签发它的网关连接独占。连接或凭据换代后，
/// 旧遍历必须停下或从首页重来，不能把旧 cursor 发到另一条连接上。
@MainActor
final class ControlledGlobalCursorLifecycleTests: XCTestCase {
    func testBackgroundSuspendStopsTraversalBeforeReplayingOldCursor() async throws {
        let project = makeProject(id: "proj_global_cursor_background")
        let gate = ControlledGlobalCursorGate()
        let log = ControlledGlobalRequestLog()
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsByRuntimeHandler: { runtimeProvider, cursor, _ in
                log.record(runtimeProvider, cursor)
                guard runtimeProvider == "claude" else { return SessionsPage(sessions: []) }
                if cursor == nil {
                    await gate.blockUntilReleased()
                    return SessionsPage(sessions: [], nextCursor: "claude-page-2", hasMore: true)
                }
                return SessionsPage(sessions: [])
            }
        )
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let refresh = Task { await store.refreshSessionLibraryIndex() }
        await gate.waitUntilBlocked()
        // 与 RootView 进入后台的顺序一致：先挂起 SessionStore，再丢弃凭据和 Runtime bundle。
        store.suspendForBackground()
        appStore.suspendCredentialsForBackground()
        await gate.release()
        await refresh.value

        XCTAssertFalse(
            log.cursors(runtimeProvider: "claude").contains("claude-page-2"),
            "回后台前开始的遍历不能在回前台后继续翻页：旧 bundle 会新建连接重放旧 cursor"
        )
        XCTAssertNil(
            store.lastSessionLibraryIndexRefreshAt,
            "被后台打断的遍历不能记成刚刷新过，否则回前台的轮询要多等一个周期"
        )

        // 回前台：resumeFromForeground 先清掉后台标记，再由轮询发起下一轮。
        store.isAppInBackground = false
        log.reset()
        await store.refreshSessionLibraryIndex()
        XCTAssertEqual(log.cursors(runtimeProvider: "claude").first, .some(nil), "下一轮必须从首页开始")
    }

    func testExpiredCursorRestartsRuntimeFromFirstPageOnceAndStillRevokes() async {
        let fixture = makeRevocationFixture(id: "restart")
        await fixture.store.refreshSessionLibraryIndex(authoritative: true)
        XCTAssertTrue(fixture.store.sessions.contains { $0.id == fixture.stale.id }, "首轮应发现两条 Claude 会话")

        // 第二轮：续页 cursor 已随连接换代失效，从首页重走后完整遍历，stale 已不在。
        fixture.log.reset()
        fixture.script.set { cursor, firstPageCount in
            switch (cursor, firstPageCount) {
            case (nil, 1):
                return SessionsPage(sessions: [fixture.live], nextCursor: "claude-old", hasMore: true)
            case ("claude-old", _):
                throw ControlledGlobalListCursorExpiredError()
            default:
                return SessionsPage(sessions: [fixture.live])
            }
        }
        await fixture.store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertEqual(fixture.log.cursors(runtimeProvider: "claude"), [nil, "claude-old", nil])
        XCTAssertFalse(
            fixture.store.sessions.contains { $0.id == fixture.stale.id },
            "重走后完整遍历仍是撤权证据，已消失的会话要移除"
        )
        XCTAssertTrue(fixture.store.sessions.contains { $0.id == fixture.live.id })
    }

    func testRepeatedCursorExpiryStopsRuntimeTraversalWithoutRevoking() async {
        let fixture = makeRevocationFixture(id: "repeat")
        await fixture.store.refreshSessionLibraryIndex(authoritative: true)

        fixture.log.reset()
        fixture.script.set { cursor, firstPageCount in
            switch cursor {
            case nil:
                return SessionsPage(sessions: [fixture.live], nextCursor: "claude-old-\(firstPageCount)", hasMore: true)
            default:
                throw ControlledGlobalListCursorExpiredError()
            }
        }
        await fixture.store.refreshSessionLibraryIndex(authoritative: true)

        XCTAssertEqual(
            fixture.log.cursors(runtimeProvider: "claude"),
            [nil, "claude-old-1", nil, "claude-old-2"],
            "每轮每个渠道最多从首页重走一次"
        )
        XCTAssertTrue(
            fixture.store.sessions.contains { $0.id == fixture.stale.id },
            "没走完的遍历不是撤权证据，不能误删会话"
        )
    }

    func testRuntimeDoesNotReplayCursorAfterIssuingConnectionRetires() async throws {
        let (runtime, pool) = makeGlobalListRuntime(id: "retired")
        let first = try await loadFirstGlobalPage(runtime: runtime, pool: pool, index: 0, nextCursor: "mimi_old")
        let installedConnection = await runtime.connection
        let issuing = try XCTUnwrap(installedConnection)
        await runtime.retireConnection(issuing)

        do {
            _ = try await runtime.controlledGlobalSessionsPage(cursor: "mimi_old", limit: 50)
            XCTFail("签发连接已退役，旧 cursor 必须被拒")
        } catch {
            XCTAssertTrue(error is ControlledGlobalListCursorExpiredError, "\(error)")
        }
        XCTAssertNil(pool.transport(at: 1), "不为一个必然被网关拒绝的续页新建连接")

        // 调用方从首页重来：新连接只发不带 cursor 的首页，之后用新连接签发的 cursor 正常续翻。
        let second = try await loadFirstGlobalPage(runtime: runtime, pool: pool, index: 1, nextCursor: "mimi_new")
        let beforeNext = await second.sentMessages().count
        let nextTask = Task { try await runtime.controlledGlobalSessionsPage(cursor: "mimi_new", limit: 50) }
        let next = try await waitForFakeAppServerRequest(second, method: "thread/list", after: beforeNext)
        XCTAssertEqual(next.params?.objectValue?["cursor"]?.stringValue, "mimi_new")
        transportResponse(second, id: next.id, result: appServerThreadListResult([], nextCursor: nil))
        _ = try await nextTask.value

        let replayed = await second.sentMessages().contains { $0.contains("mimi_old") }
        XCTAssertFalse(replayed, "旧连接签发的 cursor 不能出现在新连接上")
        let oldConnectionCloses = await first.closeCallCount()
        XCTAssertGreaterThan(oldConnectionCloses, 0, "退役的签发连接应已关闭")
    }

    func testGatewayCursorRejectionSurfacesAsExpiredCursor() async throws {
        let (runtime, pool) = makeGlobalListRuntime(id: "rejected")
        let first = try await loadFirstGlobalPage(runtime: runtime, pool: pool, index: 0, nextCursor: "mimi_rotated")
        let beforeNext = await first.sentMessages().count
        let nextTask = Task { try await runtime.controlledGlobalSessionsPage(cursor: "mimi_rotated", limit: 50) }
        let next = try await waitForFakeAppServerRequest(first, method: "thread/list", after: beforeNext)
        transportErrorResponse(
            first,
            id: next.id,
            code: -32080,
            message: "thread/list.cursor 已失效或不属于当前授权连接"
        )
        do {
            _ = try await nextTask.value
            XCTFail("gateway 拒绝 cursor 时应报告 cursor 失效")
        } catch {
            XCTAssertTrue(error is ControlledGlobalListCursorExpiredError, "\(error)")
        }
    }

    private struct RevocationFixture {
        let store: SessionStore
        let log: ControlledGlobalRequestLog
        let script: ClaudeGlobalPageScript
        let stale: AgentSession
        let live: AgentSession
    }

    /// Claude 首轮返回 stale + live 两条完整结果，之后的轮次由 script 决定；Codex 与其他渠道恒为空页。
    private func makeRevocationFixture(id: String) -> RevocationFixture {
        let project = makeProject(id: "proj_global_cursor_\(id)")
        let stale = makeSession(
            id: "claude-stale-\(id)", projectID: project.id, title: "已删除的 Claude 会话",
            status: "history", source: "claude", runtimeProvider: "claude", resumeID: "claude-stale-\(id)"
        )
        let live = makeSession(
            id: "claude-live-\(id)", projectID: project.id, title: "仍在的 Claude 会话",
            status: "history", source: "claude", runtimeProvider: "claude", resumeID: "claude-live-\(id)"
        )
        let log = ControlledGlobalRequestLog()
        let script = ClaudeGlobalPageScript { _, _ in SessionsPage(sessions: [stale, live]) }
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            controlledGlobalSessionsByRuntimeHandler: { runtimeProvider, cursor, _ in
                log.record(runtimeProvider, cursor)
                guard runtimeProvider == "claude" else { return SessionsPage(sessions: []) }
                return try script.page(cursor: cursor)
            }
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        return RevocationFixture(store: store, log: log, script: script, stale: stale, live: live)
    }

    private func makeGlobalListRuntime(id: String) -> (CodexAppServerSessionRuntime, FakeCodexAppServerTransportPool) {
        let project = AgentProject(id: "global-cursor-\(id)", name: "Global Cursor", path: "/tmp/global-cursor-\(id)")
        let pool = FakeCodexAppServerTransportPool()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787", token: "test",
            transportFactory: { pool.make() },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        return (runtime, pool)
    }

    /// 在第 index 条连接上完成 initialize 并返回一页带 nextCursor 的空首页（不触发索引补扫）。
    private func loadFirstGlobalPage(
        runtime: CodexAppServerSessionRuntime,
        pool: FakeCodexAppServerTransportPool,
        index: Int,
        nextCursor: String
    ) async throws -> FakeCodexAppServerTransport {
        let task = Task { try await runtime.controlledGlobalSessionsPage(cursor: nil, limit: 50) }
        let transport = try await waitForFakeAppServerTransport(in: pool, index: index)
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(transport, id: initialize.id, result: #"{"userAgent":"fake"}"#)
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        XCTAssertNil(list.params?.objectValue?["cursor"]?.stringValue, "首页不能带 cursor")
        transportResponse(transport, id: list.id, result: appServerThreadListResult([], nextCursor: nextCursor))
        let page = try await task.value
        XCTAssertEqual(page.nextCursor, nextCursor)
        return transport
    }
}

/// 按「请求的 cursor + 本轮已请求首页的次数」脚本化 Claude 全局页。
private final class ClaudeGlobalPageScript: @unchecked Sendable {
    typealias Handler = (String?, Int) throws -> SessionsPage
    private let lock = NSLock()
    private var handler: Handler
    private var firstPageCount = 0

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func set(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            firstPageCount = 0
        }
    }

    func page(cursor: String?) throws -> SessionsPage {
        let (handler, count) = lock.withLock { () -> (Handler, Int) in
            if cursor == nil { firstPageCount += 1 }
            return (self.handler, firstPageCount)
        }
        return try handler(cursor, count)
    }
}

private actor ControlledGlobalCursorGate {
    private var isBlocked = false
    private var isReleased = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() async {
        guard !isReleased else { return }
        isBlocked = true
        blockWaiters.forEach { $0.resume() }
        blockWaiters.removeAll()
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { blockWaiters.append($0) }
    }

    func release() {
        isReleased = true
        blocked.forEach { $0.resume() }
        blocked.removeAll()
    }
}

private final class ControlledGlobalRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(runtimeProvider: String, cursor: String?)] = []

    func record(_ runtimeProvider: String, _ cursor: String?) {
        lock.withLock { requests.append((runtimeProvider, cursor)) }
    }

    func cursors(runtimeProvider: String) -> [String?] {
        lock.withLock { requests.filter { $0.runtimeProvider == runtimeProvider }.map(\.cursor) }
    }

    func reset() {
        lock.withLock { requests.removeAll() }
    }
}

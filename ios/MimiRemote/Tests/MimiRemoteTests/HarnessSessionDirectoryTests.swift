import Foundation
import XCTest
@testable import MimiRemote

/// H05 目录测试。
///
/// 三条纪律与 H04 相同：
/// 1. **夹具共用**：list / search 的形状断言读 `contracts/harness-native/fixtures/*`，
///    与 Go 侧读同一份字节。Swift 自己造一份"自洽"的形状等于把契约漂移藏进测试里。
/// 2. **fake 时钟**：前台 5 秒兜底、后台停表这类时序策略必须由可控时钟验证。
///    用真实 `sleep` 去赌时序，测出来的只是机器忙闲。
/// 3. **每条拒绝配一条正向对照**：只有负向用例的套件可能整体是空断言。
@MainActor
final class HarnessSessionDirectoryTests: XCTestCase {

    // MARK: - 夹具共用

    func harnessFixture(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name))
    }

    func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: harnessFixture(name))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    /// 取某个 observation 的 value。
    func harnessObservation(_ name: String, label: String) throws -> HarnessJSONValue {
        let fixture = try harnessFixtureJSON(name)
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let match = observations.first { ($0["label"] as? String) == label }
        let value = try XCTUnwrap(match?["value"], "夹具 \(name) 缺少观测 \(label)")
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(HarnessJSONValue.self, from: data)
    }

    private func jsonValue(_ object: [String: Any]) throws -> HarnessJSONValue {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(HarnessJSONValue.self, from: data)
    }

    // MARK: - 1. session/list 解码

    /// 正向对照：真实夹具的 `result-populated` 必须解出真实条目。
    func testListDecodingMatchesSharedSessionListFixture() throws {
        let value = try harnessObservation("rpc/session-list.json", label: "result-populated")

        let page = try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        )

        // 夹具里 8 条都是同一个 sessionId（同一会话的多次投影），去重后只剩 1 条。
        XCTAssertEqual(page.sessions.count, 1)
        let session = try XCTUnwrap(page.sessions.first)
        XCTAssertEqual(session.id, "h00-session-0001")
        XCTAssertEqual(session.runtimeProvider, "deepseek")
        XCTAssertEqual(session.source, "deepseek")
        XCTAssertEqual(session.dir, "/h00/workspace")
        // 标题在 `projections.values.title`，**不在顶层**（夹具的 itemShapeNote 明写了这一点）。
        // 但这份夹具的 populated 项恰好是 blank 会话，`title` 就是 null —— 所以只能断言空标题。
        // 单靠这一条分不出"从 projections 读"和"压根没读标题"，正向对照见下一条用例。
        XCTAssertEqual(session.title, "")
        XCTAssertFalse(session.isRunning)
        // updatedAt 是毫秒。
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 1789755507.165))
        // 上游没有服务端分页：首屏即全量，不得伪造 cursor。
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
    }

    /// 标题来源的**正向对照**：只认 `projections.values.title`，顶层 `title` 必须被忽略。
    ///
    /// 共享夹具的 populated 项是 blank 会话（`title: null`），所以它上面那条断言对
    /// "读 projections" 和 "根本没读标题" 两种实现都成立。这条本地形状把两者分开：
    /// 两个来源同时给出不同的值，取错来源立刻显形。
    func testTitleComesFromProjectionsNotTopLevel() throws {
        let value = try jsonValue([
            "items": [[
                "sessionId": "s-title",
                "cwd": "/h05/title",
                "title": "顶层标题（必须被忽略）",
                "projections": ["values": ["title": "投影标题"]]
            ]]
        ])
        let page = try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        )
        XCTAssertEqual(page.sessions.first?.title, "投影标题")
    }

    func testListPreservesResumeIDAndSubagentIdentity() throws {
        let value = try jsonValue(["items": [
            ["sessionId": "root", "cwd": "/h05/workspace", "running": false],
            ["sessionId": "child", "cwd": "/h05/workspace", "parentSessionId": "root", "origin": "subagent"],
            ["sessionId": "orphan-child", "cwd": "/h05/workspace", "origin": "subagent"]
        ]])
        let page = try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        )

        XCTAssertEqual(page.sessions.count, 3, "子会话仍需保留在 canonical 目录供父子导航使用")
        XCTAssertEqual(page.sessions.first?.resumeID, "root")
        XCTAssertFalse(try XCTUnwrap(page.sessions.first).isSubagentThread)
        XCTAssertEqual(page.sessions[1].parentThreadID, "root")
        XCTAssertTrue(page.sessions[1].isSubagentThread)
        XCTAssertTrue(page.sessions[2].isSubagentThread)
    }

    /// 空表是**合法结果**，不是失败。
    func testEmptyListIsASuccessfulEmptyPage() throws {
        let value = try harnessObservation("rpc/session-list.json", label: "result-empty")
        let page = try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        )
        XCTAssertTrue(page.sessions.isEmpty)
    }

    /// 负向：形状不符必须显式失败，不能返回空页。
    func testListDecodingRejectsShapeWithoutItems() throws {
        let value = try jsonValue(["default": ["provider": "p"]])
        XCTAssertThrowsError(try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        ))
    }

    /// 负向：缺身份的条目必须整页失败。
    ///
    /// 目录是授权事实来源，"少了一条"和"这条被撤权了"长得一模一样；
    /// 静默丢一条等于让一次形状错误伪装成一次撤权。
    func testListDecodingRejectsItemWithoutSessionID() throws {
        let value = try jsonValue(["items": [["updatedAt": 1, "cwd": "/h05/workspace"]]])
        XCTAssertThrowsError(try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        ))
    }

    /// 工作区查询必须把归属落在该工作区上，而不是留在全局。
    func testWorkspaceListDecodingAssignsWorkspaceIdentity() throws {
        let value = try harnessObservation("rpc/session-list.json", label: "result-populated")
        let workspace = AgentWorkspace(id: "ws-1", name: "H05 工作区", path: "/h00/workspace")

        let page = try HarnessSessionDirectoryDecoding.sessionsPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: workspace
        )

        XCTAssertEqual(page.sessions.first?.projectID, "ws-1")
        XCTAssertEqual(page.sessions.first?.project, "H05 工作区")
    }

    // MARK: - 2. session/modelCatalog 解码

    /// 正向对照：模型身份必须保留 runtime/provider/model 与**真实**推理档位。
    ///
    /// 边界形状（多 provider、同名模型跨 provider、`failures` 非空、缺 reasoning）走本地形状：
    /// 本次实跑只配置了一条回环路由，这些情况不在采集范围内，写进共享夹具就是编造数据。
    /// 真实采集到的那一份由下面 `testModelCatalogDecodingMatchesSharedFixture` 读共享夹具覆盖。
    func testModelCatalogDecodingKeepsProviderAndRealReasoningEfforts() throws {
        let value = try jsonValue([
            "default": ["provider": "provider-fixture-a", "model": "model-fixture-1", "reasoningEffort": "off"],
            "routableProviders": ["provider-fixture-a", "provider-fixture-b"],
            "groups": [
                [
                    "id": "provider-fixture-a",
                    "name": "Fixture Provider A",
                    "models": [
                        [
                            "id": "model-fixture-1",
                            "name": "Fixture Model 1",
                            "description": "fixture model",
                            "reasoning": [
                                "efforts": [
                                    ["id": "off", "name": "Off"],
                                    ["id": "low", "name": "Low"],
                                    ["id": "high", "name": "High"],
                                    ["id": "max", "name": "Max"]
                                ],
                                "defaultEffort": "off"
                            ]
                        ],
                        ["id": "model-fixture-2", "name": "Fixture Model 2"]
                    ]
                ],
                ["id": "provider-fixture-b", "name": "Fixture Provider B", "models": [
                    ["id": "model-fixture-1", "name": "Fixture Model 1 (B)"]
                ]]
            ],
            "failures": [["id": "provider-fixture-c", "name": "Fixture Provider C", "message": "catalog lookup failed"]]
        ])

        let options = try HarnessSessionDirectoryDecoding.modelOptions(
            from: value,
            runtimeProvider: "deepseek"
        )

        // 三家 provider 里只有两家有目录；同名模型必须按 provider 分开，不能合并成一条。
        XCTAssertEqual(options.count, 3)
        let first = try XCTUnwrap(options.first)
        XCTAssertEqual(first.model, "model-fixture-1")
        XCTAssertEqual(first.provider, "provider-fixture-a")
        XCTAssertEqual(first.runtimeProvider, "deepseek")
        XCTAssertEqual(first.title, "Fixture Model 1")
        XCTAssertEqual(first.description, "fixture model")
        XCTAssertTrue(first.isDefault)
        // 真实推理档位来自 reasoning.efforts，不能拿固定档位表顶上。
        XCTAssertEqual(first.supportedReasoningEfforts, ["off", "low", "high", "max"])
        XCTAssertEqual(first.defaultReasoningEffort, "off")

        let second = try XCTUnwrap(options.dropFirst().first)
        XCTAssertEqual(second.model, "model-fixture-2")
        XCTAssertFalse(second.isDefault)
        XCTAssertTrue(second.supportedReasoningEfforts.isEmpty)
        XCTAssertNil(second.defaultReasoningEffort)

        let crossProvider = try XCTUnwrap(options.last)
        XCTAssertEqual(crossProvider.model, "model-fixture-1")
        XCTAssertEqual(crossProvider.provider, "provider-fixture-b")
        XCTAssertNotEqual(crossProvider.id, first.id, "同名模型跨 provider 必须有不同身份")
    }

    /// 正向对照：真实采集的模型目录必须解出真实身份。
    ///
    /// 这是与 Go 侧读**同一份字节**的那条断言。此前该夹具的 `result` 被误写成
    /// session/list 数据，模型目录只能靠本地形状自证，两边各自漂移也看不出来。
    /// 夹具修正后这条恢复，漂移风险才真正消除。
    func testModelCatalogDecodingMatchesSharedFixture() throws {
        let value = try harnessObservation("rpc/session-model-catalog.json", label: "result")

        let options = try HarnessSessionDirectoryDecoding.modelOptions(
            from: value,
            runtimeProvider: "deepseek"
        )

        // 实跑只配置了一条回环路由，因此只有一组、一个模型。
        XCTAssertEqual(options.count, 1)
        let option = try XCTUnwrap(options.first)
        XCTAssertEqual(option.provider, "h00-loopback")
        XCTAssertEqual(option.model, "h00-mock-model")
        XCTAssertEqual(option.runtimeProvider, "deepseek")
        // 目录默认项由 default.provider/model 判定，不按顺序猜。
        XCTAssertTrue(option.isDefault)
        // 真实档位来自 reasoning.efforts，逐个原样带入（未登记字符串降级为 <string:N>）。
        XCTAssertEqual(option.supportedReasoningEfforts, ["<string:7>", "<string:8>"])
        XCTAssertEqual(option.defaultReasoningEffort, "<string:8>")
    }

    /// 负向：不是模型目录的形状必须显式失败。
    ///
    /// 返回空数组会把"形状错了"显示成"Harness 没有可用模型"——那是一个业务结论，
    /// 而这里根本没有拿到过业务结论。
    ///
    /// 反例直接用 session/list 的夹具：本次缺陷正是"model-catalog 文件里装了
    /// session/list 数据"，即这个错配真实发生过。用真实发生过的错配当反例，
    /// 比编一个假的畸形 JSON 更有判别力。
    func testModelCatalogDecodingRejectsNonCatalogShape() throws {
        let sessionListShaped = try harnessObservation("rpc/session-list.json", label: "result-populated")
        XCTAssertThrowsError(try HarnessSessionDirectoryDecoding.modelOptions(
            from: sessionListShaped,
            runtimeProvider: "deepseek"
        )) { error in
            XCTAssertEqual(
                error as? HarnessTransportError,
                .malformedResponse("session/modelCatalog result is missing groups")
            )
        }
    }

    /// 空目录（`groups: []`）是合法结果，与形状错误区分开。
    func testEmptyModelCatalogIsASuccessfulEmptyCatalog() throws {
        let value = try jsonValue(["groups": [], "routableProviders": [], "failures": []])
        let options = try HarnessSessionDirectoryDecoding.modelOptions(
            from: value,
            runtimeProvider: "deepseek"
        )
        XCTAssertTrue(options.isEmpty)
    }

    // MARK: - 3. session/search 解码

    /// 正向对照：搜索结果只带 ID 与片段，必须原样保留。
    func testSearchDecodingMatchesSharedSessionSearchFixture() throws {
        let fixture = try harnessFixtureJSON("rpc/session-search.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [String: Any])
        let success = try XCTUnwrap(cases["success"] as? [String: Any])
        let result = try XCTUnwrap(success["result"] as? [String: Any])
        let value = try jsonValue(try XCTUnwrap(result["value"] as? [String: Any]))

        let page = try HarnessSessionDirectoryDecoding.searchPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        )

        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results.first?.session.id, "session-fixture-0001")
        XCTAssertEqual(page.results.first?.snippet, "fixture snippet text")
        XCTAssertEqual(page.results.first?.session.runtimeProvider, "deepseek")
        // 搜索没有服务端分页游标可用：不得凭空造一个。
        XCTAssertNil(page.nextCursor)
    }

    /// 负向：命中项缺 sessionId 无法归属，必须显式失败。
    func testSearchDecodingRejectsHitWithoutSessionID() throws {
        let value = try jsonValue(["items": [["snippet": "orphan"]]])
        XCTAssertThrowsError(try HarnessSessionDirectoryDecoding.searchPage(
            from: value,
            runtimeProvider: "deepseek",
            workspace: nil
        ))
    }

    // MARK: - 4. 客户端请求形状

    func testListRequestCarriesWorkspaceCWDOutsideArgs() async throws {
        let transport = RecordingHarnessRPCTransport()
        transport.result = .success(try harnessObservation("rpc/session-list.json", label: "result-empty"))
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)
        let workspace = AgentWorkspace(id: "ws-1", name: "H05", path: "/h05/workspace")

        _ = try await client.sessionsPage(
            workspace: workspace,
            cursor: nil,
            limit: nil,
            consistency: .authoritative
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "session/list")
        // 形参名带下划线；写成 request 会被 Harness 网关判为 gateway/arguments-invalid。
        XCTAssertEqual(request.args, .object(["_request": .object([:])]))
        XCTAssertEqual(request.cwd, "/h05/workspace")
        // cwd 是授权提示，必须留在 args 之外——混进 args 就成了发给上游的未知参数。
        XCTAssertNil(request.args?["cwd"])
    }

    func testGlobalListRequestCarriesNoCWD() async throws {
        let transport = RecordingHarnessRPCTransport()
        transport.result = .success(try harnessObservation("rpc/session-list.json", label: "result-empty"))
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)

        _ = try await client.controlledGlobalSessionsPage(cursor: nil, limit: 50)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertNil(request.cwd, "无 cwd 才表示全部已授权会话")
    }

    func testModelCatalogRequestSendsEmptyArgsAndNoCWD() async throws {
        let transport = RecordingHarnessRPCTransport()
        transport.result = .success(try jsonValue(["groups": []]))
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)

        _ = try await client.modelOptions()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "session/modelCatalog")
        // 该方法描述符没有参数：必须传空对象，省略或带键都会被中继拒。
        XCTAssertEqual(request.args, .object([:]))
        XCTAssertNil(request.cwd, "modelCatalog 不接受 cwd 提示")
    }

    func testSearchRequestUsesPlainRequestKey() async throws {
        let transport = RecordingHarnessRPCTransport()
        transport.result = .success(try jsonValue(["items": [], "hasMore": false]))
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)

        _ = try await client.searchSessions(query: "  h05 query  ", cursor: nil, limit: nil)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "session/search")
        // search 的形参名没有下划线，与 list 不同；query 要去掉首尾空白。
        XCTAssertEqual(request.args, .object(["request": .object(["query": .string("h05 query")])]))
    }

    /// 空 query 必须在本地被拒，且**不触达网络**。
    func testEmptySearchQueryIsRejectedWithoutTouchingNetwork() async throws {
        let transport = RecordingHarnessRPCTransport()
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)

        do {
            _ = try await client.searchSessions(query: "   ", cursor: nil, limit: nil)
            XCTFail("空 query 不得当成零命中")
        } catch {
            XCTAssertEqual(
                error as? HarnessTransportError,
                .rejected(status: 400, message: "Search query must not be empty")
            )
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// 通道探测必须是零参数只读方法，不触发任何模型调用。
    func testChannelAvailableProbesWithZeroArgumentReadOnlyCall() async throws {
        let transport = RecordingHarnessRPCTransport()
        transport.result = .success(try jsonValue(["groups": []]))
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)

        let available = try await client.channelAvailable()

        XCTAssertTrue(available)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "session/modelCatalog")
        XCTAssertEqual(request.args, .object([:]))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testChannelAvailablePropagatesFailureInsteadOfReportingUnavailable() async throws {
        let transport = RecordingHarnessRPCTransport()
        transport.result = .failure(HarnessTransportError.unauthorized(status: 401))
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)

        do {
            _ = try await client.channelAvailable()
            XCTFail("探测失败必须抛错：返回 false 会与「探测本身没跑」混成同一件事")
        } catch {
            XCTAssertEqual(error as? HarnessTransportError, .unauthorized(status: 401))
        }
    }

    /// 端到端：夹具结果经客户端落到共用展示模型上。
    func testClientDecodesFixtureIntoSharedDisplayModel() async throws {
        let transport = RecordingHarnessRPCTransport()
        transport.result = .success(try harnessObservation("rpc/session-list.json", label: "result-populated"))
        let client = HarnessSessionAPIClient(endpoint: "http://127.0.0.1:8787", token: "fixture", rpc: transport)

        let page = try await client.sessionsPage(
            projectID: nil,
            cursor: nil,
            limit: nil,
            consistency: .fastIndexed
        )

        XCTAssertEqual(page.sessions.map(\.id), ["h00-session-0001"])
        // 端到端只断言夹具里**真的非空**的字段：这条链路证明的是"夹具的字节能走到共用展示模型"。
        // title 在夹具里是 null（blank 会话），给它断言一个具体标题就是凭空发明期望值——
        // 那会让测试红在一个从未存在过的数据上，而掩盖链路本身是否通。
        XCTAssertEqual(page.sessions.first?.dir, "/h00/workspace")
        XCTAssertEqual(page.sessions.first?.title, "")
    }

    // MARK: - 5. 前台兜底与刷新代次（fake 时钟）

    func testForegroundListRefreshesAtMostOncePerFiveSeconds() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }

        directory.setListVisible(true, isForeground: true)
        fetch.resumeNext(with: .success(page(["s-1"])))
        await waitUntil { directory.state == .loaded }

        // 4 秒不到：不得再发请求。
        clock.advance(by: 4)
        await drain()
        XCTAssertEqual(fetch.callCount, 1)

        // 满 5 秒：补一次合并后的请求。
        clock.advance(by: 1)
        await waitUntil { fetch.callCount == 2 }
        XCTAssertEqual(fetch.callCount, 2)
    }

    func testBackgroundStopsFallbackTimer() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }
        fetch.resumeNext(with: .success(page(["s-1"])))
        await waitUntil { directory.state == .loaded }

        directory.setListVisible(true, isForeground: false)
        clock.advance(by: 60)
        await drain()

        XCTAssertEqual(fetch.callCount, 1, "后台不得继续轮询目录")
    }

    func testLeavingListStopsFallbackTimer() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }
        fetch.resumeNext(with: .success(page(["s-1"])))
        await waitUntil { directory.state == .loaded }

        directory.setListVisible(true, isForeground: true)
        directory.setListVisible(false, isForeground: true)
        clock.advance(by: 60)
        await drain()

        XCTAssertEqual(fetch.callCount, 1, "离开列表必须立刻停表")
    }

    /// 并发触发合并成一个在途请求，结束后最多补一次。
    func testConcurrentTriggersCollapseIntoOneRequestWithOneTrailingRefresh() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }

        // 在途期间连来三次失效信号：只能合并成一次尾随刷新，不能吞掉也不能各发一次。
        directory.notifyDirectoryMayHaveChanged()
        directory.notifyDirectoryMayHaveChanged()
        directory.notifyDirectoryMayHaveChanged()
        await drain()
        XCTAssertEqual(fetch.callCount, 1, "在途期间的触发不得各自再发请求")

        fetch.resumeNext(with: .success(page(["s-1"])))
        await waitUntil { fetch.callCount == 2 }
        fetch.resumeNext(with: .success(page(["s-1", "s-2"])))
        // 不能等 `state == .loaded`：第一次响应就把它置成 loaded 了，条件立刻为真，
        // waitUntil 于是直接返回，尾随刷新那一次的结果还没落地就开始断言。
        // 等**内容**，才是等这次刷新真的生效。
        await waitUntil { directory.sessions.map(\.id) == ["s-1", "s-2"] }

        XCTAssertEqual(fetch.callCount, 2, "结束后最多补一次")
        XCTAssertEqual(directory.sessions.map(\.id), ["s-1", "s-2"])
    }

    /// 切工作区：旧回调必须被拒，晚到的旧页不得覆盖新页。
    func testLateResultFromPreviousScopeCannotOverwriteNewPage() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .workspace(id: "ws-a", path: "/h05/a")))
        await waitUntil { fetch.callCount == 1 }
        directory.activate(query: makeQuery(scope: .workspace(id: "ws-b", path: "/h05/b")))
        await waitUntil { fetch.callCount == 2 }
        XCTAssertTrue(directory.sessions.isEmpty, "切换作用域后不得继续显示上一个工作区的页")

        // 旧作用域的结果晚到：必须丢弃。
        fetch.resumeNext(with: .success(page(["from-ws-a"])))
        await drain()
        XCTAssertTrue(directory.sessions.isEmpty)
        XCTAssertNotEqual(directory.state, .loaded)

        fetch.resumeNext(with: .success(page(["from-ws-b"])))
        await waitUntil { directory.state == .loaded }
        XCTAssertEqual(directory.sessions.map(\.id), ["from-ws-b"])
    }

    /// 手动刷新必须真的发新请求，且不被在途的旧结果覆盖。
    func testManualRefreshIssuesNewRequestInsteadOfReusingInflightResult() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }

        directory.refresh(manual: true)
        await waitUntil { fetch.callCount == 2 }

        fetch.resumeNext(with: .success(page(["stale"])))
        await drain()
        XCTAssertTrue(directory.sessions.isEmpty, "手动刷新前的在途结果不得落地")

        fetch.resumeNext(with: .success(page(["fresh"])))
        await waitUntil { directory.state == .loaded }
        XCTAssertEqual(directory.sessions.map(\.id), ["fresh"])
    }

    /// 失败保留旧页并显示失败——绝不把失败解释成空列表。
    func testFailureKeepsPreviousPageAndReportsError() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }
        fetch.resumeNext(with: .success(page(["s-1"])))
        await waitUntil { directory.state == .loaded }

        directory.refresh(manual: true)
        await waitUntil { fetch.callCount == 2 }
        fetch.resumeNext(with: .failure(HarnessTransportError.server(status: 503, message: "upstream down")))
        await waitUntil { directory.state.isFailed }

        XCTAssertEqual(directory.sessions.map(\.id), ["s-1"], "失败不得清空旧页")
        XCTAssertEqual(
            directory.state,
            .failed(HarnessTransportError.server(status: 503, message: "upstream down").localizedDescription)
        )
    }

    /// 首屏失败不得被当成"没有会话"。
    func testFirstPageFailureIsNotAnEmptyDirectory() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        let directory = makeDirectory(clock: clock, fetch: fetch)

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }
        fetch.resumeNext(with: .failure(HarnessTransportError.rejected(status: 403, message: "not authorized")))
        await waitUntil { directory.state.isFailed }

        XCTAssertTrue(directory.sessions.isEmpty)
        XCTAssertTrue(directory.state.isFailed, "失败必须显式可见，不能退化成空列表")
    }

    /// 目录成功时把页交给调用方落地；失败时**不**投递空页。
    func testDeliverIsCalledOnlyWithSuccessfulPages() async throws {
        let clock = FakeHarnessDirectoryClock()
        let fetch = GatedDirectoryFetch()
        var delivered: [SessionsPage] = []
        let directory = HarnessSessionDirectory(
            clock: clock,
            fetch: { try await fetch.fetch($0) },
            deliver: { _, page in delivered.append(page) }
        )

        directory.activate(query: makeQuery(scope: .global))
        await waitUntil { fetch.callCount == 1 }
        fetch.resumeNext(with: .success(page(["s-1"])))
        await waitUntil { directory.state == .loaded }
        XCTAssertEqual(delivered.count, 1)

        directory.refresh(manual: true)
        await waitUntil { fetch.callCount == 2 }
        fetch.resumeNext(with: .failure(HarnessTransportError.timedOut))
        await waitUntil { directory.state.isFailed }

        XCTAssertEqual(delivered.count, 1, "失败不得投递一页空结果")
    }

    // MARK: - 支撑

    private func makeDirectory(
        clock: FakeHarnessDirectoryClock,
        fetch: GatedDirectoryFetch
    ) -> HarnessSessionDirectory {
        HarnessSessionDirectory(
            clock: clock,
            fetch: { try await fetch.fetch($0) },
            deliver: { _, _ in }
        )
    }

    private func makeQuery(scope: HarnessSessionDirectoryQuery.Scope) -> HarnessSessionDirectoryQuery {
        HarnessSessionDirectoryQuery(
            hostScope: HostScope(profileID: "profile-fixture", installationID: "install-fixture", generation: 1),
            runtimeProvider: "deepseek",
            scope: scope
        )
    }

    private func page(_ ids: [String]) -> SessionsPage {
        SessionsPage(sessions: ids.map { id in
            AgentSession(
                id: id,
                projectID: "",
                project: "",
                dir: "/h05/workspace",
                title: id,
                status: "history",
                source: "deepseek",
                runtimeProvider: "deepseek",
                resumeID: nil,
                createdAt: nil,
                updatedAt: nil
            )
        })
    }

    /// 让已就绪的任务推进若干轮。测试里的等待都有明确上界，不做无界轮询。
    private func drain(_ iterations: Int = 50) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        iterations: Int = 200
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("等待条件超时")
    }
}

// MARK: - 替身

/// 可推进的假时钟：让"5 秒一次""后台停表"这类策略可被确定性验证。
@MainActor
final class FakeHarnessDirectoryClock: HarnessDirectoryClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Entry {
        let deadline: Date
        let body: @MainActor () -> Void
        let token: Token
        init(deadline: Date, body: @escaping @MainActor () -> Void, token: Token) {
            self.deadline = deadline
            self.body = body
            self.token = token
        }
    }

    final class Token: HarnessDirectoryClockToken {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    private var entries: [Entry] = []

    func schedule(
        after delay: TimeInterval,
        _ body: @escaping @MainActor () -> Void
    ) -> HarnessDirectoryClockToken {
        let token = Token()
        entries.append(Entry(deadline: now.addingTimeInterval(delay), body: body, token: token))
        return token
    }

    /// 推进时钟并按截止时间顺序触发到期回调（回调内新排的定时器同样参与本轮）。
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        var fired = 0
        while fired < 100 {
            guard let index = entries
                .enumerated()
                .filter({ !$0.element.token.cancelled && $0.element.deadline <= now })
                .min(by: { $0.element.deadline < $1.element.deadline })?
                .offset else {
                return
            }
            let entry = entries.remove(at: index)
            fired += 1
            entry.body()
        }
    }
}

/// 可控挂起的目录取数替身：让"晚到结果"这类时序断言可以精确构造。
@MainActor
final class GatedDirectoryFetch {
    private(set) var callCount = 0
    private(set) var queries: [HarnessSessionDirectoryQuery] = []
    private var continuations: [CheckedContinuation<SessionsPage, Error>] = []

    func fetch(_ query: HarnessSessionDirectoryQuery) async throws -> SessionsPage {
        callCount += 1
        queries.append(query)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext(with result: Result<SessionsPage, Error>) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(with: result)
    }
}

/// 记录请求的 RPC 替身：所有"请求形状对不对"的断言都靠它。
final class RecordingHarnessRPCTransport: HarnessRPCTransport {
    private(set) var requests: [HarnessRPCRequest] = []
    var result: Result<HarnessJSONValue, Error> = .success(.object([:]))

    func call(_ request: HarnessRPCRequest) async throws -> HarnessJSONValue {
        requests.append(request)
        return try result.get()
    }
}

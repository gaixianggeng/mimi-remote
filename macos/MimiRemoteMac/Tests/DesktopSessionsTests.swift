import XCTest
@testable import MimiRemoteMac

final class DesktopSessionParserTests: XCTestCase {
    func testTitleUsesNameThenFirstPreviewLineThenPlaceholder() {
        XCTAssertEqual(DesktopSessionParser.title(from: ["name": "  修复登录  ", "preview": "别的"]), "修复登录")
        XCTAssertEqual(DesktopSessionParser.title(from: ["name": "", "preview": "第一行\n第二行"]), "第一行")
        XCTAssertEqual(DesktopSessionParser.title(from: ["name": NSNull(), "preview": "  "]), DesktopSessionParser.untitled)
    }

    func testSubagentsAreNotListedButForksAre() {
        let base: [String: Any] = ["id": "t1", "cwd": "/repo"]
        XCTAssertNotNil(DesktopSessionParser.session(from: base, runtime: .codex))
        XCTAssertNotNil(DesktopSessionParser.session(from: base.merging(["forkedFromId": "t0"]) { $1 }, runtime: .codex))
        XCTAssertNotNil(DesktopSessionParser.session(from: base.merging(["parentThreadId": NSNull()]) { $1 }, runtime: .codex))
        XCTAssertNil(DesktopSessionParser.session(from: base.merging(["parentThreadId": "t0"]) { $1 }, runtime: .codex))
        XCTAssertNil(DesktopSessionParser.session(from: base.merging(["threadSource": "subAgent"]) { $1 }, runtime: .codex))
        XCTAssertNil(DesktopSessionParser.session(
            from: base.merging(["source": ["subAgent": ["thread_spawn": [String: Any]()]]]) { $1 }, runtime: .codex
        ))
        XCTAssertNil(DesktopSessionParser.session(from: ["cwd": "/repo"], runtime: .codex), "没有 id 的条目无法交接")
    }

    func testProjectNamePrefersGatewayAnnotation() throws {
        let annotated = try XCTUnwrap(DesktopSessionParser.session(from: [
            "id": "t1", "cwd": "/Users/me/code/repo/sub",
            "mimiRemote": ["discovery": "global", "projectName": "repo"],
        ], runtime: .claude))
        XCTAssertEqual(annotated.projectName, "repo")
        let plain = try XCTUnwrap(DesktopSessionParser.session(from: ["id": "t2", "cwd": "/Users/me/code/other"], runtime: .claude))
        XCTAssertEqual(plain.projectName, "other")
    }

    func testTimestampsAcceptSecondsAndMilliseconds() {
        let seconds = DesktopSessionParser.date(from: NSNumber(value: 1_794_314_866))
        let millis = DesktopSessionParser.date(from: NSNumber(value: 1_794_314_866_000))
        XCTAssertEqual(seconds, millis)
        XCTAssertNil(DesktopSessionParser.date(from: NSNull()))
        XCTAssertNil(DesktopSessionParser.date(from: NSNumber(value: 0)))
    }

    func testActivityFollowsStatusAndFlags() {
        XCTAssertEqual(DesktopSessionParser.activity(from: ["type": "notLoaded"]), .idle)
        XCTAssertEqual(DesktopSessionParser.activity(from: "idle"), .idle)
        XCTAssertEqual(DesktopSessionParser.activity(from: ["type": "active", "activeFlags": []]), .running)
        XCTAssertEqual(DesktopSessionParser.activity(from: ["type": "active", "activeFlags": ["waitingOnApproval"]]), .waitingForApproval)
        XCTAssertEqual(DesktopSessionParser.activity(from: ["type": "active", "activeFlags": ["waitingOnUserInput"]]), .waitingForInput)
        XCTAssertEqual(DesktopSessionParser.activity(from: ["type": "systemError"]), .failed)
        XCTAssertEqual(DesktopSessionParser.activity(from: nil), .idle)
    }

    func testHolderUsesTheSameSignalsAsThePhone() {
        XCTAssertEqual(DesktopSessionParser.holder(from: ["writerHeldElsewhere": true], runtime: .codex), .otherCodexProcess)
        XCTAssertNil(DesktopSessionParser.holder(from: ["writerHeldElsewhere": false], runtime: .codex))
        XCTAssertNil(DesktopSessionParser.holder(from: [:], runtime: .claude))
        XCTAssertEqual(DesktopSessionParser.holder(from: ["claudeOwner": ["entrypoint": "claude-desktop"]], runtime: .claude), .claudeDesktop)
        XCTAssertEqual(DesktopSessionParser.holder(from: ["claudeOwner": ["entrypoint": "cli"]], runtime: .claude), .claudeTerminal)
        XCTAssertEqual(DesktopSessionParser.holder(from: ["claudeOwner": ["entrypoint": "sdk-ts"]], runtime: .claude), .otherClaudeProcess)
    }

    func testPageKeepsCursorAndDropsEmptyCursor() {
        let page = DesktopSessionParser.page(from: [
            "data": [["id": "a", "cwd": "/x"], ["id": "b", "cwd": "/x", "parentThreadId": "a"]],
            "nextCursor": "mimi_next",
        ], runtime: .codex)
        XCTAssertEqual(page.sessions.map(\.threadID), ["a"])
        XCTAssertEqual(page.nextCursor, "mimi_next")
        XCTAssertNil(DesktopSessionParser.page(from: ["data": [], "nextCursor": ""], runtime: .codex).nextCursor)
    }

    func testSessionIDsAreUniqueAcrossRuntimes() {
        let codex = DesktopSessionParser.session(from: ["id": "same"], runtime: .codex)
        let claude = DesktopSessionParser.session(from: ["id": "same"], runtime: .claude)
        XCTAssertNotEqual(codex?.id, claude?.id)
    }

    func testSearchMatchesTitleOrProject() throws {
        let session = try XCTUnwrap(DesktopSessionParser.session(
            from: ["id": "t", "name": "Fix Login", "mimiRemote": ["projectName": "website"]], runtime: .codex
        ))
        XCTAssertTrue(session.matches("login"))
        XCTAssertTrue(session.matches("WEB"))
        XCTAssertTrue(session.matches("  "))
        XCTAssertFalse(session.matches("deploy"))
    }
}

final class DesktopSessionGroupingTests: XCTestCase {
    func testGroupsByDayAndSortsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_794_400_000) // 上海时间晚上 8 点多
        func session(_ id: String, hoursAgo: Double?) -> DesktopSession {
            DesktopSession(
                threadID: id, runtime: .codex, title: id, projectName: "p", cwd: "/p",
                updatedAt: hoursAgo.map { now.addingTimeInterval(-$0 * 3_600) },
                activity: .idle, holder: nil
            )
        }
        let sections = DesktopSessionGrouping.sections([
            session("older", hoursAgo: 24 * 30),
            session("today-early", hoursAgo: 2),
            session("today-late", hoursAgo: 0.1),
            session("yesterday", hoursAgo: 30),
            session("week", hoursAgo: 24 * 4),
            session("unknown", hoursAgo: nil),
        ], now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["今天", "昨天", "最近 7 天", "更早"])
        XCTAssertEqual(sections[0].sessions.map(\.threadID), ["today-late", "today-early"])
        XCTAssertEqual(sections[3].sessions.map(\.threadID), ["older", "unknown"])
    }

    func testBadgesAndTimeText() {
        let now = Date(timeIntervalSince1970: 1_794_400_000)
        let session = DesktopSession(
            threadID: "t", runtime: .claude, title: "t", projectName: "p", cwd: "",
            updatedAt: now, activity: .running, holder: .claudeDesktop
        )
        XCTAssertEqual(SessionRowBadge.badges(for: session).map(\.title), ["运行中", "Claude 桌面版已打开"])
        XCTAssertEqual(SessionRowBadge.timeText(for: nil, now: now), "")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = SessionRowBadge.timeText(for: now.addingTimeInterval(-600), now: now, calendar: calendar)
        let yesterday = SessionRowBadge.timeText(for: now.addingTimeInterval(-30 * 3_600), now: now, calendar: calendar)
        XCTAssertFalse(today.isEmpty)
        // 昨天的行显示具体时间，不再写「1 天前」。
        XCTAssertTrue(yesterday.contains(":"), yesterday)
        XCTAssertNotEqual(today, yesterday)
    }
}

final class LocalGatewayClientTests: XCTestCase {
    func testPortComesFromEndpointAndDefaultsTo8787() {
        XCTAssertEqual(LocalGatewayClient.port(fromEndpoint: "http://100.64.0.1:9000"), 9000)
        XCTAssertEqual(LocalGatewayClient.port(fromEndpoint: "http://mimi.local"), 8787)
        XCTAssertNil(LocalGatewayClient.port(fromEndpoint: ""))
    }

    func testThreadListParamsMatchPhoneGlobalDiscovery() {
        let first = LocalGatewayClient.threadListParams(cursor: nil)
        XCTAssertNil(first["cwd"], "不带 cwd 才走网关的受控全局发现")
        XCTAssertNil(first["cursor"])
        XCTAssertEqual(first["sourceKinds"] as? [String], ["cli", "vscode", "appServer", "subAgent"])
        XCTAssertEqual(first["archived"] as? Bool, false)
        XCTAssertEqual(LocalGatewayClient.threadListParams(cursor: "mimi_x")["cursor"] as? String, "mimi_x")
    }

    func testGatewayErrorMessageDropsMachineCode() {
        XCTAssertEqual(LocalJSONRPCChannel.message(from: ["message": "CLAUDE_DISABLED: Claude Code runtime 未启用"]), "Claude Code runtime 未启用")
        XCTAssertEqual(LocalJSONRPCChannel.message(from: ["message": "thread/list.cursor 已失效"]), "thread/list.cursor 已失效")
        XCTAssertEqual(LocalJSONRPCChannel.message(from: [:]), "服务返回了错误。")
    }
}

@MainActor
final class SessionsStoreTests: XCTestCase {
    private struct FakeSource: DesktopSessionSource {
        var results: [SessionRuntime: Result<DesktopSessionListing, LocalGatewayError>]
        var openResult: Result<ClaudeDesktopOpenResult, LocalGatewayError> = .success(ClaudeDesktopOpenResult(alreadyInDesktop: false))
        var opened: OpenLog? = nil

        func listSessions(runtime: SessionRuntime, port: Int, pageBudget: Int) async throws -> DesktopSessionListing {
            try results[runtime, default: .failure(.invalidResponse)].get()
        }

        func openInClaudeDesktop(threadID: String, cwd: String, port: Int) async throws -> ClaudeDesktopOpenResult {
            opened?.append("\(threadID)@\(cwd):\(port)")
            return try openResult.get()
        }
    }

    final class OpenLog: @unchecked Sendable {
        private(set) var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }

    private func listing(_ runtime: SessionRuntime, ids: [String], hasMore: Bool = false) -> DesktopSessionListing {
        DesktopSessionListing(sessions: ids.map {
            DesktopSession(threadID: $0, runtime: runtime, title: $0, projectName: "p", cwd: "/p",
                           updatedAt: Date(), activity: .idle, holder: nil)
        }, hasMore: hasMore)
    }

    func testMergesRuntimesAndFilters() async {
        let store = SessionsStore(source: FakeSource(results: [
            .codex: .success(listing(.codex, ids: ["c1"], hasMore: true)),
            .claude: .success(listing(.claude, ids: ["k1", "k2"])),
        ]))
        await store.reload(endpoint: "http://127.0.0.1:8787", runtimes: [.codex, .claude])
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertTrue(store.hasMore)
        store.filter = .claude
        XCTAssertEqual(store.visibleSections.flatMap(\.sessions).map(\.threadID).sorted(), ["k1", "k2"])
        store.query = "k2"
        XCTAssertEqual(store.visibleSections.flatMap(\.sessions).map(\.threadID), ["k2"])
        store.query = "nothing"
        XCTAssertTrue(store.isEmptyAfterFiltering)
        XCTAssertTrue(store.hasMore, "筛选后为空时仍要能继续读取更早的会话")
    }

    func testEmptyFirstPagesStillOfferMore() async {
        let store = SessionsStore(source: FakeSource(results: [
            .codex: .success(listing(.codex, ids: [], hasMore: true)),
        ]))
        await store.reload(endpoint: "http://127.0.0.1:8787", runtimes: [.codex])
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.hasMore)
    }

    func testOneRuntimeFailingKeepsTheOtherWithNotice() async {
        let store = SessionsStore(source: FakeSource(results: [
            .codex: .success(listing(.codex, ids: ["c1"])),
            .claude: .failure(.runtimeUnavailable("Claude Code runtime 未启用")),
        ]))
        await store.reload(endpoint: "http://127.0.0.1:8787", runtimes: [.codex, .claude])
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.sessions.map(\.threadID), ["c1"])
        XCTAssertEqual(store.notices, ["暂时读不到 Claude 会话：Claude Code runtime 未启用"])
    }

    func testAllRuntimesFailingShowsError() async {
        let store = SessionsStore(source: FakeSource(results: [
            .codex: .failure(.connectionFailed("连不上本机的 Mimi 服务。")),
        ]))
        await store.reload(endpoint: "http://127.0.0.1:8787", runtimes: [.codex])
        XCTAssertEqual(store.phase, .failed("连不上本机的 Mimi 服务。"))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testOpenInClaudeDesktopCallsSourceThenRefreshes() async {
        let log = OpenLog()
        let claude = DesktopSession(threadID: "k1", runtime: .claude, title: "k1", projectName: "p", cwd: "/repo",
                                    updatedAt: Date(), activity: .idle, holder: nil)
        let store = SessionsStore(source: FakeSource(results: [
            .claude: .success(DesktopSessionListing(sessions: [claude], hasMore: false)),
        ], opened: log), refreshDelay: .zero)
        await store.openInClaudeDesktop(claude, endpoint: "http://127.0.0.1:9000", runtimes: [.claude])
        XCTAssertEqual(log.entries, ["k1@/repo:9000"])
        XCTAssertNil(store.actionError)
        XCTAssertNil(store.workingSessionID)
        XCTAssertEqual(store.phase, .loaded, "打开后刷新列表以更新占用状态")
    }

    func testOpenInClaudeDesktopFailureIsShown() async {
        let claude = DesktopSession(threadID: "k1", runtime: .claude, title: "k1", projectName: "p", cwd: "/repo",
                                    updatedAt: nil, activity: .idle, holder: nil)
        let store = SessionsStore(source: FakeSource(results: [:], openResult: .failure(
            .requestRejected(code: -32602, reason: "not_installed", message: "Claude Desktop is not installed")
        )), refreshDelay: .zero)
        await store.openInClaudeDesktop(claude, endpoint: "http://127.0.0.1:8787", runtimes: [.claude])
        XCTAssertEqual(store.actionError, "这台电脑上没有安装 Claude 桌面版。")
        XCTAssertNil(store.workingSessionID)
    }

    func testOpenInCodexDesktopOpensOrShowsError() async {
        let store = SessionsStore(source: FakeSource(results: [:]), refreshDelay: .zero)
        let codex = DesktopSession(threadID: "c1", runtime: .codex, title: "c1", projectName: "p", cwd: "/repo",
                                   updatedAt: nil, activity: .running, holder: .otherCodexProcess)
        var opened: [String] = []
        await store.openInCodexDesktop(codex) { opened.append($0) }
        XCTAssertEqual(opened, ["c1"], "不看占用状态，直接打开")
        XCTAssertNil(store.actionError)
        await store.openInCodexDesktop(codex) { _ in throw AgentClientError.commandFailed("没有找到 Codex 桌面版。") }
        XCTAssertEqual(store.actionError, "没有找到 Codex 桌面版。")
        XCTAssertNil(store.workingSessionID)
    }

    func testContinueInTerminalLaunchesGeneratedCommandOrExplains() async {
        let store = SessionsStore(source: FakeSource(results: [:]), refreshDelay: .zero)
        let codex = DesktopSession(threadID: "c1", runtime: .codex, title: "c1", projectName: "p", cwd: "/repo",
                                   updatedAt: nil, activity: .running, holder: nil)
        var launched: [TerminalHandoffCommand] = []
        await store.continueInTerminal(codex, command: { runtime, id, cwd in
            TerminalHandoffCommand(cwd: cwd, argv: ["codex", "resume", id, runtime.rawValue])
        }, launch: { launched.append($0) })
        XCTAssertEqual(launched, [TerminalHandoffCommand(cwd: "/repo", argv: ["codex", "resume", "c1", "codex"])])

        let busyClaude = DesktopSession(threadID: "k1", runtime: .claude, title: "k1", projectName: "p", cwd: "/repo",
                                        updatedAt: nil, activity: .running, holder: nil)
        await store.continueInTerminal(busyClaude, command: { _, _, _ in
            XCTFail("不该生成命令")
            return TerminalHandoffCommand(cwd: "", argv: [])
        }, launch: { _ in })
        XCTAssertEqual(store.actionError, "这一轮结束后才能在终端继续。")
    }

    func testMissingServiceOrRuntimesExplainsWhy() async {
        let store = SessionsStore(source: FakeSource(results: [:]))
        await store.reload(endpoint: nil, runtimes: [.codex])
        guard case .failed(let noService) = store.phase else { return XCTFail("服务没运行应提示") }
        XCTAssertTrue(noService.contains("服务没有运行"))
        await store.reload(endpoint: "http://127.0.0.1:8787", runtimes: [])
        guard case .failed(let noRuntime) = store.phase else { return XCTFail("助手全关应提示") }
        XCTAssertTrue(noRuntime.contains("都已关闭"))
    }
}

final class DesktopSessionActionsTests: XCTestCase {
    private func session(
        _ runtime: SessionRuntime,
        activity: DesktopSession.Activity = .idle,
        holder: DesktopSession.Holder? = nil,
        cwd: String = "/repo"
    ) -> DesktopSession {
        DesktopSession(threadID: "t", runtime: runtime, title: "t", projectName: "p", cwd: cwd,
                       updatedAt: nil, activity: activity, holder: holder)
    }

    func testClaudeDesktopAppIsRecognisedByPrefix() {
        XCTAssertEqual(DesktopSessionParser.holder(from: ["claudeOwner": ["entrypoint": "claude-desktop-3p"]], runtime: .claude), .claudeDesktop)
    }

    func testPrimaryActionOnlyForClaudeAndRespectsTurnsAndHolders() {
        XCTAssertNil(DesktopSessionActions.primary(for: session(.codex)), "Codex 桌面版交接在下一步")
        XCTAssertEqual(DesktopSessionActions.primary(for: session(.claude)), .openInClaudeDesktop)
        XCTAssertEqual(DesktopSessionActions.primary(for: session(.claude, activity: .failed)), .openInClaudeDesktop)
        XCTAssertEqual(DesktopSessionActions.primary(for: session(.claude, activity: .running)), .waitForTurn)
        XCTAssertEqual(DesktopSessionActions.primary(for: session(.claude, activity: .waitingForApproval)), .waitForTurn)
        XCTAssertEqual(DesktopSessionActions.primary(for: session(.claude, holder: .claudeDesktop)), .bringClaudeDesktopForward)
        XCTAssertNil(DesktopSessionActions.primary(for: session(.claude, holder: .claudeTerminal)))
        XCTAssertNil(DesktopSessionActions.primary(for: session(.claude, holder: .otherClaudeProcess)))
    }

    func testTerminalRules() {
        XCTAssertNil(DesktopSessionActions.terminalUnavailableReason(for: session(.codex)))
        XCTAssertNil(DesktopSessionActions.terminalUnavailableReason(for: session(.codex, activity: .running)), "Codex 终端与 Mimi 可同时使用")
        XCTAssertNotNil(DesktopSessionActions.terminalUnavailableReason(for: session(.codex, holder: .otherCodexProcess)))
        XCTAssertNil(DesktopSessionActions.terminalUnavailableReason(for: session(.claude)))
        XCTAssertNotNil(DesktopSessionActions.terminalUnavailableReason(for: session(.claude, activity: .running)))
        XCTAssertNotNil(DesktopSessionActions.terminalUnavailableReason(for: session(.claude, holder: .claudeDesktop)))
        XCTAssertNotNil(DesktopSessionActions.terminalUnavailableReason(for: session(.claude, holder: .claudeTerminal)))
        XCTAssertNotNil(DesktopSessionActions.terminalUnavailableReason(for: session(.codex, cwd: "")))
    }

    func testTerminalScriptQuotesEveryArgument() {
        let script = TerminalLauncher.script(for: TerminalHandoffCommand(
            cwd: "/Users/me/it's here",
            argv: ["/opt/codex", "resume", "abc-123", "--remote", "unix:///Users/me/.codex/s.sock"]
        ))
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh -l\n"))
        XCTAssertTrue(script.contains(#"cd -- '/Users/me/it'\''s here' || exit 1"#))
        XCTAssertTrue(script.contains(#"exec '/opt/codex' 'resume' 'abc-123' '--remote' 'unix:///Users/me/.codex/s.sock'"#))
        XCTAssertTrue(script.contains(#"rm -f -- "$0""#), "脚本只用一次")
        XCTAssertEqual(TerminalLauncher.shellQuoted("$(id)"), "'$(id)'")
    }

    func testHandoffArgumentsAndFriendlyErrors() {
        XCTAssertEqual(
            AgentCommandClient.handoffCommandArguments(runtime: .claude, threadID: "abc", cwd: "/repo"),
            ["handoff-command", "--runtime", "claude", "--thread", "abc", "--cwd", "/repo"]
        )
        XCTAssertEqual(
            LocalGatewayError.requestRejected(code: -32602, reason: "turn_active", message: "x").errorDescription,
            "这一轮还在运行，结束后再打开。"
        )
        XCTAssertTrue(LocalGatewayError.requestRejected(code: -32080, reason: nil, message: "app-server method 不允许").errorDescription?.contains("重新启动") == true)
        XCTAssertEqual(LocalGatewayError.requestRejected(code: 1, reason: "other", message: "原文").errorDescription, "原文")
    }
}

final class SessionRuntimeSelectionTests: XCTestCase {
    func testMissingModuleStatusReadsBothRuntimes() throws {
        XCTAssertEqual(SessionRuntime.enabled(in: nil), [.codex, .claude])
        let onlyCodex = try JSONDecoder().decode(AgentModuleStatus.self, from: Data(#"""
        {"codex_enabled":true,"claude_enabled":false,"tailscale_enabled":false,"lan_enabled":true,"tailscale_available":false,"lan_available":true}
        """#.utf8))
        XCTAssertEqual(SessionRuntime.enabled(in: onlyCodex), [.codex])
    }
}

@MainActor
final class SessionsStoreOutcomeTests: XCTestCase {
    private struct SlowClaudeSource: DesktopSessionSource {
        func listSessions(runtime: SessionRuntime, port: Int, pageBudget: Int) async throws -> DesktopSessionListing {
            // 后到的一路也必须进入结果（#991：Release 构建里 Claude 后返回时被丢掉）。
            if runtime == .claude { try await Task.sleep(for: .milliseconds(80)) }
            return DesktopSessionListing(sessions: [DesktopSession(
                threadID: runtime.rawValue, runtime: runtime, title: runtime.rawValue, projectName: "p", cwd: "/p",
                updatedAt: Date(), activity: .idle, holder: nil
            )], hasMore: false)
        }

        func openInClaudeDesktop(threadID: String, cwd: String, port: Int) async throws -> ClaudeDesktopOpenResult {
            ClaudeDesktopOpenResult(alreadyInDesktop: false)
        }
    }

    func testLaterRuntimeIsNotDropped() async {
        let store = SessionsStore(source: SlowClaudeSource())
        for _ in 0..<5 {
            await store.reload(endpoint: "http://127.0.0.1:8787", runtimes: [.codex, .claude])
            XCTAssertEqual(Set(store.sessions.map(\.runtime)), [.codex, .claude])
            XCTAssertTrue(store.notices.isEmpty)
        }
    }
}

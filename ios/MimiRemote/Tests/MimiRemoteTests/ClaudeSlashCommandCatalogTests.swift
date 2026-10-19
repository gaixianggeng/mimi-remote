import XCTest
@testable import MimiRemote

/// Claude 会话 `/` 菜单的命令目录：解析、请求、按键缓存与菜单筛选（#765）。
@MainActor
final class ClaudeSlashCommandCatalogTests: XCTestCase {
    func testParseKeepsTypeableCommandsOnce() {
        let result: CodexAppServerJSONValue = .object(["data": .array([
            .object([
                "name": .string("compact"),
                "description": .string("Free up context"),
                "argumentHint": .string("<instructions>"),
                "aliases": .array([])
            ]),
            .object([
                "name": .string("usage"),
                "description": .string("Show usage"),
                "argumentHint": .string(" "),
                "aliases": .array([.string("cost")])
            ]),
            .object([
                "name": .string("mimi:proj-skill"),
                "description": .string("project skill"),
                "aliases": .array([.string("proj-skill")])
            ]),
            .object(["name": .string("claude.ai Notion:page (MCP)"), "description": .string("spaces")]),
            .object(["name": .string("a/b")]),
            .object(["name": .string("compact"), "description": .string("duplicate")]),
            .object(["description": .string("no name")])
        ])])
        XCTAssertEqual(ClaudeSlashCommand.parseListResult(result), [
            ClaudeSlashCommand(name: "compact", description: "Free up context", argumentHint: "<instructions>", aliases: []),
            ClaudeSlashCommand(name: "usage", description: "Show usage", argumentHint: nil, aliases: ["cost"]),
            ClaudeSlashCommand(name: "mimi:proj-skill", description: "project skill", argumentHint: nil, aliases: ["proj-skill"])
        ])
        XCTAssertEqual(ClaudeSlashCommand.parseListResult(nil), [])
    }

    func testRequestCarriesCWDSandboxTypeAndReload() throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [AgentProject(id: "repo", name: "repo", path: "/repo")])
        let spec = try builder.slashCommandList(cwd: "/repo", sandboxMode: .dangerFullAccess, forceReload: true)
        XCTAssertEqual(spec.method, "slashCommand/list")
        let params = try XCTUnwrap(spec.params?.objectValue)
        XCTAssertEqual(params["cwd"]?.stringValue, "/repo")
        XCTAssertEqual(params["sandboxPolicy"]?.objectValue?["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(params["forceReload"]?.boolValue, true)
        XCTAssertThrowsError(try builder.slashCommandList(cwd: "/elsewhere", sandboxMode: .workspaceWrite))
    }

    func testCatalogKeyIsOnlyForClaudeAndSeparatesFullAccess() {
        let store = makeStore(client: SlashCommandStubClient())
        XCTAssertNil(store.claudeSlashCommandCatalogKey(cwd: "/repo", runtimeProvider: "codex", sandboxMode: .workspaceWrite))
        XCTAssertNil(store.claudeSlashCommandCatalogKey(cwd: "  ", runtimeProvider: "claude", sandboxMode: .workspaceWrite))
        let restricted = store.claudeSlashCommandCatalogKey(cwd: "/repo", runtimeProvider: "claude", sandboxMode: .workspaceWrite)
        XCTAssertNotNil(restricted)
        XCTAssertEqual(
            restricted,
            store.claudeSlashCommandCatalogKey(cwd: "/repo", runtimeProvider: "claude", sandboxMode: .readOnly),
            "受限档位都不加载本机设置，目录相同"
        )
        XCTAssertNotEqual(
            restricted,
            store.claudeSlashCommandCatalogKey(cwd: "/repo", runtimeProvider: "claude", sandboxMode: .dangerFullAccess)
        )
    }

    func testRefreshCachesPerKeyAndDoesNotLeakAcrossWorkspaces() async throws {
        let client = SlashCommandStubClient()
        client.results = ["/repo": .success([command("compact")]), "/other": .success([command("usage")])]
        let store = makeStore(client: client)
        let repo = try key(store, cwd: "/repo")
        let other = try key(store, cwd: "/other")

        await store.refreshClaudeSlashCommands(for: repo)
        await store.refreshClaudeSlashCommands(for: repo)
        XCTAssertEqual(client.requests, [.init(cwd: "/repo", sandboxMode: .workspaceWrite, forceReload: false)], "有效期内不重复请求")
        XCTAssertEqual(store.claudeSlashCommands(for: repo).map(\.name), ["compact"])
        XCTAssertEqual(store.claudeSlashCommands(for: other), [], "别的工作区不借用这份目录")

        await store.refreshClaudeSlashCommands(for: other)
        XCTAssertEqual(store.claudeSlashCommands(for: other).map(\.name), ["usage"])
        XCTAssertEqual(store.claudeSlashCommands(for: repo).map(\.name), ["compact"])

        let full = try key(store, cwd: "/repo", sandboxMode: .dangerFullAccess)
        await store.refreshClaudeSlashCommands(for: full, forceReload: true)
        XCTAssertEqual(client.requests.last, .init(cwd: "/repo", sandboxMode: .dangerFullAccess, forceReload: true))
    }

    func testFailureKeepsPreviousCommandsAndUnsupportedHostIsCachedEmpty() async throws {
        let client = SlashCommandStubClient()
        client.results = ["/repo": .success([command("compact")])]
        let store = makeStore(client: client)
        let repo = try key(store, cwd: "/repo")
        await store.refreshClaudeSlashCommands(for: repo)

        client.results["/repo"] = .failure(MockError.unimplemented)
        await store.refreshClaudeSlashCommands(for: repo, forceReload: true)
        XCTAssertEqual(store.claudeSlashCommands(for: repo).map(\.name), ["compact"], "读取失败时保留上次的目录")
        XCTAssertNotNil(store.claudeSlashCommandCatalogs[repo]?.failedAt)
        XCTAssertEqual(store.claudeSlashCommandCatalogs[repo]?.isLoading, false)

        let legacy = try key(store, cwd: "/legacy")
        client.results["/legacy"] = .failure(ClaudeSlashCommandCatalogError.unsupported)
        await store.refreshClaudeSlashCommands(for: legacy)
        await store.refreshClaudeSlashCommands(for: legacy)
        XCTAssertEqual(store.claudeSlashCommands(for: legacy), [])
        XCTAssertEqual(client.requests.filter { $0.cwd == "/legacy" }.count, 1, "旧主机不反复探测")
    }

    func testRuntimeCommandsSkipLocalNamesButKeepPluginSkillsWithCollidingAliases() {
        let commands = ComposerSlashCommand.runtimeCommands(
            [
                ClaudeSlashCommand(name: "plan", description: "", argumentHint: nil, aliases: []),
                ClaudeSlashCommand(name: "mimi:plan", description: "project skill", argumentHint: "<task>", aliases: ["plan"]),
                ClaudeSlashCommand(name: "usage", description: "Show usage", argumentHint: nil, aliases: ["cost"])
            ],
            excludingNames: ["model", "permissions", "plan"]
        )
        XCTAssertEqual(commands.map(\.name), ["mimi:plan", "usage"], "与 App 命令同名的条目不列出")
        XCTAssertEqual(commands.first?.aliases, [], "受限档位的插件技能保留，只去掉撞名的别名")
        XCTAssertEqual(commands.first?.title, "<task>")
        XCTAssertEqual(commands.first?.action, .runtimeCommand("mimi:plan"))
        XCTAssertEqual(commands.last?.aliases, ["cost"])
    }

    func testRuntimeCommandsMatchAliasesAndKeepDistinctIdentities() {
        let local = ComposerSlashCommand(action: .compact, name: "compact", title: "压缩上下文", detail: "", systemImage: "arrow.down")
        let runtimeCompact = ComposerSlashCommand(
            action: .runtimeCommand("compact"), name: "compact", title: "", detail: "", systemImage: "terminal"
        )
        XCTAssertNotEqual(local.id, runtimeCompact.id)

        let usage = ComposerSlashCommand(
            action: .runtimeCommand("usage"), name: "usage", title: "", detail: "Show usage", systemImage: "terminal", aliases: ["cost"]
        )
        let ranked = ComposerAutocompleteRanking.rank([.command(local), .command(usage)], query: "cos")
        XCTAssertEqual(ranked.map(\.id), [ComposerAutocompleteSuggestion.command(usage).id], "别名按命令名同档匹配")
    }

    private func makeStore(client: SlashCommandStubClient) -> SessionStore {
        SessionStore(appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
                     logStore: LogStore(), clientFactory: { client })
    }

    private func key(
        _ store: SessionStore,
        cwd: String,
        sandboxMode: CodexAppServerSandboxMode = .workspaceWrite
    ) throws -> ClaudeSlashCommandCatalogKey {
        try XCTUnwrap(store.claudeSlashCommandCatalogKey(cwd: cwd, runtimeProvider: "claude", sandboxMode: sandboxMode))
    }

    private func command(_ name: String) -> ClaudeSlashCommand {
        ClaudeSlashCommand(name: name, description: "\(name) command", argumentHint: nil, aliases: [])
    }
}

private final class SlashCommandStubClient: SessionStoreAPIClient {
    struct Request: Equatable {
        let cwd: String
        let sandboxMode: CodexAppServerSandboxMode
        let forceReload: Bool
    }

    var results: [String: Result<[ClaudeSlashCommand], Error>] = [:]
    private(set) var requests: [Request] = []

    func claudeSlashCommands(cwd: String, sandboxMode: CodexAppServerSandboxMode, forceReload: Bool) async throws -> [ClaudeSlashCommand] {
        requests.append(Request(cwd: cwd, sandboxMode: sandboxMode, forceReload: forceReload))
        return try (results[cwd] ?? .success([])).get()
    }

    func projects() async throws -> [AgentProject] { [] }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] { [] }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] { [] }
}

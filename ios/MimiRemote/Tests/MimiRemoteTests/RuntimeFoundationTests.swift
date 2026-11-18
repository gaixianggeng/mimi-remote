import XCTest
@testable import MimiRemote

@MainActor
final class RuntimeFoundationTests: XCTestCase {
    func testSessionNotificationRoutePreservesAllKnownRuntimesAndRejectsUnknown() throws {
        for raw in ["codex", "Claude", "AGY", "antigravity", "DEEPSEEK", "claude-code"] {
            let route = SessionNotificationRoute.current(
                profileID: "host-1",
                projectID: "proj-1",
                sessionID: "sess-1",
                runtimeProvider: raw
            )
            let roundTrip = try XCTUnwrap(SessionNotificationRoute(userInfo: route.userInfo))
            XCTAssertEqual(
                roundTrip.runtimeProvider,
                CodexAppServerSessionRuntime.normalizedRuntimeProvider(raw)
            )
        }

        let unknown = SessionNotificationRoute.current(
            profileID: "host-1",
            projectID: "proj-1",
            sessionID: "sess-1",
            runtimeProvider: "unregistered-agent"
        )
        XCTAssertNil(unknown.runtimeProvider)
    }

    func testRuntimeBundleRoutesAdditionalAppServerRuntimesDynamically() throws {
        let codex = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: "codex")
        let claude = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: "claude")
        let agy = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: "agy")
        let bundle = AppServerRuntimeBundle(
            codexRuntime: codex,
            claudeRuntime: claude,
            additionalRuntimes: ["agy": agy]
        )

        XCTAssertTrue(try bundle.runtime(for: "codex") === codex)
        XCTAssertTrue(try bundle.runtime(for: "claude") === claude)
        XCTAssertTrue(try bundle.runtime(for: "agy") === agy)
        XCTAssertThrowsError(try bundle.runtime(for: "deepseek"))
        XCTAssertEqual(
            bundle.secondaryRuntimeEntries.map(\.provider),
            ["claude", "agy", "deepseek"]
        )
    }

    func testSlashCommandCatalogKeySeparatesRuntimeProviders() {
        let scope = HostScope(profileID: "p1", installationID: "i1", generation: 1)
        let claudeKey = ClaudeSlashCommandCatalogKey(
            hostScope: scope,
            runtimeProvider: "claude",
            cwd: "/repo",
            fullAccess: false
        )
        let agyKey = ClaudeSlashCommandCatalogKey(
            hostScope: scope,
            runtimeProvider: "agy",
            cwd: "/repo",
            fullAccess: false
        )
        XCTAssertNotEqual(claudeKey, agyKey)
    }

    func testAntigravityPermissionModesAndModelGridRespectDeclaredCapabilities() {
        let agyModes = RuntimeFeatureSupport.permissionModes(for: "agy")
        XCTAssertEqual(agyModes, [.requestApproval, .acceptEdits, .autoApprove, .readOnly, .fullAccess])
        XCTAssertEqual(
            RuntimeFeatureSupport.permissionModes(for: "claude"),
            [.requestApproval, .readOnly, .autoApprove, .fullAccess]
        )

        var options = CodexAppServerTurnOptions()
        ComposerPermissionMode.acceptEdits.apply(to: &options)
        XCTAssertEqual(options.approvalPolicy, .onRequest)
        XCTAssertEqual(options.approvalsReviewer, "accept_edits")
        XCTAssertEqual(options.sandboxMode, .workspaceWrite)
        XCTAssertEqual(ComposerPermissionMode(options: options), .acceptEdits)

        let models = [
            CodexAppServerModelOption(
                id: "gemini-4-carbon",
                title: "Gemini 4 Carbon",
                runtimeProvider: "agy",
                isDefault: true,
                supportedReasoningEfforts: ["low", "medium", "high"],
                defaultReasoningEffort: "medium"
            ),
            CodexAppServerModelOption(
                id: "gemini-4-hydrogen",
                title: "Gemini 4 Hydrogen",
                runtimeProvider: "agy",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium"
            ),
            CodexAppServerModelOption(
                id: "gemini-pro-orchestrator",
                title: "Orchestrator (Carbon)",
                runtimeProvider: "agy",
                supportedReasoningEfforts: [],
                defaultReasoningEffort: "none"
            ),
        ]
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "agy", options: models)
        XCTAssertEqual(layout.kind, .antigravity)
        XCTAssertEqual(layout.efforts, [.low, .medium, .high, .xhigh])
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: models[0], layout: layout),
            [.low, .medium, .high]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: models[1], layout: layout),
            [.low, .medium, .high, .xhigh]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: models[2], layout: layout),
            []
        )
        XCTAssertTrue(RuntimeFeatureSupport.supportsRuntimeSlashCommandCatalog(for: "agy"))
        XCTAssertTrue(RuntimeFeatureSupport.usesGlobalThreadListSearch(for: "agy"))
    }
}

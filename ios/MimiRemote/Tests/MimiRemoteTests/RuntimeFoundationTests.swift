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
        XCTAssertTrue(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: "codex"))
        XCTAssertTrue(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: nil))
        XCTAssertFalse(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: "claude"))
        XCTAssertFalse(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: "agy"))
        XCTAssertFalse(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: "deepseek"))
    }

    func testAntigravityNeverEmitsPreserveThreadPermissionsFlag() {
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "agy"
        options.preservesThreadPermissionSettings = true

        let sanitized = options.sanitizedForRuntimePolicy()
        XCTAssertFalse(sanitized.preservesThreadPermissionSettings)
        XCTAssertNil(sanitized.turnParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil)
        XCTAssertNil(sanitized.threadParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil)
        // 即便未调用 sanitizedForRuntimePolicy，底层 wire 参数也不得向非 Codex 通道发送 true。
        XCTAssertNil(options.turnParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil)
        XCTAssertNil(options.threadParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil)
    }

    @MainActor
    func testRestoredAntigravityPermissionSelectionDoesNotPreserveThreadSettings() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        let scope = ComposerDraftScopeKey.session("existing-agy-thread")

        let restoredDefault = store.restoredComposerPermissionSelection(
            for: scope,
            runtimeProvider: "agy",
            defaultMode: .fullAccess
        )
        XCTAssertFalse(restoredDefault.preservesThreadSettings)
        XCTAssertEqual(restoredDefault.mode, ComposerPermissionMode.requestApproval)

        // 若旧缓存中残留了 preservesThreadSettings = true，还原时必须归一化回显式模式。
        var staleOptions = CodexAppServerTurnOptions.default
        staleOptions.preservesThreadPermissionSettings = true
        store.saveComposerPermissionSelection(
            ComposerPermissionSelectionSnapshot(options: staleOptions),
            for: scope
        )
        let healed = store.restoredComposerPermissionSelection(
            for: scope,
            runtimeProvider: "agy",
            defaultMode: .fullAccess
        )
        XCTAssertFalse(healed.preservesThreadSettings)
        XCTAssertEqual(healed.mode, ComposerPermissionMode.requestApproval)
    }

    func testB01ApprovalSummaryHidesApproveOnceWhenGatewayOmitsAccept() {
        let alwaysOnly = ApprovalSummary(
            id: "req-always-only",
            title: "Run command",
            body: "pwd",
            kind: "command",
            count: nil,
            availableDecisions: ["acceptAlways", "decline"],
            alwaysAllowLabel: "Remember for every conversation"
        )
        XCTAssertFalse(alwaysOnly.canApproveOnce)
        XCTAssertFalse(alwaysOnly.canAcceptForSession)
        XCTAssertTrue(alwaysOnly.canAcceptAlways)
        XCTAssertEqual(alwaysOnly.alwaysAllowLabel, "Remember for every conversation")

        let onceAndSession = ApprovalSummary(
            id: "req-once-and-session",
            title: "Run command",
            body: "pwd",
            kind: "command",
            count: nil,
            availableDecisions: ["accept", "acceptForSession", "decline"]
        )
        XCTAssertTrue(onceAndSession.canApproveOnce)
        XCTAssertTrue(onceAndSession.canAcceptForSession)
        XCTAssertFalse(onceAndSession.canAcceptAlways)

        let legacyNilDecisions = ApprovalSummary(
            id: "req-legacy",
            title: "Run command",
            body: "pwd",
            kind: "command",
            count: nil,
            availableDecisions: nil
        )
        XCTAssertTrue(legacyNilDecisions.canApproveOnce)
    }

    func testB05CommandAndFileApprovalsExposeAllowForSessionWhenAdvertisedByGateway() async {
        let commandWithSession = ApprovalSummary(
            id: "req-cmd-session",
            title: "Run pwd",
            body: "pwd",
            kind: "command",
            count: nil,
            availableDecisions: ["accept", "acceptForSession", "decline"]
        )
        XCTAssertTrue(commandWithSession.canApproveOnce)
        XCTAssertTrue(commandWithSession.canAcceptForSession)
        XCTAssertFalse(commandWithSession.canAcceptAlways)
        XCTAssertFalse(commandWithSession.canAcceptMCPToolForSession)

        let crossSessionAlways = ApprovalSummary(
            id: "req-cmd-cross-session",
            title: "Run pwd",
            body: "pwd",
            kind: "command",
            count: nil,
            availableDecisions: ["accept", "acceptAlways", "decline"],
            alwaysAllowLabel: "Remember for every conversation"
        )
        XCTAssertTrue(crossSessionAlways.canApproveOnce)
        XCTAssertFalse(crossSessionAlways.canAcceptForSession)
        XCTAssertTrue(crossSessionAlways.canAcceptAlways)

        let fileSessionOnly = ApprovalSummary(
            id: "req-file-session",
            title: "Edit file",
            body: "diff",
            kind: "fileChange",
            count: nil,
            availableDecisions: ["acceptForSession", "decline"]
        )
        XCTAssertFalse(fileSessionOnly.canApproveOnce)
        XCTAssertTrue(fileSessionOnly.canAcceptForSession)
        XCTAssertFalse(fileSessionOnly.canAcceptAlways)

        let commandOnceOnly = ApprovalSummary(
            id: "req-cmd-once",
            title: "Run pwd",
            body: "pwd",
            kind: "command",
            count: nil,
            availableDecisions: ["accept", "decline"]
        )
        XCTAssertTrue(commandOnceOnly.canApproveOnce)
        XCTAssertFalse(commandOnceOnly.canAcceptForSession)
        XCTAssertFalse(commandOnceOnly.canAcceptAlways)

        let mcpWithSession = ApprovalSummary(
            id: "req-mcp-session",
            title: "Call tool",
            body: "args",
            kind: CodexMCPToolApprovalProtocol.kind,
            count: nil,
            availableDecisions: ["accept", "acceptForSession", "decline"]
        )
        XCTAssertFalse(mcpWithSession.canAcceptForSession)
        XCTAssertFalse(mcpWithSession.canAcceptAlways)
        XCTAssertTrue(mcpWithSession.canAcceptMCPToolForSession)

        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: "agy")
        let sessionResp = await runtime.approvalResponse(
            method: "item/commandExecution/requestApproval",
            params: [:],
            decision: "acceptForSession"
        )
        XCTAssertEqual(sessionResp, .object(["decision": .string("acceptForSession")]))
        let alwaysResp = await runtime.approvalResponse(
            method: "item/commandExecution/requestApproval",
            params: [:],
            decision: "acceptAlways"
        )
        XCTAssertEqual(alwaysResp, .object(["decision": .string("acceptAlways")]))
    }

    func testB14OutdatedAntigravityBridgeSurfacesVersionUpgradeDiagnosticInWorkspace() {
        let channel = CodexAppServerChannelMetadata(
            id: "agy",
            runtimeID: "agy",
            title: "Antigravity",
            provider: "agy",
            type: "agy_acp_adapter",
            protocolName: "app_server_jsonrpc_stdio_v1",
            enabled: true,
            gatewayWSURL: "ws://127.0.0.1:8787/api/app-server/ws?runtime=agy",
            gatewayAvailable: false,
            managed: false,
            experimental: true,
            lifecycle: "per_connection",
            bridge: CodexAppServerChannelBridgeMetadata(
                name: "mimi-agy-adapter",
                version: "0.1.0",
                minimumVersion: "0.1.0",
                cliVersion: "1.4.99",
                minimumCLIVersion: "1.5.0",
                path: "/opt/mimi/mimi-agy-adapter",
                status: "agy_unsupported",
                healthy: false,
                lastProbeError: "Antigravity CLI 1.4.99 过旧，Mimi Remote 需要 1.5.0 或更新版本。请升级 agy 后重试。",
                fix: "升级 Antigravity CLI (agy)"
            ),
            methods: nil,
            capabilities: nil
        )

        let diagnostic = RuntimeChannelDiagnostic.from(channel: channel)
        XCTAssertEqual(diagnostic?.provider, "agy")
        XCTAssertEqual(diagnostic?.status, "agy_unsupported")
        XCTAssertEqual(diagnostic?.cliVersion, "1.4.99")
        XCTAssertEqual(diagnostic?.minimumCLIVersion, "1.5.0")
        XCTAssertTrue(diagnostic?.localizedMessage.contains("1.4.99") == true)
        XCTAssertTrue(diagnostic?.localizedMessage.contains("1.5.0") == true)

        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        store.availableRuntimeProviders = []
        if let diagnostic {
            store.runtimeChannelDiagnosticsByProvider["agy"] = diagnostic
        }
        // Even if selectedRuntime fell back to .codex when no runtime is available,
        // the workspace still surfaces the Antigravity upgrade diagnostic.
        let notice = store.workspaceRuntimeNotice(for: .codex)
        XCTAssertEqual(notice, diagnostic)

        let errorPresentation = UserFacingError(CodexAppServerSessionRuntimeError.channelUnavailable(diagnostic!))
        XCTAssertEqual(errorPresentation.category, .described)
        XCTAssertFalse(errorPresentation.suggestsReconnect)
        XCTAssertTrue(errorPresentation.message.contains("1.4.99"))
        XCTAssertTrue(errorPresentation.message.contains("1.5.0"))
    }

    @MainActor
    func testC14C15MissingDirectorySessionIsReadOnlyWithControlNotice() {
        let session = AgentSession(
            id: "sess-missing-dir",
            projectID: "remove-fixture",
            project: "Remove Fixture",
            dir: "/tmp/remove-fixture",
            title: "Removed Workspace Fixture",
            status: "completed",
            source: "agy",
            runtimeProvider: "agy",
            resumeID: nil,
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: true,
            cwdMissing: true
        )
        XCTAssertFalse(session.allowsDirectInput)

        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        store.sessions = [session]
        store.selectedSessionID = session.id
        XCTAssertTrue(store.isProtocolReadOnlySession(session))
        XCTAssertNotNil(store.selectedSessionControlNotice)

        // Path restoration clears cwdMissing and restores direct input on the same store.
        let restored = AgentSession(
            id: session.id,
            projectID: session.projectID,
            project: session.project,
            dir: session.dir,
            title: session.title,
            status: "completed",
            source: "agy",
            runtimeProvider: "agy",
            resumeID: nil,
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: true,
            cwdMissing: false
        )
        store.applyLiveSessionIndexUpdate(restored)
        XCTAssertEqual(store.selectedSession?.cwdMissing, false)
        XCTAssertEqual(store.selectedSession?.allowsDirectInput, true)
        XCTAssertNil(store.selectedSessionControlNotice)
    }
}

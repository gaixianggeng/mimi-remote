import SwiftUI
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
        XCTAssertTrue(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: "agy"))
        XCTAssertFalse(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: "claude"))
        XCTAssertFalse(RuntimeFeatureSupport.supportsPreserveThreadPermissions(for: "deepseek"))
    }

    func testPreserveThreadPermissionsRespectsChannelCapabilityAndProtectsLegacyGateway() {
        var claudeOptions = CodexAppServerTurnOptions.default
        claudeOptions.runtimeProvider = "claude"
        claudeOptions.preservesThreadPermissionSettings = true
        let sanitizedClaude = claudeOptions.sanitizedForRuntimePolicy()
        XCTAssertFalse(sanitizedClaude.preservesThreadPermissionSettings)
        XCTAssertNil(sanitizedClaude.turnParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil)
        XCTAssertNil(claudeOptions.turnParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil)

        var agyOptions = CodexAppServerTurnOptions.default
        agyOptions.runtimeProvider = "agy"
        agyOptions.preservesThreadPermissionSettings = true
        let sanitizedAgy = agyOptions.sanitizedForRuntimePolicy()
        XCTAssertTrue(sanitizedAgy.preservesThreadPermissionSettings)
        XCTAssertEqual(sanitizedAgy.turnParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil, .bool(true))
        XCTAssertNil(sanitizedAgy.turnParams(projectPath: "/tmp/project")["approvalPolicy"] ?? nil)
        XCTAssertNil(sanitizedAgy.turnParams(projectPath: "/tmp/project")["sandboxPolicy"] ?? nil)
        XCTAssertEqual(sanitizedAgy.threadParams(projectPath: "/tmp/project")["mimiPreserveThreadPermissions"] ?? nil, .bool(true))
        XCTAssertNil(sanitizedAgy.threadParams(projectPath: "/tmp/project")["sandbox"] ?? nil)

        let project = AgentProject(id: "proj_perm", name: "Perm", path: "/tmp/perm")
        func agyChannel(preserve: Bool?) -> CodexAppServerChannelMetadata {
            CodexAppServerChannelMetadata(
                id: "agy",
                runtimeID: "agy",
                title: "Antigravity",
                provider: "agy",
                type: "agy_acp_adapter",
                protocolName: "app_server_jsonrpc_stdio_v1",
                gatewayWSURL: "ws://127.0.0.1:8787/api/app-server/ws?runtime=agy",
                gatewayAvailable: true,
                managed: false,
                experimental: true,
                lifecycle: nil,
                bridge: nil,
                methods: ["initialize", "thread/resume", "turn/start"],
                capabilities: preserve.map { ["preserve_thread_permissions": $0] }
            )
        }
        let modernConfig = makeDirectAppServerConfig(project: project, channels: [agyChannel(preserve: true)])
        let legacyConfig = makeDirectAppServerConfig(project: project, channels: [agyChannel(preserve: nil)])
        XCTAssertTrue(CodexAppServerSessionRuntime.supportsPreserveThreadPermissions(runtimeProvider: "codex", in: legacyConfig))
        XCTAssertTrue(CodexAppServerSessionRuntime.supportsPreserveThreadPermissions(runtimeProvider: "agy", in: modernConfig))
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsPreserveThreadPermissions(runtimeProvider: "agy", in: legacyConfig))
        XCTAssertFalse(CodexAppServerSessionRuntime.supportsPreserveThreadPermissions(runtimeProvider: "claude", in: modernConfig))
    }

    @MainActor
    func testRestoredAntigravityPermissionSelectionPreservesThreadSettingsWhenSupported() async {
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            runtimeChannelAvailability: ["codex": true, "agy": true]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        let scope = ComposerDraftScopeKey.session("existing-agy-thread")

        // 新版 agentd/adapter 支持沿用已有 agy 会话权限，默认不降级也不套用 App 全局默认。
        let restoredModern = store.restoredComposerPermissionSelection(
            for: scope,
            runtimeProvider: "agy",
            defaultMode: .fullAccess
        )
        XCTAssertTrue(restoredModern.preservesThreadSettings)

        // 若旧版 agentd 未声明 preserve_thread_permissions，刷新能力后自动回退为显式请求审批，避免 -32080。
        client.runtimePreserveThreadPermissionSupport["agy"] = false
        await store.refreshAppServerModelOptions()
        XCTAssertFalse(store.supportsPreserveThreadPermissions(runtimeProvider: "agy"))

        let restoredLegacy = store.restoredComposerPermissionSelection(
            for: scope,
            runtimeProvider: "agy",
            defaultMode: .fullAccess
        )
        XCTAssertFalse(restoredLegacy.preservesThreadSettings)
        XCTAssertEqual(restoredLegacy.mode, ComposerPermissionMode.requestApproval)

        // 旧缓存中残留 preservesThreadSettings = true 时，连接旧版 agentd 也必须自动归一化。
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
            alwaysAllowLabel: "Remember for every conversation",
            alwaysAllowScopeUncertain: false
        )
        XCTAssertTrue(crossSessionAlways.canApproveOnce)
        XCTAssertFalse(crossSessionAlways.canAcceptForSession)
        XCTAssertTrue(crossSessionAlways.canAcceptAlways)
        XCTAssertNotNil(crossSessionAlways.alwaysAllowScopeNotice)

        let uncertainAlways = ApprovalSummary(
            id: "req-cmd-uncertain-always",
            title: "Run ls",
            body: "ls",
            kind: "command",
            count: nil,
            availableDecisions: ["acceptAlways", "decline"],
            alwaysAllowLabel: "Allow always",
            alwaysAllowScopeUncertain: true
        )
        XCTAssertFalse(uncertainAlways.canApproveOnce)
        XCTAssertFalse(uncertainAlways.canAcceptForSession)
        XCTAssertTrue(uncertainAlways.canAcceptAlways)
        XCTAssertNotNil(uncertainAlways.alwaysAllowScopeNotice)
        XCTAssertNotEqual(uncertainAlways.alwaysAllowScopeNotice, crossSessionAlways.alwaysAllowScopeNotice)

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

    @MainActor
    func testC11Round2OpeningIdleListedSessionRefreshesMacBusyStateAndRecoversWhenIdle() {
        let idleSession = AgentSession(
            id: "sess-c11-mac-busy",
            projectID: "proj-1",
            project: "Demo",
            dir: "/tmp/demo",
            title: "Long Sleep Command",
            status: "completed",
            source: "agy",
            runtimeProvider: "agy",
            resumeID: "sess-c11-mac-busy",
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: true,
            claudeOwner: nil
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        store.sessions = [idleSession]
        store.selectedSessionID = idleSession.id
        XCTAssertTrue(store.canControlSession(store.selectedSession))
        XCTAssertNil(store.selectedOwnershipNotice)

        // Mac CLI becomes busy after the idle global list was already loaded;
        // thread/read refreshes owner/busy state into the store.
        let busySnapshot = AgentSession(
            id: idleSession.id,
            projectID: idleSession.projectID,
            project: idleSession.project,
            dir: idleSession.dir,
            title: idleSession.title,
            status: SessionStatus.running.rawValue,
            source: "agy",
            runtimeProvider: "agy",
            resumeID: idleSession.id,
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: false,
            claudeOwner: ClaudeSessionOwner(
                entrypoint: "desktop",
                kind: "desktop",
                status: "busy",
                pid: nil,
                statusUpdatedAt: Date(),
                waitingKind: nil
            )
        )
        store.applyLiveSessionIndexUpdate(busySnapshot)
        XCTAssertEqual(store.selectedSession?.isRunningOnComputer, true)
        XCTAssertFalse(store.canControlSession(store.selectedSession))
        XCTAssertTrue(store.isProtocolReadOnlySession(store.selectedSession!))
        XCTAssertNotNil(store.selectedOwnershipNotice)
        XCTAssertEqual(store.selectedOwnershipNotice?.owner.status, "busy")

        // Once Mac finishes and returns idle, refreshing restores direct input.
        let recoveredIdle = AgentSession(
            id: idleSession.id,
            projectID: idleSession.projectID,
            project: idleSession.project,
            dir: idleSession.dir,
            title: idleSession.title,
            status: SessionStatus.completed.rawValue,
            source: "agy",
            runtimeProvider: "agy",
            resumeID: idleSession.id,
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: true,
            claudeOwner: nil
        )
        store.applyLiveSessionIndexUpdate(recoveredIdle)
        XCTAssertEqual(store.selectedSession?.isRunningOnComputer, false)
        XCTAssertTrue(store.canControlSession(store.selectedSession))
        XCTAssertFalse(store.isProtocolReadOnlySession(store.selectedSession!))
        XCTAssertNil(store.selectedOwnershipNotice)
    }

    @MainActor
    func testB14Round2StaleHostDiagnosticResponseDoesNotOverwriteSwitchedHealthyHost() async throws {
        let appStore = makeIsolatedAppStore()
        var startedWaiting: CheckedContinuation<Void, Never>?
        var releaseStaleDiagnostics: CheckedContinuation<[String: RuntimeChannelDiagnostic], Never>?

        let staleDiagnostic = RuntimeChannelDiagnostic(
            provider: "agy",
            status: "agy_unsupported",
            cliVersion: "1.4.99",
            minimumCLIVersion: "1.5.0",
            lastProbeError: "Antigravity CLI 1.4.99 is outdated",
            fix: "Upgrade agy"
        )
        let slowOldHostClient = MockSessionStoreClient(
            projects: [],
            sessions: [],
            runtimeChannelAvailability: ["codex": true, "agy": false]
        )
        slowOldHostClient.runtimeChannelDiagnosticsHandler = {
            await withCheckedContinuation { continuation in
                releaseStaleDiagnostics = continuation
                startedWaiting?.resume()
                startedWaiting = nil
            }
        }
        let healthyNewHostClient = MockSessionStoreClient(
            projects: [],
            sessions: [],
            runtimeChannelAvailability: ["codex": true, "agy": true]
        )

        var useHealthyHost = false
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { useHealthyHost ? healthyNewHostClient : slowOldHostClient }
        )

        let enteredDiagnostics = Task {
            await withCheckedContinuation { continuation in
                startedWaiting = continuation
            }
        }
        let oldHostRefresh = Task {
            await store.refreshAppServerModelOptions(force: true)
        }
        await enteredDiagnostics.value

        // Switch to healthy Host B while Host A's slow diagnostics call is still in flight.
        let oldScope = appStore.activeHostScope
        useHealthyHost = true
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.21:8787",
            token: "healthy-host-token",
            profileTarget: .newProfile(id: "host-healthy", displayName: "Healthy Host"),
            installationID: "install-healthy"
        ))
        XCTAssertNotEqual(appStore.activeHostScope, oldScope)
        store.availableRuntimeProviders = ["codex", "agy"]
        store.runtimeChannelDiagnosticsByProvider = [:]

        // Now Host A's stale outdated-agy diagnostic resolves asynchronously.
        releaseStaleDiagnostics?.resume(returning: ["agy": staleDiagnostic])
        await oldHostRefresh.value

        // Host B's healthy runtime state MUST remain untouched!
        XCTAssertTrue(store.availableRuntimeProviders.contains("agy"))
        XCTAssertNil(store.runtimeChannelDiagnosticsByProvider["agy"])
        XCTAssertNil(store.workspaceRuntimeNotice(for: .agy))
    }

    func testC11Round3FirstScreenMetadataRefreshRespectsCapabilityAndDegradesGracefullyOnFailure() async throws {
        let project = AgentProject(id: "proj-c11-cap", name: "C11", path: "/tmp/c11-cap")
        let agyChannelWithoutRead = CodexAppServerChannelMetadata(
            id: "agy",
            runtimeID: "agy",
            title: "Antigravity",
            provider: "agy",
            type: "agy_acp_adapter",
            protocolName: "app_server_jsonrpc_stdio_v1",
            enabled: true,
            gatewayWSURL: "ws://127.0.0.1:8787/api/app-server/ws?runtime=agy",
            gatewayAvailable: true,
            managed: false,
            experimental: true,
            lifecycle: "per_connection",
            bridge: nil,
            methods: ["initialize", "initialized", "thread/turns/list"],
            capabilities: nil
        )
        let agyChannelWithRead = CodexAppServerChannelMetadata(
            id: "agy",
            runtimeID: "agy",
            title: "Antigravity",
            provider: "agy",
            type: "agy_acp_adapter",
            protocolName: "app_server_jsonrpc_stdio_v1",
            enabled: true,
            gatewayWSURL: "ws://127.0.0.1:8787/api/app-server/ws?runtime=agy",
            gatewayAvailable: true,
            managed: false,
            experimental: true,
            lifecycle: "per_connection",
            bridge: nil,
            methods: ["initialize", "initialized", "thread/read", "thread/turns/list"],
            capabilities: nil
        )

        // 1) When channel omits `thread/read` capability, messagesPage MUST skip `thread/read` and call `thread/turns/list` directly.
        let transportNoRead = FakeCodexAppServerTransport()
        let runtimeNoRead = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "agy",
            transportFactory: { transportNoRead },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/turns/list"],
                    channels: [agyChannelWithoutRead]
                )
            }
        )
        let pageNoRead = Task { try await runtimeNoRead.messagesPage(sessionID: "sess-no-read", before: nil, limit: 20) }
        let init1 = try await waitForFakeAppServerRequest(transportNoRead, method: "initialize")
        transportResponse(transportNoRead, id: init1.id, result: #"{"userAgent":"fake-agy","platformFamily":"macos"}"#)
        let turns1 = try await waitForFakeAppServerRequest(transportNoRead, method: "thread/turns/list")
        transportResponse(transportNoRead, id: turns1.id, result: #"{"data":[],"nextCursor":null}"#)
        _ = try await pageNoRead.value
        let sentMethods1 = await transportNoRead.sentMessages().compactMap { (try? decodeAppServerRequest($0))?.method }
        XCTAssertFalse(sentMethods1.contains("thread/read"))
        await runtimeNoRead.shutdownForHostSwitch()

        // 2) When `thread/read` IS supported on cached agy session but fails (-32601 / transient error), degrade gracefully to `thread/turns/list`.
        let transportDegrade = FakeCodexAppServerTransport()
        let runtimeDegrade = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "agy",
            transportFactory: { transportDegrade },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "thread/read", "thread/turns/list"],
                    channels: [agyChannelWithRead]
                )
            }
        )
        let cachedSession = AgentSession(
            id: "sess-degrade",
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: "Cached Agy",
            status: "completed",
            source: "agy",
            runtimeProvider: "agy",
            resumeID: "sess-degrade",
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: true
        )
        await runtimeDegrade.rememberForkedSession(cachedSession)
        let pageDegrade = Task { try await runtimeDegrade.messagesPage(sessionID: "sess-degrade", before: nil, limit: 20) }
        let init2 = try await waitForFakeAppServerRequest(transportDegrade, method: "initialize")
        transportResponse(transportDegrade, id: init2.id, result: #"{"userAgent":"fake-agy","platformFamily":"macos"}"#)
        let read2 = try await waitForFakeAppServerRequest(transportDegrade, method: "thread/read")
        transportErrorResponse(transportDegrade, id: read2.id, code: -32601, message: "method not found")
        let turns2 = try await waitForFakeAppServerRequest(transportDegrade, method: "thread/turns/list")
        transportResponse(transportDegrade, id: turns2.id, result: #"{"data":[],"nextCursor":null}"#)
        _ = try await pageDegrade.value
        await runtimeDegrade.shutdownForHostSwitch()
    }

    @MainActor
    func testC14C15Round3OpeningMissingDirectorySessionSkipsResumeWebSocketAndPreservesMissingPathNotice() async {
        let appStore = makeIsolatedAppStore()
        appStore.token = "test-token"
        let socket = MockWebSocketClient()
        let browseMissingSession = AgentSession(
            id: "sess-c15-browse-missing",
            projectID: "browse:deleted-empty-dir",
            project: "Removed Browse Dir",
            dir: "/tmp/browse-root/removed-empty-dir",
            title: "Browse Only Missing",
            status: "completed",
            source: "agy",
            runtimeProvider: "agy",
            resumeID: "sess-c15-browse-missing",
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: false,
            cwdMissing: true
        )
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [browseMissingSession],
            historyPages: [
                browseMissingSession.id: HistoryMessagesPage(
                    messages: [
                        CodexHistoryMessage(
                            id: "msg-1",
                            role: "assistant",
                            content: "Historical reply preserved read-only",
                            createdAt: Date()
                        )
                    ]
                )
            ]
        )
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket }
        )
        store.sessions = [browseMissingSession]

        let selected = await store.selectSession(browseMissingSession)
        XCTAssertTrue(selected)
        // Must NEVER open write-side WebSocket (which triggers thread/resume) for cwdMissing!
        XCTAssertTrue(socket.connectedSessionIDs.isEmpty)
        XCTAssertNil(store.connectedSessionID)
        // Must preserve dedicated missing-path notice and NOT surface "workspace expired" error!
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.selectedSessionControlNotice)
        XCTAssertTrue(
            store.selectedSessionControlNotice?.contains("移动或删除") == true
                || store.selectedSessionControlNotice?.contains("moved or deleted") == true
        )
        XCTAssertEqual(store.conversationStore.messages(for: browseMissingSession.id).count, 1)

        // Quiet background refresh for a missing browse projectID must NOT overwrite UI with "workspace expired".
        await store.refreshSessionListQuietlyIfStillSelected(projectID: browseMissingSession.projectID)
        XCTAssertNil(store.errorMessage)

        // C14/C15 round4: missing directory must skip cwd-dependent slash command prefetch.
        XCTAssertNil(
            store.claudeSlashCommandCatalogKey(
                cwd: browseMissingSession.dir,
                runtimeProvider: "agy",
                sandboxMode: .workspaceWrite,
                cwdMissing: true
            )
        )
        XCTAssertNotNil(
            store.claudeSlashCommandCatalogKey(
                cwd: browseMissingSession.dir,
                runtimeProvider: "agy",
                sandboxMode: .workspaceWrite,
                cwdMissing: false
            )
        )

        // ComposerStatusTray receives explicit missingDirectoryNotice directly on first screen (no disclosure needed).
        let tray = ComposerStatusTray(
            sessionControlNotice: nil,
            missingDirectoryNotice: store.selectedSessionControlNotice,
            ownershipNotice: nil,
            quotaNotice: nil,
            usage: nil,
            goal: nil,
            placement: .standalone,
            isGoalExpanded: false,
            isGoalUpdating: false,
            goalErrorMessage: nil,
            isRefreshDisabled: false,
            allowsTakeOver: false,
            onTakeOver: {},
            onRefreshUsage: {},
            onEditGoal: {},
            onTogglePauseGoal: {},
            onCompleteGoal: {},
            onClearGoal: {},
            onToggleGoalExpanded: {}
        )
        XCTAssertFalse(tray.hasExpandableDetail)
        XCTAssertEqual(tray.missingDirectoryNotice, store.selectedSessionControlNotice)
    }

    func testCombinedUsageItemSupportsGeminiAcrossSingleDualAndTripleRuntimes() {
        let codexDisplay = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                limitID: "codex",
                limitName: "Codex",
                secondaryUsedPercent: 72,
                secondaryResetsAt: 1_795_500_000,
                secondaryWindowDurationMins: 7 * 24 * 60
            ),
            fallbackDisplayName: "Codex"
        )
        let claudeDisplay = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                limitID: "claude",
                limitName: "Claude",
                primaryUsedPercent: 12,
                secondaryUsedPercent: 35,
                primaryResetsAt: 1_795_460_000,
                secondaryResetsAt: 1_795_600_000,
                primaryWindowDurationMins: 5 * 60,
                secondaryWindowDurationMins: 7 * 24 * 60
            ),
            fallbackDisplayName: "Claude"
        )
        let agyDisplay = CodexUsageWindowsDisplay.make(
            rateLimit: RateLimitSummary(
                limitID: "agy",
                limitName: "Antigravity",
                primaryUsedPercent: 2,
                secondaryUsedPercent: 29,
                primaryResetsAt: 1_795_460_000,
                secondaryResetsAt: 1_795_700_000,
                primaryWindowDurationMins: 5 * 60,
                secondaryWindowDurationMins: 7 * 24 * 60,
                availability: "available"
            ),
            fallbackDisplayName: "Gemini"
        )
        let emptyDisplay = CodexUsageWindowsDisplay.make(rateLimit: nil, fallbackDisplayName: "Empty")

        // 1) Codex + Gemini (without Claude): fills 3 rings with Codex 7d, Gemini 7d, Gemini 5h.
        let codexAndGemini = CombinedUsageItem.make(
            codexDisplay: codexDisplay,
            claudeDisplay: emptyDisplay,
            includesClaude: false,
            agyDisplay: agyDisplay,
            includesAgy: true,
            colorScheme: .dark
        )
        XCTAssertEqual(codexAndGemini.map(\.runtimeProvider), ["codex", "agy", "agy"])
        XCTAssertEqual(codexAndGemini.map(\.providerName), ["Codex", "Gemini", "Gemini"])
        XCTAssertEqual(codexAndGemini.map(\.window.label), ["7d", "7d", "5h"])
        XCTAssertEqual(codexAndGemini[1].window.remainingPercentText, "71%")
        XCTAssertEqual(codexAndGemini[2].window.remainingPercentText, "98%")

        // 2) Codex + Claude + Gemini: prioritizes one long window per runtime across the 3 rings.
        let allThree = CombinedUsageItem.make(
            codexDisplay: codexDisplay,
            claudeDisplay: claudeDisplay,
            includesClaude: true,
            agyDisplay: agyDisplay,
            includesAgy: true,
            colorScheme: .light
        )
        XCTAssertEqual(allThree.map(\.runtimeProvider), ["codex", "claude", "agy"])
        XCTAssertEqual(allThree.map(\.providerName), ["Codex", "Claude", "Gemini"])
        XCTAssertEqual(allThree.map(\.window.label), ["7d", "7d", "7d"])

        // 3) Codex + Claude (without Gemini): preserves existing order & windows.
        let codexAndClaude = CombinedUsageItem.make(
            codexDisplay: codexDisplay,
            claudeDisplay: claudeDisplay,
            includesClaude: true,
            agyDisplay: agyDisplay,
            includesAgy: false,
            colorScheme: .light
        )
        XCTAssertEqual(codexAndClaude.map(\.runtimeProvider), ["codex", "claude", "claude"])
        XCTAssertEqual(codexAndClaude.map(\.window.label), ["7d", "7d", "5h"])

        // 4) Gemini only: shows Gemini 7d + 5h.
        let geminiOnly = CombinedUsageItem.make(
            codexDisplay: emptyDisplay,
            claudeDisplay: emptyDisplay,
            includesClaude: false,
            agyDisplay: agyDisplay,
            includesAgy: true,
            colorScheme: .dark
        )
        XCTAssertEqual(geminiOnly.map(\.runtimeProvider), ["agy", "agy"])
        XCTAssertEqual(geminiOnly.map(\.window.label), ["7d", "5h"])
    }

    func testAgyUsageRefreshUpdatesProjectionAndSettingsAccountOverview() async {
        let agyRateLimit = RateLimitSummary(
            limitID: "agy",
            limitName: "Gemini",
            planType: "Google AI Ultra",
            primaryUsedPercent: 3,
            secondaryUsedPercent: 29,
            primaryResetsAt: 1_795_460_000,
            secondaryResetsAt: 1_795_700_000,
            primaryWindowDurationMins: 5 * 60,
            secondaryWindowDurationMins: 7 * 24 * 60,
            availability: "available"
        )
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            runtimeChannelAvailability: ["codex": true, "agy": true],
            rateLimitsByRuntime: ["agy": agyRateLimit]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshSettingsAccountOverview()

        XCTAssertTrue(store.isAgyRuntimeChannelAvailable)
        XCTAssertTrue(store.hasAgyRuntimeChannel)
        XCTAssertTrue(client.requestedRateLimitProviders.contains("codex"))
        XCTAssertTrue(client.requestedRateLimitProviders.contains("agy"))
        XCTAssertEqual(store.accountAgyUsageWindowsDisplay.displayName, "Gemini")
        XCTAssertTrue(store.accountAgyUsageWindowsDisplay.hasLiveData)
        XCTAssertEqual(store.accountAgyUsageWindowsDisplay.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(store.accountAgyUsageWindowsDisplay.windows.last?.remainingPercentText, "71%")
    }

    func testGeminiOnlyWithoutCodexHidesActivityPlaceholderUsesTwoRingsAndSkipsCodexRefresh() async {
        let agyRateLimit = RateLimitSummary(
            limitID: "agy",
            limitName: "Gemini",
            primaryUsedPercent: 4,
            secondaryUsedPercent: 30,
            primaryResetsAt: 1_795_460_000,
            secondaryResetsAt: 1_795_700_000,
            primaryWindowDurationMins: 5 * 60,
            secondaryWindowDurationMins: 7 * 24 * 60,
            availability: "available"
        )
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            runtimeChannelAvailability: ["codex": false, "agy": true],
            rateLimitsByRuntime: ["agy": agyRateLimit]
        )
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshSettingsAccountOverview()

        XCTAssertFalse(store.isCodexRuntimeChannelAvailable)
        XCTAssertFalse(store.hasCodexUsageChannel)
        XCTAssertTrue(store.hasAgyRuntimeChannel)
        XCTAssertEqual(client.requestedRateLimitProviders, ["agy"])

        let items = CombinedUsageItem.make(
            codexDisplay: store.accountCodexUsageWindowsDisplay,
            claudeDisplay: store.accountClaudeUsageWindowsDisplay,
            includesCodex: false,
            includesClaude: false,
            agyDisplay: store.accountAgyUsageWindowsDisplay,
            includesAgy: true,
            colorScheme: .dark
        )
        XCTAssertEqual(items.map(\.runtimeProvider), ["agy", "agy"])
        XCTAssertEqual(AccountTokenUsageCard.ringCount(forItemCount: items.count), 2)
        XCTAssertEqual(AccountTokenUsageCard.ringCount(forItemCount: 3), 3)
        XCTAssertEqual(AccountTokenUsageCard.ringCount(forItemCount: 0), 3)
    }
}

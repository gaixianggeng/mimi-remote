import Foundation
import XCTest
@testable import MimiRemoteMac

final class AgentDiagnosticsTests: XCTestCase {
    func testStatusDecodesCapacityRetentionAndExpiration() throws {
        let raw = #"{"enabled":true,"expires_at":"2026-09-22T08:15:30Z","current_bytes":1024,"previous_bytes":2048,"total_bytes":3072,"max_total_bytes":10485760,"retention_days":7,"dropped_records":12}"#

        let status = try JSONDecoder().decode(AgentDiagnosticsStatus.self, from: Data(raw.utf8))

        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.expiresAt, "2026-09-22T08:15:30Z")
        XCTAssertNotNil(status.expirationDate)
        XCTAssertEqual(status.currentBytes, 1024)
        XCTAssertEqual(status.previousBytes, 2048)
        XCTAssertEqual(status.totalBytes, 3072)
        XCTAssertEqual(status.maxTotalBytes, 10 * 1_048_576)
        XCTAssertEqual(status.retentionDays, 7)
        XCTAssertEqual(status.droppedRecords, 12)
    }

    func testStatusDefaultsMissingDroppedRecordsToZero() throws {
        let raw = #"{"enabled":false,"current_bytes":0,"previous_bytes":0,"total_bytes":0,"max_total_bytes":10485760,"retention_days":7}"#

        let status = try JSONDecoder().decode(AgentDiagnosticsStatus.self, from: Data(raw.utf8))

        XCTAssertEqual(status.droppedRecords, 0)
    }

    func testStatusDecodesDebugLogSizeAndDefaultsItForOlderAgents() throws {
        let current = #"{"enabled":true,"current_bytes":10,"previous_bytes":0,"total_bytes":10,"max_total_bytes":10485760,"retention_days":7,"debug_bytes":4096}"#
        let older = #"{"enabled":true,"current_bytes":10,"previous_bytes":0,"total_bytes":10,"max_total_bytes":10485760,"retention_days":7}"#

        XCTAssertEqual(try JSONDecoder().decode(AgentDiagnosticsStatus.self, from: Data(current.utf8)).debugBytes, 4096)
        XCTAssertEqual(try JSONDecoder().decode(AgentDiagnosticsStatus.self, from: Data(older.utf8)).debugBytes, 0)
    }

    func testDebugLogSitsNextToTheAgentdLog() {
        let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        XCTAssertEqual(
            AgentdSupervisorCommand.debugLogURL(homeDirectoryURL: home).path,
            "/Users/tester/Library/Logs/mimi-remote/agentd-debug.log"
        )
    }

    func testExportDecodesOrderedSafeLines() throws {
        let raw = #"{"lines":["{\"level\":\"error\",\"code\":\"upstream_failed\"}","{\"level\":\"info\",\"event\":\"request_completed\"}"]}"#

        let result = try JSONDecoder().decode(AgentDiagnosticsExport.self, from: Data(raw.utf8))

        XCTAssertEqual(result.lines, [
            #"{"level":"error","code":"upstream_failed"}"#,
            #"{"level":"info","event":"request_completed"}"#,
        ])
    }

    @MainActor
    func testStoreShowsUnavailableStatusAndLogFailure() async {
        var agent = Self.agentStub()
        agent.diagnosticsStatus = {
            throw AgentClientError.commandFailed("诊断服务未运行")
        }
        let store = Self.makeStore(
            agent: agent,
            logs: AgentLogClient(
                recentLines: { _ in throw AgentClientError.commandFailed("安全日志不可用") },
                exportLines: { [] }
            )
        )

        await store.refreshDiagnostics()

        XCTAssertNil(store.diagnosticsStatus)
        XCTAssertEqual(store.diagnosticsStatusError, "诊断服务未运行")
        XCTAssertEqual(store.diagnosticsLogError, "安全日志不可用")
    }

    @MainActor
    func testStoreUpdatesToggleClearsAndExportsSafeLogs() async {
        let events = DiagnosticsEventRecorder()
        var agent = Self.agentStub()
        agent.diagnosticsStatus = { Self.status(enabled: false) }
        agent.setDetailedDiagnostics = { enabled in
            events.append(enabled ? "start" : "stop")
            return Self.status(enabled: enabled)
        }
        agent.clearDiagnostics = {
            events.append("clear")
            return Self.status(enabled: false, totalBytes: 0)
        }
        let store = Self.makeStore(
            agent: agent,
            logs: AgentLogClient(
                recentLines: { _ in ["safe-recent"] },
                exportLines: {
                    events.append("export")
                    return ["safe-export"]
                }
            )
        )

        await store.refreshDiagnostics()
        await store.setDetailedDiagnostics(true)
        let export = await store.diagnosticExportLines()
        await store.clearDiagnostics()

        XCTAssertEqual(export, ["safe-export"])
        XCTAssertFalse(store.diagnosticsStatus?.enabled ?? true)
        XCTAssertEqual(store.diagnosticsStatus?.totalBytes, 0)
        XCTAssertTrue(store.recentLogs.isEmpty)
        XCTAssertEqual(events.values, ["start", "export", "clear"])
    }

    func testDiagnosticLogSanitizerRedactsCredentialsURLsPathsAndNonLoopbackIPs() {
        let dirty = [
            #"Authorization: Bearer tok_super_secret_123"#,
            #"{"token":"secret-host","pair_url":"mimiremote://pair?pair_sig=abc&token=xyz","grant":"g-1","signature":"s-2"}"#,
            #"connect_url=https://100.64.0.9:8787/ws?dsh_token=harness999&ws_token=ws888"#,
            #"failed reading /Users/alice/Library/Application Support/mimi-remote/config.json from 192.168.1.42"#,
            #"{"level":"info","version":"0.150.0","listen":"127.0.0.1:8787"}"#,
            #"failed with Bearer solo_secret_456"#,
        ]

        // Unstructured lines have no exportable fields, including legacy "safe-looking" JSON.
        XCTAssertTrue(DiagnosticLogSanitizer.eventLines(dirty).isEmpty)
        for line in dirty + ["ssh private-account@private-host", "raw stderr: private-project"] {
            XCTAssertEqual(DiagnosticLogSanitizer.serviceMessage(line), OnboardingCopyCatalog.safeFallbackCopy)
        }
        let trusted = OnboardingCopyCatalog.localizedMessage(code: "service_not_running", step: .serviceDaemon)
        XCTAssertEqual(DiagnosticLogSanitizer.serviceMessage(trusted), trusted)
    }

    func testLogExportAndLegacyDoctorCannotIncludeOpaquePrivateFields() throws {
        let event = #"{"at":"2026-01-01T12:00:00Z","stage":"http","outcome":"failed","stderr":"private stderr","operation":"opaque-grant","reference":"credential"}"#
        let lines = DiagnosticLogSanitizer.eventLines([event, "ssh local-user@private-host"])
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(line.contains("failed"))
        for privateValue in ["stderr", "private", "opaque-grant", "credential"] {
            XCTAssertFalse(line.contains(privateValue))
        }
        let check = AgentCheck(name: "codex-app-server", ok: false, level: "error",
                               message: "private stderr", fix: "ssh local-user@private-host")
        let display = DoctorCheckPresentation.make(from: check)
        XCTAssertEqual(display.localizedTitle, "Codex 运行环境")
        XCTAssertFalse(display.sanitizedMessage.contains("private"))
        XCTAssertFalse(display.sanitizedDetail?.contains("private") ?? false)
    }

    func testDoctorDisplayChecksAreReadOnlyWithChineseTitlesAndSanitizedText() {
        let rawChecks = [
            AgentCheck(name: "config", ok: false, level: "error", message: "bad /Users/bob/config.json", fix: "Bearer tok123"),
            AgentCheck(name: "tailscale", ok: true, level: "", message: "connected 100.64.1.2", fix: nil),
        ]
        let display = rawChecks.map(DoctorCheckPresentation.make(from:))
        XCTAssertEqual(display[0].localizedTitle, "配置文件")
        XCTAssertFalse(display[0].sanitizedMessage.contains("bob"))
        XCTAssertEqual(display[0].sanitizedDetail, "请参照上方对应的预检项目处理。")
        XCTAssertEqual(display[1].localizedTitle, "Tailscale 网络")
        XCTAssertFalse(display[1].sanitizedMessage.contains("100.64.1.2"))
    }

    @MainActor
    func testDiagnosticsClickableFixesComeOnlyFromPreflightAndHostRecoveryIsReadOnly() async throws {
        for code in ["config_invalid", "config_recovery_required", "token_rotation_requires_approval", "legacy_codex_residue"] {
            let doctorFixCalls = CallCounter()
            let report = Self.makeMacPairReport(
                configCheck: OnboardingCheck(
                    id: .configStore,
                    state: .error,
                    detail: "配置需要恢复。",
                    blocking: true,
                    code: code,
                    fix: .openSettings(.hostRecovery),
                    configPath: "/Users/private-user/Library/Application Support/mimi-remote/config.json",
                    recoveryPath: "/Users/private-user/Library/Application Support/mimi-remote/config.previous.json"
                )
            )
            var deps = Self.makeDiagnosticsDependencies(report: report)
            deps.runSafeDoctorFix = {
                _ = doctorFixCalls.increment()
                return []
            }
            deps.runReadOnlyDoctor = {
                AgentDoctorResults(ok: false, version: "1.0.0", listen: "127.0.0.1:8787", checks: [
                    AgentCheck(name: "config", ok: false, level: "error", message: "corrupted", fix: "agentd setup --force"),
                ])
            }

            let store = DiagnosticsStore(
                dependencies: deps,
                verifiedCapability: OnboardingSchema.doctorFixCapability
            )
            await store.refreshAll()

            XCTAssertTrue(store.doctorChecks.isEmpty, "Recovery must not probe tools from the unsafe config")

            let configRow = try XCTUnwrap(store.check(for: .configStore))
            XCTAssertFalse(store.canClickDoctorFix(for: configRow), code)
            XCTAssertEqual(store.clickablePrimaryFix(for: configRow), .openSettings(.hostRecovery), code)
            let recovery = try XCTUnwrap(store.recoveryDiagnostic, code)
            XCTAssertEqual(recovery.code, code)
            XCTAssertEqual(recovery.configPath, "…/config.json")
            XCTAssertEqual(recovery.recoveryPath, "…/config.previous.json")
            XCTAssertFalse(recovery.configPath?.contains("private-user") ?? false)

            await store.performCheckPrimaryAction(for: configRow)
            XCTAssertEqual(doctorFixCalls.current, 0, "host_recovery must be strictly read-only for \(code)")
        }
    }

    @MainActor
    func testPassiveDiagnosticsDoesNotRunLegacyDoctor() async {
        let calls = CallCounter()
        var deps = Self.makeDiagnosticsDependencies(report: Self.makeMacPairReport(configCheck: nil))
        deps.runReadOnlyDoctor = {
            _ = calls.increment()
            return AgentDoctorResults(ok: true, version: "test", listen: "", checks: [])
        }
        let store = DiagnosticsStore(dependencies: deps)
        await store.runPreflight()
        XCTAssertTrue(store.canReadDoctor)
        XCTAssertEqual(calls.current, 0)
        await store.runReadOnlyDoctor()
        XCTAssertEqual(calls.current, 1)
    }

    func testDoctorCapabilityBelongsToThePackagedBinary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appendingPathExtension("bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "test.mimi.capability", "CFBundlePackageType": "BNDL"]
        try PropertyListEncoder().encode(plist).write(to: directory.appending(path: "Contents/Info.plist"))
        let binary = resources.appending(path: "agentd")
        let marker = resources.appending(path: "agentd-onboarding-capability")
        try Data().write(to: binary)
        try Data().write(to: marker)
        let bundle = try XCTUnwrap(Bundle(url: directory))
        let client = AgentCommandClient.live(bundle: bundle)
        XCTAssertNil(client.verifiedOnboardingCapability())
        try Data(OnboardingSchema.doctorFixCapability.utf8).write(to: marker)
        XCTAssertEqual(client.verifiedOnboardingCapability(), OnboardingSchema.doctorFixCapability)
        XCTAssertNil(AgentCommandClient.live(bundle: bundle, binaryOverride: binary).verifiedOnboardingCapability())
        try Data("unknown".utf8).write(to: marker)
        XCTAssertNil(client.verifiedOnboardingCapability())
    }

    @MainActor
    func testDoctorFixOnlyRunsOnVerifiedBE3HostWithConfigPermissionsUnsafeAndRerunsPreflight() async throws {
        let unsafeCheck = OnboardingCheck(
            id: .configStore,
            state: .error,
            detail: "配置文件的访问权限过宽。请在电脑上修复权限。",
            blocking: true,
            code: "config_permissions_unsafe",
            fix: .runFix(.doctorFix)
        )
        let unsafeReport = Self.makeMacPairReport(configCheck: unsafeCheck)
        let greenReport = Self.makeMacPairReport(configCheck: nil)

        // 1. Pre-BE-3 host (verifiedCapability == nil): doctor_fix MUST NOT be clickable or executed.
        let preBE3DoctorFixCalls = CallCounter()
        var preBE3Deps = Self.makeDiagnosticsDependencies(report: unsafeReport)
        preBE3Deps.runSafeDoctorFix = {
            _ = preBE3DoctorFixCalls.increment()
            return ["should-not-run"]
        }
        let preBE3Store = DiagnosticsStore(dependencies: preBE3Deps, verifiedCapability: nil)
        await preBE3Store.runPreflight()
        XCTAssertFalse(preBE3Store.isBE3DoctorFixSupported)
        XCTAssertFalse(preBE3Store.canClickDoctorFix(for: unsafeCheck))
        await preBE3Store.performCheckPrimaryAction(for: unsafeCheck)
        XCTAssertEqual(preBE3DoctorFixCalls.current, 0)

        // 2. Verified BE-3+ host: doctor_fix IS clickable for config_permissions_unsafe and re-runs preflight.
        let preflightCalls = CallCounter()
        let doctorFixCalls = CallCounter()
        var be3Deps = Self.makeDiagnosticsDependencies(report: unsafeReport)
        be3Deps.preflight = { _, _ in
            let count = preflightCalls.increment()
            return count == 1 ? unsafeReport : greenReport
        }
        be3Deps.runSafeDoctorFix = {
            _ = doctorFixCalls.increment()
            return ["已收紧 /Users/alice/config.json 权限"]
        }
        let be3Store = DiagnosticsStore(
            dependencies: be3Deps,
            verifiedCapability: OnboardingSchema.doctorFixCapability
        )
        await be3Store.runPreflight()
        let row = try XCTUnwrap(be3Store.check(for: .configStore))
        XCTAssertTrue(be3Store.canClickDoctorFix(for: row))
        XCTAssertEqual(be3Store.clickablePrimaryFix(for: row), .runFix(.doctorFix))

        await be3Store.performCheckPrimaryAction(for: row)
        XCTAssertEqual(doctorFixCalls.current, 1)
        XCTAssertEqual(preflightCalls.current, 2, "doctor_fix 完成后必须立即重跑预检")
        XCTAssertEqual(be3Store.check(for: .configStore)?.state, .ok)
        XCTAssertEqual(be3Store.appliedFixes, ["已完成文件权限修复"])
    }

    @MainActor
    func testTamperedRotatesTokenPayloadExecutesZeroActionsInDiagnostics() async {
        let doctorFixCalls = CallCounter()
        let tamperedStdout = Data(
            #"{"ok":false,"error":{"code":"config_permissions_unsafe","step":"config_store","message":"fix","fix":{"kind":"run_fix","action":"doctor_fix","rotates_token":true}}}"#
                .utf8
        )
        let resolved = OnboardingCopyCatalog.resolveCLIError(
            stdout: tamperedStdout,
            stderr: Data(),
            context: OnboardingValidationContext(
                surface: .cli,
                platform: .macos,
                stage: .pair,
                configured: true,
                verifiedCapability: OnboardingSchema.doctorFixCapability
            )
        )
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.isTrusted, false)
        XCTAssertNil(resolved?.primaryAction)

        let unsafe = OnboardingCheck(id: .configStore, state: .error, detail: "权限过宽",
                                     blocking: true, code: "config_permissions_unsafe", fix: .runFix(.doctorFix))
        let previous = Self.makeMacPairReport(configCheck: unsafe)
        let calls = CallCounter()
        var deps = Self.makeDiagnosticsDependencies(report: previous)
        deps.preflight = { _, _ in
            if calls.increment() == 1 { return previous }
            throw AgentClientError.onboarding(resolved!)
        }
        deps.runSafeDoctorFix = {
            _ = doctorFixCalls.increment()
            return []
        }

        let store = DiagnosticsStore(
            dependencies: deps,
            verifiedCapability: OnboardingSchema.doctorFixCapability
        )
        await store.runPreflight()
        XCTAssertEqual(store.clickablePrimaryFix(for: unsafe), .runFix(.doctorFix))
        await store.runPreflight()
        await store.performCheckPrimaryAction(for: unsafe)
        XCTAssertNil(store.clickablePrimaryFix(for: unsafe))
        if let err = store.preflightError {
            await store.performDiagnosticAction(err)
        }
        XCTAssertEqual(doctorFixCalls.current, 0)
        XCTAssertNil(store.preflightError?.primaryAction)
    }

    @MainActor
    func testDiagnosticsRoutesOpenSettingsAssistantsTarget() async throws {
        let openedTargets = DiagnosticsEventRecorder()
        let report = Self.makeMacPairReport(
            configCheck: nil,
            codexCheck: OnboardingCheck(
                id: .assistantCodex,
                state: .error,
                detail: "Codex 连接设置无效。",
                blocking: false,
                code: "codex_transport_invalid",
                fix: .openSettings(.assistants),
                enabled: true,
                available: false,
                candidates: []
            )
        )
        var deps = Self.makeDiagnosticsDependencies(report: report)
        deps.openSettings = { target in
            openedTargets.append(target.rawValue)
        }
        let store = DiagnosticsStore(dependencies: deps)
        await store.runPreflight()

        let codexRow = try XCTUnwrap(store.check(for: .assistantCodex))
        await store.performCheckPrimaryAction(for: codexRow)
        XCTAssertEqual(openedTargets.values, ["assistants"])
    }

    private static func makeDiagnosticsDependencies(report: OnboardingPreflightReport) -> DiagnosticsDependencies {
        DiagnosticsDependencies(
            configExists: { true },
            preflight: { _, _ in report },
            runReadOnlyDoctor: { AgentDoctorResults(ok: true, version: "1.0.0", listen: "127.0.0.1:8787", checks: []) },
            runSafeDoctorFix: { [] },
            enableAssistant: { _ in },
            enableTransport: { _ in },
            restartService: {},
            registerOrStartService: { .ready },
            setRuntimePath: { _, _ in },
            updateWorkspace: { _, _ in },
            agentRegistrationState: { .enabled },
            mainAppRegistrationState: { .enabled },
            photosAccessState: { .notDetermined },
            localNetworkAccessDenied: { false },
            openURL: { _ in },
            openSettings: { _ in }
        )
    }

    private static func makeMacPairReport(
        configCheck: OnboardingCheck?,
        codexCheck: OnboardingCheck? = nil
    ) -> OnboardingPreflightReport {
        let resolvedConfig = configCheck ?? OnboardingCheck(
            id: .configStore,
            state: .ok,
            detail: "配置文件可安全读写。",
            blocking: false
        )
        let resolvedCodex = codexCheck ?? OnboardingCheck(
            id: .assistantCodex,
            state: .ok,
            detail: "Codex 已就绪。",
            blocking: false,
            enabled: true,
            available: true,
            candidates: [OnboardingCandidate(path: "/fixture/bin/codex", outcome: .selected, version: "0.150.0")],
            source: .auto,
            detectedVersion: "0.150.0"
        )
        let checks: [OnboardingCheck] = [
            resolvedConfig,
            OnboardingCheck(id: .workspaceRoot, state: .ok, detail: "目录可读取。", blocking: false),
            OnboardingCheck(id: .serviceOwnerConflict, state: .ok, detail: "归属已确认。", blocking: false),
            OnboardingCheck(id: .serviceDaemon, state: .ok, detail: "后台服务已就绪。", blocking: false),
            resolvedCodex,
            OnboardingCheck(
                id: .assistantClaude, state: .ok, detail: "Claude 已就绪。", blocking: false,
                enabled: true, available: true,
                candidates: [OnboardingCandidate(path: "/fixture/bin/claude", outcome: .selected, version: "2.1.300")],
                source: .auto, detectedVersion: "2.1.300"
            ),
            OnboardingCheck(
                id: .assistantAgy, state: .optional, detail: "未检测到 Antigravity。", blocking: false,
                code: "agy_not_found", fix: .openURL(.agy),
                enabled: false, available: false, candidates: []
            ),
            OnboardingCheck(
                id: .assistantDeepSeek, state: .optional, detail: "未检测到 DeepSeek。", blocking: false,
                code: "deepseek_not_running", fix: .openURL(.harness),
                enabled: false, available: false
            ),
            OnboardingCheck(id: .assistantAny, state: .ok, detail: "至少有一个可用助手。", blocking: false),
            OnboardingCheck(id: .networkTailscale, state: .ok, detail: "Tailscale 已连接。", blocking: false, enabled: true, available: true),
            OnboardingCheck(id: .networkTailcat, state: .ok, detail: "内置连接可用。", blocking: false, enabled: true, available: true),
            OnboardingCheck(id: .networkLAN, state: .ok, detail: "局域网可用。", blocking: false, enabled: true, available: true),
            OnboardingCheck(id: .networkAny, state: .ok, detail: "已有可用连接方式。", blocking: false),
            OnboardingCheck(id: .permissionLoginItem, state: .ok, detail: "已允许登录时启动。", blocking: false),
            OnboardingCheck(id: .permissionFolderAccess, state: .ok, detail: "已允许访问所选目录。", blocking: false),
            OnboardingCheck(id: .permissionLocalNetwork, state: .ok, detail: "已允许访问本地网络。", blocking: false),
            OnboardingCheck(id: .permissionPhotos, state: .optional, detail: "尚未获得状态。", blocking: false, code: "permission_unobserved", fix: .skip),
            OnboardingCheck(id: .permissionFullDisk, state: .optional, detail: "尚未获得状态。", blocking: false, code: "permission_unobserved", fix: .skip),
        ]
        let firstBlocker = checks.first(where: \.blocking)?.id
        return OnboardingPreflightReport(
            ok: firstBlocker == nil,
            stage: .pair,
            configured: true,
            workspaceConfirmed: true,
            configPath: "/fixture/config/config.json",
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            scanRootExists: true,
            recommendedNext: firstBlocker ?? .networkAny,
            recommendedTransport: .tailscale,
            checks: checks
        )
    }

    private static func status(enabled: Bool, totalBytes: Int64 = 3) -> AgentDiagnosticsStatus {
        AgentDiagnosticsStatus(
            enabled: enabled,
            expiresAt: enabled ? "2026-09-22T08:15:30Z" : nil,
            currentBytes: totalBytes,
            previousBytes: 0,
            totalBytes: totalBytes,
            maxTotalBytes: 10 * 1_048_576,
            retentionDays: 7
        )
    }

    private static func agentStub() -> AgentCommandClient {
        AgentCommandClient(
            configExists: { true },
            setup: { _ in throw AgentClientError.commandFailed("unused") },
            status: { throw AgentClientError.commandFailed("unused") },
            readiness: { throw AgentClientError.commandFailed("unused") },
            statusAt: { _ in throw AgentClientError.commandFailed("unused") },
            doctor: { _ in throw AgentClientError.commandFailed("unused") },
            configureClaude: { _, _ in throw AgentClientError.commandFailed("unused") },
            setLANAccess: { _ in throw AgentClientError.commandFailed("unused") },
            pair: { _ in throw AgentClientError.commandFailed("unused") },
            version: { "test" }
        )
    }

    @MainActor
    private static func makeStore(agent: AgentCommandClient, logs: AgentLogClient) -> HostStore {
        HostStore(
            agent: agent,
            services: .live(),
            homebrew: .live(),
            health: .live,
            logs: logs
        )
    }
}

private final class DiagnosticsEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

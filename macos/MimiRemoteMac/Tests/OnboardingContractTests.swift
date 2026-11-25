import Foundation
import XCTest
@testable import MimiRemoteMac

final class OnboardingContractTests: XCTestCase {
    private static func contractsDirectory() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("contracts/host-cli")
    }

    private func loadContractData(_ filename: String) throws -> Data {
        try Data(contentsOf: Self.contractsDirectory().appendingPathComponent(filename))
    }

    // MARK: - Catalog set-equality & timeouts

    func testCatalogMatchesSharedManifestSetEqualityAndTimeouts() throws {
        struct Manifest: Decodable {
            struct CheckEntry: Decodable {
                let id: String
                let group: String
                let platforms: [String]
            }
            struct RunFixEntry: Decodable {
                let requiresConfig: Bool
                let requiresCapability: String?
            }
            struct TimeoutEntry: Decodable {
                let commands: [String]
                let backendMax: Int
                let clientMin: Int
            }
            struct CodeEntry: Decodable {
                let code: String
            }
            let schema: String
            let checks: [CheckEntry]
            let urls: [String: String]
            let settingsTargets: [String]
            let pathTargets: [String]
            let runFix: [String: RunFixEntry]
            let timeoutsSeconds: [TimeoutEntry]
            let wireCodes: [CodeEntry]
            let uiLocalCodes: [CodeEntry]
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(Manifest.self, from: loadContractData("onboarding-codes-v1.json"))

        XCTAssertEqual(manifest.schema, OnboardingSchema.codesV1)
        XCTAssertGreaterThan(manifest.checks.count, 0)
        XCTAssertGreaterThan(manifest.wireCodes.count, 0)
        XCTAssertGreaterThan(manifest.uiLocalCodes.count, 0)

        // Exact ordered 18 checks
        XCTAssertEqual(OnboardingCheckID.allCases.count, manifest.checks.count)
        for (index, want) in manifest.checks.enumerated() {
            let got = OnboardingCheckID.allCases[index]
            XCTAssertEqual(got.rawValue, want.id)
            XCTAssertEqual(got.group.rawValue, want.group)
            XCTAssertEqual(got.platforms.map(\.rawValue), want.platforms)
        }

        // Exact set-equality for 77 wire + 2 UI-local codes, with Chinese copy on every code
        let manifestWire = Set(manifest.wireCodes.map(\.code))
        let manifestLocal = Set(manifest.uiLocalCodes.map(\.code))
        XCTAssertEqual(OnboardingCopyCatalog.wireCodes, manifestWire)
        XCTAssertEqual(OnboardingCopyCatalog.uiLocalCodes, manifestLocal)
        XCTAssertTrue(OnboardingCopyCatalog.wireCodes.isDisjoint(with: OnboardingCopyCatalog.uiLocalCodes))
        for entry in OnboardingCopyCatalog.allEntries {
            XCTAssertFalse(entry.messageZH.isEmpty, entry.code)
            XCTAssertTrue(
                entry.messageZH.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "Code \(entry.code) must contain Chinese copy"
            )
        }

        // Exact URL, settings, path, run_fix allow-lists
        let clientURLs = Dictionary(uniqueKeysWithValues: OnboardingFixURL.allCases.map { ($0.key, $0.rawValue) })
        XCTAssertEqual(clientURLs, manifest.urls)
        XCTAssertEqual(OnboardingSettingsTarget.allCases.map(\.rawValue), manifest.settingsTargets)
        XCTAssertEqual(OnboardingPathTarget.allCases.map(\.rawValue), manifest.pathTargets)
        XCTAssertEqual(Set(OnboardingRunFixAction.allCases.map(\.rawValue)), Set(manifest.runFix.keys))
        for action in OnboardingRunFixAction.allCases {
            let want = try XCTUnwrap(manifest.runFix[action.rawValue])
            XCTAssertEqual(action.requiresConfig, want.requiresConfig, action.rawValue)
            XCTAssertEqual(action.requiredCapability, want.requiresCapability, action.rawValue)
        }

        // Timeout budget table >= client_min for every command category
        for entry in manifest.timeoutsSeconds {
            for command in entry.commands {
                let actual = AgentCommandTimeouts.duration(for: command)
                XCTAssertGreaterThanOrEqual(
                    actual,
                    .seconds(entry.clientMin),
                    "Command \(command) timeout \(actual) must be >= \(entry.clientMin)s"
                )
            }
        }
    }

    // MARK: - Full onboarding-error-cases.json contract matrix

    func testAllOnboardingErrorCasesIncludingNegativeAndAdditive() throws {
        let raw = try loadContractData("onboarding-error-cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 0)

        var executed = 0
        for item in cases {
            executed += 1
            let id = try XCTUnwrap(item["id"] as? String)
            let valid = try XCTUnwrap(item["valid"] as? Bool)
            let rawCtx = try XCTUnwrap(item["context"] as? [String: Any])
            let surfaceRaw = try XCTUnwrap(rawCtx["surface"] as? String)
            let platform = try XCTUnwrap((rawCtx["platform"] as? String).flatMap(OnboardingPlatform.init(rawValue:)))
            let verifiedCap = rawCtx["verified_capability"] as? String

            if surfaceRaw == "report" {
                let fixtureName = try XCTUnwrap(item["fixture"] as? String)
                let patches = try XCTUnwrap(item["patch"] as? [[String: Any]])
                let patchedData = try applyReportPatch(fixture: fixtureName, patches: patches)
                let result: Result<[OnboardingCheckID: OnboardingResolvedDiagnostic], Error>
                do {
                    let report = try JSONDecoder().decode(OnboardingPreflightReport.self, from: patchedData)
                    result = OnboardingCopyCatalog.validateReport(
                        report,
                        platform: platform,
                        nativeOverlay: false,
                        verifiedCapability: verifiedCap
                    ).mapError { $0 as Error }
                } catch {
                    result = .failure(error)
                }
                if valid {
                    if case .failure(let error) = result {
                        XCTFail("Expected valid report case \(id), got error: \(error)")
                    }
                } else if case .success = result {
                    XCTFail("Expected invalid report case \(id) to fail")
                }
                continue
            }

            let surface = try XCTUnwrap(OnboardingSurface(rawValue: surfaceRaw), id)
            let stage = (rawCtx["stage"] as? String).flatMap(OnboardingStage.init(rawValue:)) ?? .pair
            let configured = rawCtx["configured"] as? Bool
            let hasRecTransport = rawCtx.keys.contains("recommended_transport")
            let recTransport = (rawCtx["recommended_transport"] as? String).flatMap(OnboardingTransport.init(rawValue:))
            let explicitlyEnabled = rawCtx["explicitly_enabled"] as? Bool
            let ctx = OnboardingValidationContext(
                surface: surface,
                platform: platform,
                stage: stage,
                configured: configured,
                hasRecommendedTransport: hasRecTransport,
                recommendedTransport: recTransport,
                verifiedCapability: verifiedCap,
                explicitlyEnabled: explicitlyEnabled
            )
            let payloadObj = try XCTUnwrap(item["payload"] as? [String: Any], id)
            let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)

            switch surface {
            case .check, .native:
                let checkResult: Result<OnboardingResolvedDiagnostic, Error>
                do {
                    let check = try JSONDecoder().decode(OnboardingCheck.self, from: payloadData)
                    checkResult = OnboardingCopyCatalog.validateCheck(check, context: ctx).mapError { $0 as Error }
                } catch {
                    checkResult = .failure(error)
                }
                if valid {
                    switch checkResult {
                    case .success(let resolved):
                        XCTAssertTrue(resolved.isTrusted, id)
                    case .failure(let error):
                        XCTFail("Expected valid check case \(id), got error: \(error)")
                    }
                } else if case .success(let resolved) = checkResult {
                    XCTFail("Expected invalid check case \(id) to fail, got \(resolved)")
                }
            case .cli, .http, .uiLocal:
                let envResult = OnboardingCopyCatalog.decodeErrorEnvelope(from: payloadData, context: ctx)
                if valid {
                    switch envResult {
                    case .success(let resolved):
                        XCTAssertTrue(resolved.isTrusted, id)
                        XCTAssertNotNil(resolved.primaryAction, id)
                    case .failure(let error):
                        XCTFail("Expected valid envelope case \(id), got error: \(error)")
                    }
                } else {
                    if case .success(let resolved) = envResult {
                        XCTFail("Expected invalid envelope case \(id) to fail, got \(resolved)")
                    }
                    if surface == .cli {
                        let safe = OnboardingCopyCatalog.resolveCLIError(stdout: payloadData, stderr: Data(), context: ctx)
                        XCTAssertEqual(safe?.primaryAction, nil, "Invalid CLI case \(id) must yield zero execution")
                        XCTAssertEqual(safe?.isTrusted, false, id)
                    }
                }
            }
        }
        XCTAssertEqual(executed, cases.count)
    }

    // MARK: - Fixtures: preflight reports, receipts, enabled-but-signed-out assistant, no-QR setup

    func testPreflightFixturesAndEnabledButSignedOutOtherAssistant() throws {
        let specs: [(String, OnboardingPlatform, Bool)] = [
            ("preflight-all-green.json", .macos, false),
            ("preflight-claude-only-no-network.json", .linux, false),
            ("preflight-codex-chatgpt-app.json", .macos, false),
            ("preflight-permission-needed.json", .macos, true),
            ("preflight-deepseek-only.json", .linux, false),
            ("preflight-windows-public.json", .windows, false),
        ]
        for (file, platform, nativeOverlay) in specs {
            let report = try JSONDecoder().decode(OnboardingPreflightReport.self, from: loadContractData(file))
            let validation = OnboardingCopyCatalog.validateReport(
                report,
                platform: platform,
                nativeOverlay: nativeOverlay
            )
            let resolvedMap = try validation.get()
            XCTAssertEqual(resolvedMap.count, OnboardingCheckID.applicable(for: platform).count, file)

            if file == "preflight-codex-chatgpt-app.json" {
                let byID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
                XCTAssertTrue(report.ok)
                XCTAssertEqual(byID[.assistantCodex]?.state, .ok)
                XCTAssertEqual(byID[.assistantClaude]?.code, "claude_signed_out")
                XCTAssertEqual(byID[.assistantClaude]?.state, .actionNeeded)
                XCTAssertEqual(byID[.assistantClaude]?.enabled, true)
                XCTAssertEqual(byID[.assistantClaude]?.available, false)
                XCTAssertEqual(resolvedMap[.assistantClaude]?.secondaryAction, .retry)
                XCTAssertEqual(resolvedMap[.assistantClaude]?.secondaryLabel, "我已登录，重新检查")
                XCTAssertTrue(resolvedMap[.assistantClaude]?.message.contains("2.1.300") == true)
                XCTAssertEqual(byID[.assistantAgy]?.code, "assistant_disabled")
                XCTAssertEqual(byID[.assistantAgy]?.state, .optional)
                XCTAssertEqual(byID[.assistantAgy]?.available, true)
                XCTAssertEqual(byID[.assistantAgy]?.enabled, false)
            }
        }
    }

    func testSetupNoTicketReceiptsAndUpAndPairReceipts() throws {
        let noAssistant = try JSONDecoder().decode(SetupReceipt.self, from: loadContractData("setup-ok-no-assistant.json"))
        XCTAssertTrue(noAssistant.ok)
        XCTAssertTrue(noAssistant.configured)
        XCTAssertTrue(noAssistant.created)
        XCTAssertNil(noAssistant.pairURL)
        XCTAssertFalse(noAssistant.asPairingInfo.hasTicket)

        let deferred = try JSONDecoder().decode(SetupReceipt.self, from: loadContractData("setup-ok-pairing-deferred.json"))
        XCTAssertTrue(deferred.ok)
        XCTAssertEqual(deferred.pairingDeferred, true)
        XCTAssertNil(deferred.pairURL)
        XCTAssertFalse(deferred.asPairingInfo.hasTicket)

        // PairingInfo directly decodes no-ticket setup JSON with nil pairURL
        let noTicketPairing = try JSONDecoder().decode(PairingInfo.self, from: loadContractData("setup-ok-pairing-deferred.json"))
        XCTAssertNil(noTicketPairing.pairURL)
        XCTAssertFalse(noTicketPairing.hasTicket)

        // Legacy ticket-bearing setup response still decodes
        let legacyData = Data(#"{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T00:05:00Z"}"#.utf8)
        let legacyReceipt = try JSONDecoder().decode(SetupReceipt.self, from: legacyData)
        XCTAssertTrue(legacyReceipt.isLegacy)
        XCTAssertTrue(legacyReceipt.asPairingInfo.hasTicket)

        // Up readiness vs submitted
        let ready = try JSONDecoder().decode(UpReadinessReceipt.self, from: loadContractData("up-ok-ready.json"))
        XCTAssertTrue(ready.serviceOK)
        XCTAssertEqual(ready.version, "1.0.0")
        XCTAssertThrowsError(try JSONDecoder().decode(
            UpReadinessReceipt.self,
            from: Data(#"{"ok":true,"start_submitted":true}"#.utf8)
        ))

        // Pair tickets
        for file in ["pair-ok-direct.json", "pair-ok-tailcat.json"] {
            let ticket = try JSONDecoder().decode(PairingTicketReceipt.self, from: loadContractData(file))
            XCTAssertTrue(ticket.ok)
            XCTAssertTrue(ticket.hasExplicitNetwork)
            XCTAssertTrue(ticket.asPairingInfo.hasTicket)
        }
    }

    // MARK: - Streaming stderr NDJSON progress, out-of-order slow assistant, cancel safety

    func testStreamingPreflightProgressOutOfOrderAndCancelSafety() async throws {
        let ndjson = String(decoding: try loadContractData("preflight-progress-slow-assistant.ndjson"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertEqual(ndjson.count, 36)

        // Unit accumulator: malformed noise ignored, fast assistant completes before slow assistant,
        // cancel does NOT overwrite terminal state.
        let acc = OnboardingProgressAccumulator(generation: 1)
        XCTAssertFalse(acc.applyLine("not-json noisy stderr", generation: 1))
        for line in ndjson.prefix(26) {
            XCTAssertTrue(acc.applyLine(line, generation: 1))
        }
        let mid = acc.snapshot()
        XCTAssertNil(mid.report)
        let midByID = Dictionary(uniqueKeysWithValues: mid.checks.map { ($0.id, $0) })
        XCTAssertEqual(midByID[.assistantCodex]?.state, .ok)
        XCTAssertEqual(midByID[.assistantAny]?.state, .ok)
        XCTAssertEqual(midByID[.assistantClaude]?.state, .checking)

        for line in ndjson.dropFirst(26) {
            XCTAssertTrue(acc.applyLine(line, generation: 1))
        }
        let finalReport = try JSONDecoder().decode(
            OnboardingPreflightReport.self,
            from: loadContractData("preflight-codex-chatgpt-app.json")
        )
        XCTAssertTrue(acc.complete(with: finalReport, generation: 1))
        acc.cancel(generation: 1)
        XCTAssertFalse(acc.applyLine(ndjson[0], generation: 1))
        let afterTerminal = acc.snapshot()
        XCTAssertEqual(afterTerminal.report, finalReport)

        // Cancelled generation rejects late updates and completion
        let acc2 = OnboardingProgressAccumulator(generation: 2)
        XCTAssertTrue(acc2.applyLine(ndjson[0], generation: 2))
        acc2.cancel(generation: 2)
        XCTAssertFalse(acc2.applyLine(ndjson[18], generation: 2))
        XCTAssertFalse(acc2.complete(with: finalReport, generation: 2))

        // Live subprocess streaming through AgentCommandClient + ProcessExecutor:
        // Verify fast progress lines arrive BEFORE slow assistant finishes, and noise lines are ignored.
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "mimi-ui1-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ndjsonURL = Self.contractsDirectory().appendingPathComponent("preflight-progress-slow-assistant.ndjson")
        let reportURL = Self.contractsDirectory().appendingPathComponent("preflight-codex-chatgpt-app.json")
        let scriptURL = tempDir.appending(path: "fake-agentd.sh")
        let script = """
        #!/bin/sh
        echo "noisy non-json stderr line" >&2
        head -n 26 "\(ndjsonURL.path)" >&2
        sleep 0.25
        tail -n +27 "\(ndjsonURL.path)" >&2
        cat "\(reportURL.path)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let recorder = ProgressRecorder()
        let client = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: scriptURL)
        let streamedReport = try await client.preflight(OnboardingPreflightOptions(stage: .pair, progressJSON: true)) { check in
            recorder.record(check)
        }
        XCTAssertEqual(streamedReport, finalReport)
        let events = recorder.events()
        XCTAssertEqual(events.count, 36)
        let codexOKIndex = try XCTUnwrap(events.firstIndex { $0.id == .assistantCodex && $0.state == .ok })
        let anyOKIndex = try XCTUnwrap(events.firstIndex { $0.id == .assistantAny && $0.state == .ok })
        let claudeFinalIndex = try XCTUnwrap(events.firstIndex { $0.id == .assistantClaude && $0.state == .actionNeeded })
        XCTAssertLessThan(codexOKIndex, claudeFinalIndex)
        XCTAssertLessThan(anyOKIndex, claudeFinalIndex)
    }

    // MARK: - Live AgentCommandClient stdout-first error, no-ticket setup, old-host fallback

    func testLiveAgentCommandClientDecodesStdoutErrorAndNoTicketSetupAndLegacyHost() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "mimi-ui1-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Setup no-ticket success
        let setupOKFixture = Self.contractsDirectory().appendingPathComponent("setup-ok-pairing-deferred.json")
        let setupScript = tempDir.appending(path: "setup-ok.sh")
        try "#!/bin/sh\ncat \"\(setupOKFixture.path)\"\n".write(to: setupScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setupScript.path)

        let setupClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: setupScript)
        let pairing = try await setupClient.setup(tempDir)
        XCTAssertNil(pairing.pairURL)
        XCTAssertFalse(pairing.hasTicket)

        // 2. Exit 1 with stdout v1 error envelope (and noisy stderr)
        let errFixture = Self.contractsDirectory().appendingPathComponent("setup-error-config-invalid.json")
        let errScript = tempDir.appending(path: "setup-err.sh")
        try "#!/bin/sh\ncat \"\(errFixture.path)\"\necho \"raw stderr\" >&2\nexit 1\n".write(to: errScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: errScript.path)

        let errClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: errScript)
        do {
            _ = try await errClient.setupNoPair(tempDir, .init())
            XCTFail("Expected structured CLI error")
        } catch let error as AgentClientError {
            let diag = try XCTUnwrap(error.onboardingDiagnostic)
            XCTAssertTrue(diag.isTrusted)
            XCTAssertEqual(diag.code, "config_invalid")
            XCTAssertEqual(diag.primaryAction, .openSettings(.hostRecovery))
            XCTAssertEqual(diag.configPath, "/fixture/config/config.json")
            XCTAssertEqual(diag.recoveryPath, "/fixture/config/config.previous.json")
        }

        // 3. Tampered rotates_token:true on stdout => zero execution (primaryAction == nil)
        let tamperedScript = tempDir.appending(path: "tampered.sh")
        let tamperedBody = #"{"ok":false,"error":{"code":"config_permissions_unsafe","step":"config_store","message":"fix","fix":{"kind":"run_fix","action":"doctor_fix","rotates_token":true}}}"#
        try "#!/bin/sh\nprintf '%s\\n' '\(tamperedBody)'\nexit 1\n".write(to: tamperedScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tamperedScript.path)

        let tamperedClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: tamperedScript)
        do {
            _ = try await tamperedClient.setupNoPair(tempDir, .init())
            XCTFail("Expected error")
        } catch let error as AgentClientError {
            let diag = try XCTUnwrap(error.onboardingDiagnostic)
            XCTAssertFalse(diag.isTrusted)
            XCTAssertNil(diag.primaryAction)
        }

        // 4. Old-host compatibility: unknown preflight subcommand maps to desktop update link
        let legacyScript = tempDir.appending(path: "legacy.sh")
        try "#!/bin/sh\necho 'Error: unknown command \"preflight\" for \"agentd\"' >&2\nexit 1\n".write(to: legacyScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyScript.path)

        let legacyClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: legacyScript)
        do {
            _ = try await legacyClient.preflight(.init(), nil)
            XCTFail("Expected legacy host error")
        } catch let error as AgentClientError {
            let diag = try XCTUnwrap(error.onboardingDiagnostic)
            XCTAssertTrue(diag.isLegacyHost)
            XCTAssertEqual(diag.primaryAction, .openURL(.desktop))
        }
    }

    @MainActor
    func testHostStoreCompleteSetupAcceptsNoTicketPairingInfo() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "mimi-ui1-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let readyStatus = AgentStatus(
            processOK: true, serviceOK: true, processError: nil, serviceError: nil,
            version: "1.0.0", endpoint: "http://127.0.0.1:8787",
            configPath: "/fixture/config/config.json", projects: 0, doctorOK: true,
            doctor: AgentDoctorResults(ok: true, version: "1.0.0", listen: "127.0.0.1:8787", checks: []),
            pairExpires: nil
        )
        let noTicket = try JSONDecoder().decode(
            SetupReceipt.self,
            from: loadContractData("setup-ok-no-assistant.json")
        ).asPairingInfo

        let agent = AgentCommandClient(
            configExists: { false },
            setup: { _ in noTicket },
            status: { readyStatus },
            readiness: { readyStatus },
            statusAt: { _ in readyStatus },
            doctor: { _ in DoctorFixResults(fixes: [], results: readyStatus.doctor) },
            configureClaude: { pref, _ in
                ClaudeConfigurationResult(
                    enabled: false, available: false, preference: pref,
                    previousEnabled: false, previousPreference: .disabled,
                    changed: false, restartRequired: false, reason: "disabled", message: ""
                )
            },
            setLANAccess: { _ in NetworkConfigurationResult(lanEnabled: false, changed: false, restartRequired: false) },
            pair: { _ in noTicket },
            version: { "1.0.0" }
        )
        let services = ServiceManagementClient(
            agentStatus: { .enabled },
            agentConfigurationError: { nil },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: {},
            registerAgent: {},
            unregisterAgent: {},
            agentLaunchFailure: { nil },
            mainAppStatus: { .enabled },
            registerMainApp: {},
            unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let store = HostStore(
            agent: agent,
            services: services,
            homebrew: HomebrewServiceClient(isLoaded: { false }, installedAgentBinary: { nil }, start: {}, stop: {}),
            health: HealthClient(check: { _ in true }, checkDirect: { _ in true }),
            logs: AgentLogClient(recentLines: { _ in [] }, exportLines: { [] })
        )
        await store.completeSetup(workspaceRoot: tempDir)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.pairing, "No-ticket setup must not leave an empty PairingInfo")
        XCTAssertNil(store.lastError)
    }

    // MARK: - Helpers

    private func applyReportPatch(fixture: String, patches: [[String: Any]]) throws -> Data {
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: loadContractData(fixture)) as? [String: Any])
        for patch in patches {
            let op = try XCTUnwrap(patch["op"] as? String)
            let path = try XCTUnwrap(patch["path"] as? String)
            let key = String(path.dropFirst())
            if key.hasPrefix("checks/") {
                var items = try XCTUnwrap(doc["checks"] as? [Any])
                let suffix = String(key.dropFirst("checks/".count))
                if op == "add", suffix == "-", let val = patch["value"] {
                    items.append(val)
                    doc["checks"] = items
                } else if op == "remove", let index = Int(suffix) {
                    items.remove(at: index)
                    doc["checks"] = items
                } else {
                    XCTFail("Unsupported checks patch \(patch)")
                }
            } else {
                switch op {
                case "add", "replace":
                    doc[key] = patch["value"]
                case "remove":
                    doc.removeValue(forKey: key)
                default:
                    XCTFail("Unsupported patch op \(op)")
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: doc)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OnboardingCheck] = []

    func record(_ check: OnboardingCheck) {
        lock.lock()
        items.append(check)
        lock.unlock()
    }

    func events() -> [OnboardingCheck] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

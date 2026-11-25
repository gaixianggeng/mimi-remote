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

        // P2-1: Legacy ticket-shaped setup output with explicit ok:false MUST be rejected
        let legacyOkFalse = Data(#"{"ok":false,"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T00:05:00Z"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SetupReceipt.self, from: legacyOkFalse))

        // P2-2: Strict RFC3339 / UTC ticket expiry validation on PairingTicketReceipt & SetupReceipt
        let v1NanoTicket = Data(#"{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=ok","pair_expires_at":"2030-01-01T00:05:00.123456789Z","network":"tailscale"}"#.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(PairingTicketReceipt.self, from: v1NanoTicket))

        let invalidTicketPayloads: [String] = [
            // Non-UTC offset rejected when ok:true (v1 ticket requires Z)
            #"{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T08:05:00+08:00","network":"tailscale"}"#,
            // Non-RFC3339 date-only or arbitrary string rejected
            #"{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01","network":"tailscale"}"#,
            #"{"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"not-a-date"}"#,
            // Impossible calendar date rejected
            #"{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-02-30T00:05:00Z","network":"tailscale"}"#,
            // Bare scheme without query rejected
            #"{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?","pair_expires_at":"2030-01-01T00:05:00Z","network":"tailscale"}"#,
        ]
        for raw in invalidTicketPayloads {
            XCTAssertThrowsError(try JSONDecoder().decode(PairingTicketReceipt.self, from: Data(raw.utf8)), "Must reject \(raw)")
        }

        // Legacy ticket (no ok key) still accepts valid RFC3339 offset
        let legacyOffsetTicket = Data(#"{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T08:05:00+08:00"}"#.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(PairingTicketReceipt.self, from: legacyOffsetTicket))
        XCTAssertNoThrow(try JSONDecoder().decode(SetupReceipt.self, from: legacyOffsetTicket))

        // Legacy setup with non-RFC3339 expiry rejected; v1 setup with non-UTC expiry rejected
        XCTAssertThrowsError(try JSONDecoder().decode(
            SetupReceipt.self,
            from: Data(#"{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"tomorrow"}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SetupReceipt.self,
            from: Data(#"{"ok":true,"configured":true,"created":true,"config_path":"/c","scan_root":"/s","browse_root":"/s","endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T08:05:00+08:00"}"#.utf8)
        ))
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

    func testProductionSetupUsesWorkspaceBrowseRootAndSanitizesUnknownErrorsAndChecksStageAndDoctorFix() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "mimi-ui1-fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. P1-4: Production HostStore setup path must pass workspaceRoot (NEVER homeDirectory) as --browse-root
        let argsFile = tempDir.appending(path: "captured-args.txt")
        let setupOKFixture = Self.contractsDirectory().appendingPathComponent("setup-ok-pairing-deferred.json")
        let captureSetupScript = tempDir.appending(path: "capture-setup.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsFile.path)"
        cat "\(setupOKFixture.path)"
        """.write(to: captureSetupScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureSetupScript.path)

        let workspaceDir = tempDir.appending(path: "my-project")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let setupClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: captureSetupScript)
        _ = try await setupClient.setup(workspaceDir)
        let capturedArgs = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let browseIdx = try XCTUnwrap(capturedArgs.firstIndex(of: "--browse-root"))
        XCTAssertEqual(capturedArgs[browseIdx + 1], workspaceDir.path)
        XCTAssertNotEqual(capturedArgs[browseIdx + 1], FileManager.default.homeDirectoryForCurrentUser.path)

        // 2. P1-1: Unrecognized stderr MUST NOT leak raw stderr, bearer, pair_url, private paths, or unmarked secrets
        let leakyScript = tempDir.appending(path: "leaky-err.sh")
        try """
        #!/bin/sh
        echo "fatal: Bearer topsecretbearer999 mimiremote://pair?pair_sig=leak123 /Users/alice/private/config.json eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456 UnmarkedCred9876543210ABCDEF $(printf 'x%.0s' $(seq 1 300))" >&2
        exit 2
        """.write(to: leakyScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leakyScript.path)

        let leakyClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: leakyScript)
        do {
            _ = try await leakyClient.setupNoPair(workspaceDir, .init())
            XCTFail("Expected failure")
        } catch let error as AgentClientError {
            let userFacing = error.localizedDescription
            let diag = try XCTUnwrap(error.onboardingDiagnostic)
            XCTAssertFalse(diag.isTrusted)
            XCTAssertNil(diag.primaryAction)
            XCTAssertTrue(userFacing.contains("退出码 2"))
            for forbidden in ["topsecretbearer999", "mimiremote://", "pair_sig", "/Users/alice", "eyJhbGci", "UnmarkedCred9876543210ABCDEF", "fatal:"] {
                XCTAssertFalse(userFacing.contains(forbidden), "User-facing error leaked \(forbidden)")
            }
            let sanitized = try XCTUnwrap(diag.sanitizedDiagnostic)
            XCTAssertLessThanOrEqual(sanitized.count, 180)
            for forbidden in ["topsecretbearer999", "mimiremote://", "pair_sig", "/Users/alice", "eyJhbGci", "UnmarkedCred9876543210ABCDEF"] {
                XCTAssertFalse(sanitized.contains(forbidden), "Sanitized diagnostic leaked \(forbidden)")
            }
        }

        // 3. P1-2: Fresh setup CLI error must NOT trust restart_service (least-privileged configured=false default)
        let restartDuringSetupScript = tempDir.appending(path: "restart-in-setup.sh")
        let restartBody = #"{"ok":false,"error":{"code":"service_not_running","step":"service_daemon","message":"未运行","fix":{"kind":"run_fix","action":"restart_service"}}}"#
        try "#!/bin/sh\nprintf '%s\\n' '\(restartBody)'\nexit 1\n".write(to: restartDuringSetupScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restartDuringSetupScript.path)
        let freshClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: restartDuringSetupScript)
        do {
            _ = try await freshClient.setupNoPair(workspaceDir, .init())
            XCTFail("Expected error")
        } catch let error as AgentClientError {
            let diag = try XCTUnwrap(error.onboardingDiagnostic)
            XCTAssertFalse(diag.isTrusted)
            XCTAssertNil(diag.primaryAction)
        }

        // 4. P1-3: A valid ok:true setup report MUST NOT satisfy a pair preflight, AND invalid progress rows MUST NOT be published
        let setupReportData = try applyReportPatch(
            fixture: "preflight-all-green.json",
            patches: [
                ["op": "replace", "path": "/stage", "value": "setup"],
                ["op": "replace", "path": "/configured", "value": false],
                ["op": "replace", "path": "/workspace_confirmed", "value": false],
                ["op": "replace", "path": "/recommended_next", "value": "config_store"],
            ]
        )
        let setupReportURL = tempDir.appending(path: "setup-report.json")
        try setupReportData.write(to: setupReportURL)
        let wrongStageScript = tempDir.appending(path: "wrong-stage-preflight.sh")
        let badProgress1 = #"{"id":"assistant_claude","group":"assistant","state":"action_needed","title":"Claude","detail":"请登录","blocking":false,"enabled":true,"available":false,"candidates":[{"path":"/fixture/bin/claude","outcome":"selected"}],"code":"claude_signed_out","fix":{"kind":"open_url","url":"https://learn.chatgpt.com/docs/codex/cli"}}"#
        let badProgress2 = #"{"id":"service_daemon","group":"service","state":"action_needed","title":"后台服务","detail":"未运行","blocking":true,"code":"service_not_running","fix":{"kind":"run_fix","action":"restart_service"}}"#
        let goodProgress = #"{"id":"config_store","group":"workspace","state":"checking","title":"配置文件","detail":"正在检查。","blocking":false}"#
        try """
        #!/bin/sh
        printf '%s\\n' '\(badProgress1)' >&2
        printf '%s\\n' '\(badProgress2)' >&2
        printf '%s\\n' '\(goodProgress)' >&2
        cat "\(setupReportURL.path)"
        """.write(to: wrongStageScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrongStageScript.path)

        let recorder = ProgressRecorder()
        let wrongStageClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: wrongStageScript)
        do {
            _ = try await wrongStageClient.preflight(OnboardingPreflightOptions(stage: .pair, progressJSON: true)) { check in
                recorder.record(check)
            }
            XCTFail("Setup report must NOT satisfy a pair preflight")
        } catch let error as AgentClientError {
            if case .invalidResponse(let detail) = error {
                XCTAssertTrue(detail.contains("stage"), "Expected stage mismatch error, got \(detail)")
            } else {
                XCTFail("Expected invalidResponse for stage mismatch, got \(error)")
            }
        }
        let published = recorder.events()
        XCTAssertEqual(published.map(\.id), [.configStore], "Invalid code/fix progress rows must never be published")

        // 5. P2-3: macOS doctor --fix preserves typed stdout error envelopes AND still decodes DoctorFixResults on exit 1
        let errFixture = Self.contractsDirectory().appendingPathComponent("setup-error-config-invalid.json")
        let doctorErrScript = tempDir.appending(path: "doctor-fix-err.sh")
        try "#!/bin/sh\ncat \"\(errFixture.path)\"\nexit 1\n".write(to: doctorErrScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: doctorErrScript.path)

        let doctorErrClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: doctorErrScript)
        do {
            _ = try await doctorErrClient.doctor(true)
            XCTFail("Expected typed onboarding error from doctor --fix")
        } catch let error as AgentClientError {
            let diag = try XCTUnwrap(error.onboardingDiagnostic)
            XCTAssertTrue(diag.isTrusted)
            XCTAssertEqual(diag.code, "config_invalid")
            XCTAssertEqual(diag.primaryAction, .openSettings(.hostRecovery))
            XCTAssertEqual(diag.configPath, "/fixture/config/config.json")
            XCTAssertEqual(diag.recoveryPath, "/fixture/config/config.previous.json")
        }

        let doctorLegacyScript = tempDir.appending(path: "doctor-fix-legacy.sh")
        let doctorLegacyBody = #"{"fixes":["tightened permissions"],"results":{"ok":false,"version":"1.0.0","listen":"127.0.0.1:8787","checks":[]},"restart_required":false}"#
        try "#!/bin/sh\nprintf '%s\\n' '\(doctorLegacyBody)'\nexit 1\n".write(to: doctorLegacyScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: doctorLegacyScript.path)
        let doctorLegacyClient = AgentCommandClient.live(executor: ProcessExecutor(), binaryOverride: doctorLegacyScript)
        let fixResults = try await doctorLegacyClient.doctor(true)
        XCTAssertEqual(fixResults.fixes, ["tightened permissions"])
        XCTAssertFalse(fixResults.results.ok)
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
                } else {
                    let parts = suffix.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let index = Int(parts[0]), index >= 0, index < items.count else {
                        XCTFail("Invalid checks index in patch \(patch)")
                        continue
                    }
                    if parts.count == 1 {
                        switch op {
                        case "replace":
                            items[index] = try XCTUnwrap(patch["value"])
                            doc["checks"] = items
                        case "remove":
                            items.remove(at: index)
                            doc["checks"] = items
                        default:
                            XCTFail("Unsupported checks patch \(patch)")
                        }
                    } else {
                        let field = String(parts[1])
                        var rowObj = try XCTUnwrap(items[index] as? [String: Any])
                        switch op {
                        case "add", "replace":
                            rowObj[field] = patch["value"]
                        case "remove":
                            rowObj.removeValue(forKey: field)
                        default:
                            XCTFail("Unsupported checks field patch \(patch)")
                        }
                        items[index] = rowObj
                        doc["checks"] = items
                    }
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

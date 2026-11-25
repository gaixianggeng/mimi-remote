import Foundation
import XCTest
@testable import MimiRemote

final class PairingErrorMapperTests: XCTestCase {
    private static func contractsDirectory() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("contracts/host-cli")
    }

    private func loadContractData(_ filename: String) throws -> Data {
        try Data(contentsOf: Self.contractsDirectory().appendingPathComponent(filename))
    }

    func testApplicableIOSCodesMatchSharedRegistrySetEquality() throws {
        struct Manifest: Decodable {
            struct CodeEntry: Decodable {
                let code: String
                let surfaces: [String]
            }
            struct HTTPConfig: Decodable {
                let mediaType: String
                let vary: String
                let paths: [String]
            }
            let schema: String
            let urls: [String: String]
            let consumersBySurface: [String: [String]]
            let http: HTTPConfig
            let wireCodes: [CodeEntry]
            let uiLocalCodes: [CodeEntry]
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(Manifest.self, from: loadContractData("onboarding-codes-v1.json"))

        XCTAssertEqual(manifest.schema, "mimi.onboarding.codes/v1")
        XCTAssertEqual(PairingErrorMapper.acceptMediaType, manifest.http.mediaType)
        XCTAssertEqual(PairingErrorMapper.expectedVaryHeaderValue, manifest.http.vary)
        XCTAssertEqual(PairingErrorMapper.negotiatedPaths, manifest.http.paths)
        XCTAssertGreaterThan(manifest.wireCodes.count, 0)
        XCTAssertGreaterThan(manifest.uiLocalCodes.count, 0)

        let iosSurfaces = Set(manifest.consumersBySurface.compactMap { surface, consumers in
            consumers.contains("ios") ? surface : nil
        })
        XCTAssertTrue(iosSurfaces.contains("http"))
        XCTAssertTrue(iosSurfaces.contains("ui_local"))

        let expectedHTTPWire = Set(
            manifest.wireCodes
                .filter { entry in entry.surfaces.contains("http") }
                .map(\.code)
        )
        let expectedLocal = Set(manifest.uiLocalCodes.map(\.code))
        XCTAssertGreaterThan(expectedHTTPWire.count, 0)
        XCTAssertEqual(PairingErrorMapper.httpWireCodes, expectedHTTPWire)
        XCTAssertEqual(PairingErrorMapper.uiLocalCodes, expectedLocal)
        XCTAssertTrue(PairingErrorMapper.httpWireCodes.isDisjoint(with: PairingErrorMapper.uiLocalCodes))

        // URL allowlist exact match
        let iosURLs = Dictionary(uniqueKeysWithValues: PairingOnboardingFixURL.allCases.map { ($0.key, $0.rawValue) })
        XCTAssertEqual(iosURLs, manifest.urls)

        for entry in PairingErrorMapper.catalogEntries {
            XCTAssertNotEqual(entry.messageZH, entry.messageKey, "Code \(entry.code) missing zh-Hans catalog entry")
            XCTAssertTrue(
                entry.messageZH.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "Code \(entry.code) must contain Chinese copy"
            )
            XCTAssertNotEqual(entry.messageEN, entry.messageKey, "Code \(entry.code) missing en catalog entry")
            XCTAssertFalse(
                entry.messageEN.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "Code \(entry.code) English copy must not contain Chinese text"
            )
        }
    }

    func testAllApplicableHTTPAndUILocalErrorCasesFromContract() throws {
        let raw = try loadContractData("onboarding-error-cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 0)

        var httpCount = 0
        var uiLocalCount = 0
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            let valid = try XCTUnwrap(item["valid"] as? Bool)
            let rawCtx = try XCTUnwrap(item["context"] as? [String: Any])
            let surface = try XCTUnwrap(rawCtx["surface"] as? String)

            if surface == "http" {
                httpCount += 1
                let payloadObj = try XCTUnwrap(item["payload"] as? [String: Any], id)
                let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)
                let configured = rawCtx["configured"] as? Bool
                let mapped = PairingErrorMapper.mapHTTPErrorEnvelope(data: payloadData, configured: configured)
                XCTAssertEqual(mapped.isTrusted, valid, "HTTP case \(id) expected trusted=\(valid)")
                XCTAssertTrue(mapped.preservesSavedProfiles, id)
                if valid {
                    XCTAssertNotEqual(mapped.action, .none, id)
                } else {
                    XCTAssertEqual(mapped.action, .none, "Invalid HTTP case \(id) must yield zero execution")
                    XCTAssertNil(mapped.wireFix, id)
                }
            } else if surface == "ui_local" {
                uiLocalCount += 1
                let payloadObj = try XCTUnwrap(item["payload"] as? [String: Any], id)
                let errObj = try XCTUnwrap(payloadObj["error"] as? [String: Any], id)
                let code = try XCTUnwrap(errObj["code"] as? String, id)
                let step = (errObj["step"] as? String).flatMap(PairingOnboardingStep.init(rawValue:))
                let local = PairingErrorMapper.synthesizeLocal(code: code, step: step)
                XCTAssertTrue(local.isTrusted, id)
                XCTAssertNotEqual(local.action, .none, id)

                // UI-local codes MUST be rejected if sent over HTTP wire
                let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)
                let overWire = PairingErrorMapper.mapHTTPErrorEnvelope(data: payloadData)
                XCTAssertFalse(overWire.isTrusted, "UI-local code \(code) must be rejected on HTTP wire")
                XCTAssertEqual(overWire.action, .none, id)
            }
        }
        XCTAssertGreaterThan(httpCount, 0)
        XCTAssertGreaterThan(uiLocalCount, 0)
    }

    func testStandaloneFixturesNegativeTuplesAdditiveFieldsAndDateTimeGuidance() throws {
        // Standalone pair-error-expired.json fixture
        let expired = PairingErrorMapper.mapHTTPErrorEnvelope(data: try loadContractData("pair-error-expired.json"))
        XCTAssertTrue(expired.isTrusted)
        XCTAssertEqual(expired.code, "pair_ticket_expired")
        XCTAssertEqual(expired.action, .retry)
        XCTAssertTrue(expired.preservesSavedProfiles)
        XCTAssertFalse(expired.message.contains("10 分钟"))

        // Clock skew uses localized text instructions, NEVER App-Prefs:
        let clockSkewData = Data(#"{"ok":false,"error":{"code":"pair_clock_skew","step":"network_any","message":"时间不一致","fix":{"kind":"open_settings","target":"date_time"}}}"#.utf8)
        let clockSkew = PairingErrorMapper.mapHTTPErrorEnvelope(data: clockSkewData)
        XCTAssertTrue(clockSkew.isTrusted)
        if case .showDateTimeGuidanceAndRetry(let instructions) = clockSkew.action {
            XCTAssertEqual(instructions, PairingErrorMapper.dateTimeInstructions)
            XCTAssertTrue(
                instructions.contains("日期与时间") || instructions.contains("Date & Time"),
                "Unexpected date_time instructions: \(instructions)"
            )
            XCTAssertFalse(instructions.contains("App-Prefs:"))
            XCTAssertTrue(
                L10n.text("ui.pairing_onboarding_date_time_instructions", language: .simplifiedChinese).contains("日期与时间")
            )
            XCTAssertTrue(
                L10n.text("ui.pairing_onboarding_date_time_instructions", language: .english).contains("Date & Time")
            )
        } else {
            XCTFail("Expected date_time text guidance, got \(clockSkew.action)")
        }

        // Workspace confirmation & token mismatch become desktop guidance + rescan (never execute host fix on iOS)
        let workspaceData = Data(#"{"ok":false,"error":{"code":"workspace_confirmation_required","step":"workspace_root","message":"确认目录","fix":{"kind":"choose_path","target":"workspace_root"}}}"#.utf8)
        let workspace = PairingErrorMapper.mapHTTPErrorEnvelope(data: workspaceData)
        XCTAssertTrue(workspace.isTrusted)
        if case .desktopGuidanceAndRescan = workspace.action {
            // expected
        } else {
            XCTFail("Expected desktopGuidanceAndRescan, got \(workspace.action)")
        }

        let tokenMismatchData = Data(#"{"ok":false,"error":{"code":"pair_token_mismatch","step":"service_daemon","message":"身份未同步","fix":{"kind":"run_fix","action":"restart_service"}}}"#.utf8)
        let tokenMismatch = PairingErrorMapper.mapHTTPErrorEnvelope(data: tokenMismatchData, configured: true)
        XCTAssertTrue(tokenMismatch.isTrusted)
        XCTAssertTrue(tokenMismatch.preservesSavedProfiles)
        if case .desktopGuidanceAndRescan = tokenMismatch.action {
            // expected
        } else {
            XCTFail("Expected desktopGuidanceAndRescan, got \(tokenMismatch.action)")
        }

        // Unverified or unconfigured context must NOT grant trusted restart_service for pair_token_mismatch
        let unverifiedTokenMismatch = PairingErrorMapper.mapHTTPErrorEnvelope(data: tokenMismatchData)
        XCTAssertFalse(unverifiedTokenMismatch.isTrusted)
        XCTAssertEqual(unverifiedTokenMismatch.action, .none)
        XCTAssertNil(unverifiedTokenMismatch.wireFix)
        let freshTokenMismatch = PairingErrorMapper.mapHTTPErrorEnvelope(data: tokenMismatchData, configured: false)
        XCTAssertFalse(freshTokenMismatch.isTrusted)
        XCTAssertEqual(freshTokenMismatch.action, .none)

        // Nested forbidden public field must be rejected
        let nestedPrivate = Data(#"{"ok":false,"extra":{"token":"secret-bearer"},"error":{"code":"pair_ticket_expired","step":"network_any","message":"过期","fix":{"kind":"retry"}}}"#.utf8)
        let nestedMapped = PairingErrorMapper.mapHTTPErrorEnvelope(data: nestedPrivate)
        XCTAssertFalse(nestedMapped.isTrusted)
        XCTAssertEqual(nestedMapped.action, .none)

        // Harmless additive fields accepted
        let additiveData = Data(#"{"ok":false,"future_top":true,"error":{"code":"pair_ticket_expired","step":"network_any","message":"过期","fix":{"kind":"retry"},"future_hint":"新增提示"}}"#.utf8)
        let additive = PairingErrorMapper.mapHTTPErrorEnvelope(data: additiveData)
        XCTAssertTrue(additive.isTrusted)
        XCTAssertEqual(additive.action, .retry)

        // Negative cases: rotates_token:true, unknown code, unknown URL, mismatched step, private HTTP field, non-HTTP code
        let rejectedPayloads: [String] = [
            #"{"ok":false,"error":{"code":"pair_token_mismatch","step":"service_daemon","message":"x","fix":{"kind":"run_fix","action":"restart_service","rotates_token":true}}}"#,
            #"{"ok":false,"error":{"code":"future_unknown_code","step":"network_any","message":"x","fix":{"kind":"retry"}}}"#,
            #"{"ok":false,"error":{"code":"no_enabled_assistant","step":"assistant_any","message":"x","fix":{"kind":"open_url","url":"https://evil.example.invalid/"}}}"#,
            #"{"ok":false,"error":{"code":"pair_ticket_expired","step":"service_daemon","message":"x","fix":{"kind":"retry"}}}"#,
            #"{"ok":false,"error":{"code":"pair_ticket_expired","step":"network_any","message":"x","fix":{"kind":"retry"},"recovery_path":"/fixture/config/recovery.json"}}"#,
            #"{"ok":false,"error":{"code":"config_invalid","step":"config_store","message":"x","fix":{"kind":"open_settings","target":"host_recovery"}}}"#,
            #"{"ok":false,"error":{"code":"command_timeout","step":"service_daemon","message":"x","fix":{"kind":"retry"}}}"#,
            #"{"ok":false,"error":{"code":"pair_ticket_expired","step":"network_any","message":"x"}}"#,
        ]
        for raw in rejectedPayloads {
            let mapped = PairingErrorMapper.mapHTTPErrorEnvelope(data: Data(raw.utf8))
            XCTAssertFalse(mapped.isTrusted, "Payload must be rejected: \(raw)")
            XCTAssertEqual(mapped.action, .none, "Rejected payload must yield zero execution: \(raw)")
            XCTAssertTrue(mapped.preservesSavedProfiles)
        }
    }

    func testOldHostLegacyHTTPErrorFallbackMapsKnownLegacyCodes() {
        let legacyGrant = PairingErrorMapper.mapHTTPResponse(
            data: Data(#"{"error":"grant needed","code":"tailcat_managed_grant_required"}"#.utf8),
            statusCode: 409
        )
        XCTAssertTrue(legacyGrant.isTrusted)
        XCTAssertTrue(legacyGrant.isLegacyFallback)
        XCTAssertEqual(legacyGrant.code, "pair_managed_grant_conflict")
        XCTAssertEqual(legacyGrant.action, .retry)

        let legacyAgents = PairingErrorMapper.mapHTTPResponse(
            data: Data(#"{"error":"no agents","code":"tailcat_agents_disabled"}"#.utf8),
            statusCode: 503
        )
        XCTAssertEqual(legacyAgents.code, "no_enabled_assistant")
        XCTAssertEqual(legacyAgents.action, .openURL(.guide))

        let legacyBusy = PairingErrorMapper.mapHTTPResponse(
            data: Data(#"{"error":"busy","code":"tailcat_operation_in_progress"}"#.utf8),
            statusCode: 409
        )
        XCTAssertEqual(legacyBusy.code, "tailcat_busy")

        // 401 from old host preserves saved host profiles
        let legacy401 = PairingErrorMapper.mapHTTPResponse(
            data: Data(#"{"error":"expired ticket"}"#.utf8),
            statusCode: 401
        )
        XCTAssertTrue(legacy401.preservesSavedProfiles)
        XCTAssertEqual(legacy401.code, "pair_ticket_invalid")
        XCTAssertEqual(legacy401.action, .retry)
    }

    func testUnsupportedMajorVersionRejectedEvenWithV1ShapedBody() throws {
        let v1ExpiredBody = try loadContractData("pair-error-expired.json")

        // Server explicitly declares v2 media type — must NOT grant a trusted action even for a v1-shaped body or 401.
        for mediaType in [
            "application/vnd.mimi.onboarding.v2+json",
            "application/vnd.mimi.onboarding.v2+json; charset=utf-8",
            "APPLICATION/VND.MIMI.ONBOARDING.V99+JSON",
        ] {
            let mapped = PairingErrorMapper.mapHTTPResponse(
                data: v1ExpiredBody,
                statusCode: 401,
                contentType: mediaType,
                configured: true
            )
            XCTAssertFalse(mapped.isTrusted, "v2 media type \(mediaType) must not be trusted")
            XCTAssertEqual(mapped.action, .none, "v2 media type \(mediaType) must yield zero execution")
            XCTAssertNil(mapped.wireFix, mediaType)
            XCTAssertFalse(mapped.isLegacyFallback, mediaType)
            XCTAssertTrue(mapped.preservesSavedProfiles, mediaType)
        }

        // Valid v1 media type with charset parameter IS accepted.
        let v1WithCharset = PairingErrorMapper.mapHTTPResponse(
            data: v1ExpiredBody,
            statusCode: 401,
            contentType: "application/vnd.mimi.onboarding.v1+json; charset=utf-8"
        )
        XCTAssertTrue(v1WithCharset.isTrusted)
        XCTAssertEqual(v1WithCharset.code, "pair_ticket_expired")
        XCTAssertEqual(v1WithCharset.action, .retry)

        // Explicit v2 schema field in body is also rejected even without media type.
        let v2SchemaBody = Data(#"{"ok":false,"schema":"mimi.onboarding.error/v2","error":{"code":"pair_ticket_expired","step":"network_any","message":"过期","fix":{"kind":"retry"}}}"#.utf8)
        let schemaMapped = PairingErrorMapper.mapHTTPResponse(
            data: v2SchemaBody,
            statusCode: 401,
            contentType: "application/json"
        )
        XCTAssertFalse(schemaMapped.isTrusted)
        XCTAssertEqual(schemaMapped.action, .none)
        let error = try XCTUnwrap(JSONSerialization.jsonObject(with: v1ExpiredBody) as? [String: Any])
        for declared in ["other/v2", "mimi.onboarding.error/v2/v1"] {
            var body = error
            body["schema"] = declared
            let data = try JSONSerialization.data(withJSONObject: body)
            XCTAssertEqual(PairingErrorMapper.mapHTTPErrorEnvelope(data: data).action, .none)
        }
    }

    func testMalformedAndUnknownResponsesCannotAcquireLegacyActions() {
        let responses = [
            #"{"code":"tailcat_agents_disabled","error":{"step":"assistant_any"}}"#,
            #"{"ok":true,"error":"invalid","code":"tailcat_agents_disabled"}"#,
            #"{"error":"invalid","code":"future_ticket_error"}"#,
            #"{"error":"invalid","code":"pair_token_mismatch"}"#,
            #"{"error":"invalid","code":"tailcat_agents_disabled","fix":{"rotates_token":true}}"#,
            #"{"error":"invalid","code":null}"#,
            #"{}"#,
        ]
        for response in responses {
            let mapped = PairingErrorMapper.mapHTTPResponse(
                data: Data(response.utf8), statusCode: 401, contentType: "application/json"
            )
            XCTAssertFalse(mapped.isTrusted)
            XCTAssertNil(mapped.wireFix)
            XCTAssertEqual(mapped.action, .none)
            XCTAssertTrue(mapped.preservesSavedProfiles)
        }
        let unknown = Data(#"{"ok":false,"error":{"code":"private sample","step":"network_any","message":"x","fix":{"kind":"retry"}}}"#.utf8)
        XCTAssertNil(PairingErrorMapper.mapHTTPErrorEnvelope(data: unknown).code)
    }

    func testVaryAcceptNegotiatedPathsAndScannerFailureActions() {
        XCTAssertTrue(PairingErrorMapper.hasVaryAccept("Accept"))
        XCTAssertTrue(PairingErrorMapper.hasVaryAccept("Origin, accept"))
        XCTAssertTrue(PairingErrorMapper.hasVaryAccept("*"))
        XCTAssertFalse(PairingErrorMapper.hasVaryAccept("Origin"))
        XCTAssertFalse(PairingErrorMapper.hasVaryAccept(nil))

        for path in PairingErrorMapper.negotiatedPaths {
            XCTAssertTrue(PairingErrorMapper.isNegotiatedPath(path), path)
        }
        XCTAssertTrue(PairingErrorMapper.isNegotiatedPath("/api/tailcat/managed-pairing-operations/abc-123"))
        XCTAssertFalse(PairingErrorMapper.isNegotiatedPath("/api/tailcat/managed-pairing-operations/abc-123/rollback"))
        XCTAssertFalse(PairingErrorMapper.isNegotiatedPath("/api/version"))

        // Clock skew renders text guidance with zero App-Prefs: and manual rescan actions.
        let clockSkew = PairingErrorMapper.mapHTTPErrorEnvelope(
            data: Data(#"{"ok":false,"error":{"code":"pair_clock_skew","step":"network_any","message":"时钟偏差","fix":{"kind":"open_settings","target":"date_time"}}}"#.utf8)
        )
        let clockFailure = QRCodeScannerFailure.onboardingError(clockSkew)
        XCTAssertEqual(clockFailure.message, PairingErrorMapper.dateTimeInstructions)
        XCTAssertFalse(clockFailure.message.contains("App-Prefs:"))
        XCTAssertEqual(clockFailure.recoveryActions, [.retryScanning, .pasteLink, .manualConnection])
        XCTAssertTrue(PairingErrorMapper.isUserFacingMessage(clockFailure.message))

        // no_enabled_assistant offers the allowlisted GUIDE URL alongside rescan/paste.
        let noAssistant = PairingErrorMapper.mapHTTPErrorEnvelope(
            data: Data(#"{"ok":false,"error":{"code":"no_enabled_assistant","step":"assistant_any","message":"无助手","fix":{"kind":"open_url","url":"https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md"}}}"#.utf8)
        )
        let noAssistantFailure = QRCodeScannerFailure.onboardingError(noAssistant)
        XCTAssertEqual(noAssistantFailure.recoveryActions, [.openHelpURL(.guide), .retryScanning, .pasteLink])
        XCTAssertTrue(PairingErrorMapper.isUserFacingMessage(noAssistantFailure.message))

        // Confirmed entitlement failure opens managed connection; untrusted payloads offer zero automatic actions.
        let entitlement = PairingErrorMapper.mapHTTPErrorEnvelope(
            data: Data(#"{"ok":false,"error":{"code":"pair_managed_entitlement_required","step":"network_tailcat","message":"需要订阅","fix":{"kind":"open_settings","target":"managed_connection"}}}"#.utf8)
        )
        XCTAssertEqual(
            QRCodeScannerFailure.onboardingError(entitlement).recoveryActions,
            [.openManagedConnection, .retryScanning]
        )

        let untrusted = PairingErrorMapper.mapHTTPErrorEnvelope(
            data: Data(#"{"ok":false,"error":{"code":"pair_token_mismatch","step":"service_daemon","message":"x","fix":{"kind":"run_fix","action":"restart_service","rotates_token":true}}}"#.utf8)
        )
        XCTAssertFalse(untrusted.isTrusted)
        XCTAssertEqual(untrusted.action, .none)
        XCTAssertTrue(PairingErrorMapper.isUserFacingMessage(untrusted.userFacingMessage))
        XCTAssertEqual(
            QRCodeScannerFailure.onboardingError(untrusted).recoveryActions,
            [.retryScanning, .pasteLink, .manualConnection]
        )
    }
}

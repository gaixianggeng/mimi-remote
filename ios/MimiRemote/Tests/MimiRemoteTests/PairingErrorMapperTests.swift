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
            XCTAssertTrue(
                entry.messageZH.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "Code \(entry.code) must contain Chinese copy"
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
                let configured = (rawCtx["configured"] as? Bool) ?? true
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

        // Clock skew uses pure Chinese text instructions, NEVER App-Prefs:
        let clockSkewData = Data(#"{"ok":false,"error":{"code":"pair_clock_skew","step":"network_any","message":"时间不一致","fix":{"kind":"open_settings","target":"date_time"}}}"#.utf8)
        let clockSkew = PairingErrorMapper.mapHTTPErrorEnvelope(data: clockSkewData)
        XCTAssertTrue(clockSkew.isTrusted)
        if case .showDateTimeGuidanceAndRetry(let instructions) = clockSkew.action {
            XCTAssertTrue(instructions.contains("日期与时间"))
            XCTAssertFalse(instructions.contains("App-Prefs:"))
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
        let tokenMismatch = PairingErrorMapper.mapHTTPErrorEnvelope(data: tokenMismatchData)
        XCTAssertTrue(tokenMismatch.isTrusted)
        XCTAssertTrue(tokenMismatch.preservesSavedProfiles)
        if case .desktopGuidanceAndRescan = tokenMismatch.action {
            // expected
        } else {
            XCTFail("Expected desktopGuidanceAndRescan, got \(tokenMismatch.action)")
        }

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
}

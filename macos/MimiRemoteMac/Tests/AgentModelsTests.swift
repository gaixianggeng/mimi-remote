import XCTest
@testable import MimiRemoteMac

final class AgentModelsTests: XCTestCase {
    func testPairingPayloadContainsOnlyShortLivedFields() throws {
        let raw = Data(#"{"endpoint":"http://100.64.0.8:8787","pair_url":"mimiremote://pair?pair_sig=abc","pair_expires_at":"2026-07-22T12:00:00Z","warnings":[]}"#.utf8)
        let payload = try JSONDecoder().decode(PairingInfo.self, from: raw)

        XCTAssertEqual(payload.endpoint, "http://100.64.0.8:8787")
        XCTAssertEqual(payload.network, .tailscale)
        XCTAssertTrue(payload.pairURL.contains("pair_sig"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("token"))
    }

    func testPairingPayloadAcceptsOmittedWarnings() throws {
        let raw = Data(#"{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=abc","pair_expires_at":"2026-07-22T12:00:00Z"}"#.utf8)
        let payload = try JSONDecoder().decode(PairingInfo.self, from: raw)

        XCTAssertEqual(payload.warnings, [])
    }

    func testPairingPayloadDecodesReportedNetworkAndInfersOldLANPayload() throws {
        let reported = Data(#"{"endpoint":"http://192.168.31.20:8787","network":"lan","pair_url":"mimiremote://pair?pair_sig=abc","pair_expires_at":"2026-07-22T12:00:00Z"}"#.utf8)
        let reportedPayload = try JSONDecoder().decode(PairingInfo.self, from: reported)
        XCTAssertEqual(reportedPayload.network, .localNetwork)

        let legacy = Data(#"{"endpoint":"http://10.0.0.8:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2026-07-22T12:00:00Z"}"#.utf8)
        let legacyPayload = try JSONDecoder().decode(PairingInfo.self, from: legacy)
        XCTAssertEqual(legacyPayload.network, .localNetwork)
    }

    func testStatusPayloadDecodesDoctorAndReadinessSeparately() throws {
        let raw = Data(#"{"process_ok":true,"service_ok":false,"service_error":"upstream unavailable","version":"0.1.0","endpoint":"http://127.0.0.1:8787","config_path":"/tmp/config.json","projects":2,"doctor_ok":true,"doctor":{"ok":true,"version":"0.1.0","listen":"127.0.0.1:8787","checks":[]}}"#.utf8)
        let status = try JSONDecoder().decode(AgentStatus.self, from: raw)

        XCTAssertTrue(status.processOK)
        XCTAssertFalse(status.serviceOK)
        XCTAssertEqual(status.serviceError, "upstream unavailable")
        XCTAssertTrue(status.doctor.ok)
    }

    func testLifecyclePresentationIsStable() {
        XCTAssertEqual(HostLifecycleState.ready.title, "服务可用")
        XCTAssertEqual(HostLifecycleState.failed("boom").detail, "boom")
        XCTAssertEqual(HostLifecycleState.notConfigured.symbolName, "slider.horizontal.3")
        XCTAssertEqual(HostLifecycleState.migrationRequired.symbolName, "arrow.triangle.2.circlepath")
    }
}

import XCTest
@testable import MimiRemoteMac

final class AgentModelsTests: XCTestCase {
    func testPairingExpiryStatusDescribesOnlyTheTimeBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let status = PairingExpiryStatus(rawValue: "")

        XCTAssertEqual(
            status.statusText(at: now, expiryDate: now.addingTimeInterval(10 * 60)),
            "10 分钟后失效"
        )
        XCTAssertEqual(
            status.statusText(at: now, expiryDate: now),
            "二维码已失效"
        )
        XCTAssertEqual(PairingExpiryStatus.fallbackText(for: "10 分钟后失效"), "10 分钟后失效")
        XCTAssertFalse(
            status.statusText(at: now, expiryDate: now.addingTimeInterval(10 * 60))
                .contains("一次性")
        )
    }

    func testPairingPayloadContainsOnlyShortLivedFields() throws {
        let raw = Data(#"{"endpoint":"http://100.64.0.8:8787","tailscale_dns_name":"studio.tailnet.ts.net","tailscale_device_name":"studio","pair_url":"mimiremote://pair?pair_sig=abc","pair_expires_at":"2026-07-22T12:00:00Z","warnings":[]}"#.utf8)
        let payload = try JSONDecoder().decode(PairingInfo.self, from: raw)

        XCTAssertEqual(payload.endpoint, "http://100.64.0.8:8787")
        XCTAssertEqual(payload.network, .tailscale)
        XCTAssertEqual(payload.tailscaleDNSName, "studio.tailnet.ts.net")
        XCTAssertEqual(payload.tailscaleDeviceName, "studio")
        XCTAssertTrue(payload.pairURL.contains("pair_sig"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("token"))
    }

    func testPairingPayloadAcceptsOmittedWarnings() throws {
        let raw = Data(#"{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=abc","pair_expires_at":"2026-07-22T12:00:00Z"}"#.utf8)
        let payload = try JSONDecoder().decode(PairingInfo.self, from: raw)

        XCTAssertEqual(payload.warnings, [])
        XCTAssertNil(payload.tailscaleDNSName)
        XCTAssertNil(payload.tailscaleDeviceName)
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
        let raw = Data(#"{"process_ok":true,"service_ok":false,"service_error":"upstream unavailable","version":"0.1.1+mac.240","server_version":"0.1.0+mac.239","endpoint":"http://127.0.0.1:8787","config_path":"/tmp/config.json","projects":2,"doctor_ok":true,"doctor":{"ok":true,"version":"0.1.0+mac.239","listen":"127.0.0.1:8787","checks":[]}}"#.utf8)
        let status = try JSONDecoder().decode(AgentStatus.self, from: raw)

        XCTAssertTrue(status.processOK)
        XCTAssertFalse(status.serviceOK)
        XCTAssertEqual(status.serviceError, "upstream unavailable")
        XCTAssertEqual(status.serverVersion, "0.1.0+mac.239")
        XCTAssertTrue(status.hasAgentVersionMismatch)
        XCTAssertTrue(status.doctor.ok)
    }

    func testStatusPayloadDecodesSanitizedRuntimeAccountsAndQuotaWindows() throws {
        let raw = Data(#"""
        {
          "process_ok": true,
          "service_ok": true,
          "version": "0.1.0",
          "endpoint": "http://127.0.0.1:8787",
          "config_path": "/tmp/config.json",
          "projects": 2,
          "doctor_ok": true,
          "doctor": {"ok": true, "version": "0.1.0", "listen": "127.0.0.1:8787", "checks": []},
          "runtime_status": {
            "checked_at": "2026-07-27T12:00:00Z",
            "runtimes": [
              {
                "id": "codex",
                "title": "Codex",
                "enabled": true,
                "state": "connected",
                "version": "0.146.0-alpha.3.1",
                "started_at": "2026-07-27T08:30:00Z",
                "auth_mode": "chatgpt",
                "plan_type": "plus",
                "rate_limits": {
                  "limit_id": "codex",
                  "availability": "available",
                  "primary": {
                    "used_percent": 62.5,
                    "window_duration_mins": 300,
                    "resets_at": 1780494300
                  },
                  "secondary": {
                    "used_percent": 30,
                    "window_duration_mins": 10080,
                    "resets_at": 1781099100
                  }
                }
              },
              {
                "id": "claude",
                "title": "Claude",
                "enabled": false,
                "state": "disabled",
                "version": "0.2.6",
                "reason": "disabled"
              }
            ]
          }
        }
        """#.utf8)

        let status = try JSONDecoder().decode(AgentStatus.self, from: raw)
        let snapshot = try XCTUnwrap(status.runtimeStatus)
        let runtimes = snapshot.runtimes
        XCTAssertEqual(runtimes.map(\.id), ["codex", "claude"])
        XCTAssertEqual(runtimes.map(\.version), ["0.146.0-alpha.3.1", "0.2.6"])
        XCTAssertEqual(
            runtimes[0].startedDate,
            ISO8601DateFormatter().date(from: "2026-07-27T08:30:00Z")
        )
        XCTAssertNil(runtimes[1].startedDate)
        let checkedDate = try XCTUnwrap(snapshot.checkedDate)
        XCTAssertFalse(snapshot.isExpired(at: checkedDate.addingTimeInterval(5 * 60)))
        XCTAssertTrue(snapshot.isExpired(at: checkedDate.addingTimeInterval(6 * 60 + 1)))
        XCTAssertEqual(runtimes[0].state, .connected)
        XCTAssertEqual(runtimes[0].effectivePlanType, "plus")
        let windows = try XCTUnwrap(runtimes[0].rateLimits).windows
        XCTAssertEqual(windows.map(\.durationLabel), ["5h", "7d"])
        XCTAssertEqual(windows[0].remainingPercentText, "37.5%")
        XCTAssertEqual(windows[1].remainingPercentText, "70%")
        XCTAssertEqual(runtimes[1].state, .disabled)
    }

    func testUnknownRuntimeStateFailsClosedWithoutBreakingAgentStatusDecode() throws {
        let raw = Data(#"""
        {
          "process_ok": true,
          "service_ok": true,
          "version": "0.1.0",
          "endpoint": "http://127.0.0.1:8787",
          "config_path": "/tmp/config.json",
          "projects": 1,
          "doctor_ok": true,
          "doctor": {"ok": true, "version": "0.1.0", "listen": "127.0.0.1:8787", "checks": []},
          "runtime_status": {
            "checked_at": "2026-07-27T12:00:00Z",
            "runtimes": [{"id":"codex","title":"Codex","enabled":true,"state":"future_state"}]
          }
        }
        """#.utf8)

        let status = try JSONDecoder().decode(AgentStatus.self, from: raw)
        XCTAssertEqual(status.runtimeStatus?.runtimes.first?.state, .unavailable)
    }

    func testRuntimeQuotaRecognizesReachedStateAndCredits() {
        let limits = AgentRuntimeRateLimits(
            limitID: "codex",
            limitName: "Codex",
            planType: "plus",
            reachedType: "primary",
            availability: "partial",
            unavailableReason: nil,
            primary: AgentRuntimeRateLimitWindow(
                usedPercent: nil,
                windowDurationMins: 300,
                resetsAt: 1_780_494_300
            ),
            secondary: nil,
            hasCredits: true,
            creditsUnlimited: false,
            creditBalance: "12.34"
        )

        XCTAssertTrue(limits.isExhausted)
        XCTAssertEqual(limits.creditBalance, "12.34")
        XCTAssertEqual(limits.availability, "partial")
    }

    func testRefreshingSnapshotWithoutCheckedDateIsNotMarkedExpired() {
        let snapshot = AgentRuntimeStatusSnapshot(
            checkedAt: nil,
            runtimes: [],
            refreshing: true,
            stale: false
        )

        XCTAssertFalse(snapshot.isExpired())
    }

    func testMalformedRuntimeSnapshotDoesNotBreakCoreStatusDecode() throws {
        let raw = Data(#"""
        {
          "process_ok": true,
          "service_ok": true,
          "version": "0.1.0",
          "endpoint": "http://127.0.0.1:8787",
          "config_path": "/tmp/config.json",
          "projects": 1,
          "doctor_ok": true,
          "doctor": {"ok": true, "version": "0.1.0", "listen": "127.0.0.1:8787", "checks": []},
          "runtime_status": {}
        }
        """#.utf8)

        let status = try JSONDecoder().decode(AgentStatus.self, from: raw)

        XCTAssertTrue(status.serviceOK)
        XCTAssertNil(status.runtimeStatus)
    }

    func testRuntimeFailureRetryOnlyAppliesToEnabledUnavailableProvider() {
        let failed = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-07-27T12:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "claude",
                    title: "Claude",
                    enabled: true,
                    state: .unavailable,
                    authMode: nil,
                    planType: nil,
                    reason: "bridge_unavailable",
                    rateLimits: nil
                ),
            ],
            refreshing: false,
            stale: false
        )
        let disabled = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-07-27T12:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "claude",
                    title: "Claude",
                    enabled: false,
                    state: .disabled,
                    authMode: nil,
                    planType: nil,
                    reason: "disabled",
                    rateLimits: nil
                ),
            ],
            refreshing: false,
            stale: false
        )
        let quotaRefreshing = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-07-27T12:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "claude",
                    title: "Claude",
                    enabled: true,
                    state: .available,
                    authMode: nil,
                    planType: nil,
                    reason: "quota_refresh_in_progress",
                    rateLimits: nil
                ),
            ],
            refreshing: false,
            stale: false
        )
        let quotaUnavailable = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-07-27T12:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "claude",
                    title: "Claude",
                    enabled: true,
                    state: .available,
                    authMode: nil,
                    planType: nil,
                    reason: nil,
                    rateLimits: AgentRuntimeRateLimits(
                        limitID: "claude",
                        limitName: "Claude",
                        planType: nil,
                        reachedType: nil,
                        availability: "unavailable",
                        unavailableReason: "headless_statusline_unavailable",
                        primary: nil,
                        secondary: nil,
                        hasCredits: nil,
                        creditsUnlimited: nil,
                        creditBalance: nil
                    )
                ),
            ],
            refreshing: false,
            stale: false
        )

        XCTAssertTrue(failed.hasRetryableFailure)
        XCTAssertTrue(quotaRefreshing.hasRetryableFailure)
        XCTAssertTrue(quotaUnavailable.hasRetryableFailure)
        XCTAssertEqual(
            HostStore.runtimeStatusFollowUpDelay(
                snapshot: failed,
                didRetryUnavailable: false
            ),
            .seconds(15)
        )
        XCTAssertNil(
            HostStore.runtimeStatusFollowUpDelay(
                snapshot: failed,
                didRetryUnavailable: true
            )
        )
        XCTAssertFalse(disabled.hasRetryableFailure)
    }

    func testLifecyclePresentationIsStable() {
        XCTAssertEqual(HostLifecycleState.ready.title, "服务可用")
        XCTAssertEqual(HostLifecycleState.failed("boom").detail, "boom")
        XCTAssertEqual(HostLifecycleState.notConfigured.symbolName, "slider.horizontal.3")
        XCTAssertEqual(HostLifecycleState.migrationRequired.symbolName, "arrow.triangle.2.circlepath")
    }
}

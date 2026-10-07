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

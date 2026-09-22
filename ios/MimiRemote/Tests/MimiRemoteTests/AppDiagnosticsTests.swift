import XCTest
@testable import MimiRemote

final class AppDiagnosticsTests: XCTestCase {
    private var directoryURL: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiRemote-AppDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let suiteName = "MimiRemote.AppDiagnosticsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        defaults = nil
        directoryURL = nil
        try super.tearDownWithError()
    }

    func testDetailedLoggingExpiresAfterFifteenMinutes() {
        let start = Date(timeIntervalSince1970: 10_000)
        let expiration = AppDiagnosticsPolicy.setDetailedLoggingEnabled(true, at: start, defaults: defaults)

        XCTAssertEqual(expiration, start.addingTimeInterval(15 * 60))
        XCTAssertNotNil(AppDiagnosticsPolicy.detailedLoggingExpiration(
            at: start.addingTimeInterval(15 * 60 - 1),
            defaults: defaults
        ))
        XCTAssertNil(AppDiagnosticsPolicy.detailedLoggingExpiration(
            at: start.addingTimeInterval(15 * 60),
            defaults: defaults
        ))
        XCTAssertNil(defaults.object(forKey: AppDiagnosticsPolicy.detailedLoggingExpirationKey))
    }

    func testDetailedLoggingDefaultsToOff() {
        XCTAssertNil(AppDiagnosticsPolicy.detailedLoggingExpiration(defaults: defaults))
    }

    func testClockRollbackCannotExtendRemainingWindowPastFifteenMinutes() {
        let start = Date(timeIntervalSince1970: 10_000)
        defaults.set(start.addingTimeInterval(60 * 60), forKey: AppDiagnosticsPolicy.detailedLoggingExpirationKey)

        let bounded = AppDiagnosticsPolicy.detailedLoggingExpiration(at: start, defaults: defaults)

        XCTAssertEqual(bounded, start.addingTimeInterval(15 * 60))
        XCTAssertEqual(
            defaults.object(forKey: AppDiagnosticsPolicy.detailedLoggingExpirationKey) as? Date,
            bounded
        )
    }

    func testPurgeRemovesEventsOlderThanSevenDays() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = AppDiagnosticsFileStore(directoryURL: directoryURL)
        try store.append([
            event(at: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 1), result: .failed),
            event(at: now.addingTimeInterval(-60), result: .succeeded),
        ], now: now)

        try store.purge(now: now)

        let events = store.storedEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.result, .succeeded)
    }

    func testStoreRotatesWithinTwoBoundedFiles() throws {
        let store = AppDiagnosticsFileStore(
            directoryURL: directoryURL,
            maximumFileBytes: 700,
            retentionInterval: 7 * 24 * 60 * 60
        )
        let now = Date(timeIntervalSince1970: 1_000_000)

        for index in 0..<80 {
            try store.append([
                AppDiagnosticEvent(
                    timestamp: now.addingTimeInterval(Double(index)),
                    stage: .sessionHistory,
                    result: .succeeded,
                    reason: .foreground,
                    durationMilliseconds: index,
                    correlation: .make()
                )
            ], now: now)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        XCTAssertLessThanOrEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return (values?.fileSize ?? Int.max) <= 700
        })
        XCTAssertLessThanOrEqual(files.reduce(0) { partial, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return partial + (values?.fileSize ?? 0)
        }, 1_400)
    }

    func testClearRemovesOnlyDiagnosticsFiles() throws {
        let unrelated = directoryURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let store = AppDiagnosticsFileStore(directoryURL: directoryURL)
        try store.append([event(at: Date(), result: .failed)])

        try store.clear()

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(store.storedEvents().isEmpty)
    }

    func testEncodedSchemaCannotContainFreeFormSensitiveFields() throws {
        let diagnosticEvent = AppDiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            stage: .messageAcknowledgement,
            result: .failed,
            reason: .transport,
            durationMilliseconds: 42,
            correlation: .make()
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.iso8601.encode(diagnosticEvent)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set(["timestamp", "stage", "result", "reason", "durationMilliseconds", "correlation"])
        )
        let encoded = String(decoding: try JSONEncoder.iso8601.encode(diagnosticEvent), as: UTF8.self)
        for forbiddenKey in ["message", "body", "filename", "path", "url", "ip", "account", "session_id"] {
            XCTAssertFalse(encoded.lowercased().contains("\"\(forbiddenKey)\""))
        }
    }

    func testTraceRegistryEmitsRandomCorrelationAndOnlyOneFirstResponse() throws {
        let registry = AppDiagnosticTraceRegistry()
        let correlation = registry.begin(key: "opaque-server-id")

        XCTAssertEqual(registry.takeFirstResponse(key: "opaque-server-id"), correlation)
        XCTAssertNil(registry.takeFirstResponse(key: "opaque-server-id"))
        XCTAssertEqual(registry.end(key: "opaque-server-id"), correlation)
        XCTAssertFalse(correlation.value.contains("opaque-server-id"))
        XCTAssertEqual(correlation.value.count, 12)
        XCTAssertTrue(correlation.value.allSatisfy(\.isHexDigit))
    }

    func testPurgeReencodesKnownFieldsAndDropsInjectedFreeFormFields() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let activeURL = directoryURL.appendingPathComponent("diagnostics-0.jsonl")
        let injected = """
        {"timestamp":"1970-01-12T13:46:40Z","stage":"connection","result":"failed","reason":"server","durationMilliseconds":3,"correlation":"abcdef123456","message":"secret body","path":"/private/file"}
        """
        try Data((injected + "\n").utf8).write(to: activeURL)
        let store = AppDiagnosticsFileStore(directoryURL: directoryURL)

        let exported = try store.exportData(now: now)
        let text = String(decoding: exported, as: UTF8.self)

        XCTAssertFalse(text.contains("secret body"))
        XCTAssertFalse(text.contains("/private/file"))
        XCTAssertFalse(text.contains("\"message\""))
        XCTAssertFalse(text.contains("\"path\""))
        XCTAssertEqual(store.storedEvents().count, 1)
    }

    func testInvalidCorrelationIsRejectedDuringPurge() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let activeURL = directoryURL.appendingPathComponent("diagnostics-0.jsonl")
        let injected = """
        {"timestamp":"1970-01-12T13:46:40Z","stage":"connection","result":"failed","reason":"server","correlation":"raw-session-id"}
        """
        try Data((injected + "\n").utf8).write(to: activeURL)
        let store = AppDiagnosticsFileStore(directoryURL: directoryURL)

        let exported = try store.exportData(now: now)

        XCTAssertTrue(exported.isEmpty)
        XCTAssertTrue(store.storedEvents().isEmpty)
    }

    func testPurgeDropsEventsWithImplausibleFutureTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = AppDiagnosticsFileStore(directoryURL: directoryURL)
        try store.append([
            event(at: now.addingTimeInterval(60), result: .failed),
            event(at: now.addingTimeInterval(61), result: .failed),
        ], now: now)

        let exported = try store.exportData(now: now)

        XCTAssertEqual(
            exported.split(separator: 0x0A).compactMap {
                try? JSONDecoder.iso8601.decode(AppDiagnosticEvent.self, from: Data($0))
            }.map(\.timestamp),
            [now.addingTimeInterval(60)]
        )
    }

    func testRecorderReportsDroppedWriteUntilClearSucceeds() async throws {
        let store = AppDiagnosticsFileStore(directoryURL: directoryURL)
        let recorder = AppDiagnosticsRecorder(store: store)
        _ = try await recorder.exportData()
        let activeURL = directoryURL.appendingPathComponent("diagnostics-0.jsonl")
        try FileManager.default.createDirectory(at: activeURL, withIntermediateDirectories: false)

        recorder.submit(event(at: Date(), result: .failed))

        do {
            _ = try await recorder.exportData()
            XCTFail("Export must report that an earlier diagnostic record was dropped")
        } catch {}

        try await recorder.clear()
        let exportedAfterClear = try await recorder.exportData()
        XCTAssertTrue(exportedAfterClear.isEmpty)
    }

    private func event(at date: Date, result: AppDiagnosticResult) -> AppDiagnosticEvent {
        AppDiagnosticEvent(
            timestamp: date,
            stage: .connection,
            result: result,
            reason: .unknown,
            durationMilliseconds: nil,
            correlation: nil
        )
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

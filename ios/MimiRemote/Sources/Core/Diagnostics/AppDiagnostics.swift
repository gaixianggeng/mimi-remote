import Foundation

enum AppDiagnosticStage: String, Codable, Sendable {
    case lifecycle
    case connection
    case reconnection
    case sessionList = "session_list"
    case sessionHistory = "session_history"
    case messageSend = "message_send"
    case messageAcknowledgement = "message_acknowledgement"
    case firstResponse = "first_response"
    case completion
    case approval
    case interrupt
    case failure
}

enum AppDiagnosticResult: String, Codable, Sendable {
    case started
    case scheduled
    case received
    case succeeded
    case failed
    case cancelled

    var isFailure: Bool { self == .failed }
}

enum AppDiagnosticReason: String, Codable, Sendable {
    case startup
    case foreground
    case background
    case manual
    case networkUnavailable = "network_unavailable"
    case credentialsInvalid = "credentials_invalid"
    case policyRejected = "policy_rejected"
    case writerConflict = "writer_conflict"
    case disconnected
    case notConnected = "not_connected"
    case invalidResponse = "invalid_response"
    case staleTarget = "stale_target"
    case rejected
    case timeout
    case transport
    case server
    case unknown
}

/// 关联值由本机随机生成，不接受服务端 ID、文件路径或其它自由文本。
struct AppDiagnosticCorrelation: Codable, Equatable, Sendable {
    let value: String

    private init(value: String) {
        self.value = value
    }

    static func make() -> AppDiagnosticCorrelation {
        AppDiagnosticCorrelation(
            value: String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(12))
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard value.count == 12, value.allSatisfy(\.isHexDigit) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Diagnostic correlation must be 12 hexadecimal characters"
            )
        }
        self.value = value.lowercased()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct AppDiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let stage: AppDiagnosticStage
    let result: AppDiagnosticResult
    let reason: AppDiagnosticReason?
    let durationMilliseconds: Int?
    let correlation: AppDiagnosticCorrelation?
}

enum AppDiagnosticsPolicy {
    static let detailedLoggingDuration: TimeInterval = 15 * 60
    static let detailedLoggingExpirationKey = "mimi.appDiagnostics.detailedUntil"

    static func detailedLoggingExpiration(
        at now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Date? {
        guard let expiration = defaults.object(forKey: detailedLoggingExpirationKey) as? Date else {
            return nil
        }
        guard expiration > now else {
            defaults.removeObject(forKey: detailedLoggingExpirationKey)
            return nil
        }
        // 系统时钟回拨时，旧绝对时间可能突然落到很远以后；剩余窗口仍硬限制为 15 分钟。
        let maximumExpiration = now.addingTimeInterval(detailedLoggingDuration)
        let boundedExpiration = min(expiration, maximumExpiration)
        if boundedExpiration != expiration {
            defaults.set(boundedExpiration, forKey: detailedLoggingExpirationKey)
        }
        return boundedExpiration
    }

    @discardableResult
    static func setDetailedLoggingEnabled(
        _ enabled: Bool,
        at now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Date? {
        guard enabled else {
            defaults.removeObject(forKey: detailedLoggingExpirationKey)
            return nil
        }
        let expiration = now.addingTimeInterval(detailedLoggingDuration)
        defaults.set(expiration, forKey: detailedLoggingExpirationKey)
        return expiration
    }
}

/// 只在内存中用不透明业务 ID 找到同一条链路；落盘的始终是随机本机关联值。
final class AppDiagnosticTraceRegistry: @unchecked Sendable {
    static let shared = AppDiagnosticTraceRegistry()

    private struct Trace {
        let correlation: AppDiagnosticCorrelation
        var didRecordFirstResponse: Bool
    }

    private let lock = NSLock()
    private var traces: [String: Trace] = [:]
    private var order: [String] = []
    private let capacity = 128

    func begin(key: String) -> AppDiagnosticCorrelation {
        lock.lock()
        defer { lock.unlock() }
        if let existing = traces[key] {
            return existing.correlation
        }
        let correlation = AppDiagnosticCorrelation.make()
        traces[key] = Trace(correlation: correlation, didRecordFirstResponse: false)
        order.append(key)
        trimIfNeeded()
        return correlation
    }

    func markTurnStarted(key: String) -> AppDiagnosticCorrelation {
        lock.lock()
        defer { lock.unlock() }
        if var existing = traces[key] {
            existing.didRecordFirstResponse = false
            traces[key] = existing
            return existing.correlation
        }
        let correlation = AppDiagnosticCorrelation.make()
        traces[key] = Trace(correlation: correlation, didRecordFirstResponse: false)
        order.append(key)
        trimIfNeeded()
        return correlation
    }

    func correlation(key: String) -> AppDiagnosticCorrelation {
        begin(key: key)
    }

    func takeFirstResponse(key: String) -> AppDiagnosticCorrelation? {
        lock.lock()
        defer { lock.unlock() }
        guard var trace = traces[key], !trace.didRecordFirstResponse else {
            return nil
        }
        trace.didRecordFirstResponse = true
        traces[key] = trace
        return trace.correlation
    }

    func end(key: String) -> AppDiagnosticCorrelation? {
        lock.lock()
        defer { lock.unlock() }
        order.removeAll { $0 == key }
        return traces.removeValue(forKey: key)?.correlation
    }

    func reset() {
        lock.lock()
        traces.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func trimIfNeeded() {
        guard order.count > capacity else { return }
        for key in order.prefix(order.count - capacity) {
            traces.removeValue(forKey: key)
        }
        order.removeFirst(order.count - capacity)
    }
}

/// 同步文件操作只在 recorder 的 utility 串行队列调用。
/// 实例只由 AppDiagnosticsRecorder 的串行队列访问；测试也保持单线程调用。
final class AppDiagnosticsFileStore: @unchecked Sendable {
    static let maximumFileBytes = 5 * 1_024 * 1_024
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private let directoryURL: URL
    private let fileManager: FileManager
    private let maximumFileBytes: Int
    private let retentionInterval: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var lastPurgeAt: Date?

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maximumFileBytes: Int = AppDiagnosticsFileStore.maximumFileBytes,
        retentionInterval: TimeInterval = AppDiagnosticsFileStore.retentionInterval
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maximumFileBytes = maximumFileBytes
        self.retentionInterval = retentionInterval
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ events: [AppDiagnosticEvent], now: Date = Date()) throws {
        guard !events.isEmpty else { return }
        try prepareDirectory()
        if lastPurgeAt.map({
            let elapsed = now.timeIntervalSince($0)
            return elapsed < 0 || elapsed >= 60 * 60
        }) != false {
            try purge(now: now)
        }
        let encoded = events.compactMap { event -> Data? in
            guard var data = try? encoder.encode(event) else { return nil }
            data.append(0x0A)
            return data
        }
        for data in encoded where data.count <= maximumFileBytes {
            try rotateIfNeeded(addingBytes: data.count)
            try append(data, to: activeURL)
        }
        try enforceCapacity()
    }

    func purge(now: Date = Date()) throws {
        try prepareDirectory()
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let latestAcceptedTimestamp = now.addingTimeInterval(60)
        for url in [archiveURL, activeURL] where fileManager.fileExists(atPath: url.path) {
            let data = try boundedFileData(at: url)
            let retained = data.split(separator: 0x0A).compactMap { line -> Data? in
                guard let event = try? decoder.decode(AppDiagnosticEvent.self, from: Data(line)),
                      event.timestamp >= cutoff,
                      event.timestamp <= latestAcceptedTimestamp else {
                    return nil
                }
                // 解码后重新编码，旧版本或被篡改记录中的未知字段不会透传到导出文件。
                guard var lineData = try? encoder.encode(event) else { return nil }
                lineData.append(0x0A)
                return lineData
            }
            let output = retained.reduce(into: Data()) { $0.append($1) }
            if output.isEmpty {
                try fileManager.removeItem(at: url)
            } else {
                try output.write(to: url, options: .atomic)
            }
        }
        lastPurgeAt = now
        try enforceCapacity()
    }

    func exportData(now: Date = Date()) throws -> Data {
        try purge(now: now)
        var result = Data()
        for url in [archiveURL, activeURL] {
            if fileManager.fileExists(atPath: url.path) {
                result.append(try boundedFileData(at: url))
            }
        }
        return result
    }

    func clear() throws {
        for url in [archiveURL, activeURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        lastPurgeAt = nil
    }

    func storedEvents() -> [AppDiagnosticEvent] {
        var events: [AppDiagnosticEvent] = []
        for url in [archiveURL, activeURL] {
            guard let data = try? boundedFileData(at: url) else { continue }
            events.append(contentsOf: data.split(separator: 0x0A).compactMap {
                try? decoder.decode(AppDiagnosticEvent.self, from: Data($0))
            })
        }
        return events
    }

    private var activeURL: URL { directoryURL.appendingPathComponent("diagnostics-0.jsonl") }
    private var archiveURL: URL { directoryURL.appendingPathComponent("diagnostics-1.jsonl") }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directoryURL
        try mutableURL.setResourceValues(values)
    }

    private func rotateIfNeeded(addingBytes: Int) throws {
        let currentBytes = try fileSize(activeURL)
        guard currentBytes + addingBytes > maximumFileBytes else { return }
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        if fileManager.fileExists(atPath: activeURL.path) {
            try fileManager.moveItem(at: activeURL, to: archiveURL)
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func enforceCapacity() throws {
        for url in [archiveURL, activeURL] where fileManager.fileExists(atPath: url.path) {
            if try fileSize(url) > maximumFileBytes {
                let capped = try boundedFileData(at: url)
                try capped.write(to: url, options: .atomic)
            }
        }
    }

    /// 即使磁盘上的文件被外部工具异常放大，也最多读取单文件预算大小。
    private func boundedFileData(at url: URL) throws -> Data {
        let size = try fileSize(url)
        let startOffset = max(0, size - maximumFileBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        var data = try handle.read(upToCount: maximumFileBytes) ?? Data()
        if startOffset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }

    private func fileSize(_ url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int else {
            throw CocoaError(.fileReadUnknown)
        }
        return size
    }
}

final class AppDiagnosticsRecorder: @unchecked Sendable {
    static let shared = AppDiagnosticsRecorder()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.gaixianggeng.mimi.app-diagnostics", qos: .utility)
    private var pending: [AppDiagnosticEvent] = []
    private var drainScheduled = false
    private var lastWriteFailure: Error?
    private let pendingCapacity = 256
    private let store: AppDiagnosticsFileStore
    private let maintenanceTimer: DispatchSourceTimer

    init(store: AppDiagnosticsFileStore? = nil) {
        if let store {
            self.store = store
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.store = AppDiagnosticsFileStore(directoryURL: support.appendingPathComponent("MimiRemoteDiagnostics", isDirectory: true))
        }
        let store = self.store
        maintenanceTimer = DispatchSource.makeTimerSource(queue: queue)
        maintenanceTimer.schedule(deadline: .now() + 60 * 60, repeating: 60 * 60)
        queue.async { [weak self] in
            do {
                try store.purge()
            } catch {
                self?.lastWriteFailure = error
            }
        }
        maintenanceTimer.setEventHandler { [weak self] in
            do {
                try store.purge()
            } catch {
                self?.lastWriteFailure = error
            }
        }
        maintenanceTimer.resume()
    }

    deinit {
        maintenanceTimer.cancel()
    }

    func submit(_ event: AppDiagnosticEvent) {
        lock.lock()
        pending.append(event)
        if pending.count > pendingCapacity {
            pending.removeFirst(pending.count - pendingCapacity)
        }
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        queue.async { [weak self] in self?.drain() }
    }

    func maintain() {
        queue.async { [weak self, store] in
            do {
                try store.purge()
            } catch {
                self?.lastWriteFailure = error
            }
        }
    }

    func exportData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self, store] in
                do {
                    if let lastWriteFailure = self?.lastWriteFailure {
                        throw lastWriteFailure
                    }
                    if let pending = self?.takeAllPending(), !pending.isEmpty {
                        do {
                            try store.append(pending)
                        } catch {
                            self?.lastWriteFailure = error
                            throw error
                        }
                    }
                    continuation.resume(returning: try store.exportData())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func clear() async throws {
        clearPending()
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self, store] in
                do {
                    try store.clear()
                    self?.lastWriteFailure = nil
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func drain() {
        lock.lock()
        let batch = Array(pending.prefix(32))
        pending.removeFirst(batch.count)
        if batch.isEmpty {
            drainScheduled = false
            lock.unlock()
            return
        }
        lock.unlock()
        do {
            try store.append(batch)
        } catch {
            lastWriteFailure = error
        }

        // 每批重新入队，让已经排队的导出或清除操作不会被持续事件流饿死。
        queue.async { [weak self] in self?.drain() }
    }

    private func takeAllPending() -> [AppDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        return events
    }

    private func clearPending() {
        lock.lock()
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

enum AppDiagnostics {
    static var isDetailedLoggingEnabled: Bool {
        AppDiagnosticsPolicy.detailedLoggingExpiration() != nil
    }

    static func record(
        stage: AppDiagnosticStage,
        result: AppDiagnosticResult,
        reason: AppDiagnosticReason? = nil,
        durationMilliseconds: Int? = nil,
        correlation: AppDiagnosticCorrelation? = nil,
        at now: Date = Date()
    ) {
        // 详细事件仅在用户临时开启后记录；固定代码失败始终保留，便于普通安装排障。
        guard result.isFailure || AppDiagnosticsPolicy.detailedLoggingExpiration(at: now) != nil else {
            return
        }
        AppDiagnosticsRecorder.shared.submit(AppDiagnosticEvent(
            timestamp: now,
            stage: stage,
            result: result,
            reason: reason,
            durationMilliseconds: durationMilliseconds.map { max(0, $0) },
            correlation: correlation
        ))
    }

    static func elapsedMilliseconds(since start: Date, now: Date = Date()) -> Int {
        max(0, Int((now.timeIntervalSince(start) * 1_000).rounded()))
    }

    static func maintain() {
        if AppDiagnosticsPolicy.detailedLoggingExpiration() == nil {
            AppDiagnosticTraceRegistry.shared.reset()
        }
        AppDiagnosticsRecorder.shared.maintain()
    }

    static func exportData() async throws -> Data {
        try await AppDiagnosticsRecorder.shared.exportData()
    }

    static func clear() async throws {
        try await AppDiagnosticsRecorder.shared.clear()
    }
}

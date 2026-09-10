import Foundation
import os

/// 通知路由的阶段诊断。
///
/// 只记录阶段、结果、原因、耗时和脱敏后的关联标识，不记录会话正文、明文目录、Token
/// 或完整推送载荷。每条记录同时写入统一日志（真机可用 Console 或 `log collect` 导出）
/// 和一份有界环形缓冲，供设置页在开发者模式下复制。
enum NotificationRouteDiagnostics {
    struct Entry: Equatable, Sendable {
        let at: Date
        let stage: String
        let outcome: String
        let reason: String?
        let correlation: String?
        let elapsedMilliseconds: Int?
    }

    enum Stage {
        static let received = "received"
        static let gate = "gate"
        static let localResolve = "local_resolve"
        static let sourceClient = "source_client"
        static let routeLookup = "route_lookup"
        static let projectResolve = "project_resolve"
        static let sessionOpen = "session_open"
        static let reconcile = "reconcile"
    }

    static let capacity = 200

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gaixianggeng.mimi",
        category: "NotificationRoute"
    )
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ring: [Entry] = []

    /// 记录一个阶段结果。`correlation` 只传脱敏标识（例如 action_id 前 8 位或 session_tag），
    /// `reason` 只传枚举式短语，不要拼接用户内容。
    static func record(
        stage: String,
        outcome: String,
        reason: String? = nil,
        correlation: String? = nil,
        elapsedMilliseconds: Int? = nil
    ) {
        let entry = Entry(
            at: Date(),
            stage: stage,
            outcome: outcome,
            reason: reason,
            correlation: correlation,
            elapsedMilliseconds: elapsedMilliseconds
        )
        lock.lock()
        ring.append(entry)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
        lock.unlock()
        logger.notice(
            "stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) reason=\(reason ?? "-", privacy: .public) correlation=\(correlation ?? "-", privacy: .public) elapsed_ms=\(elapsedMilliseconds ?? -1, privacy: .public)"
        )
    }

    /// 便于在 `await` 前后测量耗时。
    static func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    static func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    static func reset() {
        lock.lock()
        ring.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// 导出为多行文本，供复制到问题反馈；每行一条记录。
    static func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries().map { entry in
            var parts = [
                formatter.string(from: entry.at),
                entry.stage,
                entry.outcome,
            ]
            if let reason = entry.reason { parts.append("reason=\(reason)") }
            if let correlation = entry.correlation { parts.append("ref=\(correlation)") }
            if let elapsed = entry.elapsedMilliseconds { parts.append("\(elapsed)ms") }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// 关联标识统一截短，避免把完整 action_id 或线程 ID 写进日志。
    static func shortReference(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(8))
    }
}

import Foundation

struct AgentDiagnosticsStatus: Decodable, Equatable, Sendable {
    let enabled: Bool
    let expiresAt: String?
    let currentBytes: Int64
    let previousBytes: Int64
    let totalBytes: Int64
    let maxTotalBytes: Int64
    let retentionDays: Int
    let droppedRecords: Int64

    private enum CodingKeys: String, CodingKey {
        case enabled
        case expiresAt = "expires_at"
        case currentBytes = "current_bytes"
        case previousBytes = "previous_bytes"
        case totalBytes = "total_bytes"
        case maxTotalBytes = "max_total_bytes"
        case retentionDays = "retention_days"
        case droppedRecords = "dropped_records"
    }

    init(
        enabled: Bool,
        expiresAt: String?,
        currentBytes: Int64,
        previousBytes: Int64,
        totalBytes: Int64,
        maxTotalBytes: Int64,
        retentionDays: Int,
        droppedRecords: Int64 = 0
    ) {
        self.enabled = enabled
        self.expiresAt = expiresAt
        self.currentBytes = currentBytes
        self.previousBytes = previousBytes
        self.totalBytes = totalBytes
        self.maxTotalBytes = maxTotalBytes
        self.retentionDays = retentionDays
        self.droppedRecords = droppedRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        currentBytes = try container.decode(Int64.self, forKey: .currentBytes)
        previousBytes = try container.decode(Int64.self, forKey: .previousBytes)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        maxTotalBytes = try container.decode(Int64.self, forKey: .maxTotalBytes)
        retentionDays = try container.decode(Int.self, forKey: .retentionDays)
        droppedRecords = try container.decodeIfPresent(Int64.self, forKey: .droppedRecords) ?? 0
    }

    var expirationDate: Date? {
        guard let expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expiresAt)
            ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

struct AgentDiagnosticsExport: Decodable, Equatable, Sendable {
    let lines: [String]
}

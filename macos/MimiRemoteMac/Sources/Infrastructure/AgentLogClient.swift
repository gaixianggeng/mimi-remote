import AppKit
import Foundation

struct AgentLogClient: Sendable {
    var recentLines: @Sendable (_ count: Int) async throws -> [String]
    var reveal: @MainActor @Sendable () -> Void
    let fileURL: URL
}

extension AgentLogClient {
    static let live: AgentLogClient = {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/mimi-remote/agentd.log")
        return AgentLogClient(
            recentLines: { count in
                let safeCount = min(max(count, 1), 500)
                return try await Task.detached {
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
                    let raw = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    return String(decoding: raw, as: UTF8.self)
                        .split(whereSeparator: \.isNewline)
                        .suffix(safeCount)
                        .map(String.init)
                }.value
            },
            reveal: {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            },
            fileURL: fileURL
        )
    }()
}

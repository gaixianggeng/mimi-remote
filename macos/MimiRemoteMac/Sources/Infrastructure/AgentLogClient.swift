import Foundation

struct AgentLogClient: Sendable {
    var recentLines: @Sendable (_ count: Int) async throws -> [String]
    var exportLines: @Sendable () async throws -> [String] = {
        throw AgentClientError.commandFailed("当前 agentd 不支持安全日志导出，请更新 App。")
    }
}

extension AgentLogClient {
    static let live: AgentLogClient = {
        let agent = AgentCommandClient.live()
        return AgentLogClient(
            recentLines: { count in
                let safeCount = min(max(count, 1), 500)
                return Array(try await agent.exportDiagnostics().lines.suffix(safeCount))
            },
            exportLines: {
                try await agent.exportDiagnostics().lines
            }
        )
    }()
}

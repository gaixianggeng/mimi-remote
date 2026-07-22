import Foundation

struct AgentCommandClient: Sendable {
    var configExists: @Sendable () -> Bool
    var setup: @Sendable (_ workspaceRoot: URL) async throws -> PairingInfo
    var status: @Sendable () async throws -> AgentStatus
    var statusAt: @Sendable (_ binary: URL) async throws -> AgentStatus
    var doctor: @Sendable (_ fix: Bool) async throws -> DoctorFixResults
    var pair: @Sendable () async throws -> PairingInfo
    var version: @Sendable () async throws -> String
}

extension AgentCommandClient {
    static func live(
        executor: ProcessExecutor = .shared,
        bundle: Bundle = .main
    ) -> AgentCommandClient {
        let embeddedBinary = bundle.url(forResource: "agentd", withExtension: nil)
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/mimi-remote/config.json")
        let environment = ProcessEnvironment.userTooling

        @Sendable func requireEmbeddedBinary() throws -> URL {
            guard let embeddedBinary else {
                throw AgentClientError.embeddedBinaryMissing
            }
            return embeddedBinary
        }

        @Sendable func execute(
            binary: URL,
            arguments: [String],
            allowFailure: Bool = false,
            timeout: Duration = .seconds(15)
        ) async throws -> CommandResult {
            let result = try await executor.run(
                executable: binary,
                arguments: arguments,
                timeout: timeout,
                environment: environment
            )
            if result.status != 0 && !allowFailure {
                throw AgentClientError.commandFailed(
                    result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return result
        }

        @Sendable func decode<T: Decodable>(_ type: T.Type, from result: CommandResult) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: result.stdout)
            } catch {
                throw AgentClientError.invalidResponse(error.localizedDescription)
            }
        }

        return AgentCommandClient(
            configExists: {
                FileManager.default.fileExists(atPath: configURL.path)
            },
            setup: { workspaceRoot in
                let binary = try requireEmbeddedBinary()
                let result = try await execute(binary: binary, arguments: [
                    "setup", "--json", "--qr-only",
                    "--scan-root", workspaceRoot.path,
                    "--browse-root", workspaceRoot.path,
                ])
                return try decode(PairingInfo.self, from: result)
            },
            status: {
                let binary = try requireEmbeddedBinary()
                return try decode(AgentStatus.self, from: try await execute(
                    binary: binary,
                    arguments: ["status", "--json"],
                    timeout: .seconds(8)
                ))
            },
            statusAt: { binary in
                try decode(AgentStatus.self, from: try await execute(
                    binary: binary,
                    arguments: ["status", "--json"],
                    timeout: .seconds(8)
                ))
            },
            doctor: { fix in
                let binary = try requireEmbeddedBinary()
                var arguments = ["doctor", "--json"]
                if fix { arguments.append("--fix") }
                let result = try await execute(
                    binary: binary,
                    arguments: arguments,
                    allowFailure: true,
                    timeout: .seconds(20)
                )
                if fix {
                    return try decode(DoctorFixResults.self, from: result)
                }
                let results = try decode(AgentDoctorResults.self, from: result)
                return DoctorFixResults(fixes: [], results: results)
            },
            pair: {
                let binary = try requireEmbeddedBinary()
                return try decode(PairingInfo.self, from: try await execute(
                    binary: binary,
                    arguments: ["pair", "--json", "--qr-only"]
                ))
            },
            version: {
                let binary = try requireEmbeddedBinary()
                let result = try await execute(binary: binary, arguments: ["version"])
                return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }

}

enum AgentClientError: LocalizedError {
    case embeddedBinaryMissing
    case commandFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .embeddedBinaryMissing:
            "App 内没有找到 agentd，请重新构建或安装 Mimi Remote Mac。"
        case .commandFailed(let detail):
            detail.isEmpty ? "agentd 命令执行失败" : detail
        case .invalidResponse(let detail):
            "无法解析 agentd 返回结果：\(detail)"
        }
    }
}

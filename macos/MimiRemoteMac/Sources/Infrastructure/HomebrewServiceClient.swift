import Foundation

struct HomebrewServiceClient: Sendable {
    var isLoaded: @Sendable () async -> Bool
    var installedAgentBinary: @Sendable () -> URL?
    var start: @Sendable () async throws -> Void
    var stop: @Sendable () async throws -> Void
}

extension HomebrewServiceClient {
    static func live(executor: ProcessExecutor = .shared) -> HomebrewServiceClient {
        let environment = ProcessEnvironment.userTooling
        let launchctl = URL(filePath: "/bin/launchctl")

        @Sendable func brewBinary() -> URL? {
            for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
                if FileManager.default.isExecutableFile(atPath: path) {
                    return URL(filePath: path)
                }
            }
            return nil
        }

        @Sendable func runBrew(_ action: String) async throws {
            guard let brew = brewBinary() else {
                throw HomebrewServiceError.brewMissing
            }
            let result = try await executor.run(
                executable: brew,
                arguments: ["services", action, "mimi-remote"],
                timeout: .seconds(20),
                environment: environment
            )
            guard result.status == 0 else {
                throw HomebrewServiceError.commandFailed(
                    result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        return HomebrewServiceClient(
            isLoaded: {
                let target = "gui/\(getuid())/homebrew.mxcl.mimi-remote"
                guard let result = try? await executor.run(
                    executable: launchctl,
                    arguments: ["print", target],
                    timeout: .seconds(3),
                    outputLimit: 256 * 1024,
                    environment: environment
                ) else {
                    return false
                }
                return result.status == 0
            },
            installedAgentBinary: {
                for path in [
                    "/opt/homebrew/bin/agentd",
                    "/usr/local/bin/agentd",
                    "/opt/homebrew/opt/mimi-remote/bin/agentd",
                    "/usr/local/opt/mimi-remote/bin/agentd",
                ] where FileManager.default.isExecutableFile(atPath: path) {
                    return URL(filePath: path)
                }
                return nil
            },
            start: { try await runBrew("start") },
            stop: { try await runBrew("stop") }
        )
    }
}

enum HomebrewServiceError: LocalizedError {
    case brewMissing
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .brewMissing:
            "未找到 Homebrew，无法管理旧版 mimi-remote 服务。"
        case .commandFailed(let detail):
            detail.isEmpty ? "Homebrew 服务操作失败" : detail
        }
    }
}

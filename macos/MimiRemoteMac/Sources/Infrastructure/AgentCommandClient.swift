import Foundation

struct AgentCommandClient: Sendable {
    var configExists: @Sendable () -> Bool
    var setup: @Sendable (_ workspaceRoot: URL) async throws -> PairingInfo
    var status: @Sendable () async throws -> AgentStatus
    var statusAt: @Sendable (_ binary: URL) async throws -> AgentStatus
    var doctor: @Sendable (_ fix: Bool) async throws -> DoctorFixResults
    var configureClaude: @Sendable (
        _ preference: ClaudeActivationPreference,
        _ restoreEnabled: Bool?
    ) async throws -> ClaudeConfigurationResult
    var setLANAccess: @Sendable (_ enabled: Bool) async throws -> NetworkConfigurationResult
    var pair: @Sendable (_ network: PairingNetwork) async throws -> PairingInfo
    var tailcatStatus: @Sendable () async throws -> TailcatStatus = {
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 实验。")
    }
    var setTailcatEnabled: @Sendable (_ enabled: Bool) async throws -> TailcatStatus = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 实验。")
    }
    var configureTailcatDERPMap: @Sendable (_ derpMapURL: String) async throws -> TailcatStatus = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 中继配置。")
    }
    var resetTailcat: @Sendable () async throws -> TailcatStatus = {
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 实验。")
    }
    var version: @Sendable () async throws -> String
}

extension AgentCommandClient {
    static func live(
        executor: ProcessExecutor = .shared,
        bundle: Bundle = .main
    ) -> AgentCommandClient {
        let embeddedBinary = bundle.url(forResource: "agentd", withExtension: nil)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configURL = homeDirectory
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
            timeout: Duration = .seconds(15),
            forceKillAfterTimeout: Bool = false
        ) async throws -> CommandResult {
            let result = try await executor.run(
                executable: binary,
                arguments: arguments,
                timeout: timeout,
                environment: environment,
                forceKillAfterTimeout: forceKillAfterTimeout
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
                let result = try await execute(
                    binary: binary,
                    arguments: setupArguments(
                        workspaceRoot: workspaceRoot,
                        browseRoot: homeDirectory
                    )
                )
                return try decode(PairingInfo.self, from: result)
            },
            status: {
                let binary = try requireEmbeddedBinary()
                return try decode(AgentStatus.self, from: try await execute(
                    binary: binary,
                    arguments: statusArguments(includeRuntime: true),
                    timeout: .seconds(8)
                ))
            },
            statusAt: { binary in
                try decode(AgentStatus.self, from: try await execute(
                    binary: binary,
                    arguments: statusArguments(includeRuntime: false),
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
                    // Doctor --fix 可能等待服务诊断和配置提交，并在提交后重新跑
                    // 完整检查；给它覆盖事务上界的时间，避免配置已提交却因
                    // 客户端过早终止而漏掉 restart_required。
                    timeout: .seconds(90)
                )
                if fix {
                    return try decode(DoctorFixResults.self, from: result)
                }
                let results = try decode(AgentDoctorResults.self, from: result)
                return DoctorFixResults(fixes: [], results: results)
            },
            configureClaude: { preference, restoreEnabled in
                let binary = try requireEmbeddedBinary()
                return try decode(ClaudeConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: claudeConfigurationArguments(
                        preference: preference,
                        restoreEnabled: restoreEnabled
                    ),
                    timeout: .seconds(10)
                ))
            },
            setLANAccess: { enabled in
                let binary = try requireEmbeddedBinary()
                return try decode(NetworkConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: [
                        "network",
                        "--lan-enabled=\(enabled)",
                        "--json",
                    ]
                ))
            },
            pair: { network in
                let binary = try requireEmbeddedBinary()
                return try decode(PairingInfo.self, from: try await execute(
                    binary: binary,
                    arguments: pairArguments(network: network),
                    timeout: network == .tailcat ? .seconds(25) : .seconds(15)
                ))
            },
            tailcatStatus: {
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: "status"),
                    timeout: .seconds(8)
                ))
            },
            setTailcatEnabled: { enabled in
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: enabled ? "enable" : "disable"),
                    timeout: .seconds(25)
                ))
            },
            configureTailcatDERPMap: { derpMapURL in
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: "configure", derpMapURL: derpMapURL),
                    timeout: .seconds(55)
                ))
            },
            resetTailcat: {
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: "reset"),
                    timeout: .seconds(15)
                ))
            },
            version: {
                let binary = try requireEmbeddedBinary()
                let result = try await execute(binary: binary, arguments: ["version"])
                return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }

    static func setupArguments(workspaceRoot: URL, browseRoot: URL) -> [String] {
        [
            "setup", "--json", "--qr-only",
            // 项目发现只扫描用户选择的代码目录，避免遍历整个 Home。
            "--scan-root", workspaceRoot.path,
            // 文件预览和会话产物可能位于 ~/.codex 等目录，浏览权限默认覆盖当前用户 Home。
            "--browse-root", browseRoot.path,
        ]
    }

    static func statusArguments(includeRuntime: Bool) -> [String] {
        var arguments = ["status", "--json"]
        if includeRuntime {
            arguments.append("--runtime")
        }
        return arguments
    }

    static func claudeConfigurationArguments(
        preference: ClaudeActivationPreference,
        restoreEnabled: Bool? = nil
    ) -> [String] {
        var arguments = [
            "runtime",
            "--claude=\(preference.rawValue)",
            "--json",
        ]
        if let restoreEnabled {
            arguments.append("--restore-enabled=\(restoreEnabled)")
        }
        return arguments
    }

    static func pairArguments(network: PairingNetwork) -> [String] {
        if network == .tailcat {
            return ["tailcat", "pair", "--json", "--qr-only"]
        }
        return [
            "pair",
            "--network", network.rawValue,
            "--json",
            "--qr-only",
        ]
    }

    static func tailcatArguments(action: String, derpMapURL: String? = nil) -> [String] {
        var arguments = ["tailcat", action, "--json"]
        if let derpMapURL {
            arguments.append("--derp-map-url=\(derpMapURL)")
        }
        return arguments
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

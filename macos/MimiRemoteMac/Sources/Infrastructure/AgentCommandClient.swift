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
    var configureCodexSharing: @Sendable (
        _ enabled: Bool
    ) async throws -> CodexSharingConfigurationResult = { enabled in
        CodexSharingConfigurationResult(enabled: enabled)
    }
    var restartCodexSharing: @Sendable () async throws -> Void = {}
    var setLANAccess: @Sendable (_ enabled: Bool) async throws -> NetworkConfigurationResult
    var pair: @Sendable (_ network: PairingNetwork) async throws -> PairingInfo
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
                    // Doctor --fix 可能等待 daemon/config 两把跨进程锁，并在提交后
                    // 重新跑完整检查；给它覆盖事务上界的时间，避免配置已提交却因
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
            configureCodexSharing: { enabled in
                let binary = try requireEmbeddedBinary()
                return try decode(
                    CodexSharingConfigurationResult.self,
                    from: try await execute(
                        binary: binary,
                        arguments: codexSharingConfigurationArguments(enabled: enabled),
                        // 后端为 owner 安装、daemon 就绪和失败回滚预留 45 秒；
                        // 调用端必须更长，不能在事务清理完成前强杀子进程。
                        timeout: .seconds(50)
                    )
                )
            },
            restartCodexSharing: {
                let binary = try requireEmbeddedBinary()
                _ = try await execute(
                    binary: binary,
                    arguments: codexSharingRestartArguments(),
                    timeout: .seconds(50),
                    // 迁移的 agentd 是短命 control CLI；超时后只回收它本身，
                    // 不触碰共享 Codex daemon。其他通用命令保持普通 TERM 语义。
                    forceKillAfterTimeout: true
                )
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
                    arguments: [
                        "pair",
                        "--network", network.rawValue,
                        "--json",
                        "--qr-only",
                    ]
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

    static func codexSharingConfigurationArguments(enabled: Bool) -> [String] {
        [
            "runtime",
            "--codex-sharing=\(enabled ? "enabled" : "disabled")",
            "--json",
        ]
    }

    static func codexSharingRestartArguments() -> [String] {
        [
            "runtime",
            "--codex-sharing-restart",
            // 该 client 只会在设置页确认后的 HostStore 迁移闭包中调用；后端
            // 拒绝缺少此显式确认的普通 CLI，避免脚本误绕过 Desktop 退出顺序。
            "--codex-sharing-restart-confirmed",
        ]
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

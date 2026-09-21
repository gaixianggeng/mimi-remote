import Foundation

/// `agentd check-config` 的机器可判读结果。后台服务反复启动失败时，App 用它把
/// agentd 自己的启动错误显示出来，而不是继续猜测「服务记录过期」。
struct AgentdConfigCheckResult: Equatable, Sendable {
    /// 与 cmd/agentd/checkconfig.go 的约定：这份配置需要更新版本的 agentd。
    static let requiresNewerVersionCode = "config_requires_newer_version"

    let ok: Bool
    let code: String?
    let message: String?

    var requiresNewerVersion: Bool { code == Self.requiresNewerVersionCode }
}

/// 只读取包内 agentd 的判断，不注册、不注销、不写配置。
struct AgentdConfigCheckClient: Sendable {
    var check: @Sendable () async -> AgentdConfigCheckResult?
    var agentdURL: URL
}

extension AgentdConfigCheckClient {
    /// 无法调用包内 agentd 时使用：保留原有诊断，不引入新的失败路径。
    static let disabled = AgentdConfigCheckClient(check: { nil }, agentdURL: URL(filePath: "/"))

    static func live(
        bundle: Bundle = .main,
        executor: ProcessExecutor = .shared
    ) -> AgentdConfigCheckClient {
        let agentdURL = bundle.bundleURL.appending(
            path: AgentdSupervisorCommand.agentdRelativePath,
            directoryHint: .notDirectory
        )
        return AgentdConfigCheckClient(
            check: {
                // 与 supervisor 保持一致：不传 --config，让 agentd 自己解析默认配置路径，
                // 这样检查的就是 launchd 实际会读到的那一份。检查失败时 agentd 仍会把
                // JSON 写进 stdout 并以退出码 1 结束，所以只看 stdout 能否解析。
                guard let result = try? await executor.run(
                    executable: agentdURL,
                    arguments: ["check-config", "--json"],
                    timeout: .seconds(10),
                    outputLimit: 64 * 1024,
                    environment: ProcessEnvironment.userTooling
                ) else {
                    return nil
                }
                return decode(result.stdoutText)
            },
            agentdURL: agentdURL
        )
    }

    /// stdout 不是 JSON（旧包没有这个子命令、命令被截断等）时返回 nil，由调用方回退到
    /// 原有诊断，绝不把解析失败当成升级结论。
    static func decode(_ stdout: String) -> AgentdConfigCheckResult? {
        guard let data = stdout.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AgentdConfigCheckPayload.self, from: data)
        else {
            return nil
        }
        return AgentdConfigCheckResult(
            ok: payload.ok,
            code: payload.code,
            message: payload.message
        )
    }
}

private struct AgentdConfigCheckPayload: Decodable {
    let ok: Bool
    let code: String?
    let message: String?
}

import Foundation
import Security
import ServiceManagement

struct CodeSigningIdentity: Equatable, Sendable {
    let identifier: String?
    let teamIdentifier: String?
}

struct ServiceManagementClient {
    var agentStatus: @MainActor () -> ServiceRegistrationState
    var agentConfigurationError: @MainActor () -> String?
    var isAgentRegistrationCurrent: @MainActor () -> Bool
    var markAgentRegistrationCurrent: @MainActor () -> Void
    var registerAgent: @MainActor () throws -> Void
    var unregisterAgent: @MainActor () async throws -> Void
    /// launchd 是否正卡在反复拉起却启动不了 agentd 的循环里（例如覆盖安装后
    /// BTM 复用了旧 App 的 Launch Constraint）。返回非空即表示需要立即换代登记。
    var agentLaunchFailure: @MainActor () async -> String?
    var mainAppStatus: @MainActor () -> ServiceRegistrationState
    var registerMainApp: @MainActor () throws -> Void
    var unregisterMainApp: @MainActor () async throws -> Void
    var openLoginItemsSettings: @MainActor () -> Void
}

extension ServiceManagementClient {
    @MainActor
    static func live(executor: ProcessExecutor = .shared) -> ServiceManagementClient {
        let registrationRevision = currentAgentRegistrationRevision()
        let launchctl = URL(filePath: "/bin/launchctl")
        let environment = ProcessEnvironment.userTooling
        return ServiceManagementClient(
            agentStatus: {
                registrationState(for: agentService.status)
            },
            agentConfigurationError: {
                validateAgentConfiguration()
            },
            isAgentRegistrationCurrent: {
                guard let registrationRevision else { return true }
                return UserDefaults.standard.string(
                    forKey: agentRegistrationRevisionKey
                ) == registrationRevision
            },
            markAgentRegistrationCurrent: {
                guard let registrationRevision else { return }
                UserDefaults.standard.set(
                    registrationRevision,
                    forKey: agentRegistrationRevisionKey
                )
            },
            registerAgent: {
                let service = agentService
                if service.status != .enabled {
                    try service.register()
                }
            },
            unregisterAgent: {
                let service = agentService
                guard service.status != .notRegistered, service.status != .notFound else { return }
                // 使用异步 API 等待系统真正终止旧进程；回调完成后才可安全重新注册。
                try await service.unregister()
            },
            agentLaunchFailure: {
                // SMAppService 在 launchd 拉不起进程时仍报告 enabled，只有 launchd
                // 自己的 job 记录能看出 spawn 失败与重试次数。这里只读取，不改动。
                let target = "gui/\(getuid())/\(agentLabel)"
                guard let result = try? await executor.run(
                    executable: launchctl,
                    arguments: ["print", target],
                    timeout: .seconds(3),
                    outputLimit: 256 * 1024,
                    environment: environment
                ) else {
                    return nil
                }
                return launchFailureDescription(
                    fromLaunchctlOutput: result.stdoutText,
                    exitStatus: result.status
                )
            },
            mainAppStatus: {
                registrationState(for: SMAppService.mainApp.status)
            },
            registerMainApp: {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            },
            unregisterMainApp: {
                guard SMAppService.mainApp.status != .notRegistered,
                      SMAppService.mainApp.status != .notFound
                else { return }
                try await SMAppService.mainApp.unregister()
            },
            openLoginItemsSettings: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }

    @MainActor
    private static var agentService: SMAppService {
        SMAppService.agent(plistName: agentPlistName)
    }

    private static let agentRegistrationRevisionKey =
        "MimiRemoteMac.agentRegistrationRevision"

    private static let agentLabel = "com.gaixianggeng.mimi.mac.agentd"

    private static let agentPlistName = "\(agentLabel).plist"

    /// 解析 `launchctl print gui/<uid>/<label>` 的输出。只有 job 存在、当前没有
    /// 运行中的进程，且 launchd 已经至少重试过一次或记录了异常退出码时，才判定为
    /// “拉起失败循环”。正在运行（有 pid）或刚刚首次派生的 job 都返回 nil，避免把
    /// 正常的慢启动误判成失败。
    static func launchFailureDescription(
        fromLaunchctlOutput output: String,
        exitStatus: Int32 = 0
    ) -> String? {
        guard exitStatus == 0 else { return nil }
        var state: String?
        var pid: String?
        var runs: Int?
        var lastExitCode: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.range(of: " = ") else { continue }
            let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "state" where state == nil:
                // 顶层 job 的 state 先于内部 endpoint/子项出现，只取第一条。
                state = value
            case "pid" where pid == nil:
                pid = value
            case "runs" where runs == nil:
                runs = Int(value)
            case "last exit code" where lastExitCode == nil:
                lastExitCode = value
            default:
                continue
            }
        }
        guard state != nil || runs != nil || lastExitCode != nil else { return nil }
        if let pid, !pid.isEmpty, pid != "0" { return nil }
        if state == "running" { return nil }
        let neverExited = lastExitCode == nil || lastExitCode == "(never exited)"
        // launchctl 输出形如 `78`、`78: EX_CONFIG` 或 `0`。KeepAlive 服务有序退出后、
        // 下一次拉起前同样没有 pid；退出码 0 本身不算失败，只有反复拉起才算循环。
        let exitCode = lastExitCode.flatMap { value -> Int? in
            Int(value.prefix { $0 == "-" || $0.isNumber })
        }
        let abnormalExit = !neverExited && exitCode != 0
        let repeatedRuns = (runs ?? 0) >= 2
        guard repeatedRuns || abnormalExit else { return nil }
        var detail = "launchd 无法启动 agentd"
        if let runs, runs >= 2 {
            detail += "，已连续尝试 \(runs) 次"
        }
        if abnormalExit, let lastExitCode {
            detail += "，最近退出码 \(lastExitCode)"
        }
        if let state, !state.isEmpty {
            detail += "，当前状态 \(state)"
        }
        return detail
    }

    /// `.notFound` 只表示 ServiceManagement 没找到服务记录，不能据此判断安装包漏文件。
    /// 这里直接核对包内 plist 与 BundleProgram，只有资源真的损坏时才要求重新安装。
    static func validateAgentConfiguration(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        signingIdentityProvider: ((URL) -> CodeSigningIdentity?)? = nil
    ) -> String? {
        let plistURL = bundleURL
            .appending(path: "Contents/Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: agentPlistName, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: plistURL.path) else {
            return "App 包内缺少 LaunchAgent 配置，请重新安装正式版本。"
        }
        guard let data = try? Data(contentsOf: plistURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any],
              let bundleProgram = dictionary["BundleProgram"] as? String,
              !bundleProgram.isEmpty
        else {
            return "App 包内的 LaunchAgent 配置无效，请重新安装正式版本。"
        }

        let executableURL = bundleURL.appending(path: bundleProgram, directoryHint: .notDirectory)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            return "App 包内缺少可执行的 agentd，请重新安装正式版本。"
        }

        let identityProvider = signingIdentityProvider ?? codeSigningIdentity(at:)
        guard let appIdentity = identityProvider(bundleURL) else {
            return "无法读取 App 代码签名，不能注册 macOS 后台服务。请重新安装正式版本。"
        }
        guard let appTeam = appIdentity.teamIdentifier, !appTeam.isEmpty else {
            // ad-hoc 快照只验证包结构，没有 Team ID，无法安全接管已有的
            // ServiceManagement / BTM 记录；必须在任何注册或注销前明确阻止。
            return "当前 App 是未签名或 ad-hoc 结构快照，不能启动 macOS 后台服务。请安装正式包或同团队签名的开发验收包。"
        }
        guard appIdentity.identifier == "com.gaixianggeng.mimi.mac" else {
            return "App 代码签名标识不正确，不能注册 macOS 后台服务。请重新安装正式版本。"
        }
        guard let agentIdentity = identityProvider(executableURL),
              agentIdentity.identifier == "com.gaixianggeng.mimi.mac.agentd",
              let agentTeam = agentIdentity.teamIdentifier,
              !agentTeam.isEmpty
        else {
            return "agentd 代码签名无效，不能注册 macOS 后台服务。请重新安装正式版本。"
        }
        guard agentTeam == appTeam else {
            return "App 与 agentd 的签名团队不一致，不能注册 macOS 后台服务。请重新安装正式版本。"
        }
        return nil
    }

    /// 直接通过 Security.framework 读取签名身份，不启动 shell，也不依赖用户 PATH。
    private static func codeSigningIdentity(at url: URL) -> CodeSigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        guard SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let dictionary = signingInformation as? [String: Any]
        else {
            return nil
        }
        return CodeSigningIdentity(
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }

    /// SMAppService 不会自动刷新已登记的 LaunchAgent 可执行文件。正式发布的
    /// build number 每次都会递增，因此用 App 版本与构建号识别需要重新注册的升级。
    private static func currentAgentRegistrationRevision(
        bundle: Bundle = .main
    ) -> String? {
        guard let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              let build = bundle.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              !version.isEmpty,
              !build.isEmpty
        else {
            return nil
        }
        return "\(version)+\(build)"
    }

    @MainActor
    private static func registrationState(for status: SMAppService.Status) -> ServiceRegistrationState {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

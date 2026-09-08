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
    var mainAppStatus: @MainActor () -> ServiceRegistrationState
    var registerMainApp: @MainActor () throws -> Void
    var unregisterMainApp: @MainActor () async throws -> Void
    var openLoginItemsSettings: @MainActor () -> Void
}

extension ServiceManagementClient {
    @MainActor
    static var live: ServiceManagementClient {
        let registrationRevision = currentAgentRegistrationRevision()
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

    private static let agentPlistName = "com.gaixianggeng.mimi.mac.agentd.plist"

    static func installationLocationError(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        let location = bundleURL.resolvingSymlinksInPath()
        let isReadOnly = (try? location.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        // 隔离副本或 DMG 内的 App 不能作为持久后台服务的所有者。签名有效也不代表
        // 该位置可登记；先阻止接管，避免注销正在工作的服务后留下无效的启动约束。
        guard location.pathComponents.contains("AppTranslocation") || isReadOnly else { return nil }
        return "请退出此副本，在 Finder 中把 DMG 里的 Mimi Remote Mac 拖入「应用程序」并替换原 App，再从「应用程序」打开。"
    }

    /// `.notFound` 只表示 ServiceManagement 没找到服务记录，不能据此判断安装包漏文件。
    /// 这里直接核对包内 plist 与 BundleProgram，只有资源真的损坏时才要求重新安装。
    static func validateAgentConfiguration(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        signingIdentityProvider: ((URL) -> CodeSigningIdentity?)? = nil
    ) -> String? {
        if let error = installationLocationError(bundleURL: bundleURL) { return error }
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

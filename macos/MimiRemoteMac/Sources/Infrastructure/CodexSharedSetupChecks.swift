import AppKit
import Foundation
import Observation

/// 「让 Codex 桌面版接入 Mimi」三步的检查结果（#991, #376）。
struct CodexSharedSetupStatus: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case checking
        case done
        case todo

        var accessibilityStatusText: String {
            switch self {
            case .checking: "检查中"
            case .todo: "待完成"
            case .done: "已完成"
            }
        }
    }

    var remoteLogin: Step = .checking
    var passwordlessLogin: Step = .checking
    var desktopConnected: Step = .checking
    /// 桌面版没在运行，第 3 步无从判断。
    var desktopNotRunning = false
    /// 是否存在由 Mimi 一键写入的本机 SSH 托管配置（供显示「移除本机配置」入口）。
    var localSSHManaged = false
    /// 经归属与 `ssh -G` 核验的 Mimi 托管别名 `mimi-local` 已确认可用。
    var managedAliasReady = false
    /// 旧式裸 `127.0.0.1` 免密回环路径已验证可用（仅此时才在指引中提及 127.0.0.1）。
    var legacyLoopbackReady = false
    /// 用户 ~/.ssh/config 里已有自定义同名 Host 别名或相关冲突。
    var hasConflictingHostAlias = false

    var allDone: Bool {
        remoteLogin == .done && passwordlessLogin == .done && desktopConnected == .done
    }

    /// 桌面版已经经本机 SSH 连上，前两步必然已经做好，不再去试登录。
    static func make(
        desktop: CodexDesktopLink.Connection,
        remoteLogin: Bool,
        passwordless: Bool,
        localSSHManaged: Bool = false,
        managedAliasReady: Bool = false,
        legacyLoopbackReady: Bool = false,
        hasConflictingHostAlias: Bool = false
    ) -> Self {
        if desktop == .shared {
            return Self(
                remoteLogin: .done,
                passwordlessLogin: .done,
                desktopConnected: .done,
                localSSHManaged: localSSHManaged,
                managedAliasReady: managedAliasReady,
                legacyLoopbackReady: legacyLoopbackReady,
                hasConflictingHostAlias: hasConflictingHostAlias
            )
        }
        return Self(
            remoteLogin: remoteLogin ? .done : .todo,
            passwordlessLogin: remoteLogin && passwordless ? .done : .todo,
            desktopConnected: .todo,
            desktopNotRunning: desktop == .notRunning,
            localSSHManaged: localSSHManaged,
            managedAliasReady: remoteLogin && managedAliasReady,
            legacyLoopbackReady: remoteLogin && legacyLoopbackReady,
            hasConflictingHostAlias: hasConflictingHostAlias
        )
    }
}

/// 检查与本机 SSH 共享接入状态；不修改系统开关，只在用户显式点击一键配置时写入 `~/.ssh`。
enum CodexSharedSetupChecks {
    static let sharingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!

    /// 生成本机登录钥匙并允许自己登录自己。只追加一行公钥，已有就跳过；最后试登一次并记下本机的主机指纹。
    static let keySetupCommand = """
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
    touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    grep -qxF "$(cat ~/.ssh/id_ed25519.pub)" ~/.ssh/authorized_keys || cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new 127.0.0.1 true && echo "完成"
    """

    struct PasswordlessProbeResult: Equatable, Sendable {
        var managedAliasWorks: Bool = false
        var legacyLoopbackWorks: Bool = false

        var anyWorks: Bool { managedAliasWorks || legacyLoopbackWorks }
    }

    typealias TargetProber = @Sendable (_ target: String) async -> Bool

    /// 只有经 Mimi 归属核验且 `ssh -G` 确认为直连当前用户 127.0.0.1:22 的托管别名才允许探测 `mimi-local`。
    /// 冲突或未托管时绝不探测 `mimi-local`，避免误连用户的同名远端主机。
    static func passwordlessProbeTargets(managedAliasVerified: Bool) -> [String] {
        managedAliasVerified
            ? [CodexLocalSSHConfigurator.hostAlias, "127.0.0.1"]
            : ["127.0.0.1"]
    }

    @MainActor
    static func check() async -> CodexSharedSetupStatus {
        let inspection = await CodexLocalSSHConfigurator().inspect()
        let managedAliasVerified = inspection.isReady
        let desktop = await CodexDesktopLink.connection(includeManagedAlias: managedAliasVerified)
        if desktop == .shared {
            return .make(
                desktop: desktop,
                remoteLogin: true,
                passwordless: true,
                localSSHManaged: inspection.isManaged,
                managedAliasReady: managedAliasVerified,
                legacyLoopbackReady: !managedAliasVerified,
                hasConflictingHostAlias: inspection.hasAnyConflict
            )
        }
        let remoteLogin = await remoteLoginEnabled()
        let probeResult = remoteLogin
            ? await probePasswordlessLogin(managedAliasVerified: managedAliasVerified)
            : PasswordlessProbeResult()
        return .make(
            desktop: desktop,
            remoteLogin: remoteLogin,
            passwordless: probeResult.anyWorks,
            localSSHManaged: inspection.isManaged,
            managedAliasReady: managedAliasVerified && probeResult.managedAliasWorks,
            legacyLoopbackReady: probeResult.legacyLoopbackWorks,
            hasConflictingHostAlias: inspection.hasAnyConflict
        )
    }

    /// 「远程登录」打开时本机 22 端口有人监听。
    static func remoteLoginEnabled() async -> Bool {
        let result = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/nc"),
            arguments: ["-z", "-G", "2", "127.0.0.1", "22"],
            timeout: .seconds(5)
        )
        return result?.status == 0
    }

    static func probePasswordlessLogin(
        managedAliasVerified: Bool,
        prober: TargetProber = defaultTargetProber
    ) async -> PasswordlessProbeResult {
        let targets = passwordlessProbeTargets(managedAliasVerified: managedAliasVerified)
        var outcome = PasswordlessProbeResult()
        for target in targets {
            let ok = await prober(target)
            if ok {
                if target == CodexLocalSSHConfigurator.hostAlias {
                    outcome.managedAliasWorks = true
                    return outcome
                } else {
                    outcome.legacyLoopbackWorks = true
                    return outcome
                }
            }
        }
        return outcome
    }

    /// 构造直连当前用户本机回环 22 端口的只读探测参数：
    /// 绑定到刚经 `ssh -G` 核验的冻结配置快照（保留桌面版实际认证与信任输入），禁用主机密钥更新（`UpdateHostKeys=no`）与自动写入（`StrictHostKeyChecking=yes`），并执行双向 stdin/stdout 探测。
    static func buildDirectLoopbackProbeArguments(
        for target: String,
        username: String,
        configPath: String? = nil,
        hostName: String = "127.0.0.1"
    ) -> [String] {
        var args: [String] = []
        if let configPath, !configPath.isEmpty {
            args.append(contentsOf: ["-F", configPath])
        }
        args.append(contentsOf: [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "HostName=\(hostName)",
            "-o", "Port=22",
            "-o", "User=\(username)",
            "-o", "ProxyJump=none",
            "-o", "ProxyCommand=none",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "CanonicalizeHostname=no",
            "-o", "PermitLocalCommand=no",
            "-o", "RemoteCommand=none",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no",
            "-o", "RequestTTY=no",
            "-o", "SessionType=default",
            "-o", "ForkAfterAuthentication=no",
            "-o", "ConnectTimeout=5",
            target,
            "/bin/cat",
        ])
        return args
    }

    static func defaultTargetProber(target: String) async -> Bool {
        let currentUser = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentUser.isEmpty else { return false }

        let configurator = CodexLocalSSHConfigurator(username: currentUser)
        // 冻结桌面版当前真实配置（~/.ssh/config + 系统 ssh_config 含相对 Include），确保 ssh -G 与实际探测使用同一份认证与信任输入。
        guard let materialized = try? configurator.materializeCurrentSSHConfigForEvaluation(includeSystemConfig: true) else {
            return false
        }
        defer { materialized.cleanup() }

        guard let effective = try? await configurator.resolveEffectiveSSHConfig(
            configPath: materialized.configFileURL.path,
            alias: target,
            includeSystemConfig: false
        ) else {
            return false
        }

        if target == CodexLocalSSHConfigurator.hostAlias {
            guard CodexLocalSSHConfigurator.validateEffectiveLoopbackConfig(
                effective,
                expectedUser: currentUser,
                expectedIdentityFile: configurator.expectedIdentityFileConfigValue,
                expectedKnownHostsFile: configurator.expectedKnownHostsPath
            ) == nil else {
                return false
            }
        } else {
            // 校验真实桌面配置下 127.0.0.1 的路由、认证与双向传输选项均可用，不再改用 -F /dev/null 验证另一套身份和信任设置。
            guard CodexLocalSSHConfigurator.isDirectLoopbackConfig(effective, expectedUser: currentUser) else {
                return false
            }
        }

        let resolvedHostName = effective.hostname?.lowercased() == "::1" ? "::1" : "127.0.0.1"
        let arguments = buildDirectLoopbackProbeArguments(
            for: target,
            username: currentUser,
            configPath: materialized.configFileURL.path,
            hostName: resolvedHostName
        )
        let probePayload = Data("mimi-ssh-probe-\(UUID().uuidString)\n".utf8)
        let result = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            timeout: .seconds(10),
            forceKillAfterTimeout: true,
            standardInput: probePayload
        )
        return result?.status == 0 && result?.stdout == probePayload
    }

    static func passwordlessLoginWorks(managedAliasVerified: Bool = false) async -> Bool {
        await probePasswordlessLogin(managedAliasVerified: managedAliasVerified).anyWorks
    }
}

/// 跨「菜单栏独立窗口」与「会话窗口弹窗」共享的向导状态协调器（#376）。
/// 统一串行化配置/撤销操作、丢弃乱序的旧检查结果，避免双入口并发写盘或旧快照覆盖错误提示。
@MainActor
@Observable
final class CodexSharedSetupCoordinator {
    static let shared = CodexSharedSetupCoordinator()

    var status = CodexSharedSetupStatus()
    var isChecking = false
    var isConfiguringSSH = false
    var isRemovingSSH = false
    var actionError: String?
    var desktopOpenFeedback: String?
    var desktopOpenFeedbackIsError = false

    var isMutating: Bool { isConfiguringSSH || isRemovingSSH }

    private let checker: @MainActor () async -> CodexSharedSetupStatus
    private let configureSSH: @Sendable () async throws -> Void
    private let removeSSH: @Sendable () async throws -> Void
    private let openDesktopSettings: @MainActor (_ preferSSHSubpage: Bool) async -> CodexDesktopLink.OpenSettingsResult
    private let sharedSeenSetter: @MainActor (Bool) -> Void

    private var checkGeneration: UInt64 = 0
    private var activeCheckTask: Task<Void, Never>?

    init(
        checker: @escaping @MainActor () async -> CodexSharedSetupStatus = { await CodexSharedSetupChecks.check() },
        configureSSH: @escaping @Sendable () async throws -> Void = { try await CodexLocalSSHConfigurator().configure() },
        removeSSH: @escaping @Sendable () async throws -> Void = { try await CodexLocalSSHConfigurator().remove() },
        openDesktopSettings: @escaping @MainActor (_ preferSSHSubpage: Bool) async -> CodexDesktopLink.OpenSettingsResult = {
            await CodexDesktopLink.openSSHSettings(preferSSHSubpage: $0)
        },
        sharedSeenSetter: @escaping @MainActor (Bool) -> Void = {
            UserDefaults.standard.set($0, forKey: "sessions.codexDesktopSharedSeen")
        }
    ) {
        self.checker = checker
        self.configureSSH = configureSSH
        self.removeSSH = removeSSH
        self.openDesktopSettings = openDesktopSettings
        self.sharedSeenSetter = sharedSeenSetter
    }

    /// 发起一次新检查并取代任何未完成的旧检查；旧检查即便晚返回也会被丢弃。
    func refresh(clearErrorWhenAllDone: Bool = true) async {
        activeCheckTask?.cancel()
        checkGeneration &+= 1
        let generation = checkGeneration
        isChecking = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let nextStatus = await self.checker()
            guard !Task.isCancelled, self.checkGeneration == generation else { return }
            self.status = nextStatus
            self.isChecking = false
            if nextStatus.allDone {
                self.sharedSeenSetter(true)
                if clearErrorWhenAllDone {
                    self.actionError = nil
                }
            }
        }
        activeCheckTask = task
        await task.value
        if checkGeneration == generation {
            isChecking = false
        }
    }

    func runOneClickSSHSetup() async {
        guard !isMutating else { return }
        activeCheckTask?.cancel()
        checkGeneration &+= 1
        isChecking = false
        isConfiguringSSH = true
        actionError = nil
        desktopOpenFeedback = nil
        desktopOpenFeedbackIsError = false
        defer { isConfiguringSSH = false }

        do {
            try await configureSSH()
            await refresh(clearErrorWhenAllDone: true)
        } catch {
            actionError = error.localizedDescription
            await refresh(clearErrorWhenAllDone: false)
        }
    }

    func runRemoveSSHSetup() async {
        guard !isMutating else { return }
        activeCheckTask?.cancel()
        checkGeneration &+= 1
        isChecking = false
        isRemovingSSH = true
        actionError = nil
        desktopOpenFeedback = nil
        desktopOpenFeedbackIsError = false
        defer { isRemovingSSH = false }

        do {
            try await removeSSH()
            sharedSeenSetter(false)
            await refresh(clearErrorWhenAllDone: true)
        } catch {
            actionError = error.localizedDescription
            // 撤销出错时绝不能被后续状态检查把错误清掉。
            await refresh(clearErrorWhenAllDone: false)
        }
    }

    func openCodexSSHSettings() async {
        let preferSSHSubpage = status.managedAliasReady
        let result = await openDesktopSettings(preferSSHSubpage)
        desktopOpenFeedback = result.feedbackMessage
        desktopOpenFeedbackIsError = result.isFailure
    }
}

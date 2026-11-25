import AppKit
import Foundation

/// 「让 Codex 桌面版接入 Mimi」三步的检查结果（#991）。
struct CodexSharedSetupStatus: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case checking
        case done
        case todo
    }

    var remoteLogin: Step = .checking
    var passwordlessLogin: Step = .checking
    var desktopConnected: Step = .checking
    /// 桌面版没在运行，第 3 步无从判断。
    var desktopNotRunning = false
    /// 是否存在由 Mimi 一键写入的本机 SSH 托管配置（供显示「移除本机配置」入口）。
    var localSSHManaged = false
    /// 用户 ~/.ssh/config 里已有自定义同名 Host 别名。
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
        hasConflictingHostAlias: Bool = false
    ) -> Self {
        if desktop == .shared {
            return Self(
                remoteLogin: .done,
                passwordlessLogin: .done,
                desktopConnected: .done,
                localSSHManaged: localSSHManaged,
                hasConflictingHostAlias: hasConflictingHostAlias
            )
        }
        return Self(
            remoteLogin: remoteLogin ? .done : .todo,
            passwordlessLogin: remoteLogin && passwordless ? .done : .todo,
            desktopConnected: .todo,
            desktopNotRunning: desktop == .notRunning,
            localSSHManaged: localSSHManaged,
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

    @MainActor
    static func check() async -> CodexSharedSetupStatus {
        let inspection = CodexLocalSSHConfigurator().inspect()
        let desktop = await CodexDesktopLink.connection()
        if desktop == .shared {
            return .make(
                desktop: desktop,
                remoteLogin: true,
                passwordless: true,
                localSSHManaged: inspection.isManaged,
                hasConflictingHostAlias: inspection.hasConflictingHostAlias
            )
        }
        let remoteLogin = await remoteLoginEnabled()
        let passwordless = remoteLogin ? await passwordlessLoginWorks(prefersManagedAlias: inspection.isReady) : false
        return .make(
            desktop: desktop,
            remoteLogin: remoteLogin,
            passwordless: passwordless,
            localSSHManaged: inspection.isManaged,
            hasConflictingHostAlias: inspection.hasConflictingHostAlias
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

    /// 与 Codex 桌面版相同的条件：不能弹密码或指纹确认。兼容新的一键别名 `mimi-local` 与已有 `127.0.0.1`。
    static func passwordlessLoginWorks(prefersManagedAlias: Bool = false) async -> Bool {
        let targets = prefersManagedAlias
            ? [CodexLocalSSHConfigurator.hostAlias, "127.0.0.1"]
            : ["127.0.0.1", CodexLocalSSHConfigurator.hostAlias]
        for target in targets {
            let result = try? await ProcessExecutor.shared.run(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", target, "true"],
                timeout: .seconds(10),
                forceKillAfterTimeout: true
            )
            if result?.status == 0 {
                return true
            }
        }
        return false
    }
}

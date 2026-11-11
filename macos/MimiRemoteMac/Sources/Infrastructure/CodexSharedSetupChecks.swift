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

    var allDone: Bool {
        remoteLogin == .done && passwordlessLogin == .done && desktopConnected == .done
    }

    /// 桌面版已经经本机 SSH 连上，前两步必然已经做好，不再去试登录。
    static func make(desktop: CodexDesktopLink.Connection, remoteLogin: Bool, passwordless: Bool) -> Self {
        if desktop == .shared {
            return Self(remoteLogin: .done, passwordlessLogin: .done, desktopConnected: .done)
        }
        return Self(
            remoteLogin: remoteLogin ? .done : .todo,
            passwordlessLogin: remoteLogin && passwordless ? .done : .todo,
            desktopConnected: .todo,
            desktopNotRunning: desktop == .notRunning
        )
    }
}

/// 只读检查，不改系统设置，也不写 SSH 配置。
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
        let desktop = await CodexDesktopLink.connection()
        if desktop == .shared {
            return .make(desktop: desktop, remoteLogin: true, passwordless: true)
        }
        let remoteLogin = await remoteLoginEnabled()
        let passwordless = remoteLogin ? await passwordlessLoginWorks() : false
        return .make(desktop: desktop, remoteLogin: remoteLogin, passwordless: passwordless)
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

    /// 与 Codex 桌面版相同的条件：不能弹密码或指纹确认。
    static func passwordlessLoginWorks() async -> Bool {
        let result = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "127.0.0.1", "true"],
            timeout: .seconds(10),
            forceKillAfterTimeout: true
        )
        return result?.status == 0
    }
}

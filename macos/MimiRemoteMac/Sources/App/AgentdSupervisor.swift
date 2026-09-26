import Darwin
import Foundation
import Security

// macOS 隐私授权（TCC）按"责任进程"判定：launchd 直接拉起的裸 agentd 没有 Info.plist，
// 既弹不出授权框，也拿不到"照片"这类只能由 App 申请的权限。LaunchAgent 改为启动
// Mimi Remote Mac 主可执行文件的 supervisor 模式，由它 posix_spawn 包内 agentd 并常驻
// 等待；agentd、它启动的 Codex resident 与 Claude bridge 都沿责任链继承主 App 的授权。
// supervisor 不能 exec 成 agentd：exec 后同一 pid 的代码身份变成 agentd，责任主体随之丢失。

enum AgentdSupervisorInvocation {
    static let flag = "--agentd-supervisor"

    static func matches(_ arguments: [String]) -> Bool {
        arguments.count == 2 && arguments[1] == flag
    }

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(flag)
    }
}

/// launchd 前门以 inetd Wait=true 启动主可执行文件：监听 socket 位于 fd 0-2，原样交给包内
/// agentd。与 supervisor 一样由主 App 承接 TCC 责任，前门启动的 Codex 后端因此继承同一授权。
/// 只接受 `--codex-front-door`，或额外带一个绝对路径的 `--config`（隔离验证用）。
enum CodexFrontDoorInvocation {
    static let flag = "--codex-front-door"

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    enum Configuration: Equatable {
        case standard
        case explicit(String)

        var path: String? {
            if case let .explicit(path) = self { return path }
            return nil
        }
    }

    /// 返回 nil 表示用法错误。
    static func configuration(_ arguments: [String]) -> Configuration? {
        switch arguments.count {
        case 2 where arguments[1] == flag:
            return .standard
        case 4 where arguments[1] == flag && arguments[2] == "--config" && arguments[3].hasPrefix("/"):
            return .explicit(arguments[3])
        default:
            return nil
        }
    }
}

struct AgentdSupervisorCommand: Equatable {
    static let agentdRelativePath = "Contents/Resources/agentd"

    let executableURL: URL
    let arguments: [String]

    static func fixed(bundleURL: URL, homeDirectoryURL: URL) -> Self {
        let executableURL = bundleURL.appending(
            path: agentdRelativePath,
            directoryHint: .notDirectory
        )
        let logURL = homeDirectoryURL.appending(
            path: "Library/Logs/mimi-remote/agentd.log",
            directoryHint: .notDirectory
        )
        return Self(
            executableURL: executableURL,
            arguments: [executableURL.path, "serve", "--log-file", logURL.path]
        )
    }

    static func frontDoor(bundleURL: URL, homeDirectoryURL: URL, configPath: String?) -> Self {
        let executableURL = bundleURL.appending(
            path: agentdRelativePath,
            directoryHint: .notDirectory
        )
        let logURL = homeDirectoryURL.appending(
            path: "Library/Logs/mimi-remote/codex-front.log",
            directoryHint: .notDirectory
        )
        var arguments = [executableURL.path, "codex-front", "serve", "--log-file", logURL.path]
        if let configPath {
            arguments += ["--config", configPath]
        }
        return Self(executableURL: executableURL, arguments: arguments)
    }
}

enum AgentdSupervisorEnvironment {
    static let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// agentd 据此把权限提示指向 Mimi Remote Mac，而不是让用户去给裸 agentd 授权。
    /// 该值只影响提示文案，不参与任何授权判断。
    static let tccOwnerKey = "MIMI_REMOTE_TCC_OWNER"
    static let tccOwnerValue = "com.gaixianggeng.mimi.mac"
    private static let inheritedKeys = [
        "SSH_AUTH_SOCK",
        "LANG",
        "LC_ALL",
        "TERM",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "NODE_EXTRA_CA_CERTS",
        "CLAUDE_CODE_CERT_STORE",
        // 前门固定安装时的后端目录；配置漂移时 agentd 必须拒绝悄悄切换历史。
        "MIMI_CODEX_FRONT_BACKEND_HOME",
    ]

    static func sanitized(
        homeDirectory: String,
        temporaryDirectory: String,
        userName: String,
        shell: String,
        parentEnvironment: [String: String]
    ) -> [String] {
        var environment = [
            "HOME=\(homeDirectory)",
            "PATH=\(path)",
            "TMPDIR=\(temporaryDirectory)",
            "USER=\(userName)",
            "LOGNAME=\(userName)",
            "SHELL=\(shell)",
            "\(tccOwnerKey)=\(tccOwnerValue)",
        ]
        environment.append(contentsOf: inheritedKeys.compactMap { key in
            guard let value = parentEnvironment[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        })
        return environment
    }
}

final class AgentdSupervisorSignalRelay: @unchecked Sendable {
    typealias SignalSender = @Sendable (pid_t, Int32) -> Void

    private let lock = NSLock()
    private let signalSender: SignalSender
    private var childPID: pid_t?
    private var firstTerminationSignal: Int32?
    private var sources: [DispatchSourceSignal] = []

    init(
        installSystemSignals: Bool = true,
        signalSender: @escaping SignalSender = { pid, signalNumber in
            _ = kill(pid, signalNumber)
        }
    ) {
        self.signalSender = signalSender
        guard installSystemSignals else { return }

        let forwardedSignals = [SIGTERM, SIGINT, SIGHUP]
        // 必须先接管全部终止信号，再创建暂停的子进程。否则 supervisor 在验签窗口退出时，
        // launchd 会遗留一个无人恢复和回收的 suspended agentd。
        forwardedSignals.forEach { signal($0, SIG_IGN) }
        sources = forwardedSignals.map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in
                self?.receive(signalNumber)
            }
            source.resume()
            return source
        }
    }

    /// 返回 attach 前已经收到的终止信号。此时直接杀死暂停子进程，不能让它开始执行。
    func attach(childPID: pid_t) -> Int32? {
        lock.lock()
        self.childPID = childPID
        let pendingSignal = firstTerminationSignal
        lock.unlock()
        if pendingSignal != nil {
            signalSender(childPID, SIGKILL)
        }
        return pendingSignal
    }

    func detach(childPID: pid_t) {
        lock.lock()
        if self.childPID == childPID {
            self.childPID = nil
        }
        lock.unlock()
    }

    var receivedTerminationSignal: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return firstTerminationSignal
    }

    func receive(_ signalNumber: Int32) {
        lock.lock()
        if firstTerminationSignal == nil {
            firstTerminationSignal = signalNumber
        }
        let pid = childPID
        lock.unlock()
        if let pid {
            signalSender(pid, signalNumber)
        }
    }
}

enum AgentdSupervisor {
    static let agentIdentifier = "com.gaixianggeng.mimi.mac.agentd"

    static func run(
        bundleURL: URL = Bundle.main.bundleURL,
        command makeCommand: (URL, URL) -> AgentdSupervisorCommand = AgentdSupervisorCommand.fixed
    ) -> Int32 {
        let account = currentAccount()
        let homeDirectoryURL = URL(fileURLWithPath: account.homeDirectory)
        let command = makeCommand(bundleURL, homeDirectoryURL)
        guard let appIdentity = ServiceManagementClient.codeSigningIdentity(at: bundleURL),
              appIdentity.identifier == "com.gaixianggeng.mimi.mac",
              let teamIdentifier = appIdentity.teamIdentifier,
              !teamIdentifier.isEmpty,
              validateAgentd(at: command.executableURL, teamIdentifier: teamIdentifier)
        else {
            return EX_CONFIG
        }

        let signalRelay = AgentdSupervisorSignalRelay()

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return EX_OSERR }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGHUP)
        // supervisor 为 DispatchSource 忽略信号，但 agentd 必须恢复默认处置，才能被可靠终止。
        guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSIGDEF)
              ) == 0
        else {
            return EX_OSERR
        }

        var childPID = pid_t()
        let spawnStatus = command.executableURL.path.withCString { executablePath in
            withCStringArray(command.arguments) { argv in
                withCStringArray(sanitizedEnvironment()) { environment in
                    argv.withUnsafeBufferPointer { argvBuffer in
                        environment.withUnsafeBufferPointer { environmentBuffer in
                            posix_spawn(
                                &childPID,
                                executablePath,
                                nil,
                                &attributes,
                                argvBuffer.baseAddress,
                                environmentBuffer.baseAddress
                            )
                        }
                    }
                }
            }
        }
        guard spawnStatus == 0 else { return EX_OSERR }

        if let pendingSignal = signalRelay.attach(childPID: childPID) {
            _ = waitForChild(childPID)
            signalRelay.detach(childPID: childPID)
            return 128 + pendingSignal
        }

        // 子进程保持暂停，按实际 PID 再校验一次，避免磁盘校验与 exec 之间的替换窗口。
        guard validateRunningAgentd(pid: childPID, teamIdentifier: teamIdentifier) else {
            kill(childPID, SIGKILL)
            _ = waitForChild(childPID)
            signalRelay.detach(childPID: childPID)
            if let terminationSignal = signalRelay.receivedTerminationSignal {
                return 128 + terminationSignal
            }
            return EX_NOPERM
        }

        // DispatchSource 可能在 attach 后才交付先前收到的信号；继续执行前再检查一次。
        if let terminationSignal = signalRelay.receivedTerminationSignal {
            kill(childPID, SIGKILL)
            _ = waitForChild(childPID)
            signalRelay.detach(childPID: childPID)
            return 128 + terminationSignal
        }
        guard kill(childPID, SIGCONT) == 0 else {
            kill(childPID, SIGKILL)
            _ = waitForChild(childPID)
            signalRelay.detach(childPID: childPID)
            if let terminationSignal = signalRelay.receivedTerminationSignal {
                return 128 + terminationSignal
            }
            return EX_OSERR
        }
        let result = withExtendedLifetime(signalRelay) {
            waitForChild(childPID)
        }
        signalRelay.detach(childPID: childPID)
        return result
    }

    static func validateAgentd(
        at url: URL,
        teamIdentifier: String,
        fileManager: FileManager = .default,
        identityProvider: ((URL) -> CodeSigningIdentity?)? = nil
    ) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              fileManager.isExecutableFile(atPath: url.path)
        else {
            return false
        }
        let identity = (identityProvider ?? ServiceManagementClient.codeSigningIdentity(at:))(url)
        return identity?.identifier == agentIdentifier
            && identity?.teamIdentifier == teamIdentifier
    }

    static func exitCode(forWaitStatus status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + terminationSignal
    }

    private static func validateRunningAgentd(pid: pid_t, teamIdentifier: String) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            return false
        }
        let requirementText = "anchor apple generic and identifier \"\(agentIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement
        else {
            return false
        }
        return SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }

    private static func waitForChild(_ childPID: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) == -1 {
            if errno != EINTR { return EX_OSERR }
        }
        return exitCode(forWaitStatus: status)
    }

    private static func sanitizedEnvironment() -> [String] {
        let account = currentAccount()
        var temporaryDirectoryBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let temporaryDirectoryLength = confstr(
            _CS_DARWIN_USER_TEMP_DIR,
            &temporaryDirectoryBuffer,
            temporaryDirectoryBuffer.count
        )
        let temporaryDirectory = temporaryDirectoryLength > 0
            ? String(cString: temporaryDirectoryBuffer)
            : "/tmp/"
        return AgentdSupervisorEnvironment.sanitized(
            homeDirectory: account.homeDirectory,
            temporaryDirectory: temporaryDirectory,
            userName: account.userName,
            shell: account.shell,
            parentEnvironment: ProcessInfo.processInfo.environment
        )
    }

    private static func currentAccount() -> (homeDirectory: String, userName: String, shell: String) {
        guard let passwordEntry = getpwuid(getuid())?.pointee else {
            return (
                FileManager.default.homeDirectoryForCurrentUser.path,
                NSUserName(),
                "/bin/zsh"
            )
        }
        return (
            String(cString: passwordEntry.pw_dir),
            String(cString: passwordEntry.pw_name),
            String(cString: passwordEntry.pw_shell)
        )
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: ([UnsafeMutablePointer<CChar>?]) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        return body(pointers + [nil])
    }
}

import Darwin
import Foundation
import Security

/// Mimi App 主可执行文件的第二个入口：无 UI，只作为共享 Codex daemon 的 TCC 责任进程。
///
/// 为什么需要它：macOS 的 TCC 授权按“责任进程”记账，launchd 直接拉起的裸二进制责任
/// 进程就是它自己。OpenAI 的 node/codex 没有 Info.plist，永远弹不出授权框，也就拿不到
/// 照片图库这类需要显式授权的域。把 App bundle 主可执行文件放在链条最上层后，责任进程
/// 变成 com.gaixianggeng.mimi.mac——它能弹窗、按 bundle ID 记账，授权再沿进程链继承给
/// node 与 codex。Go 侧 shared_daemon_responsible_darwin.go 有完整背景。
enum CodexDaemonSupervisorInvocation {
    /// 必须与 Go 侧 sharedDaemonResponsibleSupervisorFlag 完全一致。
    static let flag = "--codex-daemon-supervisor"

    struct Command: Equatable {
        var node: String
        var codex: String
    }

    /// 只接受“旗标 + node 绝对路径 + codex 绝对路径”这一种形态。多一个参数都拒绝：
    /// 参数面越窄，能借责任进程做的事越少。
    static func parse(_ arguments: [String]) -> Command? {
        guard arguments.count == 4, arguments[1] == flag else { return nil }
        let node = arguments[2]
        let codex = arguments[3]
        guard node.hasPrefix("/"), codex.hasPrefix("/") else { return nil }
        return Command(node: node, codex: codex)
    }
}

enum CodexDaemonSupervisorError: Error, Equatable {
    case notInsideDesktopBundle(String)
    case bundleMismatch
    case helperMissing(String)
    case signatureRejected(String)
    case stagingFailed(String)
    case spawnFailed(String)

    var message: String {
        switch self {
        case .notInsideDesktopBundle(let name): "\(name) 不在 Codex Desktop App bundle 内"
        case .bundleMismatch: "node 与 codex 不属于同一个 Codex Desktop App bundle"
        case .helperMissing(let path): "Codex Desktop bundle 缺少可用的 codex-code-mode-host：\(path)"
        case .signatureRejected(let name): "\(name) 不是受支持的 OpenAI 签名程序"
        case .stagingFailed(let detail): "准备一次性共享 daemon 程序失败：\(detail)"
        case .spawnFailed(let detail): "拉起共享 daemon 失败：\(detail)"
        }
    }
}

enum CodexDaemonSupervisorValidation: Equatable {
    case accepted(CodexDaemonSupervisorInvocation.Command)
    case rejected(CodexDaemonSupervisorError)
}

struct CodexDaemonSupervisorStaging {
    let directory: URL
    let node: String
    let codex: String
    let codeModeHost: String

    func remove() {
        _ = chmod(directory.path, S_IRWXU)
        try? FileManager.default.removeItem(at: directory)
    }
}

enum CodexDaemonSupervisor {
    /// OpenAI 的 Developer ID Team。与 Go 侧 sharedDaemonOpenAITeamIdentifier 一致。
    static let openAITeamIdentifier = "2DC432GLL2"
    static let nodeSigningIdentifier = "node"
    static let codexSigningIdentifier = "codex"
    static let codeModeHostSigningIdentifier = "codex-code-mode-host"
    private static let codeModeHostFilename = "codex-code-mode-host"
    static let stagedCodexEnvironmentKey = "MIMI_REMOTE_PINNED_CODEX_PATH"
    private static let strippedEnvironmentKeys: Set<String> = [
        "CODEX_APP_SERVER_USE_LOCAL_DAEMON",
        "CODEX_APP_SERVER_WS_URL",
        "MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH",
    ]

    /// node supervisor 脚本必须与 Go 侧 sharedDaemonNodeSupervisorScript 逐字一致：
    /// Go 在运行态会按这份正文校验 node 进程的命令行。这里保留独立副本而不是从命令行
    /// 接收，是因为脚本正文一旦可注入，任何同用户进程都能借 Mimi 的 TCC 授权执行任意
    /// JS，责任进程就成了权限旁路 gadget。两侧漂移由 Go 测试读取本文件比对拦截。
    static let nodeSupervisorScript = "'use strict';"
        + "const{spawn}=require('node:child_process');"
        + "const argv=process.argv.slice(1);"
        + "const staged=process.env.MIMI_REMOTE_PINNED_CODEX_PATH;"
        + "delete process.env.MIMI_REMOTE_PINNED_CODEX_PATH;"
        + "if(argv.length<4||!staged)process.exit(64);"
        + "const child=spawn(staged,argv.slice(1),{argv0:argv[0],detached:false,env:process.env,stdio:'inherit'});"
        + "for(const signal of['SIGTERM','SIGINT','SIGHUP'])process.on(signal,()=>{"
        + "if(child.exitCode===null&&child.signalCode===null)child.kill(signal);"
        + "});"
        + "child.once('error',()=>process.exit(70));"
        + "child.once('exit',(code,signal)=>{process.exitCode=Number.isInteger(code)?code:(signal?1:70);});"

    /// node 进程真正的 argv。Go 侧 validateSharedDaemonNodeSupervisorProcess 按同一形态验收。
    static func childArguments(node: String, codex: String) -> [String] {
        [node, "-e", nodeSupervisorScript, "--", codex, "app-server", "--listen", "unix://"]
    }

    /// 校验 node 与 codex 确实是同一个 Codex Desktop bundle 内的 OpenAI 签名程序。
    /// 先做路径形态判断再验签：形态不符时不必付出 codesign 子进程的代价。
    static func validate(
        _ command: CodexDaemonSupervisorInvocation.Command,
        verifySignature: (String, String) -> Bool = verifyOpenAISignature
    ) -> CodexDaemonSupervisorValidation {
        let node = URL(fileURLWithPath: command.node).resolvingSymlinksInPath().path
        let codex = URL(fileURLWithPath: command.codex).resolvingSymlinksInPath().path
        guard let nodeBundle = desktopBundle(forNode: node) else {
            return .rejected(.notInsideDesktopBundle("node supervisor"))
        }
        guard codex == nodeBundle + "/Contents/Resources/codex" else {
            let failure: CodexDaemonSupervisorError = codex.hasSuffix("/Contents/Resources/codex")
                ? .bundleMismatch
                : .notInsideDesktopBundle("Codex app-server")
            return .rejected(failure)
        }
        guard verifySignature(node, nodeSigningIdentifier) else {
            return .rejected(.signatureRejected("node supervisor"))
        }
        guard verifySignature(codex, codexSigningIdentifier) else {
            return .rejected(.signatureRejected("Codex app-server"))
        }
        // 后续只能执行这里验签过的 canonical 路径，不能重新使用调用方给出的符号链接。
        return .accepted(.init(node: node, codex: codex))
    }

    /// supervisor 的命令行入口可被同用户进程直接调用，因此不能只依赖 Go 侧生成 plist
    /// 时的过滤。所有 NODE_ 控制面都删除，避免 Node 在固定 -e 脚本前加载外部代码；
    /// Desktop 专用传输变量也不得泄漏给共享 daemon。
    static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !key.hasPrefix("NODE_") && !strippedEnvironmentKeys.contains(key)
        }
    }

    /// 原始 Desktop App 位于当前用户可写的 /Applications 时，单纯“验签路径后再执行”
    /// 仍有替换窗口。先用 APFS clone 取得独立 inode，再对真正将执行的副本验签；随后
    /// 把目录降为只读。macOS 会在运行中可执行文件被删除时终止进程，因此一次性目录
    /// 必须保留到 node、codex 及其 helper 都退出，再由 supervisor 统一清理。
    ///
    /// 这层防护覆盖 App 更新和普通路径替换，不把同 UID 主动篡改临时副本作为安全边界；
    /// 后一种威胁需要 root-owned staging/特权 helper，超出当前无提权 LaunchAgent 的范围。
    static func stageExecutables(
        _ command: CodexDaemonSupervisorInvocation.Command,
        clone: (String, String) throws -> Void = cloneExecutable,
        verifySignature: (String, String) -> Bool = verifyOpenAISignature
    ) throws -> CodexDaemonSupervisorStaging {
        // helper 不是 supervisor 的外部参数。它只能由已经验收的 node/codex
        // bundle 推导，避免调用方把另一份可执行文件带进 TCC 责任进程链。
        let codeModeHost = try codeModeHostPath(for: command)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: S_IRWXU)]
            )
            let stagedNode = directory.appending(path: "node").path
            let stagedCodex = directory.appending(path: "codex").path
            let stagedCodeModeHost = directory.appending(path: codeModeHostFilename).path
            try clone(command.node, stagedNode)
            try clone(command.codex, stagedCodex)
            try clone(codeModeHost, stagedCodeModeHost)
            guard verifySignature(stagedNode, nodeSigningIdentifier) else {
                throw CodexDaemonSupervisorError.signatureRejected("一次性 node supervisor")
            }
            guard verifySignature(stagedCodex, codexSigningIdentifier) else {
                throw CodexDaemonSupervisorError.signatureRejected("一次性 Codex app-server")
            }
            guard verifySignature(stagedCodeModeHost, codeModeHostSigningIdentifier) else {
                throw CodexDaemonSupervisorError.signatureRejected("一次性 codex-code-mode-host")
            }
            guard chmod(stagedNode, S_IRUSR | S_IXUSR) == 0,
                  chmod(stagedCodex, S_IRUSR | S_IXUSR) == 0,
                  chmod(stagedCodeModeHost, S_IRUSR | S_IXUSR) == 0,
                  chmod(directory.path, S_IRUSR | S_IXUSR) == 0 else {
                throw CodexDaemonSupervisorError.stagingFailed(String(cString: strerror(errno)))
            }
            return .init(
                directory: directory,
                node: stagedNode,
                codex: stagedCodex,
                codeModeHost: stagedCodeModeHost
            )
        } catch {
            _ = chmod(directory.path, S_IRWXU)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 从已验签的 node/codex 对中推导同一 bundle 的 code-mode helper。
    /// 这里不接受独立 helper 参数，且拒绝 bundle 外的路径或符号链接，避免 TOCTOU
    /// 防护只覆盖主程序而把 helper 留成可替换的旁路。
    private static func codeModeHostPath(
        for command: CodexDaemonSupervisorInvocation.Command
    ) throws -> String {
        let node = URL(fileURLWithPath: command.node).resolvingSymlinksInPath().path
        guard let bundle = desktopBundle(forNode: node) else {
            throw CodexDaemonSupervisorError.notInsideDesktopBundle("node supervisor")
        }
        let resources = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Resources")
        let expectedCodex = resources.appendingPathComponent("codex").path
        let codex = URL(fileURLWithPath: command.codex).resolvingSymlinksInPath().path
        guard codex == expectedCodex else {
            throw CodexDaemonSupervisorError.bundleMismatch
        }

        let helper = resources.appendingPathComponent(codeModeHostFilename).path
        let helperURL = URL(fileURLWithPath: helper)
        guard helperURL.resolvingSymlinksInPath().path == helper,
              let attributes = try? FileManager.default.attributesOfItem(atPath: helper),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CodexDaemonSupervisorError.helperMissing(helper)
        }
        return helper
    }

    static func cloneExecutable(source: String, destination: String) throws {
        guard clonefile(source, destination, 0) == 0 else {
            throw CodexDaemonSupervisorError.stagingFailed(String(cString: strerror(errno)))
        }
    }

    /// node 只认 <X>.app/Contents/Resources/cua_node/bin/node 这一种布局，返回 bundle 根目录。
    static func desktopBundle(forNode node: String) -> String? {
        let suffix = "/Contents/Resources/cua_node/bin/node"
        guard node.hasSuffix(suffix) else { return nil }
        let bundle = String(node.dropLast(suffix.count))
        guard bundle.hasSuffix(".app"), bundle.hasPrefix("/") else { return nil }
        return bundle
    }

    static func verifyOpenAISignature(path: String, identifier: String) -> Bool {
        let requirement = codesignRequirement(identifier: identifier, explicit: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", "--test-requirement", requirement, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func codesignRequirement(identifier: String, explicit: Bool = false) -> String {
        let prefix = explicit ? "=identifier" : "identifier"
        return """
            \(prefix) "\(identifier)" and anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
            and certificate leaf[subject.OU] = "\(openAITeamIdentifier)"
            """
    }

    /// POSIX_SPAWN_START_SUSPENDED 保证 node 在进入用户态前停住。这里校验内核中的
    /// 真实进程对象，而不是再次读取磁盘路径；通过后才允许固定脚本开始运行。
    static func verifyRunningOpenAISignature(pid: pid_t, identifier: String) -> Bool {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            codesignRequirement(identifier: identifier) as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func makeCStringArray(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        values.map { strdup($0) } + [nil]
    }

    private static func freeCStringArray(_ values: [UnsafeMutablePointer<CChar>?]) {
        for case let value? in values { free(value) }
    }

    static func spawnSuspended(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CodexDaemonSupervisorError.spawnFailed("初始化 spawn 属性失败")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED)) == 0 else {
            throw CodexDaemonSupervisorError.spawnFailed("无法挂起启动 node")
        }

        var argv = makeCStringArray(arguments)
        var envp = makeCStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envBuffer in
                posix_spawn(
                    &pid,
                    executable,
                    nil,
                    &attributes,
                    argvBuffer.baseAddress!,
                    envBuffer.baseAddress!
                )
            }
        }
        guard result == 0 else {
            throw CodexDaemonSupervisorError.spawnFailed(String(cString: strerror(result)))
        }
        return pid
    }

    static func terminationStatus(for status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return signal == 0x7f ? 70 : 1
    }

    /// 校验通过后拉起 node 并保持为它的父进程，把终止信号透传下去，最后用 node 的退出码退出。
    /// 这里不做重启：LaunchAgent 的 KeepAlive=false 与既有 gateway recovery 已经覆盖，
    /// supervisor 自作主张重启只会掩盖 socket 冲突。
    static func run(_ command: CodexDaemonSupervisorInvocation.Command) -> Never {
        let validatedCommand: CodexDaemonSupervisorInvocation.Command
        switch validate(command) {
        case .accepted(let accepted):
            validatedCommand = accepted
        case .rejected(let failure):
            FileHandle.standardError.write(Data(("共享 daemon supervisor 拒绝启动：" + failure.message + "\n").utf8))
            exit(78)
        }
        let staging: CodexDaemonSupervisorStaging
        do {
            staging = try stageExecutables(validatedCommand)
        } catch let failure as CodexDaemonSupervisorError {
            FileHandle.standardError.write(Data(("共享 daemon supervisor 拒绝启动：\(failure.message)\n").utf8))
            exit(78)
        } catch {
            FileHandle.standardError.write(Data(("共享 daemon supervisor 拒绝启动：\(error)\n").utf8))
            exit(78)
        }
        let arguments = childArguments(node: validatedCommand.node, codex: validatedCommand.codex)
        var environment = sanitizedEnvironment(ProcessInfo.processInfo.environment)
        environment[stagedCodexEnvironmentKey] = staging.codex

        let childPID: pid_t
        do {
            childPID = try spawnSuspended(
                executable: staging.node,
                arguments: arguments,
                environment: environment
            )
        } catch {
            staging.remove()
            let message = (error as? CodexDaemonSupervisorError)?.message ?? "拉起共享 daemon 失败：\(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(70)
        }
        guard verifyRunningOpenAISignature(pid: childPID, identifier: nodeSigningIdentifier) else {
            _ = kill(childPID, SIGKILL)
            var rejectedStatus: Int32 = 0
            _ = waitpid(childPID, &rejectedStatus, 0)
            staging.remove()
            FileHandle.standardError.write(
                Data((CodexDaemonSupervisorError.signatureRejected("运行中 node supervisor").message + "\n").utf8)
            )
            exit(78)
        }

        // 先屏蔽默认处置，再交给 DispatchSourceSignal，否则进程会在 source 触发前就被终止，
        // node 与 codex 会被留成孤儿。
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { _ = kill(childPID, number) }
            source.resume()
            sources.append(source)
        }

        guard kill(childPID, SIGCONT) == 0 else {
            _ = kill(childPID, SIGKILL)
            var failedStatus: Int32 = 0
            _ = waitpid(childPID, &failedStatus, 0)
            staging.remove()
            exit(70)
        }
        var status: Int32 = 0
        var waitResult: pid_t
        repeat { waitResult = waitpid(childPID, &status, 0) } while waitResult == -1 && errno == EINTR
        if waitResult != childPID { status = 0x7f }
        sources.forEach { $0.cancel() }
        staging.remove()
        withExtendedLifetime(sources) {}
        // 与 node supervisor 脚本同一套退出码语义：被信号终止记 1，其余透传子进程退出码。
        exit(terminationStatus(for: status))
    }
}

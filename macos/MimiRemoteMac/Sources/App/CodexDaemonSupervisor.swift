import Foundation

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
    case signatureRejected(String)
    case spawnFailed(String)

    var message: String {
        switch self {
        case .notInsideDesktopBundle(let name): "\(name) 不在 Codex Desktop App bundle 内"
        case .bundleMismatch: "node 与 codex 不属于同一个 Codex Desktop App bundle"
        case .signatureRejected(let name): "\(name) 不是受支持的 OpenAI 签名程序"
        case .spawnFailed(let detail): "拉起共享 daemon 失败：\(detail)"
        }
    }
}

enum CodexDaemonSupervisor {
    /// OpenAI 的 Developer ID Team。与 Go 侧 sharedDaemonOpenAITeamIdentifier 一致。
    static let openAITeamIdentifier = "2DC432GLL2"
    static let nodeSigningIdentifier = "node"
    static let codexSigningIdentifier = "codex"

    /// node supervisor 脚本必须与 Go 侧 sharedDaemonNodeSupervisorScript 逐字一致：
    /// Go 在运行态会按这份正文校验 node 进程的命令行。这里保留独立副本而不是从命令行
    /// 接收，是因为脚本正文一旦可注入，任何同用户进程都能借 Mimi 的 TCC 授权执行任意
    /// JS，责任进程就成了权限旁路 gadget。两侧漂移由 Go 测试读取本文件比对拦截。
    static let nodeSupervisorScript = "'use strict';"
        + "const{spawn}=require('node:child_process');"
        + "const argv=process.argv.slice(1);"
        + "if(argv.length<4)process.exit(64);"
        + "const child=spawn(argv[0],argv.slice(1),{detached:false,env:process.env,stdio:'inherit'});"
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
    ) -> CodexDaemonSupervisorError? {
        let node = URL(fileURLWithPath: command.node).resolvingSymlinksInPath().path
        let codex = URL(fileURLWithPath: command.codex).resolvingSymlinksInPath().path
        guard let nodeBundle = desktopBundle(forNode: node) else {
            return .notInsideDesktopBundle("node supervisor")
        }
        guard codex == nodeBundle + "/Contents/Resources/codex" else {
            return codex.hasSuffix("/Contents/Resources/codex")
                ? .bundleMismatch
                : .notInsideDesktopBundle("Codex app-server")
        }
        guard verifySignature(node, nodeSigningIdentifier) else {
            return .signatureRejected("node supervisor")
        }
        guard verifySignature(codex, codexSigningIdentifier) else {
            return .signatureRejected("Codex app-server")
        }
        return nil
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
        let requirement = """
            =identifier "\(identifier)" and anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
            and certificate leaf[subject.OU] = "\(openAITeamIdentifier)"
            """
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

    /// 校验通过后拉起 node 并保持为它的父进程，把终止信号透传下去，最后用 node 的退出码退出。
    /// 这里不做重启：LaunchAgent 的 KeepAlive=false 与既有 gateway recovery 已经覆盖，
    /// supervisor 自作主张重启只会掩盖 socket 冲突。
    static func run(_ command: CodexDaemonSupervisorInvocation.Command) -> Never {
        if let failure = validate(command) {
            FileHandle.standardError.write(Data(("共享 daemon supervisor 拒绝启动：" + failure.message + "\n").utf8))
            exit(78)
        }
        let arguments = childArguments(node: command.node, codex: command.codex)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: arguments[0])
        child.arguments = Array(arguments.dropFirst())
        child.environment = ProcessInfo.processInfo.environment

        // 先屏蔽默认处置，再交给 DispatchSourceSignal，否则进程会在 source 触发前就被终止，
        // node 与 codex 会被留成孤儿。
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { if child.isRunning { kill(child.processIdentifier, number) } }
            source.resume()
            sources.append(source)
        }

        do {
            try child.run()
        } catch {
            FileHandle.standardError.write(
                Data((CodexDaemonSupervisorError.spawnFailed("\(error)").message + "\n").utf8)
            )
            exit(70)
        }
        child.waitUntilExit()
        withExtendedLifetime(sources) {}
        // 与 node supervisor 脚本同一套退出码语义：被信号终止记 1，其余透传子进程退出码。
        exit(child.terminationReason == .uncaughtSignal ? 1 : child.terminationStatus)
    }
}

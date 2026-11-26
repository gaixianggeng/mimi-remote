import AppKit
import Foundation

/// 在 Codex 桌面版打开一条会话（#991）。只开深链、只读进程列表，不读写桌面版的私有数据。
enum CodexDesktopLink {
    /// 桌面版与 Mimi 是否接着同一个服务。
    enum Connection: Equatable, Sendable {
        /// 桌面版经本机 SSH 主机接入共用服务：手机和桌面可以同时用。
        case shared
        /// 桌面版在运行，但没有接本机 SSH 主机。
        case separate
        case notRunning
    }

    /// 打开 Codex 桌面版 SSH / 连接设置页的结果，供向导明确反馈未安装、回退或启动失败。
    enum OpenSettingsResult: Equatable, Sendable {
        case openedSSHSettings
        case openedConnectionsFallback
        case openedAppFallback
        case notInstalled
        case launchFailed(String)

        var feedbackMessage: String? {
            switch self {
            case .openedSSHSettings:
                nil
            case .openedConnectionsFallback:
                "已打开 Codex 桌面版的「连接」设置页，请进入 SSH 子页继续添加主机。"
            case .openedAppFallback:
                "已打开 Codex 桌面版，请手动进入「设置 → 连接 → SSH」继续添加主机。"
            case .notInstalled:
                "没有找到 Codex 桌面版，请先安装 Codex 桌面版后再试。"
            case .launchFailed(let detail):
                detail.isEmpty ? "没能打开 Codex 桌面版。" : "没能打开 Codex 桌面版：\(detail)"
            }
        }

        var isFailure: Bool {
            switch self {
            case .notInstalled, .launchFailed:
                true
            case .openedSSHSettings, .openedConnectionsFallback, .openedAppFallback:
                false
            }
        }
    }

    static let sshSettingsURL = URL(string: "codex://settings/connections/ssh")!
    static let connectionsSettingsURL = URL(string: "codex://settings/connections")!

    /// OpenSSH 中会消费后一个参数值的短选项集合，用于准确提取 ssh 命令的目标主机与覆盖选项。
    private static let sshOptionsRequiringArgument: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
        "-L", "-l", "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S", "-W", "-w",
    ]

    struct ParsedSSHInvocation: Equatable, Sendable {
        let destinationHost: String
        var explicitUser: String?
        var explicitPort: String?
        var explicitConfigPath: String?
        var explicitHostName: String?
        var explicitProxyJump: String?
        var explicitProxyCommand: String?
        var explicitControlPath: String?
        var explicitRemoteCommand: String?

        /// 校验命令行选项本身不包含将连接重定向到远端、非 22 端口、非当前用户或自定义配置文件的覆盖。
        func isDirectLoopbackInvocation(
            localHosts: Set<String>,
            expectedUsername: String?
        ) -> Bool {
            guard localHosts.contains(destinationHost.lowercased()) else { return false }
            if let explicitConfigPath, explicitConfigPath != "/dev/null" {
                return false
            }
            if let explicitPort, explicitPort != "22" {
                return false
            }
            if let expectedUsername, !expectedUsername.isEmpty,
               let explicitUser, explicitUser != expectedUsername {
                return false
            }
            if let explicitHostName {
                let lower = explicitHostName.lowercased()
                guard lower == "127.0.0.1" || lower == "::1" || lower == "localhost" else {
                    return false
                }
            }
            if let explicitProxyJump, !explicitProxyJump.isEmpty, explicitProxyJump.lowercased() != "none" {
                return false
            }
            if let explicitProxyCommand, !explicitProxyCommand.isEmpty, explicitProxyCommand.lowercased() != "none" {
                return false
            }
            if let explicitControlPath, !explicitControlPath.isEmpty, explicitControlPath.lowercased() != "none" {
                return false
            }
            if let explicitRemoteCommand, !explicitRemoteCommand.isEmpty, explicitRemoteCommand.lowercased() != "none" {
                return false
            }
            return true
        }
    }

    struct SSHChildCandidate: Equatable, Sendable {
        let pid: Int32
        let invocation: ParsedSSHInvocation
    }

    struct TCPPeer: Equatable, Sendable {
        let remoteHost: String
        let remotePort: String

        var isLoopbackHost: Bool {
            remoteHost == "127.0.0.1" || remoteHost == "::1"
        }

        var isLoopbackSSH: Bool {
            isLoopbackHost && remotePort == "22"
        }
    }

    static func url(threadID: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !threadID.isEmpty, threadID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }

    /// 提取桌面版名下命令行参数满足直连回环条件的 ssh 子进程候选列表。
    static func localSSHChildCandidates(
        psOutput: String,
        desktopPIDs: Set<Int32>,
        localHosts: Set<String>,
        expectedUsername: String? = nil
    ) -> [SSHChildCandidate] {
        guard !desktopPIDs.isEmpty else { return [] }
        let hosts = Set(localHosts.map { $0.lowercased() })
        var candidates: [SSHChildCandidate] = []
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  desktopPIDs.contains(ppid) else { continue }
            guard fields[2] == "ssh" || fields[2].hasSuffix("/ssh") else { continue }
            guard let invocation = parseSSHInvocation(from: Array(fields.dropFirst(3))) else { continue }
            if invocation.isDirectLoopbackInvocation(localHosts: hosts, expectedUsername: expectedUsername) {
                candidates.append(SSHChildCandidate(pid: pid, invocation: invocation))
            }
        }
        return candidates
    }

    /// 从 `lsof -nP -a -p <pids> -iTCP -sTCP:ESTABLISHED -F pn` 输出解析每个进程的实际已建立 TCP 对端。
    static func parseEstablishedTCPPeers(lsofOutput: String) -> [Int32: [TCPPeer]] {
        var result: [Int32: [TCPPeer]] = [:]
        var currentPID: Int32?
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p":
                currentPID = Int32(value)
            case "n":
                guard let pid = currentPID,
                      let arrowRange = value.range(of: "->") else { continue }
                let remoteEndpoint = String(value[arrowRange.upperBound...])
                if let peer = parseEndpoint(remoteEndpoint) {
                    result[pid, default: []].append(peer)
                }
            default:
                break
            }
        }
        return result
    }

    private static func parseEndpoint(_ endpoint: String) -> TCPPeer? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
            let afterBracket = trimmed[trimmed.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(":") else { return nil }
            let port = String(afterBracket.dropFirst())
            guard !host.isEmpty, !port.isEmpty else { return nil }
            return TCPPeer(remoteHost: host.lowercased(), remotePort: port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let port = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty else { return nil }
        return TCPPeer(remoteHost: host.lowercased(), remotePort: port)
    }

    /// 从 `ps` 输出与（可选）`lsof` 实际已建立对端输出判断桌面版是否确实经直连回环 SSH 22 端口接入。
    static func hasLocalSSHChild(
        psOutput: String,
        desktopPIDs: Set<Int32>,
        localHosts: Set<String>,
        expectedUsername: String? = nil,
        lsofOutput: String? = nil
    ) -> Bool {
        let candidates = localSSHChildCandidates(
            psOutput: psOutput,
            desktopPIDs: desktopPIDs,
            localHosts: localHosts,
            expectedUsername: expectedUsername
        )
        guard !candidates.isEmpty else { return false }
        guard let lsofOutput else { return true }
        let peersByPID = parseEstablishedTCPPeers(lsofOutput: lsofOutput)
        return candidates.contains { candidate in
            guard let peers = peersByPID[candidate.pid], !peers.isEmpty else { return false }
            let hasLoopbackSSH = peers.contains { $0.isLoopbackSSH }
            let hasRemotePeer = peers.contains { !$0.isLoopbackHost }
            return hasLoopbackSSH && !hasRemotePeer
        }
    }

    static func parseSSHInvocation(from args: [Substring]) -> ParsedSSHInvocation? {
        var idx = 0
        var explicitUser: String?
        var explicitPort: String?
        var explicitConfigPath: String?
        var explicitHostName: String?
        var explicitProxyJump: String?
        var explicitProxyCommand: String?
        var explicitControlPath: String?
        var explicitRemoteCommand: String?

        func recordSSHOption(_ rawOption: String) {
            let trimmed = rawOption.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let key: String
            let value: String
            if let eq = trimmed.firstIndex(of: "=") {
                key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            } else if let sp = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                key = String(trimmed[..<sp]).lowercased()
                value = String(trimmed[sp...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            } else {
                return
            }
            switch key {
            case "user":
                if explicitUser == nil { explicitUser = value }
            case "port":
                if explicitPort == nil { explicitPort = value }
            case "hostname":
                if explicitHostName == nil { explicitHostName = value }
            case "proxyjump":
                if explicitProxyJump == nil { explicitProxyJump = value }
            case "proxycommand":
                if explicitProxyCommand == nil { explicitProxyCommand = value }
            case "controlpath":
                if explicitControlPath == nil { explicitControlPath = value }
            case "remotecommand":
                if explicitRemoteCommand == nil { explicitRemoteCommand = value }
            default:
                break
            }
        }

        var destinationToken: String?
        while idx < args.count {
            let token = String(args[idx])
            if token == "--" {
                idx += 1
                if idx < args.count {
                    destinationToken = String(args[idx])
                }
                break
            }
            if token.hasPrefix("-"), token.count > 1 {
                // 支持合并短选项（如 -Tv、-Tp 2222、-Tl bob、-ToHostName=evil）。
                let body = token.dropFirst()
                var argFlag: String?
                var attachedValue: String?
                var charIdx = body.startIndex
                while charIdx < body.endIndex {
                    let candidateFlag = "-\(body[charIdx])"
                    let nextIdx = body.index(after: charIdx)
                    if sshOptionsRequiringArgument.contains(candidateFlag) {
                        argFlag = candidateFlag
                        if nextIdx < body.endIndex {
                            attachedValue = String(body[nextIdx...])
                        }
                        break
                    }
                    charIdx = nextIdx
                }

                if let flag = argFlag {
                    let optionValue: String?
                    if let attachedValue {
                        optionValue = attachedValue
                        idx += 1
                    } else if idx + 1 < args.count {
                        optionValue = String(args[idx + 1])
                        idx += 2
                    } else {
                        optionValue = nil
                        idx += 1
                    }

                    if flag == "-o", let opt = optionValue {
                        if !opt.contains("="), idx < args.count {
                            // ps 输出把 `-o "HostName remote"` 拆成两个空白分词时合并解析。
                            let lowerOpt = opt.lowercased()
                            if ["hostname", "user", "port", "proxyjump", "proxycommand", "controlpath", "remotecommand", "batchmode", "serveraliveinterval", "stricthostkeychecking", "identitiesonly", "identityagent", "userknownhostsfile"].contains(lowerOpt) {
                                let nextVal = String(args[idx])
                                idx += 1
                                recordSSHOption("\(opt)=\(nextVal)")
                            } else {
                                recordSSHOption(opt)
                            }
                        } else {
                            recordSSHOption(opt)
                        }
                    } else if flag == "-l", let val = optionValue, explicitUser == nil {
                        explicitUser = val
                    } else if flag == "-p", let val = optionValue, explicitPort == nil {
                        explicitPort = val
                    } else if flag == "-F", let val = optionValue {
                        explicitConfigPath = val
                    } else if flag == "-J", let val = optionValue, explicitProxyJump == nil {
                        explicitProxyJump = val
                    } else if flag == "-S", let val = optionValue, explicitControlPath == nil {
                        explicitControlPath = val
                    }
                } else {
                    idx += 1
                }
                continue
            }
            destinationToken = token
            break
        }

        guard let destinationToken,
              let parsedDestination = parseDestination(destinationToken) else {
            return nil
        }
        return ParsedSSHInvocation(
            destinationHost: parsedDestination.host,
            explicitUser: explicitUser ?? parsedDestination.user,
            explicitPort: explicitPort ?? parsedDestination.port,
            explicitConfigPath: explicitConfigPath,
            explicitHostName: explicitHostName,
            explicitProxyJump: explicitProxyJump,
            explicitProxyCommand: explicitProxyCommand,
            explicitControlPath: explicitControlPath,
            explicitRemoteCommand: explicitRemoteCommand
        )
    }

    static func extractSSHDestinationHost(from args: [Substring]) -> String? {
        parseSSHInvocation(from: args)?.destinationHost
    }

    private static func parseDestination(_ destination: String) -> (host: String, user: String?, port: String?)? {
        if destination.lowercased().hasPrefix("ssh://") {
            guard let parsed = URL(string: destination), let host = parsed.host, !host.isEmpty else {
                return nil
            }
            return (host, parsed.user, parsed.port.map(String.init))
        }
        let user: String?
        let hostPart: String
        if let at = destination.lastIndex(of: "@") {
            let u = String(destination[..<at])
            user = u.isEmpty ? nil : u
            hostPart = String(destination[destination.index(after: at)...])
        } else {
            user = nil
            hostPart = destination
        }
        let trimmedHost = hostPart.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !trimmedHost.isEmpty else { return nil }
        return (trimmedHost, user, nil)
    }

    /// 只有经 Mimi 核验且 `ssh -G` 确认直连本机回环时，才把 `mimi-local` 视为本机主机。
    static func localHosts(includeManagedAlias: Bool = false) -> Set<String> {
        var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        if includeManagedAlias {
            hosts.insert(CodexLocalSSHConfigurator.hostAlias)
        }
        let name = ProcessInfo.processInfo.hostName
        if !name.isEmpty {
            hosts.insert(name)
            if let short = name.split(separator: ".").first { hosts.insert(String(short)) }
        }
        return hosts
    }

    @MainActor
    static func openSSHSettings(
        preferSSHSubpage: Bool = true,
        findApp: @MainActor () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: SessionOpenTarget.codexDesktopBundleID)
        },
        openURL: @MainActor (URL, URL) async throws -> Void = { url, appURL in
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        },
        openApp: @MainActor (URL) async throws -> Void = { appURL in
            _ = try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    ) async -> OpenSettingsResult {
        guard let appURL = findApp() else {
            return .notInstalled
        }
        if preferSSHSubpage {
            do {
                try await openURL(sshSettingsURL, appURL)
                return .openedSSHSettings
            } catch {
                // 旧版桌面版若不识别 SSH 子页，回退到通用连接页。
            }
        }
        do {
            try await openURL(connectionsSettingsURL, appURL)
            return .openedConnectionsFallback
        } catch {
            do {
                try await openApp(appURL)
                return .openedAppFallback
            } catch let launchError {
                return .launchFailed(launchError.localizedDescription)
            }
        }
    }

    @MainActor
    static func openConnectionsSettings() async -> OpenSettingsResult {
        await openSSHSettings(preferSSHSubpage: false)
    }

    @MainActor
    static func connection(includeManagedAlias: Bool? = nil) async -> Connection {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: SessionOpenTarget.codexDesktopBundleID)
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty else { return .notRunning }
        let allowManagedAlias: Bool
        if let includeManagedAlias {
            allowManagedAlias = includeManagedAlias
        } else {
            allowManagedAlias = await CodexLocalSSHConfigurator().inspect().isReady
        }
        let result = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,command="],
            timeout: .seconds(5),
            outputLimit: 4_194_304
        )
        guard let result, result.status == 0 else { return .separate }
        let currentUser = NSUserName()
        let allowedHosts = localHosts(includeManagedAlias: allowManagedAlias)
        let candidates = localSSHChildCandidates(
            psOutput: result.stdoutText,
            desktopPIDs: pids,
            localHosts: allowedHosts,
            expectedUsername: currentUser
        )
        guard !candidates.isEmpty else { return .separate }

        // 核验每个候选 ssh 子进程的实际已建立 TCP 对端为本机回环 22 端口，防止把配置改写前已建立的远端连接误报为共享。
        let pidList = candidates.map { String($0.pid) }.joined(separator: ",")
        let lsofResult = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-p", pidList, "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn"],
            timeout: .seconds(5),
            outputLimit: 1_048_576
        )
        guard let lsofResult, lsofResult.status == 0 else { return .separate }
        let peersByPID = parseEstablishedTCPPeers(lsofOutput: lsofResult.stdoutText)

        let configurator = CodexLocalSSHConfigurator()
        for candidate in candidates {
            guard let peers = peersByPID[candidate.pid], !peers.isEmpty else { continue }
            let hasLoopbackSSH = peers.contains { $0.isLoopbackSSH }
            let hasRemotePeer = peers.contains { !$0.isLoopbackHost }
            guard hasLoopbackSSH && !hasRemotePeer else { continue }

            // 对未带 `-F /dev/null` 的非托管目标，额外通过真实 `ssh -G` 确认实际解析用户为当前用户且无代理重定向。
            let lowerDest = candidate.invocation.destinationHost.lowercased()
            if lowerDest != CodexLocalSSHConfigurator.hostAlias && candidate.invocation.explicitConfigPath != "/dev/null" {
                guard let effective = try? await configurator.resolveEffectiveSSHConfig(
                    configPath: configurator.sshConfigURL.path,
                    alias: candidate.invocation.destinationHost,
                    includeSystemConfig: true
                ),
                CodexLocalSSHConfigurator.isDirectLoopbackConfig(effective, expectedUser: currentUser) else {
                    continue
                }
            }
            return .shared
        }
        return .separate
    }

    @MainActor
    static func open(threadID: String) async throws {
        guard let url = url(threadID: threadID) else {
            throw AgentClientError.commandFailed("会话 ID 不合法。")
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SessionOpenTarget.codexDesktopBundleID) else {
            throw AgentClientError.commandFailed("没有找到 Codex 桌面版。")
        }
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw AgentClientError.commandFailed("没能打开 Codex 桌面版：\(error.localizedDescription)")
        }
    }
}

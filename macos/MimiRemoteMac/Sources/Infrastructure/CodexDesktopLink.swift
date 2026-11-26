import AppKit
import Darwin
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
                "已将 SSH 设置页链接发送给 Codex 桌面版；如未自动跳转，可点击「打开连接设置」或手动进入「设置 → 连接 → SSH」。"
            case .openedConnectionsFallback:
                "已将「连接」设置页链接发送给 Codex 桌面版，请进入 SSH 子页继续添加主机。"
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

    /// 完整 TCP 四元组（本端 IP:端口 -> 对端 IP:端口），用于将桌面 `ssh` 与服务端 `sshd`/`sshd-session` 精确关联到同一连接。
    struct TCPConnection: Equatable, Hashable, Sendable {
        let localHost: String
        let localPort: String
        let remoteHost: String
        let remotePort: String

        var isLocalLoopback: Bool {
            localHost == "127.0.0.1" || localHost == "::1"
        }

        var isRemoteLoopback: Bool {
            remoteHost == "127.0.0.1" || remoteHost == "::1"
        }

        var isLoopbackToSSHPort: Bool {
            isLocalLoopback && isRemoteLoopback && remotePort == "22"
        }

        var isLoopbackFromSSHPort: Bool {
            isLocalLoopback && isRemoteLoopback && localPort == "22"
        }

        var peer: TCPPeer {
            TCPPeer(remoteHost: remoteHost, remotePort: remotePort)
        }

        /// 同一 TCP 连接对端视角下的镜像四元组：`(A:p1 -> B:p2)` <-> `(B:p2 -> A:p1)`。
        var mirrored: TCPConnection {
            TCPConnection(
                localHost: remoteHost,
                localPort: remotePort,
                remoteHost: localHost,
                remotePort: localPort
            )
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

    /// 从 `lsof -nP -a -p <pids> -iTCP -sTCP:ESTABLISHED -F pn` 输出解析每个进程的完整已建立 TCP 四元组。
    static func parseEstablishedTCPConnections(lsofOutput: String) -> [Int32: [TCPConnection]] {
        var result: [Int32: [TCPConnection]] = [:]
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
                let localEndpoint = String(value[..<arrowRange.lowerBound])
                let remoteEndpoint = String(value[arrowRange.upperBound...])
                if let local = parseHostPort(localEndpoint),
                   let remote = parseHostPort(remoteEndpoint) {
                    result[pid, default: []].append(TCPConnection(
                        localHost: local.host,
                        localPort: local.port,
                        remoteHost: remote.host,
                        remotePort: remote.port
                    ))
                }
            default:
                break
            }
        }
        return result
    }

    /// 从 `lsof -nP -a -p <pids> -iTCP -sTCP:ESTABLISHED -F pn` 输出解析每个进程的实际已建立 TCP 对端。
    static func parseEstablishedTCPPeers(lsofOutput: String) -> [Int32: [TCPPeer]] {
        parseEstablishedTCPConnections(lsofOutput: lsofOutput).mapValues { $0.map(\.peer) }
    }

    private static func normalizeLoopbackHost(_ rawHost: String) -> String {
        let lower = rawHost.lowercased()
        if lower == "::ffff:127.0.0.1" {
            return "127.0.0.1"
        }
        return lower
    }

    private static func parseHostPort(_ endpoint: String) -> (host: String, port: String)? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
            let afterBracket = trimmed[trimmed.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(":") else { return nil }
            let port = String(afterBracket.dropFirst())
            guard !host.isEmpty, !port.isEmpty else { return nil }
            return (normalizeLoopbackHost(host), port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let port = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty else { return nil }
        return (normalizeLoopbackHost(host), port)
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

    struct ProcessSnapshotEntry: Equatable, Sendable {
        let pid: Int32
        let ppid: Int32
        let uid: uid_t
        let executable: String
        let arguments: [Substring]
        let rawCommand: String
        var exactArguments: [String]? = nil
    }

    /// 解析 `ps -axo pid=,ppid=,uid=,command=` 输出，保留原始完整命令行（不丢失路径中的空格）供后续参数解析与 `sshd` 祖先链核验。
    static func parseProcessesWithUID(psOutput: String) -> [Int32: ProcessSnapshotEntry] {
        var table: [Int32: ProcessSnapshotEntry] = [:]
        for line in psOutput.split(whereSeparator: \.isNewline) {
            var idx = line.startIndex
            func nextField() -> Substring? {
                while idx < line.endIndex && (line[idx] == " " || line[idx] == "\t") {
                    idx = line.index(after: idx)
                }
                guard idx < line.endIndex else { return nil }
                let start = idx
                while idx < line.endIndex && line[idx] != " " && line[idx] != "\t" {
                    idx = line.index(after: idx)
                }
                return line[start..<idx]
            }
            guard let pidField = nextField(),
                  let ppidField = nextField(),
                  let uidField = nextField(),
                  let pid = Int32(pidField),
                  let ppid = Int32(ppidField),
                  let uidValue = UInt32(uidField) else { continue }
            while idx < line.endIndex && (line[idx] == " " || line[idx] == "\t") {
                idx = line.index(after: idx)
            }
            guard idx < line.endIndex else { continue }
            let rawCommand = String(line[idx...])
            let commandFields = line[idx...].split(separator: " ", omittingEmptySubsequences: true)
            guard let firstField = commandFields.first else { continue }
            table[pid] = ProcessSnapshotEntry(
                pid: pid,
                ppid: ppid,
                uid: uid_t(uidValue),
                executable: String(firstField),
                arguments: Array(commandFields.dropFirst()),
                rawCommand: rawCommand,
                exactArguments: nil
            )
        }
        return table
    }

    /// 通过 macOS 内核 `KERN_PROCARGS2` 读取同用户实时进程的精确 `argv` 数组，完整保留可执行文件路径和 `--config` 路径中的空格。
    static func processArguments(forPID pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard Darwin.sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size,
              size <= 1_048_576 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard Darwin.sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }
        let argc = buffer.withUnsafeBytes { raw -> Int32 in
            raw.load(as: Int32.self)
        }
        guard argc > 0, argc < 4096 else { return nil }

        var offset = MemoryLayout<Int32>.size
        // 跳过 exec_path 及其后的 NUL 填充字节。
        while offset < size && buffer[offset] != 0 {
            offset += 1
        }
        while offset < size && buffer[offset] == 0 {
            offset += 1
        }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        while args.count < Int(argc) && offset < size {
            let start = offset
            while offset < size && buffer[offset] != 0 {
                offset += 1
            }
            args.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            offset += 1
        }
        return args.isEmpty ? nil : args
    }

    /// 从带 UID 的 `ps` 表中提取桌面版名下满足直连回环条件的 ssh 子进程候选列表。
    static func localSSHChildCandidates(
        processes: [Int32: ProcessSnapshotEntry],
        desktopPIDs: Set<Int32>,
        localHosts: Set<String>,
        expectedUsername: String? = nil
    ) -> [SSHChildCandidate] {
        guard !desktopPIDs.isEmpty else { return [] }
        let hosts = Set(localHosts.map { $0.lowercased() })
        var candidates: [SSHChildCandidate] = []
        for entry in processes.values where desktopPIDs.contains(entry.ppid) {
            guard entry.executable == "ssh" || entry.executable.hasSuffix("/ssh") else { continue }
            guard let invocation = parseSSHInvocation(from: entry.arguments) else { continue }
            if invocation.isDirectLoopbackInvocation(localHosts: hosts, expectedUsername: expectedUsername) {
                candidates.append(SSHChildCandidate(pid: entry.pid, invocation: invocation))
            }
        }
        return candidates
    }

    private struct AgentdCodexConfigFile: Decodable {
        struct CodexSection: Decodable {
            let enabled: Bool?
            let env: [String: String]?
        }

        struct AppServerSection: Decodable {
            let transport: String?
            let sharedCodexHome: String?

            enum CodingKeys: String, CodingKey {
                case transport
                case sharedCodexHome = "shared_codex_home"
            }
        }

        let listen: String?
        let codex: CodexSection?
        let appServer: AppServerSection?

        enum CodingKeys: String, CodingKey {
            case listen
            case codex
            case appServer = "app_server"
        }
    }

    /// 经实时进程、LaunchAgent 与监听端口核验确认当前正为 Mimi 服务的 `agentd serve` 实例。
    struct ActiveMimiAgentd: Equatable, Sendable {
        let pid: Int32
        let configURL: URL
        let listenPort: Int
    }

    private static let agentdLaunchAgentLabel = "com.gaixianggeng.mimi.mac.agentd"

    static func parseLaunchctlServicePID(from output: String) -> Int32? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let sep = line.range(of: " = ") else { continue }
            let key = line[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
            if key == "pid" {
                let value = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                if let pid = Int32(value), pid > 1 {
                    return pid
                }
                return nil
            }
        }
        return nil
    }

    static func parseListeningTCPPorts(lsofOutput: String) -> [Int32: Set<Int>] {
        var result: [Int32: Set<Int>] = [:]
        var currentPID: Int32?
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p":
                currentPID = Int32(value)
            case "n":
                guard let pid = currentPID,
                      let parsed = parseHostPort(value),
                      let port = Int(parsed.port),
                      port > 0 else { continue }
                result[pid, default: []].insert(port)
            default:
                break
            }
        }
        return result
    }

    private static func configuredListenPort(from listen: String?) -> Int {
        guard let raw = listen?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return LocalGatewayClient.defaultPort
        }
        if let parsed = parseHostPort(raw), let port = Int(parsed.port), port > 0 {
            return port
        }
        if raw.hasPrefix(":"), let port = Int(raw.dropFirst()), port > 0 {
            return port
        }
        return LocalGatewayClient.defaultPort
    }

    private static func isAgentdSupervisorProcess(_ entry: ProcessSnapshotEntry) -> Bool {
        if let exactArgs = entry.exactArguments {
            return AgentdSupervisorInvocation.isRequested(exactArgs)
        }
        return entry.rawCommand.contains(AgentdSupervisorInvocation.flag)
    }

    /// 识别 `agentd serve` 进程并返回其有效配置路径（省略 `--config` 时默认 `~/Library/Application Support/mimi-remote/config.json`）。
    /// 不匹配 `agentd codex-front serve`。
    static func extractAgentdServeEffectiveConfigURL(
        from entry: ProcessSnapshotEntry,
        homeDirectory: URL
    ) -> URL? {
        if let exactArgs = entry.exactArguments {
            guard exactArgs.count >= 2 else { return nil }
            let base = URL(fileURLWithPath: exactArgs[0]).lastPathComponent
            guard base == "agentd", exactArgs[1] == "serve" else { return nil }
            if let explicit = extractAgentdServeConfigPath(from: entry) {
                return URL(fileURLWithPath: expandHomePrefix(explicit, homeDirectory: homeDirectory), isDirectory: false)
            }
            return defaultAgentdConfigURL(homeDirectory: homeDirectory)
        }

        let raw = entry.rawCommand
        let serveRange: Range<String.Index>
        if let matched = raw.range(of: "/agentd serve") {
            serveRange = matched
        } else if raw.hasPrefix("agentd serve"),
                  let matched = raw.range(of: "agentd serve") {
            serveRange = matched
        } else {
            return nil
        }
        let afterServe = raw[serveRange.upperBound...]
        guard afterServe.isEmpty || afterServe.first == " " || afterServe.first == "\t" else {
            return nil
        }
        if let explicit = extractAgentdServeConfigPath(from: entry) {
            return URL(fileURLWithPath: expandHomePrefix(explicit, homeDirectory: homeDirectory), isDirectory: false)
        }
        return defaultAgentdConfigURL(homeDirectory: homeDirectory)
    }

    /// 唯一识别当前正为 Mimi 服务的活动 `agentd serve` 进程（优先 LaunchAgent supervisor 子进程，其次匹配 Mimi 配置与监听端口的唯一实例）；
    /// 绝不借用同用户其他 `agentd serve --config ...` 的配置，无法确认或存在歧义时返回 `nil`（判为非共享）。
    static func resolveActiveMimiAgentd(
        processes: [Int32: ProcessSnapshotEntry],
        listeningPortsByPID: [Int32: Set<Int>]? = nil,
        launchdSupervisorPID: Int32? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        expectedUID: uid_t = Darwin.geteuid(),
        expectedConfigURL: URL? = nil
    ) -> ActiveMimiAgentd? {
        let serveCandidates: [(entry: ProcessSnapshotEntry, configURL: URL)] = processes.values
            .sorted(by: { $0.pid < $1.pid })
            .compactMap { entry in
                guard entry.uid == expectedUID,
                      let cfgURL = extractAgentdServeEffectiveConfigURL(from: entry, homeDirectory: homeDirectory) else {
                    return nil
                }
                return (entry, cfgURL)
            }
        guard !serveCandidates.isEmpty else { return nil }

        func makeActive(_ candidate: (entry: ProcessSnapshotEntry, configURL: URL)) -> ActiveMimiAgentd? {
            let loadedPort: Int
            switch loadAgentdCodexConfig(at: candidate.configURL, expectedUID: expectedUID) {
            case .loaded(let cfg):
                loadedPort = configuredListenPort(from: cfg.listen)
            case .missing, .invalid:
                return nil
            }
            if let listeningPortsByPID {
                let ports = listeningPortsByPID[candidate.entry.pid] ?? []
                if !ports.contains(loadedPort) {
                    return nil
                }
            }
            return ActiveMimiAgentd(
                pid: candidate.entry.pid,
                configURL: candidate.configURL,
                listenPort: loadedPort
            )
        }

        // 1. 若 launchd 已报告 Mimi LaunchAgent 的 supervisor PID，严格绑定到其名下唯一的 `agentd serve` 子进程。
        if let launchdSupervisorPID {
            let supervised = serveCandidates.filter {
                $0.entry.ppid == launchdSupervisorPID || $0.entry.pid == launchdSupervisorPID
            }
            guard supervised.count == 1 else { return nil }
            return makeActive(supervised[0])
        }

        // 2. 若进程表内存在当前用户的 `--agentd-supervisor`，严格绑定到其名下唯一的 `agentd serve` 子进程。
        let supervisorPIDs = Set(
            processes.values
                .filter { $0.uid == expectedUID && isAgentdSupervisorProcess($0) }
                .map(\.pid)
        )
        if !supervisorPIDs.isEmpty {
            let supervised = serveCandidates.filter { supervisorPIDs.contains($0.entry.ppid) }
            guard supervised.count == 1 else { return nil }
            return makeActive(supervised[0])
        }

        // 3. 无 LaunchAgent supervisor 时（如手动/Homebrew 启动），只匹配 Mimi 目标配置文件对应的唯一活动 `agentd serve`（绝不误用其他 `--config` 的 `agentd`）。
        let targetConfigURL = expectedConfigURL ?? defaultAgentdConfigURL(homeDirectory: homeDirectory)
        let matchingTarget = serveCandidates.filter { configURLsMatch($0.configURL, targetConfigURL) }
        guard matchingTarget.count == 1 else { return nil }
        return makeActive(matchingTarget[0])
    }

    private static func expandHomePrefix(_ path: String, homeDirectory: URL) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            return homeDirectory.path + "/" + String(path.dropFirst(2))
        }
        return path
    }

    /// 从完整命令行（可能包含带空格的目录路径）提取 `agentd serve` 的 `--config` / `-config` 参数值。
    private static func extractAgentdServeConfigPath(from entry: ProcessSnapshotEntry) -> String? {
        if let exactArgs = entry.exactArguments, exactArgs.count >= 2 {
            let base = URL(fileURLWithPath: exactArgs[0]).lastPathComponent
            guard base == "agentd", exactArgs[1] == "serve" else { return nil }
            var idx = 2
            while idx < exactArgs.count {
                let arg = exactArgs[idx]
                if arg == "--config" || arg == "-config" {
                    if idx + 1 < exactArgs.count {
                        let rawPath = exactArgs[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rawPath.isEmpty { return rawPath }
                    }
                    idx += 2
                    continue
                }
                if arg.hasPrefix("--config=") {
                    let rawPath = String(arg.dropFirst("--config=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawPath.isEmpty { return rawPath }
                } else if arg.hasPrefix("-config=") {
                    let rawPath = String(arg.dropFirst("-config=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawPath.isEmpty { return rawPath }
                }
                idx += 1
            }
            return nil
        }

        // 回退到 `ps` 原始命令行文本解析：允许可执行文件路径和 `--config` 路径均包含空格。
        let raw = entry.rawCommand
        let serveRange: Range<String.Index>
        if let matched = raw.range(of: "/agentd serve") {
            serveRange = matched
        } else if raw.hasPrefix("agentd serve"),
                  let matched = raw.range(of: "agentd serve") {
            serveRange = matched
        } else {
            return nil
        }

        let afterServe = raw[serveRange.upperBound...]
        guard afterServe.isEmpty || afterServe.first == " " || afterServe.first == "\t" else {
            return nil
        }

        // 在 serve 之后查找 `--config` / `-config` / `--config=` / `-config=` 并截取到下一个以空白开头的新选项（` -`）之前。
        let prefixes = [" --config=", " -config=", " --config ", " -config "]
        for prefix in prefixes {
            if let range = afterServe.range(of: prefix) {
                var valueSlice = afterServe[range.upperBound...]
                while let first = valueSlice.first, first == " " || first == "\t" {
                    valueSlice = valueSlice.dropFirst()
                }
                if let nextFlag = valueSlice.range(of: " -") {
                    valueSlice = valueSlice[..<nextFlag.lowerBound]
                }
                let rawPath = String(valueSlice).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawPath.isEmpty {
                    return rawPath
                }
            }
        }
        return nil
    }

    /// 解析活动 `agentd serve` 的配置文件路径：
    /// - 存在 `--agentd-supervisor` 子进程时仅采用该受管 `agentd serve` 的配置；
    /// - 存在多个同用户 `agentd serve` 且配置路径不一致时 fail closed 返回 `nil`（绝不借用另一个 `agentd` 的配置）；
    /// - 仅当无运行中 `agentd serve` 时回退到 `AGENTD_CONFIG` 或默认配置路径。
    static func resolveAgentdConfigURL(
        processes: [Int32: ProcessSnapshotEntry] = [:],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedUID: uid_t = Darwin.geteuid()
    ) -> URL? {
        let serveEntries: [(entry: ProcessSnapshotEntry, configURL: URL)] = processes.values
            .sorted(by: { $0.pid < $1.pid })
            .compactMap { entry in
                guard entry.uid == expectedUID,
                      let cfgURL = extractAgentdServeEffectiveConfigURL(from: entry, homeDirectory: homeDirectory) else {
                    return nil
                }
                return (entry, cfgURL)
            }

        if !serveEntries.isEmpty {
            let supervisorPIDs = Set(
                processes.values
                    .filter { $0.uid == expectedUID && isAgentdSupervisorProcess($0) }
                    .map(\.pid)
            )
            if !supervisorPIDs.isEmpty {
                let supervised = serveEntries.filter { supervisorPIDs.contains($0.entry.ppid) }
                guard supervised.count == 1 else { return nil }
                return supervised[0].configURL
            }
            let firstURL = serveEntries[0].configURL
            guard serveEntries.allSatisfy({ configURLsMatch($0.configURL, firstURL) }) else {
                return nil
            }
            return firstURL
        }

        if let envConfig = environment["AGENTD_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envConfig.isEmpty {
            return URL(fileURLWithPath: expandHomePrefix(envConfig, homeDirectory: homeDirectory), isDirectory: false)
        }
        return defaultAgentdConfigURL(homeDirectory: homeDirectory)
    }

    static func agentdConfigURL(
        processes: [Int32: ProcessSnapshotEntry] = [:],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedUID: uid_t = Darwin.geteuid()
    ) -> URL {
        resolveAgentdConfigURL(
            processes: processes,
            homeDirectory: homeDirectory,
            environment: environment,
            expectedUID: expectedUID
        ) ?? defaultAgentdConfigURL(homeDirectory: homeDirectory)
    }

    private enum LoadedAgentdConfig {
        case missing
        case loaded(AgentdCodexConfigFile)
        case invalid
    }

    private static func loadAgentdCodexConfig(at url: URL, expectedUID: uid_t) -> LoadedAgentdConfig {
        var lst = stat()
        if Darwin.lstat(url.path, &lst) != 0 {
            return errno == ENOENT ? .missing : .invalid
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return .invalid }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == expectedUID,
              st.st_size >= 0,
              st.st_size <= 4 * 1024 * 1024 else {
            return .invalid
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if data.count + count > 4 * 1024 * 1024 { return .invalid }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return .invalid
            }
        }
        guard let decoded = try? JSONDecoder().decode(AgentdCodexConfigFile.self, from: data) else {
            return .invalid
        }
        return .loaded(decoded)
    }

    /// 经过 `agentd` 后端规则校验后的共享 Codex 控制 socket 解析结果。
    struct SharedCodexSocketTarget: Equatable, Sendable {
        let socketPaths: Set<String>
        let requiresManagedFrontDoor: Bool
        let expectedConfigURL: URL
        let expectedBackendCodexHome: String?
        let expectedBackendSocketPaths: Set<String>
    }

    private static let codexFrontLaunchAgentLabel = "com.gaixianggeng.mimi.mac.codex-front"

    private static func defaultAgentdConfigURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mimi-remote", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    private static func normalizePathForComparison(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    private static func configURLsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        let lStd = normalizePathForComparison(lhs.path)
        let rStd = normalizePathForComparison(rhs.path)
        if lStd == rStd { return true }
        let lRes = normalizePathForComparison(lhs.resolvingSymlinksInPath().path)
        let rRes = normalizePathForComparison(rhs.resolvingSymlinksInPath().path)
        return lRes == rRes
    }

    /// 校验绝对路径指向已存在的目录并返回 `realpath` 规范化路径（与 Go `canonicalExistingDirectory` 一致）。
    static func canonicalExistingDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var st = stat()
        guard Darwin.fstatat(AT_FDCWD, path, &st, 0) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        guard let resolvedPtr = Darwin.realpath(path, nil) else {
            return nil
        }
        defer { free(resolvedPtr) }
        return normalizePathForComparison(String(cString: resolvedPtr))
    }

    private static func pathContains(_ parent: String, _ candidate: String) -> Bool {
        let p = normalizePathForComparison(parent)
        let c = normalizePathForComparison(candidate)
        if p == c { return true }
        if p == "/" { return c.hasPrefix("/") }
        return c.hasPrefix(p + "/")
    }

    /// 路径级重叠判定（相同或相互包含，与 Go `pathsOverlap` 一致）。
    static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        pathContains(left, right) || pathContains(right, left)
    }

    private static func pathContainsByIdentity(_ parent: String, _ candidate: String) -> Bool {
        var parentSt = stat()
        guard Darwin.fstatat(AT_FDCWD, parent, &parentSt, 0) == 0 else { return false }
        var current = URL(fileURLWithPath: normalizePathForComparison(candidate))
        var hops = 0
        while hops < 128 {
            var curSt = stat()
            if Darwin.fstatat(AT_FDCWD, current.path, &curSt, 0) == 0,
               curSt.st_dev == parentSt.st_dev,
               curSt.st_ino == parentSt.st_ino {
                return true
            }
            let next = current.deletingLastPathComponent()
            if next.path == current.path {
                return false
            }
            current = next
            hops += 1
        }
        return false
    }

    /// 基于 `(st_dev, st_ino)` 祖先链的重叠判定，覆盖大小写不敏感 APFS 别名与符号链接（与 Go `pathsOverlapByIdentity` 一致）。
    static func pathsOverlapByIdentity(_ left: String, _ right: String) -> Bool {
        pathContainsByIdentity(left, right) || pathContainsByIdentity(right, left)
    }

    /// 从完整命令行提取 `agentd codex-front serve` 的配置路径（省略 `--config` 时默认 `~/Library/Application Support/mimi-remote/config.json`）。
    private static func extractAgentdCodexFrontServeConfigURL(
        from entry: ProcessSnapshotEntry,
        homeDirectory: URL
    ) -> URL? {
        if let exactArgs = entry.exactArguments {
            guard exactArgs.count >= 3 else { return nil }
            let base = URL(fileURLWithPath: exactArgs[0]).lastPathComponent
            guard base == "agentd", exactArgs[1] == "codex-front", exactArgs[2] == "serve" else {
                return nil
            }
            var idx = 3
            while idx < exactArgs.count {
                let arg = exactArgs[idx]
                if arg == "--config" || arg == "-config" {
                    if idx + 1 < exactArgs.count {
                        let rawPath = exactArgs[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rawPath.isEmpty {
                            return URL(fileURLWithPath: expandHomePrefix(rawPath, homeDirectory: homeDirectory), isDirectory: false)
                        }
                    }
                    idx += 2
                    continue
                }
                if arg.hasPrefix("--config=") {
                    let rawPath = String(arg.dropFirst("--config=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawPath.isEmpty {
                        return URL(fileURLWithPath: expandHomePrefix(rawPath, homeDirectory: homeDirectory), isDirectory: false)
                    }
                } else if arg.hasPrefix("-config=") {
                    let rawPath = String(arg.dropFirst("-config=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawPath.isEmpty {
                        return URL(fileURLWithPath: expandHomePrefix(rawPath, homeDirectory: homeDirectory), isDirectory: false)
                    }
                }
                idx += 1
            }
            return defaultAgentdConfigURL(homeDirectory: homeDirectory)
        }

        let raw = entry.rawCommand
        let frontRange: Range<String.Index>
        if let matched = raw.range(of: "/agentd codex-front serve") {
            frontRange = matched
        } else if raw.hasPrefix("agentd codex-front serve"),
                  let matched = raw.range(of: "agentd codex-front serve") {
            frontRange = matched
        } else {
            return nil
        }

        let afterServe = raw[frontRange.upperBound...]
        guard afterServe.isEmpty || afterServe.first == " " || afterServe.first == "\t" else {
            return nil
        }

        let prefixes = [" --config=", " -config=", " --config ", " -config "]
        for prefix in prefixes {
            if let range = afterServe.range(of: prefix) {
                var valueSlice = afterServe[range.upperBound...]
                while let first = valueSlice.first, first == " " || first == "\t" {
                    valueSlice = valueSlice.dropFirst()
                }
                if let nextFlag = valueSlice.range(of: " -") {
                    valueSlice = valueSlice[..<nextFlag.lowerBound]
                }
                let rawPath = String(valueSlice).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawPath.isEmpty {
                    return URL(fileURLWithPath: expandHomePrefix(rawPath, homeDirectory: homeDirectory), isDirectory: false)
                }
            }
        }
        return defaultAgentdConfigURL(homeDirectory: homeDirectory)
    }

    static func isManagedCodexFrontDoorProcess(
        _ entry: ProcessSnapshotEntry,
        expectedConfigURL: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let frontConfigURL = extractAgentdCodexFrontServeConfigURL(from: entry, homeDirectory: homeDirectory) else {
            return false
        }
        if let expectedConfigURL {
            return configURLsMatch(frontConfigURL, expectedConfigURL)
        }
        return true
    }

    /// 若默认配置对应的受管前门 LaunchAgent plist 存在，核验其登记的公共 socket 与 `MIMI_CODEX_FRONT_BACKEND_HOME` 未漂移。
    private static func validateCodexFrontPlistIfPresent(
        homeDirectory: URL,
        expectedUID: uid_t,
        expectedConfigURL: URL,
        expectedPublicSockets: Set<String>,
        expectedBackendHome: String
    ) -> Bool {
        let defaultConfig = defaultAgentdConfigURL(homeDirectory: homeDirectory)
        guard configURLsMatch(expectedConfigURL, defaultConfig) else {
            return true
        }
        let plistURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(codexFrontLaunchAgentLabel).plist", isDirectory: false)
        var lst = stat()
        if Darwin.lstat(plistURL.path, &lst) != 0 {
            return errno == ENOENT
        }
        guard (lst.st_mode & S_IFMT) == S_IFREG,
              lst.st_uid == expectedUID,
              let data = try? Data(contentsOf: plistURL),
              let rawPlist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return false
        }
        guard let sockets = rawPlist["Sockets"] as? [String: Any],
              let listeners = sockets["Listeners"] as? [String: Any],
              let sockPath = listeners["SockPathName"] as? String,
              !sockPath.isEmpty else {
            return false
        }
        let normalizedSock = normalizePathForComparison(sockPath)
        let resolvedSock = normalizePathForComparison(URL(fileURLWithPath: sockPath).resolvingSymlinksInPath().path)
        guard expectedPublicSockets.contains(normalizedSock) || expectedPublicSockets.contains(resolvedSock) else {
            return false
        }
        let env = rawPlist["EnvironmentVariables"] as? [String: String]
        guard let pinnedBackend = env?["MIMI_CODEX_FRONT_BACKEND_HOME"],
              !pinnedBackend.isEmpty,
              let canonicalPinned = canonicalExistingDirectory(pinnedBackend),
              canonicalPinned == expectedBackendHome else {
            return false
        }
        return true
    }

    /// 按 `agentd` 后端校验规则解析共享 Codex 控制 socket 目标：
    /// - 缺失配置、配置损坏、禁用 Codex 或非 `local` transport 一律返回 `nil`；
    /// - 显式 `codex.env.CODEX_HOME` 必须为已存在的绝对路径目录；默认 `~/.codex` 若存在则必须为目录；
    /// - 配置 `app_server.shared_codex_home` 时，必须为已存在的绝对路径目录且不得与公共 `CODEX_HOME` 路径或 inode 重叠，并标记要求受管前门（拒绝独立 listener）。
    static func resolveSharedCodexSocketTarget(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedUID: uid_t = Darwin.geteuid(),
        agentdConfigURL: URL? = nil,
        processes: [Int32: ProcessSnapshotEntry] = [:]
    ) -> SharedCodexSocketTarget? {
        guard let configURL = agentdConfigURL ?? Self.resolveAgentdConfigURL(
            processes: processes,
            homeDirectory: homeDirectory,
            environment: environment,
            expectedUID: expectedUID
        ) else {
            return nil
        }

        let rawPublicHome: String
        let canonicalPublicHome: String
        let requiresManagedFrontDoor: Bool
        let canonicalBackendHome: String?
        let rawSharedHome: String?

        switch loadAgentdCodexConfig(at: configURL, expectedUID: expectedUID) {
        case .invalid, .missing:
            // agentd 缺失配置或配置无效时不会启用本机共享 local socket（默认 transport 为 ssh）。
            return nil
        case .loaded(let cfg):
            if cfg.codex?.enabled == false {
                return nil
            }
            let rawTransport = cfg.appServer?.transport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let effectiveTransport = rawTransport.isEmpty ? "ssh" : rawTransport
            guard effectiveTransport == "local" else {
                return nil
            }

            if let configuredHome = cfg.codex?.env?["CODEX_HOME"], !configuredHome.isEmpty {
                guard let canonical = canonicalExistingDirectory(configuredHome) else {
                    return nil
                }
                rawPublicHome = configuredHome
                canonicalPublicHome = canonical
            } else {
                let defaultURL = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
                rawPublicHome = normalizePathForComparison(defaultURL.path)
                var st = stat()
                if Darwin.fstatat(AT_FDCWD, defaultURL.path, &st, 0) == 0 {
                    guard (st.st_mode & S_IFMT) == S_IFDIR,
                          let canonical = canonicalExistingDirectory(defaultURL.path) else {
                        return nil
                    }
                    canonicalPublicHome = canonical
                } else if errno == ENOENT {
                    let resolvedHome = canonicalExistingDirectory(homeDirectory.path) ?? normalizePathForComparison(homeDirectory.path)
                    canonicalPublicHome = URL(fileURLWithPath: resolvedHome, isDirectory: true)
                        .appendingPathComponent(".codex", isDirectory: true)
                        .standardizedFileURL.path
                } else {
                    return nil
                }
            }

            // 与 agentd（internal/config/shared_codex_home.go + internal/appserver/front_door_darwin.go）对齐：
            // shared_codex_home 必须是已存在的绝对路径独立目录，且不能与公共 CODEX_HOME 相同或相互包含（含符号链接/大小写别名）。
            if let sharedHome = cfg.appServer?.sharedCodexHome, !sharedHome.isEmpty {
                guard let backendCanonical = canonicalExistingDirectory(sharedHome) else {
                    return nil
                }
                if pathsOverlap(rawPublicHome, sharedHome) ||
                    pathsOverlap(canonicalPublicHome, backendCanonical) ||
                    pathsOverlapByIdentity(rawPublicHome, sharedHome) ||
                    pathsOverlapByIdentity(canonicalPublicHome, backendCanonical) {
                    return nil
                }
                requiresManagedFrontDoor = true
                canonicalBackendHome = backendCanonical
                rawSharedHome = sharedHome
            } else {
                requiresManagedFrontDoor = false
                canonicalBackendHome = nil
                rawSharedHome = nil
            }
        }

        var paths: Set<String> = []
        let rawPublicURL = URL(fileURLWithPath: rawPublicHome, isDirectory: true)
        let rawControlDir = rawPublicURL.appendingPathComponent("app-server-control", isDirectory: true)
        let rawSocketURL = rawControlDir.appendingPathComponent("app-server-control.sock", isDirectory: false)
        paths.insert(normalizePathForComparison(rawSocketURL.path))

        let canonicalPublicURL = URL(fileURLWithPath: canonicalPublicHome, isDirectory: true)
        let canonicalControlDir = canonicalPublicURL.appendingPathComponent("app-server-control", isDirectory: true)
        let canonicalSocketURL = canonicalControlDir.appendingPathComponent("app-server-control.sock", isDirectory: false)
        paths.insert(normalizePathForComparison(canonicalSocketURL.path))

        let resolvedDir = rawControlDir.resolvingSymlinksInPath()
        let resolvedSocket = resolvedDir.appendingPathComponent("app-server-control.sock", isDirectory: false).path
        paths.insert(normalizePathForComparison(resolvedSocket))

        if !requiresManagedFrontDoor {
            var st = stat()
            if Darwin.lstat(rawSocketURL.path, &st) == 0,
               (st.st_mode & S_IFMT) == S_IFLNK,
               st.st_uid == expectedUID {
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
                let len = Darwin.readlink(rawSocketURL.path, &buf, buf.count - 1)
                if len > 0 {
                    let target = String(cString: buf)
                    let daemonPrefix1 = "/tmp/codex-daemon-\(expectedUID)/"
                    let daemonPrefix2 = "/private/tmp/codex-daemon-\(expectedUID)/"
                    if target.hasPrefix(daemonPrefix1) || target.hasPrefix(daemonPrefix2) {
                        paths.insert(target)
                        if target.hasPrefix(daemonPrefix1) {
                            paths.insert("/private" + target)
                        }
                    }
                }
            }
        }

        var backendSockets: Set<String> = []
        if let canonicalBackendHome {
            guard validateCodexFrontPlistIfPresent(
                homeDirectory: homeDirectory,
                expectedUID: expectedUID,
                expectedConfigURL: configURL,
                expectedPublicSockets: paths,
                expectedBackendHome: canonicalBackendHome
            ) else {
                return nil
            }
            let canonicalBackendSock = URL(fileURLWithPath: canonicalBackendHome, isDirectory: true)
                .appendingPathComponent("app-server-control", isDirectory: true)
                .appendingPathComponent("app-server-backend.sock", isDirectory: false)
                .standardizedFileURL.path
            backendSockets.insert(normalizePathForComparison(canonicalBackendSock))
            if let rawSharedHome {
                let rawBackendSock = URL(fileURLWithPath: rawSharedHome, isDirectory: true)
                    .appendingPathComponent("app-server-control", isDirectory: true)
                    .appendingPathComponent("app-server-backend.sock", isDirectory: false)
                    .standardizedFileURL.path
                backendSockets.insert(normalizePathForComparison(rawBackendSock))
            }
        }

        return SharedCodexSocketTarget(
            socketPaths: paths,
            requiresManagedFrontDoor: requiresManagedFrontDoor,
            expectedConfigURL: configURL,
            expectedBackendCodexHome: canonicalBackendHome,
            expectedBackendSocketPaths: backendSockets
        )
    }

    /// 按 `agentd` 实际配置的 transport 与公共 `CODEX_HOME` 解析共享 Codex App Server 控制 socket 路径集合（不读取 GUI 的 `CODEX_HOME`，也不在配置自定义目录时额外放行默认 `~/.codex`）。
    /// 与 `agentd`（`internal/config/config.go` 与 `internal/appserver/front_door_darwin.go`）对齐：缺失配置、省略 transport 或 `shared_codex_home` 无效/缺失/重叠时一律返回空集合。
    static func sharedCodexControlSocketPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedUID: uid_t = Darwin.geteuid(),
        agentdConfigURL: URL? = nil,
        processes: [Int32: ProcessSnapshotEntry] = [:]
    ) -> Set<String> {
        resolveSharedCodexSocketTarget(
            homeDirectory: homeDirectory,
            environment: environment,
            expectedUID: expectedUID,
            agentdConfigURL: agentdConfigURL,
            processes: processes
        )?.socketPaths ?? []
    }

    /// 从 `lsof -nP -a -U -u <uid> -F0pcfdtn` 输出解析当前已连接到共享 Codex 控制 socket 的 `codex` 客户端进程 PID 集合。
    /// - 当 `requireManagedFrontDoor == true`（例如配置了 `app_server.shared_codex_home`）时，严格确认监听器属于当前用户的受管前门进程（`agentd codex-front serve`）且已建立到期望 `app-server-backend.sock` 的活动后端连接；
    /// - 当提供 `activeAgentdPID` 时，严格要求该活动 Mimi `agentd` 进程与桌面 `codex` 代理连接到同一个活动 Unix socket 端点（相同 `(listenerPID, socketPath)`），无法确认即返回空集合。
    static func parseConnectedCodexClientPIDs(
        unixLsofOutput: Data,
        sharedSocketPaths: Set<String>,
        processes: [Int32: ProcessSnapshotEntry]? = nil,
        expectedUID: uid_t? = nil,
        requireManagedFrontDoor: Bool = false,
        expectedConfigURL: URL? = nil,
        expectedBackendSocketPaths: Set<String> = [],
        activeAgentdPID: Int32? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Set<Int32> {
        guard !sharedSocketPaths.isEmpty, !unixLsofOutput.isEmpty else { return [] }
        if requireManagedFrontDoor, processes == nil {
            // 探测不到进程表时保守判为非共享，绝不猜。
            return []
        }
        struct UnixSocketFile {
            var pid: Int32 = 0
            var command: String = ""
            var kind: String = ""
            var address: String = ""
            var name: String = ""
        }
        struct LiveSocketEndpoint: Hashable {
            let listenerPID: Int32
            let socketPath: String
        }
        func isCodexProcessCommand(_ cmd: String) -> Bool {
            cmd == "codex" ||
                cmd.hasPrefix("codex-aarch64") ||
                cmd.hasPrefix("codex-x86_64") ||
                cmd == "codex-aar" ||
                cmd == "codex-x86"
        }

        let normalizedSharedSockets = Set(sharedSocketPaths.map(normalizePathForComparison))
        let normalizedExpectedBackendSockets = Set(expectedBackendSocketPaths.map(normalizePathForComparison))

        var files: [UnixSocketFile] = []
        var current = UnixSocketFile()
        var hasFile = false
        func flush() {
            if hasFile && current.kind == "unix" && current.pid > 1 {
                files.append(current)
            }
        }

        for rawField in unixLsofOutput.split(separator: 0, omittingEmptySubsequences: true) {
            let trimmed = String(decoding: rawField, as: UTF8.self)
                .drop(while: { $0 == "\n" || $0 == "\r" })
            guard let tag = trimmed.first else { continue }
            let value = String(trimmed.dropFirst())
            switch tag {
            case "p":
                flush()
                guard let pid = Int32(value), pid > 1 else {
                    current = UnixSocketFile()
                    hasFile = false
                    continue
                }
                current = UnixSocketFile(pid: pid)
                hasFile = false
            case "c":
                current.command = value
            case "f":
                flush()
                guard current.pid > 1, !current.command.isEmpty else {
                    hasFile = false
                    continue
                }
                current = UnixSocketFile(pid: current.pid, command: current.command)
                hasFile = true
            case "t":
                current.kind = value
            case "d":
                current.address = value
            case "n":
                current.name = value
            default:
                break
            }
        }
        flush()

        var addressToFile: [String: UnixSocketFile] = [:]
        for file in files where file.address.hasPrefix("0x") && !file.name.isEmpty && !file.name.hasPrefix("->") {
            addressToFile[file.address] = file
        }

        var addressToVerifiedEndpoint: [String: LiveSocketEndpoint] = [:]
        for file in files where file.address.hasPrefix("0x") && !file.name.isEmpty && !file.name.hasPrefix("->") {
            let normalizedName = normalizePathForComparison(file.name)
            guard sharedSocketPaths.contains(file.name) || normalizedSharedSockets.contains(normalizedName) else {
                continue
            }
            if let expectedUID, let entry = processes?[file.pid], entry.uid != expectedUID {
                continue
            }
            if requireManagedFrontDoor {
                guard file.command == "agentd",
                      let entry = processes?[file.pid] else {
                    continue
                }
                if let expectedUID, entry.uid != expectedUID {
                    continue
                }
                guard isManagedCodexFrontDoorProcess(
                    entry,
                    expectedConfigURL: expectedConfigURL,
                    homeDirectory: homeDirectory
                ) else {
                    continue
                }
                if !normalizedExpectedBackendSockets.isEmpty {
                    let connectedBackendPeers = files
                        .filter { $0.pid == file.pid && $0.name.hasPrefix("->") }
                        .compactMap { addressToFile[String($0.name.dropFirst(2))] }
                        .filter { $0.name.hasSuffix("/app-server-backend.sock") }
                    // 受管前门必须确证已连接到期望的私有 backend socket 且对端为当前用户的 codex 后端进程。
                    guard !connectedBackendPeers.isEmpty,
                          connectedBackendPeers.allSatisfy({ peer in
                              let peerPathOK = normalizedExpectedBackendSockets.contains(normalizePathForComparison(peer.name))
                              let peerCmdOK = isCodexProcessCommand(peer.command)
                              let peerUIDOK: Bool
                              if let expectedUID, let peerProc = processes?[peer.pid] {
                                  peerUIDOK = peerProc.uid == expectedUID
                              } else {
                                  peerUIDOK = true
                              }
                              return peerPathOK && peerCmdOK && peerUIDOK
                          }) else {
                        continue
                    }
                }
            }
            addressToVerifiedEndpoint[file.address] = LiveSocketEndpoint(
                listenerPID: file.pid,
                socketPath: normalizedName
            )
        }
        guard !addressToVerifiedEndpoint.isEmpty else { return [] }

        // 若指定了活动 Mimi agentd PID，必须确认该 agentd 自己也连接在同一个活动 (listenerPID, socketPath) 端点上。
        let allowedEndpoints: Set<LiveSocketEndpoint>
        if let activeAgentdPID {
            var agentdEndpoints: Set<LiveSocketEndpoint> = []
            for file in files where file.pid == activeAgentdPID && file.name.hasPrefix("->") {
                let peerAddress = String(file.name.dropFirst(2))
                if let endpoint = addressToVerifiedEndpoint[peerAddress] {
                    agentdEndpoints.insert(endpoint)
                }
            }
            guard !agentdEndpoints.isEmpty else { return [] }
            allowedEndpoints = agentdEndpoints
        } else {
            allowedEndpoints = Set(addressToVerifiedEndpoint.values)
        }

        var connectedCodexPIDs: Set<Int32> = []
        for file in files where file.name.hasPrefix("->") {
            let peerAddress = String(file.name.dropFirst(2))
            guard let endpoint = addressToVerifiedEndpoint[peerAddress],
                  allowedEndpoints.contains(endpoint) else { continue }
            if isCodexProcessCommand(file.command) {
                connectedCodexPIDs.insert(file.pid)
            }
        }
        return connectedCodexPIDs
    }

    private static func isSSHServerExecutable(_ executable: String) -> Bool {
        let base = URL(fileURLWithPath: executable).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return base == "sshd" || base == "sshd-session"
    }

    /// 提取指定当前用户 `codex` 进程祖先链中的所有 `sshd` / `sshd-session` PID。
    static func sshdAncestorPIDs(
        for codexPID: Int32,
        processes: [Int32: ProcessSnapshotEntry],
        expectedUID: uid_t
    ) -> [Int32] {
        guard let start = processes[codexPID], start.uid == expectedUID else { return [] }
        var ancestors: [Int32] = []
        var cursor = start.ppid
        var hops = 0
        while cursor > 1 && hops < 16 {
            guard let parent = processes[cursor] else { break }
            if isSSHServerExecutable(parent.executable) {
                ancestors.append(parent.pid)
            }
            if parent.ppid == cursor { break }
            cursor = parent.ppid
            hops += 1
        }
        return ancestors
    }

    /// 校验存在至少一个属于当前用户、由与桌面回环 `ssh` 共享同一 TCP 四元组的 `sshd` 会话拉起、且已接入共享 Codex 控制 socket 的 `codex` 客户端进程。
    static func hasCorrelatedSSHAuthenticatedCodexSession(
        processes: [Int32: ProcessSnapshotEntry],
        expectedUID: uid_t,
        connectedCodexPIDs: Set<Int32>,
        verifiedClientTuples: Set<TCPConnection>,
        serverConnectionsByPID: [Int32: [TCPConnection]]
    ) -> Bool {
        guard !verifiedClientTuples.isEmpty else { return false }
        for pid in connectedCodexPIDs {
            let ancestors = sshdAncestorPIDs(for: pid, processes: processes, expectedUID: expectedUID)
            for sshdPID in ancestors {
                guard let serverConns = serverConnectionsByPID[sshdPID] else { continue }
                if serverConns.contains(where: { $0.isLoopbackFromSSHPort && verifiedClientTuples.contains($0.mirrored) }) {
                    return true
                }
            }
        }
        return false
    }

    /// 综合校验：同一 TCP 四元组必须把桌面 `ssh` 子进程、服务端 `sshd`/`sshd-session` 及其当前账号下已连共享 Codex 控制 socket 的 `codex` 后代串联在一起。
    static func hasVerifiedSharedConnection(
        psWithUIDOutput: String,
        desktopPIDs: Set<Int32>,
        localHosts: Set<String>,
        expectedUsername: String?,
        expectedUID: uid_t,
        tcpLsofOutput: String,
        unixLsofOutput: Data,
        sharedSocketPaths: Set<String>,
        requireManagedFrontDoor: Bool = false,
        expectedConfigURL: URL? = nil,
        expectedBackendSocketPaths: Set<String> = [],
        activeAgentdPID: Int32? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let processes = parseProcessesWithUID(psOutput: psWithUIDOutput)
        let candidates = localSSHChildCandidates(
            processes: processes,
            desktopPIDs: desktopPIDs,
            localHosts: localHosts,
            expectedUsername: expectedUsername
        )
        guard !candidates.isEmpty else { return false }
        let connectionsByPID = parseEstablishedTCPConnections(lsofOutput: tcpLsofOutput)
        var verifiedClientTuples: Set<TCPConnection> = []
        for candidate in candidates {
            guard let conns = connectionsByPID[candidate.pid], !conns.isEmpty else { continue }
            let hasRemotePeer = conns.contains { !$0.isRemoteLoopback }
            guard !hasRemotePeer else { continue }
            let loopbackSSH = conns.filter(\.isLoopbackToSSHPort)
            verifiedClientTuples.formUnion(loopbackSSH)
        }
        guard !verifiedClientTuples.isEmpty else { return false }
        let connectedCodexPIDs = parseConnectedCodexClientPIDs(
            unixLsofOutput: unixLsofOutput,
            sharedSocketPaths: sharedSocketPaths,
            processes: processes,
            expectedUID: expectedUID,
            requireManagedFrontDoor: requireManagedFrontDoor,
            expectedConfigURL: expectedConfigURL,
            expectedBackendSocketPaths: expectedBackendSocketPaths,
            activeAgentdPID: activeAgentdPID,
            homeDirectory: homeDirectory
        )
        return hasCorrelatedSSHAuthenticatedCodexSession(
            processes: processes,
            expectedUID: expectedUID,
            connectedCodexPIDs: connectedCodexPIDs,
            verifiedClientTuples: verifiedClientTuples,
            serverConnectionsByPID: connectionsByPID
        )
    }

    static func hasVerifiedSharedConnection(
        psWithUIDOutput: String,
        desktopPIDs: Set<Int32>,
        localHosts: Set<String>,
        expectedUsername: String?,
        expectedUID: uid_t,
        tcpLsofOutput: String,
        unixLsofOutput: Data,
        sharedTarget: SharedCodexSocketTarget?,
        activeAgentdPID: Int32? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let sharedTarget else { return false }
        return hasVerifiedSharedConnection(
            psWithUIDOutput: psWithUIDOutput,
            desktopPIDs: desktopPIDs,
            localHosts: localHosts,
            expectedUsername: expectedUsername,
            expectedUID: expectedUID,
            tcpLsofOutput: tcpLsofOutput,
            unixLsofOutput: unixLsofOutput,
            sharedSocketPaths: sharedTarget.socketPaths,
            requireManagedFrontDoor: sharedTarget.requiresManagedFrontDoor,
            expectedConfigURL: sharedTarget.expectedConfigURL,
            expectedBackendSocketPaths: sharedTarget.expectedBackendSocketPaths,
            activeAgentdPID: activeAgentdPID,
            homeDirectory: homeDirectory
        )
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

    /// 活动连接检查允许的主机名集合：已同时核验回环 TCP 四元组与共享后端关联，故允许 `ssh -G localhost` 报告的 `hostname localhost`。
    static let activeConnectionAllowedLoopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    static func isDirectActiveLoopbackConfig(
        _ config: CodexLocalSSHConfigurator.EffectiveSSHConfig,
        expectedUser: String
    ) -> Bool {
        CodexLocalSSHConfigurator.isDirectLoopbackConfig(
            config,
            expectedUser: expectedUser,
            allowedLoopbackHosts: activeConnectionAllowedLoopbackHosts
        )
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
            arguments: ["-axo", "pid=,ppid=,uid=,command="],
            timeout: .seconds(5),
            outputLimit: 4_194_304
        )
        guard let result, result.status == 0 else { return .separate }
        let currentUser = NSUserName()
        let currentUID = Darwin.geteuid()
        var processes = parseProcessesWithUID(psOutput: result.stdoutText)
        for (pid, entry) in processes where entry.uid == currentUID &&
            (entry.rawCommand.contains("agentd") || entry.rawCommand.contains(AgentdSupervisorInvocation.flag)) {
            if let exactArgs = processArguments(forPID: pid) {
                var enriched = entry
                enriched.exactArguments = exactArgs
                processes[pid] = enriched
            }
        }
        let allowedHosts = localHosts(includeManagedAlias: allowManagedAlias)
        let candidates = localSSHChildCandidates(
            processes: processes,
            desktopPIDs: pids,
            localHosts: allowedHosts,
            expectedUsername: currentUser
        )
        guard !candidates.isEmpty else { return .separate }

        // 1. 核验每个候选 ssh 子进程的实际已建立 TCP 四元组为本机回环 22 端口，防止把远端连接误报为共享。
        let pidList = candidates.map { String($0.pid) }.joined(separator: ",")
        let lsofResult = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-p", pidList, "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn"],
            timeout: .seconds(5),
            outputLimit: 1_048_576
        )
        guard let lsofResult, lsofResult.status == 0 else { return .separate }
        let clientConnsByPID = parseEstablishedTCPConnections(lsofOutput: lsofResult.stdoutText)

        let configurator = CodexLocalSSHConfigurator()
        var verifiedClientTuples: Set<TCPConnection> = []
        for candidate in candidates {
            guard let conns = clientConnsByPID[candidate.pid], !conns.isEmpty else { continue }
            let hasRemotePeer = conns.contains { !$0.isRemoteLoopback }
            guard !hasRemotePeer else { continue }
            let loopbackSSH = conns.filter(\.isLoopbackToSSHPort)
            guard !loopbackSSH.isEmpty else { continue }

            // 对未带 `-F /dev/null` 的非托管目标，仅针对单份冻结快照执行 `ssh -G`（含桌面代理命令）确认无重定向（活动连接检查接受 localhost）。
            let lowerDest = candidate.invocation.destinationHost.lowercased()
            if lowerDest != CodexLocalSSHConfigurator.hostAlias && candidate.invocation.explicitConfigPath != "/dev/null" {
                guard let frozen = try? configurator.materializeCurrentSSHConfigForEvaluation(includeSystemConfig: true) else {
                    continue
                }
                defer { frozen.cleanup() }
                guard let effective = try? await configurator.resolveEffectiveSSHConfig(
                    configPath: frozen.configFileURL.path,
                    alias: candidate.invocation.destinationHost,
                    includeSystemConfig: false
                ),
                isDirectActiveLoopbackConfig(effective, expectedUser: currentUser) else {
                    continue
                }
                var proxyMatchesLoopback = true
                for proxyCmd in CodexLocalSSHConfigurator.desktopProxyRemoteCommands {
                    guard let proxyEffective = try? await configurator.resolveEffectiveSSHConfig(
                        configPath: frozen.configFileURL.path,
                        alias: candidate.invocation.destinationHost,
                        includeSystemConfig: false,
                        extraOptions: ["-T"],
                        remoteCommand: proxyCmd
                    ),
                    isDirectActiveLoopbackConfig(proxyEffective, expectedUser: currentUser) else {
                        proxyMatchesLoopback = false
                        break
                    }
                }
                guard proxyMatchesLoopback else { continue }
            }
            verifiedClientTuples.formUnion(loopbackSSH)
        }
        guard !verifiedClientTuples.isEmpty else { return .separate }

        // 2. 先唯一识别当前正为 Mimi 服务的活动 `agentd serve` 实例（绝不借用同用户其他 `agentd` 的配置），
        //    并确认桌面 `codex` 代理与该活动 Mimi `agentd` 连接到同一个实时后端 socket（相同 listener PID 与路径）。
        let launchctlResult = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID)/\(agentdLaunchAgentLabel)"],
            timeout: .seconds(3),
            outputLimit: 262_144
        )
        let launchdSupervisorPID: Int32? = {
            guard let launchctlResult, launchctlResult.status == 0 else { return nil }
            return parseLaunchctlServicePID(from: launchctlResult.stdoutText)
        }()
        let listenLsofResult = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-u", String(currentUID), "-iTCP", "-sTCP:LISTEN", "-F", "pn"],
            timeout: .seconds(5),
            outputLimit: 1_048_576
        )
        guard let listenLsofResult, listenLsofResult.status == 0 else { return .separate }
        let listeningPortsByPID = parseListeningTCPPorts(lsofOutput: listenLsofResult.stdoutText)

        guard let activeAgentd = resolveActiveMimiAgentd(
            processes: processes,
            listeningPortsByPID: listeningPortsByPID,
            launchdSupervisorPID: launchdSupervisorPID,
            expectedUID: currentUID
        ) else {
            return .separate
        }

        guard let sharedTarget = resolveSharedCodexSocketTarget(
            expectedUID: currentUID,
            agentdConfigURL: activeAgentd.configURL,
            processes: processes
        ) else {
            return .separate
        }

        func captureUnixLsof() async -> Data? {
            let res = try? await ProcessExecutor.shared.run(
                executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-a", "-U", "-u", String(currentUID), "-F0pcfdtn"],
                timeout: .seconds(5),
                outputLimit: 1_048_576
            )
            guard let res, res.status == 0 else { return nil }
            return res.stdout
        }

        guard let initialUnixLsof = await captureUnixLsof() else { return .separate }
        var connectedCodexPIDs = parseConnectedCodexClientPIDs(
            unixLsofOutput: initialUnixLsof,
            sharedSocketPaths: sharedTarget.socketPaths,
            processes: processes,
            expectedUID: currentUID,
            requireManagedFrontDoor: sharedTarget.requiresManagedFrontDoor,
            expectedConfigURL: sharedTarget.expectedConfigURL,
            expectedBackendSocketPaths: sharedTarget.expectedBackendSocketPaths,
            activeAgentdPID: activeAgentd.pid
        )
        if connectedCodexPIDs.isEmpty {
            // 若桌面端已连上候选共享 socket 但活动 agentd 当前空闲无打开的 Unix socket FD，
            // 通过一次性只读网关探针让活动 Mimi agentd 真实连接其当前后端，再核验双方命中同一实时端点。
            let desktopOnlyPIDs = parseConnectedCodexClientPIDs(
                unixLsofOutput: initialUnixLsof,
                sharedSocketPaths: sharedTarget.socketPaths,
                processes: processes,
                expectedUID: currentUID,
                requireManagedFrontDoor: sharedTarget.requiresManagedFrontDoor,
                expectedConfigURL: sharedTarget.expectedConfigURL,
                expectedBackendSocketPaths: sharedTarget.expectedBackendSocketPaths
            )
            guard !desktopOnlyPIDs.isEmpty else { return .separate }
            guard let probeChannel = try? await LocalGatewayClient(requestTimeout: 5)
                .openCodexProbeChannel(port: activeAgentd.listenPort) else {
                return .separate
            }
            defer { probeChannel.close() }
            guard let liveUnixLsof = await captureUnixLsof() else { return .separate }
            connectedCodexPIDs = parseConnectedCodexClientPIDs(
                unixLsofOutput: liveUnixLsof,
                sharedSocketPaths: sharedTarget.socketPaths,
                processes: processes,
                expectedUID: currentUID,
                requireManagedFrontDoor: sharedTarget.requiresManagedFrontDoor,
                expectedConfigURL: sharedTarget.expectedConfigURL,
                expectedBackendSocketPaths: sharedTarget.expectedBackendSocketPaths,
                activeAgentdPID: activeAgentd.pid
            )
        }
        guard !connectedCodexPIDs.isEmpty else { return .separate }
        var sshdAncestorSet: Set<Int32> = []
        for codexPID in connectedCodexPIDs {
            let ancestors = sshdAncestorPIDs(for: codexPID, processes: processes, expectedUID: currentUID)
            // 过滤为当前用户可检视的 sshd-session PID，避免非 root 调用 lsof 因 root sshd 父进程返回非零退出码。
            let inspectable = ancestors.filter { processes[$0]?.uid == currentUID }
            sshdAncestorSet.formUnion(inspectable.isEmpty ? ancestors : inspectable)
        }
        guard !sshdAncestorSet.isEmpty else { return .separate }

        let sshdPIDList = sshdAncestorSet.sorted().map(String.init).joined(separator: ",")
        let serverLsofResult = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-p", sshdPIDList, "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn"],
            timeout: .seconds(5),
            outputLimit: 1_048_576
        )
        guard let serverLsofResult, serverLsofResult.status == 0 else { return .separate }
        let serverConnsByPID = parseEstablishedTCPConnections(lsofOutput: serverLsofResult.stdoutText)

        guard hasCorrelatedSSHAuthenticatedCodexSession(
            processes: processes,
            expectedUID: currentUID,
            connectedCodexPIDs: connectedCodexPIDs,
            verifiedClientTuples: verifiedClientTuples,
            serverConnectionsByPID: serverConnsByPID
        ) else {
            return .separate
        }
        return .shared
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

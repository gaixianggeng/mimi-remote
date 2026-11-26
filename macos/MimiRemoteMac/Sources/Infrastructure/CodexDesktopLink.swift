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

        let codex: CodexSection?
        let appServer: AppServerSection?

        enum CodingKeys: String, CodingKey {
            case codex
            case appServer = "app_server"
        }
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

    /// 定位当前用户运行中的 `agentd serve` 实际使用的配置文件路径（优先运行中进程的 `--config`，其次 `AGENTD_CONFIG`，最后默认配置路径）。
    static func agentdConfigURL(
        processes: [Int32: ProcessSnapshotEntry] = [:],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedUID: uid_t = Darwin.geteuid()
    ) -> URL {
        for entry in processes.values.sorted(by: { $0.pid < $1.pid }) where entry.uid == expectedUID {
            if let rawPath = extractAgentdServeConfigPath(from: entry) {
                return URL(fileURLWithPath: expandHomePrefix(rawPath, homeDirectory: homeDirectory), isDirectory: false)
            }
        }

        if let envConfig = environment["AGENTD_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envConfig.isEmpty {
            return URL(fileURLWithPath: expandHomePrefix(envConfig, homeDirectory: homeDirectory), isDirectory: false)
        }
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mimi-remote", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
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

    /// 按 `agentd` 实际配置的 transport 与公共 `CODEX_HOME` 解析共享 Codex App Server 控制 socket 路径集合（不读取 GUI 的 `CODEX_HOME`，也不在配置自定义目录时额外放行默认 `~/.codex`）。
    /// 与 `agentd`（`internal/config/config.go`）对齐：缺失配置或省略 `app_server.transport` 时默认 transport 为 `ssh`，仅当显式配置 `local` 且启用 Codex 时返回本机共享控制 socket。
    static func sharedCodexControlSocketPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        expectedUID: uid_t = Darwin.geteuid(),
        agentdConfigURL: URL? = nil,
        processes: [Int32: ProcessSnapshotEntry] = [:]
    ) -> Set<String> {
        let configURL = agentdConfigURL ?? Self.agentdConfigURL(
            processes: processes,
            homeDirectory: homeDirectory,
            environment: environment,
            expectedUID: expectedUID
        )

        let effectiveCodexHome: URL
        switch loadAgentdCodexConfig(at: configURL, expectedUID: expectedUID) {
        case .invalid, .missing:
            // agentd 缺失配置或配置无效时不会启用本机共享 local socket（默认 transport 为 ssh）。
            return []
        case .loaded(let cfg):
            if cfg.codex?.enabled == false {
                return []
            }
            let rawTransport = cfg.appServer?.transport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let effectiveTransport = rawTransport.isEmpty ? "ssh" : rawTransport
            guard effectiveTransport == "local" else {
                return []
            }
            // 与前门（internal/appserver/front_door_darwin.go）一致：
            // app_server.shared_codex_home 仅隔离私有后端历史（app-server-backend.sock），
            // 公共控制 socket（app-server-control.sock）始终按 codex.env.CODEX_HOME（缺失时回退 ~/.codex）定位。
            if let sharedHome = cfg.appServer?.sharedCodexHome, !sharedHome.isEmpty {
                guard sharedHome.hasPrefix("/") else {
                    return []
                }
            }
            if let configuredHome = cfg.codex?.env?["CODEX_HOME"], !configuredHome.isEmpty {
                guard configuredHome.hasPrefix("/") else {
                    return []
                }
                effectiveCodexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
            } else {
                effectiveCodexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            }
        }

        var paths: Set<String> = []
        let controlDir = effectiveCodexHome.appendingPathComponent("app-server-control", isDirectory: true)
        let socketURL = controlDir.appendingPathComponent("app-server-control.sock", isDirectory: false)
        paths.insert(socketURL.standardizedFileURL.path)

        let resolvedDir = controlDir.resolvingSymlinksInPath()
        let canonicalSocket = resolvedDir.appendingPathComponent("app-server-control.sock", isDirectory: false).path
        paths.insert(canonicalSocket)

        var st = stat()
        if Darwin.lstat(socketURL.path, &st) == 0,
           (st.st_mode & S_IFMT) == S_IFLNK,
           st.st_uid == expectedUID {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            let len = Darwin.readlink(socketURL.path, &buf, buf.count - 1)
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
        return paths
    }

    /// 从 `lsof -nP -a -U -u <uid> -F0pcfdtn` 输出解析当前已连接到共享 Codex 控制 socket 的 `codex` 客户端进程 PID 集合。
    static func parseConnectedCodexClientPIDs(
        unixLsofOutput: Data,
        sharedSocketPaths: Set<String>
    ) -> Set<Int32> {
        guard !sharedSocketPaths.isEmpty, !unixLsofOutput.isEmpty else { return [] }
        struct UnixSocketFile {
            var pid: Int32 = 0
            var command: String = ""
            var kind: String = ""
            var address: String = ""
            var name: String = ""
        }

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

        var serverAddresses: Set<String> = []
        for file in files where file.address.hasPrefix("0x") && sharedSocketPaths.contains(file.name) {
            serverAddresses.insert(file.address)
        }
        guard !serverAddresses.isEmpty else { return [] }

        var connectedCodexPIDs: Set<Int32> = []
        for file in files where file.name.hasPrefix("->") {
            let peerAddress = String(file.name.dropFirst(2))
            guard serverAddresses.contains(peerAddress) else { continue }
            let cmd = file.command
            let isCodexCommand = cmd == "codex" ||
                cmd.hasPrefix("codex-aarch64") ||
                cmd.hasPrefix("codex-x86_64") ||
                cmd == "codex-aar" ||
                cmd == "codex-x86"
            if isCodexCommand {
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
        sharedSocketPaths: Set<String>
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
            sharedSocketPaths: sharedSocketPaths
        )
        return hasCorrelatedSSHAuthenticatedCodexSession(
            processes: processes,
            expectedUID: expectedUID,
            connectedCodexPIDs: connectedCodexPIDs,
            verifiedClientTuples: verifiedClientTuples,
            serverConnectionsByPID: connectionsByPID
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
        for (pid, entry) in processes where entry.uid == currentUID && entry.rawCommand.contains("agentd") {
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

        // 2. 查询当前账号已连 agentd 实际共享 Codex 控制 socket 的 codex 客户端进程，收集其当前用户持有的 sshd/sshd-session 祖先 PID，
        //    并通过服务端 TCP 四元组与桌面 ssh 客户端四元组精确镜像匹配，确保二者属于同一条已认证 SSH 会话。
        let unixLsofResult = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-U", "-u", String(currentUID), "-F0pcfdtn"],
            timeout: .seconds(5),
            outputLimit: 1_048_576
        )
        guard let unixLsofResult, unixLsofResult.status == 0 else { return .separate }
        let sharedSockets = sharedCodexControlSocketPaths(expectedUID: currentUID, processes: processes)
        let connectedCodexPIDs = parseConnectedCodexClientPIDs(
            unixLsofOutput: unixLsofResult.stdout,
            sharedSocketPaths: sharedSockets
        )
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

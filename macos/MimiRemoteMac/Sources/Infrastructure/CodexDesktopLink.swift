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

    static let sshSettingsURL = URL(string: "codex://settings/ssh")!
    static let connectionsSettingsURL = URL(string: "codex://settings/connections")!

    /// OpenSSH 中会消费后一个参数值的短选项集合，用于准确提取 ssh 命令的目标主机而非把 `-J`/`-o` 参数或远端命令当主机。
    private static let sshOptionsRequiringArgument: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
        "-L", "-l", "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S", "-W", "-w",
    ]

    static func url(threadID: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !threadID.isEmpty, threadID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }

    /// 从 `ps -axo pid=,ppid=,command=` 的输出里找桌面版名下连到本机的 ssh 子进程。
    static func hasLocalSSHChild(psOutput: String, desktopPIDs: Set<Int32>, localHosts: Set<String>) -> Bool {
        guard !desktopPIDs.isEmpty else { return false }
        let hosts = Set(localHosts.map { $0.lowercased() })
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let ppid = Int32(fields[1]), desktopPIDs.contains(ppid) else { continue }
            guard fields[2] == "ssh" || fields[2].hasSuffix("/ssh") else { continue }
            guard let destinationHost = extractSSHDestinationHost(from: Array(fields.dropFirst(3))) else { continue }
            if hosts.contains(destinationHost.lowercased()) {
                return true
            }
        }
        return false
    }

    static func extractSSHDestinationHost(from args: [Substring]) -> String? {
        var idx = 0
        while idx < args.count {
            let token = String(args[idx])
            if token == "--" {
                idx += 1
                guard idx < args.count else { return nil }
                return extractHostComponent(from: String(args[idx]))
            }
            if token.hasPrefix("-"), token.count > 1 {
                if sshOptionsRequiringArgument.contains(token) {
                    idx += 2
                } else {
                    idx += 1
                }
                continue
            }
            return extractHostComponent(from: token)
        }
        return nil
    }

    private static func extractHostComponent(from destination: String) -> String? {
        let withoutScheme: String
        if destination.lowercased().hasPrefix("ssh://") {
            guard let parsed = URL(string: destination), let host = parsed.host, !host.isEmpty else {
                return nil
            }
            return host
        } else {
            withoutScheme = destination
        }
        let hostPart = withoutScheme.split(separator: "@").last.map(String.init) ?? withoutScheme
        guard !hostPart.isEmpty else { return nil }
        return hostPart
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
        return hasLocalSSHChild(
            psOutput: result.stdoutText,
            desktopPIDs: pids,
            localHosts: localHosts(includeManagedAlias: allowManagedAlias)
        ) ? .shared : .separate
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

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
            let pointsHere = fields.dropFirst(3).contains { field in
                let host = field.split(separator: "@").last.map(String.init) ?? String(field)
                return hosts.contains(host.lowercased())
            }
            if pointsHere { return true }
        }
        return false
    }

    static func localHosts() -> Set<String> {
        var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        let name = ProcessInfo.processInfo.hostName
        if !name.isEmpty {
            hosts.insert(name)
            if let short = name.split(separator: ".").first { hosts.insert(String(short)) }
        }
        return hosts
    }

    @MainActor
    static func connection() async -> Connection {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: SessionOpenTarget.codexDesktopBundleID)
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty else { return .notRunning }
        let result = try? await ProcessExecutor.shared.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,command="],
            timeout: .seconds(5),
            outputLimit: 4_194_304
        )
        guard let result, result.status == 0 else { return .separate }
        return hasLocalSSHChild(psOutput: result.stdoutText, desktopPIDs: pids, localHosts: localHosts()) ? .shared : .separate
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

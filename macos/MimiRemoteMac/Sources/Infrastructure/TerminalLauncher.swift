import AppKit
import Foundation

/// 在本机终端继续一条会话所需的命令，由 agentd 按配置生成（#991）。
struct TerminalHandoffCommand: Decodable, Equatable, Sendable {
    let cwd: String
    let argv: [String]
}

/// 把命令写成一次性的 .command 脚本，交给用户选的终端打开。
/// 不用 AppleScript 控制终端，免去「自动化」授权。
enum TerminalLauncher {
    static func script(for command: TerminalHandoffCommand) -> String {
        let invocation = command.argv.map(shellQuoted).joined(separator: " ")
        return """
        #!/bin/zsh -l
        # Mimi Remote：在终端继续会话。脚本只用一次，打开后即删除。
        rm -f -- "$0"
        cd -- \(shellQuoted(command.cwd)) || exit 1
        exec \(invocation)

        """
    }

    /// POSIX 单引号转义：单引号内一切按字面量处理，只有单引号本身要拆开拼接。
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Herdr 的窗口命令：在当前空间开一个新标签运行脚本。用单个 JSON 参数，标题里的任何字符都不会被当成选项。
    static func herdrArguments(scriptPath: String, cwd: String, title: String) -> [String] {
        let payload: [String: Any] = [
            "name": String(title.prefix(40)),
            "folder": cwd,
            "argv": ["/bin/zsh", "-l", scriptPath],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ["do", "tab.new", String(decoding: data, as: UTF8.self)]
    }

    @MainActor
    static func launch(_ command: TerminalHandoffCommand, in app: TerminalApp, title: String) async throws {
        guard !command.argv.isEmpty else { throw AgentClientError.commandFailed("没有可以在终端运行的命令。") }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw AgentClientError.commandFailed("没有找到 \(app.title)。")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "mimi-handoff", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "continue-\(UUID().uuidString.prefix(8)).command")
        try Data(script(for: command).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        do {
            switch app {
            case .herdr:
                try await openInHerdr(appURL: appURL, scriptPath: url.path, cwd: command.cwd, title: title)
            case .ghostty, .terminal:
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AgentClientError.commandFailed("没能在 \(app.title) 里打开：\(error.localizedDescription)")
        }
    }

    /// Herdr 不接收脚本文件，要经它自带的窗口命令开标签；窗口没开时先打开并等它就绪。
    @MainActor
    private static func openInHerdr(appURL: URL, scriptPath: String, cwd: String, title: String) async throws {
        let executable = appURL.appending(path: "Contents/MacOS/Herdr")
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        var ready = false
        for _ in 0..<20 {
            let status = try? await ProcessExecutor.shared.run(executable: executable, arguments: ["status"], timeout: .seconds(5))
            if status?.status == 0 { ready = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard ready else { throw AgentClientError.commandFailed("Herdr 的窗口没有就绪。") }
        let result = try await ProcessExecutor.shared.run(
            executable: executable,
            arguments: herdrArguments(scriptPath: scriptPath, cwd: cwd, title: title),
            timeout: .seconds(10)
        )
        guard result.status == 0 else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentClientError.commandFailed(detail.isEmpty ? "Herdr 没有接受命令。" : String(detail.prefix(200)))
        }
    }
}

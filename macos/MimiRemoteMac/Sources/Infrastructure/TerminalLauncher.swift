import AppKit
import Foundation

/// 在本机终端继续一条会话所需的命令，由 agentd 按配置生成（#991）。
struct TerminalHandoffCommand: Decodable, Equatable, Sendable {
    let cwd: String
    let argv: [String]
}

/// 把命令写成一次性的 .command 脚本，交给系统默认的终端打开。
/// 不用 AppleScript 控制终端，免去「自动化」授权，也尊重用户设置的默认终端。
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

    @MainActor
    static func launch(_ command: TerminalHandoffCommand) throws {
        guard !command.argv.isEmpty else { throw AgentClientError.commandFailed("没有可以在终端运行的命令。") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "mimi-handoff", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "continue-\(UUID().uuidString.prefix(8)).command")
        try Data(script(for: command).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else {
            try? FileManager.default.removeItem(at: url)
            throw AgentClientError.commandFailed("没能打开终端。")
        }
    }
}

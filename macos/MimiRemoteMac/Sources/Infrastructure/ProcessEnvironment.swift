import Foundation

enum ProcessEnvironment {
    /// Finder 启动的 App 通常拿不到交互式 shell 的 PATH，这里只补受信任的常用工具目录。
    static let userTooling: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let current = environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (requiredPaths + current)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }()
}

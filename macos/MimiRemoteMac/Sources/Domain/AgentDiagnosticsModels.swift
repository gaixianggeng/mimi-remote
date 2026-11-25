import Foundation

struct AgentDiagnosticsStatus: Decodable, Equatable, Sendable {
    let enabled: Bool
    let expiresAt: String?
    let currentBytes: Int64
    let previousBytes: Int64
    let totalBytes: Int64
    let maxTotalBytes: Int64
    let retentionDays: Int
    let droppedRecords: Int64
    /// 本机调试日志的大小；只在详细记录窗口内写入，不进入安全日志导出。旧版 agentd 不返回。
    let debugBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case enabled
        case expiresAt = "expires_at"
        case currentBytes = "current_bytes"
        case previousBytes = "previous_bytes"
        case totalBytes = "total_bytes"
        case maxTotalBytes = "max_total_bytes"
        case retentionDays = "retention_days"
        case droppedRecords = "dropped_records"
        case debugBytes = "debug_bytes"
    }

    init(
        enabled: Bool,
        expiresAt: String?,
        currentBytes: Int64,
        previousBytes: Int64,
        totalBytes: Int64,
        maxTotalBytes: Int64,
        retentionDays: Int,
        droppedRecords: Int64 = 0,
        debugBytes: Int64 = 0
    ) {
        self.enabled = enabled
        self.expiresAt = expiresAt
        self.currentBytes = currentBytes
        self.previousBytes = previousBytes
        self.totalBytes = totalBytes
        self.maxTotalBytes = maxTotalBytes
        self.retentionDays = retentionDays
        self.droppedRecords = droppedRecords
        self.debugBytes = debugBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        currentBytes = try container.decode(Int64.self, forKey: .currentBytes)
        previousBytes = try container.decode(Int64.self, forKey: .previousBytes)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        maxTotalBytes = try container.decode(Int64.self, forKey: .maxTotalBytes)
        retentionDays = try container.decode(Int.self, forKey: .retentionDays)
        droppedRecords = try container.decodeIfPresent(Int64.self, forKey: .droppedRecords) ?? 0
        debugBytes = try container.decodeIfPresent(Int64.self, forKey: .debugBytes) ?? 0
    }

    var expirationDate: Date? {
        guard let expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expiresAt)
            ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

struct AgentDiagnosticsExport: Decodable, Equatable, Sendable {
    let lines: [String]
}

/// 诊断展示与折叠日志脱敏器：确保界面和导出中不出现 bearer、WS/Harness 凭据、
/// grant、签名、配对/连接 URL、用户主目录路径或非回环 IP。
enum DiagnosticLogSanitizer {
    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, options: NSRegularExpression.Options = [], template: String) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    private static let rules: [Rule] = [
        // 配对与连接深链（含短期票据与签名）
        Rule(#"mimiremote://[^\s"'<>]+"#, options: [.caseInsensitive], template: "[REDACTED_PAIR_URL]"),
        // 含敏感查询参数的 HTTP/HTTPS/WS 链接（如 Harness 启动链接或中转授权链接）
        Rule(
            #"(?:https?|wss?)://[^\s"'<>]*[?&](?:token|pair_sig|grant|sig|signature|secret|auth|key|ws_token|harness_token|dsh_token)=[^\s"'<>]+"#,
            options: [.caseInsensitive],
            template: "[REDACTED_URL]"
        ),
        // Authorization / Bearer 头（先整体脱敏 Authorization，再脱敏独立 Bearer）
        Rule(
            #"\bAuthorization\s*:\s*(?:(?:Bearer|Basic|Token)\s+)?[^\s,;\"'}\]<>]+"#,
            options: [.caseInsensitive],
            template: "Authorization: [REDACTED]"
        ),
        Rule(#"\bBearer\s+[A-Za-z0-9._~+/=-]+"#, options: [.caseInsensitive], template: "Bearer [REDACTED]"),
        // JSON 敏感字段
        Rule(
            #"\"((?:access_|refresh_|host_|ws_|harness_|dsh_|session_)?token|bearer|authorization|pair_url|connect_url|startup_url|grant|signature|pair_sig|secret|api_key|password)\"\s*:\s*\"[^\"]*\""#,
            options: [.caseInsensitive],
            template: "\"$1\":\"[REDACTED]\""
        ),
        // 键值对/查询串敏感参数
        Rule(
            #"\b((?:access_|refresh_|host_|ws_|harness_|dsh_|session_)?token|pair_url|connect_url|startup_url|grant|signature|pair_sig|secret|api_key|password)=([^\s&\"',;}\]]+)"#,
            options: [.caseInsensitive],
            template: "$1=[REDACTED]"
        ),
        // 本地用户路径脱敏（不暴露本机用户名）
        Rule(#"/Users/[^/\s\"':,;)\]]+"#, template: "~"),
        Rule(#"/home/[^/\s\"':,;)\]]+"#, template: "~"),
        Rule(#"[A-Za-z]:\\Users\\[^\\\s\"':,;)\]]+"#, template: "~"),
        // 非回环 IPv4（排除 127.0.0.1 与版本号）
        Rule(
            #"(?<![0-9.])(?!127\.0\.0\.1(?![0-9.]))(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![0-9.])"#,
            template: "[REDACTED_IP]"
        ),
    ]

    static func sanitizeLine(_ raw: String) -> String {
        var result = raw
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }

    static func sanitizeLines(_ lines: [String]) -> [String] {
        lines.map(sanitizeLine)
    }
}

/// `doctor --json` 的只读展示模型：仅映射中文标题与脱敏折叠说明，严禁派生任何可点击修复操作。
struct DoctorDisplayCheck: Equatable, Identifiable, Sendable {
    let id: String
    let localizedTitle: String
    let ok: Bool
    let isWarning: Bool
    let sanitizedMessage: String
    let sanitizedDetail: String?
}

enum DoctorCheckPresentation {
    static func localizedTitle(for rawName: String) -> String {
        switch rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "config", "config_store", "config_file":
            "配置文件"
        case "workspace", "workspace_root", "projects", "scan_root":
            "代码目录"
        case "service", "service_daemon", "daemon", "launchd":
            "后台服务"
        case "listen", "listener", "network":
            "网络监听"
        case "codex", "codex_cli", "codex_app_server":
            "Codex 运行环境"
        case "claude", "claude_cli", "claude_bridge":
            "Claude Code 运行环境"
        case "agy", "antigravity":
            "Antigravity 运行环境"
        case "deepseek", "harness":
            "DeepSeek Harness"
        case "tailscale":
            "Tailscale 网络"
        case "tailcat":
            "内置连接（Tailcat）"
        case "lan", "local_network":
            "同一局域网"
        case "permissions", "file_access":
            "文件访问权限"
        default:
            "底层检查项"
        }
    }

    static func make(from check: AgentCheck) -> DoctorDisplayCheck {
        let message = DiagnosticLogSanitizer.sanitizeLine(check.message)
        let detail = check.fix
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : DiagnosticLogSanitizer.sanitizeLine($0) }
        return DoctorDisplayCheck(
            id: check.id,
            localizedTitle: localizedTitle(for: check.name),
            ok: check.ok,
            isWarning: check.isWarning,
            sanitizedMessage: message,
            sanitizedDetail: detail
        )
    }
}

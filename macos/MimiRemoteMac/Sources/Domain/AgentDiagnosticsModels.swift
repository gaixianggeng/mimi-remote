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
    // Match the fixed vocabulary of internal/diagnosticlog.Event. Legacy text and unknown
    // fields may contain command output. Re-encode the safe fields for display and export.
    private struct Event: Codable {
        let at: String
        let stage: String
        let outcome: String
        var operation: String?
        var reference: String?
        let status_code: Int?
        let duration_ms: Int64?
    }

    static func eventLines(_ lines: [String]) -> [String] {
        let stages = ["service", "http", "gateway_connect", "gateway_disconnect", "rpc_request", "rpc_response",
                      "policy", "turn_started", "turn_completed", "approval", "bridge", "permissions"]
        let outcomes = ["started", "stopped", "sent", "received", "succeeded", "failed", "cancelled", "rejected"]
        let operations = ["thread/list", "thread/read", "thread/resume", "thread/start", "thread/turns/list",
                          "thread/items/list", "turn/start", "turn/steer", "turn/interrupt", "thread/takeover", "approval", "other"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return lines.compactMap { line in
            guard var event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)),
                  stages.contains(event.stage), outcomes.contains(event.outcome),
                  OnboardingDateParser.isValidRFC3339(event.at, requireUTC: false) else { return nil }
            if let op = event.operation, !operations.contains(op) { event.operation = "other" }
            if let ref = event.reference, ref.range(of: #"^[0-9a-f]{16}\z"#, options: .regularExpression) == nil {
                event.reference = nil
            }
            return (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) }
        }
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
        switch rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "config", "config_store", "config_file", "token", "app_server_token_file":
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
        case "agy", "antigravity", "agy_adapter":
            "Antigravity 运行环境"
        case "deepseek", "harness", "deepseek_harness":
            "DeepSeek Harness"
        case "tailscale":
            "Tailscale 网络"
        case "tailcat":
            "内置连接（Tailcat）"
        case "lan", "local_network":
            "同一局域网"
        case "permissions", "file_access", "file_access_preflight":
            "文件访问权限"
        default:
            "底层检查项"
        }
    }

    static func make(from check: AgentCheck) -> DoctorDisplayCheck {
        // Legacy checks can put stderr, SSH commands or credentials into either free-text field.
        // Keep reviewed literal hints; use local copy for dynamic/private output.
        let safeMessages = ["检测到 Tailscale 命令", "后台服务已就绪。", "Codex 在 Mimi 中已关闭",
                            "SSH App Server 配置无效", "本机 Codex CLI 版本或传输不兼容",
                            "SSH host key、非交互密钥或远程 Codex 版本检查失败"]
        let safeHints = ["检查配置的 Codex 路径或升级 Codex CLI", "检查 app_server.ssh_target",
                         "安装并登录 Tailscale：https://tailscale.com/download", "检查文件所有者和权限",
                         "改用当前用户拥有的普通文件", "确认当前用户可以执行 launchctl 后重试"]
        let message = safeMessages.contains(check.message) ? check.message : (check.ok ? "检查通过。" : "检查未通过。")
        let detail = check.fix.flatMap { hint in
            hint.isEmpty ? nil : (safeHints.contains(hint) ? hint : "请参照上方对应的预检项目处理。")
        }
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

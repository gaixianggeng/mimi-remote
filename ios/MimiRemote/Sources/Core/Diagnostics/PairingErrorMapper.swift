import Foundation

/// iOS HTTP pairing error contract decoder and action mapper for
/// `application/vnd.mimi.onboarding.v1+json` (`onboarding-codes-v1.json`).
enum PairingOnboardingFixURL: String, CaseIterable, Equatable, Hashable, Sendable {
    case codex = "https://learn.chatgpt.com/docs/codex/cli"
    case claude = "https://code.claude.com/docs/en/quickstart"
    case agy = "https://antigravity.google/"
    case harness = "https://github.com/deepseek-ai/deepseek-harness"
    case tailscale = "https://tailscale.com/download"
    case desktop = "https://github.com/gaixianggeng/mimi-remote/releases/latest"
    case guide = "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md"

    var key: String {
        switch self {
        case .codex: "CODEX"
        case .claude: "CLAUDE"
        case .agy: "AGY"
        case .harness: "HARNESS"
        case .tailscale: "TS"
        case .desktop: "DESKTOP"
        case .guide: "GUIDE"
        }
    }

    var url: URL {
        URL(string: rawValue)!
    }
}

enum PairingOnboardingStep: String, CaseIterable, Equatable, Hashable, Sendable {
    case configStore = "config_store"
    case workspaceRoot = "workspace_root"
    case serviceOwnerConflict = "service_owner_conflict"
    case serviceDaemon = "service_daemon"
    case assistantCodex = "assistant_codex"
    case assistantClaude = "assistant_claude"
    case assistantAgy = "assistant_agy"
    case assistantDeepSeek = "assistant_deepseek"
    case assistantAny = "assistant_any"
    case networkTailscale = "network_tailscale"
    case networkTailcat = "network_tailcat"
    case networkLAN = "network_lan"
    case networkAny = "network_any"
    case permissionLoginItem = "permission_login_item"
    case permissionFolderAccess = "permission_folder_access"
    case permissionLocalNetwork = "permission_local_network"
    case permissionPhotos = "permission_photos"
    case permissionFullDisk = "permission_full_disk"

    var localizedTitle: String {
        switch self {
        case .configStore: "配置文件"
        case .workspaceRoot: "代码目录"
        case .serviceOwnerConflict: "后台服务归属"
        case .serviceDaemon: "后台服务"
        case .assistantCodex: "Codex 助手"
        case .assistantClaude: "Claude Code 助手"
        case .assistantAgy: "Antigravity 助手"
        case .assistantDeepSeek: "DeepSeek 助手"
        case .assistantAny: "可用助手"
        case .networkTailscale: "Tailscale 连接"
        case .networkTailcat: "内置连接"
        case .networkLAN: "同一局域网"
        case .networkAny: "手机连接方式"
        case .permissionLoginItem: "登录项"
        case .permissionFolderAccess: "文件与文件夹"
        case .permissionLocalNetwork: "本地网络"
        case .permissionPhotos: "照片"
        case .permissionFullDisk: "完全磁盘访问"
        }
    }
}

enum PairingOnboardingWireFix: Equatable, Hashable, Sendable, Decodable {
    case openURL(PairingOnboardingFixURL)
    case openSettings(String)
    case choosePath(String)
    case runFix(String)
    case retry
    case skip

    static let allowedSettingsTargets: Set<String> = [
        "login_items", "files_and_folders", "local_network", "photos",
        "full_disk_access", "windows_firewall", "windows_network_profile",
        "assistants", "connections", "host_recovery", "date_time", "managed_connection",
    ]

    static let allowedPathTargets: Set<String> = [
        "workspace_root", "codex_bin", "claude_bin", "agy_bin",
    ]

    static let allowedRunFixActions: Set<String> = [
        "save_setup", "enable_codex", "enable_claude", "enable_agy",
        "enable_tailscale", "enable_lan", "enable_tailcat", "connect_deepseek",
        "restart_service", "register_service", "doctor_fix", "takeover_homebrew",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PairingDynamicCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard let kindKey = PairingDynamicCodingKey(stringValue: "kind"),
              let kind = try container.decodeIfPresent(String.self, forKey: kindKey)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "fix missing kind")
            )
        }
        switch kind {
        case "retry":
            guard keys == ["kind"] else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "extra field on retry fix")
                )
            }
            self = .retry
        case "skip":
            guard keys == ["kind"] else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "extra field on skip fix")
                )
            }
            self = .skip
        case "open_url":
            guard keys == ["kind", "url"],
                  let urlKey = PairingDynamicCodingKey(stringValue: "url"),
                  let rawURL = try container.decodeIfPresent(String.self, forKey: urlKey),
                  let allowed = PairingOnboardingFixURL(rawValue: rawURL)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid or disallowed open_url")
                )
            }
            self = .openURL(allowed)
        case "open_settings":
            guard keys == ["kind", "target"],
                  let targetKey = PairingDynamicCodingKey(stringValue: "target"),
                  let target = try container.decodeIfPresent(String.self, forKey: targetKey),
                  Self.allowedSettingsTargets.contains(target)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid open_settings target")
                )
            }
            self = .openSettings(target)
        case "choose_path":
            guard keys == ["kind", "target"],
                  let targetKey = PairingDynamicCodingKey(stringValue: "target"),
                  let target = try container.decodeIfPresent(String.self, forKey: targetKey),
                  Self.allowedPathTargets.contains(target)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid choose_path target")
                )
            }
            self = .choosePath(target)
        case "run_fix":
            guard keys == ["kind", "action"],
                  let actionKey = PairingDynamicCodingKey(stringValue: "action"),
                  let action = try container.decodeIfPresent(String.self, forKey: actionKey),
                  Self.allowedRunFixActions.contains(action)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid run_fix action")
                )
            }
            self = .runFix(action)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown fix kind \(kind)")
            )
        }
    }
}

/// Safe iOS-side action produced by `PairingErrorMapper`. Never contains `App-Prefs:`
/// URLs or host-side execution commands; untrusted/unknown payloads yield `.none`.
enum PairingErrorAction: Equatable, Sendable {
    case none
    case retry
    case openURL(PairingOnboardingFixURL)
    case openManagedConnection
    case showDateTimeGuidanceAndRetry(instructions: String)
    case desktopGuidanceAndRescan(instructions: String)
}

struct MappedPairingError: Equatable, Sendable {
    let code: String?
    let step: PairingOnboardingStep?
    let message: String
    let action: PairingErrorAction
    let wireFix: PairingOnboardingWireFix?
    let isTrusted: Bool
    let preservesSavedProfiles: Bool
    let isLegacyFallback: Bool
}

struct PairingErrorCatalogEntry: Equatable, Sendable {
    let code: String
    let isUILocal: Bool
    let steps: [PairingOnboardingStep]
    let allowsAnyStep: Bool
    let allowedFixes: [PairingOnboardingWireFix]
    let messageZH: String
}

enum PairingErrorMapper {
    static let acceptMediaType = "application/vnd.mimi.onboarding.v1+json"
    static let explicitClaimTimeoutSeconds: TimeInterval = 45
    static let localDiscoveryTimeoutSeconds: TimeInterval = 2
    static let safeFallbackCopy = "配对未能完成。请确认电脑端状态后重新扫码或重试，已有配对不受影响。"
    static let dateTimeInstructionsZH = "请前往系统“设置 → 通用 → 日期与时间”开启自动设置，确认电脑与手机时间一致后重新配对。"

    static let negotiatedPaths: [String] = [
        "/api/pair/claim",
        "/api/pair/local",
        "/api/tailcat/managed-pairing-link",
        "/api/tailcat/managed-pairing-operations",
        "/api/tailcat/free-route",
    ]

    static let httpForbiddenFields: Set<String> = [
        "config_path", "recovery_path", "candidates", "detected_version", "min_version",
        "source", "scan_root", "browse_root", "endpoint", "pair_url", "stderr",
        "path", "host", "host_id", "runtime", "runtime_status", "config",
        "scan_root_exists", "tailscale_dns_name", "tailscale_device_name", "device_id",
        "raw_stderr", "grant", "signature", "token", "token_file", "connect_url",
    ]

    /// Complete catalog of all HTTP wire codes applicable to iOS (15) plus
    /// the 2 UI-local codes (`command_timeout`, `embedded_binary_missing`).
    static let catalogEntries: [PairingErrorCatalogEntry] = [
        // 15 HTTP wire codes applicable to iOS
        .init(
            code: "no_enabled_assistant", isUILocal: false, steps: [.assistantAny], allowsAnyStep: false,
            allowedFixes: [.openURL(.guide)],
            messageZH: "请启用至少一个可用助手，然后重新配对。"
        ),
        .init(
            code: "workspace_confirmation_required", isUILocal: false, steps: [.workspaceRoot], allowsAnyStep: false,
            allowedFixes: [.choosePath("workspace_root")],
            messageZH: "请先在电脑上确认要与手机共享的代码目录。"
        ),
        .init(
            code: "tailcat_relay_unreachable", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "暂时无法连接中继。请稍后重试。"
        ),
        .init(
            code: "tailcat_busy", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "内置连接正在处理其他操作。请稍后重试。"
        ),
        .init(
            code: "pair_host_unreachable", isUILocal: false, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "无法连接电脑后台服务。请检查连接后重试。"
        ),
        .init(
            code: "pair_token_mismatch", isUILocal: false, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.runFix("save_setup"), .runFix("restart_service")],
            messageZH: "电脑后台服务身份未同步。请在电脑端确认服务归属并重新加载配置后重试，无需删除手机上的已保存电脑。"
        ),
        .init(
            code: "pair_ticket_expired", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "二维码已过期。请在电脑配对窗口点击“刷新二维码”后重扫，已有配对不受影响。"
        ),
        .init(
            code: "pair_ticket_invalid", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "配对链接无效。请在电脑上刷新二维码后重扫。"
        ),
        .init(
            code: "pair_clock_skew", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.openSettings("date_time")],
            messageZH: "设备时间不一致。请检查系统日期与时间后重新配对。"
        ),
        .init(
            code: "pair_local_forbidden", isUILocal: false, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "此请求无法在本机认领。请使用手机扫描电脑上的二维码。"
        ),
        .init(
            code: "pair_managed_entitlement_required", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.openSettings("managed_connection")],
            messageZH: "此托管连接需要有效的订阅权益。请查看托管连接设置。"
        ),
        .init(
            code: "pair_managed_grant_conflict", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "托管连接授权未生效或已过期。请重新获取配对链接。"
        ),
        .init(
            code: "invalid_request", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageZH: "{title}：请求参数无效。请检查输入后重试。"
        ),
        .init(
            code: "probe_timeout", isUILocal: false, steps: [], allowsAnyStep: true,
            allowedFixes: [.retry],
            messageZH: "{title}：检查超时。请重新检查此项。"
        ),
        .init(
            code: "internal_error", isUILocal: false, steps: [], allowsAnyStep: true,
            allowedFixes: [.retry],
            messageZH: "{title}：未能完成此项操作。请重试。"
        ),
        // 2 UI-local codes (never accepted over HTTP wire)
        .init(
            code: "command_timeout", isUILocal: true, steps: [], allowsAnyStep: true,
            allowedFixes: [.retry],
            messageZH: "{title}：命令等待超时。请重新检查当前步骤。"
        ),
        .init(
            code: "embedded_binary_missing", isUILocal: true, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.openURL(.desktop)],
            messageZH: "缺少内置服务程序。请重新安装桌面端。"
        ),
    ]

    static let entriesByCode: [String: PairingErrorCatalogEntry] = Dictionary(
        uniqueKeysWithValues: catalogEntries.map { ($0.code, $0) }
    )

    static var httpWireCodes: Set<String> {
        Set(catalogEntries.filter { !$0.isUILocal }.map(\.code))
    }

    static var uiLocalCodes: Set<String> {
        Set(catalogEntries.filter(\.isUILocal).map(\.code))
    }

    private struct WireEnvelope: Decodable {
        struct WireDiagnostic: Decodable {
            let code: String
            let step: String
            let message: String
            let fix: PairingOnboardingWireFix
        }
        let ok: Bool
        let error: WireDiagnostic
    }

    static func localizedMessage(
        code: String,
        step: PairingOnboardingStep? = nil,
        title: String? = nil
    ) -> String {
        guard let entry = entriesByCode[code] else {
            return safeFallbackCopy
        }
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? step?.localizedTitle
            ?? PairingOnboardingStep.serviceDaemon.localizedTitle
        return entry.messageZH.replacingOccurrences(of: "{title}", with: resolvedTitle)
    }

    static func synthesizeLocal(
        code: String,
        step: PairingOnboardingStep? = nil,
        title: String? = nil
    ) -> MappedPairingError {
        let resolvedStep = step ?? .serviceDaemon
        guard let entry = entriesByCode[code], entry.isUILocal, let fix = entry.allowedFixes.first else {
            return untrustedFallback(code: code, step: resolvedStep)
        }
        return MappedPairingError(
            code: code,
            step: resolvedStep,
            message: localizedMessage(code: code, step: resolvedStep, title: title),
            action: iosAction(for: fix, code: code),
            wireFix: fix,
            isTrusted: true,
            preservesSavedProfiles: true,
            isLegacyFallback: false
        )
    }

    /// Strictly decodes an HTTP `application/vnd.mimi.onboarding.v1+json` error envelope.
    /// Rejects UI-local codes, non-HTTP codes, private local fields (including nested ones),
    /// unsupported major schemas, unknown URLs/actions, unverified privileged context,
    /// and extra fix parameters (including `rotates_token: true`) with zero execution.
    static func mapHTTPErrorEnvelope(
        data: Data,
        configured: Bool? = nil
    ) -> MappedPairingError {
        guard let topObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return untrustedFallback()
        }
        if hasUnsupportedOnboardingSchema(topObject) || containsForbiddenHTTPField(topObject) {
            return untrustedFallback()
        }
        guard topObject["error"] is [String: Any] else {
            return untrustedFallback()
        }
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              envelope.ok == false
        else {
            return untrustedFallback()
        }
        let code = envelope.error.code
        guard !code.isEmpty,
              !envelope.error.message.isEmpty,
              let step = PairingOnboardingStep(rawValue: envelope.error.step),
              let entry = entriesByCode[code],
              !entry.isUILocal
        else {
            return untrustedFallback(code: code)
        }
        guard entry.allowsAnyStep || entry.steps.contains(step) else {
            return untrustedFallback(code: code, step: step)
        }
        let fix = envelope.error.fix
        guard entry.allowedFixes.contains(fix) else {
            return untrustedFallback(code: code, step: step)
        }
        if code == "pair_token_mismatch" {
            guard let configured else {
                return untrustedFallback(code: code, step: step)
            }
            let expectedFix: PairingOnboardingWireFix = configured ? .runFix("restart_service") : .runFix("save_setup")
            guard fix == expectedFix else {
                return untrustedFallback(code: code, step: step)
            }
        }
        return MappedPairingError(
            code: code,
            step: step,
            message: localizedMessage(code: code, step: step),
            action: iosAction(for: fix, code: code),
            wireFix: fix,
            isTrusted: true,
            preservesSavedProfiles: true,
            isLegacyFallback: false
        )
    }

    private enum MediaTypeClassification {
        case v1
        case unsupportedOnboardingMajor
        case other
    }

    private static func classifyMediaType(_ contentType: String?) -> MediaTypeClassification {
        guard let raw = contentType else { return .other }
        let essence = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if essence == acceptMediaType {
            return .v1
        }
        if essence.hasPrefix("application/vnd.mimi.onboarding.") {
            return .unsupportedOnboardingMajor
        }
        return .other
    }

    private static func hasUnsupportedOnboardingSchema(_ object: [String: Any]) -> Bool {
        if let schemaVal = object["schema"] {
            guard let schema = schemaVal as? String else { return true }
            if schema.hasPrefix("mimi.onboarding.") && !schema.hasSuffix("/v1") {
                return true
            }
        }
        if let errObj = object["error"] as? [String: Any], let schemaVal = errObj["schema"] {
            guard let schema = schemaVal as? String else { return true }
            if schema.hasPrefix("mimi.onboarding.") && !schema.hasSuffix("/v1") {
                return true
            }
        }
        return false
    }

    private static func containsForbiddenHTTPField(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                if httpForbiddenFields.contains(key) || containsForbiddenHTTPField(nested) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            for item in array where containsForbiddenHTTPField(item) {
                return true
            }
        }
        return false
    }

    /// Maps an HTTP pairing response: enforces declared onboarding major version first,
    /// prefers v1 onboarding error envelope, then falls back to recognized legacy host
    /// JSON shapes (`{"error":"...","code":"..."}`).
    static func mapHTTPResponse(
        data: Data,
        statusCode: Int,
        contentType: String? = nil,
        configured: Bool? = nil
    ) -> MappedPairingError {
        switch classifyMediaType(contentType) {
        case .unsupportedOnboardingMajor:
            return untrustedFallback()
        case .v1:
            return mapHTTPErrorEnvelope(data: data, configured: configured)
        case .other:
            if let topObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               hasUnsupportedOnboardingSchema(topObject) {
                return untrustedFallback()
            }
            if looksLikeV1ErrorEnvelope(data) {
                return mapHTTPErrorEnvelope(data: data, configured: configured)
            }
            if let legacy = mapLegacyHTTPError(data: data, statusCode: statusCode) {
                return legacy
            }
            return untrustedFallback()
        }
    }

    private static func mapLegacyHTTPError(data: Data, statusCode: Int) -> MappedPairingError? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawCode = (obj["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mappedCode: String? = switch rawCode {
        case "tailcat_managed_mode_required", "tailcat_managed_grant_required":
            "pair_managed_grant_conflict"
        case "tailcat_agents_disabled":
            "no_enabled_assistant"
        case "tailcat_operation_in_progress":
            "tailcat_busy"
        case let known? where httpWireCodes.contains(known):
            known
        default:
            nil
        }
        if let mappedCode, let entry = entriesByCode[mappedCode] {
            let step = entry.steps.first ?? .serviceDaemon
            let fix = entry.allowedFixes.last ?? .retry
            return MappedPairingError(
                code: mappedCode,
                step: step,
                message: localizedMessage(code: mappedCode, step: step),
                action: iosAction(for: fix, code: mappedCode),
                wireFix: fix,
                isTrusted: true,
                preservesSavedProfiles: true,
                isLegacyFallback: true
            )
        }
        if statusCode == 401 {
            return MappedPairingError(
                code: "pair_ticket_invalid",
                step: .networkAny,
                message: localizedMessage(code: "pair_ticket_invalid", step: .networkAny),
                action: .retry,
                wireFix: .retry,
                isTrusted: true,
                preservesSavedProfiles: true,
                isLegacyFallback: true
            )
        }
        return nil
    }

    private static func looksLikeV1ErrorEnvelope(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = obj["ok"] as? Bool,
              ok == false,
              obj["error"] is [String: Any]
        else {
            return false
        }
        return true
    }

    private static func iosAction(for fix: PairingOnboardingWireFix, code: String) -> PairingErrorAction {
        switch fix {
        case .retry:
            return .retry
        case .openURL(let allowed):
            return .openURL(allowed)
        case .openSettings("date_time"):
            return .showDateTimeGuidanceAndRetry(instructions: dateTimeInstructionsZH)
        case .openSettings("managed_connection") where code == "pair_managed_entitlement_required":
            return .openManagedConnection
        case .choosePath("workspace_root"):
            return .desktopGuidanceAndRescan(instructions: "请先在电脑端确认要共享的代码目录，然后重新扫码。")
        case .runFix("restart_service"), .runFix("save_setup"):
            return .desktopGuidanceAndRescan(instructions: "请在电脑端确认后台服务状态并重新加载配置，然后重新扫码。")
        case .openSettings, .choosePath, .runFix, .skip:
            return .none
        }
    }

    private static func untrustedFallback(
        code: String? = nil,
        step: PairingOnboardingStep? = nil
    ) -> MappedPairingError {
        MappedPairingError(
            code: code,
            step: step,
            message: safeFallbackCopy,
            action: .none,
            wireFix: nil,
            isTrusted: false,
            preservesSavedProfiles: true,
            isLegacyFallback: false
        )
    }
}

private struct PairingDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

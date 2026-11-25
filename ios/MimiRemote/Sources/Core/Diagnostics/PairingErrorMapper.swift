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
        case .configStore: L10n.text("ui.onboarding_step_config_store")
        case .workspaceRoot: L10n.text("ui.onboarding_step_workspace_root")
        case .serviceOwnerConflict: L10n.text("ui.onboarding_step_service_owner_conflict")
        case .serviceDaemon: L10n.text("ui.onboarding_step_service_daemon")
        case .assistantCodex: L10n.text("ui.onboarding_step_assistant_codex")
        case .assistantClaude: L10n.text("ui.onboarding_step_assistant_claude")
        case .assistantAgy: L10n.text("ui.onboarding_step_assistant_agy")
        case .assistantDeepSeek: L10n.text("ui.onboarding_step_assistant_deepseek")
        case .assistantAny: L10n.text("ui.onboarding_step_assistant_any")
        case .networkTailscale: L10n.text("ui.onboarding_step_network_tailscale")
        case .networkTailcat: L10n.text("ui.onboarding_step_network_tailcat")
        case .networkLAN: L10n.text("ui.onboarding_step_network_lan")
        case .networkAny: L10n.text("ui.onboarding_step_network_any")
        case .permissionLoginItem: L10n.text("ui.onboarding_step_permission_login_item")
        case .permissionFolderAccess: L10n.text("ui.onboarding_step_permission_folder_access")
        case .permissionLocalNetwork: L10n.text("ui.onboarding_step_permission_local_network")
        case .permissionPhotos: L10n.text("ui.onboarding_step_permission_photos")
        case .permissionFullDisk: L10n.text("ui.onboarding_step_permission_full_disk")
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

    /// User-facing copy for iOS alerts/banners/scanner failure cards.
    /// Surfaces pure text guidance for `date_time` (never `App-Prefs:`) and desktop rescan instructions.
    var userFacingMessage: String {
        switch action {
        case .showDateTimeGuidanceAndRetry(let instructions), .desktopGuidanceAndRescan(let instructions):
            return instructions
        case .none, .retry, .openURL, .openManagedConnection:
            return message
        }
    }
}

struct PairingErrorCatalogEntry: Equatable, Sendable {
    let code: String
    let isUILocal: Bool
    let steps: [PairingOnboardingStep]
    let allowsAnyStep: Bool
    let allowedFixes: [PairingOnboardingWireFix]
    let messageKey: String

    var messageZH: String {
        L10n.text(messageKey, language: .simplifiedChinese)
    }

    var messageEN: String {
        L10n.text(messageKey, language: .english)
    }
}

enum PairingErrorMapper {
    static let acceptMediaType = "application/vnd.mimi.onboarding.v1+json"
    static let expectedVaryHeaderValue = "Accept"
    static let explicitClaimTimeoutSeconds: TimeInterval = 45
    static let localDiscoveryTimeoutSeconds: TimeInterval = 2
    static var safeFallbackCopy: String {
        L10n.text("ui.pairing_onboarding_fallback")
    }
    static var dateTimeInstructions: String {
        L10n.text("ui.pairing_onboarding_date_time_instructions")
    }

    static let negotiatedPaths: [String] = [
        "/api/pair/claim",
        "/api/pair/local",
        "/api/tailcat/managed-pairing-link",
        "/api/tailcat/managed-pairing-operations",
        "/api/tailcat/free-route",
    ]

    static func isNegotiatedPath(_ path: String) -> Bool {
        let barePath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if negotiatedPaths.contains(barePath) {
            return true
        }
        return barePath.hasPrefix("/api/tailcat/managed-pairing-operations/")
            && !barePath.hasSuffix("/rollback")
    }

    static func hasVaryAccept(_ varyHeader: String?) -> Bool {
        guard let varyHeader else { return false }
        let tokens = varyHeader
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return tokens.contains(expectedVaryHeaderValue.lowercased())
    }

    static func isOnboardingMediaType(_ contentType: String?) -> Bool {
        classifyMediaType(contentType) != .other
    }

    static func isOnboardingErrorEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if hasUnsupportedOnboardingSchema(object) {
            return true
        }
        return object["ok"] != nil || object["error"] is [String: Any]
    }

    /// Recognizes every localized user-facing string emitted by `PairingErrorMapper` so
    /// downstream generic classifiers never overwrite typed pairing guidance or misclassify 401 tickets.
    static func isUserFacingMessage(_ message: String) -> Bool {
        if message == safeFallbackCopy
            || message == dateTimeInstructions
            || message == L10n.text("ui.pairing_onboarding_desktop_workspace_guidance")
            || message == L10n.text("ui.pairing_onboarding_desktop_service_guidance") {
            return true
        }
        for entry in catalogEntries {
            if entry.allowsAnyStep || entry.code == "invalid_request" {
                for step in PairingOnboardingStep.allCases {
                    if localizedMessage(code: entry.code, step: step) == message {
                        return true
                    }
                }
            } else if localizedMessage(code: entry.code, step: entry.steps.first) == message {
                return true
            }
        }
        return false
    }

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
            messageKey: "ui.pairing_onboarding_no_enabled_assistant"
        ),
        .init(
            code: "workspace_confirmation_required", isUILocal: false, steps: [.workspaceRoot], allowsAnyStep: false,
            allowedFixes: [.choosePath("workspace_root")],
            messageKey: "ui.pairing_onboarding_workspace_confirmation_required"
        ),
        .init(
            code: "tailcat_relay_unreachable", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_tailcat_relay_unreachable"
        ),
        .init(
            code: "tailcat_busy", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_tailcat_busy"
        ),
        .init(
            code: "pair_host_unreachable", isUILocal: false, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_pair_host_unreachable"
        ),
        .init(
            code: "pair_token_mismatch", isUILocal: false, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.runFix("save_setup"), .runFix("restart_service")],
            messageKey: "ui.pairing_onboarding_pair_token_mismatch"
        ),
        .init(
            code: "pair_ticket_expired", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_pair_ticket_expired"
        ),
        .init(
            code: "pair_ticket_invalid", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_pair_ticket_invalid"
        ),
        .init(
            code: "pair_clock_skew", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.openSettings("date_time")],
            messageKey: "ui.pairing_onboarding_pair_clock_skew"
        ),
        .init(
            code: "pair_local_forbidden", isUILocal: false, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_pair_local_forbidden"
        ),
        .init(
            code: "pair_managed_entitlement_required", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.openSettings("managed_connection")],
            messageKey: "ui.pairing_onboarding_pair_managed_entitlement_required"
        ),
        .init(
            code: "pair_managed_grant_conflict", isUILocal: false, steps: [.networkTailcat], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_pair_managed_grant_conflict"
        ),
        .init(
            code: "invalid_request", isUILocal: false, steps: [.networkAny], allowsAnyStep: false,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_invalid_request"
        ),
        .init(
            code: "probe_timeout", isUILocal: false, steps: [], allowsAnyStep: true,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_probe_timeout"
        ),
        .init(
            code: "internal_error", isUILocal: false, steps: [], allowsAnyStep: true,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_internal_error"
        ),
        // 2 UI-local codes (never accepted over HTTP wire)
        .init(
            code: "command_timeout", isUILocal: true, steps: [], allowsAnyStep: true,
            allowedFixes: [.retry],
            messageKey: "ui.pairing_onboarding_command_timeout"
        ),
        .init(
            code: "embedded_binary_missing", isUILocal: true, steps: [.serviceDaemon], allowsAnyStep: false,
            allowedFixes: [.openURL(.desktop)],
            messageKey: "ui.pairing_onboarding_embedded_binary_missing"
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
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? step?.localizedTitle
            ?? PairingOnboardingStep.serviceDaemon.localizedTitle
        switch code {
        case "no_enabled_assistant":
            return L10n.text("ui.pairing_onboarding_no_enabled_assistant")
        case "workspace_confirmation_required":
            return L10n.text("ui.pairing_onboarding_workspace_confirmation_required")
        case "tailcat_relay_unreachable":
            return L10n.text("ui.pairing_onboarding_tailcat_relay_unreachable")
        case "tailcat_busy":
            return L10n.text("ui.pairing_onboarding_tailcat_busy")
        case "pair_host_unreachable":
            return L10n.text("ui.pairing_onboarding_pair_host_unreachable")
        case "pair_token_mismatch":
            return L10n.text("ui.pairing_onboarding_pair_token_mismatch")
        case "pair_ticket_expired":
            return L10n.text("ui.pairing_onboarding_pair_ticket_expired")
        case "pair_ticket_invalid":
            return L10n.text("ui.pairing_onboarding_pair_ticket_invalid")
        case "pair_clock_skew":
            return L10n.text("ui.pairing_onboarding_pair_clock_skew")
        case "pair_local_forbidden":
            return L10n.text("ui.pairing_onboarding_pair_local_forbidden")
        case "pair_managed_entitlement_required":
            return L10n.text("ui.pairing_onboarding_pair_managed_entitlement_required")
        case "pair_managed_grant_conflict":
            return L10n.text("ui.pairing_onboarding_pair_managed_grant_conflict")
        case "invalid_request":
            return L10n.format("ui.pairing_onboarding_invalid_request", resolvedTitle)
        case "probe_timeout":
            return L10n.format("ui.pairing_onboarding_probe_timeout", resolvedTitle)
        case "internal_error":
            return L10n.format("ui.pairing_onboarding_internal_error", resolvedTitle)
        case "command_timeout":
            return L10n.format("ui.pairing_onboarding_command_timeout", resolvedTitle)
        case "embedded_binary_missing":
            return L10n.text("ui.pairing_onboarding_embedded_binary_missing")
        default:
            return safeFallbackCopy
        }
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
        for part in [object, object["error"] as? [String: Any]] {
            guard let value = part?["schema"] else { continue }
            guard let schema = value as? String, schema.hasPrefix("mimi.onboarding."),
                  schema.split(separator: "/", maxSplits: 1).last == "v1" else {
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
        varyHeader: String? = nil,
        configured: Bool? = nil
    ) -> MappedPairingError {
        switch classifyMediaType(contentType) {
        case .unsupportedOnboardingMajor:
            return untrustedFallback()
        case .v1:
            guard hasVaryAccept(varyHeader) else { return untrustedFallback() }
            let mapped = mapHTTPErrorEnvelope(data: data, configured: configured)
            let expectedStatus: Int? = switch mapped.code {
            case "pair_ticket_invalid", "pair_ticket_expired", "pair_clock_skew": 401
            case "pair_local_forbidden": 403
            case "workspace_confirmation_required", "pair_managed_grant_conflict": 409
            case "no_enabled_assistant": 503
            default: nil
            }
            if let expectedStatus, expectedStatus != statusCode { return untrustedFallback() }
            if statusCode == 401, expectedStatus != 401 { return untrustedFallback() }
            return mapped
        case .other:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !hasUnsupportedOnboardingSchema(object) else {
                return untrustedFallback()
            }
            if object["ok"] != nil || object["error"] is [String: Any] {
                return untrustedFallback()
            }
            if let legacy = mapLegacyHTTPError(object, statusCode: statusCode, configured: configured) {
                return legacy
            }
            return untrustedFallback()
        }
    }

    private static func mapLegacyHTTPError(
        _ obj: [String: Any], statusCode: Int, configured: Bool?
    ) -> MappedPairingError? {
        let error = obj["error"] as? String
        guard (error != nil || (obj["error"] == nil && obj["code"] is String)),
              Set(obj.keys).isSubset(of: ["error", "code"])
        else {
            return nil
        }
        var rawCode = obj["code"] as? String
        if obj["code"] == nil {
            // Exact strings from hosts predating the onboarding media type.
            switch (statusCode, error) {
            case (401, "配对二维码已过期"): rawCode = "pair_ticket_expired"
            case (401, "配对票据 issued_at 超出允许范围"): rawCode = "pair_clock_skew"
            case (403, "本机自动配对仅允许 Mimi Mac 客户端通过 loopback 发起"): rawCode = "pair_local_forbidden"
            case (503, "全部 AI 编程助手已关闭，请先启用助手"): rawCode = "no_enabled_assistant"
            case (401, _) where configured != true: rawCode = "pair_ticket_invalid"
            default: break
            }
        }
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
            let ticketCodes = ["pair_ticket_expired", "pair_ticket_invalid", "pair_clock_skew"]
            guard (statusCode == 401) == ticketCodes.contains(mappedCode) else { return nil }
            let step = entry.steps.first ?? .serviceDaemon
            let fix: PairingOnboardingWireFix
            if mappedCode == "pair_token_mismatch" {
                guard let configured else { return nil }
                fix = .runFix(configured ? "restart_service" : "save_setup")
            } else {
                fix = entry.allowedFixes.last ?? .retry
            }
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
        return nil
    }

    private static func iosAction(for fix: PairingOnboardingWireFix, code: String) -> PairingErrorAction {
        switch fix {
        case .retry:
            return .retry
        case .openURL(let allowed):
            return .openURL(allowed)
        case .openSettings("date_time"):
            return .showDateTimeGuidanceAndRetry(instructions: dateTimeInstructions)
        case .openSettings("managed_connection") where code == "pair_managed_entitlement_required":
            return .openManagedConnection
        case .choosePath("workspace_root"):
            return .desktopGuidanceAndRescan(instructions: L10n.text("ui.pairing_onboarding_desktop_workspace_guidance"))
        case .runFix("restart_service"), .runFix("save_setup"):
            return .desktopGuidanceAndRescan(instructions: L10n.text("ui.pairing_onboarding_desktop_service_guidance"))
        case .openSettings, .choosePath, .runFix, .skip:
            return .none
        }
    }

    private static func untrustedFallback(
        code: String? = nil,
        step: PairingOnboardingStep? = nil
    ) -> MappedPairingError {
        MappedPairingError(
            code: code.flatMap { entriesByCode[$0]?.code },
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

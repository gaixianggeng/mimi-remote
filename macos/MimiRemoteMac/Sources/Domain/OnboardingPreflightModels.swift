import Foundation

enum OnboardingSchema {
    static let preflightV1 = "mimi.onboarding.preflight/v1"
    static let codesV1 = "mimi.onboarding.codes/v1"
    static let mediaTypeV1 = "application/vnd.mimi.onboarding.v1+json"
    static func isSupportedDeclaration(_ schema: String) -> Bool {
        schema.hasPrefix("mimi.onboarding.") && schema.split(separator: "/", maxSplits: 1).last == "v1"
    }

    static func checkDeclaredVersion(in raw: KeyedDecodingContainer<OnboardingDynamicKey>) throws {
        guard let key = OnboardingDynamicKey(stringValue: "schema"), raw.contains(key) else { return }
        let schema = try raw.decode(String.self, forKey: key)
        guard isSupportedDeclaration(schema) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: raw, debugDescription: "Unsupported onboarding schema")
        }
    }

    static let doctorFixCapability = "identity_preserving_doctor_fix"
}

enum OnboardingPlatform: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case macos
    case windows
    case linux
}

enum OnboardingStage: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case setup
    case pair
}

enum OnboardingSurface: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case check
    case cli
    case http
    case native
    case uiLocal = "ui_local"
}

enum OnboardingCheckGroup: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case workspace
    case service
    case assistant
    case network
    case permission
}

enum OnboardingCheckState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case checking
    case ok
    case optional
    case actionNeeded = "action_needed"
    case error
}

enum OnboardingTransport: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case tailscale
    case tailcat
    case lan

    var pairingNetwork: PairingNetwork {
        switch self {
        case .tailscale: .tailscale
        case .tailcat: .tailcat
        case .lan: .localNetwork
        }
    }

    var checkID: OnboardingCheckID {
        switch self {
        case .tailscale: .networkTailscale
        case .tailcat: .networkTailcat
        case .lan: .networkLAN
        }
    }

    var localizedTitle: String {
        switch self {
        case .tailscale: "Tailscale"
        case .tailcat: "内置连接"
        case .lan: "同一局域网"
        }
    }
}

enum OnboardingCandidateOutcome: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case missing
    case unusable
    case unsupported
    case compatible
    case selected
    case timeout
}

enum OnboardingCandidateSource: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pin
    case env
    case auto
}

enum OnboardingCheckID: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
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

    var id: String { rawValue }

    var group: OnboardingCheckGroup {
        switch self {
        case .configStore, .workspaceRoot:
            .workspace
        case .serviceOwnerConflict, .serviceDaemon:
            .service
        case .assistantCodex, .assistantClaude, .assistantAgy, .assistantDeepSeek, .assistantAny:
            .assistant
        case .networkTailscale, .networkTailcat, .networkLAN, .networkAny:
            .network
        case .permissionLoginItem, .permissionFolderAccess, .permissionLocalNetwork, .permissionPhotos, .permissionFullDisk:
            .permission
        }
    }

    var platforms: [OnboardingPlatform] {
        switch self {
        case .serviceOwnerConflict, .permissionLoginItem, .permissionFolderAccess, .permissionPhotos, .permissionFullDisk:
            [.macos]
        case .permissionLocalNetwork:
            [.macos, .windows]
        default:
            [.macos, .windows, .linux]
        }
    }

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

    var isIndividualAssistant: Bool {
        switch self {
        case .assistantCodex, .assistantClaude, .assistantAgy, .assistantDeepSeek: true
        default: false
        }
    }

    var isCLIAssistant: Bool {
        switch self {
        case .assistantCodex, .assistantClaude, .assistantAgy: true
        default: false
        }
    }

    var isIndividualNetwork: Bool {
        switch self {
        case .networkTailscale, .networkTailcat, .networkLAN: true
        default: false
        }
    }

    var isPermission: Bool {
        group == .permission
    }

    static func applicable(for platform: OnboardingPlatform) -> [OnboardingCheckID] {
        allCases.filter { $0.platforms.contains(platform) }
    }
}

enum OnboardingFixURL: String, CaseIterable, Equatable, Hashable, Sendable {
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

enum OnboardingSettingsTarget: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case loginItems = "login_items"
    case filesAndFolders = "files_and_folders"
    case localNetwork = "local_network"
    case photos
    case fullDiskAccess = "full_disk_access"
    case windowsFirewall = "windows_firewall"
    case windowsNetworkProfile = "windows_network_profile"
    case assistants
    case connections
    case hostRecovery = "host_recovery"
    case dateTime = "date_time"
    case managedConnection = "managed_connection"
}

enum OnboardingPathTarget: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case workspaceRoot = "workspace_root"
    case codexBin = "codex_bin"
    case claudeBin = "claude_bin"
    case agyBin = "agy_bin"
}

enum OnboardingRunFixAction: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case saveSetup = "save_setup"
    case enableCodex = "enable_codex"
    case enableClaude = "enable_claude"
    case enableAgy = "enable_agy"
    case enableTailscale = "enable_tailscale"
    case enableLAN = "enable_lan"
    case enableTailcat = "enable_tailcat"
    case connectDeepSeek = "connect_deepseek"
    case restartService = "restart_service"
    case registerService = "register_service"
    case doctorFix = "doctor_fix"
    case takeoverHomebrew = "takeover_homebrew"

    var requiresConfig: Bool {
        switch self {
        case .saveSetup, .enableCodex, .enableClaude, .enableAgy:
            false
        case .enableTailscale, .enableLAN, .enableTailcat, .connectDeepSeek,
             .restartService, .registerService, .doctorFix, .takeoverHomebrew:
            true
        }
    }

    var requiredCapability: String? {
        self == .doctorFix ? OnboardingSchema.doctorFixCapability : nil
    }

    var isTransportEnable: Bool {
        switch self {
        case .enableTailscale, .enableLAN, .enableTailcat: true
        default: false
        }
    }
}

/// Strictly decoded fix allow-list. Any unknown kind, unknown URL/target/action,
/// or extra property (such as `rotates_token: true`) fails decoding cleanly.
enum OnboardingFix: Equatable, Hashable, Sendable, Decodable {
    case openURL(OnboardingFixURL)
    case openSettings(OnboardingSettingsTarget)
    case choosePath(OnboardingPathTarget)
    case runFix(OnboardingRunFixAction)
    case retry
    case skip

    var kind: String {
        switch self {
        case .openURL: "open_url"
        case .openSettings: "open_settings"
        case .choosePath: "choose_path"
        case .runFix: "run_fix"
        case .retry: "retry"
        case .skip: "skip"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OnboardingDynamicKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard let kindKey = OnboardingDynamicKey(stringValue: "kind"),
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
                    .init(codingPath: decoder.codingPath, debugDescription: "unexpected extra field on retry fix")
                )
            }
            self = .retry
        case "skip":
            guard keys == ["kind"] else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unexpected extra field on skip fix")
                )
            }
            self = .skip
        case "open_url":
            guard keys == ["kind", "url"],
                  let urlKey = OnboardingDynamicKey(stringValue: "url"),
                  let rawURL = try container.decodeIfPresent(String.self, forKey: urlKey),
                  let allowed = OnboardingFixURL(rawValue: rawURL)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid or disallowed open_url fix")
                )
            }
            self = .openURL(allowed)
        case "open_settings":
            guard keys == ["kind", "target"],
                  let targetKey = OnboardingDynamicKey(stringValue: "target"),
                  let rawTarget = try container.decodeIfPresent(String.self, forKey: targetKey),
                  let target = OnboardingSettingsTarget(rawValue: rawTarget)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid open_settings fix")
                )
            }
            self = .openSettings(target)
        case "choose_path":
            guard keys == ["kind", "target"],
                  let targetKey = OnboardingDynamicKey(stringValue: "target"),
                  let rawTarget = try container.decodeIfPresent(String.self, forKey: targetKey),
                  let target = OnboardingPathTarget(rawValue: rawTarget)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid choose_path fix")
                )
            }
            self = .choosePath(target)
        case "run_fix":
            guard keys == ["kind", "action"],
                  let actionKey = OnboardingDynamicKey(stringValue: "action"),
                  let rawAction = try container.decodeIfPresent(String.self, forKey: actionKey),
                  let action = OnboardingRunFixAction(rawValue: rawAction)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid or disallowed run_fix")
                )
            }
            self = .runFix(action)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown fix kind")
            )
        }
    }
}

struct OnboardingCandidate: Decodable, Equatable, Sendable {
    let path: String
    let outcome: OnboardingCandidateOutcome
    let version: String?

    init(path: String, outcome: OnboardingCandidateOutcome, version: String? = nil) {
        self.path = path
        self.outcome = outcome
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case path, outcome, version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: "empty candidate path")
        }
        self.path = path
        self.outcome = try container.decode(OnboardingCandidateOutcome.self, forKey: .outcome)
        self.version = try container.decodeIfPresent(String.self, forKey: .version)
    }
}

struct OnboardingCheck: Decodable, Equatable, Identifiable, Sendable {
    let id: OnboardingCheckID
    let group: OnboardingCheckGroup
    let state: OnboardingCheckState
    let title: String
    let detail: String
    let blocking: Bool
    let code: String?
    let fix: OnboardingFix?
    let configPath: String?
    let recoveryPath: String?
    let enabled: Bool?
    let available: Bool?
    let candidates: [OnboardingCandidate]?
    let source: OnboardingCandidateSource?
    let detectedVersion: String?
    let minVersion: String?

    let hasAvailableKey: Bool
    let hasCandidatesKey: Bool
    let hasCodeKey: Bool
    let hasFixKey: Bool
    let hasConfigPathKey: Bool
    let hasRecoveryPathKey: Bool

    init(
        id: OnboardingCheckID,
        group: OnboardingCheckGroup? = nil,
        state: OnboardingCheckState,
        title: String? = nil,
        detail: String,
        blocking: Bool,
        code: String? = nil,
        fix: OnboardingFix? = nil,
        configPath: String? = nil,
        recoveryPath: String? = nil,
        enabled: Bool? = nil,
        available: Bool? = nil,
        hasAvailableKey: Bool? = nil,
        candidates: [OnboardingCandidate]? = nil,
        source: OnboardingCandidateSource? = nil,
        detectedVersion: String? = nil,
        minVersion: String? = nil
    ) {
        self.id = id
        self.group = group ?? id.group
        self.state = state
        self.title = title ?? id.localizedTitle
        self.detail = detail
        self.blocking = blocking
        self.code = code
        self.fix = fix
        self.configPath = configPath
        self.recoveryPath = recoveryPath
        self.enabled = enabled
        self.available = available
        self.candidates = candidates
        self.source = source
        self.detectedVersion = detectedVersion
        self.minVersion = minVersion
        self.hasAvailableKey = hasAvailableKey ?? (available != nil || id.isIndividualAssistant || id.isIndividualNetwork)
        self.hasCandidatesKey = candidates != nil
        self.hasCodeKey = code != nil
        self.hasFixKey = fix != nil
        self.hasConfigPathKey = configPath != nil
        self.hasRecoveryPathKey = recoveryPath != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, group, state, title, detail, blocking, code, fix
        case configPath = "config_path"
        case recoveryPath = "recovery_path"
        case enabled, available, candidates, source
        case detectedVersion = "detected_version"
        case minVersion = "min_version"
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: OnboardingDynamicKey.self)
        try OnboardingSchema.checkDeclaredVersion(in: raw)
        let rawKeys = Set(raw.allKeys.map(\.stringValue))
        hasAvailableKey = rawKeys.contains("available")
        hasCandidatesKey = rawKeys.contains("candidates")
        hasCodeKey = rawKeys.contains("code")
        hasFixKey = rawKeys.contains("fix")
        hasConfigPathKey = rawKeys.contains("config_path")
        hasRecoveryPathKey = rawKeys.contains("recovery_path")

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(OnboardingCheckID.self, forKey: .id)
        group = try container.decode(OnboardingCheckGroup.self, forKey: .group)
        state = try container.decode(OnboardingCheckState.self, forKey: .state)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        blocking = try container.decode(Bool.self, forKey: .blocking)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        fix = try container.decodeIfPresent(OnboardingFix.self, forKey: .fix)
        configPath = try container.decodeIfPresent(String.self, forKey: .configPath)
        recoveryPath = try container.decodeIfPresent(String.self, forKey: .recoveryPath)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        available = try container.decodeIfPresent(Bool.self, forKey: .available)
        candidates = try container.decodeIfPresent([OnboardingCandidate].self, forKey: .candidates)
        source = try container.decodeIfPresent(OnboardingCandidateSource.self, forKey: .source)
        detectedVersion = try container.decodeIfPresent(String.self, forKey: .detectedVersion)
        minVersion = try container.decodeIfPresent(String.self, forKey: .minVersion)
    }

    var selectedOrDetectedVersion: String? {
        if let v = detectedVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return v
        }
        return candidates?.first(where: { $0.outcome == .selected })?.version
    }
}

struct OnboardingPreflightReport: Decodable, Equatable, Sendable {
    let schema: String
    let ok: Bool
    let stage: OnboardingStage
    let configured: Bool
    let workspaceConfirmed: Bool
    let configPath: String
    let scanRoot: String
    let browseRoot: String
    let scanRootExists: Bool
    let recommendedNext: OnboardingCheckID
    let recommendedTransport: OnboardingTransport?
    let checks: [OnboardingCheck]

    init(
        schema: String = OnboardingSchema.preflightV1,
        ok: Bool,
        stage: OnboardingStage,
        configured: Bool,
        workspaceConfirmed: Bool,
        configPath: String,
        scanRoot: String,
        browseRoot: String,
        scanRootExists: Bool,
        recommendedNext: OnboardingCheckID,
        recommendedTransport: OnboardingTransport?,
        checks: [OnboardingCheck]
    ) {
        self.schema = schema
        self.ok = ok
        self.stage = stage
        self.configured = configured
        self.workspaceConfirmed = workspaceConfirmed
        self.configPath = configPath
        self.scanRoot = scanRoot
        self.browseRoot = browseRoot
        self.scanRootExists = scanRootExists
        self.recommendedNext = recommendedNext
        self.recommendedTransport = recommendedTransport
        self.checks = checks
    }

    enum CodingKeys: String, CodingKey {
        case schema, ok, stage, configured
        case workspaceConfirmed = "workspace_confirmed"
        case configPath = "config_path"
        case scanRoot = "scan_root"
        case browseRoot = "browse_root"
        case scanRootExists = "scan_root_exists"
        case recommendedNext = "recommended_next"
        case recommendedTransport = "recommended_transport"
        case checks
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: OnboardingDynamicKey.self)
        let rawKeys = Set(raw.allKeys.map(\.stringValue))
        guard rawKeys.contains("recommended_transport") else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "report missing recommended_transport key")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        guard schema == OnboardingSchema.preflightV1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "unsupported preflight schema"
            )
        }
        ok = try container.decode(Bool.self, forKey: .ok)
        stage = try container.decode(OnboardingStage.self, forKey: .stage)
        configured = try container.decode(Bool.self, forKey: .configured)
        workspaceConfirmed = try container.decode(Bool.self, forKey: .workspaceConfirmed)
        configPath = try container.decode(String.self, forKey: .configPath)
        scanRoot = try container.decode(String.self, forKey: .scanRoot)
        browseRoot = try container.decode(String.self, forKey: .browseRoot)
        scanRootExists = try container.decode(Bool.self, forKey: .scanRootExists)
        recommendedNext = try container.decode(OnboardingCheckID.self, forKey: .recommendedNext)
        recommendedTransport = try container.decodeIfPresent(OnboardingTransport.self, forKey: .recommendedTransport)
        checks = try container.decode([OnboardingCheck].self, forKey: .checks)
    }
}

struct SetupReceipt: Decodable, Equatable, Sendable {
    let ok: Bool
    let configured: Bool
    let created: Bool
    let configPath: String
    let scanRoot: String
    let browseRoot: String
    let pairingDeferred: Bool?
    let endpoint: String?
    let pairURL: String?
    let pairExpiresAt: String?
    let network: PairingNetwork?
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?
    let warnings: [String]
    let isLegacy: Bool

    enum CodingKeys: String, CodingKey {
        case ok, configured, created
        case configPath = "config_path"
        case scanRoot = "scan_root"
        case browseRoot = "browse_root"
        case pairingDeferred = "pairing_deferred"
        case endpoint
        case pairURL = "pair_url"
        case pairExpiresAt = "pair_expires_at"
        case network
        case tailscaleDNSName = "tailscale_dns_name"
        case tailscaleDeviceName = "tailscale_device_name"
        case warnings
    }

    init(
        ok: Bool = true,
        configured: Bool = true,
        created: Bool = true,
        configPath: String,
        scanRoot: String,
        browseRoot: String,
        pairingDeferred: Bool? = nil,
        endpoint: String? = nil,
        pairURL: String? = nil,
        pairExpiresAt: String? = nil,
        network: PairingNetwork? = nil,
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil,
        warnings: [String] = [],
        isLegacy: Bool = false
    ) {
        self.ok = ok
        self.configured = configured
        self.created = created
        self.configPath = configPath
        self.scanRoot = scanRoot
        self.browseRoot = browseRoot
        self.pairingDeferred = pairingDeferred
        self.endpoint = endpoint
        self.pairURL = pairURL
        self.pairExpiresAt = pairExpiresAt
        self.network = network
        self.tailscaleDNSName = tailscaleDNSName
        self.tailscaleDeviceName = tailscaleDeviceName
        self.warnings = OnboardingCopyCatalog.displayWarnings(warnings)
        self.isLegacy = isLegacy
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: OnboardingDynamicKey.self)
        try OnboardingSchema.checkDeclaredVersion(in: raw)
        let rawKeys = Set(raw.allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedConfigured = try container.decodeIfPresent(Bool.self, forKey: .configured)
        let decodedCreated = try container.decodeIfPresent(Bool.self, forKey: .created)
        let decodedPairURL = try container.decodeIfPresent(String.self, forKey: .pairURL)
        let decodedEndpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        let decodedExpires = try container.decodeIfPresent(String.self, forKey: .pairExpiresAt)
        let decodedNetwork = try container.decodeIfPresent(PairingNetwork.self, forKey: .network)
        let decodedDNS = try container.decodeIfPresent(String.self, forKey: .tailscaleDNSName)
        let decodedDevice = try container.decodeIfPresent(String.self, forKey: .tailscaleDeviceName)
        let decodedWarnings = OnboardingCopyCatalog.displayWarnings(
            try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        )

        let hasOKKey = rawKeys.contains("ok")
        if hasOKKey {
            let explicitOK = try container.decode(Bool.self, forKey: .ok)
            guard explicitOK else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "setup receipt returned ok=false")
                )
            }
        }
        if let decodedNetwork, decodedNetwork == .automatic {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid setup transport auto")
            )
        }

        // Legacy setup JSON from pre-BE-3 hosts only returned ticket fields without ok/configured/created.
        if !hasOKKey, decodedConfigured == nil, decodedCreated == nil, let ticketURL = decodedPairURL, !ticketURL.isEmpty {
            guard OnboardingDateParser.isValidPairURL(ticketURL),
                  let endpoint = decodedEndpoint, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let expires = decodedExpires, OnboardingDateParser.isValidRFC3339(expires, requireUTC: false)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "incomplete or invalid legacy setup ticket")
                )
            }
            self.ok = true
            self.configured = true
            self.created = true
            self.configPath = ""
            self.scanRoot = ""
            self.browseRoot = ""
            self.pairingDeferred = nil
            self.endpoint = endpoint
            self.pairURL = ticketURL
            self.pairExpiresAt = expires
            self.network = decodedNetwork ?? PairingNetwork.inferred(from: endpoint)
            self.tailscaleDNSName = decodedDNS
            self.tailscaleDeviceName = decodedDevice
            self.warnings = decodedWarnings
            self.isLegacy = true
            return
        }

        let decodedOK = try container.decode(Bool.self, forKey: .ok)
        guard decodedOK, decodedConfigured == true, let createdVal = decodedCreated else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "setup receipt requires ok=true, configured=true, created")
            )
        }
        let cfgPath = try container.decode(String.self, forKey: .configPath)
        let scan = try container.decode(String.self, forKey: .scanRoot)
        let browse = try container.decode(String.self, forKey: .browseRoot)
        guard !cfgPath.isEmpty, !scan.isEmpty, !browse.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "setup receipt requires non-empty paths")
            )
        }
        let deferred = try container.decodeIfPresent(Bool.self, forKey: .pairingDeferred)
        if deferred == true, rawKeys.contains("pair_url") || rawKeys.contains("pair_expires_at") {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "deferred setup receipt cannot include ticket fields")
            )
        }
        if let ticketURL = decodedPairURL {
            guard OnboardingDateParser.isValidPairURL(ticketURL),
                  let endpoint = decodedEndpoint, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let expires = decodedExpires, OnboardingDateParser.isValidRFC3339(expires, requireUTC: true)
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "setup receipt ticket fields incomplete or invalid")
                )
            }
        }
        self.ok = decodedOK
        self.configured = true
        self.created = createdVal
        self.configPath = cfgPath
        self.scanRoot = scan
        self.browseRoot = browse
        self.pairingDeferred = deferred
        self.endpoint = decodedEndpoint
        self.pairURL = decodedPairURL
        self.pairExpiresAt = decodedExpires
        self.network = decodedNetwork
        self.tailscaleDNSName = decodedDNS
        self.tailscaleDeviceName = decodedDevice
        self.warnings = decodedWarnings
        self.isLegacy = false
    }

    var asPairingInfo: PairingInfo {
        PairingInfo(
            endpoint: endpoint ?? "",
            network: network ?? endpoint.map(PairingNetwork.inferred(from:)) ?? .automatic,
            tailscaleDNSName: tailscaleDNSName,
            tailscaleDeviceName: tailscaleDeviceName,
            pairURL: pairURL,
            expiresAt: pairExpiresAt ?? "",
            warnings: warnings
        )
    }
}

struct UpReadinessReceipt: Decodable, Equatable, Sendable {
    let ok: Bool
    let serviceOK: Bool
    let version: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case serviceOK = "service_ok"
        case version
        case warnings
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: OnboardingDynamicKey.self)
        try OnboardingSchema.checkDeclaredVersion(in: raw)
        let rawKeys = Set(raw.allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let okVal: Bool
        if rawKeys.contains("ok") {
            okVal = try container.decode(Bool.self, forKey: .ok)
        } else {
            okVal = true
        }
        let readyVal = try container.decode(Bool.self, forKey: .serviceOK)
        let ver = try container.decode(String.self, forKey: .version)
        guard okVal, readyVal, !ver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "up receipt does not confirm authenticated readiness")
            )
        }
        self.ok = okVal
        self.serviceOK = readyVal
        self.version = ver
        self.warnings = OnboardingCopyCatalog.displayWarnings(
            try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        )
    }
}

struct PairingTicketReceipt: Decodable, Equatable, Sendable {
    let ok: Bool
    let endpoint: String
    let network: PairingNetwork
    let hasExplicitNetwork: Bool
    let pairURL: String
    let pairExpiresAt: String
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok, endpoint, network
        case pairURL = "pair_url"
        case pairExpiresAt = "pair_expires_at"
        case tailscaleDNSName = "tailscale_dns_name"
        case tailscaleDeviceName = "tailscale_device_name"
        case warnings
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: OnboardingDynamicKey.self)
        try OnboardingSchema.checkDeclaredVersion(in: raw)
        let rawKeys = Set(raw.allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasOKKey = rawKeys.contains("ok")
        let okVal: Bool
        if hasOKKey {
            okVal = try container.decode(Bool.self, forKey: .ok)
        } else {
            okVal = true
        }
        guard okVal else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "pairing ticket returned ok=false")
            )
        }
        let ep = try container.decode(String.self, forKey: .endpoint)
        let ticket = try container.decode(String.self, forKey: .pairURL)
        let expires = try container.decode(String.self, forKey: .pairExpiresAt)
        guard !ep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              OnboardingDateParser.isValidPairURL(ticket),
              OnboardingDateParser.isValidRFC3339(expires, requireUTC: hasOKKey)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "pairing ticket missing or invalid required fields")
            )
        }
        let explicitNetwork = try container.decodeIfPresent(PairingNetwork.self, forKey: .network)
        if (hasOKKey && explicitNetwork == nil) || explicitNetwork == .automatic {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "pairing ticket requires a supported network")
            )
        }
        self.ok = okVal
        self.endpoint = ep
        self.hasExplicitNetwork = explicitNetwork != nil
        self.network = explicitNetwork ?? PairingNetwork.inferred(from: ep)
        self.pairURL = ticket
        self.pairExpiresAt = expires
        self.tailscaleDNSName = try container.decodeIfPresent(String.self, forKey: .tailscaleDNSName)
        self.tailscaleDeviceName = try container.decodeIfPresent(String.self, forKey: .tailscaleDeviceName)
        self.warnings = OnboardingCopyCatalog.displayWarnings(
            try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        )
    }

    var asPairingInfo: PairingInfo { pairingInfo(for: .automatic) }

    func pairingInfo(for requestedNetwork: PairingNetwork) -> PairingInfo {
        PairingInfo(
            endpoint: endpoint,
            network: hasExplicitNetwork || requestedNetwork == .automatic ? network : requestedNetwork,
            tailscaleDNSName: tailscaleDNSName,
            tailscaleDeviceName: tailscaleDeviceName,
            pairURL: pairURL,
            expiresAt: pairExpiresAt,
            warnings: warnings
        )
    }
}

struct OnboardingDiagnostic: Decodable, Equatable, Sendable {
    let code: String
    let step: String
    let message: String
    let fix: OnboardingFix
    let configPath: String?
    let recoveryPath: String?

    enum CodingKeys: String, CodingKey {
        case code, step, message, fix
        case configPath = "config_path"
        case recoveryPath = "recovery_path"
    }
}

struct OnboardingErrorEnvelope: Decodable, Equatable, Sendable {
    let ok: Bool
    let error: OnboardingDiagnostic
}

/// Thread-safe accumulator for `--progress-json` NDJSON stderr rows with
/// tuple validation and generation gating so invalid, cancelled, or late updates
/// never get published or overwrite terminal state.
final class OnboardingProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let validationContext: OnboardingValidationContext
    private var order: [OnboardingCheckID] = []
    private var rowsByID: [OnboardingCheckID: OnboardingCheck] = [:]
    private var finalReport: OnboardingPreflightReport?
    private var isTerminal = false
    private var generation: UInt64

    init(
        generation: UInt64 = 1,
        context: OnboardingValidationContext = OnboardingValidationContext(
            surface: .check,
            platform: .macos,
            stage: .setup,
            configured: false
        )
    ) {
        self.generation = generation
        self.validationContext = context
    }

    @discardableResult
    func applyLine(_ line: String, generation: UInt64) -> Bool {
        applyValidatedLine(line, generation: generation) != nil
    }

    func applyValidatedLine(_ line: String, generation: UInt64) -> OnboardingCheck? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let check = try? JSONDecoder().decode(OnboardingCheck.self, from: Data(trimmed.utf8))
        else {
            return nil
        }
        guard applyCheck(check, generation: generation) else {
            return nil
        }
        return check
    }

    @discardableResult
    func applyCheck(_ check: OnboardingCheck, generation: UInt64) -> Bool {
        guard case .success = OnboardingCopyCatalog.validateCheck(check, context: validationContext) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminal, generation == self.generation else { return false }
        if rowsByID[check.id] == nil {
            order.append(check.id)
        }
        rowsByID[check.id] = check
        return true
    }

    @discardableResult
    func complete(with report: OnboardingPreflightReport, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminal, generation == self.generation else { return false }
        finalReport = report
        order = report.checks.map(\.id)
        rowsByID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        isTerminal = true
        return true
    }

    func cancel(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminal, generation == self.generation else { return }
        self.generation &+= 1
    }

    func snapshot() -> (checks: [OnboardingCheck], report: OnboardingPreflightReport?) {
        lock.lock()
        defer { lock.unlock() }
        let ordered = order.compactMap { rowsByID[$0] }
        return (ordered, finalReport)
    }
}

enum OnboardingDateParser {
    static func isValidPairURL(_ raw: String) -> Bool {
        guard raw.hasPrefix("mimiremote://pair?"),
              raw.count > "mimiremote://pair?".count,
              !raw.contains(where: \.isWhitespace),
              let components = URLComponents(string: raw),
              components.scheme == "mimiremote",
              components.host == "pair"
        else {
            return false
        }
        return true
    }

    static func isValidRFC3339(_ raw: String, requireUTC: Bool) -> Bool {
        let bytes = Array(raw.utf8)
        guard bytes.count >= 20 else { return false }
        func digit(_ index: Int) -> Int? {
            let b = bytes[index]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            return Int(b - 0x30)
        }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for offset in 0..<length {
                guard let d = digit(start + offset) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, // '-'
              bytes[10] == 0x54,                  // 'T'
              bytes[13] == 0x3A, bytes[16] == 0x3A // ':'
        else {
            return false
        }
        guard let year = number(0, 4), year >= 1,
              let month = number(5, 2), (1...12).contains(month),
              let day = number(8, 2),
              let hour = number(11, 2), (0...23).contains(hour),
              let minute = number(14, 2), (0...59).contains(minute),
              let second = number(17, 2), (0...59).contains(second)
        else {
            return false
        }
        let maxDay: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: maxDay = 31
        case 4, 6, 9, 11: maxDay = 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            maxDay = leap ? 29 : 28
        default:
            return false
        }
        guard (1...maxDay).contains(day) else { return false }

        var idx = 19
        if idx < bytes.count && bytes[idx] == 0x2E { // '.'
            idx += 1
            let fracStart = idx
            while idx < bytes.count, digit(idx) != nil {
                idx += 1
            }
            let fracLen = idx - fracStart
            guard (1...9).contains(fracLen) else { return false }
        }
        guard idx < bytes.count else { return false }
        if bytes[idx] == 0x5A { // 'Z'
            return idx + 1 == bytes.count
        }
        if requireUTC {
            return false
        }
        guard (bytes[idx] == 0x2B || bytes[idx] == 0x2D), // '+' or '-'
              idx + 6 == bytes.count,
              bytes[idx + 3] == 0x3A,
              let offsetHour = number(idx + 1, 2), (0...23).contains(offsetHour),
              let offsetMin = number(idx + 4, 2), (0...59).contains(offsetMin)
        else {
            return false
        }
        return true
    }

    static func parseRFC3339(_ raw: String) -> Date? {
        guard isValidRFC3339(raw, requireUTC: false) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

struct OnboardingDynamicKey: CodingKey {
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

import Foundation

enum OnboardingRecommendedTransportMatch: Equatable, Sendable {
    case any
    case none
    case some(OnboardingTransport)
}

struct OnboardingVariantWhen: Equatable, Sendable {
    var step: OnboardingCheckID? = nil
    var stage: OnboardingStage? = nil
    var surface: OnboardingSurface? = nil
    var configured: Bool? = nil
    var recommendedTransport: OnboardingRecommendedTransportMatch = .any
}

struct OnboardingFixVariant: Equatable, Sendable {
    let when: OnboardingVariantWhen
    let fix: OnboardingFix
}

struct OnboardingCatalogEntry: Equatable, Sendable {
    let code: String
    let isUILocal: Bool
    let steps: [OnboardingCheckID]
    let allowsAnyStep: Bool
    let platforms: [OnboardingPlatform]
    let surfaces: [OnboardingSurface]
    let setupStates: [OnboardingCheckState]
    let pairStates: [OnboardingCheckState]
    let messageZH: String
    let variants: [OnboardingFixVariant]
    let stateRule: String?
    let secondaryFix: OnboardingFix?
    let secondaryLabelZH: String?
}

struct OnboardingValidationContext: Equatable, Sendable {
    let surface: OnboardingSurface
    let platform: OnboardingPlatform
    let stage: OnboardingStage
    let configured: Bool?
    let hasRecommendedTransport: Bool
    let recommendedTransport: OnboardingTransport?
    let verifiedCapability: String?
    let explicitlyEnabled: Bool?

    init(
        surface: OnboardingSurface,
        platform: OnboardingPlatform = .macos,
        stage: OnboardingStage = .pair,
        configured: Bool? = true,
        hasRecommendedTransport: Bool = false,
        recommendedTransport: OnboardingTransport? = nil,
        verifiedCapability: String? = nil,
        explicitlyEnabled: Bool? = nil
    ) {
        self.surface = surface
        self.platform = platform
        self.stage = stage
        self.configured = configured
        self.hasRecommendedTransport = hasRecommendedTransport
        self.recommendedTransport = recommendedTransport
        self.verifiedCapability = verifiedCapability
        self.explicitlyEnabled = explicitlyEnabled
    }
}

struct OnboardingResolvedDiagnostic: Equatable, Sendable {
    let code: String?
    let step: OnboardingCheckID?
    let message: String
    let primaryAction: OnboardingFix?
    let secondaryAction: OnboardingFix?
    let secondaryLabel: String?
    let configPath: String?
    let recoveryPath: String?
    let isTrusted: Bool
    let isLegacyHost: Bool
}

enum OnboardingValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(String)
    case missingRequiredField(String)
    case duplicateRow(OnboardingCheckID)
    case unexpectedRowCount(expected: Int, actual: Int)
    case unexpectedRowOrder(expected: OnboardingCheckID, actual: OnboardingCheckID)
    case unfinishedCheckInReport(OnboardingCheckID)
    case invalidTuple(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            "当前电脑端返回了不受支持的诊断协议版本。请更新桌面端后重新检查。"
        case .missingRequiredField(let detail), .invalidTuple(let detail):
            detail
        case .duplicateRow(let id):
            "诊断结果包含重复检查项：\(id.rawValue)"
        case .unexpectedRowCount(let expected, let actual):
            "诊断检查项数量不匹配（期望 \(expected)，实际 \(actual)）。"
        case .unexpectedRowOrder(let expected, let actual):
            "诊断检查项顺序不匹配（期望 \(expected.rawValue)，实际 \(actual.rawValue)）。"
        case .unfinishedCheckInReport(let id):
            "完整预检报告仍包含未完成项：\(id.rawValue)"
        }
    }
}

enum OnboardingCopyCatalog {
    static let safeFallbackCopy = "当前操作暂时无法自动处理。请检查电脑端状态后手动重新检查。"
    static let legacyHostCopy = "当前电脑端版本较旧，不支持新的引导检查。请更新桌面端后重试。"

    static let httpForbiddenFields: Set<String> = [
        "config_path", "recovery_path", "candidates", "detected_version", "min_version",
        "source", "scan_root", "browse_root", "endpoint", "pair_url", "stderr",
        "path", "host", "host_id", "runtime", "runtime_status", "config",
        "scan_root_exists", "tailscale_dns_name", "tailscale_device_name", "device_id",
        "raw_stderr", "grant", "signature", "token", "token_file", "connect_url",
    ]

    private static let allPlatforms: [OnboardingPlatform] = [.macos, .windows, .linux]
    private static let macOnly: [OnboardingPlatform] = [.macos]
    private static let winOnly: [OnboardingPlatform] = [.windows]
    private static let macAndWin: [OnboardingPlatform] = [.macos, .windows]
    private static let surfCheckCLI: [OnboardingSurface] = [.check, .cli]
    private static let surfCheckCLIHTTP: [OnboardingSurface] = [.check, .cli, .http]
    private static let surfCLI: [OnboardingSurface] = [.cli]
    private static let surfCLIHTTP: [OnboardingSurface] = [.cli, .http]
    private static let surfHTTP: [OnboardingSurface] = [.http]
    private static let surfNative: [OnboardingSurface] = [.native]
    private static let surfCheckNative: [OnboardingSurface] = [.check, .native]
    private static let surfUILocal: [OnboardingSurface] = [.uiLocal]
    private static let optAction: [OnboardingCheckState] = [.optional, .actionNeeded]
    private static let signedOutRetryLabel = "我已登录，重新检查"

    private static func always(_ fix: OnboardingFix) -> [OnboardingFixVariant] {
        [OnboardingFixVariant(when: OnboardingVariantWhen(), fix: fix)]
    }

    private static func configSplit(_ action: OnboardingRunFixAction) -> [OnboardingFixVariant] {
        [
            OnboardingFixVariant(when: OnboardingVariantWhen(configured: false), fix: .runFix(.saveSetup)),
            OnboardingFixVariant(when: OnboardingVariantWhen(configured: true), fix: .runFix(action)),
        ]
    }

    private static func transportEnable(_ action: OnboardingRunFixAction) -> [OnboardingFixVariant] {
        [
            OnboardingFixVariant(when: OnboardingVariantWhen(configured: false), fix: .runFix(.saveSetup)),
            OnboardingFixVariant(when: OnboardingVariantWhen(stage: .setup, configured: true), fix: .openSettings(.connections)),
            OnboardingFixVariant(when: OnboardingVariantWhen(stage: .pair, configured: true), fix: .runFix(action)),
        ]
    }

    private static func entry(
        _ code: String,
        uiLocal: Bool = false,
        steps: [OnboardingCheckID] = [],
        anyStep: Bool = false,
        platforms: [OnboardingPlatform] = allPlatforms,
        surfaces: [OnboardingSurface] = surfCheckCLI,
        setup: [OnboardingCheckState] = [],
        pair: [OnboardingCheckState] = [],
        message: String,
        variants: [OnboardingFixVariant],
        stateRule: String? = nil,
        secondaryFix: OnboardingFix? = nil,
        secondaryLabel: String? = nil
    ) -> OnboardingCatalogEntry {
        OnboardingCatalogEntry(
            code: code, isUILocal: uiLocal, steps: steps, allowsAnyStep: anyStep,
            platforms: platforms, surfaces: surfaces, setupStates: setup, pairStates: pair,
            messageZH: message, variants: variants, stateRule: stateRule,
            secondaryFix: secondaryFix, secondaryLabelZH: secondaryLabel
        )
    }

    static let allEntries: [OnboardingCatalogEntry] = [
        // 77 wire codes
        entry("codex_not_found", steps: [.assistantCodex], setup: optAction, pair: optAction,
              message: "未找到 Codex。请打开安装说明，安装完成后重新检查。", variants: always(.openURL(.codex))),
        entry("codex_version_too_old", steps: [.assistantCodex], setup: optAction, pair: optAction,
              message: "Codex 版本过低。请按说明更新后重新检查。", variants: always(.openURL(.codex))),
        entry("codex_signed_out", steps: [.assistantCodex], setup: optAction, pair: optAction,
              message: "请按说明登录 Codex，完成后重新检查。", variants: always(.openURL(.codex)),
              stateRule: "signed_out_states", secondaryFix: .retry, secondaryLabel: signedOutRetryLabel),
        entry("codex_upstream_unavailable", steps: [.assistantCodex], setup: [.error], pair: [.error],
              message: "无法连接 Codex 服务。请检查服务状态后重试。", variants: always(.retry)),
        entry("codex_transport_invalid", steps: [.assistantCodex], setup: [.error], pair: [.error],
              message: "Codex 连接设置无效。请检查或清除所选连接。", variants: always(.openSettings(.assistants))),
        entry("claude_not_found", steps: [.assistantClaude], setup: optAction, pair: optAction,
              message: "未找到 Claude Code。请打开安装说明，安装完成后重新检查。", variants: always(.openURL(.claude))),
        entry("claude_version_too_old", steps: [.assistantClaude], setup: optAction, pair: optAction,
              message: "Claude Code 版本过低。请按说明更新后重新检查。", variants: always(.openURL(.claude))),
        entry("claude_signed_out", steps: [.assistantClaude], setup: optAction, pair: optAction,
              message: "请按说明登录 Claude Code，完成后重新检查。", variants: always(.openURL(.claude)),
              stateRule: "signed_out_states", secondaryFix: .retry, secondaryLabel: signedOutRetryLabel),
        entry("claude_bridge_missing", steps: [.assistantClaude], setup: [.error], pair: [.error],
              message: "Claude Code 所需的连接组件不可用。请重新安装桌面端。", variants: always(.openURL(.desktop))),
        entry("agy_not_found", steps: [.assistantAgy], setup: optAction, pair: optAction,
              message: "未找到 Antigravity。请打开安装说明，安装完成后重新检查。", variants: always(.openURL(.agy))),
        entry("agy_version_too_old", steps: [.assistantAgy], setup: optAction, pair: optAction,
              message: "Antigravity 版本过低。请按说明更新后重新检查。", variants: always(.openURL(.agy))),
        entry("agy_signed_out", steps: [.assistantAgy], setup: optAction, pair: optAction,
              message: "请按说明登录 Antigravity，完成后重新检查。", variants: always(.openURL(.agy)),
              stateRule: "signed_out_states", secondaryFix: .retry, secondaryLabel: signedOutRetryLabel),
        entry("agy_adapter_missing", steps: [.assistantAgy], setup: [.error], pair: [.error],
              message: "Antigravity 所需的连接组件不可用。请重新安装桌面端。", variants: always(.openURL(.desktop))),
        entry("runtime_path_invalid", steps: [.assistantCodex, .assistantClaude, .assistantAgy], setup: [.error], pair: [.error],
              message: "{title}：所选程序无法使用。请重新选择程序，或恢复自动检测。", variants: [
                .init(when: .init(step: .assistantCodex), fix: .choosePath(.codexBin)),
                .init(when: .init(step: .assistantClaude), fix: .choosePath(.claudeBin)),
                .init(when: .init(step: .assistantAgy), fix: .choosePath(.agyBin)),
              ]),
        entry("runtime_incompatible", steps: [.assistantCodex, .assistantClaude, .assistantAgy], setup: optAction, pair: optAction,
              message: "{title}：检测到的版本不兼容。请按说明安装受支持的版本。", variants: [
                .init(when: .init(step: .assistantCodex), fix: .openURL(.codex)),
                .init(when: .init(step: .assistantClaude), fix: .openURL(.claude)),
                .init(when: .init(step: .assistantAgy), fix: .openURL(.agy)),
              ]),
        entry("runtime_probe_failed", steps: [.assistantCodex, .assistantClaude, .assistantAgy, .assistantDeepSeek], setup: [.error], pair: [.error],
              message: "{title}：未能确认助手状态。请重新检查。", variants: always(.retry)),
        entry("runtime_unsupported_platform", steps: [.assistantCodex, .assistantClaude, .assistantAgy, .assistantDeepSeek], setup: [.optional], pair: [.optional],
              message: "{title}：当前平台尚不支持此助手，可以跳过。", variants: always(.skip)),
        entry("assistant_disabled", steps: [.assistantCodex, .assistantClaude, .assistantAgy, .assistantDeepSeek], setup: optAction, pair: optAction,
              message: "{title}：已检测到可用助手。需要使用时可启用。", variants: [
                .init(when: .init(step: .assistantCodex), fix: .runFix(.enableCodex)),
                .init(when: .init(step: .assistantClaude), fix: .runFix(.enableClaude)),
                .init(when: .init(step: .assistantAgy), fix: .runFix(.enableAgy)),
                .init(when: .init(step: .assistantDeepSeek, configured: false), fix: .runFix(.saveSetup)),
                .init(when: .init(step: .assistantDeepSeek, configured: true), fix: .runFix(.connectDeepSeek)),
              ]),
        entry("deepseek_not_running", steps: [.assistantDeepSeek], setup: optAction, pair: optAction,
              message: "未检测到正在运行的 DeepSeek Harness。请打开启动说明。", variants: always(.openURL(.harness))),
        entry("deepseek_auth_failed", steps: [.assistantDeepSeek], setup: [.error], pair: [.error],
              message: "DeepSeek Harness 未能验证连接。请重新连接。", variants: configSplit(.connectDeepSeek)),
        entry("deepseek_no_models", steps: [.assistantDeepSeek], setup: [.error], pair: [.error],
              message: "DeepSeek Harness 暂无可用模型。请添加模型后重新检查。", variants: always(.retry)),
        entry("no_enabled_assistant", steps: [.assistantAny], surfaces: surfCheckCLIHTTP, setup: [.actionNeeded], pair: [.actionNeeded],
              message: "请启用至少一个可用助手，然后重新配对。", variants: always(.openURL(.guide))),
        entry("workspace_confirmation_required", steps: [.workspaceRoot], surfaces: surfCheckCLIHTTP, setup: [.actionNeeded], pair: [.actionNeeded],
              message: "请先在电脑上确认要与手机共享的代码目录。", variants: always(.choosePath(.workspaceRoot))),
        entry("workspace_not_found", steps: [.workspaceRoot], setup: [.error], pair: [.error],
              message: "找不到所选代码目录。请重新选择。", variants: always(.choosePath(.workspaceRoot))),
        entry("workspace_not_directory", steps: [.workspaceRoot], setup: [.error], pair: [.error],
              message: "所选位置是文件。请选择代码目录。", variants: always(.choosePath(.workspaceRoot))),
        entry("workspace_unreadable", steps: [.workspaceRoot], setup: [.error], pair: [.error],
              message: "请选择可读取的代码目录。", variants: always(.choosePath(.workspaceRoot))),
        entry("config_missing", steps: [.configStore], setup: [.actionNeeded], pair: [.actionNeeded],
              message: "请先选择代码目录并保存配置。", variants: always(.runFix(.saveSetup))),
        entry("config_dir_unwritable", steps: [.configStore], setup: [.error], pair: [.error],
              message: "无法写入配置目录。请检查访问权限和可用空间后重试。", variants: always(.retry)),
        entry("config_permissions_unsafe", steps: [.configStore], setup: [.error], pair: [.error],
              message: "配置文件的访问权限过宽。请在电脑上修复权限。", variants: configSplit(.doctorFix)),
        entry("config_invalid", steps: [.configStore], setup: [.error], pair: [.error],
              message: "配置无法安全读取。请查看已保留的配置和恢复位置。", variants: always(.openSettings(.hostRecovery))),
        entry("config_requires_newer_version", steps: [.configStore], setup: [.error], pair: [.error],
              message: "此配置需要较新的桌面端。请更新后重试。", variants: always(.openURL(.desktop))),
        entry("config_concurrent_change", steps: [.configStore], surfaces: surfCLI,
              message: "配置已在别处更改。请重新加载并确认选择。", variants: always(.retry)),
        entry("config_commit_failed", steps: [.configStore], surfaces: surfCLI,
              message: "本次配置未能保存。原配置已保留，请重试。", variants: always(.retry)),
        entry("config_recovery_required", steps: [.configStore], setup: [.error], pair: [.error],
              message: "配置需要恢复。请在电脑上查看保留的文件。", variants: always(.openSettings(.hostRecovery))),
        entry("token_rotation_requires_approval", steps: [.configStore], setup: [.error], pair: [.error],
              message: "此操作会更改电脑的配对身份。请查看保留的配置。", variants: always(.openSettings(.hostRecovery))),
        entry("legacy_codex_residue", steps: [.configStore], setup: [.error], pair: [.error],
              message: "检测到旧版 Codex 配置。请在电脑上查看迁移说明。", variants: always(.openSettings(.hostRecovery))),
        entry("tailscale_not_installed", steps: [.networkTailscale], setup: optAction, pair: optAction,
              message: "未检测到 Tailscale。需要此连接方式时请按说明安装。", variants: always(.openURL(.tailscale))),
        entry("tailscale_not_connected", steps: [.networkTailscale], setup: optAction, pair: optAction,
              message: "Tailscale 尚未连接。请连接后重新检查。", variants: always(.retry)),
        entry("tailscale_disabled", steps: [.networkTailscale], setup: optAction, pair: optAction,
              message: "Tailscale 已连接，可在配对设置中启用。", variants: transportEnable(.enableTailscale)),
        entry("tailcat_disabled", steps: [.networkTailcat], setup: optAction, pair: optAction,
              message: "内置连接可用，可在配对设置中启用。", variants: transportEnable(.enableTailcat)),
        entry("tailcat_unavailable", steps: [.networkTailcat], setup: [.error], pair: [.error],
              message: "内置连接组件不可用。请重新安装桌面端以修复组件。", variants: always(.openURL(.desktop))),
        entry("tailcat_relay_unreachable", steps: [.networkTailcat], surfaces: surfCheckCLIHTTP, setup: [.error], pair: [.error],
              message: "暂时无法连接中继。请稍后重试。", variants: always(.retry)),
        entry("tailcat_busy", steps: [.networkTailcat], surfaces: surfCLIHTTP,
              message: "内置连接正在处理其他操作。请稍后重试。", variants: always(.retry)),
        entry("tailcat_settings_invalid", steps: [.networkTailcat], setup: [.error], pair: [.error],
              message: "中继设置无效或尚未生效。请检查连接设置。", variants: always(.openSettings(.connections))),
        entry("lan_unavailable", steps: [.networkLAN], setup: optAction, pair: optAction,
              message: "未检测到可信局域网。请连接专用网络后重新检查。", variants: always(.retry)),
        entry("lan_disabled", steps: [.networkLAN], setup: optAction, pair: optAction,
              message: "同一局域网连接可用，可在配对设置中启用。", variants: transportEnable(.enableLAN)),
        entry("lan_public_network_blocked", steps: [.networkLAN], platforms: winOnly, setup: [.actionNeeded], pair: [.actionNeeded],
              message: "当前网络未确认为专用网络。请检查 Windows 网络配置。", variants: always(.openSettings(.windowsNetworkProfile))),
        entry("lan_firewall_blocked", steps: [.networkLAN], platforms: winOnly, setup: [.actionNeeded], pair: [.actionNeeded],
              message: "防火墙规则未允许专用网络连接。请在电脑上检查规则。", variants: always(.openSettings(.windowsFirewall))),
        entry("no_direct_network", steps: [.networkAny], setup: [.actionNeeded], pair: [.actionNeeded],
              message: "没有可用的直连通道。可在配对时启用内置连接。", variants: transportEnable(.enableTailcat)),
        entry("no_network_available", steps: [.networkAny], setup: [.actionNeeded], pair: [.actionNeeded],
              message: "暂无可用的连接方式。请检查网络后重试。", variants: [
                .init(when: .init(stage: .setup, configured: false), fix: .runFix(.saveSetup)),
                .init(when: .init(configured: true), fix: .retry),
                .init(when: .init(stage: .pair, configured: false), fix: .retry),
              ]),
        entry("network_selection_required", steps: [.networkAny], setup: [.actionNeeded], pair: [.actionNeeded],
              message: "请选择要用于配对的连接方式。", variants: [
                .init(when: .init(configured: false), fix: .runFix(.saveSetup)),
                .init(when: .init(stage: .setup, configured: true), fix: .openSettings(.connections)),
                .init(when: .init(stage: .pair, configured: true, recommendedTransport: .some(.tailscale)), fix: .runFix(.enableTailscale)),
                .init(when: .init(stage: .pair, configured: true, recommendedTransport: .some(.tailcat)), fix: .runFix(.enableTailcat)),
                .init(when: .init(stage: .pair, configured: true, recommendedTransport: .some(.lan)), fix: .runFix(.enableLAN)),
                .init(when: .init(stage: .pair, configured: true, recommendedTransport: .none), fix: .openSettings(.connections)),
              ]),
        entry("service_start_timeout", steps: [.serviceDaemon], setup: [.error], pair: [.error],
              message: "等待后台服务就绪超时。请重新检查服务状态。", variants: always(.retry)),
        entry("service_port_in_use", steps: [.serviceDaemon], setup: [.error], pair: [.error],
              message: "服务端口已被占用。请关闭占用端口的应用后重试。", variants: always(.retry)),
        entry("service_requires_approval", steps: [.serviceDaemon], platforms: macOnly, surfaces: surfNative, setup: [.actionNeeded], pair: [.actionNeeded],
              message: "需要在系统设置中允许后台服务运行。请在“登录项”中允许后重新检查，服务就绪后即可生成二维码。", variants: always(.openSettings(.loginItems))),
        entry("service_version_mismatch", steps: [.serviceDaemon], setup: [.error], pair: [.error],
              message: "后台服务与客户端版本不一致。请在电脑上重新加载服务。", variants: configSplit(.restartService)),
        entry("service_not_registered", steps: [.serviceDaemon], setup: [.actionNeeded], pair: [.actionNeeded],
              message: "后台服务尚未注册。请在电脑上注册并启动服务。", variants: configSplit(.registerService)),
        entry("service_install_incomplete", steps: [.serviceDaemon], setup: [.error], pair: [.error],
              message: "后台服务组件不完整。请重新安装桌面端。", variants: always(.openURL(.desktop))),
        entry("service_not_running", steps: [.serviceDaemon], setup: [.actionNeeded], pair: [.actionNeeded],
              message: "后台服务尚未运行。请在电脑上启动服务。", variants: configSplit(.restartService)),
        entry("service_start_failed", steps: [.serviceDaemon], setup: [.error], pair: [.error],
              message: "后台服务启动失败。请检查并重试。", variants: configSplit(.restartService)),
        entry("homebrew_service_active", steps: [.serviceOwnerConflict], platforms: macOnly, setup: [.optional], pair: [.optional],
              message: "Homebrew 正在管理后台服务。可继续使用，或确认后改由桌面端管理。", variants: configSplit(.takeoverHomebrew)),
        entry("permission_login_item_disabled", steps: [.permissionLoginItem], platforms: macOnly, surfaces: surfNative, setup: [.optional], pair: [.optional],
              message: "主应用尚未启用登录时启动。可按需在登录项中设置。", variants: always(.openSettings(.loginItems))),
        entry("permission_folder_denied", steps: [.permissionFolderAccess], platforms: macOnly, surfaces: surfCheckNative, setup: [.actionNeeded], pair: [.actionNeeded],
              message: "后台服务无法读取所选目录。请检查文件与文件夹权限。", variants: always(.openSettings(.filesAndFolders))),
        entry("permission_local_network_denied", steps: [.permissionLocalNetwork], platforms: macOnly, surfaces: surfNative, setup: [.actionNeeded], pair: [.actionNeeded],
              message: "请在系统设置中允许本地网络访问。", variants: always(.openSettings(.localNetwork))),
        entry("permission_photos_denied", steps: [.permissionPhotos], platforms: macOnly, surfaces: surfNative, setup: [.optional], pair: [.optional],
              message: "照片访问尚未获准。需要使用时可在系统设置中允许。", variants: always(.openSettings(.photos))),
        entry("permission_full_disk_optional", steps: [.permissionFullDisk], platforms: macOnly, surfaces: surfNative, setup: [.optional], pair: [.optional],
              message: "如需访问更多文件，可在系统设置中允许完全磁盘访问。", variants: always(.openSettings(.fullDiskAccess))),
        entry("permission_unobserved", steps: [.permissionLoginItem, .permissionFolderAccess, .permissionLocalNetwork, .permissionPhotos, .permissionFullDisk], platforms: macAndWin, surfaces: surfCheckNative, setup: [.optional], pair: [.optional],
              message: "{title}：尚未获得此权限的状态。可以跳过此项。", variants: always(.skip)),
        entry("pair_host_unreachable", steps: [.serviceDaemon], surfaces: surfCheckCLIHTTP, setup: [.error], pair: [.error],
              message: "无法连接电脑后台服务。请检查连接后重试。", variants: always(.retry)),
        entry("pair_token_mismatch", steps: [.serviceDaemon], surfaces: surfCheckCLIHTTP, setup: [.error], pair: [.error],
              message: "电脑后台服务身份未同步。请在电脑端确认服务归属并重新加载配置后重试，无需删除手机上的已保存电脑。", variants: configSplit(.restartService)),
        entry("pair_ticket_expired", steps: [.networkAny], surfaces: surfCLIHTTP,
              message: "二维码已过期。请在电脑配对窗口点击“刷新二维码”后重扫，已有配对不受影响。", variants: always(.retry)),
        entry("pair_ticket_invalid", steps: [.networkAny], surfaces: surfCLIHTTP,
              message: "配对链接无效。请在电脑上刷新二维码后重扫。", variants: always(.retry)),
        entry("pair_clock_skew", steps: [.networkAny], surfaces: surfCLIHTTP,
              message: "设备时间不一致。请检查系统日期与时间后重新配对。", variants: always(.openSettings(.dateTime))),
        entry("pair_local_forbidden", steps: [.serviceDaemon], surfaces: surfHTTP,
              message: "此请求无法在本机认领。请使用手机扫描电脑上的二维码。", variants: always(.retry)),
        entry("pair_managed_entitlement_required", steps: [.networkTailcat], surfaces: surfCLIHTTP,
              message: "此托管连接需要有效的订阅权益。请查看托管连接设置。", variants: always(.openSettings(.managedConnection))),
        entry("pair_managed_grant_conflict", steps: [.networkTailcat], surfaces: surfCLIHTTP,
              message: "托管连接授权未生效或已过期。请重新获取配对链接。", variants: always(.retry)),
        entry("invalid_request", steps: [.configStore, .networkAny], surfaces: surfCLIHTTP,
              message: "{title}：请求参数无效。请检查输入后重试。", variants: [
                .init(when: .init(step: .configStore, surface: .cli), fix: .retry),
                .init(when: .init(step: .networkAny, surface: .http), fix: .retry),
              ]),
        entry("probe_timeout", anyStep: true, surfaces: surfCheckCLIHTTP, setup: [.error], pair: [.error],
              message: "{title}：检查超时。请重新检查此项。", variants: always(.retry)),
        entry("internal_error", anyStep: true, surfaces: surfCheckCLIHTTP, setup: [.error], pair: [.error],
              message: "{title}：未能完成此项操作。请重试。", variants: always(.retry)),
        // 2 UI-local codes (never accepted on the wire)
        entry("command_timeout", uiLocal: true, anyStep: true, surfaces: surfUILocal,
              message: "{title}：命令等待超时。请重新检查当前步骤。", variants: always(.retry)),
        entry("embedded_binary_missing", uiLocal: true, steps: [.serviceDaemon], surfaces: surfUILocal,
              message: "缺少内置服务程序。请重新安装桌面端。", variants: always(.openURL(.desktop))),
    ]

    static let entriesByCode: [String: OnboardingCatalogEntry] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.code, $0) }
    )

    static var wireCodes: Set<String> {
        Set(allEntries.filter { !$0.isUILocal }.map(\.code))
    }

    static var uiLocalCodes: Set<String> {
        Set(allEntries.filter(\.isUILocal).map(\.code))
    }

    static func localizedMessage(
        code: String,
        step: OnboardingCheckID? = nil,
        title: String? = nil,
        detectedVersion: String? = nil
    ) -> String {
        guard let entry = entriesByCode[code] else {
            return safeFallbackCopy
        }
        let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? step?.localizedTitle
            ?? OnboardingCheckID.serviceDaemon.localizedTitle
        let base = entry.messageZH.replacingOccurrences(of: "{title}", with: resolvedTitle)
        if code.hasSuffix("_signed_out"),
           let ver = detectedVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ver.isEmpty {
            return "已检测到版本 \(ver)。\(base)"
        }
        return base
    }

    static func synthesizeLocal(
        code: String,
        step: OnboardingCheckID? = nil,
        title: String? = nil
    ) -> OnboardingResolvedDiagnostic {
        let resolvedStep = step ?? .serviceDaemon
        guard let entry = entriesByCode[code], entry.isUILocal, let fix = entry.variants.first?.fix else {
            return OnboardingResolvedDiagnostic(
                code: code, step: resolvedStep, message: safeFallbackCopy,
                primaryAction: nil, secondaryAction: nil, secondaryLabel: nil,
                configPath: nil, recoveryPath: nil, isTrusted: false, isLegacyHost: false
            )
        }
        let message = localizedMessage(code: code, step: resolvedStep, title: title)
        return OnboardingResolvedDiagnostic(
            code: code, step: resolvedStep, message: message,
            primaryAction: fix, secondaryAction: entry.secondaryFix, secondaryLabel: entry.secondaryLabelZH,
            configPath: nil, recoveryPath: nil, isTrusted: true, isLegacyHost: false
        )
    }

    static func validateDiagnostic(
        code: String,
        step: OnboardingCheckID,
        fix: OnboardingFix,
        context: OnboardingValidationContext,
        state: OnboardingCheckState? = nil
    ) -> Result<OnboardingResolvedDiagnostic, OnboardingValidationError> {
        guard let entry = entriesByCode[code] else {
            return .failure(.invalidTuple("unknown code \(code)"))
        }
        if context.surface != .uiLocal && entry.isUILocal {
            return .failure(.invalidTuple("ui_local code \(code) rejected on wire"))
        }
        if context.surface == .native && context.platform != .macos {
            return .failure(.invalidTuple("native overlay requires macOS"))
        }
        guard entry.surfaces.contains(context.surface),
              entry.platforms.contains(context.platform),
              step.platforms.contains(context.platform)
        else {
            return .failure(.invalidTuple("\(code) unavailable on \(context.surface.rawValue)/\(context.platform.rawValue)/\(step.rawValue)"))
        }
        guard entry.allowsAnyStep || entry.steps.contains(step) else {
            return .failure(.invalidTuple("\(code) cannot use step \(step.rawValue)"))
        }
        if let state {
            let allowed = context.stage == .pair ? entry.pairStates : entry.setupStates
            guard allowed.contains(state) else {
                return .failure(.invalidTuple("\(code) cannot use state \(state.rawValue) in \(context.stage.rawValue)"))
            }
        }
        let matching = entry.variants.filter { variantMatches($0.when, step: step, context: context) }
        guard matching.count == 1, matching[0].fix == fix else {
            return .failure(.invalidTuple("mismatched fix for \(code) at \(step.rawValue)"))
        }
        if case .runFix(let action) = fix {
            if action.requiresConfig && context.configured != true {
                return .failure(.invalidTuple("action \(action.rawValue) requires configuration"))
            }
            if let cap = action.requiredCapability, context.verifiedCapability != cap {
                return .failure(.invalidTuple("action \(action.rawValue) requires verified capability \(cap)"))
            }
            if action.isTransportEnable && context.stage != .pair {
                return .failure(.invalidTuple("transport enable \(action.rawValue) outside pair stage"))
            }
        }
        return .success(OnboardingResolvedDiagnostic(
            code: code,
            step: step,
            message: localizedMessage(code: code, step: step),
            primaryAction: fix,
            secondaryAction: entry.secondaryFix,
            secondaryLabel: entry.secondaryLabelZH,
            configPath: nil,
            recoveryPath: nil,
            isTrusted: true,
            isLegacyHost: false
        ))
    }

    static func validateCheck(
        _ check: OnboardingCheck,
        context: OnboardingValidationContext
    ) -> Result<OnboardingResolvedDiagnostic, OnboardingValidationError> {
        guard check.group == check.id.group, check.id.platforms.contains(context.platform) else {
            return .failure(.invalidTuple("\(check.id.rawValue) group/platform mismatch"))
        }
        guard !check.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !check.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.missingRequiredField("\(check.id.rawValue) empty title/detail"))
        }
        if check.id != .configStore && (check.hasConfigPathKey || check.hasRecoveryPathKey) {
            return .failure(.invalidTuple("unexpected path fields on \(check.id.rawValue)"))
        }
        if check.state == .ok || check.state == .checking {
            guard !check.hasCodeKey, !check.hasFixKey, !check.blocking else {
                return .failure(.invalidTuple("\(check.id.rawValue) state \(check.state.rawValue) cannot carry code/fix or block"))
            }
        } else {
            guard check.hasCodeKey, check.hasFixKey, check.code != nil, check.fix != nil else {
                return .failure(.missingRequiredField("\(check.id.rawValue) missing code/fix"))
            }
        }
        if check.id.isIndividualAssistant || check.id.isIndividualNetwork {
            guard check.enabled != nil, check.hasAvailableKey, !check.blocking else {
                return .failure(.invalidTuple("individual check \(check.id.rawValue) missing enabled/available or blocking"))
            }
        }
        if check.id.isCLIAssistant {
            guard check.hasCandidatesKey, let candidates = check.candidates else {
                return .failure(.missingRequiredField("CLI assistant \(check.id.rawValue) missing candidates"))
            }
            let selectedCount = candidates.filter { $0.outcome == .selected }.count
            let needsSelection = check.state == .ok
                || (check.code?.hasSuffix("_signed_out") == true)
                || check.code == "assistant_disabled"
            if selectedCount > 1 || (needsSelection && selectedCount != 1) {
                return .failure(.invalidTuple("invalid selected candidate count \(selectedCount) for \(check.id.rawValue)"))
            }
        }
        guard let code = check.code, let fix = check.fix else {
            return .success(OnboardingResolvedDiagnostic(
                code: nil, step: check.id, message: check.detail,
                primaryAction: nil, secondaryAction: nil, secondaryLabel: nil,
                configPath: check.configPath, recoveryPath: check.recoveryPath,
                isTrusted: true, isLegacyHost: false
            ))
        }
        let isPair = context.stage == .pair
        switch check.id {
        case .configStore, .workspaceRoot:
            guard check.blocking == (isPair || check.state == .error) else {
                return .failure(.invalidTuple("inconsistent workspace blocker on \(check.id.rawValue)"))
            }
        case .assistantAny, .networkAny, .serviceDaemon:
            guard check.blocking == isPair else {
                return .failure(.invalidTuple("inconsistent pair blocker on \(check.id.rawValue)"))
            }
        default:
            break
        }
        switch validateDiagnostic(code: code, step: check.id, fix: fix, context: context, state: check.state) {
        case .failure(let error):
            return .failure(error)
        case .success(let resolved):
            if code.hasSuffix("_signed_out") {
                if context.stage == .pair || context.explicitlyEnabled != nil {
                    let enabled = context.stage == .setup
                        ? (context.explicitlyEnabled ?? false)
                        : (check.enabled == true)
                    guard (check.state == .actionNeeded) == enabled else {
                        return .failure(.invalidTuple("incorrect signed_out state for \(check.id.rawValue)"))
                    }
                }
            }
            let msg = localizedMessage(
                code: code,
                step: check.id,
                title: check.title,
                detectedVersion: check.selectedOrDetectedVersion
            )
            return .success(OnboardingResolvedDiagnostic(
                code: resolved.code,
                step: resolved.step,
                message: msg,
                primaryAction: resolved.primaryAction,
                secondaryAction: resolved.secondaryAction,
                secondaryLabel: resolved.secondaryLabel,
                configPath: check.configPath,
                recoveryPath: check.recoveryPath,
                isTrusted: true,
                isLegacyHost: false
            ))
        }
    }

    static func validateReport(
        _ report: OnboardingPreflightReport,
        platform: OnboardingPlatform,
        nativeOverlay: Bool = false,
        verifiedCapability: String? = nil
    ) -> Result<[OnboardingCheckID: OnboardingResolvedDiagnostic], OnboardingValidationError> {
        guard report.schema == OnboardingSchema.preflightV1 else {
            return .failure(.unsupportedSchema(report.schema))
        }
        guard !report.configPath.isEmpty, !report.scanRoot.isEmpty, !report.browseRoot.isEmpty else {
            return .failure(.missingRequiredField("report missing required paths"))
        }
        if !report.configured && report.workspaceConfirmed {
            return .failure(.invalidTuple("unconfigured report cannot have workspace_confirmed=true"))
        }
        if report.ok && report.stage == .pair {
            guard report.configured && report.workspaceConfirmed && report.scanRootExists else {
                return .failure(.invalidTuple("ready pair report requires configured, confirmed, existing workspace"))
            }
        }
        let applicable = OnboardingCheckID.applicable(for: platform)
        var seen: Set<OnboardingCheckID> = []
        for check in report.checks {
            if !seen.insert(check.id).inserted {
                return .failure(.duplicateRow(check.id))
            }
        }
        guard report.checks.count == applicable.count else {
            return .failure(.unexpectedRowCount(expected: applicable.count, actual: report.checks.count))
        }
        var firstBlocker: OnboardingCheckID?
        var eligibleByGroup: [OnboardingCheckGroup: Bool] = [:]
        var expectedRecommended: OnboardingTransport?
        var resolvedByID: [OnboardingCheckID: OnboardingResolvedDiagnostic] = [:]

        for (index, check) in report.checks.enumerated() {
            let expectedID = applicable[index]
            guard check.id == expectedID else {
                return .failure(.unexpectedRowOrder(expected: expectedID, actual: check.id))
            }
            guard check.state != .checking else {
                return .failure(.unfinishedCheckInReport(check.id))
            }
            let surface: OnboardingSurface = nativeOverlay
                && (check.id.isPermission || (check.id == .serviceDaemon && check.code == "service_requires_approval"))
                ? .native
                : .check
            let ctx = OnboardingValidationContext(
                surface: surface,
                platform: platform,
                stage: report.stage,
                configured: report.configured,
                hasRecommendedTransport: true,
                recommendedTransport: report.recommendedTransport,
                verifiedCapability: verifiedCapability
            )
            switch validateCheck(check, context: ctx) {
            case .failure(let error):
                return .failure(error)
            case .success(let resolved):
                resolvedByID[check.id] = resolved
            }
            if check.blocking {
                if report.stage == .setup && check.group != .workspace {
                    return .failure(.invalidTuple("unexpected setup blocker \(check.id.rawValue)"))
                }
                if firstBlocker == nil { firstBlocker = check.id }
            }
            if check.enabled != nil {
                let ready = check.enabled == true && check.available == true
                guard (check.state == .ok) == ready else {
                    return .failure(.invalidTuple("\(check.id.rawValue) intent/availability mismatch"))
                }
                eligibleByGroup[check.group] = (eligibleByGroup[check.group] ?? false) || ready
                if check.group == .network && expectedRecommended == nil && check.available == true {
                    switch check.id {
                    case .networkTailscale: expectedRecommended = .tailscale
                    case .networkTailcat: expectedRecommended = .tailcat
                    case .networkLAN: expectedRecommended = .lan
                    default: break
                    }
                }
            }
            if check.id == .assistantAny || check.id == .networkAny {
                let groupEligible = eligibleByGroup[check.group] ?? false
                guard (check.state == .ok) == groupEligible,
                      check.blocking == (report.stage == .pair && !groupEligible)
                else {
                    return .failure(.invalidTuple("\(check.id.rawValue) eligibility mismatch"))
                }
            }
            if report.stage == .pair && check.id == .serviceDaemon {
                guard check.blocking == (check.state != .ok) else {
                    return .failure(.invalidTuple("daemon readiness mismatch"))
                }
            }
        }
        guard report.recommendedTransport == expectedRecommended else {
            return .failure(.invalidTuple("unexpected recommended_transport"))
        }
        guard report.ok == (firstBlocker == nil) else {
            return .failure(.invalidTuple("report ok inconsistent with blockers"))
        }
        let expectedNext: OnboardingCheckID = firstBlocker
            ?? (report.stage == .setup && !report.configured ? .configStore : .networkAny)
        guard report.recommendedNext == expectedNext else {
            return .failure(.invalidTuple("unexpected recommended_next \(report.recommendedNext.rawValue)"))
        }
        return .success(resolvedByID)
    }

    static func decodeErrorEnvelope(
        from data: Data,
        context: OnboardingValidationContext
    ) -> Result<OnboardingResolvedDiagnostic, OnboardingValidationError> {
        guard let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidTuple("error envelope is not a JSON object"))
        }
        if context.surface == .http {
            for key in rawObject.keys where httpForbiddenFields.contains(key) {
                return .failure(.invalidTuple("forbidden public field \(key)"))
            }
        }
        guard let errorObj = rawObject["error"] as? [String: Any] else {
            return .failure(.missingRequiredField("error envelope missing error object"))
        }
        if context.surface == .http {
            for key in errorObj.keys where httpForbiddenFields.contains(key) {
                return .failure(.invalidTuple("forbidden public error field \(key)"))
            }
        }
        guard let envelope = try? JSONDecoder().decode(OnboardingErrorEnvelope.self, from: data),
              envelope.ok == false
        else {
            return .failure(.invalidTuple("malformed error envelope or disallowed fix"))
        }
        guard !envelope.error.code.isEmpty, !envelope.error.step.isEmpty, !envelope.error.message.isEmpty else {
            return .failure(.missingRequiredField("error envelope missing required strings"))
        }
        guard let step = OnboardingCheckID(rawValue: envelope.error.step) else {
            return .failure(.invalidTuple("unknown error step \(envelope.error.step)"))
        }
        if context.surface != .http {
            let hasRecoveryPaths = errorObj["config_path"] != nil || errorObj["recovery_path"] != nil
            if hasRecoveryPaths && envelope.error.fix != .openSettings(.hostRecovery) {
                return .failure(.invalidTuple("recovery paths only allowed for host_recovery"))
            }
        }
        switch validateDiagnostic(code: envelope.error.code, step: step, fix: envelope.error.fix, context: context) {
        case .failure(let error):
            return .failure(error)
        case .success(let resolved):
            return .success(OnboardingResolvedDiagnostic(
                code: resolved.code,
                step: resolved.step,
                message: resolved.message,
                primaryAction: resolved.primaryAction,
                secondaryAction: resolved.secondaryAction,
                secondaryLabel: resolved.secondaryLabel,
                configPath: envelope.error.configPath,
                recoveryPath: envelope.error.recoveryPath,
                isTrusted: true,
                isLegacyHost: false
            ))
        }
    }

    static func looksLikeErrorEnvelopeJSON(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = obj["ok"] as? Bool,
              ok == false,
              obj["error"] is [String: Any]
        else {
            return false
        }
        return true
    }

    static func isRecognizedLegacyHostStderr(_ stderrText: String) -> Bool {
        let lower = stderrText.lowercased()
        return (lower.contains("unknown command") && lower.contains("preflight"))
            || (lower.contains("未知命令") && lower.contains("preflight"))
            || lower.contains("flag provided but not defined: -no-pair")
            || lower.contains("unknown flag: --no-pair")
    }

    /// Resolves CLI exit-1 output: reads stdout v1 JSON envelope first; any unknown,
    /// mismatched, or tampered payload yields safe copy and `primaryAction = nil` (zero execution).
    static func resolveCLIError(
        stdout: Data,
        stderr: Data,
        context: OnboardingValidationContext
    ) -> OnboardingResolvedDiagnostic? {
        if looksLikeErrorEnvelopeJSON(stdout) {
            switch decodeErrorEnvelope(from: stdout, context: context) {
            case .success(let resolved):
                return resolved
            case .failure:
                return OnboardingResolvedDiagnostic(
                    code: nil,
                    step: nil,
                    message: safeFallbackCopy,
                    primaryAction: nil,
                    secondaryAction: nil,
                    secondaryLabel: nil,
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: false,
                    isLegacyHost: false
                )
            }
        }
        let stderrText = String(decoding: stderr, as: UTF8.self)
        if isRecognizedLegacyHostStderr(stderrText) {
            return OnboardingResolvedDiagnostic(
                code: nil,
                step: .serviceDaemon,
                message: legacyHostCopy,
                primaryAction: .openURL(.desktop),
                secondaryAction: nil,
                secondaryLabel: nil,
                configPath: nil,
                recoveryPath: nil,
                isTrusted: true,
                isLegacyHost: true
            )
        }
        return nil
    }

    private static func variantMatches(
        _ when: OnboardingVariantWhen,
        step: OnboardingCheckID,
        context: OnboardingValidationContext
    ) -> Bool {
        if let wantStep = when.step, wantStep != step { return false }
        if let wantStage = when.stage, wantStage != context.stage { return false }
        if let wantSurface = when.surface, wantSurface != context.surface { return false }
        if let wantConfigured = when.configured, context.configured != wantConfigured { return false }
        switch when.recommendedTransport {
        case .any:
            break
        case .none:
            guard context.hasRecommendedTransport, context.recommendedTransport == nil else { return false }
        case .some(let wantTransport):
            guard context.hasRecommendedTransport, context.recommendedTransport == wantTransport else { return false }
        }
        return true
    }
}

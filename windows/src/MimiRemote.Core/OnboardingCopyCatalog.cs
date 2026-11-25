using System.Diagnostics.CodeAnalysis;
using System.Text.Json;

namespace MimiRemote.Core;

public sealed record OnboardingCheckSpec(string Id, string Group, IReadOnlyList<string> Platforms, string TitleZh);

public sealed record OnboardingRunFixSpec(bool RequiresConfig, string? RequiresCapability = null);

public sealed record OnboardingVariantWhen(
    string? Step = null,
    string? Stage = null,
    string? Surface = null,
    bool? Configured = null,
    bool HasRecommendedTransport = false,
    string? RecommendedTransport = null);

public sealed record OnboardingFixVariant(OnboardingVariantWhen When, OnboardingFix Fix);

public sealed record OnboardingCatalogEntry(
    string Code,
    bool IsUiLocal,
    IReadOnlyList<string> Steps,
    IReadOnlyList<string> Platforms,
    IReadOnlyList<string> Surfaces,
    IReadOnlyList<string> SetupStates,
    IReadOnlyList<string> PairStates,
    string MessageZh,
    IReadOnlyList<OnboardingFixVariant> Variants,
    string? StateRule = null,
    OnboardingFix? SecondaryFix = null,
    string? SecondaryLabelZh = null);

public static class OnboardingCopyCatalog
{
    public const string SafeFallbackCopy = "当前操作暂时无法自动处理。请检查电脑端状态后手动重新检查。";
    public const string LegacyHostCopy = "当前电脑端版本较旧，不支持新的引导检查。请更新桌面端后重试。";

    public const string UrlCodex = "https://learn.chatgpt.com/docs/codex/cli";
    public const string UrlClaude = "https://code.claude.com/docs/en/quickstart";
    public const string UrlAgy = "https://antigravity.google/";
    public const string UrlHarness = "https://github.com/deepseek-ai/deepseek-harness";
    public const string UrlTailscale = "https://tailscale.com/download";
    public const string UrlDesktop = "https://github.com/gaixianggeng/mimi-remote/releases/latest";
    public const string UrlGuide = "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md";

    private const string SignedOutRetryLabel = "我已登录，重新检查";

    private static readonly string[] AllPlatforms = ["macos", "windows", "linux"];
    private static readonly string[] MacOnly = ["macos"];
    private static readonly string[] WinOnly = ["windows"];
    private static readonly string[] MacAndWin = ["macos", "windows"];
    private static readonly string[] SurfCheckCli = ["check", "cli"];
    private static readonly string[] SurfCheckCliHttp = ["check", "cli", "http"];
    private static readonly string[] SurfCli = ["cli"];
    private static readonly string[] SurfCliHttp = ["cli", "http"];
    private static readonly string[] SurfHttp = ["http"];
    private static readonly string[] SurfNative = ["native"];
    private static readonly string[] SurfCheckNative = ["check", "native"];
    private static readonly string[] SurfUiLocal = ["ui_local"];
    private static readonly string[] StatesOptAction = ["optional", "action_needed"];
    private static readonly string[] StatesAction = ["action_needed"];
    private static readonly string[] StatesOptional = ["optional"];
    private static readonly string[] StatesError = ["error"];
    private static readonly string[] StatesEmpty = [];

    private static readonly HashSet<string> ValidOutcomes = new(StringComparer.Ordinal)
    {
        "missing", "unusable", "unsupported", "compatible", "selected", "timeout",
    };

    private static readonly HashSet<string> ValidSources = new(StringComparer.Ordinal)
    {
        "pin", "env", "auto",
    };

    private static readonly HashSet<string> ValidTransports = new(StringComparer.Ordinal)
    {
        "tailscale", "tailcat", "lan",
    };

    private static readonly HashSet<string> ValidCheckStates = new(StringComparer.Ordinal)
    {
        "checking", "ok", "optional", "action_needed", "error",
    };

    private static readonly HashSet<string> IndividualCheckIds = new(StringComparer.Ordinal)
    {
        "assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek",
        "network_tailscale", "network_tailcat", "network_lan",
    };

    private static readonly HashSet<string> CliAssistantIds = new(StringComparer.Ordinal)
    {
        "assistant_codex", "assistant_claude", "assistant_agy",
    };

    private static readonly HashSet<string> TransportEnableActions = new(StringComparer.Ordinal)
    {
        "enable_tailscale", "enable_lan", "enable_tailcat",
    };

    private static readonly HashSet<string> HttpForbiddenFields = new(StringComparer.Ordinal)
    {
        "config_path", "recovery_path", "candidates", "detected_version", "min_version",
        "source", "scan_root", "browse_root", "endpoint", "pair_url", "stderr",
        "path", "host", "host_id", "runtime", "runtime_status", "config",
        "scan_root_exists", "tailscale_dns_name", "tailscale_device_name", "device_id",
        "raw_stderr", "grant", "signature", "token", "token_file", "connect_url",
    };

    public static IReadOnlyDictionary<string, string> AllowedUrls { get; } = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["CODEX"] = UrlCodex,
        ["CLAUDE"] = UrlClaude,
        ["AGY"] = UrlAgy,
        ["HARNESS"] = UrlHarness,
        ["TS"] = UrlTailscale,
        ["DESKTOP"] = UrlDesktop,
        ["GUIDE"] = UrlGuide,
    };

    private static readonly HashSet<string> AllowedUrlSet = new(AllowedUrls.Values, StringComparer.Ordinal);

    public static IReadOnlyList<string> SettingsTargets { get; } =
    [
        "login_items",
        "files_and_folders",
        "local_network",
        "photos",
        "full_disk_access",
        "windows_firewall",
        "windows_network_profile",
        "assistants",
        "connections",
        "host_recovery",
        "date_time",
        "managed_connection",
    ];

    private static readonly HashSet<string> SettingsTargetSet = new(SettingsTargets, StringComparer.Ordinal);

    public static IReadOnlyList<string> PathTargets { get; } =
    [
        "workspace_root",
        "codex_bin",
        "claude_bin",
        "agy_bin",
    ];

    private static readonly HashSet<string> PathTargetSet = new(PathTargets, StringComparer.Ordinal);

    public static IReadOnlyDictionary<string, OnboardingRunFixSpec> RunFixSpecs { get; } =
        new Dictionary<string, OnboardingRunFixSpec>(StringComparer.Ordinal)
        {
            ["save_setup"] = new(false),
            ["enable_codex"] = new(false),
            ["enable_claude"] = new(false),
            ["enable_agy"] = new(false),
            ["enable_tailscale"] = new(true),
            ["enable_lan"] = new(true),
            ["enable_tailcat"] = new(true),
            ["connect_deepseek"] = new(true),
            ["restart_service"] = new(true),
            ["register_service"] = new(true),
            ["doctor_fix"] = new(true, OnboardingSchema.DoctorFixCapability),
            ["takeover_homebrew"] = new(true),
        };

    public static IReadOnlyList<OnboardingCheckSpec> Checks { get; } =
    [
        new("config_store", "workspace", AllPlatforms, "配置文件"),
        new("workspace_root", "workspace", AllPlatforms, "代码目录"),
        new("service_owner_conflict", "service", MacOnly, "后台服务归属"),
        new("service_daemon", "service", AllPlatforms, "后台服务"),
        new("assistant_codex", "assistant", AllPlatforms, "Codex 助手"),
        new("assistant_claude", "assistant", AllPlatforms, "Claude Code 助手"),
        new("assistant_agy", "assistant", AllPlatforms, "Antigravity 助手"),
        new("assistant_deepseek", "assistant", AllPlatforms, "DeepSeek 助手"),
        new("assistant_any", "assistant", AllPlatforms, "可用助手"),
        new("network_tailscale", "network", AllPlatforms, "Tailscale 连接"),
        new("network_tailcat", "network", AllPlatforms, "内置连接"),
        new("network_lan", "network", AllPlatforms, "同一局域网"),
        new("network_any", "network", AllPlatforms, "手机连接方式"),
        new("permission_login_item", "permission", MacOnly, "登录项"),
        new("permission_folder_access", "permission", MacOnly, "文件与文件夹"),
        new("permission_local_network", "permission", MacAndWin, "本地网络"),
        new("permission_photos", "permission", MacOnly, "照片"),
        new("permission_full_disk", "permission", MacOnly, "完全磁盘访问"),
    ];

    private static readonly Dictionary<string, OnboardingCheckSpec> CheckIndex =
        Checks.ToDictionary(c => c.Id, StringComparer.Ordinal);

    private static readonly OnboardingFix SaveSetupFix = OnboardingFix.RunFix("save_setup");
    private static readonly OnboardingFix HostRecoveryFix = OnboardingFix.OpenSettings("host_recovery");
    private static readonly OnboardingFix ConnectionsFix = OnboardingFix.OpenSettings("connections");
    private static readonly OnboardingFix DesktopUrlFix = OnboardingFix.OpenUrl(UrlDesktop);
    private static readonly OnboardingFix WorkspacePickFix = OnboardingFix.ChoosePath("workspace_root");

    private static IReadOnlyList<OnboardingFixVariant> Always(OnboardingFix fix) =>
        [new(new OnboardingVariantWhen(), fix)];

    private static IReadOnlyList<OnboardingFixVariant> ConfigSplit(string action) =>
    [
        new(new OnboardingVariantWhen(Configured: false), SaveSetupFix),
        new(new OnboardingVariantWhen(Configured: true), OnboardingFix.RunFix(action)),
    ];

    private static IReadOnlyList<OnboardingFixVariant> TransportEnable(string action) =>
    [
        new(new OnboardingVariantWhen(Configured: false), SaveSetupFix),
        new(new OnboardingVariantWhen(Stage: "setup", Configured: true), ConnectionsFix),
        new(new OnboardingVariantWhen(Stage: "pair", Configured: true), OnboardingFix.RunFix(action)),
    ];

    private static readonly OnboardingFixVariant[] RuntimePathInvalidVariants =
    [
        new(new OnboardingVariantWhen(Step: "assistant_codex"), OnboardingFix.ChoosePath("codex_bin")),
        new(new OnboardingVariantWhen(Step: "assistant_claude"), OnboardingFix.ChoosePath("claude_bin")),
        new(new OnboardingVariantWhen(Step: "assistant_agy"), OnboardingFix.ChoosePath("agy_bin")),
    ];

    private static readonly OnboardingFixVariant[] RuntimeIncompatibleVariants =
    [
        new(new OnboardingVariantWhen(Step: "assistant_codex"), OnboardingFix.OpenUrl(UrlCodex)),
        new(new OnboardingVariantWhen(Step: "assistant_claude"), OnboardingFix.OpenUrl(UrlClaude)),
        new(new OnboardingVariantWhen(Step: "assistant_agy"), OnboardingFix.OpenUrl(UrlAgy)),
    ];

    private static readonly OnboardingFixVariant[] AssistantDisabledVariants =
    [
        new(new OnboardingVariantWhen(Step: "assistant_codex"), OnboardingFix.RunFix("enable_codex")),
        new(new OnboardingVariantWhen(Step: "assistant_claude"), OnboardingFix.RunFix("enable_claude")),
        new(new OnboardingVariantWhen(Step: "assistant_agy"), OnboardingFix.RunFix("enable_agy")),
        new(new OnboardingVariantWhen(Step: "assistant_deepseek", Configured: false), SaveSetupFix),
        new(new OnboardingVariantWhen(Step: "assistant_deepseek", Configured: true), OnboardingFix.RunFix("connect_deepseek")),
    ];

    private static readonly OnboardingFixVariant[] NoNetworkAvailableVariants =
    [
        new(new OnboardingVariantWhen(Stage: "setup", Configured: false), SaveSetupFix),
        new(new OnboardingVariantWhen(Configured: true), OnboardingFix.Retry),
        new(new OnboardingVariantWhen(Stage: "pair", Configured: false), OnboardingFix.Retry),
    ];

    private static readonly OnboardingFixVariant[] NetworkSelectionRequiredVariants =
    [
        new(new OnboardingVariantWhen(Configured: false), SaveSetupFix),
        new(new OnboardingVariantWhen(Stage: "setup", Configured: true), ConnectionsFix),
        new(new OnboardingVariantWhen(Stage: "pair", Configured: true, HasRecommendedTransport: true, RecommendedTransport: "tailscale"), OnboardingFix.RunFix("enable_tailscale")),
        new(new OnboardingVariantWhen(Stage: "pair", Configured: true, HasRecommendedTransport: true, RecommendedTransport: "tailcat"), OnboardingFix.RunFix("enable_tailcat")),
        new(new OnboardingVariantWhen(Stage: "pair", Configured: true, HasRecommendedTransport: true, RecommendedTransport: "lan"), OnboardingFix.RunFix("enable_lan")),
        new(new OnboardingVariantWhen(Stage: "pair", Configured: true, HasRecommendedTransport: true, RecommendedTransport: null), ConnectionsFix),
    ];

    private static readonly OnboardingFixVariant[] InvalidRequestVariants =
    [
        new(new OnboardingVariantWhen(Step: "config_store", Surface: "cli"), OnboardingFix.Retry),
        new(new OnboardingVariantWhen(Step: "network_any", Surface: "http"), OnboardingFix.Retry),
    ];

    public static IReadOnlyList<OnboardingCatalogEntry> Entries { get; } =
    [
        // 77 wire codes
        new("codex_not_found", false, ["assistant_codex"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "未找到 Codex。请打开安装说明，安装完成后重新检查。", Always(OnboardingFix.OpenUrl(UrlCodex))),
        new("codex_version_too_old", false, ["assistant_codex"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "Codex 版本过低。请按说明更新后重新检查。", Always(OnboardingFix.OpenUrl(UrlCodex))),
        new("codex_signed_out", false, ["assistant_codex"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "请按说明登录 Codex，完成后重新检查。", Always(OnboardingFix.OpenUrl(UrlCodex)), "signed_out_states", OnboardingFix.Retry, SignedOutRetryLabel),
        new("codex_upstream_unavailable", false, ["assistant_codex"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "无法连接 Codex 服务。请检查服务状态后重试。", Always(OnboardingFix.Retry)),
        new("codex_transport_invalid", false, ["assistant_codex"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "Codex 连接设置无效。请检查或清除所选连接。", Always(OnboardingFix.OpenSettings("assistants"))),
        new("claude_not_found", false, ["assistant_claude"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "未找到 Claude Code。请打开安装说明，安装完成后重新检查。", Always(OnboardingFix.OpenUrl(UrlClaude))),
        new("claude_version_too_old", false, ["assistant_claude"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "Claude Code 版本过低。请按说明更新后重新检查。", Always(OnboardingFix.OpenUrl(UrlClaude))),
        new("claude_signed_out", false, ["assistant_claude"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "请按说明登录 Claude Code，完成后重新检查。", Always(OnboardingFix.OpenUrl(UrlClaude)), "signed_out_states", OnboardingFix.Retry, SignedOutRetryLabel),
        new("claude_bridge_missing", false, ["assistant_claude"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "Claude Code 所需的连接组件不可用。请重新安装桌面端。", Always(DesktopUrlFix)),
        new("agy_not_found", false, ["assistant_agy"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "未找到 Antigravity。请打开安装说明，安装完成后重新检查。", Always(OnboardingFix.OpenUrl(UrlAgy))),
        new("agy_version_too_old", false, ["assistant_agy"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "Antigravity 版本过低。请按说明更新后重新检查。", Always(OnboardingFix.OpenUrl(UrlAgy))),
        new("agy_signed_out", false, ["assistant_agy"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "请按说明登录 Antigravity，完成后重新检查。", Always(OnboardingFix.OpenUrl(UrlAgy)), "signed_out_states", OnboardingFix.Retry, SignedOutRetryLabel),
        new("agy_adapter_missing", false, ["assistant_agy"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "Antigravity 所需的连接组件不可用。请重新安装桌面端。", Always(DesktopUrlFix)),
        new("runtime_path_invalid", false, ["assistant_codex", "assistant_claude", "assistant_agy"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "{title}：所选程序无法使用。请重新选择程序，或恢复自动检测。", RuntimePathInvalidVariants),
        new("runtime_incompatible", false, ["assistant_codex", "assistant_claude", "assistant_agy"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "{title}：检测到的版本不兼容。请按说明安装受支持的版本。", RuntimeIncompatibleVariants),
        new("runtime_probe_failed", false, ["assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "{title}：未能确认助手状态。请重新检查。", Always(OnboardingFix.Retry)),
        new("runtime_unsupported_platform", false, ["assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek"], AllPlatforms, SurfCheckCli, StatesOptional, StatesOptional, "{title}：当前平台尚不支持此助手，可以跳过。", Always(OnboardingFix.Skip)),
        new("assistant_disabled", false, ["assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "{title}：已检测到可用助手。需要使用时可启用。", AssistantDisabledVariants),
        new("deepseek_not_running", false, ["assistant_deepseek"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "未检测到正在运行的 DeepSeek Harness。请打开启动说明。", Always(OnboardingFix.OpenUrl(UrlHarness))),
        new("deepseek_auth_failed", false, ["assistant_deepseek"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "DeepSeek Harness 未能验证连接。请重新连接。", ConfigSplit("connect_deepseek")),
        new("deepseek_no_models", false, ["assistant_deepseek"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "DeepSeek Harness 暂无可用模型。请添加模型后重新检查。", Always(OnboardingFix.Retry)),
        new("no_enabled_assistant", false, ["assistant_any"], AllPlatforms, SurfCheckCliHttp, StatesAction, StatesAction, "请启用至少一个可用助手，然后重新配对。", Always(OnboardingFix.OpenUrl(UrlGuide))),
        new("workspace_confirmation_required", false, ["workspace_root"], AllPlatforms, SurfCheckCliHttp, StatesAction, StatesAction, "请先在电脑上确认要与手机共享的代码目录。", Always(WorkspacePickFix)),
        new("workspace_not_found", false, ["workspace_root"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "找不到所选代码目录。请重新选择。", Always(WorkspacePickFix)),
        new("workspace_not_directory", false, ["workspace_root"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "所选位置是文件。请选择代码目录。", Always(WorkspacePickFix)),
        new("workspace_unreadable", false, ["workspace_root"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "请选择可读取的代码目录。", Always(WorkspacePickFix)),
        new("config_missing", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesAction, StatesAction, "请先选择代码目录并保存配置。", Always(SaveSetupFix)),
        new("config_dir_unwritable", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "无法写入配置目录。请检查访问权限和可用空间后重试。", Always(OnboardingFix.Retry)),
        new("config_permissions_unsafe", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "配置文件的访问权限过宽。请在电脑上修复权限。", ConfigSplit("doctor_fix")),
        new("config_invalid", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "配置无法安全读取。请查看已保留的配置和恢复位置。", Always(HostRecoveryFix)),
        new("config_requires_newer_version", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "此配置需要较新的桌面端。请更新后重试。", Always(DesktopUrlFix)),
        new("config_concurrent_change", false, ["config_store"], AllPlatforms, SurfCli, StatesEmpty, StatesEmpty, "配置已在别处更改。请重新加载并确认选择。", Always(OnboardingFix.Retry)),
        new("config_commit_failed", false, ["config_store"], AllPlatforms, SurfCli, StatesEmpty, StatesEmpty, "本次配置未能保存。原配置已保留，请重试。", Always(OnboardingFix.Retry)),
        new("config_recovery_required", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "配置需要恢复。请在电脑上查看保留的文件。", Always(HostRecoveryFix)),
        new("token_rotation_requires_approval", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "此操作会更改电脑的配对身份。请查看保留的配置。", Always(HostRecoveryFix)),
        new("legacy_codex_residue", false, ["config_store"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "检测到旧版 Codex 配置。请在电脑上查看迁移说明。", Always(HostRecoveryFix)),
        new("tailscale_not_installed", false, ["network_tailscale"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "未检测到 Tailscale。需要此连接方式时请按说明安装。", Always(OnboardingFix.OpenUrl(UrlTailscale))),
        new("tailscale_not_connected", false, ["network_tailscale"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "Tailscale 尚未连接。请连接后重新检查。", Always(OnboardingFix.Retry)),
        new("tailscale_disabled", false, ["network_tailscale"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "Tailscale 已连接，可在配对设置中启用。", TransportEnable("enable_tailscale")),
        new("tailcat_disabled", false, ["network_tailcat"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "内置连接可用，可在配对设置中启用。", TransportEnable("enable_tailcat")),
        new("tailcat_unavailable", false, ["network_tailcat"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "内置连接组件不可用。请重新安装桌面端以修复组件。", Always(DesktopUrlFix)),
        new("tailcat_relay_unreachable", false, ["network_tailcat"], AllPlatforms, SurfCheckCliHttp, StatesError, StatesError, "暂时无法连接中继。请稍后重试。", Always(OnboardingFix.Retry)),
        new("tailcat_busy", false, ["network_tailcat"], AllPlatforms, SurfCliHttp, StatesEmpty, StatesEmpty, "内置连接正在处理其他操作。请稍后重试。", Always(OnboardingFix.Retry)),
        new("tailcat_settings_invalid", false, ["network_tailcat"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "中继设置无效或尚未生效。请检查连接设置。", Always(ConnectionsFix)),
        new("lan_unavailable", false, ["network_lan"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "未检测到可信局域网。请连接专用网络后重新检查。", Always(OnboardingFix.Retry)),
        new("lan_disabled", false, ["network_lan"], AllPlatforms, SurfCheckCli, StatesOptAction, StatesOptAction, "同一局域网连接可用，可在配对设置中启用。", TransportEnable("enable_lan")),
        new("lan_public_network_blocked", false, ["network_lan"], WinOnly, SurfCheckCli, StatesAction, StatesAction, "当前网络未确认为专用网络。请检查 Windows 网络配置。", Always(OnboardingFix.OpenSettings("windows_network_profile"))),
        new("lan_firewall_blocked", false, ["network_lan"], WinOnly, SurfCheckCli, StatesAction, StatesAction, "防火墙规则未允许专用网络连接。请在电脑上检查规则。", Always(OnboardingFix.OpenSettings("windows_firewall"))),
        new("no_direct_network", false, ["network_any"], AllPlatforms, SurfCheckCli, StatesAction, StatesAction, "没有可用的直连通道。可在配对时启用内置连接。", TransportEnable("enable_tailcat")),
        new("no_network_available", false, ["network_any"], AllPlatforms, SurfCheckCli, StatesAction, StatesAction, "暂无可用的连接方式。请检查网络后重试。", NoNetworkAvailableVariants),
        new("network_selection_required", false, ["network_any"], AllPlatforms, SurfCheckCli, StatesAction, StatesAction, "请选择要用于配对的连接方式。", NetworkSelectionRequiredVariants),
        new("service_start_timeout", false, ["service_daemon"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "等待后台服务就绪超时。请重新检查服务状态。", Always(OnboardingFix.Retry)),
        new("service_port_in_use", false, ["service_daemon"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "服务端口已被占用。请关闭占用端口的应用后重试。", Always(OnboardingFix.Retry)),
        new("service_requires_approval", false, ["service_daemon"], MacOnly, SurfNative, StatesAction, StatesAction, "需要在系统设置中允许后台服务运行。请在“登录项”中允许后重新检查，服务就绪后即可生成二维码。", Always(OnboardingFix.OpenSettings("login_items"))),
        new("service_version_mismatch", false, ["service_daemon"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "后台服务与客户端版本不一致。请在电脑上重新加载服务。", ConfigSplit("restart_service")),
        new("service_not_registered", false, ["service_daemon"], AllPlatforms, SurfCheckCli, StatesAction, StatesAction, "后台服务尚未注册。请在电脑上注册并启动服务。", ConfigSplit("register_service")),
        new("service_install_incomplete", false, ["service_daemon"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "后台服务组件不完整。请重新安装桌面端。", Always(DesktopUrlFix)),
        new("service_not_running", false, ["service_daemon"], AllPlatforms, SurfCheckCli, StatesAction, StatesAction, "后台服务尚未运行。请在电脑上启动服务。", ConfigSplit("restart_service")),
        new("service_start_failed", false, ["service_daemon"], AllPlatforms, SurfCheckCli, StatesError, StatesError, "后台服务启动失败。请检查并重试。", ConfigSplit("restart_service")),
        new("homebrew_service_active", false, ["service_owner_conflict"], MacOnly, SurfCheckCli, StatesOptional, StatesOptional, "Homebrew 正在管理后台服务。可继续使用，或确认后改由桌面端管理。", ConfigSplit("takeover_homebrew")),
        new("permission_login_item_disabled", false, ["permission_login_item"], MacOnly, SurfNative, StatesOptional, StatesOptional, "主应用尚未启用登录时启动。可按需在登录项中设置。", Always(OnboardingFix.OpenSettings("login_items"))),
        new("permission_folder_denied", false, ["permission_folder_access"], MacOnly, SurfCheckNative, StatesAction, StatesAction, "后台服务无法读取所选目录。请检查文件与文件夹权限。", Always(OnboardingFix.OpenSettings("files_and_folders"))),
        new("permission_local_network_denied", false, ["permission_local_network"], MacOnly, SurfNative, StatesAction, StatesAction, "请在系统设置中允许本地网络访问。", Always(OnboardingFix.OpenSettings("local_network"))),
        new("permission_photos_denied", false, ["permission_photos"], MacOnly, SurfNative, StatesOptional, StatesOptional, "照片访问尚未获准。需要使用时可在系统设置中允许。", Always(OnboardingFix.OpenSettings("photos"))),
        new("permission_full_disk_optional", false, ["permission_full_disk"], MacOnly, SurfNative, StatesOptional, StatesOptional, "如需访问更多文件，可在系统设置中允许完全磁盘访问。", Always(OnboardingFix.OpenSettings("full_disk_access"))),
        new("permission_unobserved", false, ["permission_login_item", "permission_folder_access", "permission_local_network", "permission_photos", "permission_full_disk"], MacAndWin, SurfCheckNative, StatesOptional, StatesOptional, "{title}：尚未获得此权限的状态。可以跳过此项。", Always(OnboardingFix.Skip)),
        new("pair_host_unreachable", false, ["service_daemon"], AllPlatforms, SurfCheckCliHttp, StatesError, StatesError, "无法连接电脑后台服务。请检查连接后重试。", Always(OnboardingFix.Retry)),
        new("pair_token_mismatch", false, ["service_daemon"], AllPlatforms, SurfCheckCliHttp, StatesError, StatesError, "电脑后台服务身份未同步。请在电脑端确认服务归属并重新加载配置后重试，无需删除手机上的已保存电脑。", ConfigSplit("restart_service")),
        new("pair_ticket_expired", false, ["network_any"], AllPlatforms, SurfCliHttp, StatesEmpty, StatesEmpty, "二维码已过期。请在电脑配对窗口点击“刷新二维码”后重扫，已有配对不受影响。", Always(OnboardingFix.Retry)),
        new("pair_ticket_invalid", false, ["network_any"], AllPlatforms, SurfCliHttp, StatesEmpty, StatesEmpty, "配对链接无效。请在电脑上刷新二维码后重扫。", Always(OnboardingFix.Retry)),
        new("pair_clock_skew", false, ["network_any"], AllPlatforms, SurfCliHttp, StatesEmpty, StatesEmpty, "设备时间不一致。请检查系统日期与时间后重新配对。", Always(OnboardingFix.OpenSettings("date_time"))),
        new("pair_local_forbidden", false, ["service_daemon"], AllPlatforms, SurfHttp, StatesEmpty, StatesEmpty, "此请求无法在本机认领。请使用手机扫描电脑上的二维码。", Always(OnboardingFix.Retry)),
        new("pair_managed_entitlement_required", false, ["network_tailcat"], AllPlatforms, SurfCliHttp, StatesEmpty, StatesEmpty, "此托管连接需要有效的订阅权益。请查看托管连接设置。", Always(OnboardingFix.OpenSettings("managed_connection"))),
        new("pair_managed_grant_conflict", false, ["network_tailcat"], AllPlatforms, SurfCliHttp, StatesEmpty, StatesEmpty, "托管连接授权未生效或已过期。请重新获取配对链接。", Always(OnboardingFix.Retry)),
        new("invalid_request", false, ["config_store", "network_any"], AllPlatforms, SurfCliHttp, StatesEmpty, StatesEmpty, "{title}：请求参数无效。请检查输入后重试。", InvalidRequestVariants),
        new("probe_timeout", false, ["*"], AllPlatforms, SurfCheckCliHttp, StatesError, StatesError, "{title}：检查超时。请重新检查此项。", Always(OnboardingFix.Retry)),
        new("internal_error", false, ["*"], AllPlatforms, SurfCheckCliHttp, StatesError, StatesError, "{title}：未能完成此项操作。请重试。", Always(OnboardingFix.Retry)),
        // 2 UI-local codes (never accepted on the wire)
        new("command_timeout", true, ["*"], AllPlatforms, SurfUiLocal, StatesEmpty, StatesEmpty, "{title}：命令等待超时。请重新检查当前步骤。", Always(OnboardingFix.Retry)),
        new("embedded_binary_missing", true, ["service_daemon"], AllPlatforms, SurfUiLocal, StatesEmpty, StatesEmpty, "缺少内置服务程序。请重新安装桌面端。", Always(DesktopUrlFix)),
    ];

    private static readonly Dictionary<string, OnboardingCatalogEntry> EntryIndex =
        Entries.ToDictionary(e => e.Code, StringComparer.Ordinal);

    public static IReadOnlySet<string> WireCodes { get; } =
        new HashSet<string>(Entries.Where(e => !e.IsUiLocal).Select(e => e.Code), StringComparer.Ordinal);

    public static IReadOnlySet<string> UiLocalCodes { get; } =
        new HashSet<string>(Entries.Where(e => e.IsUiLocal).Select(e => e.Code), StringComparer.Ordinal);

    public static bool IsAllowedUrl(string url) => AllowedUrlSet.Contains(url);
    public static bool IsAllowedSettingsTarget(string target) => SettingsTargetSet.Contains(target);
    public static bool IsAllowedPathTarget(string target) => PathTargetSet.Contains(target);
    public static bool IsAllowedRunFixAction(string action) => RunFixSpecs.ContainsKey(action);
    public static bool IsKnownCheckId(string id) => CheckIndex.ContainsKey(id);
    public static bool IsValidCheckState(string state) => ValidCheckStates.Contains(state);

    public static IReadOnlyList<string> ApplicableCheckIds(string platform) =>
        [.. Checks.Where(c => c.Platforms.Contains(platform, StringComparer.Ordinal)).Select(c => c.Id)];

    public static string LocalizedMessage(string code, string? step = null, string? title = null, string? detectedVersion = null)
    {
        if (!EntryIndex.TryGetValue(code, out var entry))
        {
            return SafeFallbackCopy;
        }
        string resolvedTitle;
        if (!string.IsNullOrWhiteSpace(title))
        {
            resolvedTitle = title.Trim();
        }
        else if (step is not null && CheckIndex.TryGetValue(step, out var spec))
        {
            resolvedTitle = spec.TitleZh;
        }
        else
        {
            resolvedTitle = "后台服务";
        }
        var text = entry.MessageZh.Replace("{title}", resolvedTitle, StringComparison.Ordinal);
        if (code.EndsWith("_signed_out", StringComparison.Ordinal) && !string.IsNullOrWhiteSpace(detectedVersion))
        {
            return $"已检测到版本 {detectedVersion.Trim()}。{text}";
        }
        return text;
    }

    public static OnboardingResolvedDiagnostic SynthesizeLocal(string code, string? step = null, string? title = null)
    {
        var resolvedStep = string.IsNullOrWhiteSpace(step) ? "service_daemon" : step;
        if (!EntryIndex.TryGetValue(code, out var entry) || !entry.IsUiLocal || entry.Variants.Count == 0)
        {
            return new OnboardingResolvedDiagnostic
            {
                Code = code,
                Step = resolvedStep,
                Message = SafeFallbackCopy,
                Trusted = false,
            };
        }
        return new OnboardingResolvedDiagnostic
        {
            Code = code,
            Step = resolvedStep,
            Message = LocalizedMessage(code, resolvedStep, title),
            AllowedFix = entry.Variants[0].Fix,
            SecondaryFix = entry.SecondaryFix,
            SecondaryLabel = entry.SecondaryLabelZh,
            Trusted = true,
        };
    }

    public static bool TryValidateDiagnostic(
        string code,
        string step,
        OnboardingFix fix,
        OnboardingValidationContext context,
        string? state,
        out OnboardingResolvedDiagnostic resolved,
        out string error)
    {
        resolved = new OnboardingResolvedDiagnostic
        {
            Code = code,
            Step = step,
            Message = SafeFallbackCopy,
            Trusted = false,
        };
        if (!EntryIndex.TryGetValue(code, out var entry))
        {
            error = $"unknown diagnostic '{code}'";
            return false;
        }
        if (!string.Equals(context.Surface, "ui_local", StringComparison.Ordinal) && entry.IsUiLocal)
        {
            error = $"ui_local code '{code}' rejected on wire surface '{context.Surface}'";
            return false;
        }
        if (string.Equals(context.Surface, "native", StringComparison.Ordinal)
            && !string.Equals(context.Platform, "macos", StringComparison.Ordinal))
        {
            error = "native overlay requires macOS";
            return false;
        }
        if (!CheckIndex.TryGetValue(step, out var checkSpec))
        {
            error = $"unknown step '{step}'";
            return false;
        }
        if (!entry.Surfaces.Contains(context.Surface, StringComparer.Ordinal)
            || !entry.Platforms.Contains(context.Platform, StringComparer.Ordinal)
            || !checkSpec.Platforms.Contains(context.Platform, StringComparer.Ordinal))
        {
            error = $"{code} unavailable on {context.Surface}/{context.Platform}/{step}";
            return false;
        }
        var allowsAny = entry.Steps.Count == 1 && string.Equals(entry.Steps[0], "*", StringComparison.Ordinal);
        if (!allowsAny && !entry.Steps.Contains(step, StringComparer.Ordinal))
        {
            error = $"{code} cannot use step {step}";
            return false;
        }
        if (!string.IsNullOrEmpty(state))
        {
            var allowedStates = string.Equals(context.Stage, "pair", StringComparison.Ordinal)
                ? entry.PairStates
                : entry.SetupStates;
            if (!allowedStates.Contains(state, StringComparer.Ordinal))
            {
                error = $"{code} cannot use state {state} in {context.Stage}";
                return false;
            }
        }
        OnboardingFixVariant? matched = null;
        foreach (var variant in entry.Variants)
        {
            if (VariantMatches(variant.When, step, context))
            {
                if (matched is not null)
                {
                    error = $"ambiguous variants for {code}";
                    return false;
                }
                matched = variant;
            }
        }
        if (matched is null || matched.Fix != fix)
        {
            error = $"mismatched fix for {code} at {step}";
            return false;
        }
        if (string.Equals(fix.Kind, "run_fix", StringComparison.Ordinal))
        {
            if (fix.Action is null || !RunFixSpecs.TryGetValue(fix.Action, out var runFixSpec))
            {
                error = "unknown run_fix action";
                return false;
            }
            if (runFixSpec.RequiresConfig && context.Configured != true)
            {
                error = $"action {fix.Action} requires configuration";
                return false;
            }
            if (runFixSpec.RequiresCapability is not null
                && !string.Equals(context.VerifiedCapability, runFixSpec.RequiresCapability, StringComparison.Ordinal))
            {
                error = $"action {fix.Action} requires verified capability {runFixSpec.RequiresCapability}";
                return false;
            }
            if (TransportEnableActions.Contains(fix.Action)
                && !string.Equals(context.Stage, "pair", StringComparison.Ordinal))
            {
                error = $"transport enable {fix.Action} outside pair stage";
                return false;
            }
        }
        resolved = new OnboardingResolvedDiagnostic
        {
            Code = code,
            Step = step,
            Message = LocalizedMessage(code, step, checkSpec.TitleZh),
            AllowedFix = fix,
            SecondaryFix = entry.SecondaryFix,
            SecondaryLabel = entry.SecondaryLabelZh,
            Trusted = true,
        };
        error = "";
        return true;
    }

    public static bool TryDecodeCheck(string json, [NotNullWhen(true)] out OnboardingCheck? check, out string error)
    {
        check = null;
        try
        {
            using var document = JsonDocument.Parse(json);
            return TryParseCheckElement(document.RootElement, out check, out error);
        }
        catch (JsonException ex)
        {
            error = ex.Message;
            return false;
        }
    }

    public static bool TryValidateCheck(
        OnboardingCheck check,
        OnboardingValidationContext context,
        out OnboardingResolvedDiagnostic resolved,
        out string error)
    {
        resolved = new OnboardingResolvedDiagnostic { Step = check.Id, Message = SafeFallbackCopy, Trusted = false };
        if (!CheckIndex.TryGetValue(check.Id, out var spec))
        {
            error = $"unknown check id '{check.Id}'";
            return false;
        }
        if (!string.Equals(check.Group, spec.Group, StringComparison.Ordinal)
            || !spec.Platforms.Contains(context.Platform, StringComparison.Ordinal))
        {
            error = $"{check.Id} group/platform mismatch";
            return false;
        }
        if (!ValidCheckStates.Contains(check.State))
        {
            error = $"unknown check state '{check.State}'";
            return false;
        }
        if (string.IsNullOrWhiteSpace(check.Title) || string.IsNullOrWhiteSpace(check.Detail))
        {
            error = $"{check.Id} missing title or detail";
            return false;
        }
        if (check.Source is not null && !ValidSources.Contains(check.Source))
        {
            error = $"invalid candidate source '{check.Source}'";
            return false;
        }
        if (!string.Equals(check.Id, "config_store", StringComparison.Ordinal)
            && (check.HasConfigPathKey || check.HasRecoveryPathKey))
        {
            error = $"unexpected path fields on {check.Id}";
            return false;
        }
        var isOkOrChecking = string.Equals(check.State, "ok", StringComparison.Ordinal)
            || string.Equals(check.State, "checking", StringComparison.Ordinal);
        if (isOkOrChecking)
        {
            if (check.HasCodeKey || check.HasFixKey || check.Blocking)
            {
                error = $"{check.Id} state {check.State} cannot carry code/fix or block";
                return false;
            }
        }
        else if (!check.HasCodeKey || !check.HasFixKey || string.IsNullOrEmpty(check.Code) || check.Fix is null)
        {
            error = $"{check.Id} state {check.State} requires code and fix";
            return false;
        }
        if (IndividualCheckIds.Contains(check.Id))
        {
            if (check.Enabled is null || !check.HasAvailableKey || check.Blocking)
            {
                error = $"individual check {check.Id} missing enabled/available or blocking";
                return false;
            }
        }
        if (CliAssistantIds.Contains(check.Id))
        {
            if (!check.HasCandidatesKey || check.Candidates is null)
            {
                error = $"cli assistant {check.Id} missing candidates";
                return false;
            }
            var selected = 0;
            foreach (var candidate in check.Candidates)
            {
                if (string.IsNullOrWhiteSpace(candidate.Path) || !ValidOutcomes.Contains(candidate.Outcome))
                {
                    error = $"invalid candidate on {check.Id}";
                    return false;
                }
                if (string.Equals(candidate.Outcome, "selected", StringComparison.Ordinal))
                {
                    selected++;
                }
            }
            var needsSelected = string.Equals(check.State, "ok", StringComparison.Ordinal)
                || (check.Code is not null && check.Code.EndsWith("_signed_out", StringComparison.Ordinal))
                || string.Equals(check.Code, "assistant_disabled", StringComparison.Ordinal);
            if (selected > 1 || (needsSelected && selected != 1))
            {
                error = $"invalid selected candidate count {selected} for {check.Id}";
                return false;
            }
        }
        if (string.IsNullOrEmpty(check.Code) || check.Fix is null)
        {
            resolved = new OnboardingResolvedDiagnostic
            {
                Step = check.Id,
                Message = check.Detail,
                ConfigPath = check.ConfigPath,
                RecoveryPath = check.RecoveryPath,
                Trusted = true,
            };
            error = "";
            return true;
        }
        var isPair = string.Equals(context.Stage, "pair", StringComparison.Ordinal);
        if (string.Equals(check.Id, "config_store", StringComparison.Ordinal)
            || string.Equals(check.Id, "workspace_root", StringComparison.Ordinal))
        {
            if (check.Blocking != (isPair || string.Equals(check.State, "error", StringComparison.Ordinal)))
            {
                error = $"inconsistent workspace blocker on {check.Id}";
                return false;
            }
        }
        else if (string.Equals(check.Id, "assistant_any", StringComparison.Ordinal)
            || string.Equals(check.Id, "network_any", StringComparison.Ordinal)
            || string.Equals(check.Id, "service_daemon", StringComparison.Ordinal))
        {
            if (check.Blocking != isPair)
            {
                error = $"inconsistent pair blocker on {check.Id}";
                return false;
            }
        }
        if (!TryValidateDiagnostic(check.Code, check.Id, check.Fix, context, check.State, out var diag, out error))
        {
            return false;
        }
        if (check.Code.EndsWith("_signed_out", StringComparison.Ordinal))
        {
            if (isPair || context.ExplicitlyEnabled is not null)
            {
                var enabled = string.Equals(context.Stage, "setup", StringComparison.Ordinal) && context.ExplicitlyEnabled is not null
                    ? context.ExplicitlyEnabled.Value
                    : check.Enabled == true;
                if (string.Equals(check.State, "action_needed", StringComparison.Ordinal) != enabled)
                {
                    error = $"incorrect signed_out state for {check.Id}";
                    return false;
                }
            }
        }
        resolved = diag with
        {
            Message = LocalizedMessage(check.Code, check.Id, check.Title, check.SelectedOrDetectedVersion),
            ConfigPath = check.ConfigPath,
            RecoveryPath = check.RecoveryPath,
        };
        return true;
    }

    public static bool TryDecodeAndValidateReport(
        string json,
        string platform,
        bool nativeOverlay,
        string? verifiedCapability,
        [NotNullWhen(true)] out OnboardingPreflightReport? report,
        out string error)
    {
        report = null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                error = "report must be a JSON object";
                return false;
            }
            if (!TryGetRequiredString(root, "schema", out var schema)
                || !string.Equals(schema, OnboardingSchema.PreflightV1, StringComparison.Ordinal))
            {
                error = "unsupported preflight schema";
                return false;
            }
            if (!TryGetRequiredBool(root, "ok", out var ok)
                || !TryGetRequiredString(root, "stage", out var stage)
                || !TryGetRequiredBool(root, "configured", out var configured)
                || !TryGetRequiredBool(root, "workspace_confirmed", out var workspaceConfirmed)
                || !TryGetRequiredString(root, "config_path", out var configPath)
                || !TryGetRequiredString(root, "scan_root", out var scanRoot)
                || !TryGetRequiredString(root, "browse_root", out var browseRoot)
                || !TryGetRequiredBool(root, "scan_root_exists", out var scanRootExists)
                || !TryGetRequiredString(root, "recommended_next", out var recommendedNext)
                || !root.TryGetProperty("recommended_transport", out var recTransportElement)
                || !root.TryGetProperty("checks", out var checksElement)
                || checksElement.ValueKind != JsonValueKind.Array)
            {
                error = "report missing required fields";
                return false;
            }
            if (!string.Equals(stage, "setup", StringComparison.Ordinal)
                && !string.Equals(stage, "pair", StringComparison.Ordinal))
            {
                error = $"invalid stage '{stage}'";
                return false;
            }
            string? recommendedTransport = null;
            if (recTransportElement.ValueKind == JsonValueKind.String)
            {
                recommendedTransport = recTransportElement.GetString();
                if (recommendedTransport is null || !ValidTransports.Contains(recommendedTransport))
                {
                    error = "invalid recommended_transport";
                    return false;
                }
            }
            else if (recTransportElement.ValueKind != JsonValueKind.Null)
            {
                error = "recommended_transport must be string or null";
                return false;
            }
            if (!configured && workspaceConfirmed)
            {
                error = "unconfigured report cannot have workspace_confirmed=true";
                return false;
            }
            if (ok && string.Equals(stage, "pair", StringComparison.Ordinal)
                && (!configured || !workspaceConfirmed || !scanRootExists))
            {
                error = "ready pair report requires configured, confirmed, existing workspace";
                return false;
            }

            var applicable = ApplicableCheckIds(platform);
            var checks = new List<OnboardingCheck>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in checksElement.EnumerateArray())
            {
                if (!TryParseCheckElement(item, out var row, out error))
                {
                    return false;
                }
                if (!seen.Add(row.Id))
                {
                    error = $"duplicate check row {row.Id}";
                    return false;
                }
                checks.Add(row);
            }
            if (checks.Count != applicable.Count)
            {
                error = $"expected {applicable.Count} checks for {platform}, got {checks.Count}";
                return false;
            }

            string? firstBlocker = null;
            var eligibleByGroup = new Dictionary<string, bool>(StringComparer.Ordinal);
            string? expectedRecommended = null;

            for (var i = 0; i < checks.Count; i++)
            {
                var row = checks[i];
                if (!string.Equals(row.Id, applicable[i], StringComparison.Ordinal))
                {
                    error = $"expected {applicable[i]} at index {i}, got {row.Id}";
                    return false;
                }
                if (string.Equals(row.State, "checking", StringComparison.Ordinal))
                {
                    error = $"unfinished check {row.Id}";
                    return false;
                }
                var isNativeRow = nativeOverlay
                    && (row.Id.StartsWith("permission_", StringComparison.Ordinal)
                        || (string.Equals(row.Id, "service_daemon", StringComparison.Ordinal)
                            && string.Equals(row.Code, "service_requires_approval", StringComparison.Ordinal)));
                var ctx = new OnboardingValidationContext
                {
                    Surface = isNativeRow ? "native" : "check",
                    Platform = platform,
                    Stage = stage,
                    Configured = configured,
                    HasRecommendedTransport = true,
                    RecommendedTransport = recommendedTransport,
                    VerifiedCapability = verifiedCapability,
                };
                if (!TryValidateCheck(row, ctx, out _, out error))
                {
                    return false;
                }
                if (row.Blocking)
                {
                    if (string.Equals(stage, "setup", StringComparison.Ordinal)
                        && !string.Equals(row.Group, "workspace", StringComparison.Ordinal))
                    {
                        error = $"unexpected setup blocker {row.Id}";
                        return false;
                    }
                    firstBlocker ??= row.Id;
                }
                if (row.Enabled is not null)
                {
                    var ready = row.Enabled == true && row.Available == true;
                    if (string.Equals(row.State, "ok", StringComparison.Ordinal) != ready)
                    {
                        error = $"{row.Id} intent/availability mismatch";
                        return false;
                    }
                    eligibleByGroup[row.Group] = eligibleByGroup.GetValueOrDefault(row.Group) || ready;
                    if (string.Equals(row.Group, "network", StringComparison.Ordinal)
                        && expectedRecommended is null && row.Available == true)
                    {
                        expectedRecommended = row.Id["network_".Length..];
                    }
                }
                if (string.Equals(row.Id, "assistant_any", StringComparison.Ordinal)
                    || string.Equals(row.Id, "network_any", StringComparison.Ordinal))
                {
                    var groupEligible = eligibleByGroup.GetValueOrDefault(row.Group);
                    if (string.Equals(row.State, "ok", StringComparison.Ordinal) != groupEligible
                        || row.Blocking != (string.Equals(stage, "pair", StringComparison.Ordinal) && !groupEligible))
                    {
                        error = $"{row.Id} eligibility mismatch";
                        return false;
                    }
                }
                if (string.Equals(stage, "pair", StringComparison.Ordinal)
                    && string.Equals(row.Id, "service_daemon", StringComparison.Ordinal)
                    && row.Blocking != !string.Equals(row.State, "ok", StringComparison.Ordinal))
                {
                    error = "daemon readiness mismatch";
                    return false;
                }
            }
            if (!string.Equals(recommendedTransport, expectedRecommended, StringComparison.Ordinal))
            {
                error = "unexpected recommended_transport";
                return false;
            }
            if (ok != (firstBlocker is null))
            {
                error = "report ok inconsistent with blockers";
                return false;
            }
            var expectedNext = firstBlocker
                ?? (string.Equals(stage, "setup", StringComparison.Ordinal) && !configured ? "config_store" : "network_any");
            if (!string.Equals(recommendedNext, expectedNext, StringComparison.Ordinal))
            {
                error = $"expected recommended_next {expectedNext}, got {recommendedNext}";
                return false;
            }

            report = new OnboardingPreflightReport
            {
                Schema = schema,
                Ok = ok,
                Stage = stage,
                Configured = configured,
                WorkspaceConfirmed = workspaceConfirmed,
                ConfigPath = configPath,
                ScanRoot = scanRoot,
                BrowseRoot = browseRoot,
                ScanRootExists = scanRootExists,
                RecommendedNext = recommendedNext,
                RecommendedTransport = recommendedTransport,
                Checks = checks,
            };
            error = "";
            return true;
        }
        catch (JsonException ex)
        {
            error = ex.Message;
            return false;
        }
    }

    public static bool TryDecodeErrorEnvelope(
        string json,
        OnboardingValidationContext context,
        out OnboardingResolvedDiagnostic resolved,
        out string error)
    {
        resolved = new OnboardingResolvedDiagnostic { Message = SafeFallbackCopy, Trusted = false };
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                error = "envelope must be a JSON object";
                return false;
            }
            var isHttp = string.Equals(context.Surface, "http", StringComparison.Ordinal);
            if (isHttp)
            {
                foreach (var prop in root.EnumerateObject())
                {
                    if (HttpForbiddenFields.Contains(prop.Name))
                    {
                        error = $"forbidden public field '{prop.Name}'";
                        return false;
                    }
                }
            }
            if (!TryGetRequiredBool(root, "ok", out var ok) || ok
                || !root.TryGetProperty("error", out var errElement)
                || errElement.ValueKind != JsonValueKind.Object)
            {
                error = "error envelope requires ok=false and error object";
                return false;
            }
            if (isHttp)
            {
                foreach (var prop in errElement.EnumerateObject())
                {
                    if (HttpForbiddenFields.Contains(prop.Name))
                    {
                        error = $"forbidden public error field '{prop.Name}'";
                        return false;
                    }
                }
            }
            if (!TryGetRequiredString(errElement, "code", out var code)
                || !TryGetRequiredString(errElement, "step", out var step)
                || !TryGetRequiredString(errElement, "message", out _)
                || !errElement.TryGetProperty("fix", out var fixElement))
            {
                error = "error envelope missing required fields";
                return false;
            }
            var fix = fixElement.Deserialize<OnboardingFix>(AgentClient.JsonOptions);
            if (fix is null)
            {
                error = "error envelope fix is null";
                return false;
            }
            var configPath = TryGetOptionalString(errElement, "config_path", out var hasCfg);
            var recoveryPath = TryGetOptionalString(errElement, "recovery_path", out var hasRec);
            if (!isHttp && (hasCfg || hasRec)
                && !(string.Equals(fix.Kind, "open_settings", StringComparison.Ordinal)
                    && string.Equals(fix.Target, "host_recovery", StringComparison.Ordinal)))
            {
                error = "recovery paths only allowed with host_recovery fix";
                return false;
            }
            if (!TryValidateDiagnostic(code, step, fix, context, null, out var validated, out error))
            {
                return false;
            }
            resolved = validated with { ConfigPath = configPath, RecoveryPath = recoveryPath };
            return true;
        }
        catch (JsonException ex)
        {
            error = ex.Message;
            return false;
        }
    }

    public static bool LooksLikeErrorEnvelopeJson(string stdout)
    {
        if (string.IsNullOrWhiteSpace(stdout))
        {
            return false;
        }
        try
        {
            using var document = JsonDocument.Parse(stdout);
            var root = document.RootElement;
            return root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("ok", out var okProp)
                && okProp.ValueKind == JsonValueKind.False
                && root.TryGetProperty("error", out var errProp)
                && errProp.ValueKind == JsonValueKind.Object;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public static bool IsRecognizedLegacyHostStderr(string stderr)
    {
        if (string.IsNullOrWhiteSpace(stderr))
        {
            return false;
        }
        return (stderr.Contains("unknown command", StringComparison.OrdinalIgnoreCase)
                && stderr.Contains("preflight", StringComparison.OrdinalIgnoreCase))
            || (stderr.Contains("未知命令", StringComparison.Ordinal)
                && stderr.Contains("preflight", StringComparison.OrdinalIgnoreCase))
            || stderr.Contains("flag provided but not defined: -no-pair", StringComparison.OrdinalIgnoreCase)
            || stderr.Contains("unknown flag: --no-pair", StringComparison.OrdinalIgnoreCase);
    }

    public static OnboardingResolvedDiagnostic? ResolveCliError(
        string stdout,
        string stderr,
        OnboardingValidationContext context)
    {
        if (LooksLikeErrorEnvelopeJson(stdout))
        {
            if (TryDecodeErrorEnvelope(stdout, context, out var resolved, out _))
            {
                return resolved;
            }
            return new OnboardingResolvedDiagnostic
            {
                Message = SafeFallbackCopy,
                AllowedFix = null,
                Trusted = false,
            };
        }
        if (IsRecognizedLegacyHostStderr(stderr))
        {
            return new OnboardingResolvedDiagnostic
            {
                Step = "service_daemon",
                Message = LegacyHostCopy,
                AllowedFix = DesktopUrlFix,
                Trusted = true,
                LegacyHost = true,
            };
        }
        return null;
    }

    public static bool TryDecodeSetupReceipt(
        string json,
        [NotNullWhen(true)] out SetupReceipt? receipt,
        out string error)
    {
        receipt = null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                error = "setup receipt must be an object";
                return false;
            }
            var hasConfigured = root.TryGetProperty("configured", out var cfgProp);
            var hasCreated = root.TryGetProperty("created", out var createdProp);
            var pairUrl = TryGetOptionalString(root, "pair_url", out var hasPairUrl);
            var endpoint = TryGetOptionalString(root, "endpoint", out _);
            var pairExpires = TryGetOptionalString(root, "pair_expires_at", out var hasPairExpires);
            var network = TryGetOptionalString(root, "network", out _);
            var dns = TryGetOptionalString(root, "tailscale_dns_name", out _);
            var device = TryGetOptionalString(root, "tailscale_device_name", out _);
            var warnings = ReadOptionalStringArray(root, "warnings");

            if (!hasConfigured && !hasCreated && !string.IsNullOrWhiteSpace(pairUrl))
            {
                if (!pairUrl.StartsWith("mimiremote://pair?", StringComparison.Ordinal)
                    || string.IsNullOrWhiteSpace(endpoint)
                    || string.IsNullOrWhiteSpace(pairExpires))
                {
                    error = "incomplete legacy setup ticket";
                    return false;
                }
                receipt = new SetupReceipt
                {
                    Ok = true,
                    Configured = true,
                    Created = true,
                    Endpoint = endpoint,
                    PairUrl = pairUrl,
                    PairExpiresAt = pairExpires,
                    Network = network,
                    TailscaleDnsName = dns,
                    TailscaleDeviceName = device,
                    Warnings = warnings,
                    IsLegacy = true,
                };
                error = "";
                return true;
            }

            if (!TryGetRequiredBool(root, "ok", out var ok) || !ok
                || !hasConfigured || cfgProp.ValueKind != JsonValueKind.True
                || !hasCreated || (createdProp.ValueKind != JsonValueKind.True && createdProp.ValueKind != JsonValueKind.False)
                || !TryGetRequiredString(root, "config_path", out var configPath)
                || !TryGetRequiredString(root, "scan_root", out var scanRoot)
                || !TryGetRequiredString(root, "browse_root", out var browseRoot))
            {
                error = "setup receipt missing required v1 fields";
                return false;
            }
            bool? pairingDeferred = null;
            if (root.TryGetProperty("pairing_deferred", out var defProp))
            {
                if (defProp.ValueKind != JsonValueKind.True && defProp.ValueKind != JsonValueKind.False)
                {
                    error = "pairing_deferred must be boolean";
                    return false;
                }
                pairingDeferred = defProp.GetBoolean();
            }
            if (pairingDeferred == true && (hasPairUrl || hasPairExpires))
            {
                error = "deferred setup receipt cannot include ticket fields";
                return false;
            }
            if (hasPairUrl)
            {
                if (pairUrl is null
                    || !pairUrl.StartsWith("mimiremote://pair?", StringComparison.Ordinal)
                    || string.IsNullOrWhiteSpace(endpoint)
                    || string.IsNullOrWhiteSpace(pairExpires)
                    || !OnboardingProgressAccumulator.IsValidUtcRfc3339(pairExpires))
                {
                    error = "setup receipt ticket fields incomplete";
                    return false;
                }
            }
            if (network is not null && !ValidTransports.Contains(network))
            {
                error = $"invalid setup network '{network}'";
                return false;
            }
            receipt = new SetupReceipt
            {
                Ok = true,
                Configured = true,
                Created = createdProp.GetBoolean(),
                ConfigPath = configPath,
                ScanRoot = scanRoot,
                BrowseRoot = browseRoot,
                PairingDeferred = pairingDeferred,
                Endpoint = endpoint,
                PairUrl = pairUrl,
                PairExpiresAt = pairExpires,
                Network = network,
                TailscaleDnsName = dns,
                TailscaleDeviceName = device,
                Warnings = warnings,
            };
            error = "";
            return true;
        }
        catch (JsonException ex)
        {
            error = ex.Message;
            return false;
        }
    }

    public static bool TryDecodeUpReadinessReceipt(
        string json,
        [NotNullWhen(true)] out UpReadinessReceipt? receipt,
        out string error)
    {
        receipt = null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                error = "up receipt must be an object";
                return false;
            }
            if (root.TryGetProperty("ok", out var okProp) && okProp.ValueKind != JsonValueKind.True)
            {
                error = "up receipt ok is not true";
                return false;
            }
            if (!TryGetRequiredBool(root, "service_ok", out var serviceOk) || !serviceOk
                || !TryGetRequiredString(root, "version", out var version))
            {
                error = "up receipt does not confirm authenticated readiness";
                return false;
            }
            receipt = new UpReadinessReceipt
            {
                Ok = true,
                ServiceOk = true,
                Version = version,
                Warnings = ReadOptionalStringArray(root, "warnings"),
            };
            error = "";
            return true;
        }
        catch (JsonException ex)
        {
            error = ex.Message;
            return false;
        }
    }

    public static bool TryDecodePairingTicketReceipt(
        string json,
        bool requireNetwork,
        [NotNullWhen(true)] out PairingTicketReceipt? receipt,
        out string error)
    {
        receipt = null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                error = "pairing receipt must be an object";
                return false;
            }
            if (root.TryGetProperty("ok", out var okProp) && okProp.ValueKind != JsonValueKind.True)
            {
                error = "pairing receipt ok is not true";
                return false;
            }
            if (!TryGetRequiredString(root, "endpoint", out var endpoint)
                || !TryGetRequiredString(root, "pair_url", out var pairUrl)
                || !pairUrl.StartsWith("mimiremote://pair?", StringComparison.Ordinal)
                || !TryGetRequiredString(root, "pair_expires_at", out var expires)
                || !OnboardingProgressAccumulator.IsValidUtcRfc3339(expires))
            {
                error = "pairing receipt missing required ticket fields";
                return false;
            }
            var network = TryGetOptionalString(root, "network", out _);
            if (network is not null && !ValidTransports.Contains(network))
            {
                error = $"invalid transport '{network}'";
                return false;
            }
            if (requireNetwork && string.IsNullOrEmpty(network))
            {
                error = "pairing receipt missing network";
                return false;
            }
            receipt = new PairingTicketReceipt
            {
                Ok = true,
                Endpoint = endpoint,
                PairUrl = pairUrl,
                PairExpiresAt = expires,
                Network = network,
                TailscaleDnsName = TryGetOptionalString(root, "tailscale_dns_name", out _),
                TailscaleDeviceName = TryGetOptionalString(root, "tailscale_device_name", out _),
                Warnings = ReadOptionalStringArray(root, "warnings"),
            };
            error = "";
            return true;
        }
        catch (JsonException ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static bool VariantMatches(OnboardingVariantWhen when, string step, OnboardingValidationContext context)
    {
        if (when.Step is not null && !string.Equals(when.Step, step, StringComparison.Ordinal))
        {
            return false;
        }
        if (when.Stage is not null && !string.Equals(when.Stage, context.Stage, StringComparison.Ordinal))
        {
            return false;
        }
        if (when.Surface is not null && !string.Equals(when.Surface, context.Surface, StringComparison.Ordinal))
        {
            return false;
        }
        if (when.Configured is not null && context.Configured != when.Configured)
        {
            return false;
        }
        if (when.HasRecommendedTransport)
        {
            if (!context.HasRecommendedTransport
                || !string.Equals(context.RecommendedTransport, when.RecommendedTransport, StringComparison.Ordinal))
            {
                return false;
            }
        }
        return true;
    }

    private static bool TryParseCheckElement(
        JsonElement element,
        [NotNullWhen(true)] out OnboardingCheck? check,
        out string error)
    {
        check = null;
        if (element.ValueKind != JsonValueKind.Object)
        {
            error = "check must be an object";
            return false;
        }
        if (!TryGetRequiredString(element, "id", out var id)
            || !TryGetRequiredString(element, "group", out var group)
            || !TryGetRequiredString(element, "state", out var state)
            || !TryGetRequiredString(element, "title", out var title)
            || !TryGetRequiredString(element, "detail", out var detail)
            || !TryGetRequiredBool(element, "blocking", out var blocking))
        {
            error = "check missing required fields";
            return false;
        }

        var code = TryGetOptionalString(element, "code", out var hasCode);
        OnboardingFix? fix = null;
        var hasFix = element.TryGetProperty("fix", out var fixElement);
        if (hasFix)
        {
            fix = fixElement.Deserialize<OnboardingFix>(AgentClient.JsonOptions);
            if (fix is null)
            {
                error = "check fix cannot be null";
                return false;
            }
        }

        bool? enabled = null;
        if (element.TryGetProperty("enabled", out var enabledElement))
        {
            if (enabledElement.ValueKind != JsonValueKind.True && enabledElement.ValueKind != JsonValueKind.False)
            {
                error = "enabled must be boolean";
                return false;
            }
            enabled = enabledElement.GetBoolean();
        }

        bool? available = null;
        var hasAvailable = element.TryGetProperty("available", out var availableElement);
        if (hasAvailable)
        {
            if (availableElement.ValueKind == JsonValueKind.True || availableElement.ValueKind == JsonValueKind.False)
            {
                available = availableElement.GetBoolean();
            }
            else if (availableElement.ValueKind != JsonValueKind.Null)
            {
                error = "available must be boolean or null";
                return false;
            }
        }

        List<OnboardingCandidate>? candidates = null;
        var hasCandidates = element.TryGetProperty("candidates", out var candidatesElement);
        if (hasCandidates)
        {
            if (candidatesElement.ValueKind != JsonValueKind.Array)
            {
                error = "candidates must be an array";
                return false;
            }
            candidates = [];
            foreach (var item in candidatesElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object
                    || !TryGetRequiredString(item, "path", out var path)
                    || !TryGetRequiredString(item, "outcome", out var outcome))
                {
                    error = "invalid candidate entry";
                    return false;
                }
                candidates.Add(new OnboardingCandidate
                {
                    Path = path,
                    Outcome = outcome,
                    Version = TryGetOptionalString(item, "version", out _),
                });
            }
        }

        check = new OnboardingCheck
        {
            Id = id,
            Group = group,
            State = state,
            Title = title,
            Detail = detail,
            Blocking = blocking,
            Code = code,
            Fix = fix,
            ConfigPath = TryGetOptionalString(element, "config_path", out var hasConfigPath),
            RecoveryPath = TryGetOptionalString(element, "recovery_path", out var hasRecoveryPath),
            Enabled = enabled,
            Available = available,
            Candidates = candidates,
            Source = TryGetOptionalString(element, "source", out _),
            DetectedVersion = TryGetOptionalString(element, "detected_version", out _),
            MinVersion = TryGetOptionalString(element, "min_version", out _),
            HasAvailableKey = hasAvailable,
            HasCandidatesKey = hasCandidates,
            HasCodeKey = hasCode,
            HasFixKey = hasFix,
            HasConfigPathKey = hasConfigPath,
            HasRecoveryPathKey = hasRecoveryPath,
        };
        error = "";
        return true;
    }

    private static bool TryGetRequiredString(JsonElement obj, string name, out string value)
    {
        if (obj.TryGetProperty(name, out var prop) && prop.ValueKind == JsonValueKind.String)
        {
            var raw = prop.GetString();
            if (!string.IsNullOrEmpty(raw))
            {
                value = raw;
                return true;
            }
        }
        value = "";
        return false;
    }

    private static bool TryGetRequiredBool(JsonElement obj, string name, out bool value)
    {
        if (obj.TryGetProperty(name, out var prop)
            && (prop.ValueKind == JsonValueKind.True || prop.ValueKind == JsonValueKind.False))
        {
            value = prop.GetBoolean();
            return true;
        }
        value = false;
        return false;
    }

    private static string? TryGetOptionalString(JsonElement obj, string name, out bool present)
    {
        present = obj.TryGetProperty(name, out var prop);
        return present && prop.ValueKind == JsonValueKind.String ? prop.GetString() : null;
    }

    private static string[] ReadOptionalStringArray(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var prop) || prop.ValueKind != JsonValueKind.Array)
        {
            return [];
        }
        var items = new List<string>();
        foreach (var entry in prop.EnumerateArray())
        {
            if (entry.ValueKind == JsonValueKind.String && entry.GetString() is { Length: > 0 } text)
            {
                items.Add(text);
            }
        }
        return [.. items];
    }
}

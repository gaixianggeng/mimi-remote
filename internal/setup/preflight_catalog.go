package setup

import "strings"

type OnboardingFix struct {
	Kind   string `json:"kind"`
	Action string `json:"action,omitempty"`
	Target string `json:"target,omitempty"`
	URL    string `json:"url,omitempty"`
}
type OnboardingError struct {
	Code    string        `json:"code"`
	Step    string        `json:"step"`
	Message string        `json:"message"`
	Fix     OnboardingFix `json:"fix"`
}

// Project the catalog action against current intent. Clients receive only the
// resulting literal action, never a shell command or an executable path.
func OnboardingDiagnostic(code, step, stage string, configured bool, recommended string) OnboardingError {
	d, ok := preflightDiagnostics[code]
	if !ok {
		code = "internal_error"
		d = preflightDiagnostics[code]
	}
	kind, value := d.kind, d.value
	name := strings.TrimPrefix(step, "assistant_")
	switch code {
	case "runtime_path_invalid":
		value = name + "_bin"
	case "runtime_incompatible":
		value = preflightDiagnostics[name+"_not_found"].value
	case "assistant_disabled":
		value = "enable_" + name
		if name == "deepseek" {
			value = "connect_deepseek"
		}
	case "network_selection_required":
		switch recommended {
		case "tailscale", "tailcat", "lan":
			kind, value = "run_fix", "enable_"+recommended
		default:
			kind, value = "open_settings", "connections"
		}
	}
	draftAction := value == "enable_codex" || value == "enable_claude" || value == "enable_agy" || value == "save_setup"
	needsSavedConfig := kind == "run_fix" && !draftAction
	needsNetworkSelection := code == "network_selection_required" || (stage == "setup" && code == "no_network_available")
	if !configured && (needsSavedConfig || needsNetworkSelection) {
		kind, value = "run_fix", "save_setup"
	} else if stage == "setup" && (value == "enable_lan" || value == "enable_tailscale" || value == "enable_tailcat") {
		kind, value = "open_settings", "connections"
	}
	f := OnboardingFix{Kind: kind}
	switch kind {
	case "run_fix":
		f.Action = value
	case "open_url":
		f.URL = value
	case "open_settings", "choose_path":
		f.Target = value
	}
	return OnboardingError{code, step, strings.ReplaceAll(d.message, "{title}", preflightTitles[step]), f}
}

type diagnosticSpec struct{ state, kind, value, message string }

var preflightDiagnostics = map[string]diagnosticSpec{
	"codex_not_found":                   {"optional", "open_url", "https://learn.chatgpt.com/docs/codex/cli", "未找到 Codex。请打开安装说明，安装完成后重新检查。"},
	"codex_version_too_old":             {"optional", "open_url", "https://learn.chatgpt.com/docs/codex/cli", "Codex 版本过低。请按说明更新后重新检查。"},
	"codex_signed_out":                  {"optional", "open_url", "https://learn.chatgpt.com/docs/codex/cli", "请按说明登录 Codex，完成后重新检查。"},
	"codex_upstream_unavailable":        {"error", "retry", "", "无法连接 Codex 服务。请检查服务状态后重试。"},
	"codex_transport_invalid":           {"error", "open_settings", "assistants", "Codex 连接设置无效。请检查或清除所选连接。"},
	"claude_not_found":                  {"optional", "open_url", "https://code.claude.com/docs/en/quickstart", "未找到 Claude Code。请打开安装说明，安装完成后重新检查。"},
	"claude_version_too_old":            {"optional", "open_url", "https://code.claude.com/docs/en/quickstart", "Claude Code 版本过低。请按说明更新后重新检查。"},
	"claude_signed_out":                 {"optional", "open_url", "https://code.claude.com/docs/en/quickstart", "请按说明登录 Claude Code，完成后重新检查。"},
	"claude_bridge_missing":             {"error", "open_url", "https://github.com/gaixianggeng/mimi-remote/releases/latest", "Claude Code 所需的连接组件不可用。请重新安装桌面端。"},
	"agy_not_found":                     {"optional", "open_url", "https://antigravity.google/", "未找到 Antigravity。请打开安装说明，安装完成后重新检查。"},
	"agy_version_too_old":               {"optional", "open_url", "https://antigravity.google/", "Antigravity 版本过低。请按说明更新后重新检查。"},
	"agy_signed_out":                    {"optional", "open_url", "https://antigravity.google/", "请按说明登录 Antigravity，完成后重新检查。"},
	"agy_adapter_missing":               {"error", "open_url", "https://github.com/gaixianggeng/mimi-remote/releases/latest", "Antigravity 所需的连接组件不可用。请重新安装桌面端。"},
	"runtime_path_invalid":              {"error", "choose_path", "agy_bin", "{title}：所选程序无法使用。请重新选择程序，或恢复自动检测。"},
	"runtime_incompatible":              {"optional", "open_url", "https://antigravity.google/", "{title}：检测到的版本不兼容。请按说明安装受支持的版本。"},
	"runtime_probe_failed":              {"error", "retry", "", "{title}：未能确认助手状态。请重新检查。"},
	"runtime_unsupported_platform":      {"optional", "skip", "", "{title}：当前平台尚不支持此助手，可以跳过。"},
	"assistant_disabled":                {"optional", "run_fix", "connect_deepseek", "{title}：已检测到可用助手。需要使用时可启用。"},
	"deepseek_not_running":              {"optional", "open_url", "https://github.com/deepseek-ai/deepseek-harness", "未检测到正在运行的 DeepSeek Harness。请打开启动说明。"},
	"deepseek_auth_failed":              {"error", "run_fix", "connect_deepseek", "DeepSeek Harness 未能验证连接。请重新连接。"},
	"deepseek_no_models":                {"error", "retry", "", "DeepSeek Harness 暂无可用模型。请添加模型后重新检查。"},
	"no_enabled_assistant":              {"action_needed", "open_url", "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md", "请启用至少一个可用助手，然后重新配对。"},
	"workspace_confirmation_required":   {"action_needed", "choose_path", "workspace_root", "请先在电脑上确认要与手机共享的代码目录。"},
	"workspace_not_found":               {"error", "choose_path", "workspace_root", "找不到所选代码目录。请重新选择。"},
	"workspace_not_directory":           {"error", "choose_path", "workspace_root", "所选位置是文件。请选择代码目录。"},
	"workspace_unreadable":              {"error", "choose_path", "workspace_root", "请选择可读取的代码目录。"},
	"config_missing":                    {"action_needed", "run_fix", "save_setup", "请先选择代码目录并保存配置。"},
	"config_dir_unwritable":             {"error", "retry", "", "无法写入配置目录。请检查访问权限和可用空间后重试。"},
	"config_permissions_unsafe":         {"error", "run_fix", "doctor_fix", "配置文件的访问权限过宽。请在电脑上修复权限。"},
	"config_invalid":                    {"error", "open_settings", "host_recovery", "配置无法安全读取。请查看已保留的配置和恢复位置。"},
	"config_requires_newer_version":     {"error", "open_url", "https://github.com/gaixianggeng/mimi-remote/releases/latest", "此配置需要较新的桌面端。请更新后重试。"},
	"config_concurrent_change":          {"", "retry", "", "配置已在别处更改。请重新加载并确认选择。"},
	"config_commit_failed":              {"", "retry", "", "本次配置未能保存。原配置已保留，请重试。"},
	"config_recovery_required":          {"error", "open_settings", "host_recovery", "配置需要恢复。请在电脑上查看保留的文件。"},
	"token_rotation_requires_approval":  {"error", "open_settings", "host_recovery", "此操作会更改电脑的配对身份。请查看保留的配置。"},
	"legacy_codex_residue":              {"error", "open_settings", "host_recovery", "检测到旧版 Codex 配置。请在电脑上查看迁移说明。"},
	"tailscale_not_installed":           {"optional", "open_url", "https://tailscale.com/download", "未检测到 Tailscale。需要此连接方式时请按说明安装。"},
	"tailscale_not_connected":           {"optional", "retry", "", "Tailscale 尚未连接。请连接后重新检查。"},
	"tailscale_disabled":                {"optional", "run_fix", "enable_tailscale", "Tailscale 已连接，可在配对设置中启用。"},
	"tailcat_disabled":                  {"optional", "run_fix", "enable_tailcat", "内置连接可用，可在配对设置中启用。"},
	"tailcat_unavailable":               {"error", "open_url", "https://github.com/gaixianggeng/mimi-remote/releases/latest", "内置连接组件不可用。请重新安装桌面端以修复组件。"},
	"tailcat_relay_unreachable":         {"error", "retry", "", "暂时无法连接中继。请稍后重试。"},
	"tailcat_busy":                      {"", "retry", "", "内置连接正在处理其他操作。请稍后重试。"},
	"tailcat_settings_invalid":          {"error", "open_settings", "connections", "中继设置无效或尚未生效。请检查连接设置。"},
	"lan_unavailable":                   {"optional", "retry", "", "未检测到可信局域网。请连接专用网络后重新检查。"},
	"lan_disabled":                      {"optional", "run_fix", "enable_lan", "同一局域网连接可用，可在配对设置中启用。"},
	"lan_public_network_blocked":        {"action_needed", "open_settings", "windows_network_profile", "当前网络未确认为专用网络。请检查 Windows 网络配置。"},
	"lan_firewall_blocked":              {"action_needed", "open_settings", "windows_firewall", "防火墙规则未允许专用网络连接。请在电脑上检查规则。"},
	"no_direct_network":                 {"action_needed", "run_fix", "enable_tailcat", "没有可用的直连通道。可在配对时启用内置连接。"},
	"no_network_available":              {"action_needed", "retry", "", "暂无可用的连接方式。请检查网络后重试。"},
	"network_selection_required":        {"action_needed", "run_fix", "enable_tailscale", "请选择要用于配对的连接方式。"},
	"service_start_timeout":             {"error", "retry", "", "等待后台服务就绪超时。请重新检查服务状态。"},
	"service_port_in_use":               {"error", "retry", "", "服务端口已被占用。请关闭占用端口的应用后重试。"},
	"service_version_mismatch":          {"error", "run_fix", "restart_service", "后台服务与客户端版本不一致。请在电脑上重新加载服务。"},
	"service_not_registered":            {"action_needed", "run_fix", "register_service", "后台服务尚未注册。请在电脑上注册并启动服务。"},
	"service_install_incomplete":        {"error", "open_url", "https://github.com/gaixianggeng/mimi-remote/releases/latest", "后台服务组件不完整。请重新安装桌面端。"},
	"service_not_running":               {"action_needed", "run_fix", "restart_service", "后台服务尚未运行。请在电脑上启动服务。"},
	"service_start_failed":              {"error", "run_fix", "restart_service", "后台服务启动失败。请检查并重试。"},
	"homebrew_service_active":           {"optional", "run_fix", "takeover_homebrew", "Homebrew 正在管理后台服务。可继续使用，或确认后改由桌面端管理。"},
	"permission_folder_denied":          {"action_needed", "open_settings", "files_and_folders", "后台服务无法读取所选目录。请检查文件与文件夹权限。"},
	"permission_unobserved":             {"optional", "skip", "", "{title}：尚未获得此权限的状态。可以跳过此项。"},
	"pair_host_unreachable":             {"error", "retry", "", "无法连接电脑后台服务。请检查连接后重试。"},
	"pair_token_mismatch":               {"error", "run_fix", "restart_service", "电脑后台服务身份未同步。请在电脑端确认服务归属并重新加载配置后重试，无需删除手机上的已保存电脑。"},
	"pair_ticket_expired":               {"", "retry", "", "二维码已过期。请在电脑配对窗口点击“刷新二维码”后重扫，已有配对不受影响。"},
	"pair_ticket_invalid":               {"", "retry", "", "配对链接无效。请在电脑上刷新二维码后重扫。"},
	"pair_clock_skew":                   {"", "open_settings", "date_time", "设备时间不一致。请检查系统日期与时间后重新配对。"},
	"pair_managed_entitlement_required": {"", "open_settings", "managed_connection", "此托管连接需要有效的订阅权益。请查看托管连接设置。"},
	"pair_managed_grant_conflict":       {"", "retry", "", "托管连接授权未生效或已过期。请重新获取配对链接。"},
	"invalid_request":                   {"", "retry", "", "{title}：请求参数无效。请检查输入后重试。"},
	"probe_timeout":                     {"error", "retry", "", "{title}：检查超时。请重新检查此项。"},
	"internal_error":                    {"error", "retry", "", "{title}：未能完成此项操作。请重试。"},
}

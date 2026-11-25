package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
)

const (
	onboardingPreflightSchemaV1 = "mimi.onboarding.preflight/v1"
	onboardingCodesSchemaV1     = "mimi.onboarding.codes/v1"
	onboardingMediaTypeV1       = "application/vnd.mimi.onboarding.v1+json"
	onboardingDoctorFixCap      = "identity_preserving_doctor_fix"
	onboardingSafeFallbackCopy  = "当前操作暂时无法自动处理。请检查电脑端状态后手动重新检查。"
	onboardingUnknownMajorCopy  = "当前电脑端返回了不受支持的诊断协议版本。请更新桌面端后重新检查。"
	onboardingLegacyHostCopy    = "当前电脑端版本较旧，不支持新的引导检查。请更新桌面端后重试。"
)

type boundedTrayOutput struct {
	bytes.Buffer
	remaining int
	truncated bool
}

func (b *boundedTrayOutput) Write(p []byte) (int, error) {
	n := len(p)
	if len(p) > b.remaining {
		p = p[:b.remaining]
		b.truncated = true
	}
	_, _ = b.Buffer.Write(p)
	b.remaining -= len(p)
	return n, nil
}

// onboardingFix decodes strictly against the closed v1 fix allow-list and rejects any extra fields.
type onboardingFix struct {
	Kind   string `json:"kind"`
	URL    string `json:"url,omitempty"`
	Target string `json:"target,omitempty"`
	Action string `json:"action,omitempty"`
}

func (f *onboardingFix) UnmarshalJSON(raw []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return fmt.Errorf("invalid fix object: %w", err)
	}
	if fields == nil {
		return errors.New("fix must be an object")
	}
	kindRaw, ok := fields["kind"]
	if !ok {
		return errors.New("fix missing kind")
	}
	var kind string
	if err := json.Unmarshal(kindRaw, &kind); err != nil {
		return errors.New("fix kind must be string")
	}
	parsed := onboardingFix{Kind: kind}
	switch kind {
	case "retry", "skip":
		if len(fields) != 1 {
			return fmt.Errorf("unexpected extra field in %s fix", kind)
		}
	case "open_url":
		if len(fields) != 2 {
			return errors.New("open_url fix requires exact fields kind and url")
		}
		urlRaw, ok := fields["url"]
		if !ok {
			return errors.New("open_url fix missing url")
		}
		if err := json.Unmarshal(urlRaw, &parsed.URL); err != nil || !isAllowedOnboardingURL(parsed.URL) {
			return errors.New("open_url fix url not in allow-list")
		}
	case "open_settings":
		if len(fields) != 2 {
			return errors.New("open_settings fix requires exact fields kind and target")
		}
		targetRaw, ok := fields["target"]
		if !ok {
			return errors.New("open_settings fix missing target")
		}
		if err := json.Unmarshal(targetRaw, &parsed.Target); err != nil || !slices.Contains(onboardingSettingsTargets, parsed.Target) {
			return errors.New("open_settings fix target not in allow-list")
		}
	case "choose_path":
		if len(fields) != 2 {
			return errors.New("choose_path fix requires exact fields kind and target")
		}
		targetRaw, ok := fields["target"]
		if !ok {
			return errors.New("choose_path fix missing target")
		}
		if err := json.Unmarshal(targetRaw, &parsed.Target); err != nil || !slices.Contains(onboardingPathTargets, parsed.Target) {
			return errors.New("choose_path fix target not in allow-list")
		}
	case "run_fix":
		if len(fields) != 2 {
			return errors.New("run_fix requires exact fields kind and action")
		}
		actionRaw, ok := fields["action"]
		if !ok {
			return errors.New("run_fix missing action")
		}
		if err := json.Unmarshal(actionRaw, &parsed.Action); err != nil {
			return errors.New("run_fix action must be string")
		}
		if _, known := onboardingRunFixSpecs[parsed.Action]; !known {
			return errors.New("run_fix action not in allow-list")
		}
	default:
		return fmt.Errorf("unknown fix kind %q", kind)
	}
	*f = parsed
	return nil
}

type onboardingDiagnostic struct {
	Code         string        `json:"code"`
	Step         string        `json:"step"`
	Message      string        `json:"message"`
	Fix          onboardingFix `json:"fix"`
	ConfigPath   string        `json:"config_path,omitempty"`
	RecoveryPath string        `json:"recovery_path,omitempty"`
}

type onboardingErrorEnvelope struct {
	OK    *bool                `json:"ok"`
	Error *onboardingDiagnostic `json:"error"`
}

type onboardingCandidate struct {
	Path    string `json:"path"`
	Outcome string `json:"outcome"`
	Version string `json:"version,omitempty"`
}

type onboardingCheck struct {
	ID              string                `json:"id"`
	Group           string                `json:"group"`
	State           string                `json:"state"`
	Title           string                `json:"title"`
	Detail          string                `json:"detail"`
	Blocking        *bool                 `json:"blocking"`
	Code            string                `json:"code,omitempty"`
	Fix             *onboardingFix        `json:"fix,omitempty"`
	ConfigPath      string                `json:"config_path,omitempty"`
	RecoveryPath    string                `json:"recovery_path,omitempty"`
	Enabled         *bool                 `json:"enabled,omitempty"`
	Available       *bool                 `json:"available,omitempty"`
	Candidates      []onboardingCandidate `json:"candidates,omitempty"`
	Source          string                `json:"source,omitempty"`
	DetectedVersion string                `json:"detected_version,omitempty"`
	MinVersion      string                `json:"min_version,omitempty"`

	// Raw key presence flags enforced during schema/tuple validation.
	hasAvailableKey  bool
	hasCandidatesKey bool
	hasCodeKey       bool
	hasFixKey        bool
	hasConfigPath    bool
	hasRecoveryPath  bool
}

type onboardingPreflightReport struct {
	Schema               string            `json:"schema"`
	OK                   *bool             `json:"ok"`
	Stage                string            `json:"stage"`
	Configured           *bool             `json:"configured"`
	WorkspaceConfirmed   *bool             `json:"workspace_confirmed"`
	ConfigPath           string            `json:"config_path"`
	ScanRoot             string            `json:"scan_root"`
	BrowseRoot           string            `json:"browse_root"`
	ScanRootExists       *bool             `json:"scan_root_exists"`
	RecommendedNext      string            `json:"recommended_next"`
	RecommendedTransport *string           `json:"recommended_transport"`
	Checks               []onboardingCheck `json:"checks"`

	hasRecommendedTransportKey bool
}

type onboardingSetupReceipt struct {
	OK                  *bool    `json:"ok"`
	Configured          *bool    `json:"configured"`
	Created             *bool    `json:"created"`
	ConfigPath          string   `json:"config_path"`
	ScanRoot            string   `json:"scan_root"`
	BrowseRoot          string   `json:"browse_root"`
	PairingDeferred     *bool    `json:"pairing_deferred,omitempty"`
	Endpoint            string   `json:"endpoint,omitempty"`
	PairURL             string   `json:"pair_url,omitempty"`
	PairExpiresAt       string   `json:"pair_expires_at,omitempty"`
	Network             string   `json:"network,omitempty"`
	TailscaleDNSName    string   `json:"tailscale_dns_name,omitempty"`
	TailscaleDeviceName string   `json:"tailscale_device_name,omitempty"`
	Warnings            []string `json:"warnings,omitempty"`
	Legacy              bool     `json:"-"`
}

type onboardingUpReadinessReceipt struct {
	OK        *bool    `json:"ok,omitempty"`
	ServiceOK *bool    `json:"service_ok"`
	Version   string   `json:"version"`
	Warnings  []string `json:"warnings,omitempty"`
}

type onboardingPairingTicketReceipt struct {
	OK                  *bool    `json:"ok,omitempty"`
	Endpoint            string   `json:"endpoint"`
	PairURL             string   `json:"pair_url"`
	PairExpiresAt       string   `json:"pair_expires_at"`
	Network             string   `json:"network,omitempty"`
	TailscaleDNSName    string   `json:"tailscale_dns_name,omitempty"`
	TailscaleDeviceName string   `json:"tailscale_device_name,omitempty"`
	Warnings            []string `json:"warnings,omitempty"`
}

type onboardingValidationContext struct {
	Surface                 string
	Platform                string
	Stage                   string
	Configured              *bool
	HasRecommendedTransport bool
	RecommendedTransport    string // empty when HasRecommendedTransport && null
	VerifiedCapability      string
	ExplicitlyEnabled       *bool
}

type onboardingResolvedDiagnostic struct {
	Code           string
	Step           string
	Message        string
	AllowedFix     *onboardingFix
	SecondaryFix   *onboardingFix
	SecondaryLabel string
	ConfigPath     string
	RecoveryPath   string
	Trusted        bool
	LegacyHost     bool
}

type onboardingCLIError struct {
	Diagnostic onboardingResolvedDiagnostic
	Fallback   string
}

func (e *onboardingCLIError) Error() string {
	if strings.TrimSpace(e.Diagnostic.Message) != "" {
		return e.Diagnostic.Message
	}
	if strings.TrimSpace(e.Fallback) != "" {
		return e.Fallback
	}
	return onboardingSafeFallbackCopy
}

type onboardingCheckSpec struct {
	ID        string
	Group     string
	Platforms []string
	TitleZH   string
}

type onboardingRunFixSpec struct {
	RequiresConfig     bool
	RequiresCapability string
}

type onboardingVariantWhen struct {
	Step                    string
	Stage                   string
	Surface                 string
	Configured              *bool
	HasRecommendedTransport bool
	RecommendedTransport    string // empty means match JSON null when HasRecommendedTransport is true
}

type onboardingFixVariant struct {
	When onboardingVariantWhen
	Fix  onboardingFix
}

type onboardingCatalogEntry struct {
	Code             string
	UILocal          bool
	Steps            []string
	Platforms        []string
	Surfaces         []string
	SetupStates      []string
	PairStates       []string
	MessageZH        string
	Variants         []onboardingFixVariant
	StateRule        string
	SecondaryFix     *onboardingFix
	SecondaryLabelZH string
}

type onboardingCommandTimeout struct {
	Commands     []string
	BackendMax   time.Duration
	ClientMin    time.Duration
	WindowsValue time.Duration
}

const (
	onboardingURLCodex   = "https://learn.chatgpt.com/docs/codex/cli"
	onboardingURLClaude  = "https://code.claude.com/docs/en/quickstart"
	onboardingURLAgy     = "https://antigravity.google/"
	onboardingURLHarness = "https://github.com/deepseek-ai/deepseek-harness"
	onboardingURLTS      = "https://tailscale.com/download"
	onboardingURLDesktop = "https://github.com/gaixianggeng/mimi-remote/releases/latest"
	onboardingURLGuide   = "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/quickstart.md"
)

var onboardingURLAllowlist = map[string]string{
	"CODEX":   onboardingURLCodex,
	"CLAUDE":  onboardingURLClaude,
	"AGY":     onboardingURLAgy,
	"HARNESS": onboardingURLHarness,
	"TS":      onboardingURLTS,
	"DESKTOP": onboardingURLDesktop,
	"GUIDE":   onboardingURLGuide,
}

var onboardingSettingsTargets = []string{
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
}

var onboardingPathTargets = []string{
	"workspace_root",
	"codex_bin",
	"claude_bin",
	"agy_bin",
}

var onboardingRunFixSpecs = map[string]onboardingRunFixSpec{
	"save_setup":        {RequiresConfig: false},
	"enable_codex":      {RequiresConfig: false},
	"enable_claude":     {RequiresConfig: false},
	"enable_agy":        {RequiresConfig: false},
	"enable_tailscale":  {RequiresConfig: true},
	"enable_lan":        {RequiresConfig: true},
	"enable_tailcat":    {RequiresConfig: true},
	"connect_deepseek":  {RequiresConfig: true},
	"restart_service":   {RequiresConfig: true},
	"register_service":  {RequiresConfig: true},
	"doctor_fix":        {RequiresConfig: true, RequiresCapability: onboardingDoctorFixCap},
	"takeover_homebrew": {RequiresConfig: true},
}

var onboardingCommandTimeouts = []onboardingCommandTimeout{
	{Commands: []string{"preflight"}, BackendMax: 20 * time.Second, ClientMin: 35 * time.Second},
	{Commands: []string{"setup"}, BackendMax: 20 * time.Second, ClientMin: 60 * time.Second},
	{Commands: []string{"pair", "tailcat pair"}, BackendMax: 25 * time.Second, ClientMin: 45 * time.Second},
	{Commands: []string{"runtime", "network", "workspace", "doctor --fix"}, BackendMax: 30 * time.Second, ClientMin: 45 * time.Second},
	{Commands: []string{"up", "start", "restart"}, BackendMax: 85 * time.Second, ClientMin: 110 * time.Second, WindowsValue: 120 * time.Second},
}

var (
	allPlatforms      = []string{"macos", "windows", "linux"}
	macOnly           = []string{"macos"}
	winOnly           = []string{"windows"}
	macAndWin         = []string{"macos", "windows"}
	surfCheckCLI      = []string{"check", "cli"}
	surfCheckCLIHTTP  = []string{"check", "cli", "http"}
	surfCLI           = []string{"cli"}
	surfCLIHTTP       = []string{"cli", "http"}
	surfHTTP          = []string{"http"}
	surfNative        = []string{"native"}
	surfCheckNative   = []string{"check", "native"}
	surfUILocal       = []string{"ui_local"}
	statesOptAction   = []string{"optional", "action_needed"}
	statesAction      = []string{"action_needed"}
	statesOptional    = []string{"optional"}
	statesError       = []string{"error"}
	boolFalseVal      = false
	boolTrueVal       = true
	retryFix          = onboardingFix{Kind: "retry"}
	skipFix           = onboardingFix{Kind: "skip"}
	saveSetupFix      = onboardingFix{Kind: "run_fix", Action: "save_setup"}
	hostRecoveryFix   = onboardingFix{Kind: "open_settings", Target: "host_recovery"}
	connectionsFix    = onboardingFix{Kind: "open_settings", Target: "connections"}
	desktopURLFix     = onboardingFix{Kind: "open_url", URL: onboardingURLDesktop}
	workspacePickFix  = onboardingFix{Kind: "choose_path", Target: "workspace_root"}
	signedOutLabelZH  = "我已登录，重新检查"
	validOutcomes     = []string{"missing", "unusable", "unsupported", "compatible", "selected", "timeout"}
	validSources      = []string{"pin", "env", "auto"}
	validTransports   = []string{"tailscale", "tailcat", "lan"}
	validCheckStates  = []string{"checking", "ok", "optional", "action_needed", "error"}
	httpForbiddenKeys = map[string]struct{}{
		"config_path": {}, "recovery_path": {}, "candidates": {}, "detected_version": {}, "min_version": {},
		"source": {}, "scan_root": {}, "browse_root": {}, "endpoint": {}, "pair_url": {}, "stderr": {},
		"path": {}, "host": {}, "host_id": {}, "runtime": {}, "runtime_status": {}, "config": {},
		"scan_root_exists": {}, "tailscale_dns_name": {}, "tailscale_device_name": {}, "device_id": {},
		"raw_stderr": {}, "grant": {}, "signature": {}, "token": {}, "token_file": {}, "connect_url": {},
	}
)

var onboardingChecksCatalog = []onboardingCheckSpec{
	{ID: "config_store", Group: "workspace", Platforms: allPlatforms, TitleZH: "配置文件"},
	{ID: "workspace_root", Group: "workspace", Platforms: allPlatforms, TitleZH: "代码目录"},
	{ID: "service_owner_conflict", Group: "service", Platforms: macOnly, TitleZH: "后台服务归属"},
	{ID: "service_daemon", Group: "service", Platforms: allPlatforms, TitleZH: "后台服务"},
	{ID: "assistant_codex", Group: "assistant", Platforms: allPlatforms, TitleZH: "Codex 助手"},
	{ID: "assistant_claude", Group: "assistant", Platforms: allPlatforms, TitleZH: "Claude Code 助手"},
	{ID: "assistant_agy", Group: "assistant", Platforms: allPlatforms, TitleZH: "Antigravity 助手"},
	{ID: "assistant_deepseek", Group: "assistant", Platforms: allPlatforms, TitleZH: "DeepSeek 助手"},
	{ID: "assistant_any", Group: "assistant", Platforms: allPlatforms, TitleZH: "可用助手"},
	{ID: "network_tailscale", Group: "network", Platforms: allPlatforms, TitleZH: "Tailscale 连接"},
	{ID: "network_tailcat", Group: "network", Platforms: allPlatforms, TitleZH: "内置连接"},
	{ID: "network_lan", Group: "network", Platforms: allPlatforms, TitleZH: "同一局域网"},
	{ID: "network_any", Group: "network", Platforms: allPlatforms, TitleZH: "手机连接方式"},
	{ID: "permission_login_item", Group: "permission", Platforms: macOnly, TitleZH: "登录项"},
	{ID: "permission_folder_access", Group: "permission", Platforms: macOnly, TitleZH: "文件与文件夹"},
	{ID: "permission_local_network", Group: "permission", Platforms: macAndWin, TitleZH: "本地网络"},
	{ID: "permission_photos", Group: "permission", Platforms: macOnly, TitleZH: "照片"},
	{ID: "permission_full_disk", Group: "permission", Platforms: macOnly, TitleZH: "完全磁盘访问"},
}

func vAlways(fix onboardingFix) []onboardingFixVariant {
	return []onboardingFixVariant{{Fix: fix}}
}

func vConfigSplit(action string) []onboardingFixVariant {
	return []onboardingFixVariant{
		{When: onboardingVariantWhen{Configured: &boolFalseVal}, Fix: saveSetupFix},
		{When: onboardingVariantWhen{Configured: &boolTrueVal}, Fix: onboardingFix{Kind: "run_fix", Action: action}},
	}
}

func vTransportEnable(action string) []onboardingFixVariant {
	return []onboardingFixVariant{
		{When: onboardingVariantWhen{Configured: &boolFalseVal}, Fix: saveSetupFix},
		{When: onboardingVariantWhen{Stage: "setup", Configured: &boolTrueVal}, Fix: connectionsFix},
		{When: onboardingVariantWhen{Stage: "pair", Configured: &boolTrueVal}, Fix: onboardingFix{Kind: "run_fix", Action: action}},
	}
}

var onboardingCodeCatalog = []onboardingCatalogEntry{
	// 77 wire codes
	{Code: "codex_not_found", Steps: []string{"assistant_codex"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "未找到 Codex。请打开安装说明，安装完成后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLCodex})},
	{Code: "codex_version_too_old", Steps: []string{"assistant_codex"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "Codex 版本过低。请按说明更新后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLCodex})},
	{Code: "codex_signed_out", Steps: []string{"assistant_codex"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "请按说明登录 Codex，完成后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLCodex}), StateRule: "signed_out_states", SecondaryFix: &retryFix, SecondaryLabelZH: signedOutLabelZH},
	{Code: "codex_upstream_unavailable", Steps: []string{"assistant_codex"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "无法连接 Codex 服务。请检查服务状态后重试。", Variants: vAlways(retryFix)},
	{Code: "codex_transport_invalid", Steps: []string{"assistant_codex"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "Codex 连接设置无效。请检查或清除所选连接。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "assistants"})},
	{Code: "claude_not_found", Steps: []string{"assistant_claude"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "未找到 Claude Code。请打开安装说明，安装完成后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLClaude})},
	{Code: "claude_version_too_old", Steps: []string{"assistant_claude"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "Claude Code 版本过低。请按说明更新后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLClaude})},
	{Code: "claude_signed_out", Steps: []string{"assistant_claude"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "请按说明登录 Claude Code，完成后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLClaude}), StateRule: "signed_out_states", SecondaryFix: &retryFix, SecondaryLabelZH: signedOutLabelZH},
	{Code: "claude_bridge_missing", Steps: []string{"assistant_claude"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "Claude Code 所需的连接组件不可用。请重新安装桌面端。", Variants: vAlways(desktopURLFix)},
	{Code: "agy_not_found", Steps: []string{"assistant_agy"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "未找到 Antigravity。请打开安装说明，安装完成后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLAgy})},
	{Code: "agy_version_too_old", Steps: []string{"assistant_agy"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "Antigravity 版本过低。请按说明更新后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLAgy})},
	{Code: "agy_signed_out", Steps: []string{"assistant_agy"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "请按说明登录 Antigravity，完成后重新检查。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLAgy}), StateRule: "signed_out_states", SecondaryFix: &retryFix, SecondaryLabelZH: signedOutLabelZH},
	{Code: "agy_adapter_missing", Steps: []string{"assistant_agy"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "Antigravity 所需的连接组件不可用。请重新安装桌面端。", Variants: vAlways(desktopURLFix)},
	{Code: "runtime_path_invalid", Steps: []string{"assistant_codex", "assistant_claude", "assistant_agy"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "{title}：所选程序无法使用。请重新选择程序，或恢复自动检测。", Variants: []onboardingFixVariant{
		{When: onboardingVariantWhen{Step: "assistant_codex"}, Fix: onboardingFix{Kind: "choose_path", Target: "codex_bin"}},
		{When: onboardingVariantWhen{Step: "assistant_claude"}, Fix: onboardingFix{Kind: "choose_path", Target: "claude_bin"}},
		{When: onboardingVariantWhen{Step: "assistant_agy"}, Fix: onboardingFix{Kind: "choose_path", Target: "agy_bin"}},
	}},
	{Code: "runtime_incompatible", Steps: []string{"assistant_codex", "assistant_claude", "assistant_agy"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "{title}：检测到的版本不兼容。请按说明安装受支持的版本。", Variants: []onboardingFixVariant{
		{When: onboardingVariantWhen{Step: "assistant_codex"}, Fix: onboardingFix{Kind: "open_url", URL: onboardingURLCodex}},
		{When: onboardingVariantWhen{Step: "assistant_claude"}, Fix: onboardingFix{Kind: "open_url", URL: onboardingURLClaude}},
		{When: onboardingVariantWhen{Step: "assistant_agy"}, Fix: onboardingFix{Kind: "open_url", URL: onboardingURLAgy}},
	}},
	{Code: "runtime_probe_failed", Steps: []string{"assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "{title}：未能确认助手状态。请重新检查。", Variants: vAlways(retryFix)},
	{Code: "runtime_unsupported_platform", Steps: []string{"assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptional, PairStates: statesOptional, MessageZH: "{title}：当前平台尚不支持此助手，可以跳过。", Variants: vAlways(skipFix)},
	{Code: "assistant_disabled", Steps: []string{"assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "{title}：已检测到可用助手。需要使用时可启用。", Variants: []onboardingFixVariant{
		{When: onboardingVariantWhen{Step: "assistant_codex"}, Fix: onboardingFix{Kind: "run_fix", Action: "enable_codex"}},
		{When: onboardingVariantWhen{Step: "assistant_claude"}, Fix: onboardingFix{Kind: "run_fix", Action: "enable_claude"}},
		{When: onboardingVariantWhen{Step: "assistant_agy"}, Fix: onboardingFix{Kind: "run_fix", Action: "enable_agy"}},
		{When: onboardingVariantWhen{Step: "assistant_deepseek", Configured: &boolFalseVal}, Fix: saveSetupFix},
		{When: onboardingVariantWhen{Step: "assistant_deepseek", Configured: &boolTrueVal}, Fix: onboardingFix{Kind: "run_fix", Action: "connect_deepseek"}},
	}},
	{Code: "deepseek_not_running", Steps: []string{"assistant_deepseek"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "未检测到正在运行的 DeepSeek Harness。请打开启动说明。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLHarness})},
	{Code: "deepseek_auth_failed", Steps: []string{"assistant_deepseek"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "DeepSeek Harness 未能验证连接。请重新连接。", Variants: vConfigSplit("connect_deepseek")},
	{Code: "deepseek_no_models", Steps: []string{"assistant_deepseek"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "DeepSeek Harness 暂无可用模型。请添加模型后重新检查。", Variants: vAlways(retryFix)},
	{Code: "no_enabled_assistant", Steps: []string{"assistant_any"}, Platforms: allPlatforms, Surfaces: surfCheckCLIHTTP, SetupStates: statesAction, PairStates: statesAction, MessageZH: "请启用至少一个可用助手，然后重新配对。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLGuide})},
	{Code: "workspace_confirmation_required", Steps: []string{"workspace_root"}, Platforms: allPlatforms, Surfaces: surfCheckCLIHTTP, SetupStates: statesAction, PairStates: statesAction, MessageZH: "请先在电脑上确认要与手机共享的代码目录。", Variants: vAlways(workspacePickFix)},
	{Code: "workspace_not_found", Steps: []string{"workspace_root"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "找不到所选代码目录。请重新选择。", Variants: vAlways(workspacePickFix)},
	{Code: "workspace_not_directory", Steps: []string{"workspace_root"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "所选位置是文件。请选择代码目录。", Variants: vAlways(workspacePickFix)},
	{Code: "workspace_unreadable", Steps: []string{"workspace_root"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "请选择可读取的代码目录。", Variants: vAlways(workspacePickFix)},
	{Code: "config_missing", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "请先选择代码目录并保存配置。", Variants: vAlways(saveSetupFix)},
	{Code: "config_dir_unwritable", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "无法写入配置目录。请检查访问权限和可用空间后重试。", Variants: vAlways(retryFix)},
	{Code: "config_permissions_unsafe", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "配置文件的访问权限过宽。请在电脑上修复权限。", Variants: vConfigSplit("doctor_fix")},
	{Code: "config_invalid", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "配置无法安全读取。请查看已保留的配置和恢复位置。", Variants: vAlways(hostRecoveryFix)},
	{Code: "config_requires_newer_version", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "此配置需要较新的桌面端。请更新后重试。", Variants: vAlways(desktopURLFix)},
	{Code: "config_concurrent_change", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCLI, MessageZH: "配置已在别处更改。请重新加载并确认选择。", Variants: vAlways(retryFix)},
	{Code: "config_commit_failed", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCLI, MessageZH: "本次配置未能保存。原配置已保留，请重试。", Variants: vAlways(retryFix)},
	{Code: "config_recovery_required", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "配置需要恢复。请在电脑上查看保留的文件。", Variants: vAlways(hostRecoveryFix)},
	{Code: "token_rotation_requires_approval", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "此操作会更改电脑的配对身份。请查看保留的配置。", Variants: vAlways(hostRecoveryFix)},
	{Code: "legacy_codex_residue", Steps: []string{"config_store"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "检测到旧版 Codex 配置。请在电脑上查看迁移说明。", Variants: vAlways(hostRecoveryFix)},
	{Code: "tailscale_not_installed", Steps: []string{"network_tailscale"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "未检测到 Tailscale。需要此连接方式时请按说明安装。", Variants: vAlways(onboardingFix{Kind: "open_url", URL: onboardingURLTS})},
	{Code: "tailscale_not_connected", Steps: []string{"network_tailscale"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "Tailscale 尚未连接。请连接后重新检查。", Variants: vAlways(retryFix)},
	{Code: "tailscale_disabled", Steps: []string{"network_tailscale"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "Tailscale 已连接，可在配对设置中启用。", Variants: vTransportEnable("enable_tailscale")},
	{Code: "tailcat_disabled", Steps: []string{"network_tailcat"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "内置连接可用，可在配对设置中启用。", Variants: vTransportEnable("enable_tailcat")},
	{Code: "tailcat_unavailable", Steps: []string{"network_tailcat"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "内置连接组件不可用。请重新安装桌面端以修复组件。", Variants: vAlways(desktopURLFix)},
	{Code: "tailcat_relay_unreachable", Steps: []string{"network_tailcat"}, Platforms: allPlatforms, Surfaces: surfCheckCLIHTTP, SetupStates: statesError, PairStates: statesError, MessageZH: "暂时无法连接中继。请稍后重试。", Variants: vAlways(retryFix)},
	{Code: "tailcat_busy", Steps: []string{"network_tailcat"}, Platforms: allPlatforms, Surfaces: surfCLIHTTP, MessageZH: "内置连接正在处理其他操作。请稍后重试。", Variants: vAlways(retryFix)},
	{Code: "tailcat_settings_invalid", Steps: []string{"network_tailcat"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "中继设置无效或尚未生效。请检查连接设置。", Variants: vAlways(connectionsFix)},
	{Code: "lan_unavailable", Steps: []string{"network_lan"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "未检测到可信局域网。请连接专用网络后重新检查。", Variants: vAlways(retryFix)},
	{Code: "lan_disabled", Steps: []string{"network_lan"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesOptAction, PairStates: statesOptAction, MessageZH: "同一局域网连接可用，可在配对设置中启用。", Variants: vTransportEnable("enable_lan")},
	{Code: "lan_public_network_blocked", Steps: []string{"network_lan"}, Platforms: winOnly, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "当前网络未确认为专用网络。请检查 Windows 网络配置。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "windows_network_profile"})},
	{Code: "lan_firewall_blocked", Steps: []string{"network_lan"}, Platforms: winOnly, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "防火墙规则未允许专用网络连接。请在电脑上检查规则。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "windows_firewall"})},
	{Code: "no_direct_network", Steps: []string{"network_any"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "没有可用的直连通道。可在配对时启用内置连接。", Variants: vTransportEnable("enable_tailcat")},
	{Code: "no_network_available", Steps: []string{"network_any"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "暂无可用的连接方式。请检查网络后重试。", Variants: []onboardingFixVariant{
		{When: onboardingVariantWhen{Configured: &boolFalseVal, Stage: "setup"}, Fix: saveSetupFix},
		{When: onboardingVariantWhen{Configured: &boolTrueVal}, Fix: retryFix},
		{When: onboardingVariantWhen{Stage: "pair", Configured: &boolFalseVal}, Fix: retryFix},
	}},
	{Code: "network_selection_required", Steps: []string{"network_any"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "请选择要用于配对的连接方式。", Variants: []onboardingFixVariant{
		{When: onboardingVariantWhen{Configured: &boolFalseVal}, Fix: saveSetupFix},
		{When: onboardingVariantWhen{Configured: &boolTrueVal, Stage: "setup"}, Fix: connectionsFix},
		{When: onboardingVariantWhen{Configured: &boolTrueVal, Stage: "pair", HasRecommendedTransport: true, RecommendedTransport: "tailscale"}, Fix: onboardingFix{Kind: "run_fix", Action: "enable_tailscale"}},
		{When: onboardingVariantWhen{Configured: &boolTrueVal, Stage: "pair", HasRecommendedTransport: true, RecommendedTransport: "tailcat"}, Fix: onboardingFix{Kind: "run_fix", Action: "enable_tailcat"}},
		{When: onboardingVariantWhen{Configured: &boolTrueVal, Stage: "pair", HasRecommendedTransport: true, RecommendedTransport: "lan"}, Fix: onboardingFix{Kind: "run_fix", Action: "enable_lan"}},
		{When: onboardingVariantWhen{Configured: &boolTrueVal, Stage: "pair", HasRecommendedTransport: true, RecommendedTransport: ""}, Fix: connectionsFix},
	}},
	{Code: "service_start_timeout", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "等待后台服务就绪超时。请重新检查服务状态。", Variants: vAlways(retryFix)},
	{Code: "service_port_in_use", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "服务端口已被占用。请关闭占用端口的应用后重试。", Variants: vAlways(retryFix)},
	{Code: "service_requires_approval", Steps: []string{"service_daemon"}, Platforms: macOnly, Surfaces: surfNative, SetupStates: statesAction, PairStates: statesAction, MessageZH: "需要在系统设置中允许后台服务运行。请在“登录项”中允许后重新检查，服务就绪后即可生成二维码。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "login_items"})},
	{Code: "service_version_mismatch", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "后台服务与客户端版本不一致。请在电脑上重新加载服务。", Variants: vConfigSplit("restart_service")},
	{Code: "service_not_registered", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "后台服务尚未注册。请在电脑上注册并启动服务。", Variants: vConfigSplit("register_service")},
	{Code: "service_install_incomplete", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "后台服务组件不完整。请重新安装桌面端。", Variants: vAlways(desktopURLFix)},
	{Code: "service_not_running", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesAction, PairStates: statesAction, MessageZH: "后台服务尚未运行。请在电脑上启动服务。", Variants: vConfigSplit("restart_service")},
	{Code: "service_start_failed", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLI, SetupStates: statesError, PairStates: statesError, MessageZH: "后台服务启动失败。请检查并重试。", Variants: vConfigSplit("restart_service")},
	{Code: "homebrew_service_active", Steps: []string{"service_owner_conflict"}, Platforms: macOnly, Surfaces: surfCheckCLI, SetupStates: statesOptional, PairStates: statesOptional, MessageZH: "Homebrew 正在管理后台服务。可继续使用，或确认后改由桌面端管理。", Variants: vConfigSplit("takeover_homebrew")},
	{Code: "permission_login_item_disabled", Steps: []string{"permission_login_item"}, Platforms: macOnly, Surfaces: surfNative, SetupStates: statesOptional, PairStates: statesOptional, MessageZH: "主应用尚未启用登录时启动。可按需在登录项中设置。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "login_items"})},
	{Code: "permission_folder_denied", Steps: []string{"permission_folder_access"}, Platforms: macOnly, Surfaces: surfCheckNative, SetupStates: statesAction, PairStates: statesAction, MessageZH: "后台服务无法读取所选目录。请检查文件与文件夹权限。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "files_and_folders"})},
	{Code: "permission_local_network_denied", Steps: []string{"permission_local_network"}, Platforms: macOnly, Surfaces: surfNative, SetupStates: statesAction, PairStates: statesAction, MessageZH: "请在系统设置中允许本地网络访问。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "local_network"})},
	{Code: "permission_photos_denied", Steps: []string{"permission_photos"}, Platforms: macOnly, Surfaces: surfNative, SetupStates: statesOptional, PairStates: statesOptional, MessageZH: "照片访问尚未获准。需要使用时可在系统设置中允许。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "photos"})},
	{Code: "permission_full_disk_optional", Steps: []string{"permission_full_disk"}, Platforms: macOnly, Surfaces: surfNative, SetupStates: statesOptional, PairStates: statesOptional, MessageZH: "如需访问更多文件，可在系统设置中允许完全磁盘访问。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "full_disk_access"})},
	{Code: "permission_unobserved", Steps: []string{"permission_login_item", "permission_folder_access", "permission_local_network", "permission_photos", "permission_full_disk"}, Platforms: macAndWin, Surfaces: surfCheckNative, SetupStates: statesOptional, PairStates: statesOptional, MessageZH: "{title}：尚未获得此权限的状态。可以跳过此项。", Variants: vAlways(skipFix)},
	{Code: "pair_host_unreachable", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLIHTTP, SetupStates: statesError, PairStates: statesError, MessageZH: "无法连接电脑后台服务。请检查连接后重试。", Variants: vAlways(retryFix)},
	{Code: "pair_token_mismatch", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfCheckCLIHTTP, SetupStates: statesError, PairStates: statesError, MessageZH: "电脑后台服务身份未同步。请在电脑端确认服务归属并重新加载配置后重试，无需删除手机上的已保存电脑。", Variants: vConfigSplit("restart_service")},
	{Code: "pair_ticket_expired", Steps: []string{"network_any"}, Platforms: allPlatforms, Surfaces: surfCLIHTTP, MessageZH: "二维码已过期。请在电脑配对窗口点击“刷新二维码”后重扫，已有配对不受影响。", Variants: vAlways(retryFix)},
	{Code: "pair_ticket_invalid", Steps: []string{"network_any"}, Platforms: allPlatforms, Surfaces: surfCLIHTTP, MessageZH: "配对链接无效。请在电脑上刷新二维码后重扫。", Variants: vAlways(retryFix)},
	{Code: "pair_clock_skew", Steps: []string{"network_any"}, Platforms: allPlatforms, Surfaces: surfCLIHTTP, MessageZH: "设备时间不一致。请检查系统日期与时间后重新配对。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "date_time"})},
	{Code: "pair_local_forbidden", Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfHTTP, MessageZH: "此请求无法在本机认领。请使用手机扫描电脑上的二维码。", Variants: vAlways(retryFix)},
	{Code: "pair_managed_entitlement_required", Steps: []string{"network_tailcat"}, Platforms: allPlatforms, Surfaces: surfCLIHTTP, MessageZH: "此托管连接需要有效的订阅权益。请查看托管连接设置。", Variants: vAlways(onboardingFix{Kind: "open_settings", Target: "managed_connection"})},
	{Code: "pair_managed_grant_conflict", Steps: []string{"network_tailcat"}, Platforms: allPlatforms, Surfaces: surfCLIHTTP, MessageZH: "托管连接授权未生效或已过期。请重新获取配对链接。", Variants: vAlways(retryFix)},
	{Code: "invalid_request", Steps: []string{"config_store", "network_any"}, Platforms: allPlatforms, Surfaces: surfCLIHTTP, MessageZH: "{title}：请求参数无效。请检查输入后重试。", Variants: []onboardingFixVariant{
		{When: onboardingVariantWhen{Step: "config_store", Surface: "cli"}, Fix: retryFix},
		{When: onboardingVariantWhen{Step: "network_any", Surface: "http"}, Fix: retryFix},
	}},
	{Code: "probe_timeout", Steps: []string{"*"}, Platforms: allPlatforms, Surfaces: surfCheckCLIHTTP, SetupStates: statesError, PairStates: statesError, MessageZH: "{title}：检查超时。请重新检查此项。", Variants: vAlways(retryFix)},
	{Code: "internal_error", Steps: []string{"*"}, Platforms: allPlatforms, Surfaces: surfCheckCLIHTTP, SetupStates: statesError, PairStates: statesError, MessageZH: "{title}：未能完成此项操作。请重试。", Variants: vAlways(retryFix)},
	// 2 UI-local codes (never accepted on the wire)
	{Code: "command_timeout", UILocal: true, Steps: []string{"*"}, Platforms: allPlatforms, Surfaces: surfUILocal, MessageZH: "{title}：命令等待超时。请重新检查当前步骤。", Variants: vAlways(retryFix)},
	{Code: "embedded_binary_missing", UILocal: true, Steps: []string{"service_daemon"}, Platforms: allPlatforms, Surfaces: surfUILocal, MessageZH: "缺少内置服务程序。请重新安装桌面端。", Variants: vAlways(desktopURLFix)},
}

var (
	onboardingCodeIndex  map[string]onboardingCatalogEntry
	onboardingCheckIndex map[string]onboardingCheckSpec
)

func init() {
	onboardingCodeIndex = make(map[string]onboardingCatalogEntry, len(onboardingCodeCatalog))
	for _, entry := range onboardingCodeCatalog {
		onboardingCodeIndex[entry.Code] = entry
	}
	onboardingCheckIndex = make(map[string]onboardingCheckSpec, len(onboardingChecksCatalog))
	for _, check := range onboardingChecksCatalog {
		onboardingCheckIndex[check.ID] = check
	}
}

func isAllowedOnboardingURL(value string) bool {
	for _, allowed := range onboardingURLAllowlist {
		if value == allowed {
			return true
		}
	}
	return false
}

func onboardingCheckTitle(step, overrideTitle string) string {
	if trimmed := strings.TrimSpace(overrideTitle); trimmed != "" {
		return trimmed
	}
	if spec, ok := onboardingCheckIndex[step]; ok {
		return spec.TitleZH
	}
	return "后台服务"
}

func formatOnboardingMessage(code, step, title, detectedVersion string) string {
	entry, ok := onboardingCodeIndex[code]
	if !ok {
		return onboardingSafeFallbackCopy
	}
	msg := strings.ReplaceAll(entry.MessageZH, "{title}", onboardingCheckTitle(step, title))
	if strings.HasSuffix(code, "_signed_out") && strings.TrimSpace(detectedVersion) != "" {
		msg = fmt.Sprintf("已检测到版本 %s。%s", strings.TrimSpace(detectedVersion), msg)
	}
	return msg
}

func validateOnboardingDiagnostic(code, step string, fix onboardingFix, ctx onboardingValidationContext, state string) (onboardingResolvedDiagnostic, error) {
	entry, ok := onboardingCodeIndex[code]
	if !ok {
		return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("unknown diagnostic %q", code)
	}
	if ctx.Surface != "ui_local" && entry.UILocal {
		return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("ui_local code %q rejected on wire surface %q", code, ctx.Surface)
	}
	if ctx.Surface == "native" && ctx.Platform != "macos" {
		return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, errors.New("native overlay requires macOS")
	}
	checkSpec, checkOK := onboardingCheckIndex[step]
	if !checkOK {
		return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("unknown step %q", step)
	}
	if !slices.Contains(entry.Surfaces, ctx.Surface) || !slices.Contains(entry.Platforms, ctx.Platform) || !slices.Contains(checkSpec.Platforms, ctx.Platform) {
		return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("%s unavailable on %s/%s/%s", code, ctx.Surface, ctx.Platform, step)
	}
	if !slices.Contains(entry.Steps, step) && !slices.Equal(entry.Steps, []string{"*"}) {
		return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("%s cannot use step %s", code, step)
	}
	if state != "" {
		allowedStates := entry.SetupStates
		if ctx.Stage == "pair" {
			allowedStates = entry.PairStates
		}
		if !slices.Contains(allowedStates, state) {
			return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("%s cannot use state %s in %s", code, state, ctx.Stage)
		}
	}
	matched := -1
	for i, variant := range entry.Variants {
		if variantMatches(variant.When, step, ctx) {
			if matched >= 0 {
				return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("ambiguous %s variants", code)
			}
			matched = i
		}
	}
	if matched < 0 || entry.Variants[matched].Fix != fix {
		return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("mismatched fix for %s at %s", code, step)
	}
	if fix.Kind == "run_fix" {
		spec, known := onboardingRunFixSpecs[fix.Action]
		if !known {
			return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("unknown run_fix %q", fix.Action)
		}
		if spec.RequiresConfig && (ctx.Configured == nil || !*ctx.Configured) {
			return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("action %s requires configuration", fix.Action)
		}
		if spec.RequiresCapability != "" && ctx.VerifiedCapability != spec.RequiresCapability {
			return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("action %s requires verified capability %s", fix.Action, spec.RequiresCapability)
		}
		if slices.Contains([]string{"enable_tailscale", "enable_lan", "enable_tailcat"}, fix.Action) && ctx.Stage != "pair" {
			return onboardingResolvedDiagnostic{Code: code, Step: step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("transport enable %s outside pair stage", fix.Action)
		}
	}
	allowedFix := fix
	var secFix *onboardingFix
	if entry.SecondaryFix != nil {
		copySec := *entry.SecondaryFix
		secFix = &copySec
	}
	return onboardingResolvedDiagnostic{
		Code:           code,
		Step:           step,
		Message:        formatOnboardingMessage(code, step, checkSpec.TitleZH, ""),
		AllowedFix:     &allowedFix,
		SecondaryFix:   secFix,
		SecondaryLabel: entry.SecondaryLabelZH,
		Trusted:        true,
	}, nil
}

func variantMatches(when onboardingVariantWhen, step string, ctx onboardingValidationContext) bool {
	if when.Step != "" && when.Step != step {
		return false
	}
	if when.Stage != "" && when.Stage != ctx.Stage {
		return false
	}
	if when.Surface != "" && when.Surface != ctx.Surface {
		return false
	}
	if when.Configured != nil {
		if ctx.Configured == nil || *ctx.Configured != *when.Configured {
			return false
		}
	}
	if when.HasRecommendedTransport {
		if !ctx.HasRecommendedTransport || ctx.RecommendedTransport != when.RecommendedTransport {
			return false
		}
	}
	return true
}

func decodeOnboardingCheck(raw []byte) (onboardingCheck, error) {
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(raw, &keys); err != nil {
		return onboardingCheck{}, err
	}
	if keys == nil {
		return onboardingCheck{}, errors.New("check must be a JSON object")
	}
	var row onboardingCheck
	if err := json.Unmarshal(raw, &row); err != nil {
		return onboardingCheck{}, err
	}
	_, row.hasAvailableKey = keys["available"]
	_, row.hasCandidatesKey = keys["candidates"]
	_, row.hasCodeKey = keys["code"]
	_, row.hasFixKey = keys["fix"]
	_, row.hasConfigPath = keys["config_path"]
	_, row.hasRecoveryPath = keys["recovery_path"]
	return row, nil
}

func validateOnboardingCheck(row onboardingCheck, ctx onboardingValidationContext) (onboardingResolvedDiagnostic, error) {
	spec, ok := onboardingCheckIndex[row.ID]
	if !ok {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("unknown check id %q", row.ID)
	}
	if row.Group != spec.Group || !slices.Contains(spec.Platforms, ctx.Platform) {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("check %s group/platform mismatch", row.ID)
	}
	if !slices.Contains(validCheckStates, row.State) {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("unknown check state %q", row.State)
	}
	if strings.TrimSpace(row.Title) == "" || strings.TrimSpace(row.Detail) == "" || row.Blocking == nil {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("check %s missing required fields", row.ID)
	}
	if row.Source != "" && !slices.Contains(validSources, row.Source) {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("invalid candidate source %q", row.Source)
	}
	if row.ID != "config_store" && (row.hasConfigPath || row.hasRecoveryPath) {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("unexpected path fields on %s", row.ID)
	}
	if row.State == "ok" || row.State == "checking" {
		if row.hasCodeKey || row.hasFixKey || *row.Blocking {
			return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("%s state %s cannot carry code/fix or block", row.ID, row.State)
		}
	} else if !row.hasCodeKey || !row.hasFixKey || row.Fix == nil {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("%s state %s requires code and fix", row.ID, row.State)
	}
	isIndividual := slices.Contains([]string{
		"assistant_codex", "assistant_claude", "assistant_agy", "assistant_deepseek",
		"network_tailscale", "network_tailcat", "network_lan",
	}, row.ID)
	if isIndividual {
		if row.Enabled == nil || !row.hasAvailableKey || *row.Blocking {
			return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("individual check %s missing enabled/available or blocking", row.ID)
		}
	}
	isCLI := slices.Contains([]string{"assistant_codex", "assistant_claude", "assistant_agy"}, row.ID)
	if isCLI {
		if !row.hasCandidatesKey || row.Candidates == nil {
			return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("cli assistant %s missing candidates", row.ID)
		}
		selected := 0
		for _, cand := range row.Candidates {
			if strings.TrimSpace(cand.Path) == "" || !slices.Contains(validOutcomes, cand.Outcome) {
				return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("invalid candidate on %s", row.ID)
			}
			if cand.Outcome == "selected" {
				selected++
			}
		}
		needsSelection := row.State == "ok" || strings.HasSuffix(row.Code, "_signed_out") || row.Code == "assistant_disabled"
		if selected > 1 || (needsSelection && selected != 1) {
			return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("invalid selected candidate count %d on %s", selected, row.ID)
		}
	}
	if row.Code == "" {
		return onboardingResolvedDiagnostic{Step: row.ID, Message: row.Detail, Trusted: true}, nil
	}
	isPair := ctx.Stage == "pair"
	switch row.ID {
	case "config_store", "workspace_root":
		if *row.Blocking != (isPair || row.State == "error") {
			return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("inconsistent blocker on %s", row.ID)
		}
	case "assistant_any", "network_any", "service_daemon":
		if *row.Blocking != isPair {
			return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("inconsistent pair blocker on %s", row.ID)
		}
	}
	resolved, err := validateOnboardingDiagnostic(row.Code, row.ID, *row.Fix, ctx, row.State)
	if err != nil {
		return resolved, err
	}
	if strings.HasSuffix(row.Code, "_signed_out") {
		if ctx.Stage == "pair" || ctx.ExplicitlyEnabled != nil {
			enabled := row.Enabled != nil && *row.Enabled
			if ctx.Stage == "setup" && ctx.ExplicitlyEnabled != nil {
				enabled = *ctx.ExplicitlyEnabled
			}
			if (row.State == "action_needed") != enabled {
				return onboardingResolvedDiagnostic{Code: row.Code, Step: row.ID, Message: onboardingSafeFallbackCopy}, errors.New("incorrect signed_out state")
			}
		}
		resolved.Message = formatOnboardingMessage(row.Code, row.ID, row.Title, selectedOrDetectedVersion(row))
	} else {
		resolved.Message = formatOnboardingMessage(row.Code, row.ID, row.Title, "")
	}
	resolved.ConfigPath = row.ConfigPath
	resolved.RecoveryPath = row.RecoveryPath
	return resolved, nil
}

func selectedOrDetectedVersion(row onboardingCheck) string {
	if strings.TrimSpace(row.DetectedVersion) != "" {
		return row.DetectedVersion
	}
	for _, c := range row.Candidates {
		if c.Outcome == "selected" && strings.TrimSpace(c.Version) != "" {
			return c.Version
		}
	}
	return ""
}

func decodeAndValidatePreflightReport(raw []byte, platform string, nativeOverlay bool, verifiedCapability string) (onboardingPreflightReport, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		return onboardingPreflightReport{}, err
	}
	if top == nil {
		return onboardingPreflightReport{}, errors.New("report must be an object")
	}
	var report onboardingPreflightReport
	if err := json.Unmarshal(raw, &report); err != nil {
		return onboardingPreflightReport{}, err
	}
	_, report.hasRecommendedTransportKey = top["recommended_transport"]
	if report.Schema != onboardingPreflightSchemaV1 {
		return onboardingPreflightReport{}, fmt.Errorf("unsupported schema %q", report.Schema)
	}
	if report.OK == nil || report.Configured == nil || report.WorkspaceConfirmed == nil || report.ScanRootExists == nil || !report.hasRecommendedTransportKey {
		return onboardingPreflightReport{}, errors.New("missing required report field")
	}
	if report.Stage != "setup" && report.Stage != "pair" {
		return onboardingPreflightReport{}, fmt.Errorf("invalid stage %q", report.Stage)
	}
	if strings.TrimSpace(report.ConfigPath) == "" || strings.TrimSpace(report.ScanRoot) == "" || strings.TrimSpace(report.BrowseRoot) == "" {
		return onboardingPreflightReport{}, errors.New("missing required report path field")
	}
	if report.RecommendedTransport != nil && !slices.Contains(validTransports, *report.RecommendedTransport) {
		return onboardingPreflightReport{}, fmt.Errorf("invalid recommended_transport %q", *report.RecommendedTransport)
	}
	if !*report.Configured && *report.WorkspaceConfirmed {
		return onboardingPreflightReport{}, errors.New("unconfigured report cannot have workspace_confirmed=true")
	}
	if *report.OK && report.Stage == "pair" && (!*report.Configured || !*report.WorkspaceConfirmed || !*report.ScanRootExists) {
		return onboardingPreflightReport{}, errors.New("ready pair report requires configured, confirmed, existing workspace")
	}

	var rawChecks []json.RawMessage
	if err := json.Unmarshal(top["checks"], &rawChecks); err != nil {
		return onboardingPreflightReport{}, fmt.Errorf("invalid checks array: %w", err)
	}
	applicable := platformCheckIDs(platform)
	if len(rawChecks) != len(applicable) {
		return onboardingPreflightReport{}, fmt.Errorf("expected %d %s checks, got %d", len(applicable), platform, len(rawChecks))
	}

	report.Checks = make([]onboardingCheck, 0, len(rawChecks))
	seen := make(map[string]struct{}, len(rawChecks))
	firstBlocker := ""
	eligible := map[string]bool{}
	recommended := ""
	hasRec := false

	recTransport := ""
	if report.RecommendedTransport != nil {
		recTransport = *report.RecommendedTransport
	}

	for i, rawCheck := range rawChecks {
		row, err := decodeOnboardingCheck(rawCheck)
		if err != nil {
			return onboardingPreflightReport{}, fmt.Errorf("check[%d]: %w", i, err)
		}
		if _, dup := seen[row.ID]; dup {
			return onboardingPreflightReport{}, fmt.Errorf("duplicate check row %s", row.ID)
		}
		seen[row.ID] = struct{}{}
		if row.ID != applicable[i] {
			return onboardingPreflightReport{}, fmt.Errorf("expected %s at index %d, got %s", applicable[i], i, row.ID)
		}
		if row.State == "checking" {
			return onboardingPreflightReport{}, fmt.Errorf("unfinished checking row %s in completed report", row.ID)
		}
		surface := "check"
		if nativeOverlay && (strings.HasPrefix(row.ID, "permission_") || (row.ID == "service_daemon" && row.Code == "service_requires_approval")) {
			surface = "native"
		}
		ctx := onboardingValidationContext{
			Surface:                 surface,
			Platform:                platform,
			Stage:                   report.Stage,
			Configured:              report.Configured,
			HasRecommendedTransport: true,
			RecommendedTransport:    recTransport,
			VerifiedCapability:      verifiedCapability,
		}
		if _, err := validateOnboardingCheck(row, ctx); err != nil {
			return onboardingPreflightReport{}, fmt.Errorf("%s: %w", row.ID, err)
		}
		if *row.Blocking {
			if report.Stage == "setup" && row.Group != "workspace" {
				return onboardingPreflightReport{}, fmt.Errorf("unexpected setup blocker %s", row.ID)
			}
			if firstBlocker == "" {
				firstBlocker = row.ID
			}
		}
		if row.Enabled != nil {
			ready := *row.Enabled && row.Available != nil && *row.Available
			if (row.State == "ok") != ready {
				return onboardingPreflightReport{}, fmt.Errorf("%s intent/availability mismatch", row.ID)
			}
			eligible[row.Group] = eligible[row.Group] || ready
			if row.Group == "network" && !hasRec && row.Available != nil && *row.Available {
				recommended = strings.TrimPrefix(row.ID, "network_")
				hasRec = true
			}
		}
		if row.ID == "assistant_any" || row.ID == "network_any" {
			if (row.State == "ok") != eligible[row.Group] || *row.Blocking != (report.Stage == "pair" && !eligible[row.Group]) {
				return onboardingPreflightReport{}, fmt.Errorf("%s eligibility mismatch", row.ID)
			}
		}
		if report.Stage == "pair" && row.ID == "service_daemon" && *row.Blocking != (row.State != "ok") {
			return onboardingPreflightReport{}, errors.New("daemon readiness mismatch")
		}
		report.Checks = append(report.Checks, row)
	}
	if (report.RecommendedTransport == nil && hasRec) || (report.RecommendedTransport != nil && (!hasRec || *report.RecommendedTransport != recommended)) {
		return onboardingPreflightReport{}, errors.New("unexpected recommended_transport")
	}
	if *report.OK != (firstBlocker == "") {
		return onboardingPreflightReport{}, errors.New("report ok inconsistent with blockers")
	}
	expectedNext := firstBlocker
	if expectedNext == "" {
		expectedNext = "network_any"
		if report.Stage == "setup" && !*report.Configured {
			expectedNext = "config_store"
		}
	}
	if report.RecommendedNext != expectedNext {
		return onboardingPreflightReport{}, fmt.Errorf("expected recommended_next %s, got %s", expectedNext, report.RecommendedNext)
	}
	return report, nil
}

func platformCheckIDs(platform string) []string {
	ids := make([]string, 0, len(onboardingChecksCatalog))
	for _, spec := range onboardingChecksCatalog {
		if slices.Contains(spec.Platforms, platform) {
			ids = append(ids, spec.ID)
		}
	}
	return ids
}

func decodeOnboardingErrorEnvelope(raw []byte, ctx onboardingValidationContext) (onboardingResolvedDiagnostic, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, err
	}
	if top == nil {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, errors.New("envelope must be an object")
	}
	if ctx.Surface == "http" {
		for key := range top {
			if _, forbidden := httpForbiddenKeys[key]; forbidden {
				return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, fmt.Errorf("forbidden public field %q", key)
			}
		}
	}
	var env onboardingErrorEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, err
	}
	if env.OK == nil || *env.OK || env.Error == nil {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, errors.New("error envelope requires ok=false and error object")
	}
	var errFields map[string]json.RawMessage
	if err := json.Unmarshal(top["error"], &errFields); err != nil {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, err
	}
	if _, hasFix := errFields["fix"]; !hasFix {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, errors.New("error envelope missing fix")
	}
	if strings.TrimSpace(env.Error.Code) == "" || strings.TrimSpace(env.Error.Step) == "" || strings.TrimSpace(env.Error.Message) == "" {
		return onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}, errors.New("error envelope missing required fields")
	}
	if ctx.Surface == "http" {
		for key := range errFields {
			if _, forbidden := httpForbiddenKeys[key]; forbidden {
				return onboardingResolvedDiagnostic{Code: env.Error.Code, Step: env.Error.Step, Message: onboardingSafeFallbackCopy}, fmt.Errorf("forbidden public error field %q", key)
			}
		}
	} else {
		_, hasCfg := errFields["config_path"]
		_, hasRec := errFields["recovery_path"]
		if (hasCfg || hasRec) && !(env.Error.Fix.Kind == "open_settings" && env.Error.Fix.Target == "host_recovery") {
			return onboardingResolvedDiagnostic{Code: env.Error.Code, Step: env.Error.Step, Message: onboardingSafeFallbackCopy}, errors.New("recovery paths only allowed with host_recovery fix")
		}
	}
	resolved, err := validateOnboardingDiagnostic(env.Error.Code, env.Error.Step, env.Error.Fix, ctx, "")
	if err != nil {
		return resolved, err
	}
	resolved.ConfigPath = env.Error.ConfigPath
	resolved.RecoveryPath = env.Error.RecoveryPath
	return resolved, nil
}

func looksLikeOnboardingEnvelopeJSON(stdout []byte) bool {
	trimmed := bytes.TrimSpace(stdout)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return false
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &probe); err != nil {
		return false
	}
	okRaw, hasOK := probe["ok"]
	_, hasError := probe["error"]
	if !hasOK || !hasError {
		return false
	}
	var okVal bool
	return json.Unmarshal(okRaw, &okVal) == nil && !okVal
}

func isLegacyHostCLIOutput(stderr []byte) bool {
	lower := strings.ToLower(string(stderr))
	return (strings.Contains(lower, "unknown command") && strings.Contains(lower, "preflight")) ||
		(strings.Contains(lower, "未知命令") && strings.Contains(lower, "preflight")) ||
		strings.Contains(lower, "flag provided but not defined: -no-pair") ||
		strings.Contains(lower, "unknown flag: --no-pair")
}

func decodeTrayCommandError(stdout, stderr []byte, exitErr error, ctx onboardingValidationContext) error {
	if looksLikeOnboardingEnvelopeJSON(stdout) {
		resolved, err := decodeOnboardingErrorEnvelope(stdout, ctx)
		if err != nil {
			return &onboardingCLIError{
				Diagnostic: onboardingResolvedDiagnostic{
					Code:       resolved.Code,
					Step:       resolved.Step,
					Message:    onboardingSafeFallbackCopy,
					AllowedFix: nil,
					Trusted:    false,
				},
			}
		}
		return &onboardingCLIError{Diagnostic: resolved}
	}
	if isLegacyHostCLIOutput(stderr) {
		updateFix := desktopURLFix
		return &onboardingCLIError{
			Diagnostic: onboardingResolvedDiagnostic{
				Step:       "service_daemon",
				Message:    onboardingLegacyHostCopy,
				AllowedFix: &updateFix,
				Trusted:    true,
				LegacyHost: true,
			},
		}
	}
	return nil
}

func newTrayUILocalError(code, step, title string) *onboardingCLIError {
	if step == "" {
		step = "service_daemon"
	}
	ctx := onboardingValidationContext{Surface: "ui_local", Platform: "linux"}
	entry, ok := onboardingCodeIndex[code]
	if !ok || !entry.UILocal {
		return &onboardingCLIError{Diagnostic: onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}}
	}
	fix := entry.Variants[0].Fix
	resolved, err := validateOnboardingDiagnostic(code, step, fix, ctx, "")
	if err != nil {
		return &onboardingCLIError{Diagnostic: onboardingResolvedDiagnostic{Message: onboardingSafeFallbackCopy}}
	}
	resolved.Message = formatOnboardingMessage(code, step, title, "")
	return &onboardingCLIError{Diagnostic: resolved}
}

func decodeOnboardingSetupReceipt(raw []byte) (onboardingSetupReceipt, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		return onboardingSetupReceipt{}, err
	}
	if top == nil {
		return onboardingSetupReceipt{}, errors.New("setup receipt must be an object")
	}
	var receipt onboardingSetupReceipt
	if err := json.Unmarshal(raw, &receipt); err != nil {
		return onboardingSetupReceipt{}, err
	}
	// Legacy setup output (pre-BE-3): only has endpoint/pair_url/pair_expires_at without configured/created.
	if receipt.Configured == nil && receipt.Created == nil && strings.TrimSpace(receipt.PairURL) != "" {
		if !strings.HasPrefix(receipt.PairURL, "mimiremote://pair?") || strings.TrimSpace(receipt.Endpoint) == "" || strings.TrimSpace(receipt.PairExpiresAt) == "" {
			return onboardingSetupReceipt{}, errors.New("incomplete legacy setup ticket")
		}
		receipt.Legacy = true
		return receipt, nil
	}
	if receipt.OK == nil || !*receipt.OK || receipt.Configured == nil || !*receipt.Configured || receipt.Created == nil {
		return onboardingSetupReceipt{}, errors.New("setup receipt requires ok=true, configured=true, created")
	}
	if strings.TrimSpace(receipt.ConfigPath) == "" || strings.TrimSpace(receipt.ScanRoot) == "" || strings.TrimSpace(receipt.BrowseRoot) == "" {
		return onboardingSetupReceipt{}, errors.New("setup receipt missing required paths")
	}
	_, hasPairURL := top["pair_url"]
	_, hasPairExpires := top["pair_expires_at"]
	if receipt.PairingDeferred != nil && *receipt.PairingDeferred && (hasPairURL || hasPairExpires) {
		return onboardingSetupReceipt{}, errors.New("deferred setup receipt cannot contain ticket fields")
	}
	if hasPairURL {
		if !strings.HasPrefix(receipt.PairURL, "mimiremote://pair?") || strings.TrimSpace(receipt.Endpoint) == "" || strings.TrimSpace(receipt.PairExpiresAt) == "" {
			return onboardingSetupReceipt{}, errors.New("setup receipt ticket fields incomplete")
		}
		if _, err := time.Parse(time.RFC3339Nano, receipt.PairExpiresAt); err != nil {
			return onboardingSetupReceipt{}, err
		}
	}
	if receipt.Network != "" && !slices.Contains(validTransports, receipt.Network) {
		return onboardingSetupReceipt{}, fmt.Errorf("invalid setup network %q", receipt.Network)
	}
	return receipt, nil
}

func decodeOnboardingUpReadinessReceipt(raw []byte) (onboardingUpReadinessReceipt, error) {
	var receipt onboardingUpReadinessReceipt
	if err := json.Unmarshal(raw, &receipt); err != nil {
		return onboardingUpReadinessReceipt{}, err
	}
	if receipt.OK != nil && !*receipt.OK {
		return onboardingUpReadinessReceipt{}, errors.New("up receipt ok=false")
	}
	if receipt.ServiceOK == nil || !*receipt.ServiceOK || strings.TrimSpace(receipt.Version) == "" {
		return onboardingUpReadinessReceipt{}, errors.New("up receipt does not confirm authenticated readiness")
	}
	return receipt, nil
}

func decodeOnboardingPairingTicketReceipt(raw []byte, requireNetwork bool) (onboardingPairingTicketReceipt, error) {
	var receipt onboardingPairingTicketReceipt
	if err := json.Unmarshal(raw, &receipt); err != nil {
		return onboardingPairingTicketReceipt{}, err
	}
	if receipt.OK != nil && !*receipt.OK {
		return onboardingPairingTicketReceipt{}, errors.New("pairing receipt ok=false")
	}
	if strings.TrimSpace(receipt.Endpoint) == "" || !strings.HasPrefix(receipt.PairURL, "mimiremote://pair?") {
		return onboardingPairingTicketReceipt{}, errors.New("pairing receipt missing endpoint or valid pair_url")
	}
	if _, err := url.Parse(receipt.PairURL); err != nil {
		return onboardingPairingTicketReceipt{}, err
	}
	if !strings.HasSuffix(receipt.PairExpiresAt, "Z") {
		if _, err := time.Parse(time.RFC3339Nano, receipt.PairExpiresAt); err != nil {
			return onboardingPairingTicketReceipt{}, err
		}
	} else if _, err := time.Parse(time.RFC3339Nano, receipt.PairExpiresAt); err != nil {
		return onboardingPairingTicketReceipt{}, err
	}
	if receipt.Network != "" && !slices.Contains(validTransports, receipt.Network) {
		return onboardingPairingTicketReceipt{}, fmt.Errorf("invalid transport %q", receipt.Network)
	}
	if requireNetwork && receipt.Network == "" {
		return onboardingPairingTicketReceipt{}, errors.New("pairing receipt missing network")
	}
	return receipt, nil
}

// onboardingProgressAccumulator applies out-of-order NDJSON progress checks while
// ensuring cancelled or superseded runs never overwrite a terminal state.
type onboardingProgressAccumulator struct {
	mu          sync.Mutex
	order       []string
	byID        map[string]onboardingCheck
	finalReport *onboardingPreflightReport
	terminal    bool
	generation  uint64
}

func newOnboardingProgressAccumulator(generation uint64) *onboardingProgressAccumulator {
	return &onboardingProgressAccumulator{
		byID:       make(map[string]onboardingCheck),
		generation: generation,
	}
}

func (a *onboardingProgressAccumulator) ApplyLine(generation uint64, line []byte) bool {
	trimmed := bytes.TrimSpace(line)
	if len(trimmed) == 0 {
		return false
	}
	row, err := decodeOnboardingCheck(trimmed)
	if err != nil {
		return false
	}
	if _, known := onboardingCheckIndex[row.ID]; !known || !slices.Contains(validCheckStates, row.State) {
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.terminal || generation != a.generation {
		return false
	}
	if _, exists := a.byID[row.ID]; !exists {
		a.order = append(a.order, row.ID)
	}
	a.byID[row.ID] = row
	return true
}

func (a *onboardingProgressAccumulator) ApplyStream(generation uint64, reader io.Reader) int {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	applied := 0
	for scanner.Scan() {
		if a.ApplyLine(generation, scanner.Bytes()) {
			applied++
		}
	}
	return applied
}

func (a *onboardingProgressAccumulator) Complete(generation uint64, report onboardingPreflightReport) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.terminal || generation != a.generation {
		return false
	}
	copyReport := report
	a.finalReport = &copyReport
	a.order = make([]string, 0, len(report.Checks))
	a.byID = make(map[string]onboardingCheck, len(report.Checks))
	for _, check := range report.Checks {
		a.order = append(a.order, check.ID)
		a.byID[check.ID] = check
	}
	a.terminal = true
	return true
}

func (a *onboardingProgressAccumulator) Cancel(generation uint64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.terminal || generation != a.generation {
		return
	}
	a.generation++
}

func (a *onboardingProgressAccumulator) Snapshot() ([]onboardingCheck, *onboardingPreflightReport) {
	a.mu.Lock()
	defer a.mu.Unlock()
	rows := make([]onboardingCheck, 0, len(a.order))
	for _, id := range a.order {
		rows = append(rows, a.byID[id])
	}
	var rep *onboardingPreflightReport
	if a.finalReport != nil {
		copyRep := *a.finalReport
		rep = &copyRep
	}
	return rows, rep
}

var trayOnboardingSecretPattern = regexp.MustCompile(`(?i)(token|secret|password|authorization|capability|pair_sig|private[_ -]?key|bearer\s|mimiremote://)`)

func redactOnboardingFallback(text string) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	for i, line := range lines {
		if trayOnboardingSecretPattern.MatchString(line) {
			lines[i] = "[已隐藏包含凭据的内容]"
		}
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func trayValidationContextForArgs(platform string, args []string) onboardingValidationContext {
	configured := true
	stage := "pair"
	if len(args) > 0 && (args[0] == "setup" || args[0] == "preflight") {
		stage = "setup"
	}
	return onboardingValidationContext{
		Surface:    "cli",
		Platform:   platform,
		Stage:      stage,
		Configured: &configured,
	}
}

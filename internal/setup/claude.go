package setup

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const claudeBinaryEnvKey = "CLAUDE_BRIDGE_CLAUDE_BIN"

type ClaudeActivationPreference string

const (
	ClaudeActivationAuto     ClaudeActivationPreference = "auto"
	ClaudeActivationEnabled  ClaudeActivationPreference = "enabled"
	ClaudeActivationDisabled ClaudeActivationPreference = "disabled"
)

type ClaudeConfigurationResult struct {
	Enabled            bool                       `json:"claude_enabled"`
	Available          bool                       `json:"available"`
	Preference         ClaudeActivationPreference `json:"preference"`
	PreviousEnabled    bool                       `json:"previous_enabled"`
	PreviousPreference ClaudeActivationPreference `json:"previous_preference"`
	Changed            bool                       `json:"changed"`
	RestartRequired    bool                       `json:"restart_required"`
	ClaudeBin          string                     `json:"claude_bin,omitempty"`
	ClaudeVersion      string                     `json:"claude_version,omitempty"`
	LoggedIn           *bool                      `json:"logged_in,omitempty"`
	ProxyConfigured    bool                       `json:"proxy_configured"`
	SystemProxyEnabled bool                       `json:"system_proxy_enabled"`
	ProxyMismatch      bool                       `json:"proxy_mismatch"`
	Reason             string                     `json:"reason"`
	Message            string                     `json:"message"`
}

type claudePreflightResult struct {
	OK                 bool
	ClaudeBin          string
	ClaudeVersion      string
	LoggedIn           *bool
	ProxyConfigured    bool
	SystemProxyEnabled bool
	ProxyMismatch      bool
	Reason             string
	Message            string
}

func ParseClaudeActivationPreference(raw string) (ClaudeActivationPreference, error) {
	preference := ClaudeActivationPreference(strings.ToLower(strings.TrimSpace(raw)))
	switch preference {
	case ClaudeActivationAuto, ClaudeActivationEnabled, ClaudeActivationDisabled:
		return preference, nil
	default:
		return "", fmt.Errorf("Claude 启用策略只支持 auto、enabled 或 disabled，实际为 %q", raw)
	}
}

// ConfigureClaude 只更新 claude.enabled、claude.activation 和检测到的 Claude CLI
// 绝对路径。其余配置（包括 Token、bridge 参数和未来字段）按原 JSON 原样保留。
// restoreEnabled 仅供 Mac App 在服务重载失败时恢复调用前状态。
func ConfigureClaude(
	ctx context.Context,
	configPath string,
	requested ClaudeActivationPreference,
	restoreEnabled *bool,
) (ClaudeConfigurationResult, error) {
	requested, err := ParseClaudeActivationPreference(string(requested))
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return ClaudeConfigurationResult{}, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return ClaudeConfigurationResult{}, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}

	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return ClaudeConfigurationResult{}, fmt.Errorf("读取配置文件失败：%w", err)
	}
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return ClaudeConfigurationResult{}, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return ClaudeConfigurationResult{}, fmt.Errorf("配置文件必须是 JSON object")
	}
	claudeDocument, err := decodeClaudeDocument(document)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	currentEnabled, err := decodeClaudeEnabled(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	previousPreference, err := decodeClaudePreference(claudeDocument, currentEnabled)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	result := ClaudeConfigurationResult{
		Enabled:            currentEnabled,
		Preference:         previousPreference,
		PreviousEnabled:    currentEnabled,
		PreviousPreference: previousPreference,
	}

	// 启动阶段的 auto 不能覆盖用户已经在设置页做出的明确选择。
	targetPreference := requested
	if restoreEnabled == nil && requested == ClaudeActivationAuto && previousPreference != ClaudeActivationAuto {
		targetPreference = previousPreference
	}

	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	targetEnabled := currentEnabled
	preflight := claudePreflightResult{}
	if restoreEnabled != nil {
		targetEnabled = *restoreEnabled
		preflight = claudePreflightResult{
			OK:      targetEnabled,
			Reason:  "restored",
			Message: "已恢复 Claude 设置。",
		}
	} else {
		switch targetPreference {
		case ClaudeActivationDisabled:
			targetEnabled = false
			preflight = claudePreflightResult{
				Reason:  "disabled_by_user",
				Message: "Claude 实验通道已关闭；后续启动不会自动重新启用。",
			}
		case ClaudeActivationAuto, ClaudeActivationEnabled:
			preflight = preflightClaude(ctx, cfg)
			result.ClaudeBin = preflight.ClaudeBin
			result.ClaudeVersion = preflight.ClaudeVersion
			result.LoggedIn = preflight.LoggedIn
			result.ProxyConfigured = preflight.ProxyConfigured
			result.SystemProxyEnabled = preflight.SystemProxyEnabled
			result.ProxyMismatch = preflight.ProxyMismatch
			if preflight.OK {
				targetEnabled = true
			} else if requested == ClaudeActivationEnabled {
				// 用户手动开启但前置条件不满足时不落盘，让 Toggle 回到真实状态。
				result.Available = false
				result.Reason = preflight.Reason
				result.Message = preflight.Message
				return result, nil
			} else {
				// 启动检测始终 fail closed；保留明确偏好，后续环境恢复时可自动重新启用。
				targetEnabled = false
			}
		}
	}

	currentClaudeBin, err := decodeClaudeBinary(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	targetClaudeBin := currentClaudeBin
	if targetEnabled && preflight.ClaudeBin != "" {
		targetClaudeBin = preflight.ClaudeBin
	}
	if err := encodeClaudeDocument(
		claudeDocument,
		targetEnabled,
		targetPreference,
		targetClaudeBin,
	); err != nil {
		return ClaudeConfigurationResult{}, err
	}
	encodedClaude, err := json.Marshal(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, fmt.Errorf("编码 claude 配置失败：%w", err)
	}
	document["claude"] = encodedClaude
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return ClaudeConfigurationResult{}, fmt.Errorf("编码配置文件失败：%w", err)
	}
	updated = append(updated, '\n')
	changed := string(updated) != string(original)
	if changed {
		if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
			return ClaudeConfigurationResult{}, fmt.Errorf("原子更新配置文件失败：%w", err)
		}
	}

	result.Enabled = targetEnabled
	result.Available = preflight.OK
	result.Preference = targetPreference
	result.Changed = changed
	result.RestartRequired = currentEnabled != targetEnabled || currentClaudeBin != targetClaudeBin
	result.ClaudeBin = preflight.ClaudeBin
	result.ClaudeVersion = preflight.ClaudeVersion
	result.LoggedIn = preflight.LoggedIn
	result.ProxyConfigured = preflight.ProxyConfigured
	result.SystemProxyEnabled = preflight.SystemProxyEnabled
	result.ProxyMismatch = preflight.ProxyMismatch
	result.Reason = preflight.Reason
	result.Message = preflight.Message
	if targetEnabled && preflight.OK && preflight.Message == "" {
		result.Reason = "ready"
		result.Message = "已检测到 Claude Code 和兼容的 Claude bridge。"
	}
	return result, nil
}

func decodeClaudeDocument(document map[string]json.RawMessage) (map[string]json.RawMessage, error) {
	claudeDocument := map[string]json.RawMessage{}
	if rawClaude, ok := document["claude"]; ok && string(rawClaude) != "null" {
		if err := json.Unmarshal(rawClaude, &claudeDocument); err != nil {
			return nil, fmt.Errorf("解析 claude 配置失败：%w", err)
		}
		if claudeDocument == nil {
			claudeDocument = map[string]json.RawMessage{}
		}
	}
	return claudeDocument, nil
}

func decodeClaudeEnabled(document map[string]json.RawMessage) (bool, error) {
	current := false
	if raw, ok := document["enabled"]; ok {
		if err := json.Unmarshal(raw, &current); err != nil {
			return false, fmt.Errorf("解析 claude.enabled 失败：%w", err)
		}
	}
	return current, nil
}

func decodeClaudePreference(
	document map[string]json.RawMessage,
	enabled bool,
) (ClaudeActivationPreference, error) {
	if raw, ok := document["activation"]; ok {
		var value string
		if err := json.Unmarshal(raw, &value); err != nil {
			return "", fmt.Errorf("解析 claude.activation 失败：%w", err)
		}
		return ParseClaudeActivationPreference(value)
	}
	// 老版本没有设置入口；enabled=true 只可能来自用户手动配置，必须视为明确开启。
	if enabled {
		return ClaudeActivationEnabled, nil
	}
	return ClaudeActivationAuto, nil
}

func decodeClaudeBinary(document map[string]json.RawMessage) (string, error) {
	rawEnv, ok := document["env"]
	if !ok || string(rawEnv) == "null" {
		return "", nil
	}
	env := map[string]json.RawMessage{}
	if err := json.Unmarshal(rawEnv, &env); err != nil {
		return "", fmt.Errorf("解析 claude.env 失败：%w", err)
	}
	raw, ok := env[claudeBinaryEnvKey]
	if !ok {
		return "", nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", fmt.Errorf("解析 claude.env.%s 失败：%w", claudeBinaryEnvKey, err)
	}
	return strings.TrimSpace(value), nil
}

func encodeClaudeDocument(
	document map[string]json.RawMessage,
	enabled bool,
	preference ClaudeActivationPreference,
	claudeBin string,
) error {
	encodedEnabled, _ := json.Marshal(enabled)
	encodedPreference, _ := json.Marshal(preference)
	document["enabled"] = encodedEnabled
	document["activation"] = encodedPreference
	if claudeBin == "" {
		return nil
	}
	env := map[string]json.RawMessage{}
	if rawEnv, ok := document["env"]; ok && string(rawEnv) != "null" {
		if err := json.Unmarshal(rawEnv, &env); err != nil {
			return fmt.Errorf("解析 claude.env 失败：%w", err)
		}
		if env == nil {
			env = map[string]json.RawMessage{}
		}
	}
	encodedBin, _ := json.Marshal(claudeBin)
	env[claudeBinaryEnvKey] = encodedBin
	encodedEnv, err := json.Marshal(env)
	if err != nil {
		return fmt.Errorf("编码 claude.env 失败：%w", err)
	}
	document["env"] = encodedEnv
	return nil
}

func preflightClaude(ctx context.Context, cfg config.Config) claudePreflightResult {
	commandEnvironment := claudeCommandEnvironment(cfg.Claude.Env)
	proxyConfigured := claudeProxyConfigured(commandEnvironment)
	systemProxyEnabled := claudeSystemProxyConfigured()
	proxyMismatch := systemProxyEnabled && !proxyConfigured
	baseResult := claudePreflightResult{
		ProxyConfigured:    proxyConfigured,
		SystemProxyEnabled: systemProxyEnabled,
		ProxyMismatch:      proxyMismatch,
	}
	bridge, ok := claudebridge.ResolveBinary(cfg.Claude.BridgeBin)
	if !ok {
		baseResult.Reason = "bridge_missing"
		baseResult.Message = "App 内没有可用的 Claude bridge，请重新安装 Mimi Remote。"
		return baseResult
	}
	bridgeCtx, cancelBridge := context.WithTimeout(ctx, 2*time.Second)
	bridgeCommand := exec.CommandContext(
		bridgeCtx,
		bridge,
		append(append([]string{}, cfg.Claude.Args...), "--version")...,
	)
	bridgeCommand.Env = commandEnvironment
	bridgeVersionOutput, bridgeErr := bridgeCommand.Output()
	cancelBridge()
	bridgeVersion, parsed := claudebridge.ParseVersion(string(bridgeVersionOutput))
	if bridgeErr != nil || !parsed {
		baseResult.Reason = "bridge_version_unknown"
		baseResult.Message = "无法确认 Claude bridge 版本，请重新安装 Mimi Remote。"
		return baseResult
	}
	if !claudebridge.IsSupported(bridgeVersion) {
		baseResult.Reason = "bridge_unsupported"
		baseResult.Message = "Claude bridge 版本不兼容，请升级 Mimi Remote。"
		return baseResult
	}

	configuredClaudeBin := strings.TrimSpace(cfg.Claude.Env[claudeBinaryEnvKey])
	claudeBin, err := resolveClaudeBin(configuredClaudeBin)
	if err != nil {
		baseResult.Reason = "claude_missing"
		baseResult.Message = "未检测到 Claude Code。安装并登录后，重新打开 Mimi Remote 即可自动启用。"
		return baseResult
	}
	baseResult.ClaudeBin = claudeBin
	claudeVersion, err := probeClaudeVersion(ctx, claudeBin, commandEnvironment)
	if err != nil {
		baseResult.Reason = "claude_version_unknown"
		baseResult.Message = "检测到 Claude Code，但无法确认版本。请重新安装或升级 Claude Code。"
		return baseResult
	}
	baseResult.ClaudeVersion = claudeVersion
	authCtx, cancelAuth := context.WithTimeout(ctx, 5*time.Second)
	authCommand := exec.CommandContext(authCtx, claudeBin, "auth", "status")
	authCommand.Env = commandEnvironment
	authCommand.Stderr = io.Discard
	authOutput, authErr := authCommand.Output()
	cancelAuth()
	loggedIn, parsedAuth := parseClaudeAuthStatus(authOutput)
	if parsedAuth {
		baseResult.LoggedIn = &loggedIn
	}
	if parsedAuth && !loggedIn {
		baseResult.Reason = "claude_signed_out"
		baseResult.Message = "已检测到 Claude Code，但尚未登录。请先在 Claude Code 中完成登录。"
		return baseResult
	}
	if authErr != nil || !parsedAuth {
		baseResult.Reason = "claude_auth_status_failed"
		baseResult.Message = "已检测到 Claude Code，但无法确认登录状态。请在终端运行 claude auth status 查看具体原因。"
		return baseResult
	}
	baseResult.OK = true
	baseResult.Reason = "ready"
	baseResult.Message = fmt.Sprintf("已检测到 Claude Code %s 和兼容的 Claude bridge。", claudeVersion)
	if proxyMismatch {
		baseResult.Message += " Windows 系统代理已启用，但 Claude 进程未配置 HTTP(S)_PROXY；如直连不可用，请重启 Mimi Remote 以继承用户代理环境。"
	}
	return baseResult
}

func resolveClaudeBin(configured string) (string, error) {
	candidates := claudeExecutableCandidates(configured)
	seen := map[string]struct{}{}
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}
		resolved, err := lookupUsableCodexExecutable(candidate)
		if err != nil {
			continue
		}
		absolute, err := filepath.Abs(resolved)
		if err == nil {
			return filepath.Clean(absolute), nil
		}
	}
	return "", exec.ErrNotFound
}

func probeClaudeVersion(ctx context.Context, claudeBin string, environment []string) (string, error) {
	versionCtx, cancelVersion := context.WithTimeout(ctx, 3*time.Second)
	defer cancelVersion()
	command := exec.CommandContext(versionCtx, claudeBin, "--version")
	command.Env = environment
	output, err := command.Output()
	if err != nil {
		return "", err
	}
	version, ok := claudebridge.ParseVersion(string(output))
	if !ok {
		return "", fmt.Errorf("无法解析 Claude Code 版本")
	}
	return version, nil
}

func parseClaudeAuthStatus(output []byte) (bool, bool) {
	status := struct {
		LoggedIn *bool `json:"loggedIn"`
	}{}
	if err := json.Unmarshal(output, &status); err != nil || status.LoggedIn == nil {
		return false, false
	}
	return *status.LoggedIn, true
}

func claudeProxyConfigured(environment []string) bool {
	for _, item := range environment {
		key, value, ok := strings.Cut(item, "=")
		if !ok || strings.TrimSpace(value) == "" {
			continue
		}
		switch strings.ToUpper(strings.TrimSpace(key)) {
		case "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY":
			return true
		}
	}
	return false
}

func claudeCommandEnvironment(extra map[string]string) []string {
	environment := append([]string{}, os.Environ()...)
	type environmentValue struct {
		key   string
		value string
	}
	values := map[string]environmentValue{}
	for _, item := range environment {
		if key, value, ok := strings.Cut(item, "="); ok {
			values[claudeEnvironmentKey(key)] = environmentValue{key: key, value: value}
		}
	}
	for key, value := range extra {
		key = strings.TrimSpace(key)
		if key != "" && !strings.Contains(key, "=") {
			values[claudeEnvironmentKey(key)] = environmentValue{key: key, value: value}
		}
	}
	const bypassKey = "CLAUDE_BRIDGE_BYPASS_PERMISSIONS"
	values[claudeEnvironmentKey(bypassKey)] = environmentValue{key: bypassKey, value: "false"}
	environment = environment[:0]
	for _, entry := range values {
		environment = append(environment, entry.key+"="+entry.value)
	}
	return environment
}

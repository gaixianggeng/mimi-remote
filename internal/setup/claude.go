package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"reflect"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/claudeenv"
	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
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
	SystemProxyKnown   bool                       `json:"system_proxy_known"`
	SystemProxySource  string                     `json:"system_proxy_source,omitempty"`
	ProxyMismatch      bool                       `json:"proxy_mismatch"`
	Reason             string                     `json:"reason"`
	Message            string                     `json:"message"`
	TurnHintsEnabled   bool                       `json:"turn_hints_enabled"`
	Previous           ClaudeModuleState          `json:"previous"`
	Applied            ClaudeModuleState          `json:"applied"`
}

// ClaudeModuleState 只记录 ConfigureClaude 会修改的字段。回滚比较这些字段，
// 既能拒绝覆盖其他写者的新意图，也允许无关配置并发更新后继续安全恢复。
type ClaudeModuleState struct {
	Enabled            *bool                       `json:"enabled,omitempty"`
	Activation         *ClaudeActivationPreference `json:"activation,omitempty"`
	ClaudeBin          *string                     `json:"claude_bin,omitempty"`
	EnvironmentPresent bool                        `json:"environment_present"`
}

type claudePreflightResult struct {
	OK                 bool
	ClaudeBin          string
	ClaudeVersion      string
	LoggedIn           *bool
	ProxyConfigured    bool
	SystemProxyEnabled bool
	SystemProxyKnown   bool
	SystemProxySource  string
	ProxyMismatch      bool
	Reason             string
	Message            string
}

type claudeSystemProxyDetection struct {
	Enabled bool
	Known   bool
	Source  string
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
	original, err := readPrivateConfig(cfgPath)
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
	previousState, err := claudeModuleState(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	result := ClaudeConfigurationResult{
		Enabled:            currentEnabled,
		Preference:         previousPreference,
		PreviousEnabled:    currentEnabled,
		PreviousPreference: previousPreference,
		Previous:           previousState,
		Applied:            previousState,
	}
	turnHintsState, err := claudeTurnHintsState(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	result.TurnHintsEnabled = effectiveClaudeTurnHints(turnHintsState)

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
			result.SystemProxyKnown = preflight.SystemProxyKnown
			result.SystemProxySource = preflight.SystemProxySource
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
	if err := encodeClaudeDocument(
		claudeDocument,
		targetEnabled,
		targetPreference,
		currentClaudeBin,
	); err != nil {
		return ClaudeConfigurationResult{}, err
	}
	appliedState, err := claudeModuleState(claudeDocument)
	if err != nil {
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
	result.Applied = appliedState
	result.Changed = changed
	result.RestartRequired = currentEnabled != targetEnabled
	result.ClaudeBin = preflight.ClaudeBin
	result.ClaudeVersion = preflight.ClaudeVersion
	result.LoggedIn = preflight.LoggedIn
	result.ProxyConfigured = preflight.ProxyConfigured
	result.SystemProxyEnabled = preflight.SystemProxyEnabled
	result.SystemProxyKnown = preflight.SystemProxyKnown
	result.SystemProxySource = preflight.SystemProxySource
	result.ProxyMismatch = preflight.ProxyMismatch
	result.Reason = preflight.Reason
	result.Message = preflight.Message
	if targetEnabled && preflight.OK && preflight.Message == "" {
		result.Reason = "ready"
		result.Message = "已检测到 Claude Code 和兼容的 Claude bridge。"
	}
	return result, nil
}

// RestoreClaude 只在当前受控字段仍等于本次操作的 Applied 快照时恢复 Previous。
// 读取后的写入继续使用文件 CAS，覆盖“比较后、提交前”插入的并发修改。
func RestoreClaude(configPath string, previous ClaudeConfigurationResult) (ClaudeConfigurationResult, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	original, err := readPrivateConfig(cfgPath)
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
	currentState, err := claudeModuleState(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	if !reflect.DeepEqual(currentState, previous.Applied) {
		return ClaudeConfigurationResult{}, fmt.Errorf("Claude 设置已被其他操作修改，未覆盖新的设置；请刷新后重试")
	}
	currentEnabled, err := decodeClaudeEnabled(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	currentPreference, err := decodeClaudePreference(claudeDocument, currentEnabled)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	currentBin, err := decodeClaudeBinary(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	if err := applyClaudeModuleState(claudeDocument, previous.Previous); err != nil {
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
	changed := !bytes.Equal(original, updated)
	if changed {
		if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
			return ClaudeConfigurationResult{}, fmt.Errorf("原子恢复配置文件失败：%w", err)
		}
	}
	restoredEnabled, err := decodeClaudeEnabled(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	restoredPreference, err := decodeClaudePreference(claudeDocument, restoredEnabled)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	restoredBin, err := decodeClaudeBinary(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	restoredTurnHintsState, err := claudeTurnHintsState(claudeDocument)
	if err != nil {
		return ClaudeConfigurationResult{}, err
	}
	return ClaudeConfigurationResult{
		Enabled: restoredEnabled, Available: restoredEnabled, Preference: restoredPreference,
		PreviousEnabled: currentEnabled, PreviousPreference: currentPreference,
		Changed:         changed,
		RestartRequired: currentEnabled != restoredEnabled || currentBin != restoredBin,
		ClaudeBin:       restoredBin, Reason: "restored", Message: "已恢复修改前的 Claude 设置。",
		TurnHintsEnabled: effectiveClaudeTurnHints(restoredTurnHintsState),
		Previous:         currentState, Applied: previous.Previous,
	}, nil
}

func claudeModuleState(document map[string]json.RawMessage) (ClaudeModuleState, error) {
	state := ClaudeModuleState{}
	if raw, ok := document["enabled"]; ok {
		var enabled bool
		if err := json.Unmarshal(raw, &enabled); err != nil {
			return state, fmt.Errorf("解析 claude.enabled 失败：%w", err)
		}
		state.Enabled = &enabled
	}
	if raw, ok := document["activation"]; ok {
		var value string
		if err := json.Unmarshal(raw, &value); err != nil {
			return state, fmt.Errorf("解析 claude.activation 失败：%w", err)
		}
		preference, err := ParseClaudeActivationPreference(value)
		if err != nil {
			return state, err
		}
		state.Activation = &preference
	}
	rawEnv, hasEnv := document["env"]
	state.EnvironmentPresent = hasEnv && string(rawEnv) != "null"
	if !state.EnvironmentPresent {
		return state, nil
	}
	env := map[string]json.RawMessage{}
	if err := json.Unmarshal(rawEnv, &env); err != nil {
		return state, fmt.Errorf("解析 claude.env 失败：%w", err)
	}
	if raw, ok := env[claudeBinaryEnvKey]; ok {
		var value string
		if err := json.Unmarshal(raw, &value); err != nil {
			return state, fmt.Errorf("解析 claude.env.%s 失败：%w", claudeBinaryEnvKey, err)
		}
		state.ClaudeBin = &value
	}
	return state, nil
}

func applyClaudeModuleState(document map[string]json.RawMessage, state ClaudeModuleState) error {
	if state.Enabled == nil {
		delete(document, "enabled")
	} else {
		document["enabled"], _ = json.Marshal(*state.Enabled)
	}
	if state.Activation == nil {
		delete(document, "activation")
	} else {
		document["activation"], _ = json.Marshal(*state.Activation)
	}
	env := map[string]json.RawMessage{}
	if rawEnv, ok := document["env"]; ok && string(rawEnv) != "null" {
		if err := json.Unmarshal(rawEnv, &env); err != nil {
			return fmt.Errorf("解析 claude.env 失败：%w", err)
		}
	}
	if state.ClaudeBin == nil {
		delete(env, claudeBinaryEnvKey)
	} else {
		env[claudeBinaryEnvKey], _ = json.Marshal(*state.ClaudeBin)
	}
	if len(env) == 0 && !state.EnvironmentPresent {
		delete(document, "env")
		return nil
	}
	encodedEnv, err := json.Marshal(env)
	if err != nil {
		return fmt.Errorf("编码 claude.env 失败：%w", err)
	}
	document["env"] = encodedEnv
	return nil
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
	proxyConfigured := claudeenv.HasSupportedProxy(commandEnvironment)
	systemProxy := claudeSystemProxyStatus()
	proxyMismatch := systemProxy.Known && systemProxy.Enabled && !proxyConfigured
	baseResult := claudePreflightResult{
		ProxyConfigured:    proxyConfigured,
		SystemProxyEnabled: systemProxy.Enabled,
		SystemProxyKnown:   systemProxy.Known,
		SystemProxySource:  systemProxy.Source,
		ProxyMismatch:      proxyMismatch,
	}
	bridge, ok := claudebridge.ResolveBinary(cfg.Claude.BridgeBin, cfg.Claude.LegacyBridge)
	if !ok {
		baseResult.Reason = "bridge_missing"
		baseResult.Message = "App 内没有可用的 Claude bridge，请重新安装 Mimi Remote。"
		return baseResult
	}
	bridgeCtx, cancelBridge := context.WithTimeout(ctx, 2*time.Second)
	bridgeVersionOutput, bridgeErr := cliinspect.Stdout(bridgeCtx, bridge, commandEnvironment,
		append(append([]string{}, cfg.Claude.Args...), "--version")...)
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
	// SDK 适配器（#660 起默认）声明了它要求的 Claude Code 最低版本。
	var adapter *claudebridge.AdapterCapabilities
	if claudebridge.IsAdapterVersionOutput(string(bridgeVersionOutput)) {
		capabilities, err := claudebridge.ReadAdapterCapabilities(ctx, bridge, cfg.Claude.Args, commandEnvironment)
		if err != nil {
			baseResult.Reason = "bridge_capabilities_unknown"
			baseResult.Message = "无法读取 Claude 适配器的能力声明，请重新安装 Mimi Remote。"
			return baseResult
		}
		adapter = &capabilities
	}

	minimum := ""
	if adapter != nil {
		minimum = adapter.ClaudeCode.MinimumVersion
	}
	claude, err := ResolveRuntime(ctx, ClaudeRuntime(cfg.Claude, minimum, commandEnvironment))
	baseResult.ClaudeBin, baseResult.ClaudeVersion = claude.Path, claude.Version
	if err != nil {
		switch {
		case errors.Is(err, ErrRuntimeIncompatible):
			baseResult.Reason = "claude_unsupported"
			baseResult.Message = claudebridge.ClaudeCodeUpgradeMessage(claude.Version, minimum)
		case errors.Is(err, ErrRuntimeVersion):
			baseResult.Reason = "claude_version_unknown"
			baseResult.Message = "检测到 Claude Code，但无法确认版本。请重新安装或升级 Claude Code。"
		default:
			baseResult.Reason = "claude_missing"
			baseResult.Message = "未检测到 Claude Code。请检查配置的路径或安装 Claude Code。"
		}
		return baseResult
	}
	claudeBin, claudeVersion := claude.Path, claude.Version
	loggedIn, authErr := probeClaudeAuthStatus(ctx, claudeBin, commandEnvironment, 5*time.Second)
	baseResult.LoggedIn = loggedIn
	if authErr != nil {
		baseResult.Reason = "claude_auth_status_failed"
		baseResult.Message = "已检测到 Claude Code，但无法确认登录状态。请在终端运行 claude auth status 查看具体原因。"
		return baseResult
	}
	if loggedIn == nil || !*loggedIn {
		baseResult.Reason = "claude_signed_out"
		baseResult.Message = "已检测到 Claude Code，但尚未登录。请先在 Claude Code 中完成登录。"
		return baseResult
	}
	baseResult.OK = true
	baseResult.Reason = "ready"
	baseResult.Message = fmt.Sprintf("已检测到 Claude Code %s 和兼容的 Claude bridge。", claudeVersion)
	if proxyMismatch {
		baseResult.Message += " Windows 用户代理已启用，但 Claude 进程未配置受支持的 HTTP(S) 代理；请设置 HTTPS_PROXY/HTTP_PROXY 或 claude.env 后完全重启 Mimi Remote。"
	}
	return baseResult
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

func probeClaudeAuthStatus(
	ctx context.Context,
	claudeBin string,
	environment []string,
	deadline time.Duration,
) (*bool, error) {
	authCtx, cancelAuth := context.WithTimeout(ctx, deadline)
	authCommand := exec.CommandContext(authCtx, claudeBin, "auth", "status")
	authCommand.Env = environment
	var authOutput bytes.Buffer
	authCommand.Stdout = &authOutput
	authCommand.Stderr = io.Discard
	// Command.Output 的内部 pipe 会在超时杀进程时丢掉已经读到的短输出。
	// 直接写入本地 buffer，保留 loggedIn 作为诊断，但仍以 timeout 作为结果分类。
	authErr := authCommand.Run()
	authContextErr := authCtx.Err()
	cancelAuth()

	loggedIn, parsedAuth := parseClaudeAuthStatus(authOutput.Bytes())
	var result *bool
	if parsedAuth {
		result = &loggedIn
	}
	if authErr != nil && authContextErr != nil {
		return result, authContextErr
	}
	if !parsedAuth {
		return nil, fmt.Errorf("Claude auth status 未返回有效 JSON")
	}
	if authErr == nil {
		return result, nil
	}
	var exitError *exec.ExitError
	if !loggedIn && errors.As(authErr, &exitError) && exitError.ExitCode() == 1 {
		return result, nil
	}
	return result, authErr
}

func claudeCommandEnvironment(extra map[string]string) []string {
	return claudeenv.Build(extra)
}

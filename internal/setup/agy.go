package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type AgyActivationPreference string

const (
	AgyActivationAuto     AgyActivationPreference = "auto"
	AgyActivationEnabled  AgyActivationPreference = "enabled"
	AgyActivationDisabled AgyActivationPreference = "disabled"
)

type AgyConfigurationResult struct {
	Enabled            bool                    `json:"agy_enabled"`
	Available          bool                    `json:"available"`
	Preference         AgyActivationPreference `json:"preference"`
	PreviousEnabled    bool                    `json:"previous_enabled"`
	PreviousPreference AgyActivationPreference `json:"previous_preference"`
	Changed            bool                    `json:"changed"`
	RestartRequired    bool                    `json:"restart_required"`
	AgyBin             string                  `json:"agy_bin,omitempty"`
	AgyVersion         string                  `json:"agy_version,omitempty"`
	LoggedIn           *bool                   `json:"logged_in,omitempty"`
	Reason             string                  `json:"reason"`
	Message            string                  `json:"message"`
	Previous           AgyModuleState          `json:"previous"`
	Applied            AgyModuleState          `json:"applied"`
}

type AgyModuleState struct {
	Enabled            *bool                    `json:"enabled,omitempty"`
	Activation         *AgyActivationPreference `json:"activation,omitempty"`
	AgyBin             *string                  `json:"agy_bin,omitempty"`
	EnvironmentPresent bool                     `json:"environment_present"`
}

type agyPreflightResult struct {
	OK         bool
	AgyBin     string
	AgyVersion string
	LoggedIn   *bool
	Reason     string
	Message    string
}

func ParseAgyActivationPreference(raw string) (AgyActivationPreference, error) {
	preference := AgyActivationPreference(strings.ToLower(strings.TrimSpace(raw)))
	switch preference {
	case AgyActivationAuto, AgyActivationEnabled, AgyActivationDisabled:
		return preference, nil
	default:
		return "", fmt.Errorf("Antigravity 启用策略只支持 auto、enabled 或 disabled，实际为 %q", raw)
	}
}

func ConfigureAgy(
	ctx context.Context,
	configPath string,
	requested AgyActivationPreference,
	restoreEnabled *bool,
) (AgyConfigurationResult, error) {
	return configureAgyWithCandidates(ctx, configPath, requested, restoreEnabled, agyExecutableCandidates)
}

func configureAgyWithCandidates(
	ctx context.Context,
	configPath string,
	requested AgyActivationPreference,
	restoreEnabled *bool,
	candidates func(string) []string,
) (AgyConfigurationResult, error) {
	requested, err := ParseAgyActivationPreference(string(requested))
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return AgyConfigurationResult{}, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}

	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("读取配置文件失败：%w", err)
	}
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return AgyConfigurationResult{}, fmt.Errorf("配置文件必须是 JSON object")
	}
	agyDoc, err := decodeAgyDocument(document)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	currentEnabled, err := decodeAgyEnabled(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	previousPreference, err := decodeAgyPreference(agyDoc, currentEnabled)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	previousState, err := agyModuleState(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	result := AgyConfigurationResult{
		Enabled:            currentEnabled,
		Preference:         previousPreference,
		PreviousEnabled:    currentEnabled,
		PreviousPreference: previousPreference,
		Previous:           previousState,
		Applied:            previousState,
	}

	targetPreference := requested
	if restoreEnabled == nil && requested == AgyActivationAuto && previousPreference != AgyActivationAuto {
		targetPreference = previousPreference
	}

	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	targetEnabled := currentEnabled
	preflight := agyPreflightResult{}
	if restoreEnabled != nil {
		targetEnabled = *restoreEnabled
		preflight = agyPreflightResult{
			OK:      targetEnabled,
			Reason:  "restored",
			Message: "已恢复 Antigravity 设置。",
		}
	} else {
		switch targetPreference {
		case AgyActivationDisabled:
			targetEnabled = false
			preflight = agyPreflightResult{
				Reason:  "disabled_by_user",
				Message: "Antigravity 实验通道已关闭；后续启动不会自动重新启用。",
			}
		case AgyActivationAuto, AgyActivationEnabled:
			preflight = preflightAgy(ctx, cfg, candidates(cfg.Agy.Env[agybridge.AgyBinaryEnvKey]))
			result.AgyBin = preflight.AgyBin
			result.AgyVersion = preflight.AgyVersion
			result.LoggedIn = preflight.LoggedIn
			if preflight.OK {
				targetEnabled = true
			} else if requested == AgyActivationEnabled {
				result.Available = false
				result.Reason = preflight.Reason
				result.Message = preflight.Message
				return result, nil
			} else {
				targetEnabled = false
			}
		}
	}

	currentAgyBin, err := decodeAgyBinary(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	targetAgyBin := currentAgyBin
	if targetEnabled && preflight.AgyBin != "" {
		targetAgyBin = preflight.AgyBin
	}
	if err := encodeAgyDocument(agyDoc, targetEnabled, targetPreference, targetAgyBin); err != nil {
		return AgyConfigurationResult{}, err
	}
	appliedState, err := agyModuleState(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	encodedAgy, err := json.Marshal(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("编码 agy 配置失败：%w", err)
	}
	document["agy"] = encodedAgy
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("编码配置文件失败：%w", err)
	}
	updated = append(updated, '\n')
	changed := string(updated) != string(original)
	if changed {
		if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
			return AgyConfigurationResult{}, fmt.Errorf("原子更新配置文件失败：%w", err)
		}
	}

	result.Enabled = targetEnabled
	result.Available = preflight.OK
	result.Preference = targetPreference
	result.Applied = appliedState
	result.Changed = changed
	result.RestartRequired = currentEnabled != targetEnabled || currentAgyBin != targetAgyBin
	result.AgyBin = preflight.AgyBin
	result.AgyVersion = preflight.AgyVersion
	result.LoggedIn = preflight.LoggedIn
	result.Reason = preflight.Reason
	result.Message = preflight.Message
	if targetEnabled && preflight.OK && preflight.Message == "" {
		result.Reason = "ready"
		result.Message = "已检测到 Antigravity CLI 和兼容的 mimi-agy-adapter。"
	}
	return result, nil
}

func RestoreAgy(configPath string, previous AgyConfigurationResult) (AgyConfigurationResult, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return AgyConfigurationResult{}, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}
	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("读取配置文件失败：%w", err)
	}
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return AgyConfigurationResult{}, fmt.Errorf("配置文件必须是 JSON object")
	}
	agyDoc, err := decodeAgyDocument(document)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	currentState, err := agyModuleState(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	if !reflect.DeepEqual(currentState, previous.Applied) {
		return AgyConfigurationResult{}, fmt.Errorf("Antigravity 设置已被其他操作修改，未覆盖新的设置；请刷新后重试")
	}
	currentEnabled, err := decodeAgyEnabled(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	currentPreference, err := decodeAgyPreference(agyDoc, currentEnabled)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	currentBin, err := decodeAgyBinary(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	if err := applyAgyModuleState(agyDoc, previous.Previous); err != nil {
		return AgyConfigurationResult{}, err
	}
	encodedAgy, err := json.Marshal(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("编码 agy 配置失败：%w", err)
	}
	document["agy"] = encodedAgy
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return AgyConfigurationResult{}, fmt.Errorf("编码配置文件失败：%w", err)
	}
	updated = append(updated, '\n')
	changed := !bytes.Equal(original, updated)
	if changed {
		if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
			return AgyConfigurationResult{}, fmt.Errorf("原子恢复配置文件失败：%w", err)
		}
	}
	restoredEnabled, err := decodeAgyEnabled(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	restoredPreference, err := decodeAgyPreference(agyDoc, restoredEnabled)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	restoredBin, err := decodeAgyBinary(agyDoc)
	if err != nil {
		return AgyConfigurationResult{}, err
	}
	return AgyConfigurationResult{
		Enabled:            restoredEnabled,
		Available:          restoredEnabled,
		Preference:         restoredPreference,
		PreviousEnabled:    currentEnabled,
		PreviousPreference: currentPreference,
		Changed:            changed,
		RestartRequired:    currentEnabled != restoredEnabled || currentBin != restoredBin,
		AgyBin:             restoredBin,
		Reason:             "restored",
		Message:            "已恢复 Antigravity 设置。",
		Previous:           currentState,
		Applied:            previous.Previous,
	}, nil
}

func preflightAgy(ctx context.Context, cfg config.Config, candidates []string) agyPreflightResult {
	adapterBin, ok := agybridge.ResolveBinary(cfg.Agy.AdapterBin)
	if !ok {
		return agyPreflightResult{
			Reason:  "adapter_missing",
			Message: "未找到 mimi-agy-adapter。请重新安装 Mimi Remote 或配置 agy.adapter_bin。",
		}
	}
	env := agybridge.BuildEnv(cfg.Agy.Env)
	caps, err := agybridge.ReadAdapterCapabilities(ctx, adapterBin, cfg.Agy.Args, env)
	if err != nil {
		return agyPreflightResult{
			Reason:  "adapter_invalid",
			Message: "无法读取 mimi-agy-adapter 的能力声明：" + err.Error(),
		}
	}

	bestBin := ""
	bestVersion := ""
	seen := map[string]bool{}
	for _, candidate := range candidates {
		trimmed := strings.TrimSpace(candidate)
		if trimmed == "" {
			continue
		}
		resolved := trimmed
		if !filepath.IsAbs(resolved) {
			found, lookErr := exec.LookPath(resolved)
			if lookErr != nil {
				continue
			}
			resolved = found
		}
		if seen[resolved] {
			continue
		}
		seen[resolved] = true
		version, verErr := agybridge.AgyVersion(ctx, resolved, env)
		if verErr != nil {
			continue
		}
		if bestVersion == "" || claudebridge.Compare(version, bestVersion) > 0 {
			bestBin = resolved
			bestVersion = version
		}
	}
	if bestBin == "" {
		return agyPreflightResult{
			Reason:  "agy_missing",
			Message: "未检测到 Antigravity CLI (agy)。请先在电脑安装 agy 并完成登录。",
		}
	}
	if !caps.AgySupported(bestVersion) {
		return agyPreflightResult{
			AgyBin:     bestBin,
			AgyVersion: bestVersion,
			Reason:     "agy_unsupported",
			Message:    agybridge.AgyUpgradeMessage(bestVersion, caps.Agy.MinimumVersion),
		}
	}

	authState, authMsg := agybridge.CheckAgyAuthStatus(ctx, bestBin, env)
	switch authState {
	case agybridge.AgyAuthSignedOut:
		loggedIn := false
		return agyPreflightResult{
			AgyBin:     bestBin,
			AgyVersion: bestVersion,
			LoggedIn:   &loggedIn,
			Reason:     "agy_signed_out",
			Message:    authMsg,
		}
	case agybridge.AgyAuthUnknown:
		return agyPreflightResult{
			AgyBin:     bestBin,
			AgyVersion: bestVersion,
			LoggedIn:   nil,
			Reason:     "agy_auth_unknown",
			Message:    authMsg,
		}
	}
	loggedIn := true
	return agyPreflightResult{
		OK:         true,
		AgyBin:     bestBin,
		AgyVersion: bestVersion,
		LoggedIn:   &loggedIn,
		Reason:     "ready",
		Message:    fmt.Sprintf("已检测到 Antigravity CLI %s。", bestVersion),
	}
}

func decodeAgyDocument(document map[string]json.RawMessage) (map[string]json.RawMessage, error) {
	raw, exists := document["agy"]
	if !exists || len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		return map[string]json.RawMessage{}, nil
	}
	section := map[string]json.RawMessage{}
	if err := json.Unmarshal(raw, &section); err != nil {
		return nil, fmt.Errorf("解析 agy 配置失败：%w", err)
	}
	if section == nil {
		return map[string]json.RawMessage{}, nil
	}
	return section, nil
}

func decodeAgyEnabled(section map[string]json.RawMessage) (bool, error) {
	raw, exists := section["enabled"]
	if !exists || len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		return false, nil
	}
	var enabled bool
	if err := json.Unmarshal(raw, &enabled); err != nil {
		return false, fmt.Errorf("解析 agy.enabled 失败：%w", err)
	}
	return enabled, nil
}

func decodeAgyPreference(section map[string]json.RawMessage, enabled bool) (AgyActivationPreference, error) {
	raw, exists := section["activation"]
	if !exists || len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		if enabled {
			return AgyActivationEnabled, nil
		}
		return AgyActivationAuto, nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", fmt.Errorf("解析 agy.activation 失败：%w", err)
	}
	return ParseAgyActivationPreference(value)
}

func decodeAgyBinary(section map[string]json.RawMessage) (string, error) {
	rawEnv, exists := section["env"]
	if !exists || len(bytes.TrimSpace(rawEnv)) == 0 || string(bytes.TrimSpace(rawEnv)) == "null" {
		return "", nil
	}
	envMap := map[string]string{}
	if err := json.Unmarshal(rawEnv, &envMap); err != nil {
		return "", fmt.Errorf("解析 agy.env 失败：%w", err)
	}
	return strings.TrimSpace(envMap[agybridge.AgyBinaryEnvKey]), nil
}

func agyModuleState(section map[string]json.RawMessage) (AgyModuleState, error) {
	var state AgyModuleState
	if raw, exists := section["enabled"]; exists && string(bytes.TrimSpace(raw)) != "null" {
		var enabled bool
		if err := json.Unmarshal(raw, &enabled); err != nil {
			return AgyModuleState{}, err
		}
		state.Enabled = &enabled
	}
	if raw, exists := section["activation"]; exists && string(bytes.TrimSpace(raw)) != "null" {
		var value string
		if err := json.Unmarshal(raw, &value); err != nil {
			return AgyModuleState{}, err
		}
		pref, err := ParseAgyActivationPreference(value)
		if err != nil {
			return AgyModuleState{}, err
		}
		state.Activation = &pref
	}
	if rawEnv, exists := section["env"]; exists && string(bytes.TrimSpace(rawEnv)) != "null" {
		envMap := map[string]string{}
		if err := json.Unmarshal(rawEnv, &envMap); err != nil {
			return AgyModuleState{}, err
		}
		state.EnvironmentPresent = true
		if bin, ok := envMap[agybridge.AgyBinaryEnvKey]; ok {
			trimmed := strings.TrimSpace(bin)
			state.AgyBin = &trimmed
		}
	}
	return state, nil
}

func encodeAgyDocument(
	section map[string]json.RawMessage,
	enabled bool,
	preference AgyActivationPreference,
	agyBin string,
) error {
	encodedEnabled, err := json.Marshal(enabled)
	if err != nil {
		return err
	}
	encodedPref, err := json.Marshal(preference)
	if err != nil {
		return err
	}
	section["enabled"] = encodedEnabled
	section["activation"] = encodedPref
	if _, hasAdapterBin := section["adapter_bin"]; !hasAdapterBin {
		encodedAdapter, _ := json.Marshal(agybridge.AdapterName)
		section["adapter_bin"] = encodedAdapter
	}
	if _, hasMax := section["max_concurrent_sessions"]; !hasMax {
		encodedMax, _ := json.Marshal(config.DefaultAgyMaxConcurrentSessions)
		section["max_concurrent_sessions"] = encodedMax
	}
	envMap := map[string]string{"TERM": "xterm-256color"}
	if rawEnv, exists := section["env"]; exists && string(bytes.TrimSpace(rawEnv)) != "null" {
		_ = json.Unmarshal(rawEnv, &envMap)
	}
	if strings.TrimSpace(agyBin) != "" {
		envMap[agybridge.AgyBinaryEnvKey] = strings.TrimSpace(agyBin)
	}
	encodedEnv, err := json.Marshal(envMap)
	if err != nil {
		return err
	}
	section["env"] = encodedEnv
	return nil
}

func applyAgyModuleState(section map[string]json.RawMessage, state AgyModuleState) error {
	if state.Enabled == nil {
		delete(section, "enabled")
	} else {
		encoded, err := json.Marshal(*state.Enabled)
		if err != nil {
			return err
		}
		section["enabled"] = encoded
	}
	if state.Activation == nil {
		delete(section, "activation")
	} else {
		encoded, err := json.Marshal(*state.Activation)
		if err != nil {
			return err
		}
		section["activation"] = encoded
	}
	if !state.EnvironmentPresent {
		delete(section, "env")
		return nil
	}
	envMap := map[string]string{}
	if rawEnv, exists := section["env"]; exists && string(bytes.TrimSpace(rawEnv)) != "null" {
		_ = json.Unmarshal(rawEnv, &envMap)
	}
	if state.AgyBin == nil {
		delete(envMap, agybridge.AgyBinaryEnvKey)
	} else {
		envMap[agybridge.AgyBinaryEnvKey] = *state.AgyBin
	}
	encodedEnv, err := json.Marshal(envMap)
	if err != nil {
		return err
	}
	section["env"] = encodedEnv
	return nil
}

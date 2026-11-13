package setup

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
)

type ClaudeTurnHintsState struct {
	Enabled *bool `json:"enabled,omitempty"`
}

type ClaudeTurnHintsConfigurationResult struct {
	Enabled         bool                 `json:"enabled"`
	PreviousEnabled bool                 `json:"previous_enabled"`
	Changed         bool                 `json:"changed"`
	RestartRequired bool                 `json:"restart_required"`
	Message         string               `json:"message"`
	Previous        ClaudeTurnHintsState `json:"previous"`
	Applied         ClaudeTurnHintsState `json:"applied"`
}

// ConfigureClaudeTurnHints 只修改 claude.turn_hints_enabled，并用文件 CAS 防止
// “读取后、提交前”的并发配置写入被覆盖。省略字段按开启处理，兼容旧配置。
func ConfigureClaudeTurnHints(configPath string, enabled bool) (ClaudeTurnHintsConfigurationResult, error) {
	cfgPath, original, document, claudeDocument, err := readClaudeTurnHintsDocument(configPath)
	if err != nil {
		return ClaudeTurnHintsConfigurationResult{}, err
	}
	previous, err := claudeTurnHintsState(claudeDocument)
	if err != nil {
		return ClaudeTurnHintsConfigurationResult{}, err
	}
	result := ClaudeTurnHintsConfigurationResult{
		Enabled: effectiveClaudeTurnHints(previous), PreviousEnabled: effectiveClaudeTurnHints(previous),
		Previous: previous, Applied: previous,
	}
	if result.Enabled == enabled {
		result.Message = claudeTurnHintsMessage(enabled)
		return result, nil
	}
	appliedEnabled := enabled
	applied := ClaudeTurnHintsState{Enabled: &appliedEnabled}
	applyClaudeTurnHintsState(claudeDocument, applied)
	updated, err := encodeClaudeTurnHintsDocument(document, claudeDocument)
	if err != nil {
		return ClaudeTurnHintsConfigurationResult{}, err
	}
	if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
		return ClaudeTurnHintsConfigurationResult{}, fmt.Errorf("原子更新配置文件失败：%w", err)
	}
	result.Enabled = enabled
	result.Changed = true
	result.RestartRequired = true
	result.Applied = applied
	result.Message = claudeTurnHintsMessage(enabled)
	return result, nil
}

// RestoreClaudeTurnHints 只在当前字段仍等于本次操作的 Applied 快照时恢复，避免
// 服务重载失败后的自动回滚覆盖另一位配置写者刚做出的选择。
func RestoreClaudeTurnHints(configPath string, previous ClaudeTurnHintsConfigurationResult) (ClaudeTurnHintsConfigurationResult, error) {
	cfgPath, original, document, claudeDocument, err := readClaudeTurnHintsDocument(configPath)
	if err != nil {
		return ClaudeTurnHintsConfigurationResult{}, err
	}
	current, err := claudeTurnHintsState(claudeDocument)
	if err != nil {
		return ClaudeTurnHintsConfigurationResult{}, err
	}
	if !reflect.DeepEqual(current, previous.Applied) {
		return ClaudeTurnHintsConfigurationResult{}, fmt.Errorf("Claude 提示卡设置已被其他操作修改，未覆盖新的设置；请刷新后重试")
	}
	applyClaudeTurnHintsState(claudeDocument, previous.Previous)
	updated, err := encodeClaudeTurnHintsDocument(document, claudeDocument)
	if err != nil {
		return ClaudeTurnHintsConfigurationResult{}, err
	}
	changed := !bytes.Equal(original, updated)
	if changed {
		if err := writePrivateFileAtomicallyCAS(cfgPath, original, updated); err != nil {
			return ClaudeTurnHintsConfigurationResult{}, fmt.Errorf("原子恢复配置文件失败：%w", err)
		}
	}
	restored := effectiveClaudeTurnHints(previous.Previous)
	return ClaudeTurnHintsConfigurationResult{
		Enabled: restored, PreviousEnabled: effectiveClaudeTurnHints(current),
		Changed: changed, RestartRequired: changed, Message: "已恢复修改前的 Claude 提示卡设置。",
		Previous: current, Applied: previous.Previous,
	}, nil
}

func readClaudeTurnHintsDocument(configPath string) (string, []byte, map[string]json.RawMessage, map[string]json.RawMessage, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return "", nil, nil, nil, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return "", nil, nil, nil, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}
	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("读取配置文件失败：%w", err)
	}
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return "", nil, nil, nil, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return "", nil, nil, nil, fmt.Errorf("配置文件必须是 JSON object")
	}
	claudeDocument, err := decodeClaudeDocument(document)
	return cfgPath, original, document, claudeDocument, err
}

func claudeTurnHintsState(document map[string]json.RawMessage) (ClaudeTurnHintsState, error) {
	state := ClaudeTurnHintsState{}
	if raw, ok := document["turn_hints_enabled"]; ok {
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return state, nil
		}
		var enabled bool
		if err := json.Unmarshal(raw, &enabled); err != nil {
			return state, fmt.Errorf("解析 claude.turn_hints_enabled 失败：%w", err)
		}
		state.Enabled = &enabled
	}
	return state, nil
}

func effectiveClaudeTurnHints(state ClaudeTurnHintsState) bool {
	return state.Enabled == nil || *state.Enabled
}

func applyClaudeTurnHintsState(document map[string]json.RawMessage, state ClaudeTurnHintsState) {
	if state.Enabled == nil {
		delete(document, "turn_hints_enabled")
		return
	}
	document["turn_hints_enabled"], _ = json.Marshal(*state.Enabled)
}

func encodeClaudeTurnHintsDocument(document, claudeDocument map[string]json.RawMessage) ([]byte, error) {
	encodedClaude, err := json.Marshal(claudeDocument)
	if err != nil {
		return nil, fmt.Errorf("编码 claude 配置失败：%w", err)
	}
	document["claude"] = encodedClaude
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("编码配置文件失败：%w", err)
	}
	return append(updated, '\n'), nil
}

func claudeTurnHintsMessage(enabled bool) string {
	if enabled {
		return "Claude 回合提示卡已开启。"
	}
	return "Claude 回合提示卡已关闭。"
}

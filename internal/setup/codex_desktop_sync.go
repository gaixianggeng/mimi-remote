package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
)

type CodexDesktopSyncConfigurationResult struct {
	Enabled                bool   `json:"enabled"`
	Changed                bool   `json:"changed"`
	ServiceRestartRequired bool   `json:"service_restart_required"`
	LegacyCleanupRequired  bool   `json:"legacy_cleanup_required"`
	Message                string `json:"message"`
}

var (
	inspectDesktopSyncLegacyArtifacts = desktopSyncLegacyArtifactsPresent
	removeDesktopSyncLegacyArtifacts  = cleanupDesktopSyncLegacyArtifacts
)

// ConfigureCodexDesktopSync only changes the experimental overlay switch. The
// independent managed WebSocket remains the App Server owner in every state.
func ConfigureCodexDesktopSync(
	ctx context.Context,
	configPath string,
	enabled bool,
	cleanupLegacyConfirmed bool,
) (CodexDesktopSyncConfigurationResult, error) {
	path, err := resolveConfigPath(configPath)
	if err != nil {
		return CodexDesktopSyncConfigurationResult{}, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return CodexDesktopSyncConfigurationResult{}, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return CodexDesktopSyncConfigurationResult{}, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}
	original, err := os.ReadFile(path)
	if err != nil {
		return CodexDesktopSyncConfigurationResult{}, fmt.Errorf("读取配置文件失败：%w", err)
	}
	initial := append([]byte(nil), original...)
	document, codexDocument, appServerDocument, err := decodeDesktopSyncConfig(original)
	if err != nil {
		return CodexDesktopSyncConfigurationResult{}, err
	}
	currentEnabled, err := decodeDesktopSyncEnabled(codexDocument)
	if err != nil {
		return CodexDesktopSyncConfigurationResult{}, err
	}
	legacyConfig := legacySharingConfigPresent(appServerDocument)
	legacyArtifacts, err := inspectDesktopSyncLegacyArtifacts()
	if err != nil {
		return CodexDesktopSyncConfigurationResult{}, err
	}
	legacyPending := decodeRawBool(codexDocument["desktop_sync_legacy_cleanup_pending"])
	legacyRequired := legacyConfig || legacyArtifacts || legacyPending
	result := CodexDesktopSyncConfigurationResult{
		Enabled:               currentEnabled,
		LegacyCleanupRequired: legacyRequired,
	}
	if legacyRequired && !cleanupLegacyConfirmed {
		result.Message = "检测到旧共享 daemon 配置。请确认 Codex Desktop 已退出后执行一次遗留清理。"
		return result, nil
	}

	if cleanupLegacyConfirmed {
		if runtime.GOOS != "darwin" {
			return result, fmt.Errorf("共享 daemon 遗留清理只支持 macOS")
		}
		restoreLegacyAppServer(appServerDocument)
		encodedAppServer, marshalErr := json.Marshal(appServerDocument)
		if marshalErr != nil {
			return result, fmt.Errorf("编码 app_server 配置失败：%w", marshalErr)
		}
		document["app_server"] = encodedAppServer
		codexDocument["desktop_sync_enabled"] = json.RawMessage(`false`)
		codexDocument["desktop_sync_legacy_cleanup_pending"] = json.RawMessage(`true`)
		encodedCodex, marshalErr := json.Marshal(codexDocument)
		if marshalErr != nil {
			return result, fmt.Errorf("编码 codex 配置失败：%w", marshalErr)
		}
		document["codex"] = encodedCodex
		prepared, marshalErr := json.MarshalIndent(document, "", "  ")
		if marshalErr != nil {
			return result, fmt.Errorf("编码配置文件失败：%w", marshalErr)
		}
		prepared = append(prepared, '\n')
		if !bytes.Equal(prepared, original) {
			if err := writePrivateFileAtomicallyCAS(path, original, prepared); err != nil {
				return result, fmt.Errorf("写入遗留清理迁移标记失败：%w", err)
			}
			original = prepared
		}
		if err := removeDesktopSyncLegacyArtifacts(ctx); err != nil {
			return result, err
		}
		delete(codexDocument, "desktop_sync_legacy_cleanup_pending")
		legacyRequired = false
	}

	encodedEnabled, err := json.Marshal(enabled)
	if err != nil {
		return result, err
	}
	codexDocument["desktop_sync_enabled"] = encodedEnabled
	encodedCodex, err := json.Marshal(codexDocument)
	if err != nil {
		return result, fmt.Errorf("编码 codex 配置失败：%w", err)
	}
	document["codex"] = encodedCodex
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return result, fmt.Errorf("编码配置文件失败：%w", err)
	}
	updated = append(updated, '\n')
	changed := !bytes.Equal(updated, initial)
	if !bytes.Equal(updated, original) {
		if err := writePrivateFileAtomicallyCAS(path, original, updated); err != nil {
			return result, fmt.Errorf("原子更新配置文件失败：%w", err)
		}
	}
	result.Enabled = enabled
	result.Changed = changed
	result.ServiceRestartRequired = changed
	result.LegacyCleanupRequired = legacyRequired
	if enabled {
		result.Message = "Codex Desktop 会话同步已开启；重载 agentd 后生效。"
	} else {
		result.Message = "Codex Desktop 会话同步已关闭；重载 agentd 后生效。"
	}
	return result, nil
}

func decodeRawBool(raw json.RawMessage) bool {
	var value bool
	return len(raw) > 0 && json.Unmarshal(raw, &value) == nil && value
}

func decodeDesktopSyncConfig(raw []byte) (
	map[string]json.RawMessage,
	map[string]json.RawMessage,
	map[string]json.RawMessage,
	error,
) {
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(raw, &document); err != nil || document == nil {
		return nil, nil, nil, fmt.Errorf("配置文件必须是 JSON object")
	}
	decodeObject := func(key string) (map[string]json.RawMessage, error) {
		value := map[string]json.RawMessage{}
		if encoded, ok := document[key]; ok && string(encoded) != "null" {
			if err := json.Unmarshal(encoded, &value); err != nil || value == nil {
				return nil, fmt.Errorf("%s 配置必须是 JSON object", key)
			}
		}
		return value, nil
	}
	codex, err := decodeObject("codex")
	if err != nil {
		return nil, nil, nil, err
	}
	appServer, err := decodeObject("app_server")
	if err != nil {
		return nil, nil, nil, err
	}
	return document, codex, appServer, nil
}

func decodeDesktopSyncEnabled(codex map[string]json.RawMessage) (bool, error) {
	raw, ok := codex["desktop_sync_enabled"]
	if !ok {
		return false, nil
	}
	var enabled bool
	if err := json.Unmarshal(raw, &enabled); err != nil {
		return false, fmt.Errorf("codex.desktop_sync_enabled 必须是布尔值")
	}
	return enabled, nil
}

func legacySharingConfigPresent(appServer map[string]json.RawMessage) bool {
	if raw, ok := appServer["shared_fallback"]; ok && string(raw) != "null" {
		return true
	}
	var transport string
	_ = json.Unmarshal(appServer["transport"], &transport)
	return strings.EqualFold(strings.TrimSpace(transport), "unix")
}

func restoreLegacyAppServer(appServer map[string]json.RawMessage) {
	if raw, ok := appServer["shared_fallback"]; ok && string(raw) != "null" {
		fallback := map[string]json.RawMessage{}
		if json.Unmarshal(raw, &fallback) == nil {
			for _, key := range []string{"transport", "managed", "listen", "ws_token_file"} {
				if value, exists := fallback[key]; exists {
					appServer[key] = value
				} else {
					delete(appServer, key)
				}
			}
		}
	}
	delete(appServer, "shared_fallback")
	if raw := appServer["transport"]; len(raw) == 0 || strings.Contains(strings.ToLower(string(raw)), "unix") {
		appServer["transport"] = json.RawMessage(`"ws"`)
		appServer["managed"] = json.RawMessage(`true`)
		appServer["listen"] = json.RawMessage(`"ws://127.0.0.1:4222"`)
	}
}

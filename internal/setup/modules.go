package setup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"reflect"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// ModulePreferences contains only switch intent, never credentials or provider
// settings. Nil preserves a legacy missing field during rollback.
type ModulePreferences struct {
	Codex            *bool   `json:"codex"`
	Claude           *bool   `json:"claude"`
	ClaudeActivation *string `json:"claude_activation"`
	LAN              *bool   `json:"lan"`
	Tailscale        *bool   `json:"tailscale"`
}

type ModuleChange struct {
	Module          string                     `json:"module"`
	Configuration   config.ModuleConfiguration `json:"configuration"`
	Previous        ModulePreferences          `json:"previous"`
	Revision        string                     `json:"revision"`
	Changed         bool                       `json:"changed"`
	RestartRequired bool                       `json:"restart_required"`
}

// ConfigureModule changes switches in one CAS transaction, preserving all other
// raw JSON fields. Restoring requires the exact revision produced by the change:
// a CLI/another App edit must never be overwritten by delayed rollback or undo.
func ConfigureModule(ctx context.Context, path, module string, enabled bool, expectedRevision string, restore *ModulePreferences) (ModuleChange, error) {
	result := ModuleChange{Module: module}
	switch module {
	case "codex", "claude", "tailscale", "lan":
	default:
		return result, fmt.Errorf("不支持的模块：%s", module)
	}
	if restore != nil && expectedRevision == "" {
		return result, fmt.Errorf("恢复模块设置必须提供配置版本")
	}
	cfgPath, err := resolveConfigPath(path)
	if err != nil {
		return result, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return result, err
	}
	if !info.Mode().IsRegular() {
		return result, fmt.Errorf("配置文件必须是普通文件，不能是符号链接")
	}
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return result, err
	}
	result.Revision = moduleRevision(raw)
	if expectedRevision != "" && expectedRevision != result.Revision {
		return result, fmt.Errorf("配置已被其他操作修改；请刷新后重试，不会覆盖新设置")
	}
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(raw, &document); err != nil {
		return result, err
	}
	if document == nil {
		return result, fmt.Errorf("配置必须是 JSON object")
	}
	sections := map[string]map[string]json.RawMessage{}
	for _, key := range []string{"codex", "claude", "network"} {
		section := map[string]json.RawMessage{}
		if value := document[key]; len(value) > 0 && string(value) != "null" {
			if err := json.Unmarshal(value, &section); err != nil {
				return result, fmt.Errorf("解析 %s：%w", key, err)
			}
			if section == nil {
				section = map[string]json.RawMessage{}
			}
		}
		sections[key] = section
	}
	previous, err := readModulePreferences(sections)
	if err != nil {
		return result, err
	}
	result.Previous = previous
	next := previous
	if restore != nil {
		next = *restore
	} else {
		switch module {
		case "codex":
			next.Codex = &enabled
		case "claude":
			next.Claude = &enabled
			activation := "disabled"
			if enabled {
				activation = "enabled"
			}
			next.ClaudeActivation = &activation
		case "tailscale":
			next.Tailscale = &enabled
		case "lan":
			next.LAN = &enabled
			// Opt into the independent listener policy without changing the legacy
			// Tailscale intent. A later LAN disable cannot leave a private bind open.
			if next.Tailscale == nil {
				legacyEnabled := true
				next.Tailscale = &legacyEnabled
			}
		}
	}
	if next.ClaudeActivation != nil {
		if _, err := ParseClaudeActivationPreference(*next.ClaudeActivation); err != nil {
			return result, err
		}
	}
	setModuleField(sections["codex"], "enabled", next.Codex)
	setModuleField(sections["claude"], "enabled", next.Claude)
	setModuleField(sections["claude"], "activation", next.ClaudeActivation)
	setModuleField(sections["network"], "allow_lan", next.LAN)
	setModuleField(sections["network"], "tailscale_enabled", next.Tailscale)
	for name, section := range sections {
		encoded, err := json.Marshal(section)
		if err != nil {
			return result, err
		}
		document[name] = encoded
	}
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return result, err
	}
	updated = append(updated, '\n')
	cfg, err := config.LoadSnapshot(updated)
	if err != nil {
		return result, fmt.Errorf("新的模块设置无效：%w", err)
	}
	if restore == nil && module == "claude" && cfg.Claude.Enabled != enabled {
		return result, fmt.Errorf("AGENTD_CLAUDE_ENABLED 覆盖了模块设置，请先移除该环境变量")
	}
	result.Configuration = cfg.Modules()
	if reflect.DeepEqual(previous, next) {
		return result, nil
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	if err := writePrivateFileAtomicallyCAS(cfgPath, raw, updated); err != nil {
		return result, err
	}
	result.Changed = true
	result.RestartRequired = true
	result.Revision = moduleRevision(updated)
	return result, nil
}

func moduleRevision(raw []byte) string { sum := sha256.Sum256(raw); return hex.EncodeToString(sum[:]) }

func readModulePreferences(sections map[string]map[string]json.RawMessage) (ModulePreferences, error) {
	var p ModulePreferences
	for _, item := range []struct {
		section, field string
		target         any
	}{
		{"codex", "enabled", &p.Codex}, {"claude", "enabled", &p.Claude},
		{"claude", "activation", &p.ClaudeActivation}, {"network", "allow_lan", &p.LAN},
		{"network", "tailscale_enabled", &p.Tailscale},
	} {
		if raw := sections[item.section][item.field]; len(raw) > 0 {
			if err := json.Unmarshal(raw, item.target); err != nil {
				return p, fmt.Errorf("解析 %s.%s：%w", item.section, item.field, err)
			}
		}
	}
	return p, nil
}

func setModuleField[T any](section map[string]json.RawMessage, key string, value *T) {
	if value == nil {
		delete(section, key)
		return
	}
	section[key], _ = json.Marshal(*value)
}

// ConnectionModuleStatus describes endpoint availability, not connected devices.
// The Mac additionally checks the running service's module configuration before
// permitting pairing; a disk setting alone is not evidence it has been applied.
type ConnectionModuleStatus struct {
	ID        string `json:"id"`
	Enabled   bool   `json:"enabled"`
	Available bool   `json:"available"`
	Endpoint  string `json:"endpoint,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

func ConnectionModules(ctx context.Context, cfg config.Config) []ConnectionModuleStatus {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	result := make([]ConnectionModuleStatus, 0, 2)
	for _, network := range []PairingNetwork{PairingNetworkTailscale, PairingNetworkLAN} {
		enabled := cfg.Network.AllowsTailscale()
		if network == PairingNetworkLAN {
			enabled = cfg.Modules().LANEnabled
		}
		row := ConnectionModuleStatus{ID: string(network), Enabled: enabled}
		if enabled {
			probeConfig := cfg
			probeEnabled := true
			probeConfig.Codex.Enabled = &probeEnabled
			endpoint, _, err := pairingEndpoint(ctx, probeConfig, network, defaultPairingNetworkLookups())
			if err != nil {
				row.Reason = err.Error()
			} else {
				row.Endpoint = endpoint
				checkCtx, cancelCheck := context.WithTimeout(ctx, time.Second)
				request, requestErr := http.NewRequestWithContext(checkCtx, http.MethodGet, endpoint+"/healthz", nil)
				if requestErr == nil {
					transport := &http.Transport{Proxy: nil}
					client := &http.Client{Transport: transport, Timeout: time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
					response, checkErr := client.Do(request)
					if checkErr == nil {
						row.Available = response.StatusCode == http.StatusOK
						response.Body.Close()
					}
					transport.CloseIdleConnections()
				}
				cancelCheck()
				if !row.Available {
					row.Reason = "此地址上的 Mimi 服务尚未就绪；连接网络后可重新启动 Mimi 服务"
				}
			}
		}
		result = append(result, row)
	}
	return result
}

package setup

import (
	"context"
	"fmt"
	"reflect"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type CodexModuleState struct {
	Enabled    *bool  `json:"enabled,omitempty"`
	Activation string `json:"activation,omitempty"`
}

type CodexConfigurationResult struct {
	Enabled         bool             `json:"codex_enabled"`
	Available       bool             `json:"available"`
	Changed         bool             `json:"changed"`
	RestartRequired bool             `json:"restart_required"`
	Reason          string           `json:"reason"`
	Message         string           `json:"message"`
	Previous        CodexModuleState `json:"previous"`
	Applied         CodexModuleState `json:"applied"`
}

func codexModuleState(cfg config.Config) CodexModuleState {
	return CodexModuleState{Enabled: cfg.Codex.Enabled, Activation: cfg.Codex.Activation}
}

func ConfigureCodex(ctx context.Context, path, preference string) (CodexConfigurationResult, error) {
	preference = strings.ToLower(strings.TrimSpace(preference))
	if preference != "auto" && preference != "enabled" && preference != "disabled" {
		return CodexConfigurationResult{}, fmt.Errorf("Codex 启用策略只支持 auto、enabled 或 disabled")
	}
	doc, err := readModuleDocument(path, "codex")
	if err != nil {
		return CodexConfigurationResult{}, err
	}
	before := codexModuleState(doc.cfg)
	target := preference
	if target == "auto" {
		switch before.Activation {
		case "enabled", "disabled":
			target = before.Activation
		default:
			if before.Enabled != nil && !*before.Enabled {
				target = "disabled"
			}
		}
	}
	enabled := target != "disabled"
	result := CodexConfigurationResult{Enabled: doc.cfg.Codex.IsEnabled(), Previous: before, Applied: before}
	if enabled {
		var probeErr error
		if strings.EqualFold(doc.cfg.AppServer.Transport, "ssh") {
			transport, err := appserver.NewSSHTransport(appserver.SSHTransportOptions{Target: doc.cfg.AppServer.SSHTarget})
			if err != nil {
				return result, err
			}
			_, probeErr = transport.CheckRemoteCodex(ctx)
		} else {
			_, probeErr = appserver.CheckLocalCodex(ctx, doc.cfg.Codex.Bin)
		}
		if probeErr != nil {
			result.Reason = "codex_unavailable"
			result.Message = "未检测到可用的 Codex CLI；请检查安装与连接配置后重试。"
			return result, nil
		}
	}
	after := CodexModuleState{Enabled: &enabled, Activation: target}
	result, err = commitCodexModule(doc, before, after)
	if err != nil {
		return result, err
	}
	result.Available = enabled
	if enabled {
		result.Reason, result.Message = "enabled", "Codex 已启用；登录状态由运行时检查确认。"
	} else {
		result.Reason, result.Message = "disabled_by_user", "Codex 在 Mimi 中已关闭，不会退出系统中的 Codex Desktop。"
	}
	return result, nil
}

func RestoreCodex(path string, previous CodexConfigurationResult) (CodexConfigurationResult, error) {
	doc, err := readModuleDocument(path, "codex")
	if err != nil {
		return CodexConfigurationResult{}, err
	}
	current := codexModuleState(doc.cfg)
	if !reflect.DeepEqual(current, previous.Applied) {
		return CodexConfigurationResult{}, fmt.Errorf("Codex 设置已被其他操作修改，未覆盖新的设置；请刷新后重试")
	}
	result, err := commitCodexModule(doc, current, previous.Previous)
	result.Reason, result.Message = "restored", "已恢复修改前的 Codex 设置。"
	return result, err
}

func commitCodexModule(doc moduleDocument, before, after CodexModuleState) (CodexConfigurationResult, error) {
	changed := !reflect.DeepEqual(before, after)
	if changed {
		var activation any
		if after.Activation != "" {
			activation = after.Activation
		}
		if err := doc.commit("codex", map[string]any{
			"enabled": optionalBoolValue(after.Enabled), "activation": activation,
		}); err != nil {
			return CodexConfigurationResult{}, err
		}
	}
	enabled := after.Enabled == nil || *after.Enabled
	return CodexConfigurationResult{
		Enabled: enabled, Changed: changed, RestartRequired: doc.cfg.Codex.IsEnabled() != enabled,
		Previous: before, Applied: after,
	}, nil
}

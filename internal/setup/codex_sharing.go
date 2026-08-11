package setup

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type CodexSharingConfigurationResult struct {
	Enabled         bool   `json:"enabled"`
	Changed         bool   `json:"changed"`
	RestartRequired bool   `json:"restart_required"`
	Transport       string `json:"transport"`
	CodexHome       string `json:"codex_home,omitempty"`
	Message         string `json:"message"`
}

type ensureLocalDaemonFunc func(
	context.Context,
	appserver.LocalDaemonOptions,
) (appserver.LocalDaemonStatus, error)

type inspectLocalDaemonLifecycleFunc func(
	context.Context,
	appserver.LocalDaemonOptions,
) (appserver.LocalDaemonLifecycleStatus, error)

// ConfigureCodexSharing 是从 legacy 独立 WS 进程切换到官方 local daemon 的
// 唯一持久化入口。先确认 daemon 真正可握手，再原子提交配置，避免只设置 Desktop
// 环境却让 agentd 继续使用另一进程，重新制造 writer lock 冲突。
func ConfigureCodexSharing(
	ctx context.Context,
	configPath string,
	enabled bool,
) (CodexSharingConfigurationResult, error) {
	return configureCodexSharing(
		ctx,
		configPath,
		enabled,
		appserver.EnsureLocalDaemon,
		appserver.InspectLocalDaemonLifecycle,
	)
}

func configureCodexSharing(
	ctx context.Context,
	configPath string,
	enabled bool,
	ensureDaemon ensureLocalDaemonFunc,
	inspectDaemon inspectLocalDaemonLifecycleFunc,
) (CodexSharingConfigurationResult, error) {
	resolvedPath, err := resolveConfigPath(configPath)
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	existed, err := regularFileOrMissing(resolvedPath, "配置文件")
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	if !existed {
		return CodexSharingConfigurationResult{}, fmt.Errorf("配置文件不存在，请先完成 Mimi Remote 设置")
	}
	cfg, err := config.Load(resolvedPath)
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}

	codexHome := ""
	if enabled {
		status, err := ensureDaemon(ctx, appserver.LocalDaemonOptions{
			CodexBin: cfg.Codex.Bin,
			Env:      cfg.Codex.Env,
		})
		if err != nil {
			return CodexSharingConfigurationResult{}, err
		}
		lifecycle, err := inspectDaemon(ctx, appserver.LocalDaemonOptions{
			CodexBin: cfg.Codex.Bin,
			Env:      cfg.Codex.Env,
		})
		if err != nil {
			return CodexSharingConfigurationResult{}, fmt.Errorf("确认 Codex daemon 冷启动能力失败：%w", err)
		}
		if err := appserver.ValidateLocalDaemonLifecycle(lifecycle, status.SocketPath); err != nil {
			return CodexSharingConfigurationResult{}, err
		}
		if err := appserver.ValidateLocalDaemonProbeVersion(lifecycle, status.Version); err != nil {
			return CodexSharingConfigurationResult{}, err
		}
		codexHome = localDaemonCodexHome(status.SocketPath)
		if strings.EqualFold(cfg.AppServer.Transport, "unix") {
			return CodexSharingConfigurationResult{
				Enabled:   true,
				Transport: "unix",
				CodexHome: codexHome,
				Message:   codexSharingAlreadyEnabledMessage(cfg.AppServer.SharedFallback != nil),
			}, nil
		}
	} else {
		if !strings.EqualFold(cfg.AppServer.Transport, "unix") {
			return CodexSharingConfigurationResult{
				Enabled:   false,
				Transport: cfg.AppServer.Transport,
				Message:   "Codex Desktop 共享会话服务已关闭。",
			}, nil
		}
		if cfg.AppServer.SharedFallback == nil {
			// 当前 Unix transport 不是 Mimi 从 WS 切换而来，因此没有可验证的
			// 原配置可恢复。关闭 Desktop 环境即可；绝不能虚构默认 WS 覆盖外部配置。
			return CodexSharingConfigurationResult{
				Enabled:   false,
				Transport: "unix",
				Message:   "Codex Desktop 共享环境已关闭；外部管理的 Unix backend 保持不变。",
			}, nil
		}
	}

	document, appServerDocument, err := readCodexSharingConfigDocument(resolvedPath)
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	next := cfg
	if enabled {
		fallback := &config.AppServerFallbackConfig{
			Transport:   cfg.AppServer.Transport,
			Managed:     cfg.AppServer.Managed,
			Listen:      cfg.AppServer.Listen,
			WSTokenFile: cfg.AppServer.WSTokenFile,
		}
		next.AppServer.Transport = "unix"
		next.AppServer.Managed = true
		next.AppServer.Listen = appserver.LocalDaemonListen
		next.AppServer.SharedFallback = fallback
	} else {
		fallback := cfg.AppServer.SharedFallback
		if fallback == nil {
			fallback = &config.AppServerFallbackConfig{
				Transport:   "ws",
				Managed:     true,
				Listen:      config.DefaultAppServerWebSocketListen(),
				WSTokenFile: cfg.AppServer.WSTokenFile,
			}
		}
		next.AppServer.Transport = fallback.Transport
		next.AppServer.Managed = fallback.Managed
		next.AppServer.Listen = fallback.Listen
		next.AppServer.WSTokenFile = fallback.WSTokenFile
		next.AppServer.SharedFallback = nil
	}
	if err := next.Validate(); err != nil {
		return CodexSharingConfigurationResult{}, fmt.Errorf("共享 Codex 配置无效：%w", err)
	}
	if err := encodeCodexSharingAppServer(appServerDocument, next.AppServer); err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	encodedAppServer, err := json.Marshal(appServerDocument)
	if err != nil {
		return CodexSharingConfigurationResult{}, fmt.Errorf("编码 app_server 配置失败：%w", err)
	}
	document["app_server"] = encodedAppServer
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return CodexSharingConfigurationResult{}, fmt.Errorf("编码配置失败：%w", err)
	}
	updated = append(updated, '\n')
	if err := writePrivateFileAtomically(resolvedPath, updated); err != nil {
		return CodexSharingConfigurationResult{}, fmt.Errorf("写入共享 Codex 配置失败：%w", err)
	}

	transport := strings.ToLower(strings.TrimSpace(next.AppServer.Transport))
	return CodexSharingConfigurationResult{
		Enabled:         enabled,
		Changed:         true,
		RestartRequired: true,
		Transport:       transport,
		CodexHome:       codexHome,
		Message:         codexSharingMessage(enabled),
	}, nil
}

func localDaemonCodexHome(socketPath string) string {
	if strings.TrimSpace(socketPath) == "" {
		return ""
	}
	return filepath.Dir(filepath.Dir(filepath.Clean(socketPath)))
}

func readCodexSharingConfigDocument(path string) (
	map[string]json.RawMessage,
	map[string]json.RawMessage,
	error,
) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, fmt.Errorf("读取配置失败：%w", err)
	}
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(raw, &document); err != nil {
		return nil, nil, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return nil, nil, fmt.Errorf("解析配置文件失败：根对象不能为空")
	}
	appServerDocument := map[string]json.RawMessage{}
	if encoded, ok := document["app_server"]; ok && string(encoded) != "null" {
		if err := json.Unmarshal(encoded, &appServerDocument); err != nil {
			return nil, nil, fmt.Errorf("解析 app_server 配置失败：%w", err)
		}
	}
	return document, appServerDocument, nil
}

func encodeCodexSharingAppServer(
	document map[string]json.RawMessage,
	value config.AppServerConfig,
) error {
	fields := map[string]any{
		"transport":  value.Transport,
		"managed":    value.Managed,
		"listen":     value.Listen,
		"auto_title": value.AutoTitle,
	}
	if strings.TrimSpace(value.WSTokenFile) != "" {
		fields["ws_token_file"] = value.WSTokenFile
	} else {
		delete(document, "ws_token_file")
	}
	if value.SharedFallback != nil {
		fields["shared_fallback"] = value.SharedFallback
	} else {
		delete(document, "shared_fallback")
	}
	for key, field := range fields {
		encoded, err := json.Marshal(field)
		if err != nil {
			return fmt.Errorf("编码 app_server.%s 失败：%w", key, err)
		}
		document[key] = encoded
	}
	return nil
}

func codexSharingMessage(enabled bool) string {
	if enabled {
		return "共享 Codex app-server 已启用；重启 agentd 和 Codex Desktop 后生效。"
	}
	return "共享 Codex app-server 已关闭；重启 agentd 和 Codex Desktop 后生效。"
}

func codexSharingAlreadyEnabledMessage(owned bool) string {
	if owned {
		return "Codex Desktop 与 Mimi 已配置为共用本地 app-server。"
	}
	return "已检测到外部管理的 Unix app-server；Mimi 只配置 Desktop 环境，不会在关闭时覆盖该 backend。"
}

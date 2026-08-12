package setup

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const codexSharingCleanupTimeout = 10 * time.Second

type CodexSharingConfigurationResult struct {
	Enabled               bool   `json:"enabled"`
	Changed               bool   `json:"changed"`
	RestartRequired       bool   `json:"restart_required"`
	DaemonRestartRequired bool   `json:"daemon_restart_required"`
	Transport             string `json:"transport"`
	CodexHome             string `json:"codex_home,omitempty"`
	Message               string `json:"message"`
}

type CodexSharingDaemonRestartResult struct {
	Restarted  bool   `json:"restarted"`
	SocketPath string `json:"socket_path"`
	Version    string `json:"version"`
	Message    string `json:"message"`
}

type ensureLocalDaemonFunc func(
	context.Context,
	appserver.LocalDaemonOptions,
) (appserver.LocalDaemonStatus, error)

type inspectLocalDaemonLifecycleFunc func(
	context.Context,
	appserver.LocalDaemonOptions,
) (appserver.LocalDaemonLifecycleStatus, error)

type removeSharedDaemonOwnerFunc func(context.Context) error

type restartSharedDaemonFunc func(
	context.Context,
	appserver.LocalDaemonOptions,
) (appserver.LocalDaemonStatus, error)

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
		appserver.RemoveSharedDaemonOwner,
	)
}

func configureCodexSharing(
	ctx context.Context,
	configPath string,
	enabled bool,
	ensureDaemon ensureLocalDaemonFunc,
	inspectDaemon inspectLocalDaemonLifecycleFunc,
	removeOwner removeSharedDaemonOwnerFunc,
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
	daemonRestartRequired := false
	ownerCleanupRequired := false
	var ownerRollback *appserver.SharedDaemonOwnerRollback
	failBeforeCommit := func(cause error) (CodexSharingConfigurationResult, error) {
		// 原请求可能已经超时，但回滚必须有独立且有上限的机会完成；Background
		// 会在另一进程持锁时无限等待，最终被 Mac App 强杀并遗留半成品 owner。
		cleanupCtx, cancelCleanup := context.WithTimeout(context.Background(), codexSharingCleanupTimeout)
		defer cancelCleanup()
		if enabled && ownerRollback != nil {
			if cleanupErr := appserver.RollbackSharedDaemonOwnerChange(cleanupCtx, ownerRollback); cleanupErr != nil {
				return CodexSharingConfigurationResult{}, fmt.Errorf(
					"准备共享 Codex 配置失败：%w；恢复原 daemon owner 也失败：%v",
					cause,
					cleanupErr,
				)
			}
		} else if enabled && ownerCleanupRequired {
			if cleanupErr := removeOwner(cleanupCtx); cleanupErr != nil {
				return CodexSharingConfigurationResult{}, fmt.Errorf(
					"准备共享 Codex 配置失败：%w；清理新建 daemon owner 也失败：%v",
					cause,
					cleanupErr,
				)
			}
		}
		return CodexSharingConfigurationResult{}, cause
	}
	if enabled {
		transport := strings.ToLower(strings.TrimSpace(cfg.AppServer.Transport))
		if transport == "unix" && cfg.AppServer.SharedFallback == nil {
			// 这是用户或其他工具预先配置的 Unix backend。共享开关只允许
			// Desktop attach；绝不能借“managed”字段替外部 owner 启动进程。
			status, attachErr := ensureDaemon(ctx, appserver.LocalDaemonOptions{
				CodexBin:   cfg.Codex.Bin,
				Env:        cfg.Codex.Env,
				AttachOnly: true,
			})
			if attachErr != nil {
				return CodexSharingConfigurationResult{}, attachErr
			}
			return CodexSharingConfigurationResult{
				Enabled:   true,
				Transport: "unix",
				CodexHome: localDaemonCodexHome(status.SocketPath),
				Message:   codexSharingAlreadyEnabledMessage(false, false),
			}, nil
		}
		status, err := ensureDaemon(ctx, appserver.LocalDaemonOptions{
			CodexBin:    cfg.Codex.Bin,
			Env:         cfg.Codex.Env,
			StableOwner: true,
		})
		if err != nil {
			return CodexSharingConfigurationResult{}, err
		}
		// 从非 Unix 配置启用失败时，本次新建或更新的 Mimi owner 都必须
		// 清理，不能让默认 WS 用户下次登录被一个半成品 job 静默拉起。
		ownerCleanupRequired = status.OwnerCreated || (transport != "unix" && status.OwnerChanged)
		ownerRollback = status.OwnerRollback
		daemonRestartRequired = status.OwnerMigrationRequired
		if !status.LifecycleValidated {
			lifecycle, err := inspectDaemon(ctx, appserver.LocalDaemonOptions{
				CodexBin: cfg.Codex.Bin,
				Env:      cfg.Codex.Env,
			})
			if err != nil {
				return failBeforeCommit(fmt.Errorf("确认 Codex daemon 冷启动能力失败：%w", err))
			}
			if err := appserver.ValidateLocalDaemonLifecycle(lifecycle, status.SocketPath); err != nil {
				return failBeforeCommit(err)
			}
			if err := appserver.ValidateLocalDaemonProbeVersion(lifecycle, status.Version); err != nil {
				return failBeforeCommit(err)
			}
		}
		codexHome = localDaemonCodexHome(status.SocketPath)
		if transport == "unix" {
			return CodexSharingConfigurationResult{
				Enabled:               true,
				Transport:             "unix",
				CodexHome:             codexHome,
				DaemonRestartRequired: daemonRestartRequired,
				Message:               codexSharingAlreadyEnabledMessage(cfg.AppServer.SharedFallback != nil, daemonRestartRequired),
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

	original, err := os.ReadFile(resolvedPath)
	if err != nil {
		return failBeforeCommit(fmt.Errorf("读取配置失败：%w", err))
	}
	document, appServerDocument, err := readCodexSharingConfigDocument(resolvedPath)
	if err != nil {
		return failBeforeCommit(err)
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
		return failBeforeCommit(fmt.Errorf("共享 Codex 配置无效：%w", err))
	}
	if err := encodeCodexSharingAppServer(appServerDocument, next.AppServer); err != nil {
		return failBeforeCommit(err)
	}
	encodedAppServer, err := json.Marshal(appServerDocument)
	if err != nil {
		return failBeforeCommit(fmt.Errorf("编码 app_server 配置失败：%w", err))
	}
	document["app_server"] = encodedAppServer
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return failBeforeCommit(fmt.Errorf("编码配置失败：%w", err))
	}
	updated = append(updated, '\n')
	if err := writePrivateFileAtomically(resolvedPath, updated); err != nil {
		return failBeforeCommit(fmt.Errorf("写入共享 Codex 配置失败：%w", err))
	}
	if !enabled {
		if err := removeOwner(ctx); err != nil {
			if rollbackErr := writePrivateFileAtomically(resolvedPath, original); rollbackErr != nil {
				return CodexSharingConfigurationResult{}, fmt.Errorf(
					"卸载共享 daemon owner 失败：%v；恢复原配置也失败：%w",
					err,
					rollbackErr,
				)
			}
			return CodexSharingConfigurationResult{}, fmt.Errorf("卸载共享 daemon owner 失败，已恢复原配置：%w", err)
		}
	}

	transport := strings.ToLower(strings.TrimSpace(next.AppServer.Transport))
	return CodexSharingConfigurationResult{
		Enabled:               enabled,
		Changed:               true,
		RestartRequired:       true,
		DaemonRestartRequired: daemonRestartRequired,
		Transport:             transport,
		CodexHome:             codexHome,
		Message:               codexSharingMessage(enabled, daemonRestartRequired),
	}, nil
}

// RestartCodexSharingDaemon 只供 Mac App 在用户确认“应用待处理设置”后调用。配置未由
// Mimi 切换到 shared unix 时拒绝执行，避免碰触外部部署方管理的 daemon。
func RestartCodexSharingDaemon(
	ctx context.Context,
	configPath string,
) (CodexSharingDaemonRestartResult, error) {
	return restartCodexSharingDaemon(
		ctx,
		configPath,
		appserver.RestartSharedDaemonWithStableOwner,
	)
}

func restartCodexSharingDaemon(
	ctx context.Context,
	configPath string,
	restartDaemon restartSharedDaemonFunc,
) (CodexSharingDaemonRestartResult, error) {
	resolvedPath, err := resolveConfigPath(configPath)
	if err != nil {
		return CodexSharingDaemonRestartResult{}, err
	}
	cfg, err := config.Load(resolvedPath)
	if err != nil {
		return CodexSharingDaemonRestartResult{}, err
	}
	if !strings.EqualFold(strings.TrimSpace(cfg.AppServer.Transport), "unix") ||
		cfg.AppServer.SharedFallback == nil {
		return CodexSharingDaemonRestartResult{}, fmt.Errorf("当前 Codex backend 不是 Mimi 管理的共享 daemon")
	}
	options := appserver.LocalDaemonOptions{CodexBin: cfg.Codex.Bin, Env: cfg.Codex.Env, StableOwner: true}
	status, err := restartDaemon(ctx, options)
	if err != nil {
		return CodexSharingDaemonRestartResult{}, err
	}
	// appserver 在同一把跨进程锁内完成 stop、kickstart、协议/生命周期/
	// 版本校验，最后才清除 migration marker。这里不能在提交点之后再做
	// 一次可失败的重复校验，否则瞬时读失败会“报错但已丢失可重试标记”。
	return CodexSharingDaemonRestartResult{
		Restarted:  status.Started,
		SocketPath: status.SocketPath,
		Version:    status.Version,
		Message:    codexSharingDaemonRestartMessage(status.Started),
	}, nil
}

func codexSharingDaemonRestartMessage(restarted bool) string {
	if restarted {
		return "共享 Codex daemon 已由稳定 launchd owner 重新创建。"
	}
	return "共享 Codex daemon 已由稳定 launchd owner 管理，无需重复重启。"
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

func codexSharingMessage(enabled bool, daemonRestartRequired bool) string {
	if enabled {
		if daemonRestartRequired {
			return "共享 Codex app-server 已启用；请使用 Mac App 的“应用待处理设置”迁移旧 daemon；若 Codex Desktop 正在运行，成功后会重新打开。"
		}
		return "共享 Codex app-server 已启用；重启 agentd 和 Codex Desktop 后生效。"
	}
	return "共享 Codex app-server 已关闭；重启 agentd 和 Codex Desktop 后生效。"
}

func codexSharingAlreadyEnabledMessage(owned bool, daemonRestartRequired bool) string {
	if owned {
		if daemonRestartRequired {
			return "Codex Desktop 与 Mimi 已配置为共用本地 app-server，但稳定 owner 迁移尚未完成；请在 Mac App 中选择“应用待处理设置”。"
		}
		return "Codex Desktop 与 Mimi 已配置为共用本地 app-server。"
	}
	return "已检测到外部管理的 Unix app-server；Mimi 只配置 Desktop 环境，不会在关闭时覆盖该 backend。"
}

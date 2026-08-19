package setup

import (
	"bytes"
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
	Enabled               bool   `json:"enabled"`
	Changed               bool   `json:"changed"`
	RestartRequired       bool   `json:"restart_required"`
	DaemonRestartRequired bool   `json:"daemon_restart_required"`
	Transport             string `json:"transport"`
	CodexHome             string `json:"codex_home,omitempty"`
	Warning               string `json:"warning,omitempty"`
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

type commitSharedDaemonDisableFunc func(
	context.Context,
	func() error,
	func() error,
) error

type commitSharedDaemonEnableFunc func(
	context.Context,
	appserver.LocalDaemonOptions,
	func() error,
	func() error,
) (appserver.LocalDaemonStatus, error)

type disableSharedDaemonAfterDesktopExitFunc func(
	context.Context,
	appserver.LocalDaemonOptions,
	func() error,
	func() error,
) error

// 单独保留读取 seam，只用于验证 typed config、未知字段 document 与 CAS
// baseline 确实来自同一份 bytes；生产始终调用 os.ReadFile。
var readCodexSharingConfigFile = os.ReadFile

// ConfigureCodexSharing 是从 legacy 独立 WS 进程切换到官方 local daemon 的
// 唯一持久化入口。先确认 daemon 真正可握手，再原子提交配置，避免只设置 Desktop
// 环境却让 agentd 继续使用另一进程，重新制造 writer lock 冲突。
func ConfigureCodexSharing(
	ctx context.Context,
	configPath string,
	enabled bool,
) (CodexSharingConfigurationResult, error) {
	// 空路径与其他 setup API 一样表示默认配置。必须在判断默认 owner 归属前
	// 先解析，否则 disable 会把默认 shared 配置改回 WS，却误走 custom 分支
	// 而留下用户全局的 RunAtLoad owner。
	resolvedPath, platformDefault, err := resolveCodexSharingTarget(configPath, enabled)
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	commitDisable := commitSharedDaemonDisableFunc(appserver.CommitSharedDaemonDisable)
	if !platformDefault {
		// 旧版本曾允许 custom profile 开启 direct shared。升级后必须允许它
		// 恢复自己的 fallback，但 custom profile 永远不能移除平台默认配置
		// 所有的用户全局 LaunchAgent。
		commitDisable = func(ctx context.Context, validate func() error, commit func() error) error {
			return appserver.CommitConfigWithSharedDaemonLock(ctx, validate, commit)
		}
	}
	return configureCodexSharingWithTransactions(
		ctx,
		resolvedPath,
		enabled,
		appserver.EnsureLocalDaemon,
		appserver.InspectLocalDaemonLifecycle,
		appserver.RemoveSharedDaemonOwner,
		appserver.CommitSharedDaemonEnable,
		commitDisable,
	)
}

// DisableCodexSharingAfterDesktopExit 只供调用方明确确认 Codex Desktop 已退出
// 后使用。平台默认配置只有在 appserver 完成 listener、socket/PID 和
// loaded LaunchAgent 的关闭事务后，才把保存的 fallback WS 提交回磁盘。
// 旧版 custom profile 只在配置锁内恢复自己的 fallback，不得触碰全局 owner。
func DisableCodexSharingAfterDesktopExit(
	ctx context.Context,
	configPath string,
) (CodexSharingConfigurationResult, error) {
	resolvedPath, platformDefault, err := resolveCodexSharingTarget(configPath, false)
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	if !platformDefault {
		// 历史版本允许 custom profile 保存 shared_fallback。这里复用
		// 普通关闭的 CAS/配置锁语义，不执行只属于平台默认配置的
		// listener 停止和 LaunchAgent bootout。
		return ConfigureCodexSharing(ctx, resolvedPath, false)
	}
	return disableCodexSharingAfterDesktopExit(
		ctx,
		resolvedPath,
		platformDefault,
		appserver.DisableSharedDaemonAfterDesktopExit,
	)
}

func disableCodexSharingAfterDesktopExit(
	ctx context.Context,
	configPath string,
	platformDefault bool,
	disableSharedDaemon disableSharedDaemonAfterDesktopExitFunc,
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
	original, err := readCodexSharingConfigFile(resolvedPath)
	if err != nil {
		return CodexSharingConfigurationResult{}, fmt.Errorf("读取配置失败：%w", err)
	}
	cfg, err := config.LoadSnapshot(original)
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	validateOriginal := func() error {
		current, readErr := readCodexSharingConfigFile(resolvedPath)
		if readErr != nil {
			return fmt.Errorf("重新读取配置失败：%w", readErr)
		}
		if !bytes.Equal(current, original) {
			return fmt.Errorf("配置已被其他进程修改，请重新执行")
		}
		return nil
	}
	transport := strings.ToLower(strings.TrimSpace(cfg.AppServer.Transport))
	if transport == "unix" && cfg.AppServer.SharedFallback == nil {
		// 没有 shared_fallback 时，Unix listener 的责任主体属于外部部署方。
		// confirmed disable 不能借配置开关停止或接管它；普通 disable 的兼容
		// 结果保持不变。
		return CodexSharingConfigurationResult{
			Enabled:   false,
			Transport: cfg.AppServer.Transport,
			Message:   "Codex Desktop 共享环境已关闭；外部管理的 Unix backend 保持不变。",
		}, nil
	}
	if !platformDefault {
		// 生产入口已在读取配置前把 custom profile 路由到配置锁事务。
		// 留下显式失败，避免未来的内部调用误报“已关闭”。
		return CodexSharingConfigurationResult{}, fmt.Errorf("自定义配置必须使用配置锁恢复 fallback")
	}
	if disableSharedDaemon == nil {
		return CodexSharingConfigurationResult{}, fmt.Errorf("禁用共享 daemon 缺少显式关闭事务")
	}

	options := appserver.LocalDaemonOptions{
		CodexBin:    cfg.Codex.Bin,
		Env:         cfg.Codex.Env,
		StableOwner: true,
	}
	if transport == "unix" && cfg.AppServer.SharedFallback != nil {
		document, appServerDocument, parseErr := parseCodexSharingConfigDocument(original)
		if parseErr != nil {
			return CodexSharingConfigurationResult{}, parseErr
		}
		fallback := cfg.AppServer.SharedFallback
		next := cfg
		next.AppServer.Transport = fallback.Transport
		next.AppServer.Managed = fallback.Managed
		next.AppServer.Listen = fallback.Listen
		next.AppServer.WSTokenFile = fallback.WSTokenFile
		next.AppServer.SharedFallback = nil
		if err := next.Validate(); err != nil {
			return CodexSharingConfigurationResult{}, fmt.Errorf("关闭后的 Codex 配置无效：%w", err)
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
		commitConfig := func() error {
			if err := writePrivateFileAtomicallyCAS(resolvedPath, original, updated); err != nil {
				return fmt.Errorf("写入共享 Codex 配置失败：%w", err)
			}
			return nil
		}
		options.ValidateStableOwner = func() error {
			return config.ValidateSharedDaemonRecoveryOwnership(resolvedPath, cfg.Codex.Bin, cfg.Codex.Env)
		}
		if err := disableSharedDaemon(ctx, options, validateOriginal, commitConfig); err != nil {
			return CodexSharingConfigurationResult{}, err
		}
		return CodexSharingConfigurationResult{
			Enabled:         false,
			Changed:         true,
			RestartRequired: true,
			Transport:       strings.ToLower(strings.TrimSpace(next.AppServer.Transport)),
			Message:         codexSharingMessage(false, false),
		}, nil
	}

	// 已经是 WS 时 confirmed 入口不改 JSON，只清理旧版 Mimi loaded job。
	// disabled ownership validator 允许这条幂等修复，但仍锁定 Codex bin/env，
	// 防止旧进程用过期配置清理新 owner。
	options.ValidateStableOwner = func() error {
		return config.ValidateSharedDaemonDisabledOwnership(resolvedPath, cfg.Codex.Bin, cfg.Codex.Env)
	}
	if err := disableSharedDaemon(ctx, options, validateOriginal, func() error { return nil }); err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	return CodexSharingConfigurationResult{
		Enabled:   false,
		Transport: cfg.AppServer.Transport,
		Message:   "Codex Desktop 共享会话服务已关闭。",
	}, nil
}

func resolveCodexSharingTarget(configPath string, enabled bool) (string, bool, error) {
	resolvedPath, err := resolveConfigPath(configPath)
	if err != nil {
		return "", false, err
	}
	if err := validateStableSharedDaemonTarget(resolvedPath, enabled); err != nil {
		return "", false, err
	}
	return resolvedPath, config.IsPlatformDefaultPath(resolvedPath), nil
}

func configureCodexSharing(
	ctx context.Context,
	configPath string,
	enabled bool,
	ensureDaemon ensureLocalDaemonFunc,
	inspectDaemon inspectLocalDaemonLifecycleFunc,
	removeOwner removeSharedDaemonOwnerFunc,
) (CodexSharingConfigurationResult, error) {
	return configureCodexSharingWithTransactions(
		ctx,
		configPath,
		enabled,
		ensureDaemon,
		inspectDaemon,
		removeOwner,
		func(
			ctx context.Context,
			options appserver.LocalDaemonOptions,
			validate func() error,
			commit func() error,
		) (appserver.LocalDaemonStatus, error) {
			if err := validate(); err != nil {
				return appserver.LocalDaemonStatus{}, err
			}
			status, err := ensureDaemon(ctx, options)
			if err != nil {
				return appserver.LocalDaemonStatus{}, err
			}
			cleanupPreparedOwner := func(cause error) (appserver.LocalDaemonStatus, error) {
				if status.OwnerCreated || status.OwnerChanged {
					if cleanupErr := removeOwner(context.Background()); cleanupErr != nil {
						return appserver.LocalDaemonStatus{}, fmt.Errorf("%w；清理未提交的共享 daemon owner 也失败：%v", cause, cleanupErr)
					}
				}
				return appserver.LocalDaemonStatus{}, cause
			}
			if !status.LifecycleValidated {
				lifecycle, inspectErr := inspectDaemon(ctx, options)
				if inspectErr != nil {
					return cleanupPreparedOwner(inspectErr)
				}
				if validateErr := appserver.ValidateLocalDaemonLifecycle(lifecycle, status.SocketPath); validateErr != nil {
					return cleanupPreparedOwner(validateErr)
				}
				if validateErr := appserver.ValidateLocalDaemonProbeVersion(lifecycle, status.Version); validateErr != nil {
					return cleanupPreparedOwner(validateErr)
				}
			}
			if err := commit(); err != nil {
				return cleanupPreparedOwner(err)
			}
			return status, nil
		},
		func(ctx context.Context, validate func() error, commit func() error) error {
			if err := validate(); err != nil {
				return err
			}
			if err := removeOwner(ctx); err != nil {
				return err
			}
			return commit()
		},
	)
}

func configureCodexSharingWithTransactions(
	ctx context.Context,
	configPath string,
	enabled bool,
	ensureDaemon ensureLocalDaemonFunc,
	inspectDaemon inspectLocalDaemonLifecycleFunc,
	removeOwner removeSharedDaemonOwnerFunc,
	commitEnable commitSharedDaemonEnableFunc,
	commitDisable commitSharedDaemonDisableFunc,
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
	original, err := readCodexSharingConfigFile(resolvedPath)
	if err != nil {
		return CodexSharingConfigurationResult{}, fmt.Errorf("读取配置失败：%w", err)
	}
	// typed cfg、保留未知字段的 JSON document 与后续 CAS 必须来自同一次
	// ReadFile。分开 Load(path)/ReadFile(path) 会在并发写入时把两代配置拼接，
	// 让旧操作错误取得新快照的提交权。
	cfg, err := config.LoadSnapshot(original)
	if err != nil {
		return CodexSharingConfigurationResult{}, err
	}
	validateOriginal := func() error {
		current, readErr := readCodexSharingConfigFile(resolvedPath)
		if readErr != nil {
			return fmt.Errorf("重新读取配置失败：%w", readErr)
		}
		if !bytes.Equal(current, original) {
			return fmt.Errorf("配置已被其他进程修改，请重新执行")
		}
		return nil
	}

	codexHome := ""
	daemonRestartRequired := false
	transport := strings.ToLower(strings.TrimSpace(cfg.AppServer.Transport))
	if enabled {
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
		if transport == "unix" {
			options := appserver.LocalDaemonOptions{
				CodexBin:    cfg.Codex.Bin,
				Env:         cfg.Codex.Env,
				StableOwner: true,
				ValidateStableOwner: func() error {
					return config.ValidateSharedDaemonRecoveryOwnership(
						resolvedPath,
						cfg.Codex.Bin,
						cfg.Codex.Env,
					)
				},
			}
			status, ensureErr := ensureDaemon(ctx, options)
			if ensureErr != nil {
				return CodexSharingConfigurationResult{}, ensureErr
			}
			if !status.LifecycleValidated {
				lifecycle, inspectErr := inspectDaemon(ctx, options)
				if inspectErr != nil {
					return CodexSharingConfigurationResult{}, fmt.Errorf("确认 Codex daemon 冷启动能力失败：%w", inspectErr)
				}
				if validateErr := appserver.ValidateLocalDaemonLifecycle(lifecycle, status.SocketPath); validateErr != nil {
					return CodexSharingConfigurationResult{}, validateErr
				}
				if validateErr := appserver.ValidateLocalDaemonProbeVersion(lifecycle, status.Version); validateErr != nil {
					return CodexSharingConfigurationResult{}, validateErr
				}
			}
			codexHome = localDaemonCodexHome(status.SocketPath)
			daemonRestartRequired = status.OwnerMigrationRequired
			return CodexSharingConfigurationResult{
				Enabled:               true,
				Transport:             "unix",
				CodexHome:             codexHome,
				DaemonRestartRequired: daemonRestartRequired,
				Message:               codexSharingAlreadyEnabledMessage(cfg.AppServer.SharedFallback != nil, daemonRestartRequired),
			}, nil
		}
	} else {
		if transport != "unix" {
			// 上一次关闭可能已提交 WS 配置，却在卸载 Mimi 专属 owner 前进程
			// 退出。关闭操作必须可重入：即使配置已经是非 Unix，也再次收敛
			// plist/loaded job/marker，避免残留 owner 在下次登录继续自启。
			if commitDisable == nil {
				return CodexSharingConfigurationResult{}, fmt.Errorf("禁用共享 daemon 缺少原子清理能力")
			}
			if err := commitDisable(ctx, validateOriginal, func() error { return nil }); err != nil {
				return CodexSharingConfigurationResult{}, fmt.Errorf("清理残留共享 daemon owner 失败：%w", err)
			}
			return CodexSharingConfigurationResult{
				Enabled:   false,
				Transport: cfg.AppServer.Transport,
				Message:   "Codex Desktop 共享会话服务已关闭。",
			}, nil
		}
		if cfg.AppServer.SharedFallback == nil {
			// 当前 Unix transport 不是 Mimi 从 WS 切换而来，因此没有可验证的
			// 原配置可恢复。只清理 Mimi 自己可能残留的 owner，绝不能虚构
			// 默认 WS 覆盖外部配置，也不会停止当前外部 daemon。
			if commitDisable == nil {
				return CodexSharingConfigurationResult{}, fmt.Errorf("禁用共享 daemon 缺少原子清理能力")
			}
			if err := commitDisable(ctx, validateOriginal, func() error { return nil }); err != nil {
				return CodexSharingConfigurationResult{}, fmt.Errorf("清理残留共享 daemon owner 失败：%w", err)
			}
			return CodexSharingConfigurationResult{
				Enabled:   false,
				Transport: "unix",
				Message:   "Codex Desktop 共享环境已关闭；外部管理的 Unix backend 保持不变。",
			}, nil
		}
	}

	document, appServerDocument, err := parseCodexSharingConfigDocument(original)
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
	commitConfig := func() error {
		// daemon 准备可能持续数秒；最终 CAS 与 rename 共用 Mimi 配置提交锁，
		// 避免 Claude/network/另一条 sharing 命令在两步间互相覆盖。
		if err := writePrivateFileAtomicallyCAS(resolvedPath, original, updated); err != nil {
			return fmt.Errorf("写入共享 Codex 配置失败：%w", err)
		}
		return nil
	}
	if enabled {
		if commitEnable == nil {
			return CodexSharingConfigurationResult{}, fmt.Errorf("启用共享 daemon 缺少两阶段提交能力")
		}
		status, commitErr := commitEnable(
			ctx,
			appserver.LocalDaemonOptions{
				CodexBin:                    cfg.Codex.Bin,
				Env:                         cfg.Codex.Env,
				StableOwner:                 true,
				PrepareOwnerForConfigCommit: true,
			},
			validateOriginal,
			commitConfig,
		)
		if commitErr != nil {
			if !status.ConfigCommitted {
				return CodexSharingConfigurationResult{}, commitErr
			}
			// 配置 rename 是提交点。其后的 daemon start/握手失败必须仍以
			// enabled+pending 的机器可读结果返回，让 Mac App 重载 shared 配置
			// 并显示“应用待处理设置”，而不是留在旧 WS Router 且无恢复入口。
			codexHome = localDaemonCodexHome(status.SocketPath)
			daemonRestartRequired = true
			return CodexSharingConfigurationResult{
				Enabled:               true,
				Changed:               true,
				RestartRequired:       true,
				DaemonRestartRequired: true,
				Transport:             "unix",
				CodexHome:             codexHome,
				Warning:               commitErr.Error(),
				Message:               "共享 Codex 配置已提交；daemon 启动未完成，请重载服务后使用“应用待处理设置”恢复。",
			}, nil
		}
		codexHome = localDaemonCodexHome(status.SocketPath)
		daemonRestartRequired = status.OwnerMigrationRequired
	} else {
		if commitDisable == nil {
			return CodexSharingConfigurationResult{}, fmt.Errorf("禁用共享 daemon 缺少原子提交能力")
		}
		if err := commitDisable(ctx, validateOriginal, commitConfig); err != nil {
			return CodexSharingConfigurationResult{}, err
		}
	}

	transport = strings.ToLower(strings.TrimSpace(next.AppServer.Transport))
	warning := ""
	if !enabled && !config.IsPlatformDefaultPath(resolvedPath) {
		warning = "已恢复自定义配置的 fallback；未触碰平台默认配置所拥有的共享 daemon owner。"
	}
	return CodexSharingConfigurationResult{
		Enabled:               enabled,
		Changed:               true,
		RestartRequired:       true,
		DaemonRestartRequired: daemonRestartRequired,
		Transport:             transport,
		CodexHome:             codexHome,
		Warning:               warning,
		Message:               codexSharingMessage(enabled, daemonRestartRequired),
	}, nil
}

// RestartCodexSharingDaemon 只供 Mac App 在用户确认“应用待处理设置”后调用。配置未由
// Mimi 切换到 shared unix 时拒绝执行，避免碰触外部部署方管理的 daemon。
func RestartCodexSharingDaemon(
	ctx context.Context,
	configPath string,
) (CodexSharingDaemonRestartResult, error) {
	if err := validateStableSharedDaemonTarget(configPath, true); err != nil {
		return CodexSharingDaemonRestartResult{}, err
	}
	return restartCodexSharingDaemon(
		ctx,
		configPath,
		appserver.RestartSharedDaemonWithStableOwner,
	)
}

func validateStableSharedDaemonTarget(configPath string, enabling bool) error {
	// 非 macOS 旧版本可能已经写入 Mimi shared 配置。升级后仍允许 disable
	// 回退到保存的 fallback；只拒绝继续启用或执行 owner restart。
	if enabling && !appserver.SupportsStableSharedDaemonOwner() {
		return fmt.Errorf("Codex 完整共享 daemon owner 当前仅支持 macOS")
	}
	resolvedPath, err := resolveConfigPath(configPath)
	if err != nil {
		return err
	}
	if enabling && appserver.SupportsStableSharedDaemonOwner() && !config.IsPlatformDefaultPath(resolvedPath) {
		return fmt.Errorf("Codex 完整共享 daemon 只能使用平台默认配置：%s", config.PlatformDefaultPath())
	}
	return nil
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
	// Desktop 此时可能已经按用户确认正常退出。控制面只读取 daemon 身份，
	// 不能让无关的 scan_roots I/O 再把迁移挡在生命周期操作之前。
	cfg, err := config.LoadSharedDaemonControlConfig(resolvedPath)
	if err != nil {
		return CodexSharingDaemonRestartResult{}, err
	}
	if !strings.EqualFold(strings.TrimSpace(cfg.AppServer.Transport), "unix") ||
		!cfg.AppServer.Managed || cfg.AppServer.SharedFallback == nil {
		return CodexSharingDaemonRestartResult{}, fmt.Errorf("当前 Codex backend 不是 Mimi 管理的共享 daemon")
	}
	options := appserver.LocalDaemonOptions{
		CodexBin:    cfg.Codex.Bin,
		Env:         cfg.Codex.Env,
		StableOwner: true,
		ValidateStableOwner: func() error {
			return config.ValidateSharedDaemonRecoveryOwnership(resolvedPath, cfg.Codex.Bin, cfg.Codex.Env)
		},
	}
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

func parseCodexSharingConfigDocument(raw []byte) (
	map[string]json.RawMessage,
	map[string]json.RawMessage,
	error,
) {
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

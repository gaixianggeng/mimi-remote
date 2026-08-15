//go:build !darwin

package appserver

import (
	"context"
	"fmt"
	"os"
	"time"
)

const sharedDaemonStartTimeoutForLocalEnsure = 15 * time.Second

type SharedDaemonOwnerStatus struct {
	Supported         bool
	Installed         bool
	Loaded            bool
	Running           bool
	Secure            bool
	RunAtLoad         bool
	Changed           bool
	Created           bool
	MigrationRequired bool
	Path              string
	Label             string
	Rollback          *SharedDaemonOwnerRollback
}

// 非 macOS 没有本实现所依赖的 launchd/TCC owner 语义。与其用进程内 no-op
// lock 假装支持共享 owner，不如在生产入口明确拒绝，避免并发配置留下双 backend。
func SupportsStableSharedDaemonOwner() bool { return false }

func EnsureSharedDaemonOwner(
	context.Context,
	LocalDaemonOptions,
	bool,
) (SharedDaemonOwnerStatus, error) {
	return SharedDaemonOwnerStatus{}, nil
}

// 非 macOS 没有 launchd/TCC owner 迁移状态。保留与 Darwin 内部 helper 相同的
// 签名，让跨平台 local daemon 逻辑可以统一调用；forcePending 在这里没有语义。
func ensureSharedDaemonOwner(
	ctx context.Context,
	options LocalDaemonOptions,
	daemonPreexisting bool,
	_ bool,
) (SharedDaemonOwnerStatus, error) {
	return EnsureSharedDaemonOwner(ctx, options, daemonPreexisting)
}

func InspectSharedDaemonOwner(context.Context) (SharedDaemonOwnerStatus, error) {
	return SharedDaemonOwnerStatus{}, nil
}

func SharedDaemonMigrationRequired() (bool, error) { return false, nil }

func SharedDaemonOwnerArtifactsPresent() (bool, error) { return false, nil }

func markSharedDaemonEnablePrepared() error { return nil }

func sharedDaemonEnablePrepared() (bool, error) { return false, nil }

func clearSharedDaemonEnablePrepared() error { return nil }

func clearSharedDaemonMigrationFlag() error { return nil }

func markSharedDaemonMigrationRequired() error {
	return fmt.Errorf("稳定共享 daemon owner 仅支持 macOS")
}

func withSharedDaemonOperationLock(
	_ context.Context,
	operation func() (LocalDaemonStatus, error),
) (LocalDaemonStatus, error) {
	return operation()
}

func RemoveSharedDaemonOwner(context.Context) error { return nil }

func removeSharedDaemonOwnerUnlocked(context.Context) error { return nil }

func removeSharedDaemonOwnerForTransactionUnlocked(
	context.Context,
) (func(context.Context) error, error) {
	return func(context.Context) error { return nil }, nil
}

func startPreparedSharedDaemonAfterConfigCommit(
	ctx context.Context,
	options LocalDaemonOptions,
) (LocalDaemonStatus, error) {
	if err := startLocalDaemonDirect(ctx, options); err != nil {
		return LocalDaemonStatus{}, err
	}
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancel()
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	status := localDaemonStatus(socketPath, true, probe.Version, os.Stat)
	status.StartedByStableOwner = true
	status.LifecycleValidated = true
	if err := clearSharedDaemonEnablePrepared(); err != nil {
		return LocalDaemonStatus{}, err
	}
	return status, nil
}

func RollbackSharedDaemonOwnerChange(context.Context, *SharedDaemonOwnerRollback) error { return nil }

func RestartSharedDaemonWithStableOwner(
	context.Context,
	LocalDaemonOptions,
) (LocalDaemonStatus, error) {
	return LocalDaemonStatus{}, fmt.Errorf("稳定共享 daemon owner 仅支持 macOS")
}

// 非 macOS 平台没有 TCC responsible process 这一层，共享 daemon 的权限主体不受
// 启动者影响，继续沿用官方 CLI 的直接启动路径。
func startLocalDaemonWithStableOwner(ctx context.Context, options LocalDaemonOptions) error {
	return startLocalDaemonDirect(ctx, options)
}

func startLocalDaemonWithStableOwnerTracked(ctx context.Context, options LocalDaemonOptions) (bool, error) {
	return false, startLocalDaemonDirect(ctx, options)
}

func startPreparedSharedDaemonWithStableOwnerTracked(
	ctx context.Context,
	options LocalDaemonOptions,
) (bool, error) {
	return false, startLocalDaemonDirect(ctx, options)
}

func sharedDaemonSocketAcceptsConnectionMust(LocalDaemonOptions) bool { return false }

func sharedDaemonLaunchAgentLogSize() int64 { return 0 }

func waitForSharedDaemonSocket(context.Context, LocalDaemonOptions, int64) error {
	return fmt.Errorf("稳定共享 daemon owner 仅支持 macOS")
}

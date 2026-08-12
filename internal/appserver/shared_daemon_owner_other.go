//go:build !darwin

package appserver

import (
	"context"
	"fmt"
	"time"
)

const sharedDaemonStartTimeoutForLocalEnsure = 15 * time.Second

type SharedDaemonOwnerStatus struct {
	Supported         bool
	Installed         bool
	Loaded            bool
	Running           bool
	Secure            bool
	Changed           bool
	Created           bool
	MigrationRequired bool
	Path              string
	Label             string
	Rollback          *SharedDaemonOwnerRollback
}

func EnsureSharedDaemonOwner(
	context.Context,
	LocalDaemonOptions,
	bool,
) (SharedDaemonOwnerStatus, error) {
	return SharedDaemonOwnerStatus{}, nil
}

func InspectSharedDaemonOwner(context.Context) (SharedDaemonOwnerStatus, error) {
	return SharedDaemonOwnerStatus{}, nil
}

func SharedDaemonMigrationRequired() (bool, error) { return false, nil }

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

func sharedDaemonSocketAcceptsConnectionMust(LocalDaemonOptions) bool { return false }

package setup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// withConfigCommitLock 只覆盖“重新读取 expected bytes → rename”的最终提交段。
// Mimi 的 sharing/Claude/network/repair 写入都使用同一把跨进程锁，因此不会在
// 各自的 compare-and-swap 与 rename 之间互相插入。锁外编辑器无法被强制遵守
// 本协议，调用方仍保留最后一跳 bytes 复核并在冲突时 fail closed。
func withConfigCommitLock(
	ctx context.Context,
	configPath string,
	commit func() error,
) error {
	if commit == nil {
		return fmt.Errorf("配置提交回调不能为空")
	}
	lockPath, err := configCommitLockPath(configPath)
	if err != nil {
		return err
	}
	unlock, err := acquireConfigCommitLock(ctx, lockPath)
	if err != nil {
		return err
	}
	defer unlock()
	return commit()
}

func configCommitLockPath(configPath string) (string, error) {
	absPath, err := config.ConfigPathIdentity(configPath)
	if err != nil {
		return "", fmt.Errorf("解析配置提交锁目标失败：%w", err)
	}
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("解析配置提交锁目录失败：%w", err)
	}
	digest := sha256.Sum256([]byte(absPath))
	name := hex.EncodeToString(digest[:16]) + ".lock"
	return filepath.Join(cacheDir, "mimi-remote", "config-locks", name), nil
}

// commitConfigReplacingOwnedSharedDaemon 把“用户全局 owner”严格限定给平台
// 默认配置。自定义 --config profile 仍与 daemon 事务串行提交，但绝不能因此
// 删除默认后台服务正在使用的 LaunchAgent。
func commitConfigReplacingOwnedSharedDaemon(
	ctx context.Context,
	configPath string,
	validate func() error,
	commit func() error,
) error {
	if config.IsPlatformDefaultPath(configPath) {
		return appserver.CommitConfigReplacingSharedDaemon(ctx, validate, commit)
	}
	return appserver.CommitConfigWithSharedDaemonLock(ctx, validate, commit)
}

// commitConfigRepairingOwnedSharedDaemonIdentity 与普通 setup replacement
// 分开：Doctor 只更新 codex.bin，配置仍是 shared。默认配置若正处于 manual
// pending，必须保留 marker/owner；custom profile 仍不能触碰用户全局 owner。
func commitConfigRepairingOwnedSharedDaemonIdentity(
	ctx context.Context,
	configPath string,
	validate func() error,
	commit func() error,
) error {
	if config.IsPlatformDefaultPath(configPath) {
		return appserver.CommitConfigRepairingSharedDaemonIdentity(ctx, validate, commit)
	}
	return appserver.CommitConfigWithSharedDaemonLock(ctx, validate, commit)
}

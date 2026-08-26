//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// AcquireSharedDaemonUsageFence 让共享 daemon 重启等待写请求收到上游响应。
func AcquireSharedDaemonUsageFence(ctx context.Context) (func(), error) {
	return acquireSharedDaemonOperationLock(ctx, syscall.LOCK_SH, "使用")
}

func sharedDaemonOperationLockPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("解析用户 Home 失败：%w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "mimi-remote", sharedDaemonOperationLockName), nil
}

// withSharedDaemonOperationLock 跨进程序列化启动、gateway 恢复与显式迁移。
// 仅靠 Router mutex 无法阻止独立 runtime CLI 在 stop/start 中间被另一进程插入。
func withSharedDaemonOperationLock(
	ctx context.Context,
	operation func() (LocalDaemonStatus, error),
) (LocalDaemonStatus, error) {
	release, err := acquireSharedDaemonOperationLock(ctx, syscall.LOCK_EX, "操作")
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	defer release()
	return operation()
}

func acquireSharedDaemonOperationLock(ctx context.Context, mode int, purpose string) (func(), error) {
	file, err := openSharedDaemonOperationLockFile()
	if err != nil {
		return nil, err
	}
	for {
		err = syscall.Flock(int(file.Fd()), mode|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			_ = file.Close()
			return nil, fmt.Errorf("获取共享 daemon %s锁失败：%w", purpose, err)
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-time.After(sharedDaemonSocketPollInterval):
		}
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
			_ = file.Close()
		})
	}, nil
}

func openSharedDaemonOperationLockFile() (*os.File, error) {
	path, err := sharedDaemonOperationLockPath()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("创建共享 daemon 锁目录失败：%w", err)
	}
	if info, statErr := os.Lstat(path); statErr == nil {
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("共享 daemon 操作锁必须是普通文件")
		}
	} else if !os.IsNotExist(statErr) {
		return nil, fmt.Errorf("检查共享 daemon 操作锁失败：%w", statErr)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("打开共享 daemon 操作锁失败：%w", err)
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("收紧共享 daemon 操作锁权限失败：%w", err)
	}
	return file, nil
}

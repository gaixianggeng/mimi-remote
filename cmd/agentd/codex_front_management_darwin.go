//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

const codexFrontManagementLockTimeout = 90 * time.Second

// codexFrontManagementOps 让安装事务在测试中使用确定性的 launchd 模型，
// 避免测试接触用户真实的 LaunchAgent 和 socket。
type codexFrontManagementOps struct {
	loaded          func(string) bool
	bootout         func(string) error
	bootstrap       func(string) error
	socketListening func(string) bool
}

func defaultCodexFrontManagementOps() codexFrontManagementOps {
	return codexFrontManagementOps{
		loaded:          codexFrontLoaded,
		bootout:         codexFrontBootout,
		bootstrap:       codexFrontBootstrap,
		socketListening: codexFrontSocketListening,
	}
}

func lockCodexFrontManagement(label string, exclusive bool) (func(), error) {
	ctx, cancel := context.WithTimeout(context.Background(), codexFrontManagementLockTimeout)
	unlock, err := appserver.LockFrontDoorManagement(ctx, label, exclusive)
	cancel()
	if err != nil {
		return nil, fmt.Errorf("等待前门管理操作完成失败：%w", err)
	}
	return unlock, nil
}

func restoreCodexFrontPlist(path string, previous []byte, existed bool) error {
	if existed {
		return writeFileAtomically(path, previous, 0o644)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// rollbackCodexFrontInstall 撤销本次加载，并恢复安装前磁盘与 launchd 状态。
// 管理锁由调用方持有，回滚完成前其它 install/uninstall/status 都看不到中间状态。
func rollbackCodexFrontInstall(install codexFrontInstallation, ops codexFrontManagementOps, wasLoaded bool, previous []byte, existed bool) error {
	// bootstrap 失败时 launchd 可能已经创建了 job，但 print 尚未稳定；始终尝试 bootout，
	// 不能复用安装前的 loaded=false 判断，否则会留下磁盘与运行态身份分裂。
	rollbackErr := ops.bootout(install.Label)
	if rollbackErr != nil {
		return rollbackErr
	}
	rollbackErr = errors.Join(rollbackErr, restoreCodexFrontPlist(install.PlistPath, previous, existed))
	if rollbackErr == nil && wasLoaded {
		rollbackErr = errors.Join(rollbackErr, ops.bootstrap(install.PlistPath))
	}
	return rollbackErr
}

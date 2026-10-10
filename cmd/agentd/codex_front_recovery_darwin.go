//go:build darwin

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
)

// 调用方持有管理锁，且仅在 backend 已退出、启动/迁移锁仍持有时执行返回的操作。
// 不复用 install 的管理锁和空闲检查，避免确认断连后仍被旧前门的重连者挡住。
func prepareCodexFrontRecovery(install codexFrontInstallation, configPath, executable string, ops codexFrontManagementOps) (func(context.Context) error, error) {
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	args, err := codexFrontProgramArguments(executable, false, configPath, "")
	if err != nil {
		return nil, err
	}
	revision, err := codexFrontExecutableRevision(executable)
	if err != nil {
		return nil, err
	}
	previous, err := os.ReadFile(install.PlistPath)
	if err != nil {
		return nil, err
	}
	plist := renderCodexFrontPlist(install.Label, args, install.Socket, revision, install.BackendHome)
	return func(ctx context.Context) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := writeFileAtomically(install.PlistPath, plist, 0o644); err != nil {
			return err
		}
		if err := ops.bootout(install.Label); err != nil {
			return errors.Join(err, restoreCodexFrontPlist(install.PlistPath, previous, true))
		}
		if err := ops.bootstrap(install.PlistPath); err != nil {
			return errors.Join(err, rollbackCodexFrontInstall(install, ops, true, previous, true))
		}
		if !ops.socketListening(install.Socket) {
			return errors.Join(errors.New("Codex 前门已重新加载，但标准 socket 尚未就绪"),
				rollbackCodexFrontInstall(install, ops, true, previous, true))
		}
		return nil
	}, nil
}

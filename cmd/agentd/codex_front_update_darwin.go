//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func runCodexFrontRuntime(args []string, stdout io.Writer, update bool) error {
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	configPath, label, plistPath := codexFrontFlags(fs)
	restart := fs.Bool("restart", false, "已确认断开共享连接并可能中断任务，重启后台以修复设置或切换版本")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("Codex 版本管理不接受额外参数")
	}
	if *restart && !update {
		return errors.New("--restart 仅适用于 codex-front update")
	}
	budget := 8 * time.Second
	if update {
		budget = 35 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()
	unlock, err := appserver.LockFrontDoorManagement(ctx, *label, update)
	if err != nil {
		return errors.New("另一项 Codex 管理操作正在进行，请稍后重试。")
	}
	defer unlock()
	cfg, err := config.LoadForDoctor(*configPath)
	if err != nil {
		return errors.New("无法读取 Mimi 配置，请运行诊断。")
	}
	if !cfg.Codex.IsEnabled() || cfg.AppServer.Transport != "local" || cfg.AppServer.SSHTarget != "" {
		return errors.New("请在运行 Codex 的电脑上管理版本；此入口仅支持 Mimi 托管的本机 Codex。")
	}
	install, err := resolveCodexFrontInstallation(*configPath, *label, *plistPath)
	if err != nil {
		return errors.New("无法确认共享 Codex 配置，请运行诊断。")
	}
	if !codexFrontLoaded(install.Label) {
		return errors.New("请先启动 Mimi 的 Codex 服务，再检查版本。")
	}
	registered, err := registeredCodexFrontDoor(install.PlistPath)
	if err != nil || registered.PublicSocketPath() != install.Socket || registered.BackendCodexHome() != install.BackendHome {
		return errors.New("共享 Codex 的运行配置已改变，请先运行诊断；当前后台保持不变。")
	}
	var versions appserver.CodexRuntimeVersions
	var reloadFrontDoor func(context.Context) error
	if update {
		versions, err = install.door.RuntimeVersions(ctx)
		if err != nil {
			return err
		}
		if versions.UpdateAvailable || versions.FeatureMismatch {
			executable, err := os.Executable()
			if err != nil {
				return err
			}
			reloadFrontDoor, err = prepareCodexFrontRecovery(install, *configPath, executable, defaultCodexFrontManagementOps())
			if err != nil {
				return errors.New("无法准备 Codex 连接修复，请从已安装的 Mimi Remote Mac 运行诊断后重试；后台保持不变。")
			}
		}
	}
	if update && *restart {
		versions, err = install.door.RestartRuntime(ctx, reloadFrontDoor)
	} else if update {
		versions, err = install.door.UpdateRuntime(ctx, reloadFrontDoor)
	} else {
		versions, err = install.door.RuntimeVersions(ctx)
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(stdout).Encode(struct {
		appserver.CodexRuntimeVersions
		Connections *appserver.CodexRuntimeConnections `json:"connections,omitempty"`
	}{versions, install.door.RuntimeConnections(ctx)})
}

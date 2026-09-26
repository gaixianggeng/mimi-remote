//go:build darwin

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const codexFrontBackendHomeKey = "MIMI_CODEX_FRONT_BACKEND_HOME"

func codexFrontOptions(cfg config.Config) appserver.SharedLocalOptions {
	return appserver.SharedLocalOptions{
		CodexBin: cfg.Codex.Bin, Env: cfg.Codex.Env,
		BackendCodexHome: cfg.AppServer.SharedCodexHome,
	}
}

func configuredCodexFrontDoor(cfg config.Config) (*appserver.FrontDoor, error) {
	if err := cfg.ValidateSharedCodexHome(); err != nil {
		return nil, err
	}
	return appserver.NewFrontDoor(codexFrontOptions(cfg), nil)
}

// 固定安装时的目录，防止 config.json 已改变而仍有旧前门连接时静默开启第二份历史。
func validateCodexFrontPinnedHome(pinned string, door *appserver.FrontDoor, isolated bool) error {
	if pinned == "" && !isolated {
		return nil // 旧版本默认前门没有此标记，升级仍沿用同一目录。
	}
	if pinned == "" || filepath.Clean(pinned) != door.BackendCodexHome() {
		return errors.New("前门后端会话目录与安装记录不一致；请恢复原配置，用 --stop-idle-backend 安全卸载后再切换目录")
	}
	return nil
}

func codexFrontPlistBackendHome(path string) (string, error) {
	_, home, err := codexFrontPlistIdentity(path)
	return home, err
}

func codexFrontPlistIdentity(path string) (string, string, error) {
	data, err := exec.Command("/usr/bin/plutil", "-convert", "json", "-o", "-", path).Output()
	if err != nil {
		return "", "", fmt.Errorf("无法读取前门已登记的后端目录：%w", err)
	}
	var job struct {
		Environment map[string]string `json:"EnvironmentVariables"`
		Sockets     struct {
			Listeners struct {
				Path string `json:"SockPathName"`
			} `json:"Listeners"`
		} `json:"Sockets"`
	}
	if err := json.Unmarshal(data, &job); err != nil {
		return "", "", fmt.Errorf("解析前门后端目录失败：%w", err)
	}
	home := job.Environment[codexFrontBackendHomeKey]
	if home == "" {
		// 旧版的 backend 和 public socket 都位于同一 CODEX_HOME 下。
		if !filepath.IsAbs(job.Sockets.Listeners.Path) {
			return "", "", errors.New("旧前门缺少有效的标准 socket，拒绝推测后端目录")
		}
		home = filepath.Dir(filepath.Dir(job.Sockets.Listeners.Path))
	}
	if !filepath.IsAbs(home) {
		return "", "", errors.New("前门已登记的后端目录不是绝对路径")
	}
	return filepath.Clean(job.Sockets.Listeners.Path), filepath.Clean(home), nil
}

func validateCodexFrontRegisteredHome(path, desired string) error {
	registered, err := codexFrontPlistBackendHome(path)
	if err != nil {
		return err
	}
	if registered != desired {
		return errors.New("前门已登记的会话目录与配置不同；请恢复原配置，用 codex-front uninstall --stop-idle-backend 安全卸载，再修改 shared_codex_home 并安装")
	}
	return nil
}

func registeredCodexFrontDoor(path string) (*appserver.FrontDoor, error) {
	socket, home, err := codexFrontPlistIdentity(path)
	if err != nil {
		return nil, err
	}
	publicHome := filepath.Dir(filepath.Dir(socket))
	options := appserver.SharedLocalOptions{Env: map[string]string{"CODEX_HOME": publicHome}}
	if home != publicHome {
		options.BackendCodexHome = home
	}
	return appserver.NewFrontDoor(options, nil)
}

// 旧版允许卸载前门但保留 backend。启用隔离前必须排除这种仍在执行旧任务的遗留进程。
func rejectLegacyBackendForIsolation(install codexFrontInstallation) error {
	if install.BackendHome == filepath.Dir(filepath.Dir(install.Socket)) {
		return nil
	}
	legacy := filepath.Join(filepath.Dir(install.Socket), "app-server-backend.sock")
	info, err := os.Lstat(legacy)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("无法确认旧默认后端已退出：%w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("旧默认后端路径被非 socket 文件占用，拒绝启用独立会话目录")
	}
	conn, err := net.DialTimeout("unix", legacy, time.Second)
	if err == nil {
		_ = conn.Close()
		return errors.New("旧默认 Codex 后端仍在运行；请先用原配置安全停止空闲后端，再启用独立会话目录")
	}
	if errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return fmt.Errorf("无法确认旧默认后端已退出：%w", err)
}

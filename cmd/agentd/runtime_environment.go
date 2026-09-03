package main

import (
	"context"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"

	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

// ServiceManagement 注册的 BundleProgram 不保证带 HOME。没有 HOME 时，
// os.UserConfigDir 会退化失败，agentd 会误读当前目录下的 config.json；Codex
// 子进程也会指向错误的状态目录。只补缺失值，不覆盖用户或服务显式配置。
func ensureProcessUserEnvironment() error {
	if strings.TrimSpace(os.Getenv("HOME")) != "" {
		return nil
	}
	current, err := user.Current()
	if err != nil {
		return fmt.Errorf("后台服务缺少 HOME，且无法解析当前用户：%w", err)
	}
	home := strings.TrimSpace(current.HomeDir)
	if home == "" || !filepath.IsAbs(home) {
		return fmt.Errorf("后台服务缺少 HOME，且当前用户 Home 无效")
	}
	if err := os.Setenv("HOME", home); err != nil {
		return fmt.Errorf("恢复后台服务 HOME 失败：%w", err)
	}
	username := strings.TrimSpace(current.Username)
	if username != "" {
		if strings.TrimSpace(os.Getenv("USER")) == "" {
			_ = os.Setenv("USER", username)
		}
		if strings.TrimSpace(os.Getenv("LOGNAME")) == "" {
			_ = os.Setenv("LOGNAME", username)
		}
	}
	return nil
}

// ensureAppServerSSHMigration 只在 macOS 正式 Load 前原子迁移旧 managed WS
// 配置。Linux 与 Windows 都支持受管本机 WebSocket，不应被改写回 SSH。
func ensureAppServerSSHMigration(ctx context.Context, configPath string, target string) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	if err := agentsetup.MigrateAppServerToSSH(ctx, configPath, target); err != nil {
		return fmt.Errorf("迁移共享 SSH App Server 配置失败：%w", err)
	}
	return nil
}

package main

import (
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
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

// 历史 stdio/off 配置会兼容迁移为 managed WS。旧配置通常没有独立
// ws_token_file；后台服务不能依赖用户先手工运行 doctor --fix，因此在正式
// Load 前完成同一套原子修复。
func ensureManagedWSTokenAvailable(configPath string) error {
	cfg, err := config.LoadForDoctor(configPath)
	if err != nil {
		return err
	}
	if !strings.EqualFold(strings.TrimSpace(cfg.AppServer.Transport), "ws") {
		return fmt.Errorf("app_server.transport 只支持 ws")
	}
	if !cfg.AppServer.Managed {
		return fmt.Errorf("app_server.managed 必须为 true；agentd 只支持受管 App Server")
	}
	if _, _, err := agentsetup.RepairManagedWSTokenFile(configPath); err != nil {
		return fmt.Errorf("准备 managed app-server token 失败：%w", err)
	}
	if _, _, err := agentsetup.RepairRemoteGatewayTokenFile(configPath); err != nil {
		return fmt.Errorf("准备 remote gateway token 失败：%w", err)
	}
	return nil
}

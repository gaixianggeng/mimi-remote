//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// setsid 只隔离进程组，不会把 SSH 的安全会话变成已登录用户的安全会话。
// setup/up 不再启动 resident；由 Mac supervisor 或 Homebrew GUI 服务负责创建。
func validateSharedLocalLaunchSession(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, sharedLocalSessionTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, "/bin/launchctl", "managername").Output()
	return validateSharedLocalLaunchManager(string(output), err)
}

func validateSharedLocalLaunchManager(manager string, err error) error {
	if err == nil && strings.TrimSpace(manager) == "Aqua" {
		return nil
	}
	return fmt.Errorf("共享 Codex 服务必须从 macOS 已登录的桌面环境启动；请打开 Mimi Remote Mac 启动服务，或在本机终端运行 agentd up。不会从 SSH 后台创建缺少钥匙串授权的服务")
}

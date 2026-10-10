//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

// 策略查询经 PowerShell 读取防火墙和网络配置，登录后冷启动实测 8–11 秒。
// 预算不足时 PowerShell 会被强杀，启动只剩 exit status 1（#456）。
const windowsLANPolicyCheckTimeout = 30 * time.Second

func ensurePlatformLANAccessAllowed() error {
	agentPath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("定位 agentd.exe 失败：%w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), windowsLANPolicyCheckTimeout)
	defer cancel()
	status, err := windowslan.Check(ctx, agentPath)
	if err != nil {
		return err
	}
	if len(status.UnsafeRules) > 0 {
		return fmt.Errorf("Windows 检测到额外的 agentd.exe 入站 Allow 规则，它会绕过 Mimi Remote 的 Private/LocalSubnet 边界；请重新运行安装器以清理不安全规则")
	}
	if !status.FirewallValid {
		return fmt.Errorf("Windows 局域网访问缺少精确的 Private/LocalSubnet 防火墙规则；请重新运行 Mimi Remote 安装器并勾选 Private LAN access")
	}
	if !status.ProfilePrivate {
		return fmt.Errorf(
			"Windows 默认网络 %q 当前为 %s；仅在信任该网络时将其改为“专用网络”，然后再启用 Mimi Remote 局域网访问",
			status.InterfaceLabel(),
			status.CategoryLabel(),
		)
	}
	return nil
}

//go:build windows

package doctor

import (
	"context"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

func (c *Checker) windowsLANCheck(ctx context.Context) Check {
	if !c.cfg.Network.AllowLAN {
		return Check{}
	}
	rawPath, err := os.Executable()
	if err != nil {
		return Check{
			Name:    "windows-private-lan",
			OK:      false,
			Message: "无法确定 agentd.exe 路径，不能验证 Windows 局域网边界",
			Fix:     "重新安装 Mimi Remote，然后再次运行 agentd doctor",
		}
	}
	agentPath, err := windowslan.CanonicalFirewallPath(rawPath)
	if err != nil {
		return Check{
			Name:    "windows-private-lan",
			OK:      false,
			Message: err.Error(),
			Fix:     "重新安装 Mimi Remote，然后再次运行 agentd doctor",
		}
	}
	status, err := windowslan.Check(ctx, agentPath)
	if err != nil {
		return Check{
			Name:    "windows-private-lan",
			OK:      false,
			Message: err.Error(),
			Fix:     "确认 Windows PowerShell 和 Windows Defender Firewall 服务可用",
		}
	}
	if len(status.UnsafeRules) > 0 {
		return Check{
			Name:    "windows-private-lan",
			OK:      false,
			Message: "检测到额外的 agentd.exe 入站 Allow 规则，会绕过 Mimi Remote 的 Private/LocalSubnet 边界",
			Fix:     "重新运行 Mimi Remote 安装器；安装器会删除额外规则，只保留受限的托管规则",
		}
	}
	if !status.FirewallValid {
		return Check{
			Name:    "windows-private-lan",
			OK:      false,
			Message: "局域网配置已开启，但缺少精确的 Private/LocalSubnet/agentd.exe 防火墙规则",
			Fix:     "重新运行 Mimi Remote 安装器并勾选 Private LAN access",
		}
	}
	if !status.ProfilePrivate {
		return Check{
			Name:    "windows-private-lan",
			OK:      false,
			Message: "默认网络 " + status.InterfaceLabel() + " 当前为 " + status.CategoryLabel() + "，Private 防火墙规则不会在该网络生效",
			Fix:     "仅在信任此 Wi-Fi/以太网时，于 Windows 设置中将网络配置文件改为“专用网络”；否则关闭 Mimi Remote LAN access",
		}
	}
	return Check{
		Name:    "windows-private-lan",
		OK:      true,
		Message: "默认网络为 Private，且防火墙仅允许 LocalSubnet 访问已安装的 agentd.exe",
	}
}

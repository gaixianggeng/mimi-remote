//go:build windows

package doctor

import (
	"github.com/gaixianggeng/mimi-remote/internal/systemproxy"
)

// systemProxyCheck 说明 Codex 与 Claude 如何联网（#884）。不显示代理地址：它属于
// 用户本机配置，诊断结果会同步到已配对的移动设备。系统代理关闭时不显示这一项。
func (c *Checker) systemProxyCheck() Check {
	environment := make([]string, 0, len(c.cfg.Codex.Env))
	for key, value := range c.cfg.Codex.Env {
		environment = append(environment, key+"="+value)
	}
	if systemproxy.HasProxySetting(environment) {
		return Check{Name: "windows-system-proxy", OK: true, Message: "Codex 使用 codex.env 中的代理设置，不经过系统代理中转"}
	}
	settings, err := systemproxy.CurrentSettings()
	if err != nil {
		return Check{
			Name:    "windows-system-proxy",
			OK:      false,
			Level:   "warning",
			Message: "无法读取 Windows 系统代理设置，Codex 与 Claude 将直连",
			Fix:     "如需代理，在 agentd 配置的 codex.env 中设置 HTTPS_PROXY",
		}
	}
	switch settings.Mode() {
	case "static":
		return Check{Name: "windows-system-proxy", OK: true, Message: "已开启 Windows 系统代理；agentd 会让 Codex 与 Claude 经本机中转使用它，代理软件开关后无需重启服务"}
	case "pac":
		return Check{Name: "windows-system-proxy", OK: true, Message: "Windows 使用代理自动配置脚本（PAC）；agentd 会让 Codex 与 Claude 按该脚本联网"}
	default:
		return Check{}
	}
}

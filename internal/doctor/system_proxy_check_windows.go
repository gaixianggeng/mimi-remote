//go:build windows

package doctor

import (
	"fmt"
	"os"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/systemproxy"
)

// systemProxyCheck 说明 Codex 与 Claude 如何联网（#884）。不显示代理地址：它属于
// 用户本机配置，诊断结果会同步到已配对的移动设备。系统代理关闭时不显示这一项。
func (c *Checker) systemProxyCheck() Check {
	return c.systemProxyCheckWith(os.Environ(), systemproxy.CurrentSettings)
}

func (c *Checker) systemProxyCheckWith(
	inherited []string,
	readSettings func() (systemproxy.Settings, error),
) Check {
	codexSource := explicitProxySource(c.cfg.Codex.Env, "codex.env", inherited)
	claudeSource := explicitProxySource(c.cfg.Claude.Env, "claude.env", inherited)
	if codexSource != "" && claudeSource != "" {
		return proxyRouteCheck(codexSource, claudeSource, "")
	}
	settings, err := readSettings()
	if err != nil {
		check := proxyRouteCheck(codexSource, claudeSource, "unavailable")
		check.OK = false
		check.Level = "warning"
		check.Fix = "如需代理，分别在 agentd 配置的 codex.env 或 claude.env 中设置 HTTPS_PROXY"
		return check
	}
	mode := settings.Mode()
	if mode == "direct" && codexSource == "" && claudeSource == "" {
		return Check{}
	}
	return proxyRouteCheck(codexSource, claudeSource, mode)
}

func explicitProxySource(configured map[string]string, configName string, inherited []string) string {
	sources := make([]string, 0, 2)
	configuredEnvironment := make([]string, 0, len(configured))
	for key, value := range configured {
		configuredEnvironment = append(configuredEnvironment, key+"="+value)
	}
	if systemproxy.HasProxySetting(configuredEnvironment) {
		sources = append(sources, configName)
	}
	if systemproxy.HasProxySetting(inherited) {
		sources = append(sources, "agentd 继承环境")
	}
	return strings.Join(sources, " 与 ")
}

func proxyRouteCheck(codexSource string, claudeSource string, systemMode string) Check {
	return Check{
		Name: "windows-system-proxy",
		OK:   true,
		Message: strings.Join([]string{
			describeProxyRoute("Codex", codexSource, systemMode),
			describeProxyRoute("Claude", claudeSource, systemMode),
		}, "；"),
	}
}

func describeProxyRoute(runtimeName string, explicitSource string, systemMode string) string {
	if explicitSource != "" {
		return fmt.Sprintf("%s 按 %s 中的代理变量联网，不使用系统代理中转", runtimeName, explicitSource)
	}
	switch systemMode {
	case "static":
		return runtimeName + " 经本机中转使用 Windows 系统代理"
	case "pac":
		return runtimeName + " 经本机中转按 Windows PAC 联网"
	case "unavailable":
		return runtimeName + " 无法读取 Windows 系统代理设置，将直连"
	default:
		return runtimeName + " 直连"
	}
}

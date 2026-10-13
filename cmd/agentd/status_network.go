package main

import (
	"net"
	"net/netip"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

// agentNetworkStatus is deliberately a sanitized snapshot. In particular it
// reports only the number of unexpected firewall rules, never their names or
// the configured authentication token.
type agentNetworkStatus struct {
	Mode                string `json:"mode"`
	AllowLAN            bool   `json:"allow_lan"`
	PolicyChecked       bool   `json:"policy_checked"`
	PolicyOK            bool   `json:"policy_ok"`
	FirewallValid       bool   `json:"firewall_valid"`
	InterfaceAlias      string `json:"interface_alias,omitempty"`
	NetworkCategory     string `json:"network_category,omitempty"`
	UnsafeRuleCount     int    `json:"unsafe_rule_count"`
	PolicyInspectionErr bool   `json:"policy_inspection_error"`
}

func configuredAgentNetworkStatus(cfg config.Config) agentNetworkStatus {
	return agentNetworkStatus{
		Mode:     configuredAgentNetworkMode(cfg),
		AllowLAN: cfg.Network.AllowLAN,
	}
}

func configuredAgentNetworkMode(cfg config.Config) string {
	if cfg.Network.AllowLAN {
		return "lan"
	}

	host, _, err := net.SplitHostPort(strings.TrimSpace(cfg.Listen))
	if err != nil {
		return "unknown"
	}
	host = strings.Trim(strings.TrimSpace(host), "[]")
	if strings.EqualFold(host, "localhost") {
		return "loopback"
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return "unknown"
	}
	if ip.IsLoopback() {
		return "loopback"
	}
	if isTailscaleStatusIP(ip) {
		return "tailscale"
	}
	return "specific"
}

// isTailscaleStatusIP 与配置校验、模块意图使用同一判定：Tailscale IPv4 与 IPv6 都算。
func isTailscaleStatusIP(ip net.IP) bool {
	addr, ok := netip.AddrFromSlice(ip)
	return ok && tailscaleinfo.IsTailscaleAddress(addr)
}

func networkPolicyDoctorCheck(status agentNetworkStatus) doctor.Check {
	if !status.PolicyChecked || status.PolicyOK {
		return doctor.Check{}
	}

	check := doctor.Check{
		Name:  "windows-network-policy",
		OK:    false,
		Level: "error",
	}
	switch {
	case status.PolicyInspectionErr:
		check.Message = "无法检查 Windows 防火墙和默认网络类别"
		check.Fix = "确认 Windows PowerShell 与 Windows Defender Firewall 服务可用，然后从托盘刷新状态"
	case status.UnsafeRuleCount > 0:
		check.Message = "检测到额外的 agentd.exe 入站 Allow 规则，会绕过 Mimi Remote 的局域网边界"
		check.Fix = "重新运行 Mimi Remote 安装器以清理额外规则"
	case status.AllowLAN && !strings.EqualFold(status.NetworkCategory, "Private"):
		check.Message = "局域网访问已开启，但默认 Windows 网络不是 Private"
		check.Fix = "仅在信任当前网络时将其改为“专用网络”；否则关闭 Mimi Remote LAN access"
	case status.AllowLAN && !status.FirewallValid:
		check.Message = "局域网访问已开启，但缺少精确的 Private/LocalSubnet 防火墙规则"
		check.Fix = "重新运行 Mimi Remote 安装器并勾选 Private LAN access"
	default:
		check.Message = "Windows 网络安全策略需要处理"
		check.Fix = "从托盘运行诊断并按提示修复"
	}
	return check
}

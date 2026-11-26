package setup

import (
	"context"
	"fmt"
	"net"
	"runtime"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func modulePairingEndpoint(ctx context.Context, cfg config.Config, network PairingNetwork, lookups pairingNetworkLookups) (string, []string, error) {
	_, port := splitListen(cfg.Listen)
	if port == "" {
		port = defaultAgentDPort
	}
	if network == PairingNetworkAuto {
		if cfg.TailscaleAccessEnabled() {
			if endpoint, warnings, err := modulePairingEndpoint(ctx, cfg, PairingNetworkTailscale, lookups); err == nil {
				return endpoint, warnings, nil
			}
		}
		if cfg.LANAccessEnabled() {
			return modulePairingEndpoint(ctx, cfg, PairingNetworkLAN, lookups)
		}
		return "", nil, NoPairingNetworkError(runtime.GOOS)
	}
	switch network {
	case PairingNetworkTailscale:
		if !cfg.TailscaleAccessEnabled() {
			return "", nil, &PairingDiagnostic{"network_selection_required", "network_any", "Tailscale 已在 Mimi 中关闭"}
		}
		host := strings.TrimSpace(lookups.tailscaleIP(ctx))
		if !isTailscaleIPv4(net.ParseIP(host)) {
			return "", nil, &PairingDiagnostic{"tailscale_not_connected", "network_tailscale", "未检测到 Tailscale IPv4，请安装、登录并连接 Tailscale"}
		}
		return httpEndpoint(host, port), nil, nil
	case PairingNetworkLAN:
		if !cfg.LANAccessEnabled() {
			return "", nil, &PairingDiagnostic{"network_selection_required", "network_any", "局域网已在 Mimi 中关闭"}
		}
		host := strings.TrimSpace(lookups.lanIP())
		if !isPrivateLANIPv4(net.ParseIP(host)) {
			return "", nil, &PairingDiagnostic{"lan_unavailable", "network_lan", "未检测到可用的局域网 IPv4，请连接 Wi-Fi 或以太网"}
		}
		return httpEndpoint(host, port), []string{"仅用于受信任的局域网；仍需 Mimi 配对鉴权"}, nil
	default:
		return "", nil, fmt.Errorf("不支持的配对网络 %q", network)
	}
}

// NoPairingNetworkError 只在 Tailscale 和局域网都关闭时出现，托盘会原样显示为配对失败原因。
// Windows 托盘没有连接方式开关，LAN 还需要安装器建立受限防火墙规则，因此给出可直接执行的步骤（#874）；
// Linux/macOS 给出同一局域网、Tailscale 与联网 Tailcat 的真实可执行命令（#1164）。
func NoPairingNetworkError(goos string) error {
	if goos == "windows" {
		return &PairingDiagnostic{"network_selection_required", "network_any", "没有可用的 Tailscale 或局域网连接；可以在托盘控制面板开启 Tailcat（或运行 agentd tailcat enable）后用 Tailcat 配对，也可以安装并登录 Tailscale 后运行 agentd network --tailscale-enabled=true 和 agentd restart，或重新运行安装器并勾选局域网访问"}
	}
	return &PairingDiagnostic{"network_selection_required", "network_any", "没有可用的 Tailscale 或局域网连接；同一局域网可运行 agentd network --lan-enabled=true 后执行 agentd restart --no-pair，Tailscale 可运行 agentd network --tailscale-enabled=true 后执行 agentd restart --no-pair；联网时也可运行 agentd tailcat enable 后用 agentd tailcat pair 配对"}
}

// PairingDiagnostic preserves existing human-readable messages while exposing
// the originating check to the CLI's JSON boundary.
type PairingDiagnostic struct{ Code, Step, Message string }

func (e *PairingDiagnostic) Error() string { return e.Message }

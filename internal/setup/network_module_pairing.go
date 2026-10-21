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
		return "", nil, noPairingNetworkError(runtime.GOOS)
	}
	switch network {
	case PairingNetworkTailscale:
		if !cfg.TailscaleAccessEnabled() {
			return "", nil, fmt.Errorf("Tailscale 已在 Mimi 中关闭")
		}
		host := strings.TrimSpace(lookups.tailscaleIP(ctx))
		if !isTailscaleIPv4(net.ParseIP(host)) {
			return "", nil, fmt.Errorf("未检测到 Tailscale IPv4，请安装、登录并连接 Tailscale")
		}
		return httpEndpoint(host, port), nil, nil
	case PairingNetworkLAN:
		if !cfg.LANAccessEnabled() {
			return "", nil, fmt.Errorf("局域网已在 Mimi 中关闭")
		}
		host := strings.TrimSpace(lookups.lanIP())
		if !isPrivateLANIPv4(net.ParseIP(host)) {
			return "", nil, fmt.Errorf("未检测到可用的局域网 IPv4，请连接 Wi-Fi 或以太网")
		}
		return httpEndpoint(host, port), []string{"仅用于受信任的局域网；仍需 Mimi 配对鉴权"}, nil
	default:
		return "", nil, fmt.Errorf("不支持的配对网络 %q", network)
	}
}

// noPairingNetworkError 只在 Tailscale 和局域网都关闭时出现，托盘会原样显示为配对失败原因。
// Windows 托盘没有连接方式开关，LAN 还需要安装器建立受限防火墙规则，因此给出可直接执行的步骤（#874）。
func noPairingNetworkError(goos string) error {
	if goos == "windows" {
		return fmt.Errorf("没有可用的 Tailscale 或局域网连接；请安装并登录 Tailscale 后运行 agentd network --tailscale-enabled=true 和 agentd restart，或重新运行安装器并勾选局域网访问")
	}
	return fmt.Errorf("没有可用的 Tailscale 或局域网连接；请启用连接方式或使用 Tailcat 配对")
}

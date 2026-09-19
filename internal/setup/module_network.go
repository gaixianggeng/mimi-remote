package setup

import (
	"context"
	"fmt"
	"net"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// ModuleListenAddresses is used only after an explicit network switch has been
// saved. Local administration is always reachable; an offline VPN cannot stop
// the control plane or force LAN to be enabled as a fallback.
func ModuleListenAddresses(ctx context.Context, cfg config.Config) []string {
	_, port := splitListen(cfg.Listen)
	if port == "" {
		port = defaultAgentDPort
	}
	if cfg.Network.AllowLAN {
		return []string{net.JoinHostPort("0.0.0.0", port)}
	}
	addresses := []string{net.JoinHostPort("127.0.0.1", port)}
	if cfg.Network.AllowsTailscale() {
		if ip := net.ParseIP(strings.TrimSpace(firstTailscaleIP(ctx))); isTailscaleIPv4(ip) {
			addresses = append(addresses, net.JoinHostPort(ip.String(), port))
		}
	}
	return addresses
}

func managedPairingEndpoint(ctx context.Context, cfg config.Config, network PairingNetwork, lookups pairingNetworkLookups) (string, []string, error) {
	_, port := splitListen(cfg.Listen)
	if port == "" {
		port = defaultAgentDPort
	}
	if network == PairingNetworkAuto {
		if cfg.Network.AllowsTailscale() {
			if endpoint, warnings, err := managedPairingEndpoint(ctx, cfg, PairingNetworkTailscale, lookups); err == nil {
				return endpoint, warnings, nil
			}
		}
		if cfg.Network.AllowLAN {
			return managedPairingEndpoint(ctx, cfg, PairingNetworkLAN, lookups)
		}
		return "", nil, fmt.Errorf("没有已启用且可用的连接方式；请在连接方式设置中开启 Tailscale 或局域网")
	}
	switch network {
	case PairingNetworkTailscale:
		if !cfg.Network.AllowsTailscale() {
			return "", nil, fmt.Errorf("Tailscale 已在 Mimi Remote 中关闭")
		}
		ip := net.ParseIP(strings.TrimSpace(lookups.tailscaleIP(ctx)))
		if !isTailscaleIPv4(ip) {
			return "", nil, fmt.Errorf("Tailscale 尚未连接，请先登录并连接 Tailscale")
		}
		return httpEndpoint(ip.String(), port), nil, nil
	case PairingNetworkLAN:
		if !cfg.Network.AllowLAN {
			return "", nil, fmt.Errorf("局域网已在 Mimi Remote 中关闭")
		}
		ip := net.ParseIP(strings.TrimSpace(lookups.lanIP()))
		if !isPrivateLANIPv4(ip) {
			return "", nil, fmt.Errorf("未检测到可用的 Wi-Fi 或以太网局域网地址")
		}
		return httpEndpoint(ip.String(), port), []string{"局域网配对仅适用于与这台电脑位于同一局域网的设备"}, nil
	default:
		return "", nil, fmt.Errorf("不支持的配对网络：%s", network)
	}
}

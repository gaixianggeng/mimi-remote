package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
)

type moduleStatusFetchState string

const (
	moduleStatusAvailable   moduleStatusFetchState = "available"
	moduleStatusUnsupported moduleStatusFetchState = "unsupported"
	moduleStatusUnavailable moduleStatusFetchState = "unavailable"
)

func moduleListenAddresses(cfg config.Config) []string {
	if !cfg.HasNetworkModuleControls() {
		return agentDListenAddresses(cfg.Listen, cfg.Network.AllowLAN)
	}
	host, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return []string{cfg.Listen}
	}
	// 模块控制一旦接管，监听地址就按模块开关重建，不再沿用 cfg.Listen 的主机部分：
	// 关闭局域网只改变入口策略，不会把通配监听改写成 loopback，因此仍开启的 Tailscale
	// 继续经同一个监听可达；本机控制面与 Tailcat sidecar 固定连 127.0.0.1，任何开关
	// 组合下都被覆盖。
	if cfg.TailscaleAccessEnabled() || cfg.LANAccessEnabled() {
		// Every socket accepted on this listener is checked by networkaccess.
		// Wildcard alone is never the module-control security boundary.
		// Go 在 "tcp" 网络上监听 0.0.0.0 时创建双栈 [::] socket，已经接受 ::1；
		// 再单独绑定 [::1] 在 macOS 上多余，在 Linux 上会因同端口通配监听而 EADDRINUSE。
		return []string{net.JoinHostPort("0.0.0.0", port)}
	}
	addresses := []string{net.JoinHostPort("127.0.0.1", port)}
	// 两种外部直连都关闭时只监听 loopback。若原配置绑定的是 IPv6 loopback
	// （例如 "[::1]:8787"），不能把它丢掉，否则走 ::1 的本机客户端会在只改了一个
	// 模块开关后突然连不上。策略层对 loopback→loopback 一直放行。
	if boundIPv6Loopback(host) {
		addresses = append(addresses, net.JoinHostPort("::1", port))
	}
	return addresses
}

// moduleIngressPolicy 是模块控制下每个 accept 的连接都要通过的入口策略，与
// moduleListenAddresses 共用同一份开关推导，避免监听集合与策略分叉。
func moduleIngressPolicy(cfg config.Config) networkaccess.Policy {
	return networkaccess.Policy{Tailscale: cfg.TailscaleAccessEnabled(), LAN: cfg.LANAccessEnabled()}
}

// boundIPv6Loopback 判断配置里绑定的主机名是不是 IPv6 loopback（含未加方括号的写法）。
func boundIPv6Loopback(host string) bool {
	normalized := strings.Trim(strings.TrimSpace(host), "[]")
	if normalized == "" {
		return false
	}
	ip := net.ParseIP(normalized)
	return ip != nil && ip.To4() == nil && ip.IsLoopback()
}

func fetchModuleStatusForCommand(endpoint, token string) (*config.ModuleStatus, moduleStatusFetchState) {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(endpoint, "/")+"/api/host/modules", nil)
	if err != nil {
		return nil, moduleStatusUnavailable
	}
	req.Header.Set("Authorization", "Bearer "+token)
	client := &http.Client{Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	response, err := client.Do(req)
	if err != nil {
		return nil, moduleStatusUnavailable
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusMethodNotAllowed {
		return nil, moduleStatusUnsupported
	}
	if response.StatusCode != http.StatusOK {
		return nil, moduleStatusUnavailable
	}
	var status config.ModuleStatus
	if err := json.NewDecoder(io.LimitReader(response.Body, 16<<10)).Decode(&status); err != nil {
		return nil, moduleStatusUnavailable
	}
	return &status, moduleStatusAvailable
}

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
	// 模块控制一旦接管，监听地址就按模块开关重建，不再沿用 cfg.Listen。若原配置绑定的
	// 是 IPv6 loopback（例如 "[::1]:8787"），重建时不能把它丢掉：那会让原本走 ::1 的
	// 本机客户端在只改了一个模块开关后突然连不上。策略层对 loopback→loopback 一直放行，
	// 所以这个监听与开关状态无关，始终保留。
	var addresses []string
	if cfg.TailscaleAccessEnabled() || cfg.LANAccessEnabled() {
		// Every socket accepted on this listener is checked by networkaccess.
		// Wildcard alone is never the module-control security boundary.
		addresses = []string{net.JoinHostPort("0.0.0.0", port)}
	} else {
		addresses = []string{net.JoinHostPort("127.0.0.1", port)}
	}
	if boundIPv6Loopback(host) {
		addresses = append(addresses, net.JoinHostPort("::1", port))
	}
	return addresses
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

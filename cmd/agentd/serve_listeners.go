package main

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"syscall"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

const staleTailscaleListenWarning = "警告：旧配置中的 Tailscale 监听地址当前不可用（EADDRNOTAVAIL）；已保留本机 loopback 控制面，远程直连尚未恢复。请恢复 Tailscale 后重启服务，或在 Mac App 中修复连接地址。配置未改写，本次不显示远程配对二维码。"

// bindServeListeners owns startup listeners until all required binds succeed.
// Recovery only retains an already planned loopback listener; it never adds an
// address, rewrites config, or changes the module-control ingress policy.
func bindServeListeners(cfg config.Config, addresses []string, bind func(config.Config, string) (net.Listener, error)) ([]net.Listener, bool, error) {
	listeners := make([]net.Listener, 0, len(addresses))
	complete := false
	defer func() {
		if !complete {
			for _, opened := range listeners {
				_ = opened.Close()
			}
		}
	}()
	loopback := legacyTailscaleRecoveryLoopback(cfg, addresses)
	loopbackBound := false
	var unavailable error
	for _, address := range addresses {
		listener, err := bind(cfg, address)
		if err != nil {
			if loopback != "" && address == strings.TrimSpace(cfg.Listen) && errors.Is(err, syscall.EADDRNOTAVAIL) {
				unavailable = err
				continue
			}
			return nil, false, fmt.Errorf("监听 %s 失败：%w", address, err)
		}
		if listener == nil {
			continue
		}
		if cfg.HasNetworkModuleControls() {
			listener = networkaccess.Wrap(listener, moduleIngressPolicy(cfg))
		}
		listeners = append(listeners, listener)
		if address == loopback {
			loopbackBound = true
		}
	}
	if unavailable != nil && !loopbackBound {
		return nil, false, fmt.Errorf("Tailscale 地址不可用且本机控制面未能监听：%w", unavailable)
	}
	complete = true
	return listeners, unavailable != nil, nil
}

func legacyTailscaleRecoveryLoopback(cfg config.Config, addresses []string) string {
	if cfg.HasNetworkModuleControls() || cfg.Network.AllowLAN || len(addresses) != 2 {
		return ""
	}
	configured := strings.TrimSpace(cfg.Listen)
	host, port, err := net.SplitHostPort(configured)
	if err != nil || port == "" {
		return ""
	}
	ip, err := netip.ParseAddr(host)
	if err != nil || !tailscaleinfo.IsTailscaleAddress(ip) {
		return ""
	}
	// Match the legacy plan exactly, including the same port. Do not interpret
	// DNS names, wildcards, or additional remote listeners as local recovery.
	loopback := net.JoinHostPort("127.0.0.1", port)
	if (addresses[0] == configured && addresses[1] == loopback) ||
		(addresses[1] == configured && addresses[0] == loopback) {
		return loopback
	}
	return ""
}

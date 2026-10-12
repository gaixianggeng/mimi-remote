package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

// 入口策略判定用到的代表性 socket 地址：本机控制与 Tailcat sidecar 固定走 127.0.0.1，
// MagicDNS 可能把 Tailscale 解析到 IPv6。
var (
	loopbackPeer      = [2]string{"127.0.0.1", "127.0.0.1"}
	tailscaleIPv4Peer = [2]string{"100.64.0.2", "100.64.0.3"}
	tailscaleIPv6Peer = [2]string{"fd7a:115c:a1e0::2", "fd7a:115c:a1e0::3"}
	lanIPv4Peer       = [2]string{"192.168.50.2", "192.168.50.3"}
	mappedLANPeer     = [2]string{"::ffff:192.168.50.2", "::ffff:192.168.50.3"}
)

func writeNetworkToggleConfig(t *testing.T, listen, network string) string {
	t.Helper()
	document := map[string]any{
		"listen":     listen,
		"auth":       map[string]any{"token": "network-toggle-test-only"},
		"app_server": map[string]any{"transport": "local"},
		"codex":      map[string]any{"bin": "/missing/network-toggle-codex"},
		"claude":     map[string]any{"enabled": false},
		"network":    json.RawMessage(network),
		"projects":   []config.ProjectConfig{{ID: "network-toggle", Name: "Network toggle", Path: t.TempDir()}},
	}
	if runtime.GOOS == "windows" {
		appServer := config.DefaultManagedAppServerConfig()
		appServer.WSTokenFile = filepath.Join(t.TempDir(), "app-server-token")
		document["app_server"] = appServer
	}
	raw, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func runNetworkToggle(t *testing.T, path string, flag string) agentsetup.NetworkConfigurationResult {
	t.Helper()
	var stdout bytes.Buffer
	if err := runNetworkWithWriters([]string{"network", "--config", path, flag, "--json"}, &stdout, io.Discard); err != nil {
		t.Fatalf("agentd network %s: %v", flag, err)
	}
	var result agentsetup.NetworkConfigurationResult
	if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
		t.Fatalf("decode %s result: %v", flag, err)
	}
	return result
}

// assertIngress 校验重载后 agentd 实际会建立的监听集合与入口策略：listen 字段不被改写，
// 监听覆盖每个应可达的地址，策略只放行仍开启的连接方式。
func assertIngress(t *testing.T, path, listen string, tailscale, lan bool, wantListeners []string) {
	t.Helper()
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("reload config: %v", err)
	}
	if cfg.Listen != listen {
		t.Fatalf("listen rewritten: got %q want %q", cfg.Listen, listen)
	}
	if cfg.TailscaleAccessEnabled() != tailscale || cfg.LANAccessEnabled() != lan {
		t.Fatalf("intent tailscale=%t lan=%t, want %t/%t", cfg.TailscaleAccessEnabled(), cfg.LANAccessEnabled(), tailscale, lan)
	}
	listeners := moduleListenAddresses(cfg)
	if !reflect.DeepEqual(listeners, wantListeners) {
		t.Fatalf("listeners %v want %v", listeners, wantListeners)
	}
	policy := moduleIngressPolicy(cfg)
	for _, tc := range []struct {
		name  string
		peer  [2]string
		allow bool
	}{
		{"local control and Tailcat sidecar", loopbackPeer, true},
		{"Tailscale IPv4", tailscaleIPv4Peer, tailscale},
		{"Tailscale IPv6 via MagicDNS", tailscaleIPv6Peer, tailscale},
		{"LAN IPv4", lanIPv4Peer, lan},
		{"LAN IPv4 on dual-stack socket", mappedLANPeer, lan},
	} {
		local := net.ParseIP(tc.peer[0])
		reachable := policy.Allows(local, net.ParseIP(tc.peer[1])) && listenersCover(listeners, local)
		if reachable != tc.allow {
			t.Fatalf("%s reachable=%t want %t (listeners %v policy %+v)", tc.name, reachable, tc.allow, listeners, policy)
		}
	}
}

// listenersCover 判断某个本机地址能否被监听集合接收。Go 在 "tcp" 网络上监听 0.0.0.0
// 时创建双栈 socket，因此 IPv4 通配同样覆盖 IPv6 本机地址。
func listenersCover(listeners []string, local net.IP) bool {
	for _, address := range listeners {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			continue
		}
		bound := net.ParseIP(host)
		if bound != nil && (bound.IsUnspecified() || bound.Equal(local)) {
			return true
		}
	}
	return false
}

// #529：关闭局域网只能收紧局域网入口。Issue 表格中的每种 listen（以及 IPv6 loopback），
// 无论是旧版隐式 Tailscale 意图还是显式 allow_tailscale=true，经 CLI 关闭 LAN 后都不改写
// listen，Tailscale（含 IPv6）、本机控制和 Tailcat sidecar 继续可达，局域网被拒绝；
// 再关闭 Tailscale 才收紧到 loopback。来回切换保持幂等，listen 始终不变。
func TestDisablingLANKeepsEnabledTailscaleReachable(t *testing.T) {
	for _, listen := range []string{"0.0.0.0:8787", "[::]:8787", "100.64.0.2:8787", "127.0.0.1:8787", "[::1]:8787"} {
		for _, network := range []string{`{"allow_lan":true}`, `{"allow_lan":true,"allow_tailscale":true}`} {
			t.Run(listen+" "+network, func(t *testing.T) {
				wildcard := []string{"0.0.0.0:8787"}
				loopback := []string{"127.0.0.1:8787"}
				if strings.HasPrefix(listen, "[::1]") {
					loopback = append(loopback, "[::1]:8787")
				}
				path := writeNetworkToggleConfig(t, listen, network)

				result := runNetworkToggle(t, path, "--lan-enabled=false")
				if !result.Changed || result.LANEnabled || !result.TailscaleEnabled {
					t.Fatalf("disable LAN result %+v", result)
				}
				assertIngress(t, path, listen, true, false, wildcard)

				saved, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				if again := runNetworkToggle(t, path, "--lan-enabled=false"); again.Changed {
					t.Fatalf("repeated disable is not idempotent: %+v", again)
				}
				if current, _ := os.ReadFile(path); !bytes.Equal(current, saved) {
					t.Fatal("repeated disable rewrote the configuration")
				}

				// 只有 Tailscale 也关闭后才收紧到 loopback：局域网与 Tailscale 都没有外部监听。
				if result = runNetworkToggle(t, path, "--tailscale-enabled=false"); !result.Changed || result.TailscaleEnabled || result.LANEnabled {
					t.Fatalf("disable Tailscale result %+v", result)
				}
				assertIngress(t, path, listen, false, false, loopback)

				if result = runNetworkToggle(t, path, "--tailscale-enabled=true"); !result.Changed || !result.TailscaleEnabled || result.LANEnabled {
					t.Fatalf("re-enable Tailscale result %+v", result)
				}
				assertIngress(t, path, listen, true, false, wildcard)

				// 重新开启 LAN 走 setup 入口，避免在 Windows CI 上触发真实防火墙策略检查。
				if result, err = agentsetup.ConfigureNetworkAccess(path, "lan", true); err != nil || !result.Changed {
					t.Fatalf("re-enable LAN result %+v %v", result, err)
				}
				assertIngress(t, path, listen, true, true, wildcard)
				if result = runNetworkToggle(t, path, "--lan-enabled=false"); !result.Changed || result.LANEnabled || !result.TailscaleEnabled {
					t.Fatalf("second disable LAN result %+v", result)
				}
				assertIngress(t, path, listen, true, false, wildcard)
			})
		}
	}
}

// 旧配置没有 allow_lan，只是手动把 listen 写成 Tailscale 地址：IPv4（100.64.0.0/10）与
// IPv6（fd7a:115c:a1e0::/48）都必须被识别为隐式 Tailscale 意图。首次经 CLI 修改网络转入
// 模块控制后，Tailscale 两个地址族继续可达，局域网保持关闭，而不是只剩 loopback。
func TestLegacyTailscaleListenKeepsTailscaleAfterModuleTakeover(t *testing.T) {
	for _, listen := range []string{"100.64.0.2:8787", "[fd7a:115c:a1e0::2]:8787"} {
		t.Run(listen, func(t *testing.T) {
			path := writeNetworkToggleConfig(t, listen, `{}`)
			cfg, err := config.Load(path)
			if err != nil {
				t.Fatalf("Tailscale listen 不需要 allow_lan：%v", err)
			}
			if cfg.HasNetworkModuleControls() || !cfg.TailscaleAccessEnabled() || cfg.LANAccessEnabled() {
				t.Fatalf("legacy intent tailscale=%t lan=%t", cfg.TailscaleAccessEnabled(), cfg.LANAccessEnabled())
			}

			result := runNetworkToggle(t, path, "--lan-enabled=false")
			if result.LANEnabled || !result.TailscaleEnabled {
				t.Fatalf("takeover result %+v", result)
			}
			assertIngress(t, path, listen, true, false, []string{"0.0.0.0:8787"})
			if cfg, err = config.Load(path); err != nil || !cfg.HasNetworkModuleControls() {
				t.Fatalf("CLI 修改后应记录模块意图：%v", err)
			}
		})
	}
}

// Tailscale 本就关闭时，关闭局域网必须真正收紧到 loopback：通配或 IPv6 通配 listen
// 都不能让局域网继续对外监听。
func TestDisablingLANWithoutTailscaleFallsBackToLoopback(t *testing.T) {
	for _, listen := range []string{"0.0.0.0:8787", "[::]:8787", "127.0.0.1:8787", "[::1]:8787"} {
		t.Run(listen, func(t *testing.T) {
			loopback := []string{"127.0.0.1:8787"}
			if strings.HasPrefix(listen, "[::1]") {
				loopback = append(loopback, "[::1]:8787")
			}
			path := writeNetworkToggleConfig(t, listen, `{"allow_lan":true,"allow_tailscale":false}`)
			assertIngress(t, path, listen, false, true, []string{"0.0.0.0:8787"})
			result := runNetworkToggle(t, path, "--lan-enabled=false")
			if !result.Changed || result.LANEnabled || result.TailscaleEnabled {
				t.Fatalf("disable LAN result %+v", result)
			}
			assertIngress(t, path, listen, false, false, loopback)
		})
	}
}

// 计算出的监听集合必须能在同一端口上同时绑定，并让本机控制面（127.0.0.1）与 IPv6
// loopback 客户端连上。Tailscale 开启时双栈通配已覆盖 ::1，不能再重复绑定 [::1]。
func TestModuleListenersBindTogetherAndAcceptLoopback(t *testing.T) {
	ipv6 := false
	if probe, err := net.Listen("tcp", "[::1]:0"); err == nil {
		ipv6 = true
		_ = probe.Close()
	}
	for _, tc := range []struct {
		name      string
		tailscale bool
	}{{"external enabled", true}, {"all external off", false}} {
		t.Run(tc.name, func(t *testing.T) {
			listen := "127.0.0.1:0"
			if ipv6 {
				listen = "[::1]:0"
			}
			listeners := bindModuleListenersOnFreePort(t, listen, tc.tailscale)
			_, port, _ := net.SplitHostPort(listeners[0].Addr().String())
			hosts := []string{"127.0.0.1"}
			if ipv6 {
				hosts = append(hosts, "::1")
			}
			for _, host := range hosts {
				conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 2*time.Second)
				if err != nil {
					t.Fatalf("dial %s: %v", host, err)
				}
				_ = conn.Close()
			}
		})
	}
}

// bindModuleListenersOnFreePort 选一个空闲端口，再按 moduleListenAddresses 的结果在同一端口
// 上逐个监听，与 serve 的绑定方式一致。端口被其他进程抢占时换一个端口重试。
func bindModuleListenersOnFreePort(t *testing.T, listen string, tailscale bool) []net.Listener {
	t.Helper()
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		probe, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		_, port, _ := net.SplitHostPort(probe.Addr().String())
		_ = probe.Close()
		host, _, _ := net.SplitHostPort(listen)
		allow := tailscale
		cfg := config.Config{Listen: net.JoinHostPort(host, port), Network: config.NetworkConfig{AllowTailscale: &allow}}
		var listeners []net.Listener
		lastErr = nil
		for _, address := range moduleListenAddresses(cfg) {
			listener, err := net.Listen("tcp", address)
			if err != nil {
				lastErr = fmt.Errorf("listen %s: %w", address, err)
				break
			}
			listeners = append(listeners, listener)
		}
		if lastErr == nil {
			t.Cleanup(func() {
				for _, listener := range listeners {
					_ = listener.Close()
				}
			})
			go acceptAndClose(listeners)
			return listeners
		}
		for _, listener := range listeners {
			_ = listener.Close()
		}
		if len(listeners) > 0 {
			// 首个监听已成功、后续同端口监听失败，说明监听集合自身冲突，不是端口被抢占。
			t.Fatal(lastErr)
		}
	}
	t.Fatal(lastErr)
	return nil
}

func acceptAndClose(listeners []net.Listener) {
	for _, listener := range listeners {
		go func(listener net.Listener) {
			for {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				_ = conn.Close()
			}
		}(listener)
	}
}

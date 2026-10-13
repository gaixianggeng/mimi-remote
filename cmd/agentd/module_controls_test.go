package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestModuleListenersAllOffRemainLocalAndDisabledCodexDoesNotStart(t *testing.T) {
	off, on := false, true
	cfg := config.Config{Listen: "100.64.0.2:8787", Network: config.NetworkConfig{AllowTailscale: &off}, Codex: config.CodexConfig{Enabled: &off, Bin: "/missing/module-test-codex"}}
	if got := moduleListenAddresses(cfg); !reflect.DeepEqual(got, []string{"127.0.0.1:8787"}) {
		t.Fatalf("off listeners %v", got)
	}
	cfg.Network.AllowTailscale = &on
	if got := moduleListenAddresses(cfg); !reflect.DeepEqual(got, []string{"0.0.0.0:8787", "[::]:8787"}) {
		t.Fatalf("gated listeners %v", got)
	}
	resident, err := prepareAgentAppServerRuntime(cfg)
	if err != nil || resident.routerOptions.AppServerSSH != nil || resident.managedWS != nil {
		t.Fatalf("disabled Codex started: %+v %v", resident, err)
	}
}

// 原配置绑定 IPv6 loopback 时，模块开关第一次接管监听不能把 ::1 丢掉；
// 否则只改一个模块开关就会让走 ::1 的本机客户端失去连接。外部连接开启时，
// IPv6 通配监听已经接受 ::1，不再重复绑定（Linux 上会与通配监听冲突）。
func TestModuleListenersPreserveIPv6Loopback(t *testing.T) {
	for _, tc := range []struct {
		name  string
		allow bool
		want  []string
	}{
		{"off", false, []string{"127.0.0.1:8787", "[::1]:8787"}},
		{"on", true, []string{"0.0.0.0:8787", "[::]:8787"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			allow := tc.allow
			cfg := config.Config{
				Listen:  "[::1]:8787",
				Network: config.NetworkConfig{AllowTailscale: &allow},
			}
			if got := moduleListenAddresses(cfg); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("IPv6 loopback 监听丢失：got %v want %v", got, tc.want)
			}
		})
	}
	// 非 IPv6 loopback 的配置保持原有行为，不额外增加监听。
	off := false
	cfg := config.Config{Listen: "100.64.0.2:8787", Network: config.NetworkConfig{AllowTailscale: &off}}
	if got := moduleListenAddresses(cfg); !reflect.DeepEqual(got, []string{"127.0.0.1:8787"}) {
		t.Fatalf("IPv4 配置不应增加监听：%v", got)
	}
}

func TestUnavailableModuleIPv6DoesNotHideOtherListenerFailures(t *testing.T) {
	for _, code := range []syscall.Errno{syscall.EAFNOSUPPORT, syscall.EPROTONOSUPPORT, syscall.EADDRNOTAVAIL} {
		err := fmt.Errorf("listen: %w", code)
		if !unavailableModuleIPv6("[::]:8787", err) {
			t.Fatalf("IPv6 unavailable should keep IPv4 running: %v", err)
		}
		if unavailableModuleIPv6("0.0.0.0:8787", err) || unavailableModuleIPv6("[::1]:8787", err) {
			t.Fatalf("configured listener failure must remain visible: %v", err)
		}
	}
	for _, err := range []error{nil, syscall.EADDRINUSE, syscall.EACCES} {
		if unavailableModuleIPv6("[::]:8787", err) {
			t.Fatalf("port conflict or permission failure must not be ignored: %v", err)
		}
	}
}

func TestModuleCLIRejectsAmbiguousMutations(t *testing.T) {
	if err := runRuntimeWithWriters([]string{"runtime", "--codex=disabled", "--claude=disabled"}, io.Discard, io.Discard); err == nil {
		t.Fatal("ambiguous runtime accepted")
	}
	if err := runNetworkWithWriters([]string{"network", "--lan-enabled=true", "--tailscale-enabled=false"}, io.Discard, io.Discard); err == nil {
		t.Fatal("ambiguous network accepted")
	}
}

func TestDisabledCodexStartupSkipsMigrationAndBinaryRepair(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"listen":"127.0.0.1:8787","auth":{"token":"module-test-only"},"codex":{"enabled":false,"bin":"/missing/module-test-codex"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := ensureCodexCLIAvailable(path); err != nil {
		t.Fatal(err)
	}
	if err := ensureAppServerTransportMigration(context.Background(), path, ""); err != nil {
		t.Fatal(err)
	}
}

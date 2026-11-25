package tailscaleinfo

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"
	"time"
)

func TestInspectReturnsNormalizedMagicDNSHost(t *testing.T) {
	host := inspect(context.Background(), func(context.Context) ([]byte, error) {
		return []byte(`{"Self":{"DNSName":"Studio-Mac.alpha-beta.ts.net."}}`), nil
	})
	if host.DNSName != "studio-mac.alpha-beta.ts.net" || host.DeviceName != "studio-mac" {
		t.Fatalf("MagicDNS 元数据异常：%+v", host)
	}
}

func TestInspectFailsOpenWithoutValidMagicDNS(t *testing.T) {
	tests := []struct {
		name   string
		output string
		err    error
	}{
		{name: "CLI unavailable", err: errors.New("missing")},
		{name: "no MagicDNS", output: `{"Self":{"DNSName":""}}`},
		{name: "short hostname", output: `{"Self":{"DNSName":"studio-mac"}}`},
		{name: "invalid hostname", output: `{"Self":{"DNSName":"bad name.tail.ts.net"}}`},
		{name: "invalid JSON", output: `{`},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			host := inspect(context.Background(), func(context.Context) ([]byte, error) {
				return []byte(testCase.output), testCase.err
			})
			if host != (Host{}) {
				t.Fatalf("异常环境必须回退为空元数据，got=%+v", host)
			}
		})
	}
}

func TestResolverCachesEmptyAndNonEmptyResults(t *testing.T) {
	var calls atomic.Int32
	resolver := newResolver(time.Minute, func(context.Context) Host {
		if calls.Add(1) == 1 {
			return Host{}
		}
		return Host{DNSName: "studio.tail.ts.net", DeviceName: "studio"}
	})
	if got := resolver.Lookup(context.Background()); got != (Host{}) {
		t.Fatalf("首次空结果异常：%+v", got)
	}
	if got := resolver.Lookup(context.Background()); got != (Host{}) {
		t.Fatalf("TTL 内应复用空结果：%+v", got)
	}
	if calls.Load() != 1 {
		t.Fatalf("TTL 内不应重复运行 CLI，calls=%d", calls.Load())
	}
}

func TestIsTailscaleEndpoint(t *testing.T) {
	if !IsTailscaleEndpoint("http://100.100.20.30:8787") {
		t.Fatal("CGNAT Tailscale 地址应被识别")
	}
	if IsTailscaleEndpoint("http://192.168.1.2:8787") {
		t.Fatal("LAN 地址不应被识别为 Tailscale")
	}
}

func TestCommandEnvForcesCLIMode(t *testing.T) {
	env := commandEnv([]string{
		"PATH=/usr/bin:/bin",
		"TAILSCALE_BE_CLI=false",
		"HOME=/tmp/example",
	})
	if !slices.Contains(env, "TAILSCALE_BE_CLI=true") {
		t.Fatalf("应注入 TAILSCALE_BE_CLI=true：%v", env)
	}
	if slices.Contains(env, "TAILSCALE_BE_CLI=false") {
		t.Fatalf("应覆盖旧的 TAILSCALE_BE_CLI 值：%v", env)
	}
	if !slices.Contains(env, "PATH=/usr/bin:/bin") || !slices.Contains(env, "HOME=/tmp/example") {
		t.Fatalf("不应丢弃原有环境变量：%v", env)
	}
}

type fakeFileInfo struct {
	mode os.FileMode
}

func (f fakeFileInfo) Name() string       { return "Tailscale" }
func (f fakeFileInfo) Size() int64        { return 1 }
func (f fakeFileInfo) Mode() os.FileMode  { return f.mode }
func (f fakeFileInfo) ModTime() time.Time { return time.Time{} }
func (f fakeFileInfo) IsDir() bool        { return f.mode.IsDir() }
func (f fakeFileInfo) Sys() any           { return nil }

func TestFindCLIFallsBackToDarwinAppBundles(t *testing.T) {
	home := filepath.Join(string(filepath.Separator), "Users", "example")
	userBundle := filepath.Join(home, "Applications", "Tailscale.app", "Contents", "MacOS", "Tailscale")
	missing := errors.New("not found")

	got, err := findCLI(
		func(string) (string, error) { return "", missing },
		func(path string) (os.FileInfo, error) {
			if path == userBundle {
				return fakeFileInfo{mode: 0o755}, nil
			}
			return nil, os.ErrNotExist
		},
		"darwin",
		home,
	)
	if err != nil || got != userBundle {
		t.Fatalf("应回退到用户目录 Tailscale.app：got=%q err=%v", got, err)
	}
}

func TestFirstIPv4UsesCLIAndFallsBackSafely(t *testing.T) {
	tests := []struct {
		name       string
		stdout     string
		stderr     string
		err        error
		fallbackIP string
		want       string
	}{
		{
			name:       "CLI returns valid IPv4",
			stdout:     "100.100.20.30\n",
			fallbackIP: "100.64.0.9",
			want:       "100.100.20.30",
		},
		{
			name:       "App Store GUI fallback output with exit 0",
			stdout:     "The Tailscale GUI failed to start: The operation couldn't be completed. (Tailscale.CLIError error 3.)\n",
			fallbackIP: "100.64.10.20",
			want:       "100.64.10.20",
		},
		{
			name:       "App Store CLI credentials unavailable",
			stderr:     "Error: CLI credentials are not available\n",
			err:        errors.New("exit status 1"),
			fallbackIP: "100.64.10.21",
			want:       "100.64.10.21",
		},
		{
			name:       "CLI missing",
			err:        errors.New("executable file not found"),
			fallbackIP: "100.64.10.22",
			want:       "100.64.10.22",
		},
		{
			name:       "CLI reports stopped must not fallback",
			stderr:     "Tailscale is stopped.\n",
			err:        errors.New("exit status 1"),
			fallbackIP: "100.64.10.23",
			want:       "",
		},
		{
			name:       "CLI reports logged out must not fallback",
			stderr:     "Logged out.\n",
			err:        errors.New("exit status 1"),
			fallbackIP: "100.64.10.24",
			want:       "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := firstIPv4(
				context.Background(),
				func(context.Context) ([]byte, []byte, error) {
					return []byte(tc.stdout), []byte(tc.stderr), tc.err
				},
				func() string { return tc.fallbackIP },
			)
			if got != tc.want {
				t.Fatalf("FirstIPv4 结果异常：got=%q want=%q", got, tc.want)
			}
		})
	}
}

func TestSelectInterfaceIPv4PrefersTailscaleAndIgnoresPhysicalCGNAT(t *testing.T) {
	mustAddr := func(raw string) netip.Addr {
		t.Helper()
		return netip.MustParseAddr(raw)
	}

	t.Run("ignores physical interface CGNAT and loopback or down interfaces", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "en0", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.1.10")}},
			{name: "lo0", flags: net.FlagUp | net.FlagLoopback, addrs: []netip.Addr{mustAddr("100.64.1.11")}},
			{name: "utun4", flags: 0, addrs: []netip.Addr{mustAddr("100.64.1.12"), mustAddr("fd7a:115c:a1e0::1")}},
		})
		if got != "" {
			t.Fatalf("物理 CGNAT、回环或未启用接口不应被当作 Tailscale：%q", got)
		}
	})

	t.Run("prefers utun with Tailscale IPv6 over bare utun", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "en0", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.1.10")}},
			{name: "utun1", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.2.1")}},
			{name: "utun4", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.100.20.30"), mustAddr("fd7a:115c:a1e0::1234")}},
		})
		if got != "100.100.20.30" {
			t.Fatalf("应优先选择带 Tailscale IPv6 前缀的隧道网卡：got=%q", got)
		}
	})

	t.Run("falls back to bare utun tunnel when IPv6 absent", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "utun4", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.88.77.66")}},
		})
		if got != "100.88.77.66" {
			t.Fatalf("无 IPv6 时应回退到活跃 utun 隧道地址：got=%q", got)
		}
	})

	t.Run("matches named tailscale interface", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "Tailscale", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.99.88.77")}},
		})
		if got != "100.99.88.77" {
			t.Fatalf("应识别命名为 Tailscale 的网卡：got=%q", got)
		}
	})
}

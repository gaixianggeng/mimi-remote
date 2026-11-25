package tailscaleinfo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
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

func TestTailscaleHelperProcess(t *testing.T) {
	mode := os.Getenv("MIMI_TAILSCALE_HELPER_MODE")
	if mode == "" {
		return
	}
	switch mode {
	case "dump-env":
		payload := map[string]string{
			"TAILSCALE_BE_CLI":    os.Getenv("TAILSCALE_BE_CLI"),
			"tailscale_be_cli":    os.Getenv("tailscale_be_cli"),
			"MIMI_TEST_INHERITED": os.Getenv("MIMI_TEST_INHERITED"),
		}
		encoded, err := json.Marshal(payload)
		if err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			os.Exit(2)
		}
		_, _ = os.Stdout.Write(encoded)
		os.Exit(0)
	case "emit":
		if out := os.Getenv("MIMI_HELPER_STDOUT"); out != "" {
			_, _ = fmt.Fprint(os.Stdout, out)
		}
		if errOut := os.Getenv("MIMI_HELPER_STDERR"); errOut != "" {
			_, _ = fmt.Fprint(os.Stderr, errOut)
		}
		code, _ := strconv.Atoi(os.Getenv("MIMI_HELPER_EXIT"))
		os.Exit(code)
	case "sleep":
		time.Sleep(10 * time.Second)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "unknown helper mode: %s\n", mode)
		os.Exit(2)
	}
}

func helperCommandBuilder(ctx context.Context, args ...string) (*exec.Cmd, error) {
	helperArgs := append([]string{"-test.run=^TestTailscaleHelperProcess$", "--"}, args...)
	return newCommandContext(ctx, os.Args[0], helperArgs...), nil
}

func TestCommandContextForcesCLIModeAndPreservesOtherEnv(t *testing.T) {
	t.Setenv("TAILSCALE_BE_CLI", "false")
	t.Setenv("MIMI_TEST_INHERITED", "keep-value")
	t.Setenv("MIMI_TAILSCALE_HELPER_MODE", "dump-env")
	if runtime.GOOS != "windows" {
		t.Setenv("tailscale_be_cli", "lowercase-value")
	}

	cmd, err := helperCommandBuilder(context.Background(), "ip", "-4")
	if err != nil {
		t.Fatal(err)
	}
	effectiveEnv := cmd.Environ()
	if !slices.Contains(effectiveEnv, "TAILSCALE_BE_CLI=true") {
		t.Fatal("应注入 TAILSCALE_BE_CLI=true")
	}
	if slices.Contains(effectiveEnv, "TAILSCALE_BE_CLI=false") {
		t.Fatal("应覆盖旧的 TAILSCALE_BE_CLI 值")
	}
	if !slices.Contains(effectiveEnv, "MIMI_TEST_INHERITED=keep-value") {
		t.Fatal("不应丢弃其他环境变量")
	}
	if runtime.GOOS != "windows" && !slices.Contains(effectiveEnv, "tailscale_be_cli=lowercase-value") {
		t.Fatal("Unix 下不应删除大小写不同的合法环境键")
	}

	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("运行辅助子进程失败：%v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("解析子进程环境输出失败：%v", err)
	}
	if got["TAILSCALE_BE_CLI"] != "true" {
		t.Fatal("子进程 TAILSCALE_BE_CLI 必须被强制为 true")
	}
	if got["MIMI_TEST_INHERITED"] != "keep-value" {
		t.Fatal("子进程应继承 MIMI_TEST_INHERITED")
	}
	if runtime.GOOS != "windows" && got["tailscale_be_cli"] != "lowercase-value" {
		t.Fatal("Unix 子进程应保留独立的 tailscale_be_cli 键")
	}
	if parentVal := os.Getenv("TAILSCALE_BE_CLI"); parentVal != "false" {
		t.Fatalf("不得修改父进程环境：got=%q", parentVal)
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

	got, err := FindCLIForHost(
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
		name             string
		stdout           string
		stderr           string
		err              error
		fallbackIP       string
		want             string
		wantFallbackCall bool
	}{
		{
			name:             "CLI returns valid IPv4",
			stdout:           "100.100.20.30\n",
			fallbackIP:       "100.64.0.9",
			want:             "100.100.20.30",
			wantFallbackCall: false,
		},
		{
			name:             "App Store GUI fallback output with exit 0",
			stdout:           "The Tailscale GUI failed to start: The operation couldn't be completed. (Tailscale.CLIError error 3.)\n",
			fallbackIP:       "100.64.10.20",
			want:             "100.64.10.20",
			wantFallbackCall: true,
		},
		{
			name:             "App Store CLI credentials unavailable",
			stderr:           "Error: CLI credentials are not available\n",
			err:              errors.New("exit status 1"),
			fallbackIP:       "100.64.10.21",
			want:             "100.64.10.21",
			wantFallbackCall: true,
		},
		{
			name:             "CLI missing",
			err:              errors.New("executable file not found"),
			fallbackIP:       "100.64.10.22",
			want:             "100.64.10.22",
			wantFallbackCall: true,
		},
		{
			name:             "CLI reports stopped must not fallback",
			stderr:           "Tailscale is stopped.\n",
			err:              errors.New("exit status 1"),
			fallbackIP:       "100.64.10.23",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "CLI reports real state Stopped must not fallback",
			stderr:           "no current Tailscale IPs; state: Stopped\n",
			err:              errors.New("exit status 1"),
			fallbackIP:       "100.64.10.23",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "CLI reports real state NeedsLogin must not fallback",
			stderr:           "no current Tailscale IPs; state: NeedsLogin\n",
			err:              errors.New("exit status 1"),
			fallbackIP:       "100.64.10.23",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "CLI reports real state NoState must not fallback",
			stderr:           "no current Tailscale IPs; state: NoState\n",
			err:              errors.New("exit status 1"),
			fallbackIP:       "100.64.10.23",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "CLI reports logged out must not fallback",
			stderr:           "Logged out.\n",
			err:              errors.New("exit status 1"),
			fallbackIP:       "100.64.10.24",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "CLI exit 0 with stdout IPv4 and stderr state Stopped rejects both",
			stdout:           "100.100.20.30\n",
			stderr:           "no current Tailscale IPs; state: Stopped\n",
			fallbackIP:       "100.64.10.25",
			want:             "",
			wantFallbackCall: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fallbackCalled := false
			got := firstIPv4(
				context.Background(),
				func(context.Context) ([]byte, []byte, error) {
					return []byte(tc.stdout), []byte(tc.stderr), tc.err
				},
				func() string {
					fallbackCalled = true
					return tc.fallbackIP
				},
			)
			if got != tc.want {
				t.Fatalf("FirstIPv4 结果异常：got=%q want=%q", got, tc.want)
			}
			if fallbackCalled != tc.wantFallbackCall {
				t.Fatalf("fallback 调用状态异常：called=%v want=%v", fallbackCalled, tc.wantFallbackCall)
			}
		})
	}
}

func TestFirstIPv4SubprocessHandling(t *testing.T) {
	tests := []struct {
		name             string
		stdout           string
		stderr           string
		exitCode         int
		fallbackIP       string
		want             string
		wantFallbackCall bool
	}{
		{
			name:             "real upstream state Stopped error does not call fallback",
			stderr:           "no current Tailscale IPs; state: Stopped\n",
			exitCode:         1,
			fallbackIP:       "100.64.10.30",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "exit 0 with stderr state Stopped rejects stdout IP and skips fallback",
			stdout:           "100.100.20.30\n",
			stderr:           "no current Tailscale IPs; state: Stopped\n",
			exitCode:         0,
			fallbackIP:       "100.64.10.31",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "exit 0 with stderr NeedsLogin skips fallback",
			stderr:           "no current Tailscale IPs; state: NeedsLogin\n",
			exitCode:         0,
			fallbackIP:       "100.64.10.32",
			want:             "",
			wantFallbackCall: false,
		},
		{
			name:             "exit 0 GUI error allows confirmed fallback",
			stdout:           "The Tailscale GUI failed to start: The operation couldn't be completed. (Tailscale.CLIError error 3.)\n",
			exitCode:         0,
			fallbackIP:       "100.64.10.33",
			want:             "100.64.10.33",
			wantFallbackCall: true,
		},
		{
			name:             "CLI credentials unavailable allows confirmed fallback",
			stderr:           "Error: CLI credentials are not available\n",
			exitCode:         1,
			fallbackIP:       "100.64.10.34",
			want:             "100.64.10.34",
			wantFallbackCall: true,
		},
		{
			name:             "exit 0 with valid IPv4 returns CLI IP without fallback",
			stdout:           "100.100.20.30\n",
			exitCode:         0,
			fallbackIP:       "100.64.10.35",
			want:             "100.100.20.30",
			wantFallbackCall: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("MIMI_TAILSCALE_HELPER_MODE", "emit")
			t.Setenv("MIMI_HELPER_STDOUT", tc.stdout)
			t.Setenv("MIMI_HELPER_STDERR", tc.stderr)
			t.Setenv("MIMI_HELPER_EXIT", strconv.Itoa(tc.exitCode))

			fallbackCalled := false
			got := firstIPv4(
				context.Background(),
				func(ctx context.Context) ([]byte, []byte, error) {
					return runIPv4CommandWithTimeout(ctx, helperCommandBuilder, 5*time.Second)
				},
				func() string {
					fallbackCalled = true
					return tc.fallbackIP
				},
			)
			if got != tc.want {
				t.Fatalf("子进程场景 FirstIPv4 结果异常：got=%q want=%q", got, tc.want)
			}
			if fallbackCalled != tc.wantFallbackCall {
				t.Fatalf("子进程场景 fallback 调用状态异常：called=%v want=%v", fallbackCalled, tc.wantFallbackCall)
			}
		})
	}
}

func TestFirstIPv4RespectsParentContextCancellation(t *testing.T) {
	t.Run("already canceled parent context skips CLI and fallback", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()

		cliCalled := false
		fallbackCalled := false
		got := firstIPv4(
			ctx,
			func(context.Context) ([]byte, []byte, error) {
				cliCalled = true
				return nil, nil, errors.New("should not run")
			},
			func() string {
				fallbackCalled = true
				return "100.64.10.40"
			},
		)
		if got != "" || cliCalled || fallbackCalled {
			t.Fatalf("父上下文已取消时不得运行 CLI 或回退：got=%q cli=%v fallback=%v", got, cliCalled, fallbackCalled)
		}
	})

	t.Run("parent context canceled during CLI execution skips fallback", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		fallbackCalled := false
		got := firstIPv4(
			ctx,
			func(context.Context) ([]byte, []byte, error) {
				cancel()
				return nil, nil, context.Canceled
			},
			func() string {
				fallbackCalled = true
				return "100.64.10.41"
			},
		)
		if got != "" || fallbackCalled {
			t.Fatalf("CLI 执行期间父上下文取消后不得回退：got=%q fallback=%v", got, fallbackCalled)
		}
	})

	t.Run("parent context deadline exceeded on subprocess skips fallback", func(t *testing.T) {
		t.Setenv("MIMI_TAILSCALE_HELPER_MODE", "sleep")
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()

		fallbackCalled := false
		got := firstIPv4(
			ctx,
			func(runCtx context.Context) ([]byte, []byte, error) {
				return runIPv4CommandWithTimeout(runCtx, helperCommandBuilder, 5*time.Second)
			},
			func() string {
				fallbackCalled = true
				return "100.64.10.42"
			},
		)
		if got != "" || fallbackCalled {
			t.Fatalf("父上下文超时后不得回退网卡：got=%q fallback=%v", got, fallbackCalled)
		}
	})

	t.Run("internal CLI timeout with live parent context allows fallback", func(t *testing.T) {
		t.Setenv("MIMI_TAILSCALE_HELPER_MODE", "sleep")
		fallbackCalled := false
		got := firstIPv4(
			context.Background(),
			func(runCtx context.Context) ([]byte, []byte, error) {
				return runIPv4CommandWithTimeout(runCtx, helperCommandBuilder, 200*time.Millisecond)
			},
			func() string {
				fallbackCalled = true
				return "100.64.10.43"
			},
		)
		if got != "100.64.10.43" || !fallbackCalled {
			t.Fatalf("仅内部 CLI 探测超时且父上下文有效时应允许回退：got=%q fallback=%v", got, fallbackCalled)
		}
	})
}

func TestSelectInterfaceIPv4PrefersTailscaleAndIgnoresPhysicalCGNAT(t *testing.T) {
	mustAddr := func(raw string) netip.Addr {
		t.Helper()
		return netip.MustParseAddr(raw)
	}

	t.Run("ignores physical interface CGNAT and loopback or down interfaces", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "en0", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.1.10")}},
			{name: "lo0", flags: net.FlagUp | net.FlagLoopback, addrs: []netip.Addr{mustAddr("100.64.1.11"), mustAddr("fd7a:115c:a1e0::2")}},
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

	t.Run("rejects bare utun tunnel without Tailscale ownership evidence", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "utun4", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.88.77.66")}},
		})
		if got != "" {
			t.Fatalf("缺少 Tailscale 归属证据的裸 utun 隧道必须返回空：got=%q", got)
		}
	})

	t.Run("rejects single third-party VPN tunnel with CGNAT IPv4", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "tun0", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.20.10"), mustAddr("fe80::1"), mustAddr("fd12:3456:789a::1")}},
		})
		if got != "" {
			t.Fatalf("单个其他 VPN 隧道的 CGNAT 地址不得被当作 Tailscale：got=%q", got)
		}
	})

	t.Run("rejects multiple third-party VPN tunnels with CGNAT IPv4", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "utun1", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.2.1")}},
			{name: "utun3", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.3.1"), mustAddr("fd00::1")}},
			{name: "tun0", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.4.1"), mustAddr("fe80::2")}},
		})
		if got != "" {
			t.Fatalf("多个其他 VPN 隧道共存且无 Tailscale 归属证据时必须返回空：got=%q", got)
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

	t.Run("rejects bridge interface merely containing tailscale substring", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "br-tailscale", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.5.10")}},
		})
		if got != "" {
			t.Fatalf("仅包含 tailscale 子串且无 Tailscale IPv6 的网桥必须返回空：got=%q", got)
		}
	})

	t.Run("prefers real tailscale0 over br-tailscale bridge", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "br-tailscale", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.5.10")}},
			{name: "tailscale0", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.100.20.40")}},
		})
		if got != "100.100.20.40" {
			t.Fatalf("br-tailscale 与 tailscale0 并存时不得选中网桥：got=%q", got)
		}
	})

	t.Run("prefers utun with Tailscale IPv6 over br-tailscale bridge", func(t *testing.T) {
		got := selectInterfaceIPv4([]interfaceSnapshot{
			{name: "br-tailscale", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.64.5.10")}},
			{name: "utun4", flags: net.FlagUp, addrs: []netip.Addr{mustAddr("100.100.20.41"), mustAddr("fd7a:115c:a1e0::5678")}},
		})
		if got != "100.100.20.41" {
			t.Fatalf("br-tailscale 与带 Tailscale IPv6 的隧道并存时不得选中网桥：got=%q", got)
		}
	})
}

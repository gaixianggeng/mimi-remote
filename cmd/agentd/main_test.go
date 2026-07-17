package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestVersionDoesNotRequireConfig(t *testing.T) {
	if err := run([]string{"agentd", "version"}); err != nil {
		t.Fatalf("version 不应依赖配置：%v", err)
	}
}

func TestAgentDListenAddressesAddsLoopbackForSpecificRemoteBind(t *testing.T) {
	tests := []struct {
		name       string
		configured string
		want       []string
	}{
		{name: "Tailscale IPv4", configured: "100.127.16.9:8787", want: []string{"100.127.16.9:8787", "127.0.0.1:8787"}},
		{name: "LAN IPv4", configured: "192.168.31.10:9000", want: []string{"192.168.31.10:9000", "127.0.0.1:9000"}},
		{name: "loopback", configured: "127.0.0.1:8787", want: []string{"127.0.0.1:8787"}},
		{name: "localhost", configured: "localhost:8787", want: []string{"localhost:8787"}},
		{name: "IPv4 wildcard", configured: "0.0.0.0:8787", want: []string{"0.0.0.0:8787"}},
		{name: "IPv6 wildcard", configured: "[::]:8787", want: []string{"[::]:8787"}},
		{name: "invalid keeps original", configured: "bad-address", want: []string{"bad-address"}},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			if got := agentDListenAddresses(testCase.configured); !reflect.DeepEqual(got, testCase.want) {
				t.Fatalf("监听地址不符合预期：got=%v want=%v", got, testCase.want)
			}
		})
	}
}

func TestRunPairQROnlyNeverPrintsLongLivedCredentials(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	const longLivedToken = "0123456789abcdef0123456789abcdef"
	configPath := filepath.Join(t.TempDir(), "config.json")
	cfg := config.Config{
		Listen: "127.0.0.1:8787",
		Auth:   config.AuthConfig{Token: longLivedToken},
	}
	rawConfig, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, rawConfig, 0o600); err != nil {
		t.Fatal(err)
	}

	for _, testCase := range []struct {
		name string
		args []string
	}{
		{name: "terminal", args: []string{"pair", "--config", configPath, "--qr-only"}},
		{name: "json", args: []string{"pair", "--config", configPath, "--qr-only", "--json"}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			var stdout, stderr strings.Builder
			if err := runPairWithWriters(testCase.args, &stdout, &stderr); err != nil {
				t.Fatalf("pair --qr-only 失败：%v stderr=%s", err, stderr.String())
			}
			output := stdout.String()
			for _, want := range []string{"127.0.0.1:8787", "mimiremote://pair", "pair_sig"} {
				if !strings.Contains(output, want) {
					t.Fatalf("安全配对输出缺少 %q：%s", want, output)
				}
			}
			for _, forbidden := range []string{longLivedToken, "Token：", "connect_url", "mimiremote://connect"} {
				if strings.Contains(output, forbidden) {
					t.Fatalf("安全配对输出泄漏长期凭据 %q：%s", forbidden, output)
				}
			}
		})
	}
}

func TestBrewServiceConfigGuardAllowsPlatformDefault(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	customPath := filepath.Join(t.TempDir(), "custom-config.json")
	t.Setenv("AGENTD_CONFIG", customPath)

	if err := ensureBrewServiceDefaultConfig(config.PlatformDefaultPath()); err != nil {
		t.Fatalf("平台默认 config.json 必须允许 Homebrew 后台托管：%v", err)
	}
	if err := ensureBrewServiceDefaultConfig(filepath.Clean(config.PlatformDefaultPath())); err != nil {
		t.Fatalf("清理后的等价默认路径也应允许：%v", err)
	}
}

func TestManagedServiceAdapterUsesPlatformCommands(t *testing.T) {
	tests := []struct {
		name        string
		goos        string
		commandName string
		action      string
		wantArgs    string
		needsUnit   bool
	}{
		{
			name:        "mac keeps brew services",
			goos:        "darwin",
			commandName: "brew",
			action:      "start",
			wantArgs:    "services start mimi-remote",
		},
		{
			name:        "linux start",
			goos:        "linux",
			commandName: "systemctl",
			action:      "start",
			wantArgs:    "--user start mimi-remote.service",
			needsUnit:   true,
		},
		{
			name:        "linux restart",
			goos:        "linux",
			commandName: "systemctl",
			action:      "restart",
			wantArgs:    "--user restart mimi-remote.service",
			needsUnit:   true,
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			marker := prepareManagedCommandProbe(t, testCase.commandName)
			if testCase.needsUnit {
				writeMainTestLinuxUnit(t)
			}
			var stdout, stderr strings.Builder
			if err := runManagedServiceForPlatform(testCase.goos, testCase.action, &stdout, &stderr); err != nil {
				t.Fatalf("平台服务命令失败：%v", err)
			}
			raw, err := os.ReadFile(marker)
			if err != nil {
				t.Fatal(err)
			}
			if got := strings.TrimSpace(string(raw)); got != testCase.wantArgs {
				t.Fatalf("服务命令参数错误：got=%q want=%q", got, testCase.wantArgs)
			}
		})
	}
}

func TestManagedLogsLinuxUsesJournalctlAndFollow(t *testing.T) {
	for _, testCase := range []struct {
		name      string
		lineCount int
		follow    bool
		wantArgs  string
	}{
		{
			name:      "recent logs",
			lineCount: 42,
			wantArgs:  "--user -u mimi-remote.service -n 42 --no-pager",
		},
		{
			name:      "follow logs",
			lineCount: 42,
			follow:    true,
			wantArgs:  "--user -u mimi-remote.service -n 42 --no-pager -f",
		},
		{
			name:      "zero uses default",
			lineCount: 0,
			wantArgs:  "--user -u mimi-remote.service -n 120 --no-pager",
		},
		{
			name:      "negative uses default",
			lineCount: -8,
			wantArgs:  "--user -u mimi-remote.service -n 120 --no-pager",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			marker := prepareManagedCommandProbe(t, "journalctl")
			writeMainTestLinuxUnit(t)
			var stdout, stderr strings.Builder
			if err := runManagedLogsForPlatform("linux", testCase.lineCount, testCase.follow, &stdout, &stderr); err != nil {
				t.Fatalf("Linux 日志命令失败：%v", err)
			}
			raw, err := os.ReadFile(marker)
			if err != nil {
				t.Fatal(err)
			}
			if got := strings.TrimSpace(string(raw)); got != testCase.wantArgs {
				t.Fatalf("journalctl 参数错误：got=%q want=%q", got, testCase.wantArgs)
			}
		})
	}
}

func TestManagedLogsDarwinUsesNormalizedDefaultWithFollow(t *testing.T) {
	marker, logPath := prepareDarwinLogCommandProbe(t)
	var stdout, stderr strings.Builder
	if err := runManagedLogsForPlatform("darwin", 0, true, &stdout, &stderr); err != nil {
		t.Fatalf("Darwin follow 日志失败：%v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	want := "-n 120 -f " + logPath
	if got := strings.TrimSpace(string(raw)); got != want {
		t.Fatalf("Darwin tail 参数错误：got=%q want=%q", got, want)
	}
}

func TestManagedLogsRejectsTooManyLinesBeforeCommand(t *testing.T) {
	marker := prepareManagedCommandProbe(t, "journalctl")
	var stdout, stderr strings.Builder
	err := runManagedLogsForPlatform("linux", maxLogLineCount+1, false, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "1 到 5000") {
		t.Fatalf("超大日志行数必须明确报错：%v", err)
	}
	assertPathDoesNotExist(t, marker, "行数超限时不能调用 journalctl")
}

func TestManagedServiceLinuxMissingUnitExplainsInstaller(t *testing.T) {
	marker := prepareManagedCommandProbe(t, "systemctl")
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(t.TempDir(), ".config"))
	var stdout, stderr strings.Builder
	err := runManagedServiceForPlatform("linux", "start", &stdout, &stderr)
	if err == nil {
		t.Fatal("缺少 Linux unit 时必须拒绝执行 systemctl")
	}
	for _, want := range []string{"尚未安装 Linux user-systemd 服务", "scripts/install-linux.sh install"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("缺少 unit 的提示不完整，缺少 %q：%v", want, err)
		}
	}
	assertPathDoesNotExist(t, marker, "unit 缺失时不能调用 systemctl")
}

func TestManagedServiceRejectsUnsupportedPlatform(t *testing.T) {
	var stdout, stderr strings.Builder
	for _, action := range []func() error{
		func() error { return runManagedServiceForPlatform("windows", "start", &stdout, &stderr) },
		func() error { return runManagedLogsForPlatform("windows", 10, false, &stdout, &stderr) },
	} {
		err := action()
		if err == nil || !strings.Contains(err.Error(), "不支持后台服务命令") || !strings.Contains(err.Error(), "agentd serve") {
			t.Fatalf("不支持的平台必须给出前台运行提示：%v", err)
		}
	}
}

func TestStopDispatchUsesDarwinServiceWithNeutralOutput(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	useManagedServicePlatform(t, "darwin")
	marker := prepareManagedCommandProbe(t, "brew")
	stdout, _, err := captureMainCommandOutput(t, func() error {
		return run([]string{"agentd", "stop"})
	})
	if err != nil {
		t.Fatalf("stop dispatch 失败：%v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(raw)); got != "services stop mimi-remote" {
		t.Fatalf("Darwin stop 参数错误：%q", got)
	}
	for _, want := range []string{"正在停止 Mimi Mac 助手", "Mimi Mac 助手已停止"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stop 输出缺少 %q：%q", want, stdout)
		}
	}
	if strings.Contains(stdout, "Homebrew") || strings.Contains(stdout, "systemd") {
		t.Fatalf("stop 用户输出必须平台中立：%q", stdout)
	}
	unknownErr := run([]string{"agentd", "not-a-command"})
	if unknownErr == nil || !strings.Contains(unknownErr.Error(), "stop") {
		t.Fatalf("CLI 可用命令提示必须包含 stop：%v", unknownErr)
	}
}

func TestStopLinuxUsesSystemdService(t *testing.T) {
	marker := prepareManagedCommandProbe(t, "systemctl")
	writeMainTestLinuxUnit(t)
	var stdout, stderr strings.Builder
	if err := runManagedServiceForPlatform("linux", "stop", &stdout, &stderr); err != nil {
		t.Fatalf("Linux stop 失败：%v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(raw)); got != "--user stop mimi-remote.service" {
		t.Fatalf("Linux stop 参数错误：%q", got)
	}
}

func TestStopRejectsCustomConfigBeforeSideEffects(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	useManagedServicePlatform(t, "darwin")
	marker := prepareManagedCommandProbe(t, "brew")
	customPath := filepath.Join(t.TempDir(), "custom stop config.json")

	err := run([]string{"agentd", "stop", "--config", customPath})
	assertCustomBrewConfigError(t, err, customPath)
	assertPathDoesNotExist(t, marker, "自定义配置校验失败后不能执行 stop")
	assertPathDoesNotExist(t, customPath, "stop 不应读取、创建或迁移配置")
}

func TestBrewManagedCommandsRejectExplicitCustomConfigBeforeSideEffects(t *testing.T) {
	for _, command := range []string{"up", "start", "restart"} {
		t.Run(command, func(t *testing.T) {
			clearAgentdEnvForMainTest(t)
			marker := prepareBrewSideEffectProbe(t)
			customPath := filepath.Join(t.TempDir(), "custom $config's file.json")

			err := run([]string{"agentd", command, "--config", customPath, "--wait", "0"})
			assertCustomBrewConfigError(t, err, customPath)
			assertPathDoesNotExist(t, marker, "自定义配置校验失败后不能调用 brew services")
			assertPathDoesNotExist(t, customPath, "自定义配置校验必须发生在 setup/pair 之前")
		})
	}
}

func TestBrewManagedCommandRejectsAgentdConfigBeforeSideEffects(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	marker := prepareBrewSideEffectProbe(t)
	customPath := filepath.Join(t.TempDir(), "env-config.json")
	t.Setenv("AGENTD_CONFIG", customPath)

	err := run([]string{"agentd", "restart", "--wait", "0"})
	assertCustomBrewConfigError(t, err, customPath)
	assertPathDoesNotExist(t, marker, "AGENTD_CONFIG 校验失败后不能调用 brew services")
}

func TestSetupCommandCreatesConfig(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	scanRoot := t.TempDir()

	if err := run([]string{
		"agentd",
		"setup",
		"-config", cfgPath,
		"-scan-root", scanRoot,
		"-listen", "127.0.0.1:8787",
		"-json",
	}); err != nil {
		t.Fatalf("setup 命令失败：%v", err)
	}
}

func TestDefaultPathCommandsReuseLegacyConfigWithoutRotatingToken(t *testing.T) {
	commands := []struct {
		name string
		run  func(t *testing.T, fixture mainLegacyConfigFixture) error
	}{
		{
			name: "brew serve config load",
			run: func(t *testing.T, fixture mainLegacyConfigFixture) error {
				cfg, _, _, err := loadRuntimeConfig([]string{"agentd"}, false)
				if err == nil && cfg.Auth.Token != fixture.token {
					t.Fatalf("serve 必须复用旧 token：got=%q", cfg.Auth.Token)
				}
				return err
			},
		},
		{name: "setup", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			return run([]string{"agentd", "setup", "--json"})
		}},
		{name: "up", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			prepareBrewSideEffectProbe(t)
			return run([]string{"agentd", "up", "--wait", "0", "--json"})
		}},
		{name: "start", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			prepareBrewSideEffectProbe(t)
			return run([]string{"agentd", "start", "--wait", "0"})
		}},
		{name: "restart", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			prepareBrewSideEffectProbe(t)
			return run([]string{"agentd", "restart", "--wait", "0"})
		}},
		{name: "status", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			return run([]string{"agentd", "status", "--json"})
		}},
		{name: "pair", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			return run([]string{"agentd", "pair", "--json"})
		}},
		{name: "doctor", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			return run([]string{"agentd", "doctor", "--json"})
		}},
	}

	for _, testCase := range commands {
		t.Run(testCase.name, func(t *testing.T) {
			fixture := prepareMainLegacyConfigFixture(t)
			_, stderr, err := captureMainCommandOutput(t, func() error {
				return testCase.run(t, fixture)
			})
			if err != nil {
				t.Fatalf("默认路径命令应直接复用迁移配置：%v", err)
			}
			if count := strings.Count(stderr, "已复用旧版配置并迁移到新目录"); count != 1 {
				t.Fatalf("成功迁移只应提示一次：count=%d stderr=%q", count, stderr)
			}
			if strings.Contains(stderr, fixture.token) || strings.Contains(stderr, "legacy-upstream-secret") {
				t.Fatalf("迁移提示不得把 token 写入日志：%q", stderr)
			}
			assertMainLegacyConfigPreserved(t, fixture)
		})
	}
}

func TestExplicitDefaultConfigFlagDoesNotTriggerLegacyMigration(t *testing.T) {
	fixture := prepareMainLegacyConfigFixture(t)
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	if err := fs.Parse([]string{"--config", fixture.destination}); err != nil {
		t.Fatal(err)
	}
	var notice strings.Builder
	if err := prepareDefaultConfigMigration(fs, *configPath, &notice); err != nil {
		t.Fatal(err)
	}
	if notice.Len() != 0 {
		t.Fatalf("显式 --config 不应产生迁移提示：%q", notice.String())
	}
	assertPathDoesNotExist(t, fixture.destination, "显式 --config 即使等于平台默认路径也不得触发迁移")
}

func TestServeConnectionIsNotPrintedToRegularFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}

	maybePrintServeConnection(file, agentsetup.Result{
		Endpoint:   "http://127.0.0.1:8787",
		Token:      "secret-token",
		ConnectURL: "mimiremote://connect?endpoint=http%3A%2F%2F127.0.0.1%3A8787&token=secret-token",
	})
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	output := string(raw)
	if strings.Contains(output, "secret-token") || strings.Contains(output, "mimiremote://connect") {
		t.Fatalf("serve 不应把连接凭证写入非交互式日志输出：%q", output)
	}
}

func TestShutdownServeDrainsHTTPBeforeRuntimeCleanup(t *testing.T) {
	requestStarted := make(chan struct{})
	releaseRequest := make(chan struct{})
	requestFinished := make(chan struct{})

	testServer := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(requestStarted)
		<-releaseRequest
		w.WriteHeader(http.StatusNoContent)
		close(requestFinished)
	}))
	shutdownStarted := make(chan struct{})
	testServer.Config.RegisterOnShutdown(func() { close(shutdownStarted) })
	testServer.Start()
	t.Cleanup(testServer.Close)

	requestDone := make(chan error, 1)
	go func() {
		resp, err := testServer.Client().Get(testServer.URL)
		if err == nil {
			_ = resp.Body.Close()
		}
		requestDone <- err
	}()
	<-requestStarted

	var cleanupCalls atomic.Int32
	cleanupCalled := make(chan struct{})
	shutdownDone := make(chan error, 1)
	go func() {
		shutdownDone <- shutdownServe(testServer.Config, time.Second, func() error {
			cleanupCalls.Add(1)
			close(cleanupCalled)
			return nil
		})
	}()
	<-shutdownStarted

	select {
	case <-cleanupCalled:
		t.Fatal("活动 HTTP 请求尚未 drain 时不能先回收 session/upstream")
	default:
	}
	close(releaseRequest)
	<-requestFinished
	if err := <-requestDone; err != nil {
		t.Fatalf("活动请求应在 graceful shutdown 中正常完成：%v", err)
	}
	if err := <-shutdownDone; err != nil {
		t.Fatalf("graceful shutdown 不应失败：%v", err)
	}
	if cleanupCalls.Load() != 1 {
		t.Fatalf("runtime cleanup 必须且只能执行一次，got=%d", cleanupCalls.Load())
	}
}

func TestWaitForServeExitPreservesCauseAndAlwaysCleansUp(t *testing.T) {
	upstreamErr := errors.New("managed upstream crashed")
	tests := []struct {
		name      string
		signal    os.Signal
		serveErr  error
		wantCause error
	}{
		{name: "signal", signal: syscall.SIGTERM},
		{name: "http closed", serveErr: http.ErrServerClosed},
		{name: "managed upstream error", serveErr: upstreamErr, wantCause: upstreamErr},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			stopCh := make(chan os.Signal, 1)
			errCh := make(chan error, 1)
			if tc.signal != nil {
				stopCh <- tc.signal
			} else {
				errCh <- tc.serveErr
			}
			var cleanupCalls atomic.Int32
			err := waitForServeExit(stopCh, errCh, func() error {
				cleanupCalls.Add(1)
				return nil
			})
			if tc.wantCause == nil && err != nil {
				t.Fatalf("正常退出不应返回错误：%v", err)
			}
			if tc.wantCause != nil && !errors.Is(err, tc.wantCause) {
				t.Fatalf("异常退出必须保留原始原因：got=%v want=%v", err, tc.wantCause)
			}
			if cleanupCalls.Load() != 1 {
				t.Fatalf("退出路径必须且只能清理一次，got=%d", cleanupCalls.Load())
			}
		})
	}
}

func TestAgentStatusAggregatesHealthAndReadiness(t *testing.T) {
	const (
		serverToken     = "status-server-token-0123456789"
		expectedVersion = "1.2.3"
	)
	tests := []struct {
		name           string
		readyStatus    int
		readyVersion   string
		clientToken    string
		wantServiceOK  bool
		wantReadyError string
	}{
		{
			name:           "health 200 ready 503",
			readyStatus:    http.StatusServiceUnavailable,
			clientToken:    serverToken,
			wantReadyError: "readyz HTTP 503",
		},
		{
			name:          "health 200 ready 200",
			readyStatus:   http.StatusOK,
			readyVersion:  expectedVersion,
			clientToken:   serverToken,
			wantServiceOK: true,
		},
		{
			name:           "ready authentication mismatch",
			readyStatus:    http.StatusOK,
			readyVersion:   expectedVersion,
			clientToken:    "status-client-token-mismatch",
			wantReadyError: "readyz HTTP 401",
		},
		{
			name:           "ready version mismatch",
			readyStatus:    http.StatusOK,
			readyVersion:   "1.2.2",
			clientToken:    serverToken,
			wantReadyError: "1.2.2",
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				switch req.URL.Path {
				case "/healthz":
					w.WriteHeader(http.StatusOK)
				case "/api/readyz":
					// readyz 必须使用外侧 Bearer Token；错误 Token 只能得到通用 401。
					if req.Header.Get("Authorization") != "Bearer "+serverToken {
						w.WriteHeader(http.StatusUnauthorized)
						return
					}
					w.WriteHeader(testCase.readyStatus)
					if testCase.readyStatus >= 200 && testCase.readyStatus < 300 {
						_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "version": testCase.readyVersion})
					}
				default:
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer server.Close()

			got := probeAgentServiceStatus(
				context.Background(),
				server.URL,
				testCase.clientToken,
				expectedVersion,
				time.Nanosecond,
			)
			if !got.ProcessOK() {
				t.Fatalf("healthz=200 时进程必须标记存活：%v", got.ProcessErr)
			}
			if got.Ready() != testCase.wantServiceOK {
				t.Fatalf("service_ok 聚合错误：got=%v ready_err=%v", got.Ready(), got.ReadyErr)
			}
			fields := serviceStatusFields(got, testCase.clientToken)
			if fields["process_ok"] != true || fields["service_ok"] != testCase.wantServiceOK {
				t.Fatalf("status JSON 字段语义错误：%v", fields)
			}
			serviceError, _ := fields["service_error"].(string)
			if testCase.wantReadyError == "" {
				if serviceError != "" {
					t.Fatalf("readyz 成功不应返回 service_error：%q", serviceError)
				}
			} else if !strings.Contains(serviceError, testCase.wantReadyError) {
				t.Fatalf("readyz 失败原因不明确：got=%q want=%q", serviceError, testCase.wantReadyError)
			}
			if strings.Contains(serviceError, testCase.clientToken) {
				t.Fatalf("status 错误不得泄露外侧 Token：%q", serviceError)
			}
		})
	}
}

func TestAgentStatusTextSeparatesProcessAndCodexAndRedactsToken(t *testing.T) {
	const token = "status-secret-must-not-leak"
	status := agentServiceStatus{
		ReadyErr: errors.New("readyz 暂不可用，authorization=" + token),
	}
	var output strings.Builder
	printServiceStatus(&output, status, token)

	text := output.String()
	for _, want := range []string{"进程存活：是", "Codex 服务可用：否", "<redacted>"} {
		if !strings.Contains(text, want) {
			t.Fatalf("status 文本缺少 %q：%q", want, text)
		}
	}
	if strings.Contains(text, token) {
		t.Fatalf("status 文本不得泄露外侧 Token：%q", text)
	}

	fields := serviceStatusFields(status, token)
	raw, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), token) || !strings.Contains(string(raw), `"process_ok":true`) || !strings.Contains(string(raw), `"service_ok":false`) {
		t.Fatalf("status JSON 应保留兼容字段并脱敏：%s", raw)
	}
}

func TestWaitForServiceReadyUsesBearerAndReadyz(t *testing.T) {
	const token = "ready-secret"
	const expectedVersion = "1.2.3"
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/api/readyz" {
			t.Errorf("就绪检查路径错误：%s", req.URL.Path)
		}
		if req.Header.Get("Authorization") != "Bearer "+token {
			t.Errorf("就绪检查必须携带 Bearer token：%q", req.Header.Get("Authorization"))
		}
		if requests.Add(1) == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{"ok":true,"version":"1.2.3"}`))
	}))
	defer server.Close()

	if err := waitForServiceReady(context.Background(), server.URL, token, expectedVersion, 2*time.Second); err != nil {
		t.Fatalf("readyz 从 503 恢复到 200 后应就绪：%v", err)
	}
	if requests.Load() < 2 {
		t.Fatalf("503 时应继续等待 readyz，requests=%d", requests.Load())
	}
}

func TestWaitForServiceReadyRejectsOldServerVersion(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true,"version":"1.2.2"}`))
	}))
	defer server.Close()

	err := waitForServiceReady(context.Background(), server.URL, "token", "1.2.3", time.Nanosecond)
	if err == nil {
		t.Fatal("旧 agentd 占用 Endpoint 时必须 fail-closed")
	}
	for _, want := range []string{"1.2.2", "1.2.3", "brew services restart mimi-remote", "agentd logs"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("版本不一致错误缺少 %q：%v", want, err)
		}
	}
}

func TestWaitForServiceReadyRejectsMalformedOrMissingVersion(t *testing.T) {
	for _, testCase := range []struct {
		name string
		body string
		want string
	}{
		{name: "malformed json", body: `not-json`, want: "不是有效 JSON"},
		{name: "missing version", body: `{"ok":true}`, want: "缺少 server version"},
		{name: "malformed trailing data", body: `{"version":"1.2.3"} trailing`, want: "畸形尾部数据"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				_, _ = w.Write([]byte(testCase.body))
			}))
			defer server.Close()

			err := waitForServiceReady(context.Background(), server.URL, "token", "1.2.3", time.Nanosecond)
			if err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("无可信版本的 readyz 必须失败并说明原因：%v", err)
			}
			if !strings.Contains(err.Error(), "agentd logs") {
				t.Fatalf("畸形 readyz 应给出排障命令：%v", err)
			}
		})
	}
}

func TestWaitForServiceReadyAllowsDevelopmentClientVersion(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true,"version":"local-test-server"}`))
	}))
	defer server.Close()

	if err := waitForServiceReady(context.Background(), server.URL, "token", "devel", time.Second); err != nil {
		t.Fatalf("默认开发版本不应误伤本地测试服务：%v", err)
	}
}

func TestWaitForServiceReadyTreatsRelease010AsFormalVersion(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true,"version":"0.0.9"}`))
	}))
	defer server.Close()

	err := waitForServiceReady(context.Background(), server.URL, "token", "0.1.0", time.Nanosecond)
	if err == nil || !strings.Contains(err.Error(), "0.0.9") || !strings.Contains(err.Error(), "0.1.0") {
		t.Fatalf("GoReleaser 注入的首个正式版本必须精确校验：%v", err)
	}
}

func TestRunDoctorFixOnlyTightensSensitiveFilePermissions(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	tokenPath := filepath.Join(dir, "app-server-token")
	projectPath := filepath.Join(dir, "project")
	if err := os.Mkdir(projectPath, 0o755); err != nil {
		t.Fatal(err)
	}
	const tokenContent = "upstream-token-must-not-change"
	if err := os.WriteFile(tokenPath, []byte(tokenContent), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(tokenPath, 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		Listen:  "127.0.0.1:8787",
		Auth:    config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime: config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{
			Transport:   "ws",
			Managed:     true,
			Listen:      "ws://127.0.0.1:4222",
			WSTokenFile: tokenPath,
		},
		Codex: config.CodexConfig{Bin: "/bin/true"},
		Projects: []config.ProjectConfig{{
			ID: "demo", Name: "Demo", Path: projectPath,
		}},
	}
	rawConfig, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, rawConfig, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(configPath, 0o644); err != nil {
		t.Fatal(err)
	}

	current := doctor.Results{Checks: []doctor.Check{
		{Name: "config-file", OK: false},
		{Name: "app-server-token-file", OK: false},
	}}
	fixes, _, _, err := runDoctorFix(context.Background(), configPath, false, current)
	if err != nil {
		t.Fatalf("doctor --fix 收紧权限失败：%v", err)
	}
	if len(fixes) != 2 {
		t.Fatalf("应分别修复配置与 token file 权限：%v", fixes)
	}
	for _, path := range []string{configPath, tokenPath} {
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s 权限应为 0600，实际 %04o", path, info.Mode().Perm())
		}
	}
	rawToken, err := os.ReadFile(tokenPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(rawToken) != tokenContent {
		t.Fatalf("doctor --fix 不能重建或改写 token：%q", rawToken)
	}
}

func TestDoctorFixMigratesLegacyManagedWSWithoutReplacingUserConfig(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	projectPath := filepath.Join(dir, "project")
	scanRoot := filepath.Join(dir, "scan")
	browseRoot := filepath.Join(dir, "browse")
	for _, path := range []string{projectPath, scanRoot, browseRoot} {
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	codexPath := filepath.Join(dir, "codex")
	writeMainTestCodex(t, codexPath)
	const authToken = "0123456789abcdef0123456789abcdef"

	// 这是旧版 pty + stdio 配置；Doctor 只能补 upstream token，不能用 setup --force 覆盖用户定制项。
	legacy := map[string]any{
		"listen": "127.0.0.1:8787",
		"auth": map[string]any{
			"token":             authToken,
			"allow_query_token": true,
		},
		"runtime": map[string]any{"type": "pty", "fallback_pty": true},
		"app_server": map[string]any{
			"transport":     "stdio",
			"managed":       true,
			"future_option": "keep-app-server-option",
		},
		"voice": map[string]any{
			"transcription_provider": "openai",
			"transcription_model":    "custom-transcribe-model",
			"transcription_base_url": "https://voice.example.test/v1",
		},
		"codex": map[string]any{
			"bin":          codexPath,
			"default_args": []string{"--no-alt-screen", "--custom"},
			"env":          map[string]string{"TERM": "xterm-256color", "KEEP_ME": "1"},
		},
		"claude": map[string]any{
			"enabled":                false,
			"bridge_bin":             "/custom/claude-bridge",
			"args":                   []string{"--keep"},
			"max_concurrent_bridges": 7,
			"env":                    map[string]string{"KEEP_CLAUDE": "1"},
		},
		"session":        map[string]any{"output_buffer_bytes": 4096},
		"debug":          map[string]any{"enable_codex_history": true},
		"projects":       []map[string]any{{"id": "demo", "name": "Demo", "path": projectPath}},
		"scan_roots":     []string{scanRoot},
		"browse_roots":   []string{browseRoot},
		"worktrees_root": filepath.Join(dir, "worktrees"),
		"actions": []map[string]any{{
			"id": "test", "name": "Test", "command": "go", "args": []string{"test", "./..."},
			"working_dir": projectPath, "timeout_seconds": 30, "requires_confirmation": true,
		}},
		"future_root": map[string]any{"nested": []any{"keep", 42.0}},
	}
	original, err := json.MarshalIndent(legacy, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(original, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := run([]string{"agentd", "doctor", "--config", configPath, "--fix", "--json"}); err != nil {
		t.Fatalf("legacy 配置应能由 doctor --fix 原地修复：%v", err)
	}
	updated, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var after map[string]any
	if err := json.Unmarshal(updated, &after); err != nil {
		t.Fatal(err)
	}
	afterAppServer := after["app_server"].(map[string]any)
	tokenPath, ok := afterAppServer["ws_token_file"].(string)
	if !ok || tokenPath == "" {
		t.Fatalf("doctor --fix 应持久化新 upstream token 路径：%+v", afterAppServer)
	}
	delete(afterAppServer, "ws_token_file")
	var before map[string]any
	if err := json.Unmarshal(original, &before); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("doctor --fix 除 ws_token_file 外不能改写用户配置：\nwant=%+v\n got=%+v", before, after)
	}
	configInfo, err := os.Lstat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !configInfo.Mode().IsRegular() || configInfo.Mode().Perm() != 0o600 {
		t.Fatalf("原子更新后的配置必须是 0600 regular file：%v", configInfo.Mode())
	}
	assertMainTestPrivateToken(t, tokenPath, authToken)

	migrated, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if migrated.Runtime.Type != "codex_app_server" || migrated.AppServer.Transport != "ws" || migrated.AppServer.Listen != "ws://127.0.0.1:4222" {
		t.Fatalf("修复后 legacy runtime 应继续平滑归一到 managed WS：%+v %+v", migrated.Runtime, migrated.AppServer)
	}
	if migrated.Auth.Token != authToken || migrated.AppServer.WSTokenFile != tokenPath || len(migrated.Actions) != 1 || len(migrated.BrowseRoots) != 1 {
		t.Fatalf("修复后业务配置必须保留：%+v", migrated)
	}
}

func TestRunDoctorFixMissingConfigStillUsesFullSetup(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.Mkdir(filepath.Join(home, "code"), 0o755); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(home, "config.json")
	current := doctor.Results{Checks: []doctor.Check{
		{Name: "token", OK: false},
		{Name: "projects", OK: false},
		{Name: "config-file", OK: false},
		{Name: "app-server-token-file", OK: false},
	}}

	fixes, _, _, err := runDoctorFix(context.Background(), configPath, false, current)
	if err != nil {
		t.Fatalf("配置完全缺失时仍应走完整 setup，而不是尝试局部迁移：%v", err)
	}
	if len(fixes) == 0 {
		t.Fatal("完整 setup 应返回修复记录")
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.Token == "" || cfg.AppServer.WSTokenFile == "" {
		t.Fatalf("完整 setup 应同时生成外侧 token 与 upstream token：%+v", cfg)
	}
}

func TestEnsureCodexCLIAvailableRepairsStalePathBeforeServiceStart(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	dir := t.TempDir()
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeMainTestCodex(t, codexPath)
	t.Setenv("PATH", binDir)
	configPath := filepath.Join(dir, "config.json")
	const authToken = "0123456789abcdef0123456789abcdef"
	document := map[string]any{
		"auth": map[string]any{"token": authToken},
		"codex": map[string]any{
			"bin":           "/opt/homebrew/bin/codex",
			"future_option": "keep-codex-option",
		},
		"future_root": "keep-root-option",
	}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := ensureCodexCLIAvailable(configPath); err != nil {
		t.Fatalf("启动前应自动恢复 Codex 路径：%v", err)
	}
	updated, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var after map[string]any
	if err := json.Unmarshal(updated, &after); err != nil {
		t.Fatal(err)
	}
	afterCodex := after["codex"].(map[string]any)
	if afterCodex["bin"] != codexPath || afterCodex["future_option"] != "keep-codex-option" {
		t.Fatalf("只应修复路径并保留 Codex 扩展配置：%+v", afterCodex)
	}
	if after["future_root"] != "keep-root-option" || after["auth"].(map[string]any)["token"] != authToken {
		t.Fatalf("启动前修复不能改写 Token 或未知字段：%+v", after)
	}
}

func clearAgentdEnvForMainTest(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"AGENTD_CONFIG", "AGENTD_LISTEN", "AGENTD_BIND", "AGENTD_PORT", "AGENTD_TOKEN",
		"AGENTD_ALLOW_QUERY_TOKEN", "AGENTD_CODEX_BIN", "AGENTD_CODEX_ARGS", "AGENTD_APP_SERVER_TRANSPORT",
		"AGENTD_APP_SERVER_LISTEN", "AGENTD_APP_SERVER_WS_TOKEN_FILE", "AGENTD_APP_SERVER_MANAGED",
		"AGENTD_CLAUDE_ENABLED", "AGENTD_CLAUDE_BRIDGE_BIN", "AGENTD_CLAUDE_BRIDGE_ARGS",
		"AGENTD_CLAUDE_MAX_CONCURRENT_BRIDGES", "AGENTD_PROJECTS", "AGENTD_SCAN_ROOTS", "AGENTD_BROWSE_ROOTS",
		"AGENTD_WORKTREES_ROOT", "AGENTD_DEV_INSECURE",
	} {
		t.Setenv(key, "")
	}
}

func useManagedServicePlatform(t *testing.T, goos string) {
	t.Helper()
	previous := managedServicePlatform
	managedServicePlatform = goos
	t.Cleanup(func() { managedServicePlatform = previous })
}

func writeMainTestCodex(t *testing.T, path string) {
	t.Helper()
	body := "#!/bin/sh\nif [ \"$1\" = \"app-server\" ] && [ \"$2\" = \"--help\" ]; then\n  printf '%s\\n' '--listen --ws-auth --ws-token-file'\nfi\nexit 0\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func assertMainTestPrivateToken(t *testing.T, path string, outerToken string) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("upstream token 必须是 0600 regular file：%v", info.Mode())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	token := strings.TrimSpace(string(raw))
	if len(token) != 64 || token == outerToken {
		t.Fatalf("upstream token 必须是独立的 32-byte hex，got=%q", token)
	}
}

func prepareBrewSideEffectProbe(t *testing.T) string {
	t.Helper()
	useManagedServicePlatform(t, "darwin")
	binDir := t.TempDir()
	marker := filepath.Join(t.TempDir(), "brew-called")
	brewPath := filepath.Join(binDir, "brew")
	brewBody := "#!/bin/sh\nprintf '%s\\n' called > \"$BREW_MARKER\"\nexit 0\n"
	if err := os.WriteFile(brewPath, []byte(brewBody), 0o755); err != nil {
		t.Fatal(err)
	}
	writeMainTestCodex(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", binDir)
	t.Setenv("BREW_MARKER", marker)
	return marker
}

func prepareManagedCommandProbe(t *testing.T, commandName string) string {
	t.Helper()
	binDir := t.TempDir()
	marker := filepath.Join(t.TempDir(), commandName+"-called")
	commandPath := filepath.Join(binDir, commandName)
	body := "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$MANAGED_COMMAND_MARKER\"\nexit 0\n"
	if err := os.WriteFile(commandPath, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	t.Setenv("MANAGED_COMMAND_MARKER", marker)
	return marker
}

func prepareDarwinLogCommandProbe(t *testing.T) (string, string) {
	t.Helper()
	binDir := t.TempDir()
	prefix := t.TempDir()
	logPath := filepath.Join(prefix, "var", "log", config.AppName+".log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logPath, []byte("ready\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(t.TempDir(), "tail-called")
	brewBody := "#!/bin/sh\nif [ \"$1\" = \"--prefix\" ]; then\n  printf '%s\\n' \"$TEST_BREW_PREFIX\"\nfi\nexit 0\n"
	tailBody := "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$MANAGED_COMMAND_MARKER\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(binDir, "brew"), []byte(brewBody), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "tail"), []byte(tailBody), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	t.Setenv("TEST_BREW_PREFIX", prefix)
	t.Setenv("MANAGED_COMMAND_MARKER", marker)
	return marker, logPath
}

func writeMainTestLinuxUnit(t *testing.T) string {
	t.Helper()
	configHome := filepath.Join(t.TempDir(), ".config")
	t.Setenv("XDG_CONFIG_HOME", configHome)
	unitPath := filepath.Join(configHome, "systemd", "user", managedServiceUnitName)
	if err := os.MkdirAll(filepath.Dir(unitPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(unitPath, []byte("[Service]\nExecStart=/bin/true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return unitPath
}

func assertCustomBrewConfigError(t *testing.T, err error, customPath string) {
	t.Helper()
	if err == nil {
		t.Fatal("自定义配置用于 Homebrew 后台命令时必须 fail-fast")
	}
	message := err.Error()
	for _, want := range []string{"后台服务不支持自定义配置", "agentd serve --config", customPath, shellQuoteArgument(customPath)} {
		if !strings.Contains(message, want) {
			t.Fatalf("错误应说明限制并给出可运行前台方案，缺少 %q：%v", want, err)
		}
	}
}

func assertPathDoesNotExist(t *testing.T, path string, message string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("%s：path=%s err=%v", message, path, err)
	}
}

type mainLegacyConfigFixture struct {
	destination string
	source      string
	upstream    string
	token       string
	raw         []byte
}

func prepareMainLegacyConfigFixture(t *testing.T) mainLegacyConfigFixture {
	t.Helper()
	clearAgentdEnvForMainTest(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	projectPath := filepath.Join(home, "code", "legacy-project")
	if err := os.MkdirAll(projectPath, 0o700); err != nil {
		t.Fatal(err)
	}
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeMainTestCodex(t, codexPath)

	source := config.LegacyDefaultPath()
	destination := config.PlatformDefaultPath()
	upstream := filepath.Join(filepath.Dir(source), "app-server-ws-token")
	worktreesRoot := filepath.Join(filepath.Dir(source), "worktrees")
	token := "legacy-command-token-never-rotate-0123456789"
	document := map[string]any{
		"listen": "127.0.0.1:8787",
		"auth":   map[string]any{"token": token},
		"runtime": map[string]any{
			"type": "codex_app_server",
		},
		"app_server": map[string]any{
			"transport": "ws", "managed": true, "listen": "ws://127.0.0.1:4222", "ws_token_file": upstream,
		},
		"codex": map[string]any{
			"bin": codexPath, "default_args": []string{"--no-alt-screen"},
		},
		"session":              map[string]any{"output_buffer_bytes": 131072},
		"projects":             []map[string]any{{"id": "legacy-project", "name": "Legacy Project", "path": projectPath}},
		"worktrees_root":       worktreesRoot,
		"future_unknown_field": map[string]any{"keep": true},
	}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	raw = append(raw, '\n')
	if err := os.MkdirAll(filepath.Dir(source), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(source, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(source, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(upstream, []byte("legacy-upstream-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return mainLegacyConfigFixture{destination: destination, source: source, upstream: upstream, token: token, raw: raw}
}

func assertMainLegacyConfigPreserved(t *testing.T, fixture mainLegacyConfigFixture) {
	t.Helper()
	for _, path := range []string{fixture.source, fixture.destination} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if string(raw) != string(fixture.raw) {
			t.Fatalf("迁移必须逐字节保留配置：path=%s", path)
		}
	}
	info, err := os.Lstat(fixture.destination)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("新版配置必须是 0600 普通文件：%v", info.Mode())
	}
	result, err := agentsetup.Pair(context.Background(), fixture.destination)
	if err != nil {
		t.Fatal(err)
	}
	if result.Token != fixture.token || result.AppServerTokenFile != fixture.upstream {
		t.Fatalf("迁移不得轮换 token 或改写旧 upstream 绝对路径：%+v", result)
	}
	upstreamRaw, err := os.ReadFile(fixture.upstream)
	if err != nil {
		t.Fatal(err)
	}
	if string(upstreamRaw) != "legacy-upstream-secret\n" {
		t.Fatalf("旧 upstream token 不得变化：%q", upstreamRaw)
	}
	assertPathDoesNotExist(t, filepath.Join(filepath.Dir(fixture.destination), "app-server-ws-token"), "不得擅自搬迁旧 upstream token")
}

func captureMainCommandOutput(t *testing.T, action func() error) (string, string, error) {
	t.Helper()
	stdoutFile, err := os.CreateTemp(t.TempDir(), "stdout-")
	if err != nil {
		t.Fatal(err)
	}
	stderrFile, err := os.CreateTemp(t.TempDir(), "stderr-")
	if err != nil {
		t.Fatal(err)
	}
	previousStdout, previousStderr := os.Stdout, os.Stderr
	actionErr := func() (err error) {
		os.Stdout, os.Stderr = stdoutFile, stderrFile
		defer func() {
			os.Stdout, os.Stderr = previousStdout, previousStderr
		}()
		return action()
	}()
	if err := stdoutFile.Close(); err != nil {
		t.Fatal(err)
	}
	if err := stderrFile.Close(); err != nil {
		t.Fatal(err)
	}
	stdout, err := os.ReadFile(stdoutFile.Name())
	if err != nil {
		t.Fatal(err)
	}
	stderr, err := os.ReadFile(stderrFile.Name())
	if err != nil {
		t.Fatal(err)
	}
	return string(stdout), string(stderr), actionErr
}

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/user"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync/atomic"
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

func TestEnsureProcessUserEnvironmentRestoresLaunchdHome(t *testing.T) {
	current, err := user.Current()
	if err != nil || strings.TrimSpace(current.HomeDir) == "" {
		t.Skip("当前测试环境无法解析系统用户 Home")
	}
	t.Setenv("HOME", "")
	t.Setenv("USER", "")
	t.Setenv("LOGNAME", "")

	if err := ensureProcessUserEnvironment(); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("HOME") != current.HomeDir {
		t.Fatalf("应从系统用户恢复 HOME：want=%q got=%q", current.HomeDir, os.Getenv("HOME"))
	}
	if strings.TrimSpace(current.Username) != "" {
		if os.Getenv("USER") != current.Username || os.Getenv("LOGNAME") != current.Username {
			t.Fatalf("应补齐 USER/LOGNAME：user=%q logname=%q", os.Getenv("USER"), os.Getenv("LOGNAME"))
		}
	}
}

func TestLoadInstallationIDForServeIsStableAndFailsClosed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("APPDATA", filepath.Join(home, "AppData", "Roaming"))
	t.Setenv("LOCALAPPDATA", filepath.Join(home, "AppData", "Local"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))

	first, err := loadInstallationIDForServe()
	if err != nil {
		t.Fatal(err)
	}
	second, err := loadInstallationIDForServe()
	if err != nil {
		t.Fatal(err)
	}
	if first == "" || second != first {
		t.Fatalf("serve 必须复用稳定安装身份：first=%q second=%q", first, second)
	}

	configDir, err := config.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	identityPath := filepath.Join(configDir, "installation-id")
	if err := os.WriteFile(identityPath, []byte("damaged\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadInstallationIDForServe(); err == nil || !strings.Contains(err.Error(), "加载 agentd 安装身份失败") {
		t.Fatalf("损坏身份必须阻止 serve 启动：%v", err)
	}
	raw, err := os.ReadFile(identityPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "damaged\n" {
		t.Fatalf("serve 不能静默替换损坏身份：%q", raw)
	}
}

func TestRestartNoPairDoesNotPrintLongLivedCredentials(t *testing.T) {
	fixture := prepareMainLegacyConfigFixture(t)
	prepareBrewSideEffectProbe(t)
	stdout, stderr, err := captureMainCommandOutput(t, func() error {
		return run([]string{"agentd", "restart", "--wait", "0", "--no-pair"})
	})
	if err != nil {
		t.Fatalf("restart --no-pair 失败：%v stderr=%s", err, stderr)
	}
	if !strings.Contains(stdout, "正在重启 Mimi Remote 助手") {
		t.Fatalf("安全重启仍应输出进度：%q", stdout)
	}
	for _, forbidden := range []string{fixture.token, "Token：", "访问码：", "用 iPad 扫这个二维码"} {
		if strings.Contains(stdout, forbidden) || strings.Contains(stderr, forbidden) {
			t.Fatalf("restart --no-pair 泄漏长期凭据或二维码 %q：stdout=%q stderr=%q", forbidden, stdout, stderr)
		}
	}
}

func TestStartNoPairDoesNotPrintLongLivedCredentials(t *testing.T) {
	fixture := prepareMainLegacyConfigFixture(t)
	prepareBrewSideEffectProbe(t)
	stdout, stderr, err := captureMainCommandOutput(t, func() error {
		return run([]string{"agentd", "start", "--wait", "0", "--no-pair"})
	})
	if err != nil {
		t.Fatalf("start --no-pair 失败：%v stderr=%s", err, stderr)
	}
	if !strings.Contains(stdout, "正在启动 Mimi Remote 后台服务") {
		t.Fatalf("安全启动仍应输出进度：%q", stdout)
	}
	for _, forbidden := range []string{fixture.token, "Token：", "访问码：", "用 iPad 扫这个二维码"} {
		if strings.Contains(stdout, forbidden) || strings.Contains(stderr, forbidden) {
			t.Fatalf("start --no-pair 泄漏长期凭据或二维码 %q：stdout=%q stderr=%q", forbidden, stdout, stderr)
		}
	}
}

func TestUpNoPairDoesNotPrintConnectionCredentials(t *testing.T) {
	fixture := prepareMainLegacyConfigFixture(t)
	prepareBrewSideEffectProbe(t)
	stdout, stderr, err := captureMainCommandOutput(t, func() error {
		return run([]string{"agentd", "up", "--wait", "0", "--no-pair"})
	})
	if err != nil {
		t.Fatalf("up --no-pair 失败：%v stderr=%s", err, stderr)
	}
	if !strings.Contains(stdout, "正在准备 Mimi Remote 助手") || !strings.Contains(stdout, "常用命令") {
		t.Fatalf("安全启动仍应输出进度和后续命令：%q", stdout)
	}
	for _, forbidden := range []string{
		fixture.token,
		"127.0.0.1:8787",
		"Token：",
		"访问码：",
		"mimiremote://",
		"用 iPad 扫这个二维码",
	} {
		if strings.Contains(stdout, forbidden) || strings.Contains(stderr, forbidden) {
			t.Fatalf("up --no-pair 泄漏连接信息 %q：stdout=%q stderr=%q", forbidden, stdout, stderr)
		}
	}
}

func TestUpNoPairJSONOmitsSetupResult(t *testing.T) {
	fixture := prepareMainLegacyConfigFixture(t)
	prepareBrewSideEffectProbe(t)
	stdout, stderr, err := captureMainCommandOutput(t, func() error {
		return run([]string{"agentd", "up", "--wait", "0", "--no-pair", "--json"})
	})
	if err != nil {
		t.Fatalf("up --no-pair --json 失败：%v stderr=%s", err, stderr)
	}

	var output map[string]any
	if err := json.Unmarshal([]byte(stdout), &output); err != nil {
		t.Fatalf("安全启动 JSON 无法解析：%v output=%q", err, stdout)
	}
	if output["service_ok"] != true || output["version"] != version {
		t.Fatalf("安全启动 JSON 缺少非敏感状态：%+v", output)
	}
	for _, forbiddenKey := range []string{"result", "token", "endpoint", "connect_url", "pair_url", "config_path"} {
		if _, exists := output[forbiddenKey]; exists {
			t.Fatalf("安全启动 JSON 不应包含 %q：%+v", forbiddenKey, output)
		}
	}
	for _, forbiddenValue := range []string{fixture.token, "127.0.0.1:8787", "mimiremote://"} {
		if strings.Contains(stdout, forbiddenValue) || strings.Contains(stderr, forbiddenValue) {
			t.Fatalf("安全启动 JSON 泄漏连接信息 %q：stdout=%q stderr=%q", forbiddenValue, stdout, stderr)
		}
	}
}

func TestUpNoPairJSONRedactsConnectionDetailsFromServiceError(t *testing.T) {
	result := agentsetup.Result{
		Endpoint:   "http://100.64.0.8:8787",
		Token:      "long-lived-token",
		ConnectURL: "mimiremote://connect?endpoint=http%3A%2F%2F100.64.0.8%3A8787&token=long-lived-token",
		PairURL:    "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.8%3A8787&pair_sig=short-ticket",
	}
	result.Warnings = []string{"连接警告：" + result.Endpoint + " " + result.Token}
	serviceError := strings.Join([]string{
		result.Endpoint,
		result.Token,
		result.ConnectURL,
		result.PairURL,
	}, " ")

	output := upJSONOutput(result, false, serviceError, true)
	raw, err := json.Marshal(output)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{result.Endpoint, result.Token, result.ConnectURL, result.PairURL, "100.64.0.8"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("安全启动错误泄漏连接信息 %q：%s", forbidden, raw)
		}
	}
	redactedError, _ := output["service_error"].(string)
	if !strings.Contains(redactedError, "<redacted>") {
		t.Fatalf("安全启动错误应明确标记去敏内容：%s", raw)
	}
}

func TestAgentDListenAddressesAddsLoopbackForSpecificRemoteBind(t *testing.T) {
	tests := []struct {
		name       string
		configured string
		allowLAN   bool
		want       []string
	}{
		{name: "Tailscale IPv4", configured: "100.127.16.9:8787", want: []string{"100.127.16.9:8787", "127.0.0.1:8787"}},
		{name: "LAN IPv4", configured: "192.168.31.10:9000", want: []string{"192.168.31.10:9000", "127.0.0.1:9000"}},
		{name: "loopback", configured: "127.0.0.1:8787", want: []string{"127.0.0.1:8787"}},
		{name: "localhost", configured: "localhost:8787", want: []string{"localhost:8787"}},
		{name: "IPv4 wildcard", configured: "0.0.0.0:8787", want: []string{"0.0.0.0:8787"}},
		{name: "IPv6 wildcard", configured: "[::]:8787", want: []string{"[::]:8787"}},
		{name: "invalid keeps original", configured: "bad-address", want: []string{"bad-address"}},
		{
			name:       "explicit LAN access uses IPv4 wildcard",
			configured: "100.127.16.9:8787",
			allowLAN:   true,
			want:       []string{"0.0.0.0:8787"},
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			if got := agentDListenAddresses(testCase.configured, testCase.allowLAN); !reflect.DeepEqual(got, testCase.want) {
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

func TestRunSetupQROnlyNeverReturnsLongLivedCredentials(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	installMainTestSSH(t)
	root := t.TempDir()
	configPath := filepath.Join(root, "config.json")
	workspace := filepath.Join(root, "code")
	if err := os.Mkdir(workspace, 0o700); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr strings.Builder
	err := runSetupWithWriters([]string{
		"setup",
		"--config", configPath,
		"--scan-root", workspace,
		"--browse-root", workspace,
		"--listen", "127.0.0.1:8787",
		"--json",
		"--qr-only",
	}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("setup --qr-only 失败：%v stderr=%s", err, stderr.String())
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout.String()), &payload); err != nil {
		t.Fatalf("setup 安全 JSON 无法解析：%v output=%s", err, stdout.String())
	}
	for _, key := range []string{"endpoint", "pair_url", "pair_expires_at"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("setup 安全 JSON 缺少 %s：%v", key, payload)
		}
	}
	for _, forbiddenKey := range []string{"token", "connect_url", "app_server_token_file"} {
		if _, ok := payload[forbiddenKey]; ok {
			t.Fatalf("setup 安全 JSON 不应包含 %s：%v", forbiddenKey, payload)
		}
	}
	rawConfig, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var stored config.Config
	if err := json.Unmarshal(rawConfig, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Auth.Token == "" {
		t.Fatal("setup 必须仍在私有配置中生成长期 Token")
	}
	if strings.Contains(stdout.String(), stored.Auth.Token) {
		t.Fatal("setup 安全输出泄漏了长期 Token")
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
	if runtime.GOOS == "windows" {
		t.Skip("POSIX service command shims are exercised on their native CI runners")
	}
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
			name:        "mac restart is one launchd operation",
			goos:        "darwin",
			commandName: "launchctl",
			action:      "restart",
			wantArgs:    fmt.Sprintf("kickstart -k gui/%d/homebrew.mxcl.mimi-remote", os.Getuid()),
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

func TestDarwinRestartFallsBackToBrewStartWhenServiceIsNotLoaded(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX launchctl shim is exercised on macOS")
	}
	binDir := t.TempDir()
	launchctlMarker := filepath.Join(t.TempDir(), "launchctl-called")
	brewMarker := filepath.Join(t.TempDir(), "brew-called")
	launchctlBody := "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$LAUNCHCTL_MARKER\"\nprintf '%s\\n' 'Could not find service' >&2\nexit 1\n"
	brewBody := "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$BREW_MARKER\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(binDir, "launchctl"), []byte(launchctlBody), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "brew"), []byte(brewBody), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	t.Setenv("LAUNCHCTL_MARKER", launchctlMarker)
	t.Setenv("BREW_MARKER", brewMarker)

	var stdout, stderr strings.Builder
	if err := runManagedServiceForPlatform("darwin", "restart", &stdout, &stderr); err != nil {
		t.Fatalf("未加载的 Homebrew 服务应回退到 start：%v", err)
	}
	launchctlRaw, err := os.ReadFile(launchctlMarker)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(launchctlRaw)); got != fmt.Sprintf("kickstart -k gui/%d/homebrew.mxcl.mimi-remote", os.Getuid()) {
		t.Fatalf("必须先尝试 launchd 原子重启：%q", got)
	}
	brewRaw, err := os.ReadFile(brewMarker)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(brewRaw)); got != "services start mimi-remote" {
		t.Fatalf("回退只能启动服务，不能再执行非原子的 restart：%q", got)
	}
	if !strings.Contains(stderr.String(), "当前未加载") {
		t.Fatalf("回退时应明确说明服务状态：%q", stderr.String())
	}
}

func TestDarwinRestartDoesNotHideAtomicKickstartFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX launchctl shim is exercised on macOS")
	}
	binDir := t.TempDir()
	brewMarker := filepath.Join(t.TempDir(), "brew-called")
	launchctlBody := "#!/bin/sh\nprintf '%s\\n' 'Operation not permitted' >&2\nexit 1\n"
	brewBody := "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$BREW_MARKER\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(binDir, "launchctl"), []byte(launchctlBody), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "brew"), []byte(brewBody), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	t.Setenv("BREW_MARKER", brewMarker)

	err := runManagedServiceForPlatform("darwin", "restart", io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "Operation not permitted") {
		t.Fatalf("非服务缺失错误必须原样失败：%v", err)
	}
	assertPathDoesNotExist(t, brewMarker, "原子 kickstart 失败时不能用 start 掩盖真实错误")
}

func TestManagedLogsLinuxUsesJournalctlAndFollow(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX journalctl shim is exercised on Linux")
	}
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
	if runtime.GOOS == "windows" {
		t.Skip("POSIX tail shim is exercised on macOS")
	}
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
		func() error { return runManagedServiceForPlatform("freebsd", "start", &stdout, &stderr) },
		func() error { return runManagedLogsForPlatform("freebsd", 10, false, &stdout, &stderr) },
	} {
		err := action()
		if err == nil || !strings.Contains(err.Error(), "不支持后台服务命令") || !strings.Contains(err.Error(), "agentd serve") {
			t.Fatalf("不支持的平台必须给出前台运行提示：%v", err)
		}
	}
}

func TestStopDispatchUsesDarwinServiceWithNeutralOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX brew shim is exercised on macOS")
	}
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
	for _, want := range []string{"正在停止 Mimi Remote 助手", "Mimi Remote 助手已停止"} {
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
	if runtime.GOOS == "windows" {
		t.Skip("POSIX systemctl shim is exercised on Linux")
	}
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
	clearAgentdEnvForMainTest(t)
	installMainTestSSH(t)
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
		name        string
		migratesSSH bool
		run         func(t *testing.T, fixture mainLegacyConfigFixture) error
	}{
		{
			name:        "brew serve config load",
			migratesSSH: true,
			run: func(t *testing.T, fixture mainLegacyConfigFixture) error {
				cfg, _, _, err := loadRuntimeConfig([]string{"agentd"}, false)
				if err == nil && cfg.Auth.Token != fixture.token {
					t.Fatalf("serve 必须复用旧 token：got=%q", cfg.Auth.Token)
				}
				return err
			},
		},
		{name: "setup", migratesSSH: true, run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			return run([]string{"agentd", "setup", "--json"})
		}},
		{name: "up", migratesSSH: true, run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			prepareBrewSideEffectProbe(t)
			return run([]string{"agentd", "up", "--wait", "0", "--json"})
		}},
		{name: "start", migratesSSH: true, run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			prepareBrewSideEffectProbe(t)
			return run([]string{"agentd", "start", "--wait", "0"})
		}},
		{name: "restart", migratesSSH: true, run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			prepareBrewSideEffectProbe(t)
			return run([]string{"agentd", "restart", "--wait", "0"})
		}},
		{name: "status", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			if runtime.GOOS == "windows" {
				installFakeWindowsCommands(t)
			}
			return run([]string{"agentd", "status", "--json"})
		}},
		{name: "pair", run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			return run([]string{"agentd", "pair", "--json"})
		}},
		{name: "doctor", migratesSSH: true, run: func(t *testing.T, _ mainLegacyConfigFixture) error {
			return run([]string{"agentd", "doctor", "--fix", "--json"})
		}},
	}

	for _, testCase := range commands {
		t.Run(testCase.name, func(t *testing.T) {
			fixture := prepareMainLegacyConfigFixture(t)
			stdout, stderr, err := captureMainCommandOutput(t, func() error {
				return testCase.run(t, fixture)
			})
			if err != nil {
				t.Fatalf("默认路径命令应直接复用迁移配置：%v stdout=%s stderr=%s", err, stdout, stderr)
			}
			if count := strings.Count(stderr, "已复用旧版配置并迁移到新目录"); count != 1 {
				t.Fatalf("成功迁移只应提示一次：count=%d stderr=%q", count, stderr)
			}
			if strings.Contains(stderr, fixture.token) || strings.Contains(stderr, "legacy-upstream-secret") {
				t.Fatalf("迁移提示不得把 token 写入日志：%q", stderr)
			}
			assertMainLegacyConfigPreserved(t, fixture, testCase.migratesSSH)
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
		{name: "signal", signal: os.Interrupt},
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
			if testCase.readyVersion != "" &&
				testCase.clientToken == serverToken &&
				fields["server_version"] != testCase.readyVersion {
				t.Fatalf("status 必须保留 Endpoint 的真实服务版本：%v", fields)
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

func TestStatusRuntimeEnrichmentRequiresJSON(t *testing.T) {
	err := runStatus([]string{"status", "--runtime"})
	if err == nil || !strings.Contains(err.Error(), "--json") {
		t.Fatalf("status --runtime 必须拒绝无 JSON 的调用：%v", err)
	}
}

func TestStatusRuntimeRefreshRequiresRuntimeJSON(t *testing.T) {
	err := runStatus([]string{"status", "--json", "--runtime-refresh"})
	if err == nil || !strings.Contains(err.Error(), "--runtime --json") {
		t.Fatalf("status --runtime-refresh 必须要求 --runtime --json：%v", err)
	}
}

func TestAttachRuntimeStatusPropagatesOnlyForcedRefreshFailure(t *testing.T) {
	status := map[string]any{"version": "1.2.3"}
	fetchErr := errors.New("runtime status HTTP 500")
	if err := attachRuntimeStatus(status, runtimeStatusResult{err: fetchErr}, false); err != nil {
		t.Fatalf("cached runtime enrichment must remain compatible with an old service: %v", err)
	}
	if _, exists := status["runtime_status"]; exists {
		t.Fatalf("failed cached enrichment must not attach an empty runtime status: %v", status)
	}
	if err := attachRuntimeStatus(status, runtimeStatusResult{err: fetchErr}, true); err == nil ||
		!strings.Contains(err.Error(), "强制刷新运行时状态失败") {
		t.Fatalf("forced refresh failure must reach the tray as a non-zero error: %v", err)
	}

	payload := map[string]any{"runtimes": []any{}}
	if err := attachRuntimeStatus(status, runtimeStatusResult{payload: payload}, true); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(status["runtime_status"], payload) {
		t.Fatalf("successful runtime status was not attached: %v", status)
	}
}

func TestStatusNetworkPolicyInspectionRequiresJSON(t *testing.T) {
	err := runStatus([]string{"status", "--network-policy"})
	if err == nil || !strings.Contains(err.Error(), "--json") {
		t.Fatalf("status --network-policy 必须拒绝无 JSON 的调用：%v", err)
	}
}

func TestStatusOnlyRequestsRuntimeWhenExplicitlyEnabled(t *testing.T) {
	if runtime.GOOS == "windows" {
		installFakeWindowsCommands(t)
	}
	clearAgentdEnvForMainTest(t)
	const token = "status-runtime-opt-in-token-0123456789"
	var runtimeRequests atomic.Int32
	var runtimeRefreshRequests atomic.Int32
	var runtimeFailure atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/healthz":
			w.WriteHeader(http.StatusOK)
		case "/api/readyz":
			if req.Header.Get("Authorization") != "Bearer "+token {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(doctor.Results{
				OK: true, Version: version, Checks: []doctor.Check{},
			})
		case "/api/runtime/status":
			runtimeRequests.Add(1)
			if req.URL.Query().Get("refresh") == "wait" {
				runtimeRefreshRequests.Add(1)
			}
			if req.Header.Get("Authorization") != "Bearer "+token {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			switch runtimeFailure.Load() {
			case 1:
				w.WriteHeader(http.StatusNotFound)
				return
			case 2:
				w.WriteHeader(http.StatusInternalServerError)
				return
			case 3:
				_, _ = w.Write([]byte(`{"runtimes":`))
				return
			}
			_, _ = w.Write([]byte(`{"refreshing":false,"stale":false,"runtimes":[]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	root := t.TempDir()
	configPath := filepath.Join(root, "config.json")
	upstreamTokenPath := filepath.Join(root, "app-server-token")
	projectPath := filepath.Join(root, "project")
	if err := os.Mkdir(projectPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(upstreamTokenPath, []byte("upstream-token"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		Listen: strings.TrimPrefix(server.URL, "http://"),
		Auth:   config.AuthConfig{Token: token},
		Runtime: config.RuntimeConfig{
			Type: "codex_app_server",
		},
		AppServer: config.AppServerConfig{
			Transport: "ssh",
			SSHTarget: "127.0.0.1",
		},
		Codex: config.CodexConfig{Bin: "/bin/true"},
		Session: config.SessionConfig{
			OutputBufferBytes: 128 * 1024,
		},
		Projects: []config.ProjectConfig{{
			ID: "test", Name: "Test", Path: projectPath,
		}},
		WorktreesRoot: filepath.Join(root, "worktrees"),
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	statusOutput, _, err := captureMainCommandOutput(t, func() error {
		return runStatus([]string{"status", "--config", configPath, "--json"})
	})
	if err != nil {
		t.Fatalf("core status 失败：%v", err)
	}
	if runtimeRequests.Load() != 0 {
		t.Fatalf("默认 status --json 不得触发额度探测：requests=%d", runtimeRequests.Load())
	}
	var statusPayload struct {
		NetworkStatus agentNetworkStatus `json:"network_status"`
	}
	if err := json.Unmarshal([]byte(statusOutput), &statusPayload); err != nil {
		t.Fatalf("status JSON 无法解析：%v\n%s", err, statusOutput)
	}
	if statusPayload.NetworkStatus.Mode != "loopback" ||
		statusPayload.NetworkStatus.AllowLAN ||
		statusPayload.NetworkStatus.PolicyChecked {
		t.Fatalf("默认 status 应快速返回配置网络模式且不做昂贵策略检查：%+v", statusPayload.NetworkStatus)
	}

	if _, _, err := captureMainCommandOutput(t, func() error {
		return runStatus([]string{"status", "--config", configPath, "--json", "--runtime"})
	}); err != nil {
		t.Fatalf("runtime-enriched status 失败：%v", err)
	}
	if runtimeRequests.Load() != 1 {
		t.Fatalf("显式 --runtime 应只请求一次缓存接口：requests=%d", runtimeRequests.Load())
	}
	if runtimeRefreshRequests.Load() != 0 {
		t.Fatalf("普通 --runtime 不得强制刷新：requests=%d", runtimeRefreshRequests.Load())
	}
	if _, _, err := captureMainCommandOutput(t, func() error {
		return runStatus([]string{"status", "--config", configPath, "--json", "--runtime", "--runtime-refresh"})
	}); err != nil {
		t.Fatalf("runtime force-refresh status 失败：%v", err)
	}
	if runtimeRequests.Load() != 2 || runtimeRefreshRequests.Load() != 1 {
		t.Fatalf("--runtime-refresh 必须只请求一次强制刷新接口：requests=%d refresh=%d", runtimeRequests.Load(), runtimeRefreshRequests.Load())
	}
	for mode, want := range map[int32]string{1: "HTTP 404", 2: "HTTP 500", 3: "不是有效 JSON"} {
		runtimeFailure.Store(mode)
		if _, _, err := captureMainCommandOutput(t, func() error {
			return runStatus([]string{"status", "--config", configPath, "--json", "--runtime", "--runtime-refresh"})
		}); err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("forced runtime failure mode %d = %v, want substring %q", mode, err, want)
		}
	}
}

func TestFetchServiceRuntimeStatusUsesBearerAndStrictJSON(t *testing.T) {
	const token = "runtime-status-secret"
	var requests atomic.Int32
	var refreshRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		requests.Add(1)
		if req.URL.Path != "/api/runtime/status" {
			t.Errorf("runtime status 路径错误：%s", req.URL.Path)
		}
		if req.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if req.URL.Query().Get("refresh") == "wait" {
			refreshRequests.Add(1)
		}
		_, _ = w.Write([]byte(`{"checked_at":"2026-07-27T12:00:00Z","runtimes":[{"id":"codex","title":"Codex","enabled":true,"state":"connected"}]}`))
	}))
	defer server.Close()

	payload, err := fetchServiceRuntimeStatus(context.Background(), server.URL, token, time.Second, false)
	if err != nil {
		t.Fatal(err)
	}
	if payload["checked_at"] != "2026-07-27T12:00:00Z" {
		t.Fatalf("runtime status payload 异常：%v", payload)
	}
	if requests.Load() != 1 {
		t.Fatalf("runtime status 应只请求一次：requests=%d", requests.Load())
	}
	if _, err := fetchServiceRuntimeStatus(context.Background(), server.URL, token, time.Second, true); err != nil {
		t.Fatal(err)
	}
	if refreshRequests.Load() != 1 {
		t.Fatalf("强制刷新必须请求 refresh=wait：requests=%d", refreshRequests.Load())
	}

	if _, err := fetchServiceRuntimeStatus(context.Background(), server.URL, "wrong-token", time.Second, false); err == nil ||
		!strings.Contains(err.Error(), "HTTP 401") {
		t.Fatalf("runtime status 必须使用 Bearer Token：%v", err)
	}
}

func TestFetchServiceRuntimeStatusReportsRefreshFailures(t *testing.T) {
	tests := []struct {
		name    string
		handler http.HandlerFunc
		want    string
		timeout time.Duration
	}{
		{name: "old endpoint", handler: func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNotFound)
		}, want: "HTTP 404", timeout: time.Second},
		{name: "server error", handler: func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
		}, want: "HTTP 500", timeout: time.Second},
		{name: "malformed JSON", handler: func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"runtimes":`))
		}, want: "不是有效 JSON", timeout: time.Second},
		{name: "timeout", handler: func(w http.ResponseWriter, req *http.Request) {
			<-req.Context().Done()
		}, want: "deadline exceeded", timeout: 20 * time.Millisecond},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(test.handler)
			defer server.Close()
			_, err := fetchServiceRuntimeStatus(context.Background(), server.URL, "", test.timeout, true)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("refresh failure = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestFetchServiceRuntimeStatusRejectsTrailingJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(`{"runtimes":[]} {"unexpected":true}`))
	}))
	defer server.Close()

	if _, err := fetchServiceRuntimeStatus(context.Background(), server.URL, "", time.Second, false); err == nil ||
		!strings.Contains(err.Error(), "多个 JSON 值") {
		t.Fatalf("runtime status 必须拒绝尾随 JSON：%v", err)
	}
}

func TestFetchServiceRuntimeStatusRejectsMissingRequiredShape(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(`{}`))
	}))
	defer server.Close()

	if _, err := fetchServiceRuntimeStatus(context.Background(), server.URL, "", time.Second, false); err == nil ||
		!strings.Contains(err.Error(), "缺少 runtimes") {
		t.Fatalf("runtime status 必须拒绝缺少最小结构的 200 响应：%v", err)
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

func TestWaitForServiceReadyResultsUsesBearerAndDoesNotRequestDoctor(t *testing.T) {
	const token = "ready-service-token"
	var doctorRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == "/api/doctor" {
			doctorRequests.Add(1)
			http.Error(w, "status 不应请求完整 doctor", http.StatusInternalServerError)
			return
		}
		if req.URL.Path != "/api/readyz" {
			t.Errorf("服务端 readiness 路径错误：%s", req.URL.Path)
		}
		if req.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(doctor.Results{
			OK:      true,
			Version: "1.2.3",
			Checks: []doctor.Check{{
				Name:    "app-server-upstream",
				OK:      true,
				Level:   "ok",
				Message: "upstream 可用",
			}},
		})
	}))
	defer server.Close()

	results, err := waitForServiceReadyResults(context.Background(), server.URL, token, "1.2.3", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(results.Checks) != 1 || results.Checks[0].Name != "app-server-upstream" {
		t.Fatalf("status 必须直接复用 readyz 结果：%+v", results)
	}
	if doctorRequests.Load() != 0 {
		t.Fatalf("status 不应触发完整 doctor：requests=%d", doctorRequests.Load())
	}
	if _, err := waitForServiceReadyResults(context.Background(), server.URL, "wrong-token", "1.2.3", time.Nanosecond); err == nil {
		t.Fatal("服务端 readiness 必须使用外侧 Bearer Token")
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
	for _, want := range []string{"1.2.2", "1.2.3", "agentd restart", "agentd logs"} {
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

	for _, clientVersion := range []string{"devel", "devel-e6049e97bd9d"} {
		if err := waitForServiceReady(context.Background(), server.URL, "token", clientVersion, time.Second); err != nil {
			t.Fatalf("开发版本 %q 不应误伤本地测试服务：%v", clientVersion, err)
		}
	}
}

func TestAgentVersionsKeepMacBuildStrictButAllowReleaseCLI(t *testing.T) {
	tests := []struct {
		expected string
		running  string
		want     bool
	}{
		{expected: "0.1.5", running: "0.1.5+mac.240", want: true},
		{expected: "0.1.5+mac.240", running: "0.1.5+mac.240", want: true},
		{expected: "0.1.5+mac.240", running: "0.1.5+mac.239", want: false},
		{expected: "0.1.6", running: "0.1.5+mac.240", want: false},
	}
	for _, testCase := range tests {
		if got := agentVersionsCompatible(testCase.expected, testCase.running); got != testCase.want {
			t.Fatalf(
				"agentd 版本兼容判断错误：expected=%q running=%q got=%v want=%v",
				testCase.expected,
				testCase.running,
				got,
				testCase.want,
			)
		}
	}
}

func TestLoopbackServiceEndpointPreservesSchemePortAndPath(t *testing.T) {
	tests := []struct {
		name     string
		endpoint string
		want     string
	}{
		{
			name:     "tailscale ipv4",
			endpoint: "http://100.127.16.9:8787",
			want:     "http://127.0.0.1:8787",
		},
		{
			name:     "lan with path",
			endpoint: "https://192.168.31.20:9443/base?source=status",
			want:     "https://127.0.0.1:9443/base?source=status",
		},
		{
			name:     "invalid endpoint unchanged",
			endpoint: "not-an-endpoint",
			want:     "not-an-endpoint",
		},
		{
			name:     "missing port unchanged",
			endpoint: "http://100.127.16.9",
			want:     "http://100.127.16.9",
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			if got := loopbackServiceEndpoint(testCase.endpoint); got != testCase.want {
				t.Fatalf("loopback Endpoint 错误：got=%q want=%q", got, testCase.want)
			}
		})
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
	projectPath := filepath.Join(dir, "project")
	if err := os.Mkdir(projectPath, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		Listen:  "127.0.0.1:8787",
		Auth:    config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime: config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{
			Transport: "ssh",
			SSHTarget: "127.0.0.1",
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
	}}
	fixes, restartRequired, _, _, err := runDoctorFix(context.Background(), configPath, false, current)
	if err != nil {
		t.Fatalf("doctor --fix 收紧权限失败：%v", err)
	}
	if runtime.GOOS != "windows" && len(fixes) != 1 {
		t.Fatalf("应修复配置文件权限：%v", fixes)
	}
	if restartRequired {
		t.Fatal("只收紧文件权限不应要求重启 agentd")
	}
	for _, path := range []string{configPath} {
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
			t.Fatalf("%s 权限应为 0600，实际 %04o", path, info.Mode().Perm())
		}
	}
}

func TestDoctorFixMigratesLegacyManagedWSWithoutReplacingUserConfig(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	installMainTestSSH(t)
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
	codexPath = writeMainTestCodex(t, codexPath)
	const authToken = "0123456789abcdef0123456789abcdef"
	legacyUpstreamToken := filepath.Join(dir, "legacy-upstream-token")
	if err := os.WriteFile(legacyUpstreamToken, []byte("legacy-capability-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	// 只有旧版受管 WS 配置可以无损自动迁移；stdio 等用户配置必须拒绝自动改写。
	legacy := map[string]any{
		"listen": "127.0.0.1:8787",
		"auth": map[string]any{
			"token":             authToken,
			"allow_query_token": true,
		},
		"runtime": map[string]any{"type": "codex_app_server"},
		"app_server": map[string]any{
			"transport":     "ws",
			"managed":       true,
			"listen":        "ws://127.0.0.1:4222",
			"ws_token_file": legacyUpstreamToken,
			"future_option": "keep-app-server-option",
		},
		"voice": map[string]any{
			"codex_transcription_base_url": "https://chatgpt.example.test/backend-api",
			"codex_auth_file":              filepath.Join(dir, "custom-codex-auth.json"),
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
	if runtime.GOOS == "windows" {
		if !bytes.Equal(updated, append(original, '\n')) {
			t.Fatalf("Windows 应继续使用原有受管 WS 配置：\nwant=%s\n got=%s", original, updated)
		}
		loaded, loadErr := config.Load(configPath)
		if loadErr != nil || loaded.AppServer.Transport != "ws" || !loaded.AppServer.Managed {
			t.Fatalf("Windows 受管 WS 配置必须保持可加载：cfg=%+v err=%v", loaded.AppServer, loadErr)
		}
		return
	}
	if afterAppServer["transport"] != "ssh" || afterAppServer["ssh_target"] != "127.0.0.1" {
		t.Fatalf("doctor --fix 应迁移为默认共享 SSH 配置：%+v", afterAppServer)
	}
	var before map[string]any
	if err := json.Unmarshal(original, &before); err != nil {
		t.Fatal(err)
	}
	beforeAppServer := before["app_server"].(map[string]any)
	delete(beforeAppServer, "managed")
	delete(beforeAppServer, "listen")
	delete(beforeAppServer, "ws_token_file")
	beforeAppServer["transport"] = "ssh"
	beforeAppServer["ssh_target"] = "127.0.0.1"
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("doctor --fix 只能改写旧 WS 迁移所需字段：\nwant=%+v\n got=%+v", before, after)
	}
	configInfo, err := os.Lstat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !configInfo.Mode().IsRegular() || (runtime.GOOS != "windows" && configInfo.Mode().Perm() != 0o600) {
		t.Fatalf("原子更新后的配置必须是 0600 regular file：%v", configInfo.Mode())
	}
	migrated, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if migrated.Runtime.Type != "codex_app_server" || migrated.AppServer.Transport != "ssh" || migrated.AppServer.SSHTarget == "" {
		t.Fatalf("配置必须迁移为共享 SSH：%+v %+v", migrated.Runtime, migrated.AppServer)
	}
	if migrated.Auth.Token != authToken || len(migrated.Actions) != 1 || len(migrated.BrowseRoots) != 1 {
		t.Fatalf("修复后业务配置必须保留：%+v", migrated)
	}
}

func TestRunDoctorFixMissingConfigStillUsesFullSetup(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	installMainTestSSH(t)
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

	fixes, restartRequired, _, _, err := runDoctorFix(context.Background(), configPath, false, current)
	if err != nil {
		t.Fatalf("配置完全缺失时仍应走完整 setup，而不是尝试局部迁移：%v", err)
	}
	if len(fixes) == 0 {
		t.Fatal("完整 setup 应返回修复记录")
	}
	if !restartRequired {
		t.Fatal("完整 setup 重建配置后必须要求重启 agentd")
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.Token == "" {
		t.Fatalf("完整 setup 应生成外侧 token：%+v", cfg)
	}
	if runtime.GOOS == "windows" {
		if cfg.AppServer.Transport != "ws" || !cfg.AppServer.Managed || cfg.AppServer.Listen == "" {
			t.Fatalf("Windows 完整 setup 应生成受管 WS 配置：%+v", cfg.AppServer)
		}
	} else if cfg.AppServer.SSHTarget == "" {
		t.Fatalf("完整 setup 应生成 SSH target：%+v", cfg)
	}
}

func TestRunDoctorFixRejectsLegacyResidueBeforeAnyMutation(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	original := []byte("{\"auth\":{\"token\":\"keep-token-0123456789\"}}\n")
	if err := os.WriteFile(configPath, original, 0o644); err != nil {
		t.Fatal(err)
	}
	beforeInfo, err := os.Stat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	current := doctor.Results{Checks: []doctor.Check{
		{Name: "legacy-codex-experiment", OK: false},
		{Name: "config-file", OK: false},
		{Name: "app-server-token-file", OK: false},
	}}

	_, _, _, _, err = runDoctorFix(context.Background(), configPath, false, current)
	if err == nil || !strings.Contains(err.Error(), "不会终止任务或改写 owner") {
		t.Fatalf("doctor --fix must reject legacy residue: %v", err)
	}
	stored, readErr := os.ReadFile(configPath)
	info, statErr := os.Stat(configPath)
	entries, dirErr := os.ReadDir(dir)
	if readErr != nil || statErr != nil || dirErr != nil || !bytes.Equal(stored, original) || info.Mode() != beforeInfo.Mode() || len(entries) != 1 {
		t.Fatalf("legacy residue rejection must be byte- and mode-identical: read=%v stat=%v dir=%v entries=%v", readErr, statErr, dirErr, entries)
	}
}

func TestRunDoctorFixDoesNotRebuildLegacySharingConfiguration(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	original := []byte(`{"app_server":{"transport":"ws","shared_fallback":{"transport":"ws"}}}`)
	if err := os.WriteFile(configPath, original, 0o600); err != nil {
		t.Fatal(err)
	}

	err := runDoctor([]string{"doctor", "--config", configPath, "--fix"})
	if !errors.Is(err, config.ErrLegacyAppServerConfiguration) {
		t.Fatalf("doctor --fix must preserve the legacy migration boundary: %v", err)
	}
	stored, readErr := os.ReadFile(configPath)
	entries, dirErr := os.ReadDir(dir)
	if readErr != nil || dirErr != nil || !bytes.Equal(stored, original) || len(entries) != 1 {
		t.Fatalf("legacy config must not produce backup or token artifacts: read=%v dir=%v entries=%v raw=%s", readErr, dirErr, entries, stored)
	}
}

func TestRunUpRejectsLegacyResidueBeforeSetupWrites(t *testing.T) {
	previous := inspectLegacyCodexExperimentResidue
	inspectLegacyCodexExperimentResidue = func() (string, error) {
		return "旧 LaunchAgent 配置仍存在", nil
	}
	t.Cleanup(func() { inspectLegacyCodexExperimentResidue = previous })
	dir := filepath.Join(t.TempDir(), "new-config-dir")
	configPath := filepath.Join(dir, "config.json")

	err := runUp([]string{"up", "--config", configPath, "--wait=0"})
	if err == nil || !strings.Contains(err.Error(), "两套 owner 混跑") {
		t.Fatalf("up must reject legacy residue: %v", err)
	}
	if _, statErr := os.Stat(dir); !os.IsNotExist(statErr) {
		t.Fatalf("residue preflight must run before setup creates files: %v", statErr)
	}
}

func TestRunSetupForceRejectsLegacyResidueBeforeMigrationOrPreflight(t *testing.T) {
	fixture := prepareMainLegacyConfigFixture(t)
	sshCalled := filepath.Join(t.TempDir(), "ssh-called")
	t.Setenv("MIMI_AGENTD_SSH_CALLED_MARKER", sshCalled)
	previous := inspectLegacyCodexExperimentResidue
	inspectLegacyCodexExperimentResidue = func() (string, error) {
		return "旧 LaunchAgent 配置仍存在", nil
	}
	t.Cleanup(func() { inspectLegacyCodexExperimentResidue = previous })

	err := runSetupWithWriters([]string{"setup", "--force"}, io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "两套 owner 混跑") {
		t.Fatalf("setup --force must reject legacy residue: %v", err)
	}
	stored, readErr := os.ReadFile(fixture.source)
	if readErr != nil || !bytes.Equal(stored, fixture.raw) {
		t.Fatalf("residue rejection must not modify legacy config: read=%v raw=%s", readErr, stored)
	}
	assertPathDoesNotExist(t, fixture.destination, "residue rejection must run before default config migration")
	assertPathDoesNotExist(t, sshCalled, "residue rejection must run before setup SSH preflight")
}

func TestEnsureCodexCLIAvailableRepairsStalePathBeforeServiceStart(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	dir := t.TempDir()
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	codexPath = writeMainTestCodex(t, codexPath)
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
		"AGENTD_APP_SERVER_SSH_TARGET",
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

func writeMainTestCodex(t *testing.T, path string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		path += ".cmd"
		body := "@echo off\r\nif \"%~1\"==\"--version\" echo codex-cli 0.149.1\r\nif \"%~1\"==\"app-server\" if \"%~2\"==\"--help\" echo --listen --ws-auth --ws-token-file\r\nexit /b 0\r\n"
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	body := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  printf '%s\\n' 'codex-cli 0.149.1'\nfi\nif [ \"$1\" = \"app-server\" ] && [ \"$2\" = \"--help\" ]; then\n  printf '%s\\n' '--listen --ws-auth --ws-token-file'\nfi\nexit 0\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

const mainTestSSHHelperEnv = "MIMI_AGENTD_SSH_HELPER"

// TestMainSSHHelperProcess 以当前测试进程模拟 SSH 远端，避免单测依赖本机 Remote Login。
func TestMainSSHHelperProcess(t *testing.T) {
	if os.Getenv(mainTestSSHHelperEnv) != "1" {
		return
	}
	if marker := os.Getenv("MIMI_AGENTD_SSH_CALLED_MARKER"); marker != "" {
		if err := os.WriteFile(marker, []byte("called\n"), 0o600); err != nil {
			os.Exit(89)
		}
	}
	separator := -1
	for index, arg := range os.Args {
		if arg == "--" {
			separator = index
			break
		}
	}
	if separator < 0 || separator+1 >= len(os.Args) {
		os.Exit(90)
	}
	sshArgs := os.Args[separator+1:]
	command := sshArgs[len(sshArgs)-1]
	switch command {
	case "codex --version":
		fmt.Fprintln(os.Stdout, "codex-cli 0.149.1")
	case `if test -S "$HOME/.codex/app-server-control/app-server-control.sock"; then printf socket-present; else printf socket-missing; fi`:
		if mainTestFileExists(os.Getenv("MIMI_AGENTD_SSH_SERVER_MARKER")) {
			fmt.Fprint(os.Stdout, "socket-present")
		} else {
			fmt.Fprint(os.Stdout, "socket-missing")
		}
	case "nohup env CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1 codex -c features.code_mode_host=true app-server --listen unix:// >/dev/null 2>&1 </dev/null &":
		if err := os.WriteFile(os.Getenv("MIMI_AGENTD_SSH_SERVER_MARKER"), []byte("ready"), 0o600); err != nil {
			os.Exit(91)
		}
	case "codex app-server proxy":
		if !mainTestFileExists(os.Getenv("MIMI_AGENTD_SSH_SERVER_MARKER")) {
			os.Exit(92)
		}
		serveMainTestSSHWebSocket()
	default:
		os.Exit(93)
	}
	os.Exit(0)
}

func installMainTestSSH(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	marker := filepath.Join(dir, "server-ready")
	if err := os.WriteFile(marker, []byte("ready"), 0o600); err != nil {
		t.Fatal(err)
	}
	wrapper := filepath.Join(dir, "ssh")
	if runtime.GOOS == "windows" {
		wrapper += ".cmd"
		body := "@echo off\r\n\"%MIMI_AGENTD_SSH_TEST_BINARY%\" -test.run=TestMainSSHHelperProcess -- %*\r\n"
		if err := os.WriteFile(wrapper, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	} else {
		body := "#!/bin/sh\nexec \"$MIMI_AGENTD_SSH_TEST_BINARY\" -test.run=TestMainSSHHelperProcess -- \"$@\"\n"
		if err := os.WriteFile(wrapper, []byte(body), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv(mainTestSSHHelperEnv, "1")
	t.Setenv("MIMI_AGENTD_SSH_TEST_BINARY", os.Args[0])
	t.Setenv("MIMI_AGENTD_SSH_SERVER_MARKER", marker)
	t.Setenv("PATH", prependMainTestPath(dir, os.Getenv("PATH")))
}

func prependMainTestPath(dir, current string) string {
	if current == "" {
		return dir
	}
	return dir + string(os.PathListSeparator) + current
}

func serveMainTestSSHWebSocket() {
	reader := bufio.NewReader(os.Stdin)
	key := ""
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			os.Exit(94)
		}
		if strings.HasPrefix(strings.ToLower(line), "sec-websocket-key:") {
			key = strings.TrimSpace(line[len("Sec-WebSocket-Key:"):])
		}
		if line == "\r\n" {
			break
		}
	}
	digest := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	fmt.Fprintf(os.Stdout, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(digest[:]))
	_ = readMainTestSSHFrame(reader)
	writeMainTestSSHFrame([]byte(`{"id":1,"result":{"userAgent":"codex_cli_rs/0.149.1"}}`))
	_, _ = io.Copy(io.Discard, reader)
}

func readMainTestSSHFrame(reader *bufio.Reader) []byte {
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil
	}
	length := int(header[1] & 0x7f)
	if length == 126 {
		raw := make([]byte, 2)
		_, _ = io.ReadFull(reader, raw)
		length = int(binary.BigEndian.Uint16(raw))
	}
	mask := make([]byte, 4)
	_, _ = io.ReadFull(reader, mask)
	payload := make([]byte, length)
	_, _ = io.ReadFull(reader, payload)
	for index := range payload {
		payload[index] ^= mask[index%4]
	}
	return payload
}

func writeMainTestSSHFrame(payload []byte) {
	header := []byte{0x81, byte(len(payload))}
	if len(payload) >= 126 {
		header = []byte{0x81, 126, byte(len(payload) >> 8), byte(len(payload))}
	}
	_, _ = os.Stdout.Write(append(header, payload...))
}

func mainTestFileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func prepareBrewSideEffectProbe(t *testing.T) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		installFakeWindowsCommands(t)
		return filepath.Join(t.TempDir(), "windows-task-called")
	}
	useManagedServicePlatform(t, "darwin")
	binDir := t.TempDir()
	marker := filepath.Join(t.TempDir(), "brew-called")
	brewPath := filepath.Join(binDir, "brew")
	brewBody := "#!/bin/sh\nprintf '%s\\n' called > \"$BREW_MARKER\"\nexit 0\n"
	if err := os.WriteFile(brewPath, []byte(brewBody), 0o755); err != nil {
		t.Fatal(err)
	}
	launchctlPath := filepath.Join(binDir, "launchctl")
	launchctlBody := "#!/bin/sh\nprintf '%s\\n' called > \"$BREW_MARKER\"\nexit 0\n"
	if err := os.WriteFile(launchctlPath, []byte(launchctlBody), 0o755); err != nil {
		t.Fatal(err)
	}
	_ = writeMainTestCodex(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", prependMainTestPath(binDir, os.Getenv("PATH")))
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
	installMainTestSSH(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	// os.UserConfigDir uses APPDATA on Windows rather than HOME/XDG_CONFIG_HOME.
	// Isolate both platform defaults so tests never migrate a real user config.
	t.Setenv("APPDATA", filepath.Join(home, "AppData", "Roaming"))
	t.Setenv("LOCALAPPDATA", filepath.Join(home, "AppData", "Local"))
	t.Setenv("USERPROFILE", home)
	projectPath := filepath.Join(home, "code", "legacy-project")
	if err := os.MkdirAll(projectPath, 0o700); err != nil {
		t.Fatal(err)
	}
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	codexPath = writeMainTestCodex(t, codexPath)

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

func assertMainLegacyConfigPreserved(t *testing.T, fixture mainLegacyConfigFixture, migratesSSH bool) {
	t.Helper()
	sourceRaw, err := os.ReadFile(fixture.source)
	if err != nil {
		t.Fatal(err)
	}
	if string(sourceRaw) != string(fixture.raw) {
		t.Fatal("平台默认路径迁移不得改写旧配置")
	}
	destinationRaw, err := os.ReadFile(fixture.destination)
	if err != nil {
		t.Fatal(err)
	}
	var destination map[string]any
	if err := json.Unmarshal(destinationRaw, &destination); err != nil {
		t.Fatal(err)
	}
	appServer := destination["app_server"].(map[string]any)
	if destination["future_unknown_field"] == nil {
		t.Fatalf("平台默认路径迁移必须保留未知字段：%+v", destination)
	}
	if migratesSSH && runtime.GOOS != "windows" {
		if appServer["transport"] != "ssh" || appServer["ssh_target"] != "127.0.0.1" {
			t.Fatalf("新配置必须将旧 WS 迁移为共享 SSH：%+v", destination)
		}
		for _, obsolete := range []string{"managed", "listen", "ws_token_file", "remote_gateway"} {
			if _, ok := appServer[obsolete]; ok {
				t.Fatalf("新配置不得保留旧 WS 字段 %q：%+v", obsolete, appServer)
			}
		}
	} else if appServer["transport"] != "ws" {
		t.Fatalf("只读命令不得额外改写 App Server 配置：%+v", appServer)
	}
	info, err := os.Lstat(fixture.destination)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != 0o600) {
		t.Fatalf("新版配置必须是 0600 普通文件：%v", info.Mode())
	}
	result, err := agentsetup.Pair(context.Background(), fixture.destination)
	if err != nil {
		t.Fatal(err)
	}
	if result.Token != fixture.token {
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

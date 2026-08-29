package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestMain(m *testing.M) {
	sshPreflight = func(context.Context, *appserver.SSHTransport) error { return nil }
	os.Exit(m.Run())
}

func TestRunCreatesConfigAndPairURL(t *testing.T) {
	clearSetupEnv(t)
	scanRoot := t.TempDir()
	cfgPath := filepath.Join(t.TempDir(), "config.json")

	result, err := Run(context.Background(), Options{
		ConfigPath: cfgPath,
		ScanRoot:   scanRoot,
		Listen:     "127.0.0.1:8787",
	})
	if err != nil {
		t.Fatal(err)
	}

	if !result.Created {
		t.Fatal("首次 setup 应创建配置")
	}
	if result.ConfigPath != cfgPath {
		t.Fatalf("配置路径异常：%s", result.ConfigPath)
	}
	if result.Endpoint != "http://127.0.0.1:8787" {
		t.Fatalf("Endpoint 异常：%s", result.Endpoint)
	}
	if len(result.Token) != 64 {
		t.Fatalf("外侧 token 应为 32 bytes hex，got len=%d", len(result.Token))
	}
	if result.AppServerSSHTarget != config.DefaultAppServerSSHTarget() {
		t.Fatalf("SSH target 异常：%s", result.AppServerSSHTarget)
	}
	connect, err := url.Parse(result.ConnectURL)
	if err != nil {
		t.Fatal(err)
	}
	if connect.Scheme != "mimiremote" || connect.Host != "connect" {
		t.Fatalf("连接链接 scheme/host 异常：%s", result.ConnectURL)
	}
	if connect.Query().Get("endpoint") != result.Endpoint || connect.Query().Get("token") != result.Token {
		t.Fatalf("连接链接未包含 endpoint/token：%s", result.ConnectURL)
	}
	parsed, err := url.Parse(result.PairURL)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != "mimiremote" || parsed.Host != "pair" {
		t.Fatalf("配对链接 scheme/host 异常：%s", result.PairURL)
	}
	if parsed.Query().Get("endpoint") != result.Endpoint || parsed.Query().Get("pair_sig") == "" {
		t.Fatalf("配对链接未包含 endpoint/pair_sig：%s", result.PairURL)
	}
	if parsed.Query().Get("token") != "" {
		t.Fatalf("配对二维码不应携带长期 token：%s", result.PairURL)
	}
	if parsed.Query().Get("expires_at") == "" {
		t.Fatalf("配对链接应包含 expires_at：%s", result.PairURL)
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AppServer.Transport != config.DefaultAppServerTransport() || cfg.AppServer.SSHTarget != config.DefaultAppServerSSHTarget() {
		t.Fatalf("setup 应默认启用 localhost SSH app-server：%+v", cfg.AppServer)
	}
	if len(cfg.ScanRoots) != 1 || cfg.ScanRoots[0] != scanRoot {
		t.Fatalf("scan root 未写入配置：%+v", cfg.ScanRoots)
	}
	if cfg.Claude.MaxConcurrentBridges != config.DefaultClaudeMaxConcurrentBridges {
		t.Fatalf("setup Claude 并发默认值异常：got=%d want=%d", cfg.Claude.MaxConcurrentBridges, config.DefaultClaudeMaxConcurrentBridges)
	}
	rawConfig, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	var stored config.Config
	if err := json.Unmarshal(rawConfig, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Claude.MaxConcurrentBridges != config.DefaultClaudeMaxConcurrentBridges {
		t.Fatalf("setup 必须把有效 Claude 并发值写入磁盘：got=%d want=%d", stored.Claude.MaxConcurrentBridges, config.DefaultClaudeMaxConcurrentBridges)
	}
}

func TestRunUsesAppServerSSHTargetFromEnvironment(t *testing.T) {
	clearSetupEnv(t)
	t.Setenv("AGENTD_APP_SERVER_SSH_TARGET", "mimi-host")
	cfgPath := filepath.Join(t.TempDir(), "config.json")

	result, err := Run(context.Background(), Options{
		ConfigPath: cfgPath,
		ScanRoot:   t.TempDir(),
		Listen:     "127.0.0.1:8787",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.AppServerSSHTarget != "mimi-host" {
		t.Fatalf("setup 应使用环境变量中的 SSH target：%q", result.AppServerSSHTarget)
	}
	t.Setenv("AGENTD_APP_SERVER_SSH_TARGET", "")
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AppServer.SSHTarget != "mimi-host" {
		t.Fatalf("配置应持久化环境变量中的 SSH target：%q", cfg.AppServer.SSHTarget)
	}
}

func TestPairingURLRefreshCreatesDistinctTicketsAndKeepsPriorValidUntilOwnExpiry(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	endpoint := "https://mac.example.test"
	firstIssuedAt := time.Date(2026, 7, 31, 8, 0, 0, 100, time.UTC)
	refreshedIssuedAt := firstIssuedAt.Add(30 * time.Second)
	first := pairingTicketFromURL(
		t,
		pairingURL(endpoint, secret, firstIssuedAt, firstIssuedAt.Add(defaultPairingURLTTL)),
	)
	refreshed := pairingTicketFromURL(
		t,
		pairingURL(endpoint, secret, refreshedIssuedAt, refreshedIssuedAt.Add(defaultPairingURLTTL)),
	)

	if first.Signature == refreshed.Signature {
		t.Fatal("主动刷新必须生成不同的配对票据")
	}
	firstExpiry, err := time.Parse(time.RFC3339Nano, first.ExpiresAt)
	if err != nil {
		t.Fatal(err)
	}
	firstIssue, err := time.Parse(time.RFC3339Nano, first.IssuedAt)
	if err != nil {
		t.Fatal(err)
	}
	if firstExpiry.Sub(firstIssue) != defaultPairingURLTTL {
		t.Fatalf("配对票据必须保持 10 分钟有效期：%s", firstExpiry.Sub(firstIssue))
	}

	// 刷新当前没有主动撤销表；旧票据保持既有语义，到自己的 expires_at 前仍可重复使用。
	for attempt := 1; attempt <= 2; attempt++ {
		if err := auth.ValidatePairingTicket(secret, first, refreshedIssuedAt); err != nil {
			t.Fatalf("刷新后旧票据第 %d 次校验应继续成功：%v", attempt, err)
		}
	}
	if err := auth.ValidatePairingTicket(secret, refreshed, refreshedIssuedAt); err != nil {
		t.Fatalf("刷新生成的新票据应成功：%v", err)
	}
	if err := auth.ValidatePairingTicket(secret, first, firstExpiry); err == nil {
		t.Fatal("旧票据到自己的到期瞬间必须失效")
	}
	if err := auth.ValidatePairingTicket(secret, refreshed, firstExpiry); err != nil {
		t.Fatalf("旧票据到期不应提前撤销新票据：%v", err)
	}
	refreshedExpiry, err := time.Parse(time.RFC3339Nano, refreshed.ExpiresAt)
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.ValidatePairingTicket(secret, refreshed, refreshedExpiry); err == nil {
		t.Fatal("新票据到自己的到期瞬间必须失效")
	}
}

func pairingTicketFromURL(t *testing.T, rawURL string) auth.PairingTicket {
	t.Helper()
	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	query := parsed.Query()
	if query.Get("token") != "" {
		t.Fatal("短期配对链接不能携带长期 Token")
	}
	return auth.PairingTicket{
		Endpoint:  query.Get("endpoint"),
		IssuedAt:  query.Get("issued_at"),
		ExpiresAt: query.Get("expires_at"),
		Signature: query.Get("pair_sig"),
	}
}

func TestDefaultScanRootKeepsExplicitValue(t *testing.T) {
	explicit := t.TempDir()
	root, err := defaultScanRoot(explicit)
	if err != nil {
		t.Fatal(err)
	}
	if root != explicit {
		t.Fatalf("显式 scan root 不应被改写：got %s want %s", root, explicit)
	}
}

func TestDefaultBrowseRootDefaultsToHome(t *testing.T) {
	root, err := defaultBrowseRoot("")
	if err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if root != home {
		t.Fatalf("默认浏览授权根应是用户 Home：got %s want %s", root, home)
	}
}

func TestDefaultAgentDNetworkPrefersTailscaleAndFallsBackToLAN(t *testing.T) {
	tests := []struct {
		name         string
		tailscaleIP  string
		lanIP        string
		wantListen   string
		wantAllowLAN bool
		wantError    string
	}{
		{
			name:        "tailscale preferred",
			tailscaleIP: "100.100.20.30",
			lanIP:       "192.168.31.20",
			wantListen:  "100.100.20.30:8787",
		},
		{
			name:         "lan fallback",
			lanIP:        "192.168.31.20",
			wantListen:   "0.0.0.0:8787",
			wantAllowLAN: true,
		},
		{
			name:      "no reachable network",
			wantError: "未检测到 Tailscale 或可用的局域网 IPv4",
		},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			listen, allowLAN, err := defaultAgentDNetworkWithLANFallback(
				context.Background(),
				pairingNetworkLookups{
					tailscaleIP: func(context.Context) string { return testCase.tailscaleIP },
					lanIP:       func() string { return testCase.lanIP },
				},
				true,
			)
			if testCase.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), testCase.wantError) {
					t.Fatalf("缺少预期错误 %q：%v", testCase.wantError, err)
				}
				return
			}
			if err != nil || listen != testCase.wantListen || allowLAN != testCase.wantAllowLAN {
				t.Fatalf(
					"默认网络选择错误：listen=%q allow_lan=%v err=%v",
					listen,
					allowLAN,
					err,
				)
			}
		})
	}
}

func TestDefaultAgentDNetworkCanRequireExplicitLANOptIn(t *testing.T) {
	listen, allowLAN, err := defaultAgentDNetworkWithLANFallback(
		context.Background(),
		pairingNetworkLookups{
			tailscaleIP: func(context.Context) string { return "" },
			lanIP:       func() string { return "192.168.31.20" },
		},
		false,
	)
	if err != nil {
		t.Fatal(err)
	}
	if listen != "127.0.0.1:8787" || allowLAN {
		t.Fatalf("未显式允许 LAN 时必须保持 loopback：listen=%s allowLAN=%v", listen, allowLAN)
	}
}

func TestRunWritesBrowseRoots(t *testing.T) {
	clearSetupEnv(t)
	scanRoot := t.TempDir()
	browseRoot := t.TempDir()
	cfgPath := filepath.Join(t.TempDir(), "config.json")

	result, err := Run(context.Background(), Options{
		ConfigPath: cfgPath,
		ScanRoot:   scanRoot,
		BrowseRoot: browseRoot,
		Listen:     "127.0.0.1:8787",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.BrowseRoot != browseRoot {
		t.Fatalf("setup 结果应包含浏览授权根：%+v", result)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.BrowseRoots) != 1 || cfg.BrowseRoots[0] != browseRoot {
		t.Fatalf("browse_roots 未写入配置：%+v", cfg.BrowseRoots)
	}
	if len(cfg.ScanRoots) != 1 || cfg.ScanRoots[0] != scanRoot {
		t.Fatalf("browse root 不应影响 scan_roots：%+v", cfg.ScanRoots)
	}
}

func TestRunKeepsExistingConfigWithoutForce(t *testing.T) {
	clearSetupEnv(t)
	scanRoot := t.TempDir()
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	first, err := Run(context.Background(), Options{
		ConfigPath: cfgPath,
		ScanRoot:   scanRoot,
		Listen:     "127.0.0.1:8787",
	})
	if err != nil {
		t.Fatal(err)
	}
	second, err := Run(context.Background(), Options{
		ConfigPath: cfgPath,
		ScanRoot:   scanRoot,
		Listen:     "127.0.0.1:9999",
	})
	if err != nil {
		t.Fatal(err)
	}
	if second.Created {
		t.Fatal("配置已存在时 setup 不应覆盖")
	}
	if second.Token != first.Token || second.Endpoint != first.Endpoint {
		t.Fatalf("未 force 时应保留原配置：first=%+v second=%+v", first, second)
	}
	if second.AppServerSSHTarget != first.AppServerSSHTarget {
		t.Fatal("未 force 时不能更改 SSH target")
	}
}

func TestRunRejectsUnsafeSSHTargetBeforeWriting(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	original := []byte("{\"existing\":true}\n")
	if err := os.WriteFile(cfgPath, original, 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := Run(context.Background(), Options{
		ConfigPath:         cfgPath,
		ScanRoot:           t.TempDir(),
		BrowseRoot:         t.TempDir(),
		AppServerSSHTarget: "-oProxyCommand=bad",
		Force:              true,
	})
	if err == nil || !strings.Contains(err.Error(), "不能以 - 开头") {
		t.Fatalf("setup 必须在写入前拒绝 SSH option injection：%v", err)
	}
	stored, readErr := os.ReadFile(cfgPath)
	if readErr != nil || !bytes.Equal(stored, original) {
		t.Fatalf("失败的 setup 不能覆盖现有配置：err=%v raw=%s", readErr, stored)
	}
}

func TestPairWarnsWhenEndpointIsLoopback(t *testing.T) {
	clearSetupEnv(t)
	scanRoot := t.TempDir()
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	result, err := Run(context.Background(), Options{
		ConfigPath: cfgPath,
		ScanRoot:   scanRoot,
		Listen:     "127.0.0.1:8787",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !hasWarning(result.Warnings, "本机地址") {
		t.Fatalf("loopback endpoint 应提示真机 iPad 风险：%+v", result.Warnings)
	}
}

func clearSetupEnv(t *testing.T) {
	t.Helper()
	// setup 的并发提交使用用户级配置锁。每个测试使用独立 HOME，避免并行
	// 用例共享锁文件或碰到开发机配置。
	t.Setenv("HOME", t.TempDir())
	for _, key := range []string{
		"AGENTD_CONFIG",
		"AGENTD_LISTEN",
		"AGENTD_BIND",
		"AGENTD_PORT",
		"AGENTD_TOKEN",
		"AGENTD_ALLOW_QUERY_TOKEN",
		"AGENTD_CODEX_BIN",
		"AGENTD_CODEX_ARGS",
		"AGENTD_APP_SERVER_TRANSPORT",
		"AGENTD_APP_SERVER_LISTEN",
		"AGENTD_APP_SERVER_WS_TOKEN_FILE",
		"AGENTD_APP_SERVER_MANAGED",
		"AGENTD_APP_SERVER_SSH_TARGET",
		"AGENTD_CODEX_TRANSCRIPTION_BASE_URL",
		"AGENTD_CODEX_AUTH_FILE",
		"AGENTD_DEBUG_CODEX_HISTORY",
		"AGENTD_DEV_INSECURE",
		"AGENTD_OUTPUT_BUFFER_BYTES",
		"AGENTD_PROJECTS",
		"AGENTD_SCAN_ROOTS",
		"AGENTD_BROWSE_ROOTS",
		"AGENTD_WORKTREES_ROOT",
	} {
		t.Setenv(key, "")
	}
}

func hasWarning(warnings []string, want string) bool {
	for _, warning := range warnings {
		if strings.Contains(warning, want) {
			return true
		}
	}
	return false
}

func assertPrivateTokenFile(t *testing.T, path string) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != 0o600) {
		t.Fatalf("upstream token 必须是 0600 regular file：mode=%v", info.Mode())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(strings.TrimSpace(string(raw))) != 64 {
		t.Fatalf("upstream token 应为 32-byte hex：%q", raw)
	}
}

package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
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
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestFreshExplicitSSHUsesOnlySuccessfulPreflight(t *testing.T) {
	if config.SupportsManagedAppServer() {
		t.Skip("explicit SSH setup requires a non-managed platform")
	}
	clearSetupEnv(t)
	for _, tc := range []struct {
		name             string
		saveOnly         bool
		localServiceOnly bool
		wantCalls        int
	}{
		{name: "verified SSH", wantCalls: 1},
		{name: "save without preflight", saveOnly: true},
		{name: "local service without preflight", localServiceOnly: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			opts := Options{
				ConfigPath: path, ScanRoot: t.TempDir(), Listen: "127.0.0.1:8787",
				AppServerSSHTarget: "mimi-local", SaveOnly: tc.saveOnly, LocalServiceOnly: tc.localServiceOnly,
				Assistants:       map[string]string{"claude": "disabled", "agy": "disabled"},
				ObserveAssistant: inspectPreflightRuntime,
			}
			original := sshPreflight
			t.Cleanup(func() { sshPreflight = original })
			calls := 0
			sshPreflight = func(_ context.Context, transport *appserver.SSHTransport) error {
				calls++
				if transport.Target() != opts.AppServerSSHTarget {
					t.Fatalf("unexpected SSH target %q", transport.Target())
				}
				return nil
			}
			result, err := Run(t.Context(), opts)
			if err != nil {
				t.Fatal(err)
			}
			if calls != tc.wantCalls || result.PairURL != "" {
				t.Fatalf("SSH preflight calls = %d, pairing available = %t", calls, result.PairURL != "")
			}
			cfg := config.ParseSetupDocument(readPublicationBytes(t, path)).Config
			if cfg.AppServer.Transport != "ssh" || cfg.Codex.Enabled == nil || *cfg.Codex.Enabled != (tc.wantCalls == 1) {
				t.Fatalf("transport = %q, codex enabled = %t", cfg.AppServer.Transport, cfg.Codex.IsEnabled())
			}
		})
	}
}

func TestLegacyExplicitSSHOnExistingLocalHost(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("legacy macOS local-to-SSH setup")
	}
	clearSetupEnv(t)
	opts := atomicSetupOptions(t, filepath.Join(t.TempDir(), "config.json"), false)
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	old := readPublicationBytes(t, opts.ConfigPath)
	identity := config.ParseSetupDocument(old).Config.Auth
	opts.SaveOnly, opts.LocalServiceOnly = false, true
	opts.AppServerSSHTarget = "mimi-local"
	original := sshPreflight
	t.Cleanup(func() { sshPreflight = original })
	injected := errors.New("SSH unavailable")
	sshPreflight = func(context.Context, *appserver.SSHTransport) error { return injected }
	if _, err := Run(t.Context(), opts); !errors.Is(err, injected) {
		t.Fatalf("SSH preflight failure: %v", err)
	}
	assertFileBytesAndMode(t, opts.ConfigPath, old, 0600)
	sshPreflight = func(_ context.Context, transport *appserver.SSHTransport) error {
		if transport.Target() != opts.AppServerSSHTarget {
			t.Fatal("wrong SSH target")
		}
		return nil
	}
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	cfg := config.ParseSetupDocument(readPublicationBytes(t, opts.ConfigPath)).Config
	if cfg.Auth != identity || cfg.AppServer.Transport != "ssh" || cfg.AppServer.SSHTarget != opts.AppServerSSHTarget || !cfg.AppServer.PinTransport {
		t.Fatal("legacy command lost the SSH selection or host identity")
	}
}

func TestMain(m *testing.M) {
	for _, e := range os.Environ() {
		k, _, _ := strings.Cut(e, "=")
		if strings.HasPrefix(strings.ToUpper(k), "AGENTD_") || k == "CLAUDE_BRIDGE_CLAUDE_BIN" || k == "AGY_ADAPTER_AGY_BIN" {
			os.Unsetenv(k)
		}
	}
	observeSetupAssistant = func(_ context.Context, id string, _ config.Config, _ string, _ PreflightHost) PreflightObservation {
		return PreflightObservation{Available: knownAvailability(id == "codex")}
	}
	sshPreflight = func(context.Context, *appserver.SSHTransport) error { return nil }
	localAppServerPreflight = func(context.Context, string, map[string]string) error { return nil }
	// CI 机器上没有 Codex。迁移与 doctor 修复共用的解析器默认原样返回配置路径，
	// 需要覆盖回退解析行为的用例自行替换。
	resolveMigrationCodexBin = func(configured string) (string, error) { return configured, nil }
	os.Exit(m.Run())
}

func TestRunCreatesConfigWithoutIssuingOffline(t *testing.T) {
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
	assertDefaultSetupResultAppServer(t, result)
	if result.ConnectURL != "" || result.PairURL != "" || result.PairExpiresAt != "" {
		t.Fatal("offline setup issued credentials")
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Codex.Bin != "codex" {
		t.Fatal("automatic setup persisted a pin")
	}
	assertDefaultSetupConfigAppServer(t, cfg)
	scanRoot, err = filepath.EvalSymlinks(scanRoot)
	if err != nil {
		t.Fatal(err)
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
	if runtime.GOOS == "windows" {
		t.Skip("Windows 使用本机受管 WebSocket，不读取 SSH target")
	}
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

func TestRunPinsExplicitLoopbackSSHTargetAgainstAutoMigration(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 使用本机受管 WebSocket，不读取 SSH target")
	}
	clearSetupEnv(t)
	t.Setenv("AGENTD_APP_SERVER_SSH_TARGET", "127.0.0.1")
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	if _, err := Run(context.Background(), Options{
		ConfigPath: cfgPath,
		ScanRoot:   t.TempDir(),
		Listen:     "127.0.0.1:8787",
	}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTD_APP_SERVER_SSH_TARGET", "")
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AppServer.Transport != "ssh" || cfg.AppServer.SSHTarget != "127.0.0.1" || !cfg.AppServer.PinTransport {
		t.Fatalf("显式回环 target 必须写入 ssh 并固定：%+v", cfg.AppServer)
	}
	if !config.SupportsSharedLocalAppServer() {
		return
	}
	// 后台 serve 不带命令行参数：自动迁移必须尊重这次显式选择。
	previous := localAppServerPreflight
	localAppServerPreflight = func(context.Context, string, map[string]string) error {
		t.Fatal("固定的显式 SSH 不应触发本机迁移预检")
		return nil
	}
	t.Cleanup(func() { localAppServerPreflight = previous })
	before, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := MigrateAppServerToSharedLocal(context.Background(), cfgPath); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("显式固定的 SSH 配置在后台启动时被改写：%s", after)
	}
}

func assertDefaultSetupResultAppServer(t *testing.T, result Result) {
	t.Helper()
	if config.SupportsManagedAppServer() || config.SupportsSharedLocalAppServer() {
		if result.AppServerSSHTarget != "" {
			t.Fatalf("本机 App Server setup 不应持久化 SSH target：%q", result.AppServerSSHTarget)
		}
		return
	}
	if result.AppServerSSHTarget != config.DefaultAppServerSSHTarget() {
		t.Fatalf("SSH target 异常：%s", result.AppServerSSHTarget)
	}
}

func assertDefaultSetupConfigAppServer(t *testing.T, cfg config.Config) {
	t.Helper()
	if config.SupportsSharedLocalAppServer() {
		if cfg.AppServer != config.DefaultSharedLocalAppServerConfig() {
			t.Fatalf("macOS 与 Linux setup 应默认启用共享本机 App Server：%+v", cfg.AppServer)
		}
		return
	}
	if config.SupportsManagedAppServer() {
		if cfg.AppServer.Transport != "ws" ||
			!cfg.AppServer.Managed ||
			cfg.AppServer.Listen != config.DefaultManagedAppServerListen() ||
			strings.TrimSpace(cfg.AppServer.WSTokenFile) == "" {
			t.Fatalf("本机 setup 应启用受管 loopback WebSocket：%+v", cfg.AppServer)
		}
		assertPrivateRegularFile(t, cfg.AppServer.WSTokenFile)
		return
	}
	if cfg.AppServer.Transport != config.DefaultAppServerTransport() || cfg.AppServer.SSHTarget != config.DefaultAppServerSSHTarget() {
		t.Fatalf("setup 应默认启用 localhost SSH app-server：%+v", cfg.AppServer)
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

func TestSetupUsesSelectedEmptyDirectoryAsOnlyDefaultGrant(t *testing.T) {
	home := preflightSandbox(t)
	selected := filepath.Join(home, "selected")
	sibling := filepath.Join(home, "sibling")
	for _, d := range []string{selected, sibling} {
		if err := os.Mkdir(d, 0700); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(t.TempDir(), "config.json")
	r, err := Run(t.Context(), Options{ConfigPath: path, ScanRoot: selected, SaveOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(selected)
	if err != nil {
		t.Fatal(err)
	}
	for _, roots := range [][]string{cfg.ScanRoots, cfg.BrowseRoots, {r.ScanRoot}, {r.BrowseRoot}} {
		if len(roots) != 1 {
			t.Fatalf("unexpected grants %q", roots)
		}
		got, err := filepath.EvalSymlinks(roots[0])
		if err != nil || got != canonical {
			t.Fatalf("wrong grant %q: %v", roots, err)
		}
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := registry.FindByPath(selected); !ok {
		t.Fatal("empty authorized root is not a workspace")
	}
	if _, ok := registry.FindByPath(sibling); ok {
		t.Fatal("sibling accessible outside selected root")
	}
	if cfg.Listen != "127.0.0.1:8787" || cfg.TailscaleAccessEnabled() || cfg.LANAccessEnabled() || cfg.Tailcat.Enabled {
		t.Fatal("fresh install opened an external transport")
	}
}

func TestFreshNoPairDoesNotEnableExternalIngress(t *testing.T) {
	clearSetupEnv(t)
	for _, listen := range []string{"", "127.0.0.1:9080", "0.0.0.0:9080"} {
		t.Run(listen, func(t *testing.T) {
			o := atomicSetupOptions(t, filepath.Join(t.TempDir(), "config.json"), false)
			o.Listen = listen
			r, err := Run(t.Context(), o)
			if listen == "0.0.0.0:9080" {
				if err == nil {
					t.Fatal("accepted an external bind")
				}
				assertMissingPath(t, o.ConfigPath)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			saved := config.ReadPreflightSnapshot(r.ConfigPath)
			if saved.Code != "" || saved.Config.TailscaleAccessEnabled() || saved.Config.LANAccessEnabled() || saved.Config.Tailcat.Enabled {
				t.Fatal("fresh install enabled external access")
			}
		})
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
	browseRoot, err = filepath.EvalSymlinks(browseRoot)
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
	scanRoot, err = filepath.EvalSymlinks(scanRoot)
	if err != nil {
		t.Fatal(err)
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
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	_, err := Run(t.Context(), Options{SaveOnly: true, ConfigPath: path, ScanRoot: t.TempDir(), AppServerSSHTarget: "-oProxyCommand=bad"})
	if err == nil {
		t.Fatal("accepted an unsafe SSH option")
	}
	assertMissingPath(t, path)
}

func TestStatusWarnsWhenEndpointIsLoopback(t *testing.T) {
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
	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	result = ResultFromConfig(t.Context(), cfgPath, cfg)
	if result.PairURL != "" {
		t.Fatal("status minted a ticket")
	}
	if !hasWarning(result.Warnings, "本机地址") || !hasWarning(result.Warnings, "移动设备") {
		t.Fatalf("loopback endpoint 应提示移动设备连接风险：%+v", result.Warnings)
	}
	// Windows 配对页会原样显示这些警告，不能和“移动设备”说明混用设备型号。
	if hasWarning(result.Warnings, "iPad") {
		t.Fatalf("配对警告不应限定 iPad：%+v", result.Warnings)
	}
}

func clearSetupEnv(t *testing.T) {
	t.Helper()
	// setup 的并发提交使用用户级配置锁。每个测试使用独立 HOME，避免并行
	// 用例共享锁文件或碰到开发机配置。
	home := t.TempDir()
	for _, key := range []string{"HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"} {
		t.Setenv(key, home)
	}
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

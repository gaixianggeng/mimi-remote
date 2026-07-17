package doctor

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestCheckerRunAndPrintDoNotLeakToken(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeFakeCodexWithAppServerHelp(t, codexPath)
	writeFakeExecutable(t, filepath.Join(binDir, "tailscale"))
	t.Setenv("PATH", binDir)

	secret := "0123456789abcdef0123456789abcdef"
	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: secret},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if !results.OK {
		t.Fatalf("fake codex/tailscale 均存在时 doctor 应通过：%+v", results)
	}

	var out bytes.Buffer
	Print(&out, results)
	if strings.Contains(out.String(), secret) {
		t.Fatalf("doctor 输出不能泄漏 token：%s", out.String())
	}
}

func TestCheckerMarksMissingTailscaleAsWarning(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID: "demo", Name: "Demo", Path: t.TempDir(),
		}},
	})
	results := checker.Run(context.Background(), false)
	if !results.OK {
		t.Fatalf("仅缺少 Tailscale 时 doctor 总状态应可用：%+v", results)
	}
	var tailscale Check
	for _, check := range results.Checks {
		if check.Name == "tailscale" {
			tailscale = check
			break
		}
	}
	if tailscale.OK || tailscale.Level != "warning" {
		t.Fatalf("Tailscale 缺失应标记为 warning：%+v", tailscale)
	}

	var out bytes.Buffer
	Print(&out, results)
	if !strings.Contains(out.String(), "WARN tailscale") || strings.Contains(out.String(), "需要处理") {
		t.Fatalf("CLI 应显示 WARN 且不列为阻断错误：%s", out.String())
	}
}

func TestCheckerFailsOnMissingCodexButIgnoresMissingTailscale(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	checker := newTestChecker(t, config.Config{
		Listen: "127.0.0.1:8787",
		Auth:   config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Codex:  config.CodexConfig{Bin: "definitely-missing-codex"},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("缺少 Codex CLI 时 doctor 应失败：%+v", results)
	}

	var codexOK, tailscaleOK bool
	var codexLevel string
	for _, check := range results.Checks {
		switch check.Name {
		case "codex":
			codexOK = check.OK
			codexLevel = check.Level
		case "tailscale":
			tailscaleOK = check.OK
			if check.Message != "未检测到 Tailscale 命令，本机访问仍可使用" {
				t.Fatalf("tailscale 缺失应降级为本机可用提示，实际 %q", check.Message)
			}
		}
	}
	if codexOK {
		t.Fatal("codex check 应失败")
	}
	if codexLevel != "error" {
		t.Fatalf("阻断性检查失败应标记 level=error，实际 %q", codexLevel)
	}
	if !hasCheckMessage(results, "codex", "未找到 Codex CLI") {
		t.Fatalf("codex 缺失时应给出准确文案：%+v", results.Checks)
	}
	if tailscaleOK {
		t.Fatal("空 PATH 下 tailscale check 应失败但不影响整体失败原因判断")
	}
}

func TestCheckerReportsAppServerRuntimeSafely(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if !results.OK {
		t.Fatalf("ws app-server gateway 应通过 doctor：%+v", results)
	}
	if !hasCheck(results, "app-server") {
		t.Fatalf("doctor 应包含 app-server gateway 检查：%+v", results.Checks)
	}
}

func TestCheckerRejectsUnsafeAppServerWS(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "0.0.0.0:8390"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("非 loopback app-server ws 不应通过 doctor：%+v", results)
	}
}

func TestCheckerReportsManagedWSGatewayForAppServerRuntime(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if !results.OK {
		t.Fatalf("setup 默认 ws gateway 应通过 doctor：%+v", results)
	}
	if !hasCheck(results, "app-server") {
		t.Fatalf("启用 ws gateway 时应检查 app-server：%+v", results.Checks)
	}
}

func TestClaudeBridgeCheckRequiresCompatibleVersion(t *testing.T) {
	tests := []struct {
		name       string
		versionOut string
		wantOK     bool
		want       string
	}{
		{name: "compatible", versionOut: "alleycat-claude-bridge 0.2.0", wantOK: true, want: "0.2.0 可用"},
		{name: "too old", versionOut: "alleycat-claude-bridge 0.1.9", wantOK: false, want: "低于最低兼容版本"},
		{name: "missing standard version", versionOut: "bridge starting", wantOK: false, want: "版本无法解析"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			bridge := filepath.Join(t.TempDir(), "alleycat-claude-bridge")
			body := "#!/bin/sh\nprintf '%s\\n' " + fmt.Sprintf("%q", test.versionOut) + "\n"
			if err := os.WriteFile(bridge, []byte(body), 0o755); err != nil {
				t.Fatal(err)
			}
			checker := newTestChecker(t, config.Config{Claude: config.ClaudeConfig{Enabled: true, BridgeBin: bridge}})
			check := checker.claudeBridgeCheck(context.Background())
			if check.OK != test.wantOK || !strings.Contains(check.Message, test.want) {
				t.Fatalf("Claude bridge 版本检查异常：%+v", check)
			}
			if !test.wantOK && !strings.Contains(check.Fix, "cargo install") {
				t.Fatalf("不兼容版本应返回可执行修复命令：%+v", check)
			}
		})
	}
}

func TestCheckerCheckPortIncludesManagedAppServerPort(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	listener := listenOnFreePort(t)
	defer listener.Close()

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:0",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://" + listener.Addr().String()},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), true)
	if results.OK {
		t.Fatalf("app-server upstream 端口被占用时 doctor --check-port 应失败：%+v", results)
	}
	if !hasCheckMessage(results, "app-server-port", "端口不可监听") {
		t.Fatalf("应报告 app-server-port 占用：%+v", results.Checks)
	}
}

func TestCheckerFailsWhenCodexAppServerHelpMissingWSFlags(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	writeFakeExecutable(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://127.0.0.1:4222"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("缺少 app-server ws flags 时 doctor 应失败：%+v", results)
	}
	if !hasCheck(results, "codex-app-server") {
		t.Fatalf("应包含 codex-app-server 检查：%+v", results.Checks)
	}
}

func TestSensitiveFileCheckRequiresRegularPrivateFile(t *testing.T) {
	t.Run("secure regular file", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "secret")
		if err := os.WriteFile(path, []byte("secret"), 0o600); err != nil {
			t.Fatal(err)
		}
		check := sensitiveFileCheck("secret", "敏感文件", path)
		if !check.OK {
			t.Fatalf("0600 regular file 应通过：%+v", check)
		}
	})

	t.Run("group or other permissions", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "secret")
		if err := os.WriteFile(path, []byte("secret"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o644); err != nil {
			t.Fatal(err)
		}
		check := sensitiveFileCheck("secret", "敏感文件", path)
		if check.OK || !strings.Contains(check.Message, "权限过宽") {
			t.Fatalf("group/other 有权限时应失败：%+v", check)
		}
	})

	t.Run("directory", func(t *testing.T) {
		check := sensitiveFileCheck("secret", "敏感文件", t.TempDir())
		if check.OK || !strings.Contains(check.Message, "regular file") {
			t.Fatalf("目录不应被当成敏感文件：%+v", check)
		}
	})

	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "target")
		link := filepath.Join(dir, "link")
		if err := os.WriteFile(target, []byte("secret"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		check := sensitiveFileCheck("secret", "敏感文件", link)
		if check.OK || !strings.Contains(check.Message, "符号链接") {
			t.Fatalf("符号链接不应通过：%+v", check)
		}
	})

	t.Run("missing", func(t *testing.T) {
		check := sensitiveFileCheck("secret", "敏感文件", filepath.Join(t.TempDir(), "missing"))
		if check.OK || !strings.Contains(check.Message, "不存在") {
			t.Fatalf("缺失文件应失败：%+v", check)
		}
	})
}

func TestCheckerChecksConfigAndManagedAppServerTokenFiles(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	tokenPath := filepath.Join(t.TempDir(), "app-server-token")
	if err := os.WriteFile(configPath, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tokenPath, []byte("upstream-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		AppServer: config.AppServerConfig{Transport: "ws", Managed: true, WSTokenFile: tokenPath},
	}
	checker := NewChecker("test", cfg, &projects.Registry{}, configPath)

	configCheck := checker.configFileCheck()
	tokenCheck := checker.appServerTokenFileCheck()
	if !configCheck.OK || !tokenCheck.OK {
		t.Fatalf("0600 配置与 token file 应通过：config=%+v token=%+v", configCheck, tokenCheck)
	}
	results := checker.Run(context.Background(), false)
	if !hasCheck(results, "config-file") || !hasCheck(results, "app-server-token-file") {
		t.Fatalf("doctor Run 应包含两个敏感文件检查：%+v", results.Checks)
	}

	if err := os.Chmod(tokenPath, 0o640); err != nil {
		t.Fatal(err)
	}
	tokenCheck = checker.appServerTokenFileCheck()
	if tokenCheck.OK || !strings.Contains(tokenCheck.Message, "权限过宽") {
		t.Fatalf("token file group 可读时应失败：%+v", tokenCheck)
	}

	cfg.AppServer.WSTokenFile = ""
	missingTokenChecker := NewChecker("test", cfg, &projects.Registry{}, configPath)
	missingCheck := missingTokenChecker.appServerTokenFileCheck()
	if missingCheck.OK || !strings.Contains(missingCheck.Message, "未配置") {
		t.Fatalf("托管 app-server 缺少 token file 应失败：%+v", missingCheck)
	}
}

func hasCheck(results Results, name string) bool {
	for _, check := range results.Checks {
		if check.Name == name {
			return true
		}
	}
	return false
}

func hasCheckMessage(results Results, name, want string) bool {
	for _, check := range results.Checks {
		if check.Name == name && strings.Contains(check.Message, want) {
			return true
		}
	}
	return false
}

func newTestChecker(t *testing.T, cfg config.Config) *Checker {
	t.Helper()
	if cfg.AppServer.Managed && strings.TrimSpace(cfg.AppServer.WSTokenFile) == "" {
		tokenPath := filepath.Join(t.TempDir(), "app-server-token")
		if err := os.WriteFile(tokenPath, []byte("test-upstream-token"), 0o600); err != nil {
			t.Fatal(err)
		}
		cfg.AppServer.WSTokenFile = tokenPath
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	return NewChecker("test-version", cfg, registry)
}

func listenOnFreePort(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return listener
}

func writeFakeExecutable(t *testing.T, path string) {
	t.Helper()
	// doctor 只需要 LookPath 能找到命令；脚本内容保持最小，避免测试依赖真实 CLI。
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeFakeCodexWithAppServerHelp(t *testing.T, path string) {
	t.Helper()
	body := `#!/bin/sh
if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
  printf '%s\n' '--listen --ws-auth --ws-token-file'
  exit 0
fi
exit 0
`
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

package doctor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

type fakeDoctorSSHTransport struct {
	checkErr error
	readyErr error
}

func (f fakeDoctorSSHTransport) CheckRemoteCodex(context.Context) (string, error) {
	return "0.149.1", f.checkErr
}
func (f fakeDoctorSSHTransport) EnsureReady(context.Context) error { return f.readyErr }
func (fakeDoctorSSHTransport) SSHCheckCommand() string             { return "ssh 127.0.0.1 codex --version" }

func TestMain(m *testing.M) {
	newDoctorSSHTransport = func(appserver.SSHTransportOptions) (doctorSSHTransport, error) {
		return fakeDoctorSSHTransport{}, nil
	}
	os.Exit(m.Run())
}

func TestCheckerRunAndPrintDoNotLeakToken(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	codexPath = writeFakeCodexWithAppServerHelp(t, codexPath)
	writeFakeExecutable(t, filepath.Join(binDir, "tailscale"))
	t.Setenv("PATH", binDir)

	secret := "0123456789abcdef0123456789abcdef"
	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: secret},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
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
	codexPath = writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
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

func TestCheckerRunReadinessSkipsExternalProcessDiagnostics(t *testing.T) {
	checker := newTestChecker(t, config.Config{
		Listen:  "127.0.0.1:8787",
		Auth:    config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime: config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{
			Transport: "ssh",
			SSHTarget: "127.0.0.1",
		},
		Codex:  config.CodexConfig{Bin: filepath.Join(t.TempDir(), "missing-codex")},
		Claude: config.ClaudeConfig{Enabled: true, BridgeBin: filepath.Join(t.TempDir(), "missing-bridge")},
		Projects: []config.ProjectConfig{{
			ID: "demo", Name: "Demo", Path: t.TempDir(),
		}},
	})

	results := checker.RunReadiness(context.Background())
	if !results.OK {
		t.Fatalf("外部诊断不可用不应阻断当前 readiness：%+v", results)
	}
	for _, excluded := range []string{"codex", "codex-app-server", "claude-bridge", "tailscale", "macos-code-signing"} {
		if hasCheck(results, excluded) {
			t.Fatalf("readiness 不应执行或返回完整诊断项 %q：%+v", excluded, results.Checks)
		}
	}
	for _, required := range []string{"token", "projects", "runtime", "app-server"} {
		if !hasCheck(results, required) {
			t.Fatalf("readiness 缺少关键静态检查 %q：%+v", required, results.Checks)
		}
	}
}

func TestDesignatedRequirementRejectsPerBuildCDHash(t *testing.T) {
	tests := []struct {
		name   string
		output string
		stable bool
	}{
		{
			name:   "go linker ad-hoc signature",
			output: `# designated => cdhash H"716c95a0649b65115acda41d95f1e30c58a8582c"`,
			stable: false,
		},
		{
			name:   "apple development identity",
			output: `designated => identifier "agentd" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Example"`,
			stable: true,
		},
		{
			name: "developer id identity",
			output: `Executable=/opt/homebrew/bin/agentd
designated => identifier "agentd" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID"`,
			stable: true,
		},
		{name: "missing requirement", output: "Signature=adhoc", stable: false},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			requirement := designatedRequirement(testCase.output)
			if got := isStableDesignatedRequirement(requirement); got != testCase.stable {
				t.Fatalf("稳定代码身份判定错误：requirement=%q got=%v want=%v", requirement, got, testCase.stable)
			}
		})
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
	codexPath = writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
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
	codexPath = writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "-oBad"},
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

func TestCheckerRejectsNonSSHAppServer(t *testing.T) {
	binDir := t.TempDir()
	codexPath := writeFakeCodexWithAppServerHelp(t, filepath.Join(binDir, "codex"))
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ws", SSHTarget: "127.0.0.1"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID: "demo", Name: "Demo", Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("non-SSH App Server must not pass doctor: %+v", results)
	}
	for _, check := range results.Checks {
		if check.Name == "app-server" && !check.OK && strings.Contains(check.Fix, "transport") {
			return
		}
	}
	t.Fatalf("doctor must explain the SSH-only boundary: %+v", results.Checks)
}

func TestCheckerReportsManagedWSGatewayForAppServerRuntime(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	codexPath = writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
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
		{name: "compatible", versionOut: "alleycat-claude-bridge 0.2.8", wantOK: true, want: "0.2.8 可用"},
		{name: "too old", versionOut: "alleycat-claude-bridge 0.2.0", wantOK: false, want: "低于最低兼容版本"},
		{name: "missing standard version", versionOut: "bridge starting", wantOK: false, want: "版本无法解析"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			bridge := filepath.Join(t.TempDir(), "alleycat-claude-bridge")
			if runtime.GOOS == "windows" {
				bridge += ".cmd"
			}
			body := "#!/bin/sh\nprintf '%s\\n' " + fmt.Sprintf("%q", test.versionOut) + "\n"
			if runtime.GOOS == "windows" {
				body = "@echo off\r\necho " + test.versionOut + "\r\n"
			}
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

func TestClaudeBridgeCheckFallsBackToBundledCopy(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("a bundled bridge is a real .exe on Windows; command-script fakes use .cmd")
	}
	executable, err := os.Executable()
	if err != nil {
		t.Skip("拿不到测试可执行文件路径")
	}
	if resolved, resolveErr := filepath.EvalSymlinks(executable); resolveErr == nil {
		executable = resolved
	}
	sibling := filepath.Join(filepath.Dir(executable), claudebridge.BinaryName)
	if _, err := os.Stat(sibling); err == nil {
		t.Skip("测试二进制旁已存在同名文件，跳过以免干扰")
	}
	body := []byte("#!/bin/sh\nprintf 'alleycat-claude-bridge 0.2.8\\n'\n")
	if runtime.GOOS == "windows" {
		body = []byte("@echo off\r\necho alleycat-claude-bridge 0.2.8\r\n")
	}
	if err := os.WriteFile(
		sibling,
		body,
		0o755,
	); err != nil {
		t.Skip("无法在测试二进制旁写入：" + err.Error())
	}
	t.Cleanup(func() { _ = os.Remove(sibling) })

	checker := newTestChecker(t, config.Config{
		Claude: config.ClaudeConfig{
			Enabled:   true,
			BridgeBin: filepath.Join(t.TempDir(), "stale-bridge-path"),
		},
	})
	check := checker.claudeBridgeCheck(context.Background())
	if !check.OK || !strings.Contains(check.Message, "0.2.8 可用") {
		t.Fatalf("Doctor 应回退检查 Mac App 随包 bridge：%+v", check)
	}
}

func TestCheckerCheckPortDoesNotProbeSharedAppServerPort(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	codexPath = writeFakeCodexWithAppServerHelp(t, codexPath)
	t.Setenv("PATH", binDir)

	listener := listenOnFreePort(t)
	defer listener.Close()

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:0",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})

	results := checker.Run(context.Background(), true)
	if !results.OK {
		t.Fatalf("SSH App Server 没有本地 TCP listen 端口，不应阻断 doctor：%+v", results)
	}
	if hasCheck(results, "app-server-port") {
		t.Fatalf("不应再检查已删除的 WS listen 端口：%+v", results.Checks)
	}
}

func TestCheckerFailsWhenSSHInitializeFails(t *testing.T) {
	binDir := t.TempDir()
	codexPath := filepath.Join(binDir, "codex")
	codexPath = writeFakeExecutable(t, codexPath)
	t.Setenv("PATH", binDir)

	checker := newTestChecker(t, config.Config{
		Listen:    "127.0.0.1:8787",
		Auth:      config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
		Codex:     config.CodexConfig{Bin: codexPath},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: t.TempDir(),
		}},
	})
	previous := newDoctorSSHTransport
	newDoctorSSHTransport = func(appserver.SSHTransportOptions) (doctorSSHTransport, error) {
		return fakeDoctorSSHTransport{readyErr: context.DeadlineExceeded}, nil
	}
	defer func() { newDoctorSSHTransport = previous }()

	results := checker.Run(context.Background(), false)
	if results.OK {
		t.Fatalf("SSH proxy initialize 失败时 doctor 应失败：%+v", results)
	}
	if !hasCheck(results, "codex-app-server") {
		t.Fatalf("应包含 codex-app-server 检查：%+v", results.Checks)
	}
}

func TestCheckerFailsWhenRemoteCodexVersionIsUnsupported(t *testing.T) {
	checker := newTestChecker(t, config.Config{
		Listen: "127.0.0.1:8787", Auth: config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Runtime:   config.RuntimeConfig{Type: "codex_app_server"},
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
		Projects:  []config.ProjectConfig{{ID: "demo", Name: "Demo", Path: t.TempDir()}},
	})
	previous := newDoctorSSHTransport
	newDoctorSSHTransport = func(appserver.SSHTransportOptions) (doctorSSHTransport, error) {
		return fakeDoctorSSHTransport{checkErr: errors.New("远端 Codex 0.149.0 低于最低兼容版本 0.149.1")}, nil
	}
	defer func() { newDoctorSSHTransport = previous }()

	results := checker.Run(context.Background(), false)
	if results.OK || !hasCheck(results, "codex-app-server") {
		t.Fatalf("远端 Codex 版本不足必须让 doctor 失败：%+v", results)
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
		if runtime.GOOS == "windows" {
			t.Skip("Windows ACLs do not expose POSIX mode bits")
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
			if runtime.GOOS == "windows" {
				t.Skip("Windows symlink creation requires Developer Mode or elevation")
			}
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

func TestCheckerChecksConfigFileWithoutLegacyAppServerToken(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(configPath, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "127.0.0.1"},
	}
	checker := NewChecker("test", cfg, &projects.Registry{}, configPath)

	configCheck := checker.configFileCheck()
	if !configCheck.OK {
		t.Fatalf("0600 配置应通过：config=%+v", configCheck)
	}
	results := checker.Run(context.Background(), false)
	if !hasCheck(results, "config-file") || hasCheck(results, "app-server-token-file") {
		t.Fatalf("doctor Run 不应再检查已删除的 token file：%+v", results.Checks)
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
	if strings.TrimSpace(cfg.AppServer.Transport) == "" {
		cfg.AppServer.Transport = "ssh"
	}
	if strings.TrimSpace(cfg.AppServer.SSHTarget) == "" {
		cfg.AppServer.SSHTarget = "127.0.0.1"
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

func writeFakeExecutable(t *testing.T, path string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		path += ".cmd"
		if err := os.WriteFile(path, []byte("@echo off\r\nexit /b 0\r\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	// doctor 只需要 LookPath 能找到命令；脚本内容保持最小，避免测试依赖真实 CLI。
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeFakeCodexWithAppServerHelp(t *testing.T, path string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		path += ".cmd"
		body := "@echo off\r\nif \"%~1\"==\"--version\" echo codex-cli 0.149.0\r\nif \"%~1\"==\"app-server\" if \"%~2\"==\"--help\" echo --listen --ws-auth --ws-token-file\r\nexit /b 0\r\n"
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
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
	return path
}

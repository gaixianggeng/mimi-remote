package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadMergesExplicitAndScannedProjects(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "app")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".hidden"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "node_modules"), 0o755); err != nil {
		t.Fatal(err)
	}

	cfgPath := filepath.Join(t.TempDir(), "config.json")
	raw, err := json.Marshal(map[string]any{
		"auth": AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		"projects": []ProjectConfig{{
			ID:   "explicit-app",
			Name: "Explicit App",
			Path: appDir,
		}},
		"scan_roots": []string{root},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfgPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	clearAgentdEnv(t)

	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}

	if len(cfg.Projects) != 2 {
		t.Fatalf("期望 explicit app + scan root 两个项目，实际 %+v", cfg.Projects)
	}
	if cfg.Projects[0].ID != "explicit-app" {
		t.Fatalf("显式项目应保持优先级，实际 %+v", cfg.Projects[0])
	}
	if cfg.Projects[1].Path != root {
		t.Fatalf("扫描根目录未规范化加入：%+v", cfg.Projects)
	}
	for _, project := range cfg.Projects {
		if project.Name == ".hidden" || project.Name == "node_modules" {
			t.Fatalf("扫描目录应跳过隐藏目录和依赖目录：%+v", cfg.Projects)
		}
	}
}

func TestLoadMigratesLegacyStdioTransportToWS(t *testing.T) {
	projectDir := t.TempDir()
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	raw, err := json.Marshal(map[string]any{
		"auth":       AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		"runtime":    map[string]any{"type": "pty", "fallback_pty": true},
		"app_server": map[string]any{"transport": "stdio", "managed": true},
		"projects":   []ProjectConfig{{ID: "demo", Name: "Demo", Path: projectDir}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfgPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	clearAgentdEnv(t)

	// 旧配置（pty + stdio，且没有 listen）不能再让 Load/Validate 直接失败，必须平滑迁移到 ws gateway。
	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatalf("旧 stdio 配置应平滑迁移而不是报错：%v", err)
	}
	if cfg.Runtime.Type != "codex_app_server" {
		t.Fatalf("runtime.type 应迁移为 codex_app_server，实际 %q", cfg.Runtime.Type)
	}
	if cfg.AppServer.Transport != "ws" {
		t.Fatalf("app_server.transport 应迁移为 ws，实际 %q", cfg.AppServer.Transport)
	}
	if cfg.AppServer.Listen != defaultAppServerListen {
		t.Fatalf("迁移后缺失的 listen 应补默认 loopback upstream，实际 %q", cfg.AppServer.Listen)
	}
}

func TestLoadEnvListenPrecedenceAndSessionBuffer(t *testing.T) {
	projectDir := t.TempDir()
	clearAgentdEnv(t)
	t.Setenv("AGENTD_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("AGENTD_PROJECTS", projectDir)
	t.Setenv("AGENTD_BIND", "0.0.0.0")
	t.Setenv("AGENTD_PORT", "9999")
	t.Setenv("AGENTD_LISTEN", "127.0.0.1:7777")
	t.Setenv("AGENTD_OUTPUT_BUFFER_BYTES", "4096")
	t.Setenv("AGENTD_ALLOW_QUERY_TOKEN", "1")
	t.Setenv("AGENTD_APP_SERVER_TRANSPORT", "ws")
	t.Setenv("AGENTD_APP_SERVER_MANAGED", "true")
	t.Setenv("AGENTD_APP_SERVER_WS_TOKEN_FILE", "/tmp/codex-app-server-ws-token")
	t.Setenv("AGENTD_DEBUG_CODEX_HISTORY", "true")
	t.Setenv("AGENTD_CODEX_TRANSCRIPTION_BASE_URL", "https://chatgpt.com/backend-api")
	t.Setenv("AGENTD_CODEX_AUTH_FILE", filepath.Join(t.TempDir(), "auth.json"))

	cfg, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Listen != "127.0.0.1:7777" {
		t.Fatalf("AGENTD_LISTEN 应优先于 bind/port，实际 %q", cfg.Listen)
	}
	if cfg.Session.OutputBufferBytes != 4096 {
		t.Fatalf("输出缓冲区环境变量未生效：%d", cfg.Session.OutputBufferBytes)
	}
	if !cfg.Auth.AllowQueryToken {
		t.Fatal("AGENTD_ALLOW_QUERY_TOKEN=1 应启用 query token 兼容模式")
	}
	if cfg.Runtime.Type != "codex_app_server" {
		t.Fatalf("runtime 环境变量解析异常：%+v", cfg.Runtime)
	}
	if cfg.AppServer.Transport != "ws" || !cfg.AppServer.Managed || cfg.AppServer.WSTokenFile != "/tmp/codex-app-server-ws-token" {
		t.Fatalf("app_server 环境变量解析异常：%+v", cfg.AppServer)
	}
	if cfg.Voice.CodexTranscriptionBaseURL != "https://chatgpt.com/backend-api" || cfg.Voice.CodexAuthFile == "" {
		t.Fatalf("voice 环境变量解析异常：%+v", cfg.Voice)
	}
	if !cfg.Debug.EnableCodexHistory {
		t.Fatal("AGENTD_DEBUG_CODEX_HISTORY=true 应启用 Codex history debug endpoint")
	}
	if len(cfg.Projects) != 1 || cfg.Projects[0].Path != projectDir {
		t.Fatalf("项目环境变量解析异常：%+v", cfg.Projects)
	}
}

func TestLoadBrowseRootsFromFileAndEnv(t *testing.T) {
	projectDir := t.TempDir()
	browseDir := t.TempDir()
	clearAgentdEnv(t)
	t.Setenv("AGENTD_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("AGENTD_PROJECTS", projectDir)

	cfgPath := filepath.Join(t.TempDir(), "config.json")
	raw := fmt.Sprintf(`{"browse_roots": [%q]}`, browseDir)
	if err := os.WriteFile(cfgPath, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.BrowseRoots) != 1 || cfg.BrowseRoots[0] != browseDir {
		t.Fatalf("browse_roots 应从配置文件读取：%+v", cfg.BrowseRoots)
	}
	if len(cfg.Projects) != 1 {
		t.Fatalf("browse_roots 不应参与项目发现：%+v", cfg.Projects)
	}

	envDir := t.TempDir()
	t.Setenv("AGENTD_BROWSE_ROOTS", envDir+", "+browseDir)
	cfg, err = Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.BrowseRoots) != 2 || cfg.BrowseRoots[0] != envDir || cfg.BrowseRoots[1] != browseDir {
		t.Fatalf("AGENTD_BROWSE_ROOTS 应覆盖配置文件：%+v", cfg.BrowseRoots)
	}
}

func TestValidateAcceptsDevInsecureWithoutToken(t *testing.T) {
	cfg := defaults()
	cfg.DevInsecure = true
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("开发模式应允许无 token：%v", err)
	}
}

func TestValidateRejectsDevInsecureOnNonLoopbackListen(t *testing.T) {
	for _, listen := range []string{
		"0.0.0.0:8787",
		"127.example.com:8787",
		"127.0.0.1.evil:8787",
	} {
		t.Run(listen, func(t *testing.T) {
			cfg := defaults()
			cfg.DevInsecure = true
			cfg.Listen = listen
			cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

			if err := cfg.Validate(); err == nil {
				t.Fatal("dev_insecure 不应允许非 loopback listen")
			}
		})
	}

	for _, listen := range []string{
		"localhost:8787",
		"127.0.0.1:8787",
		"[::1]:8787",
	} {
		t.Run(listen, func(t *testing.T) {
			cfg := defaults()
			cfg.DevInsecure = true
			cfg.Listen = listen
			cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

			if err := cfg.Validate(); err != nil {
				t.Fatalf("dev_insecure 应允许 loopback listen：%v", err)
			}
		})
	}
}

func TestValidateRejectsShortToken(t *testing.T) {
	cfg := defaults()
	cfg.Auth.Token = "short"
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

	if err := cfg.Validate(); err == nil {
		t.Fatal("期望短 token 被拒绝")
	}
}

func TestValidateRejectsUnsafeAppServerListen(t *testing.T) {
	cfg := defaults()
	cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
	cfg.Runtime.Type = "codex_app_server"
	cfg.AppServer.Transport = "ws"
	cfg.AppServer.Listen = "0.0.0.0:8390"
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

	if err := cfg.Validate(); err == nil {
		t.Fatal("非 loopback app-server ws 监听应被拒绝")
	}

	cfg.AppServer.Listen = "127.0.0.1.evil:8390"
	if err := cfg.Validate(); err == nil {
		t.Fatal("伪 loopback hostname 不应允许作为 app-server ws 监听")
	}

	cfg.AppServer.Listen = "127.0.0.1:8390"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("loopback app-server ws 监听应允许用于本机调试：%v", err)
	}
}

func TestValidateAcceptsSafeActions(t *testing.T) {
	cfg := defaults()
	cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	cfg.Actions = []ActionConfig{{
		ID:             "go-test",
		Name:           "Go Test",
		Command:        "go",
		Args:           []string{"test", "./..."},
		WorkingDir:     ".",
		TimeoutSeconds: 30,
		// 高风险动作可要求 iPad 端二次确认；它不改变后端 allowlist 安全边界。
		RequiresConfirmation: true,
	}}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("安全 action 配置应允许：%v", err)
	}
}

func TestValidateRejectsUnsafeActions(t *testing.T) {
	base := defaults()
	base.Auth.Token = "0123456789abcdef0123456789abcdef"
	base.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}

	cases := []ActionConfig{
		{ID: "", Name: "Empty", Command: "go"},
		{ID: "bad id", Name: "Bad", Command: "go"},
		{ID: "dup", Name: "Dup", Command: "go"},
		{ID: "unsafe-command", Name: "Unsafe", Command: "go test"},
		{ID: "bad-timeout", Name: "Timeout", Command: "go", TimeoutSeconds: 121},
	}
	for _, action := range cases {
		t.Run(action.ID+"-"+action.Name, func(t *testing.T) {
			cfg := base
			if action.ID == "dup" {
				cfg.Actions = []ActionConfig{
					{ID: "dup", Name: "One", Command: "go"},
					{ID: "dup", Name: "Two", Command: "go"},
				}
			} else {
				cfg.Actions = []ActionConfig{action}
			}
			if err := cfg.Validate(); err == nil {
				t.Fatalf("不安全 action 应被拒绝：%+v", cfg.Actions)
			}
		})
	}
}

func clearAgentdEnv(t *testing.T) {
	t.Helper()
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

package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

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
	if result.AppServerTokenFile == "" {
		t.Fatal("应生成独立 app-server upstream token file")
	}
	if _, err := os.Stat(result.AppServerTokenFile); err != nil {
		t.Fatalf("app-server token file 不存在：%v", err)
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
	if cfg.AppServer.Transport != "ws" || !cfg.AppServer.Managed || cfg.AppServer.Listen != "ws://127.0.0.1:4222" {
		t.Fatalf("setup 应默认启用 managed ws gateway：%+v", cfg.AppServer)
	}
	if len(cfg.ScanRoots) != 1 || cfg.ScanRoots[0] != scanRoot {
		t.Fatalf("scan root 未写入配置：%+v", cfg.ScanRoots)
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
	firstUpstreamToken, err := os.ReadFile(first.AppServerTokenFile)
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
	secondUpstreamToken, err := os.ReadFile(second.AppServerTokenFile)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(secondUpstreamToken, firstUpstreamToken) {
		t.Fatal("未 force 时不能轮换正在运行服务使用的 upstream token")
	}
}

func TestRepairManagedWSTokenFileReplacesMissingConfiguredPath(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	missingPath := filepath.Join(dir, "deleted-upstream-token")
	raw, err := json.Marshal(map[string]any{
		"app_server": map[string]any{
			"transport":     "ws",
			"managed":       true,
			"listen":        "ws://127.0.0.1:4222",
			"ws_token_file": missingPath,
			"future_option": "keep-me",
		},
		"future_root": map[string]any{"enabled": true},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfgPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	tokenPath, repaired, err := RepairManagedWSTokenFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if !repaired || tokenPath == "" || tokenPath == missingPath {
		t.Fatalf("缺失的旧 token file 应替换为新的独立文件：path=%q repaired=%v", tokenPath, repaired)
	}
	assertPrivateTokenFile(t, tokenPath)

	updated, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(updated, &document); err != nil {
		t.Fatal(err)
	}
	appServer := document["app_server"].(map[string]any)
	if appServer["ws_token_file"] != tokenPath || appServer["future_option"] != "keep-me" {
		t.Fatalf("修复应只替换 token 路径并保留未知字段：%+v", appServer)
	}
	if _, ok := document["future_root"]; !ok {
		t.Fatalf("修复不能丢失未来新增的根字段：%+v", document)
	}
}

func TestRepairManagedWSTokenFileFailureKeepsOldConfigAndCleansTemporaryFiles(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	original := []byte("{\n  \"app_server\": {\"transport\": \"stdio\", \"managed\": true},\n  \"future_root\": \"keep-me\"\n}\n")
	if err := os.WriteFile(cfgPath, original, 0o600); err != nil {
		t.Fatal(err)
	}

	sentinel := errors.New("injected rename failure")
	_, repaired, err := repairManagedWSTokenFile(cfgPath, func(path string, raw []byte) error {
		return writePrivateFileAtomicallyWithRename(path, raw, func(string, string) error {
			return sentinel
		})
	})
	if !errors.Is(err, sentinel) || repaired {
		t.Fatalf("注入 rename 失败时应返回原错误且不报告成功：repaired=%v err=%v", repaired, err)
	}
	after, readErr := os.ReadFile(cfgPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(after, original) {
		t.Fatalf("原子提交失败后旧配置必须逐字节不变：\n%s", after)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.Name() != filepath.Base(cfgPath) {
			t.Fatalf("失败后必须清理新 token 和配置临时文件，残留：%s", entry.Name())
		}
	}
}

func TestRepairManagedWSTokenFileRejectsSymlinkAndDirectory(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		create func(t *testing.T, dir string) string
	}{
		{
			name: "symlink",
			create: func(t *testing.T, dir string) string {
				t.Helper()
				target := filepath.Join(dir, "real-token")
				if err := os.WriteFile(target, []byte("do-not-touch"), 0o600); err != nil {
					t.Fatal(err)
				}
				link := filepath.Join(dir, "token-link")
				if err := os.Symlink(target, link); err != nil {
					t.Fatal(err)
				}
				return link
			},
		},
		{
			name: "directory",
			create: func(t *testing.T, dir string) string {
				t.Helper()
				path := filepath.Join(dir, "token-dir")
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
				return path
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			dir := t.TempDir()
			tokenPath := testCase.create(t, dir)
			cfgPath := filepath.Join(dir, "config.json")
			raw, err := json.Marshal(map[string]any{
				"app_server": map[string]any{"ws_token_file": tokenPath},
				"auth":       map[string]any{"token": "keep-auth-token"},
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(cfgPath, raw, 0o600); err != nil {
				t.Fatal(err)
			}

			_, repaired, err := RepairManagedWSTokenFile(cfgPath)
			if err == nil || repaired || !strings.Contains(err.Error(), "regular file") {
				t.Fatalf("%s 必须 fail-closed：repaired=%v err=%v", testCase.name, repaired, err)
			}
			after, err := os.ReadFile(cfgPath)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(after, raw) {
				t.Fatalf("拒绝危险 token 路径时不能改写配置：%s", after)
			}
		})
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
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
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

package appserver

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestManagedProcessStartsCodexAppServerStdioAndInitializes(t *testing.T) {
	dir := t.TempDir()
	argLog := filepath.Join(dir, "args.log")
	fakeCodex := writeFakeCodexAppServer(t, dir, `
printf '%s\n' "$@" > "$FAKE_CODEX_ARG_LOG"
echo 'warning: token=super-secret' >&2
while IFS= read -r line; do
  case "$line" in
	    *'"method":"initialize"'*) printf '{"id":1,"result":{"userAgent":"fake-managed","platformFamily":"macos"}}\n' ;;
	    *'"method":"initialized"'*) ;;
	    *'"method":"thread/list"'*) printf '{"id":2,"result":{"data":[]}}\n' ;;
	  esac
done
	`)

	startCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	process, result, err := StartManaged(startCtx, ManagedOptions{
		CodexBin:   fakeCodex,
		Env:        map[string]string{"FAKE_CODEX_ARG_LOG": argLog},
		ClientInfo: ClientInfo{Name: "mimi_remote", Title: "Mimi Remote", Version: "test"},
	})
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer shutdownCancel()
		if err := process.Shutdown(shutdownCtx); err != nil {
			t.Fatalf("shutdown 失败：%v", err)
		}
	}()

	if result.UserAgent != "fake-managed" {
		t.Fatalf("initialize result 异常：%+v", result)
	}
	// startCtx 只控制握手，取消后托管子进程仍应存活并能继续处理 RPC。
	callCtx, callCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer callCancel()
	var list struct {
		Data []any `json:"data"`
	}
	if err := process.Client().Call(callCtx, "thread/list", map[string]any{}, &list); err != nil {
		t.Fatalf("取消握手 ctx 后 app-server 子进程不应退出：%v", err)
	}
	args, err := os.ReadFile(argLog)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(args)); got != "app-server\n--listen\nstdio://" {
		t.Fatalf("fake codex 参数应为 app-server --listen stdio://，got=%q", got)
	}
	waitFor(t, func() bool {
		diag := process.Diagnostics()
		return diag.Initialized && len(diag.StderrTail) > 0
	}, "等待 managed diagnostics ready")
	for _, line := range process.Diagnostics().StderrTail {
		if strings.Contains(line, "super-secret") {
			t.Fatalf("stderr 诊断不应泄漏敏感值：%v", process.Diagnostics().StderrTail)
		}
	}
}

func TestManagedProcessNotReadyWhenHandshakeFails(t *testing.T) {
	dir := t.TempDir()
	fakeCodex := writeFakeCodexAppServer(t, dir, `
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*) printf '{"id":1,"error":{"code":500,"message":"handshake failed"}}\n'; sleep 1; exit 0 ;;
  esac
done
`)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	process, _, err := StartManaged(ctx, ManagedOptions{CodexBin: fakeCodex})
	if err == nil {
		if process != nil {
			_ = process.Shutdown(context.Background())
		}
		t.Fatal("initialize 返回错误时 StartManaged 应失败")
	}
	if !strings.Contains(err.Error(), "handshake failed") {
		t.Fatalf("错误信息应包含握手失败原因，got=%v", err)
	}
}

func TestBuildManagedEnvFiltersLegacyDesktopTransportAndOverlaysConfiguredValues(t *testing.T) {
	t.Setenv("CODEX_APP_SERVER_USE_LOCAL_DAEMON", "1")
	t.Setenv("CODEX_APP_SERVER_WS_URL", "ws://desktop-only.invalid")
	t.Setenv("MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH", "desktop-owner-token")
	t.Setenv("MIMI_MANAGED_ENV_TEST", "inherited")
	t.Setenv("CODEX_HOME", "/inherited/codex")

	env := buildManagedEnv(map[string]string{
		"CODEX_APP_SERVER_USE_LOCAL_DAEMON":         "1",
		"CODEX_APP_SERVER_WS_URL":                   "ws://still-blocked.invalid",
		"MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH": "still-blocked-owner-token",
		"MIMI_MANAGED_ENV_TEST":                     "configured",
		"CODEX_HOME":                                "/configured/codex",
	})
	values := map[string]string{}
	counts := map[string]int{}
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		values[key] = value
		counts[key]++
	}
	for _, key := range []string{
		"CODEX_APP_SERVER_USE_LOCAL_DAEMON",
		"CODEX_APP_SERVER_WS_URL",
		"MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH",
	} {
		if _, exists := values[key]; exists {
			t.Fatalf("旧 Desktop transport 环境不能泄漏到受管 App Server：%s", key)
		}
	}
	if values["MIMI_MANAGED_ENV_TEST"] != "configured" || counts["MIMI_MANAGED_ENV_TEST"] != 1 {
		t.Fatalf("显式配置应唯一覆盖继承值：value=%q count=%d", values["MIMI_MANAGED_ENV_TEST"], counts["MIMI_MANAGED_ENV_TEST"])
	}
	if values["CODEX_HOME"] != "/configured/codex" || counts["CODEX_HOME"] != 1 {
		t.Fatalf("CODEX_HOME 必须沿用显式配置且不重复：value=%q count=%d", values["CODEX_HOME"], counts["CODEX_HOME"])
	}
}

func writeFakeCodexAppServer(t *testing.T, dir, body string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake app-server shell scripts are Unix-only")
	}
	path := filepath.Join(dir, "codex")
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

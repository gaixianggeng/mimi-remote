package appserver

import (
	"context"
	"os"
	"os/exec"
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

func TestManagedWebSocketProcessStartsWithTokenFile(t *testing.T) {
	dir := t.TempDir()
	argLog := filepath.Join(dir, "args.log")
	tokenFile := filepath.Join(dir, "ws-token")
	if err := os.WriteFile(tokenFile, []byte("capability-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	fakeCodex := writeFakeCodexAppServer(t, dir, `
printf '%s\n' "$@" > "$FAKE_CODEX_ARG_LOG"
echo 'warning: authorization bearer secret' >&2
while true; do sleep 1; done
`)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	process, err := StartManagedWebSocket(ctx, ManagedWebSocketOptions{
		CodexBin:       fakeCodex,
		Env:            map[string]string{"FAKE_CODEX_ARG_LOG": argLog},
		Listen:         "ws://127.0.0.1:4222",
		WSTokenFile:    tokenFile,
		EarlyExitGrace: 100 * time.Millisecond,
	})
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if process.StartedAt().IsZero() || time.Since(process.StartedAt()) > time.Minute {
		t.Fatalf("managed Codex 应记录当前子进程启动时间：%s", process.StartedAt())
	}
	defer func() {
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer shutdownCancel()
		if err := process.Shutdown(shutdownCtx); err != nil {
			t.Fatalf("shutdown 失败：%v", err)
		}
	}()

	want := "app-server\n--listen\nws://127.0.0.1:4222\n--ws-auth\ncapability-token\n--ws-token-file\n" + tokenFile
	var got string
	// shell 重定向会先创建文件再逐项写入参数，必须等待内容完整，不能只等待文件出现。
	waitFor(t, func() bool {
		args, err := os.ReadFile(argLog)
		if err != nil {
			return false
		}
		got = strings.TrimSpace(string(args))
		return got == want
	}, "等待 fake codex 写入完整参数")
	if got != want {
		t.Fatalf("fake codex 参数异常，got=%q want=%q", got, want)
	}
	waitFor(t, func() bool {
		return len(process.Diagnostics().StderrTail) > 0
	}, "等待 managed ws diagnostics ready")
	for _, line := range process.Diagnostics().StderrTail {
		if strings.Contains(line, "secret") {
			t.Fatalf("stderr 诊断不应泄漏敏感值：%v", process.Diagnostics().StderrTail)
		}
	}
}

func TestManagedWebSocketProcessFailsWhenProcessExitsEarly(t *testing.T) {
	falseBin := writeCodexThatExitsEarly(t)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	process, err := StartManagedWebSocket(ctx, ManagedWebSocketOptions{
		CodexBin:       falseBin,
		Listen:         "ws://127.0.0.1:4222",
		EarlyExitGrace: 2 * time.Second,
	})
	if err == nil {
		if process != nil {
			_ = process.Shutdown(context.Background())
		}
		t.Fatal("app-server 立即退出时 StartManagedWebSocket 应失败")
	}
	if !strings.Contains(err.Error(), "启动后立即退出") {
		t.Fatalf("错误信息应提示立即退出，got=%v", err)
	}
}

func writeCodexThatExitsEarly(t *testing.T) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		path := filepath.Join(t.TempDir(), "codex-exits-early.cmd")
		body := "@echo off\r\nif \"%~1\"==\"--version\" (\r\n  echo codex-cli 0.149.0\r\n  exit /b 0\r\n)\r\nexit /b 1\r\n"
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	falseBin, err := exec.LookPath("false")
	if err != nil {
		t.Skip("系统缺少 false 命令")
	}
	return falseBin
}

func TestBuildManagedEnvFiltersDesktopTransportAndOverlaysConfiguredValues(t *testing.T) {
	t.Setenv(LocalDaemonEnvironmentKey, "1")
	t.Setenv("CODEX_APP_SERVER_WS_URL", "ws://desktop-only.invalid")
	t.Setenv("MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH", "desktop-owner-token")
	t.Setenv("MIMI_MANAGED_ENV_TEST", "inherited")
	t.Setenv("CODEX_HOME", "/inherited/codex")

	env := buildManagedEnv(map[string]string{
		LocalDaemonEnvironmentKey:                   "1",
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
	if _, exists := values[LocalDaemonEnvironmentKey]; exists {
		t.Fatal("Desktop local-daemon 开关不能泄漏到 agentd 管理的 Codex 子进程")
	}
	if _, exists := values["CODEX_APP_SERVER_WS_URL"]; exists {
		t.Fatal("Desktop 外部 WS URL 不能泄漏到 agentd 管理的 Codex 子进程")
	}
	if _, exists := values["MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH"]; exists {
		t.Fatal("Desktop 环境 ownership token 不能泄漏到 agentd 管理的 Codex 子进程")
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

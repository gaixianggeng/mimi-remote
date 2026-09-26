package httpapi

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestCodexRuntimeLoginCommandQuotesBackendHomeAndExecutable(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Mac 本机登录命令使用 POSIX shell")
	}
	home := filepath.Join(t.TempDir(), "shared home ' $(printf expanded) `printf expanded`")
	bin := filepath.Join(t.TempDir(), "codex tool ' $(printf expanded)")
	// 只执行测试自己的假 CLI，验证 shell 收到的目录和 argv，不进行真实登录。
	script := "#!/bin/sh\nprintf '%s\\000' \"$CODEX_HOME\" \"$#\" \"$1\"\n"
	if err := os.WriteFile(bin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	router := &Router{cfg: config.Config{
		AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: home},
		Codex:     config.CodexConfig{Bin: bin, Env: map[string]string{"CODEX_HOME": "/public-fixture"}},
	}}
	command := router.codexRuntimeLoginCommand()
	output, err := exec.Command("/bin/sh", "-c", command).CombinedOutput()
	if err != nil {
		t.Fatalf("执行测试登录命令失败：%v %s", err, output)
	}
	if got, want := string(output), home+"\x001\x00login\x00"; got != want {
		t.Fatalf("登录命令改变了 backend 目录或参数：got=%q want=%q", got, want)
	}
}

func TestCodexRuntimeLoginCommandSurvivesUnavailableAndDisabledStates(t *testing.T) {
	home := t.TempDir()
	router := &Router{cfg: config.Config{
		AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: home},
	}}
	command := router.codexRuntimeLoginCommand()
	if command == "" || !strings.Contains(command, home) {
		t.Fatal("必须提供共享目录的登录命令")
	}
	if got := router.runtimeStatusPlaceholder().Runtimes[0].LoginCommand; got != command {
		t.Fatal("初次加载状态丢失登录目录")
	}
	if got := router.probeCodexRuntime(context.Background()); got.State != runtimeStateUnavailable || got.LoginCommand != command {
		t.Fatalf("上游不可用时仍需提供正确登录入口：%+v", got)
	}
	disabled := false
	router.cfg.Codex.Enabled = &disabled
	if got := router.probeCodexRuntime(context.Background()); got.State != runtimeStateDisabled || got.LoginCommand != command {
		t.Fatalf("禁用时仍需保留登录入口：%+v", got)
	}
}

func TestCodexRuntimeLoginCommandDoesNotInventRemoteHome(t *testing.T) {
	router := &Router{cfg: config.Config{
		AppServer: config.AppServerConfig{Transport: "ssh", SharedCodexHome: t.TempDir()},
	}}
	if command := router.codexRuntimeLoginCommand(); command != "" {
		t.Fatalf("远端模式不能生成本机目录登录命令：%s", command)
	}
}

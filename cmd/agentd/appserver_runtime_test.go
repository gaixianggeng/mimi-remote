//go:build darwin || linux

package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestLocalCodexUnavailablePreservesDiagnosticRuntime(t *testing.T) {
	// Unix socket 路径有长度限制，不能使用默认的长 macOS test temp 路径。
	home, err := os.MkdirTemp("/tmp", "mimi-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	bin := filepath.Join(home, "codex")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nif [ \"$1\" = --version ]; then echo codex-cli 0.155.1; exit 0; fi\nexit 99\n"), 0700); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"CODEX_HOME": home}
	socket, err := appserver.SharedLocalSocketPath(env)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(socket, []byte("occupied"), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{Codex: config.CodexConfig{Bin: bin, Env: env}, AppServer: config.AppServerConfig{Transport: "local"}}
	runtime, err := prepareAgentAppServerRuntime(cfg)
	if err != nil || runtime == nil || runtime.routerOptions.AppServerSSH == nil {
		t.Fatalf("Codex 初始化故障不应阻止 agentd 提供诊断：runtime=%v err=%v", runtime, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := runtime.routerOptions.AppServerSSH.EnsureReady(ctx); err == nil {
		t.Fatal("保留诊断服务不能把 Codex 故障标为成功")
	}
	if got, err := os.ReadFile(socket); err != nil || string(got) != "occupied" {
		t.Fatalf("初始化失败不能清除已有路径：%q %v", got, err)
	}
}

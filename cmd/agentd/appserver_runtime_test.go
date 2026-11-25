//go:build darwin || linux

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestOptionalSSHRejectsUnsupportedRemoteBeforePublishingTransport(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte("#!/bin/sh\necho 'codex-cli 0.140.0'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	cfg := config.Config{AppServer: config.AppServerConfig{Transport: "ssh", SSHTarget: "fixture.invalid"}}
	upstream := startOptionalCodex(context.Background(), cfg, "")
	defer upstream.Shutdown()
	<-upstream.done
	if _, err := upstream.WebSocketURL(); err == nil {
		t.Fatal("published a transport for an unsupported remote Codex")
	}
}

func TestSharedCodexHomeCannotStartAnUnmanagedResident(t *testing.T) {
	cfg := config.Config{
		Codex:     config.CodexConfig{Bin: "/must-not-execute-codex"},
		AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: t.TempDir()},
	}
	if _, err := prepareAgentAppServerRuntime(cfg); err == nil || !strings.Contains(err.Error(), "前门") {
		t.Fatalf("独立目录不能回退到默认 resident 或执行 Codex：%v", err)
	}
}

func TestLocalCodexUnavailablePreservesDiagnosticRuntime(t *testing.T) {
	// Unix socket 路径有长度限制，不能使用默认的长 macOS test temp 路径。
	home, err := os.MkdirTemp("/tmp", "mimi-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	bin := filepath.Join(home, "codex")
	// The daemon cannot run this shim unless both discovery and startup
	// give /usr/bin/env the interpreter directory from codex.env.PATH.
	t.Setenv("AGENTD_CODEX_BIN", "")
	t.Setenv("PATH", t.TempDir())
	if err := os.WriteFile(bin, []byte("#!/usr/bin/env test-codex-interpreter\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "test-codex-interpreter"), []byte("#!/bin/sh\nif [ \"$2\" = --version ]; then echo codex-cli 0.155.1; exit 0; fi\nexit 99\n"), 0700); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"CODEX_HOME": home, "PATH": home}
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
	if err := resolveLaunchCodex(context.Background(), &cfg); err != nil {
		t.Fatalf("discovery: %v", err)
	}
	runtime, err := prepareAgentAppServerRuntime(cfg)
	if err != nil || runtime == nil || runtime.transport == nil {
		t.Fatalf("Codex 初始化故障不应阻止 agentd 提供诊断：runtime=%v err=%v", runtime, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := runtime.transport.EnsureReady(ctx); err == nil {
		t.Fatal("保留诊断服务不能把 Codex 故障标为成功")
	}
	if got, err := os.ReadFile(socket); err != nil || string(got) != "occupied" {
		t.Fatalf("初始化失败不能清除已有路径：%q %v", got, err)
	}
}

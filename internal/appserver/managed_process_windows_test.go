//go:build windows

package appserver

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestConfigureManagedCommandCreatesWindowsProcessGroup(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/d", "/c", "exit", "/b", "0")
	configureManagedCommand(cmd)
	if cmd.SysProcAttr == nil || cmd.SysProcAttr.CreationFlags&syscall.CREATE_NEW_PROCESS_GROUP == 0 {
		t.Fatalf("managed app-server must start in a new Windows process group: %#v", cmd.SysProcAttr)
	}
}

func TestManagedAppServerRejectsCodexWithoutSingleWriterBaseline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "codex-old.cmd")
	if err := os.WriteFile(path, []byte("@echo off\r\necho codex-cli 0.145.0\r\nexit /b 0\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	process, _, err := StartManaged(ctx, ManagedOptions{CodexBin: path})
	if err == nil {
		if process != nil {
			_ = process.Shutdown(context.Background())
		}
		t.Fatal("unsafe stdio runtime must fail before app-server start")
	}
	if !errors.Is(err, ErrIndependentWriterCapabilityUnavailable) ||
		!strings.Contains(err.Error(), "0.145.0") {
		t.Fatalf("stdio rejection should report the unsafe version: %v", err)
	}

	webSocketProcess, err := StartManagedWebSocket(ctx, ManagedWebSocketOptions{
		CodexBin:       path,
		Listen:         "ws://127.0.0.1:4222",
		EarlyExitGrace: time.Millisecond,
	})
	if err == nil {
		if webSocketProcess != nil {
			_ = webSocketProcess.Shutdown(context.Background())
		}
		t.Fatal("unsafe WebSocket runtime must fail before app-server start")
	}
	if !errors.Is(err, ErrIndependentWriterCapabilityUnavailable) ||
		!strings.Contains(err.Error(), "0.145.0") {
		t.Fatalf("WebSocket rejection should report the unsafe version: %v", err)
	}
}

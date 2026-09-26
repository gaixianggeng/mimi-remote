//go:build darwin

package appserver

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// 本机显式启用时，使用独立 CODEX_HOME 验证真实 Codex 的 RPC、lsof 与 SIGHUP 退出。
func TestFrontDoorRealBackendIdleShutdown(t *testing.T) {
	if os.Getenv("MIMI_TEST_REAL_CODEX_FRONT") != "1" {
		t.Skip("仅在显式隔离实测时运行")
	}
	bin, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	home, err := os.MkdirTemp("/tmp", "mimi-real-front-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(home)
	door, err := NewFrontDoor(SharedLocalOptions{CodexBin: bin, Env: map[string]string{"CODEX_HOME": home}}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(door.BackendSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	processCtx, stop := context.WithCancel(context.Background())
	defer stop()
	cmd := exec.CommandContext(processCtx, bin, "app-server", "--listen", "unix://"+door.BackendSocketPath())
	cmd.Env = []string{"HOME=" + os.Getenv("HOME"), "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + home}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	defer func() {
		stop()
		<-exited
	}()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if conn, err := door.dialBackendOnce(context.Background()); err == nil {
			_ = conn.Close()
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	busy, err := dialSharedLocalRepairTransport(ctx, &SharedLocalTransport{socket: door.BackendSocketPath()})
	if err != nil {
		t.Fatal(err)
	}
	if err := busy.Initialize(ctx); err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	if err := door.CanReload(ctx); err == nil {
		_ = busy.Close()
		t.Fatal("仍有业务连接时不能换代前门")
	}
	_ = busy.Close()
	if err := door.CanReload(ctx); err != nil {
		t.Fatalf("真实空闲 backend 应允许前门换代：%v", err)
	}
	if err := door.StopIdleBackend(ctx); err != nil {
		t.Fatalf("真实空闲 backend 应优雅退出：%v", err)
	}
}

func TestFrontDoorRealOrphanBlocksUntilOldResidentExits(t *testing.T) {
	if os.Getenv("MIMI_TEST_REAL_CODEX_FRONT") != "1" {
		t.Skip("仅在显式隔离实测时运行")
	}
	bin, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	home, err := os.MkdirTemp("/tmp", "mimi-real-orphan-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(home)
	door, err := NewFrontDoor(SharedLocalOptions{CodexBin: bin, Env: map[string]string{"CODEX_HOME": home}}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	processCtx, stop := context.WithCancel(context.Background())
	defer stop()
	cmd := exec.CommandContext(processCtx, bin, "app-server", "--listen", "unix://")
	cmd.Env = []string{"HOME=" + os.Getenv("HOME"), "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + home}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	defer func() {
		stop()
		<-exited
	}()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if conn, err := net.Dial("unix", door.PublicSocketPath()); err == nil {
			_ = conn.Close()
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	busy, err := dialSharedLocalRepairTransport(ctx, &SharedLocalTransport{socket: door.PublicSocketPath()})
	if err != nil {
		t.Fatal(err)
	}
	if err := busy.Initialize(ctx); err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	if err := os.Remove(door.PublicSocketPath()); err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	newListener, err := net.Listen("unix", door.PublicSocketPath())
	if err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	defer newListener.Close()
	blockedCtx, blockedCancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer blockedCancel()
	if _, err := door.DialBackend(blockedCtx); err == nil {
		_ = busy.Close()
		t.Fatal("旧 resident 仍有客户端时不能开放 backend")
	}
	if _, err := os.Stat(door.BackendSocketPath()); !os.IsNotExist(err) {
		_ = busy.Close()
		t.Fatalf("旧 resident 未退出却出现私有 backend：%v", err)
	}
	_ = busy.Close()
	var stopEcho func()
	door.launch = func(context.Context, SharedLocalOptions, string) error {
		stopEcho = echoBackend(t, door.BackendSocketPath())
		return nil
	}
	defer func() {
		if stopEcho != nil {
			stopEcho()
		}
	}()
	conn, err := door.DialBackend(ctx)
	if err != nil {
		t.Fatalf("旧 resident 退出后应开放 backend：%v", err)
	}
	_ = conn.Close()
}

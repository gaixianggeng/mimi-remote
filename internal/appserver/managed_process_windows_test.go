//go:build windows

package appserver

import (
	"context"
	"os/exec"
	"testing"
	"time"
)

func startManagedTestProcess(t *testing.T, name string, args ...string) *ManagedWebSocketProcess {
	t.Helper()
	cmd := exec.Command(name, args...)
	configureManagedCommand(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	process := &ManagedWebSocketProcess{cmd: cmd, waitCh: make(chan error, 1), doneCh: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		process.waitErrMu.Lock()
		process.waitErr = err
		process.waitErrMu.Unlock()
		process.waitCh <- err
		close(process.doneCh)
	}()
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	return process
}

func TestManagedShutdownAcceptsWindowsForcedTermination(t *testing.T) {
	process := startManagedTestProcess(t, "ping.exe", "-n", "60", "127.0.0.1")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := process.Shutdown(ctx); err != nil {
		t.Fatalf("主动停止受管进程不能误报退出码：%v", err)
	}
	if exitErr := process.ExitError(); !isForcedTerminationExit(exitErr) {
		t.Fatalf("测试前提：子进程应被强制终止，实际 %v", exitErr)
	}
}

func TestManagedShutdownKeepsExitBeforeStop(t *testing.T) {
	process := startManagedTestProcess(t, "cmd.exe", "/c", "exit 1")
	select {
	case <-process.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("测试子进程未退出")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := process.Shutdown(ctx); err == nil {
		t.Fatal("停止前已退出的子进程即使退出码为 1 也必须保留错误")
	}
}

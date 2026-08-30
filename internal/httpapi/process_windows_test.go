//go:build windows

package httpapi

import (
	"os/exec"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestConfigureGatewayCommandProcessGroupWindows(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "exit", "0")
	configureGatewayCommandProcessGroup(cmd)
	if cmd.SysProcAttr == nil {
		t.Fatal("SysProcAttr is nil")
	}
	if cmd.SysProcAttr.CreationFlags&syscall.CREATE_NEW_PROCESS_GROUP == 0 {
		t.Fatalf("CreationFlags = %#x, missing CREATE_NEW_PROCESS_GROUP", cmd.SysProcAttr.CreationFlags)
	}
	if cmd.SysProcAttr.CreationFlags&windows.CREATE_SUSPENDED == 0 {
		t.Fatalf("CreationFlags = %#x, missing CREATE_SUSPENDED", cmd.SysProcAttr.CreationFlags)
	}
}

func TestTerminateGatewayProcessGroupWindows(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "ping.exe", "-t", "127.0.0.1")
	configureGatewayCommandProcessGroup(cmd)
	if err := startGatewayCommand(cmd); err != nil {
		t.Fatalf("start process: %v", err)
	}
	wait := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		releaseGatewayProcessGroup(cmd)
		wait <- err
	}()
	t.Cleanup(func() {
		terminateGatewayProcessGroup(cmd, true)
		select {
		case <-wait:
		case <-time.After(10 * time.Second):
		}
	})

	// shutdown 首次传入 force=false；Windows 仍必须一次性结束整棵进程树。
	terminateGatewayProcessGroup(cmd, false)
	select {
	case <-wait:
	case <-time.After(10 * time.Second):
		t.Fatal("process did not exit after tree termination")
	}
}

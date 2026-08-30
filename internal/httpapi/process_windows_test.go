//go:build windows

package httpapi

import (
	"os/exec"
	"syscall"
	"testing"
	"time"
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
}

func TestTerminateGatewayProcessGroupWindows(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "ping.exe", "-t", "127.0.0.1")
	configureGatewayCommandProcessGroup(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start process: %v", err)
	}
	wait := make(chan error, 1)
	go func() { wait <- cmd.Wait() }()
	t.Cleanup(func() {
		terminateGatewayProcessGroup(cmd, true)
		select {
		case <-wait:
		case <-time.After(10 * time.Second):
		}
	})

	terminateGatewayProcessGroup(cmd, true)
	select {
	case <-wait:
	case <-time.After(10 * time.Second):
		t.Fatal("process did not exit after forced tree termination")
	}
}

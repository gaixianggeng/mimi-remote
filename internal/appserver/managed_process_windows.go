//go:build windows

package appserver

import (
	"context"
	"os/exec"
	"strconv"
	"syscall"
	"time"
)

const managedTaskkillTimeout = 5 * time.Second

func configureManagedCommand(cmd *exec.Cmd) {
	if cmd != nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
	}
}

func validateManagedCodexRuntime(context.Context, string) error {
	return nil
}

func terminateManagedProcess(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), managedTaskkillTimeout)
	defer cancel()
	err := exec.CommandContext(
		ctx,
		"taskkill.exe",
		"/PID", strconv.Itoa(cmd.Process.Pid),
		"/T",
		"/F",
	).Run()
	if err != nil {
		_ = cmd.Process.Kill()
	}
}

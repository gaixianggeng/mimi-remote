//go:build windows

package appserver

import (
	"context"
	"errors"
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

// taskkill /F 与 Process.Kill 都经 TerminateProcess 结束进程，退出码固定为 1。
func isForcedTerminationExit(err error) bool {
	var exitErr *exec.ExitError
	return errors.As(err, &exitErr) && exitErr.ExitCode() == 1
}

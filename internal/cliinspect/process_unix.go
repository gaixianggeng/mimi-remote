//go:build !windows

package cliinspect

import (
	"os/exec"
	"syscall"
)

func start(cmd *exec.Cmd) (func(), error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	// CommandContext kills the root on cancellation. Clean the group after
	// every Wait, including when the root exits successfully on its own.
	pgid := cmd.Process.Pid
	return func() { _ = syscall.Kill(-pgid, syscall.SIGKILL) }, nil
}

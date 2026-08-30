//go:build !windows

package httpapi

import (
	"os/exec"
	"syscall"
)

func configureGatewayCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func startGatewayCommand(cmd *exec.Cmd) error {
	return cmd.Start()
}

func releaseGatewayProcessGroup(_ *exec.Cmd) {}

func terminateGatewayProcessGroup(cmd *exec.Cmd, force bool) {
	pid := gatewayProcessID(cmd)
	if pid <= 0 {
		return
	}
	signal := syscall.SIGTERM
	if force {
		signal = syscall.SIGKILL
	}
	if err := syscall.Kill(-pid, signal); err != nil && err != syscall.ESRCH {
		_ = syscall.Kill(pid, signal)
	}
}

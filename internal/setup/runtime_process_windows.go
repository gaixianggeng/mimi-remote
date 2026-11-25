//go:build windows

package setup

import (
	"os/exec"
	"syscall"
)

func configureInspection(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}

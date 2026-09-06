//go:build linux

package appserver

import (
	"os/exec"
	"syscall"
)

func configureSharedLocalCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

//go:build linux

package appserver

import (
	"os/exec"
	"syscall"
)

func configureSharedLocalCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

// Linux 优先走 systemd-run；这里只是没有 user-systemd 时的兜底，直接执行即可。
func residentLaunchCommand(bin string, args []string) (string, []string) {
	return bin, args
}

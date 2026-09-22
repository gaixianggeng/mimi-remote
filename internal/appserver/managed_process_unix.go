//go:build !windows

package appserver

import (
	"os/exec"
)

func configureManagedCommand(*exec.Cmd) {}

func terminateManagedProcess(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

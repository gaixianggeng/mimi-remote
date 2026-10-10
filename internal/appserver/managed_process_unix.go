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

// Unix 的强制终止表现为 signal: killed，已由 ignoreKilledProcessError 处理。
func isForcedTerminationExit(error) bool { return false }

//go:build !windows

package appserver

import (
	"context"
	"os/exec"
)

func configureManagedCommand(*exec.Cmd) {}

func validateManagedCodexRuntime(context.Context, string) error { return nil }

func terminateManagedProcess(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

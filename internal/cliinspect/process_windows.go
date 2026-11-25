//go:build windows

package cliinspect

import (
	"context"
	"os/exec"
	"syscall"

	"github.com/gaixianggeng/mimi-remote/internal/winjob"
)

// npm resolves logs-dir against its working directory. Use the absolute device
// path so Node cannot enumerate a literal directory named NUL there.
const probeLogSink = `\\.\NUL`

func start(_ context.Context, cmd *exec.Cmd) (func(), error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	job, err := winjob.Start(cmd)
	if err != nil {
		return nil, err
	}
	return job.Close, nil
}

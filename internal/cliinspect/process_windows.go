//go:build windows

package cliinspect

import (
	"os/exec"
	"syscall"

	"github.com/gaixianggeng/mimi-remote/internal/winjob"
)

func start(cmd *exec.Cmd) (func(), error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	job, err := winjob.Start(cmd)
	if err != nil {
		return nil, err
	}
	return job.Close, nil
}

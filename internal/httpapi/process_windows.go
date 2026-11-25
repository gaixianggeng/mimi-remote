//go:build windows

package httpapi

import (
	"context"
	"os/exec"
	"strconv"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/windows"

	"github.com/gaixianggeng/mimi-remote/internal/winjob"
)

const gatewayTaskkillTimeout = 5 * time.Second

var gatewayWindowsJobs sync.Map

func configureGatewayCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	// 先挂起根进程，确保它在绑定 Job Object 前不会派生子进程。
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | windows.CREATE_SUSPENDED,
	}
}

func startGatewayCommand(cmd *exec.Cmd) error {
	job, err := winjob.Start(cmd)
	if err != nil {
		return err
	}
	gatewayWindowsJobs.Store(cmd, job)
	return nil
}

func releaseGatewayProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	value, ok := gatewayWindowsJobs.LoadAndDelete(cmd)
	if !ok {
		return
	}
	value.(*winjob.Job).Close()
}

func terminateGatewayProcessGroup(cmd *exec.Cmd, _ bool) {
	if cmd == nil {
		return
	}
	if value, ok := gatewayWindowsJobs.Load(cmd); ok {
		if value.(*winjob.Job).Terminate(gatewayTaskkillTimeout) {
			return
		}
	}

	// Job Object 无法使用时保留强制 taskkill 作为最后退路。
	pid := gatewayProcessID(cmd)
	if pid <= 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), gatewayTaskkillTimeout)
	defer cancel()
	args := []string{"/PID", strconv.Itoa(pid), "/T", "/F"}
	if err := exec.CommandContext(ctx, "taskkill.exe", args...).Run(); err != nil && cmd.Process != nil {
		// taskkill reports an error when the process already exited. Process.Kill is
		// likewise safe to ignore, and is a last resort if taskkill is unavailable.
		_ = cmd.Process.Kill()
	}
}

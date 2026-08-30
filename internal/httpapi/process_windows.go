//go:build windows

package httpapi

import (
	"context"
	"os/exec"
	"strconv"
	"syscall"
	"time"
)

const gatewayTaskkillTimeout = 5 * time.Second

func configureGatewayCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

func terminateGatewayProcessGroup(cmd *exec.Cmd, force bool) {
	pid := gatewayProcessID(cmd)
	if pid <= 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), gatewayTaskkillTimeout)
	defer cancel()
	args := []string{"/PID", strconv.Itoa(pid), "/T"}
	if force {
		args = append(args, "/F")
	}
	if err := exec.CommandContext(ctx, "taskkill.exe", args...).Run(); err != nil && force && cmd.Process != nil {
		// taskkill reports an error when the process already exited. Process.Kill is
		// likewise safe to ignore, and is a last resort if taskkill is unavailable.
		_ = cmd.Process.Kill()
	}
}

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

func terminateGatewayProcessGroup(cmd *exec.Cmd, _ bool) {
	pid := gatewayProcessID(cmd)
	if pid <= 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), gatewayTaskkillTimeout)
	defer cancel()
	// 非强制 taskkill 可能让根进程先退出，使 reaper 在子进程清理前完成。
	// 根 PID 消失后无法再可靠枚举孤儿，因此 Windows 首次就强制结束整棵树。
	args := []string{"/PID", strconv.Itoa(pid), "/T", "/F"}
	if err := exec.CommandContext(ctx, "taskkill.exe", args...).Run(); err != nil && cmd.Process != nil {
		// taskkill reports an error when the process already exited. Process.Kill is
		// likewise safe to ignore, and is a last resort if taskkill is unavailable.
		_ = cmd.Process.Kill()
	}
}

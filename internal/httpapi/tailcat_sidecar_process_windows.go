//go:build windows

package httpapi

import (
	"context"
	"net/http"
	"os/exec"
	"time"
)

// 与 Claude bridge 一样放进独立的 kill-on-close Job Object：受管服务的生命周期
// Job 之外，手动运行的 agentd serve 异常退出时也不会留下辅助程序。
func prepareTailcatSidecarProcess(cmd *exec.Cmd) {
	configureGatewayCommandProcessGroup(cmd)
}

func startTailcatSidecarProcess(cmd *exec.Cmd) error {
	return startGatewayCommand(cmd)
}

func releaseTailcatSidecarProcess(cmd *exec.Cmd) {
	releaseGatewayProcessGroup(cmd)
}

func killTailcatSidecarProcess(cmd *exec.Cmd) {
	if value, ok := gatewayWindowsJobs.Load(cmd); ok && value.(*gatewayWindowsJob).terminate() {
		return
	}
	// reap 可能已释放 Job。os.Process 持有进程句柄，不会像按 PID taskkill 那样误杀复用 PID 的进程。
	_ = cmd.Process.Kill()
}

const tailcatSidecarShutdownCallTimeout = 2 * time.Second

// requestSidecarExit 走控制 socket：Windows 不能向子进程投递 SIGINT/SIGTERM，
// os.Process.Signal 只会返回不支持。
func (s *tailcatSidecarSupervisor) requestSidecarExit(*exec.Cmd) bool {
	return s.call(context.Background(), tailcatSidecarShutdownCallTimeout, http.MethodPost, "/shutdown", nil, nil) == nil
}

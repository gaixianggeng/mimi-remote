//go:build !windows

package httpapi

import (
	"os"
	"os/exec"
)

func prepareTailcatSidecarProcess(*exec.Cmd) {}

func startTailcatSidecarProcess(cmd *exec.Cmd) error {
	return cmd.Start()
}

func releaseTailcatSidecarProcess(*exec.Cmd) {}

func killTailcatSidecarProcess(cmd *exec.Cmd) {
	_ = cmd.Process.Kill()
}

// requestSidecarExit 发送中断信号；辅助程序收到后关闭节点并清理控制 socket。
func (s *tailcatSidecarSupervisor) requestSidecarExit(cmd *exec.Cmd) bool {
	return cmd.Process.Signal(os.Interrupt) == nil
}

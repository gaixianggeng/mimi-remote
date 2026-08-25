//go:build windows

package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func runManagedServiceHost(agentPath, logPath string) error {
	command, err := managedServiceHostCommand(agentPath, logPath)
	if err != nil {
		return err
	}
	return command.Run()
}

func managedServiceHostCommand(agentPath, logPath string) (*exec.Cmd, error) {
	agentPath = strings.TrimSpace(agentPath)
	logPath = strings.TrimSpace(logPath)
	if agentPath == "" {
		return nil, fmt.Errorf("Windows 后台服务缺少 agentd 路径")
	}
	if logPath == "" {
		return nil, fmt.Errorf("Windows 后台服务缺少日志路径")
	}

	command := exec.Command(agentPath, "serve", "--managed-service", "--log-file", logPath)
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
	// 计划任务运行的是 windowsgui 子系统的托盘宿主。显式丢弃标准句柄，
	// 避免 agentd 因继承无效控制台句柄而退出；服务日志仍写入 --log-file。
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	return command, nil
}

func appendManagedServiceHostError(logPath string, hostErr error) {
	logPath = strings.TrimSpace(logPath)
	if logPath == "" || hostErr == nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		return
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer logFile.Close()
	_, _ = fmt.Fprintf(logFile, "%s service_host_error=%q\n", time.Now().UTC().Format(time.RFC3339), hostErr.Error())
}

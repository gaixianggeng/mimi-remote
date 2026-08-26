//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const swHide = 0

var (
	managedConsoleKernel32            = syscall.NewLazyDLL("kernel32.dll")
	managedConsoleUser32              = syscall.NewLazyDLL("user32.dll")
	procGetConsoleWindow              = managedConsoleKernel32.NewProc("GetConsoleWindow")
	procGetConsoleProcessList         = managedConsoleKernel32.NewProc("GetConsoleProcessList")
	procHideManagedServiceShowWindow  = managedConsoleUser32.NewProc("ShowWindow")
	managedServiceFailureFallbackPath = func() (string, error) {
		return windowsManagedRuntimePath("agentd.last-error.log")
	}
)

func hideStandaloneManagedServiceConsole(args []string) {
	// Task Scheduler 为控制台程序创建独立控制台。只隐藏仅有 agentd 的控制台，
	// 避免用户从现有 PowerShell 或终端手动调试时连带隐藏父窗口。
	var processIDs [2]uint32
	count, _, _ := procGetConsoleProcessList.Call(
		uintptr(unsafe.Pointer(&processIDs[0])),
		uintptr(len(processIDs)),
	)
	if !shouldHideManagedServiceConsole(args, count) {
		return
	}
	window, _, _ := procGetConsoleWindow.Call()
	if window != 0 {
		procHideManagedServiceShowWindow.Call(window, swHide)
	}
}

func shouldHideManagedServiceConsole(args []string, attachedProcessCount uintptr) bool {
	return managedServiceRequested(args) && attachedProcessCount == 1
}

func managedServiceRequested(args []string) bool {
	for _, arg := range args[1:] {
		if arg == "--managed-service" {
			return true
		}
	}
	return false
}

func appendManagedServiceFailure(args []string, serviceErr error) {
	if serviceErr == nil || !managedServiceRequested(args) {
		return
	}
	logPath := argumentValue(args, "--log-file")
	if logPath == "" {
		return
	}
	line := fmt.Sprintf(
		"%s managed_service_error=%q\n",
		time.Now().UTC().Format(time.RFC3339),
		sanitizeManagedServiceDiagnostic(serviceErr.Error()),
	)
	if appendManagedServiceDiagnostic(logPath, line, false) == nil {
		return
	}
	fallbackPath, err := managedServiceFailureFallbackPath()
	if err != nil || strings.EqualFold(filepath.Clean(fallbackPath), filepath.Clean(logPath)) {
		return
	}
	// 主日志路径本身故障时，保留一份有上限的最后错误；每次覆盖，避免
	// 计划任务自动重试造成无界增长。
	_ = appendManagedServiceDiagnostic(fallbackPath, line, true)
}

func appendManagedServiceDiagnostic(path, line string, replace bool) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if replace {
		flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	}
	logFile, err := os.OpenFile(path, flags, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	_, err = logFile.WriteString(line)
	return err
}

func sanitizeManagedServiceDiagnostic(value string) string {
	value = strings.TrimSpace(value)
	lower := strings.ToLower(value)
	for _, marker := range []string{"token", "secret", "password", "authorization", "bearer", "api_key", "apikey"} {
		if strings.Contains(lower, marker) {
			return "[redacted sensitive managed-service diagnostic]"
		}
	}
	return value
}

func argumentValue(args []string, name string) string {
	for index := 1; index < len(args); index++ {
		if args[index] == name && index+1 < len(args) {
			return strings.TrimSpace(args[index+1])
		}
		if value, found := strings.CutPrefix(args[index], name+"="); found {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const windowsManagedTaskName = "Mimi Remote agentd"

var (
	windowsLookPath    = exec.LookPath
	windowsExecCommand = exec.Command
)

func runWindowsManagedService(action string, stdout, stderr io.Writer) error {
	schtasks, err := windowsLookPath("schtasks")
	if err != nil {
		return fmt.Errorf("未找到 schtasks，无法管理 Windows 当前用户计划任务：%w", err)
	}

	if action == "status" {
		return queryWindowsManagedTask(schtasks, stdout, stderr)
	}
	if err := queryWindowsManagedTask(schtasks, io.Discard, io.Discard); err != nil {
		return err
	}

	switch action {
	case "start":
		removeWindowsManagedStopRequest()
		return runWindowsTaskAction(schtasks, "Run", stdout, stderr, true)
	case "stop":
		return stopWindowsManagedTask(schtasks, stdout, stderr)
	case "restart":
		if err := stopWindowsManagedTask(schtasks, stdout, stderr); err != nil {
			return err
		}
		removeWindowsManagedStopRequest()
		return runWindowsTaskAction(schtasks, "Run", stdout, stderr, true)
	default:
		return fmt.Errorf("Windows 当前用户计划任务不支持操作 %q", action)
	}
}

func windowsManagedRuntimeDir(path string) string {
	return filepath.Dir(path)
}

func windowsManagedRuntimePath(name string) (string, error) {
	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	if localAppData == "" {
		cacheDir, err := os.UserCacheDir()
		if err != nil {
			return "", fmt.Errorf("定位 Windows 用户服务状态目录失败：%w", err)
		}
		localAppData = cacheDir
	}
	return filepath.Join(localAppData, "Mimi Remote", name), nil
}

func windowsManagedPIDPath() (string, error) {
	return windowsManagedRuntimePath("agentd.pid")
}

func windowsManagedStopPath() (string, error) {
	return windowsManagedRuntimePath("agentd.stop")
}

func removeWindowsManagedStopRequest() {
	if path, err := windowsManagedStopPath(); err == nil {
		_ = os.Remove(path)
	}
}

func stopWindowsManagedTask(schtasks string, stdout, stderr io.Writer) error {
	pidPath, pathErr := windowsManagedPIDPath()
	stopPath, stopPathErr := windowsManagedStopPath()
	if pathErr == nil && stopPathErr == nil {
		if pidData, readErr := os.ReadFile(pidPath); readErr == nil {
			pidText := strings.TrimSpace(string(pidData))
			pid, pidErr := strconv.Atoi(pidText)
			if pidErr != nil || !windowsManagedPIDMatchesExecutable(pid) {
				// A forced task end can leave a stale PID file. Never send a stop
				// marker or taskkill to a recycled PID owned by another process.
				_ = os.Remove(pidPath)
				_ = os.Remove(stopPath)
			} else {
				if err := os.MkdirAll(filepath.Dir(stopPath), 0o700); err == nil {
					if err := os.WriteFile(stopPath, []byte("stop\n"), 0o600); err == nil {
						deadline := time.Now().Add(10 * time.Second)
						for time.Now().Before(deadline) {
							if _, err := os.Stat(pidPath); errors.Is(err, os.ErrNotExist) {
								_ = os.Remove(stopPath)
								// The service removes its PID file during graceful shutdown, but
								// Task Scheduler may still report the old instance as Running for a
								// short window. With MultipleInstances=IgnoreNew, an immediate
								// restart would then be accepted as a no-op and leave the service
								// offline. Fall through and synchronize the scheduler state before
								// returning to the caller.
								return waitForWindowsManagedTaskStopped(schtasks, stdout, stderr, 10*time.Second)
							}
							time.Sleep(100 * time.Millisecond)
						}
					}
				}
				_ = forceKillWindowsProcessTree(pidText, stdout, stderr)
				_ = os.Remove(pidPath)
				_ = os.Remove(stopPath)
			}
		}
	}
	return waitForWindowsManagedTaskStopped(schtasks, stdout, stderr, 10*time.Second)
}

func waitForWindowsManagedTaskStopped(
	schtasks string,
	stdout, stderr io.Writer,
	timeout time.Duration,
) error {
	if err := runWindowsTaskAction(schtasks, "End", stdout, stderr, true); err != nil {
		return err
	}
	powershell, err := windowsLookPath("powershell.exe")
	if err != nil {
		return fmt.Errorf("未找到 powershell.exe，无法等待 Windows 当前用户计划任务停止：%w", err)
	}
	const stateScript = `$task = Get-ScheduledTask -TaskName $env:MIMI_REMOTE_WINDOWS_TASK_NAME -ErrorAction Stop; [Console]::Out.Write([string]$task.State)`
	deadline := time.Now().Add(timeout)
	for {
		var commandStdout, commandStderr bytes.Buffer
		cmd := windowsExecCommand(powershell, "-NoProfile", "-NonInteractive", "-Command", stateScript)
		cmd.Env = append(cmd.Environ(), "MIMI_REMOTE_WINDOWS_TASK_NAME="+windowsManagedTaskName)
		cmd.Stdout = &commandStdout
		cmd.Stderr = &commandStderr
		err := cmd.Run()
		detail := commandStdout.String() + commandStderr.String()
		if err != nil {
			_, _ = io.Copy(stdout, &commandStdout)
			_, _ = io.Copy(stderr, &commandStderr)
			return fmt.Errorf(
				"查询 Windows 当前用户计划任务 %q 状态失败：%w%s",
				windowsManagedTaskName,
				err,
				formatWindowsCommandDetail(detail),
			)
		}
		switch strings.ToLower(strings.TrimSpace(commandStdout.String())) {
		case "ready", "disabled":
			return nil
		case "running", "queued":
			// Keep polling below. /End only submits the stop request, while an
			// IgnoreNew task cannot safely be restarted until this state clears.
		default:
			return fmt.Errorf(
				"Windows 当前用户计划任务 %q 返回了未知状态%s",
				windowsManagedTaskName,
				formatWindowsCommandDetail(detail),
			)
		}
		if timeout <= 0 || time.Now().After(deadline) {
			return fmt.Errorf("等待 Windows 当前用户计划任务 %q 停止超时", windowsManagedTaskName)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func forceKillWindowsProcessTree(pid string, stdout, stderr io.Writer) error {
	if _, err := strconv.Atoi(pid); err != nil {
		return fmt.Errorf("Windows 后台服务 PID 无效：%q", pid)
	}
	taskkill, err := windowsLookPath("taskkill")
	if err != nil {
		return fmt.Errorf("未找到 taskkill，无法清理 Windows 后台服务进程树：%w", err)
	}
	cmd := windowsExecCommand(taskkill, "/PID", pid, "/T", "/F")
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}

func ensureWindowsManagedTaskInstalled() error {
	schtasks, err := windowsLookPath("schtasks")
	if err != nil {
		return fmt.Errorf("未找到 schtasks，无法检查 Windows 当前用户计划任务：%w", err)
	}
	return queryWindowsManagedTask(schtasks, io.Discard, io.Discard)
}

func queryWindowsManagedTask(schtasks string, stdout, stderr io.Writer) error {
	var detail bytes.Buffer
	cmd := windowsExecCommand(schtasks, "/Query", "/TN", windowsManagedTaskName, "/FO", "LIST", "/V")
	cmd.Stdout = io.MultiWriter(stdout, &detail)
	cmd.Stderr = io.MultiWriter(stderr, &detail)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf(
			"尚未安装 Windows 当前用户计划任务 %q；请重新运行 Mimi Remote Windows 安装程序（安装器负责注册该任务）：%w%s",
			windowsManagedTaskName,
			err,
			formatWindowsCommandDetail(detail.String()),
		)
	}
	return nil
}

func runWindowsTaskAction(schtasks, verb string, stdout, stderr io.Writer, allowIdempotentNoop bool) error {
	var commandStdout, commandStderr bytes.Buffer
	cmd := windowsExecCommand(schtasks, "/"+verb, "/TN", windowsManagedTaskName)
	cmd.Stdout = &commandStdout
	cmd.Stderr = &commandStderr
	if err := cmd.Run(); err != nil {
		detail := commandStdout.String() + commandStderr.String()
		if allowIdempotentNoop &&
			((verb == "End" && windowsTaskAlreadyStopped(detail)) ||
				(verb == "Run" && windowsTaskAlreadyRunning(detail))) {
			return nil
		}
		_, _ = io.Copy(stdout, &commandStdout)
		_, _ = io.Copy(stderr, &commandStderr)
		return fmt.Errorf("执行 schtasks /%s /TN %q 失败：%w%s", verb, windowsManagedTaskName, err, formatWindowsCommandDetail(detail))
	}
	_, _ = io.Copy(stdout, &commandStdout)
	_, _ = io.Copy(stderr, &commandStderr)
	return nil
}

func windowsTaskAlreadyStopped(detail string) bool {
	normalized := strings.ToLower(strings.TrimSpace(detail))
	for _, marker := range []string{
		"not currently running",
		"is not running",
		"cannot be stopped",
		"当前未运行",
		"尚未运行",
		"任务未运行",
		"没有运行",
		"未在运行",
	} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

func windowsTaskAlreadyRunning(detail string) bool {
	normalized := strings.ToLower(strings.TrimSpace(detail))
	for _, marker := range []string{
		"currently running",
		"is already running",
		"正在运行",
		"已在运行",
	} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

func formatWindowsCommandDetail(detail string) string {
	detail = strings.TrimSpace(detail)
	if detail == "" {
		return ""
	}
	return "：" + detail
}

func windowsManagedLogPath() (string, error) {
	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	if localAppData == "" {
		cacheDir, err := os.UserCacheDir()
		if err != nil {
			return "", fmt.Errorf("定位 Windows 用户日志目录失败：%w", err)
		}
		localAppData = cacheDir
	}
	return filepath.Join(localAppData, "Mimi Remote", "logs", "agentd.log"), nil
}

func runWindowsManagedLogs(lineCount int, follow bool, stdout, stderr io.Writer) error {
	path, err := windowsManagedLogPath()
	if err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("未找到 Mimi Remote 助手日志文件：%s；请确认 Windows 安装程序已完成且计划任务至少启动过一次", path)
		}
		return fmt.Errorf("检查 Windows 助手日志失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("Windows 助手日志路径不是普通文件：%s", path)
	}

	fmt.Fprintf(stdout, "日志文件：%s\n\n", path)
	if !follow {
		lines, err := tailLines(path, lineCount)
		if err != nil {
			return err
		}
		for _, line := range lines {
			fmt.Fprintln(stdout, line)
		}
		return nil
	}

	powershell, err := findWindowsPowerShell()
	if err != nil {
		return err
	}
	cmd := windowsExecCommand(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
		"Get-Content -LiteralPath $args[0] -Tail ([int]$args[1]) -Wait", path, fmt.Sprint(lineCount))
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("跟随 Windows 助手日志失败：%w", err)
	}
	return nil
}

func findWindowsPowerShell() (string, error) {
	for _, name := range []string{"powershell.exe", "powershell", "pwsh.exe", "pwsh"} {
		if path, err := windowsLookPath(name); err == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf("未找到 PowerShell，无法跟随 Windows 助手日志；可去掉 -f 查看最近日志")
}

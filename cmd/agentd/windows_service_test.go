package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWindowsManagedServiceUsesExistingCurrentUserTask(t *testing.T) {
	marker := installFakeWindowsCommands(t)
	var stdout, stderr strings.Builder

	if err := runManagedServiceForPlatform("windows", "start", &stdout, &stderr); err != nil {
		t.Fatalf("Windows start 失败：%v", err)
	}
	if err := runManagedServiceForPlatform("windows", "stop", &stdout, &stderr); err != nil {
		t.Fatalf("重复停止未运行任务应保持幂等：%v", err)
	}
	if err := runManagedServiceForPlatform("windows", "restart", &stdout, &stderr); err != nil {
		t.Fatalf("Windows restart 失败：%v", err)
	}
	if err := runManagedServiceForPlatform("windows", "status", &stdout, &stderr); err != nil {
		t.Fatalf("Windows status 失败：%v", err)
	}
	if stderr.Len() != 0 {
		t.Fatalf("幂等停止/重启不应泄漏 schtasks 的“未运行”错误：%q", stderr.String())
	}

	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	calls := strings.Split(strings.TrimSpace(string(raw)), "\n")
	joined := strings.Join(calls, "\n")
	for _, want := range []string{
		"schtasks|/Query|/TN|Mimi Remote agentd|/FO|LIST|/V",
		"schtasks|/Run|/TN|Mimi Remote agentd",
		"schtasks|/End|/TN|Mimi Remote agentd",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("缺少计划任务命令 %q：\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "/Create") {
		t.Fatalf("CLI 不得注册计划任务：\n%s", joined)
	}
}

func TestWindowsManagedServiceMissingTaskExplainsInstaller(t *testing.T) {
	marker := installFakeWindowsCommands(t)
	t.Setenv("AGENTD_FAKE_TASK_MISSING", "1")

	err := runManagedServiceForPlatform("windows", "start", io.Discard, io.Discard)
	if err == nil {
		t.Fatal("任务缺失时必须失败")
	}
	for _, want := range []string{windowsManagedTaskName, "Windows 安装程序", "安装器负责注册"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("任务缺失提示缺少 %q：%v", want, err)
		}
	}
	raw, readErr := os.ReadFile(marker)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if strings.Contains(string(raw), "/Run") {
		t.Fatalf("任务缺失时不得尝试启动：%s", raw)
	}
}

func TestWindowsManagedStartAlreadyRunningIsIdempotent(t *testing.T) {
	installFakeWindowsCommands(t)
	t.Setenv("AGENTD_FAKE_TASK_RUNNING", "1")
	var stderr strings.Builder
	if err := runManagedServiceForPlatform("windows", "start", io.Discard, &stderr); err != nil {
		t.Fatalf("已经运行的任务再次 start 应保持幂等：%v", err)
	}
	if stderr.Len() != 0 {
		t.Fatalf("幂等 start 不应泄漏 schtasks 错误：%q", stderr.String())
	}
}

func TestWindowsManagedStopRequestsGracefulShutdownAndSynchronizesTask(t *testing.T) {
	marker := installFakeWindowsCommands(t)
	pidPath, err := windowsManagedPIDPath()
	if err != nil {
		t.Fatal(err)
	}
	stopPath, err := windowsManagedStopPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(pidPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidPath, []byte("1234\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := os.Stat(stopPath); err == nil {
				_ = os.Remove(pidPath)
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}()

	if err := runManagedServiceForPlatform("windows", "stop", io.Discard, io.Discard); err != nil {
		t.Fatalf("Windows graceful stop 失败：%v", err)
	}
	<-done
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "schtasks|/End|/TN|Mimi Remote agentd") {
		t.Fatalf("优雅退出成功后必须等待 Task Scheduler 状态收敛：%s", raw)
	}
	if _, err := os.Stat(stopPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("优雅退出后应清理 stop marker：%v", err)
	}
}

func TestWindowsManagedRestartEndsTaskBeforeStartingReplacement(t *testing.T) {
	marker := installFakeWindowsCommands(t)
	if err := runManagedServiceForPlatform("windows", "restart", io.Discard, io.Discard); err != nil {
		t.Fatalf("Windows restart 失败：%v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	calls := string(raw)
	endIndex := strings.Index(calls, "schtasks|/End|/TN|Mimi Remote agentd")
	runIndex := strings.LastIndex(calls, "schtasks|/Run|/TN|Mimi Remote agentd")
	if endIndex < 0 || runIndex < 0 || endIndex > runIndex {
		t.Fatalf("restart 必须先同步停止 Task Scheduler 实例再启动新实例：%s", calls)
	}
}

func TestWindowsManagedStopWaitsForSchedulerToReportStopped(t *testing.T) {
	marker := installFakeWindowsCommands(t)
	t.Setenv("AGENTD_FAKE_TASK_STATE_TRANSITION", "1")
	if err := runManagedServiceForPlatform("windows", "stop", io.Discard, io.Discard); err != nil {
		t.Fatalf("Windows stop 失败：%v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if count := strings.Count(string(raw), "Get-ScheduledTask"); count != 2 {
		t.Fatalf("Task Scheduler 过渡期间应持续探测到明确停止，实际状态查询次数=%d：%s", count, raw)
	}
}

func TestWindowsManagedStopDoesNotSwallowUnexpectedSchedulerError(t *testing.T) {
	installFakeWindowsCommands(t)
	t.Setenv("AGENTD_FAKE_TASK_END_DENIED", "1")
	var stderr strings.Builder
	err := runManagedServiceForPlatform("windows", "stop", io.Discard, &stderr)
	if err == nil {
		t.Fatal("Task Scheduler 拒绝停止时必须失败")
	}
	if !strings.Contains(err.Error(), "Access is denied") || !strings.Contains(stderr.String(), "Access is denied") {
		t.Fatalf("Task Scheduler 的意外错误必须保留：err=%v stderr=%q", err, stderr.String())
	}
}

func TestWaitForWindowsManagedTaskStoppedTimesOutDuringPersistentTransition(t *testing.T) {
	installFakeWindowsCommands(t)
	t.Setenv("AGENTD_FAKE_TASK_STATE_ALWAYS_PENDING", "1")
	err := waitForWindowsManagedTaskStopped("schtasks", io.Discard, io.Discard, 50*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "停止超时") {
		t.Fatalf("Task Scheduler 持续过渡时必须超时失败：%v", err)
	}
}

func TestWindowsManagedStopRemovesStalePIDWithoutKillingReusedProcess(t *testing.T) {
	marker := installFakeWindowsCommands(t)
	windowsManagedPIDMatchesExecutable = func(int) bool { return false }
	pidPath, err := windowsManagedPIDPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(pidPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidPath, []byte("4321\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := runManagedServiceForPlatform("windows", "stop", io.Discard, io.Discard); err != nil {
		t.Fatalf("stale PID cleanup should remain idempotent: %v", err)
	}
	if _, err := os.Stat(pidPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale PID file should be removed: %v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "taskkill") {
		t.Fatalf("recycled PID must never be passed to taskkill: %s", raw)
	}
}

func TestWindowsManagedLogsUseLocalAppDataAndPowerShellFollow(t *testing.T) {
	marker := installFakeWindowsCommands(t)
	localAppData := t.TempDir()
	t.Setenv("LOCALAPPDATA", localAppData)
	logPath := filepath.Join(localAppData, "Mimi Remote", "logs", "agentd.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logPath, []byte("one\ntwo\nthree\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var recent strings.Builder
	if err := runManagedLogsForPlatform("windows", 2, false, &recent, io.Discard); err != nil {
		t.Fatalf("读取 Windows 最近日志失败：%v", err)
	}
	if !strings.Contains(recent.String(), "two\nthree\n") {
		t.Fatalf("最近日志内容不正确：%q", recent.String())
	}

	var followed strings.Builder
	if err := runManagedLogsForPlatform("windows", 7, true, &followed, io.Discard); err != nil {
		t.Fatalf("跟随 Windows 日志失败：%v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	call := string(raw)
	for _, want := range []string{"powershell.exe|", "Get-Content -LiteralPath $args[0] -Tail ([int]$args[1]) -Wait", logPath, "|7"} {
		if !strings.Contains(call, want) {
			t.Fatalf("PowerShell follow 参数缺少 %q：%s", want, call)
		}
	}
}

func installFakeWindowsCommands(t *testing.T) string {
	t.Helper()
	t.Setenv("LOCALAPPDATA", t.TempDir())
	marker := filepath.Join(t.TempDir(), "windows-commands.txt")
	oldLookPath := windowsLookPath
	oldExecCommand := windowsExecCommand
	oldPIDMatchesExecutable := windowsManagedPIDMatchesExecutable
	windowsLookPath = func(name string) (string, error) {
		switch name {
		case "schtasks":
			return "schtasks", nil
		case "powershell.exe":
			return "powershell.exe", nil
		default:
			return "", exec.ErrNotFound
		}
	}
	windowsExecCommand = func(name string, args ...string) *exec.Cmd {
		helperArgs := append([]string{"-test.run=TestWindowsCommandProbe", "--", name}, args...)
		cmd := exec.Command(os.Args[0], helperArgs...)
		cmd.Env = append(os.Environ(), "AGENTD_WINDOWS_COMMAND_MARKER="+marker)
		return cmd
	}
	windowsManagedPIDMatchesExecutable = func(int) bool { return true }
	t.Cleanup(func() {
		windowsLookPath = oldLookPath
		windowsExecCommand = oldExecCommand
		windowsManagedPIDMatchesExecutable = oldPIDMatchesExecutable
	})
	return marker
}

func TestWindowsCommandProbe(t *testing.T) {
	if len(os.Args) < 4 || os.Args[2] != "--" {
		return
	}
	marker := os.Getenv("AGENTD_WINDOWS_COMMAND_MARKER")
	file, err := os.OpenFile(marker, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	_, _ = fmt.Fprintln(file, strings.Join(os.Args[3:], "|"))
	_ = file.Close()

	commandArgs := os.Args[4:]
	if os.Args[3] == "schtasks" && len(commandArgs) > 0 {
		switch commandArgs[0] {
		case "/Query":
			if os.Getenv("AGENTD_FAKE_TASK_MISSING") == "1" {
				fmt.Fprintln(os.Stderr, "ERROR: The system cannot find the file specified.")
				os.Exit(1)
			}
			fmt.Fprintln(os.Stdout, "TaskName: Mimi Remote agentd")
		case "/Run":
			if os.Getenv("AGENTD_FAKE_TASK_RUNNING") == "1" {
				fmt.Fprintln(os.Stderr, "ERROR: The task is already running.")
				os.Exit(1)
			}
		case "/End":
			if os.Getenv("AGENTD_FAKE_TASK_END_DENIED") == "1" {
				fmt.Fprintln(os.Stderr, "ERROR: Access is denied.")
				os.Exit(1)
			}
			fmt.Fprintln(os.Stderr, "ERROR: The task is not currently running.")
			os.Exit(1)
		}
	}
	if os.Args[3] == "powershell.exe" {
		if strings.Contains(strings.Join(commandArgs, " "), "Get-ScheduledTask") {
			if os.Getenv("AGENTD_FAKE_TASK_STATE_ALWAYS_PENDING") == "1" {
				fmt.Fprint(os.Stdout, "Running")
				os.Exit(0)
			}
			if os.Getenv("AGENTD_FAKE_TASK_STATE_TRANSITION") == "1" {
				raw, _ := os.ReadFile(marker)
				if strings.Count(string(raw), "Get-ScheduledTask") == 1 {
					fmt.Fprint(os.Stdout, "Running")
					os.Exit(0)
				}
			}
			fmt.Fprint(os.Stdout, "Ready")
			os.Exit(0)
		}
		fmt.Fprintln(os.Stdout, "followed")
	}
	os.Exit(0)
}

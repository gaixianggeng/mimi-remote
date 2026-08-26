//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestManagedServiceHostCommandStartsAgentWithoutConsoleWindow(t *testing.T) {
	agentPath := `C:\Program Files\Mimi Remote\agentd.exe`
	logPath := `C:\Users\tester\AppData\Local\Mimi Remote\logs\agentd.log`

	command, err := managedServiceHostCommand(agentPath, logPath)
	if err != nil {
		t.Fatalf("managedServiceHostCommand returned error: %v", err)
	}
	if command.Path != agentPath {
		t.Fatalf("command path = %q, want %q", command.Path, agentPath)
	}
	wantArgs := []string{agentPath, "serve", "--managed-service", "--log-file", logPath}
	if !reflect.DeepEqual(command.Args, wantArgs) {
		t.Fatalf("command args = %#v, want %#v", command.Args, wantArgs)
	}
	if command.SysProcAttr == nil || !command.SysProcAttr.HideWindow {
		t.Fatalf("managed agentd must hide its Windows process: %#v", command.SysProcAttr)
	}
	if command.SysProcAttr.CreationFlags&createNoWindow == 0 {
		t.Fatalf("creation flags = %#x, want CREATE_NO_WINDOW", command.SysProcAttr.CreationFlags)
	}
	if command.SysProcAttr.CreationFlags&createSuspended == 0 {
		t.Fatalf("creation flags = %#x, want CREATE_SUSPENDED", command.SysProcAttr.CreationFlags)
	}
}

func TestManagedServiceHostCommandRequiresPaths(t *testing.T) {
	for _, testCase := range []struct {
		name      string
		agentPath string
		logPath   string
	}{
		{name: "missing agent", logPath: `C:\logs\agentd.log`},
		{name: "missing log", agentPath: `C:\Mimi Remote\agentd.exe`},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := managedServiceHostCommand(testCase.agentPath, testCase.logPath); err == nil {
				t.Fatal("missing managed-service path must fail")
			}
		})
	}
}

func TestManagedServiceJobUsesKillOnClose(t *testing.T) {
	job, err := createManagedServiceJob()
	if err != nil {
		t.Fatalf("createManagedServiceJob returned error: %v", err)
	}
	defer windows.CloseHandle(job)

	var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	if err := windows.QueryInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
		nil,
	); err != nil {
		t.Fatalf("QueryInformationJobObject returned error: %v", err)
	}
	if info.BasicLimitInformation.LimitFlags&windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE == 0 {
		t.Fatalf("job limit flags = %#x, want KILL_ON_JOB_CLOSE", info.BasicLimitInformation.LimitFlags)
	}
}

func TestManagedServiceJobKillsEntireProcessTreeWhenHostCloses(t *testing.T) {
	pidPath := t.TempDir() + `\child.pid`
	command := exec.Command(os.Args[0], "-test.run=TestManagedServiceTreeHelper")
	command.Env = append(os.Environ(),
		"MIMI_SERVICE_TREE_HELPER=parent",
		"MIMI_SERVICE_TREE_PID_PATH="+pidPath,
	)
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow | createSuspended,
	}

	job, err := createManagedServiceJob()
	if err != nil {
		t.Fatal(err)
	}
	jobOpen := true
	defer func() {
		if jobOpen {
			windows.CloseHandle(job)
		}
	}()
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	waitStarted := false
	defer func() {
		if !waitStarted && command.ProcessState == nil {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	}()
	if err := assignProcessToManagedServiceJob(job, uint32(command.Process.Pid)); err != nil {
		t.Fatal(err)
	}
	if err := resumeManagedServiceProcess(uint32(command.Process.Pid)); err != nil {
		t.Fatal(err)
	}

	childPID, err := waitForManagedServiceChildPID(pidPath, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	windows.CloseHandle(job)
	jobOpen = false

	waitDone := make(chan error, 1)
	waitStarted = true
	go func() { waitDone <- command.Wait() }()
	select {
	case <-waitDone:
	case <-time.After(5 * time.Second):
		_ = command.Process.Kill()
		<-waitDone
		t.Fatal("关闭服务 Job Object 后宿主子进程未退出")
	}
	if err := waitForWindowsProcessExit(childPID, 5*time.Second); err != nil {
		t.Fatalf("关闭服务 Job Object 后后代进程仍存活：%v", err)
	}
}

func TestManagedServiceTreeHelper(t *testing.T) {
	mode := os.Getenv("MIMI_SERVICE_TREE_HELPER")
	if mode == "" {
		return
	}
	if mode == "child" {
		time.Sleep(30 * time.Second)
		return
	}
	child := exec.Command(os.Args[0], "-test.run=TestManagedServiceTreeHelper")
	child.Env = append(os.Environ(), "MIMI_SERVICE_TREE_HELPER=child")
	child.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	pidPath := os.Getenv("MIMI_SERVICE_TREE_PID_PATH")
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(child.Process.Pid)), 0o600); err != nil {
		t.Fatal(err)
	}
	time.Sleep(30 * time.Second)
}

func TestManagedServiceCommandCapturesEarlyStderr(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=TestManagedServiceEarlyFailureHelper")
	command.Env = append(os.Environ(), "MIMI_SERVICE_EARLY_FAILURE_HELPER=1")
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow | createSuspended,
	}
	stderr := &boundedServiceOutput{limit: managedServiceStderrMaxBytes}
	command.Stderr = stderr
	if err := runManagedServiceCommand(command); err == nil {
		t.Fatal("early service failure must propagate")
	}
	if detail := stderr.Text(); !strings.Contains(detail, "agentd startup configuration failed") {
		t.Fatalf("early stderr was not captured: %q", detail)
	}
}

func TestManagedServiceEarlyFailureHelper(t *testing.T) {
	if os.Getenv("MIMI_SERVICE_EARLY_FAILURE_HELPER") == "" {
		return
	}
	_, _ = fmt.Fprintln(os.Stderr, "agentd startup configuration failed")
	os.Exit(7)
}

func waitForManagedServiceChildPID(path string, timeout time.Duration) (uint32, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(path)
		if err == nil {
			pid, parseErr := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 32)
			if parseErr != nil {
				return 0, parseErr
			}
			return uint32(pid), nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return 0, fmt.Errorf("服务测试进程未在 %s 内启动后代进程", timeout)
}

func waitForWindowsProcessExit(processID uint32, timeout time.Duration) error {
	process, err := windows.OpenProcess(windows.SYNCHRONIZE, false, processID)
	if err != nil {
		if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
			// 进程对象已经消失也表示 Job Object 成功清理了后代。
			return nil
		}
		return err
	}
	defer windows.CloseHandle(process)
	result, err := windows.WaitForSingleObject(process, uint32(timeout.Milliseconds()))
	if err != nil {
		return err
	}
	if result != windows.WAIT_OBJECT_0 {
		return fmt.Errorf("PID %d 等待结果 %#x", processID, result)
	}
	return nil
}

func TestBoundedServiceOutputPreservesUsefulErrorWithoutUnboundedGrowth(t *testing.T) {
	output := &boundedServiceOutput{limit: 8}
	input := []byte("agentd startup failed")
	if written, err := output.Write(input); err != nil || written != len(input) {
		t.Fatalf("Write = (%d, %v), want (%d, nil)", written, err, len(input))
	}
	if got := output.buffer.Len(); got != 8 {
		t.Fatalf("captured bytes = %d, want 8", got)
	}
	if text := output.Text(); !strings.Contains(text, "agentd s") || !strings.Contains(text, "已截断") {
		t.Fatalf("bounded stderr text = %q", text)
	}
}

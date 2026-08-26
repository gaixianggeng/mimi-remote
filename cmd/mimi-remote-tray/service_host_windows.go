//go:build windows

package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	createSuspended              = 0x00000004
	managedServiceStderrMaxBytes = 16 * 1024
)

func runManagedServiceHost(agentPath, logPath string) error {
	command, err := managedServiceHostCommand(agentPath, logPath)
	if err != nil {
		return err
	}
	stderr := &boundedServiceOutput{limit: managedServiceStderrMaxBytes}
	command.Stderr = stderr
	if err := runManagedServiceCommand(command); err != nil {
		if detail := stderr.Text(); detail != "" {
			return fmt.Errorf("agentd 后台服务退出：%w；stderr=%q", err, detail)
		}
		return fmt.Errorf("agentd 后台服务退出：%w", err)
	}
	return nil
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
		CreationFlags: createNoWindow | createSuspended,
	}
	// 计划任务运行的是 windowsgui 子系统的托盘宿主。显式丢弃标准句柄，
	// 避免 agentd 因继承无效控制台句柄而退出；服务日志仍写入 --log-file。
	command.Stdin = nil
	command.Stdout = io.Discard
	return command, nil
}

func runManagedServiceCommand(command *exec.Cmd) error {
	job, err := createManagedServiceJob()
	if err != nil {
		return fmt.Errorf("创建 Windows 服务 Job Object 失败：%w", err)
	}
	defer windows.CloseHandle(job)

	if err := command.Start(); err != nil {
		return err
	}
	abort := func() {
		if command.Process != nil {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	}
	if err := assignProcessToManagedServiceJob(job, uint32(command.Process.Pid)); err != nil {
		abort()
		return fmt.Errorf("绑定 agentd 到 Windows 服务 Job Object 失败：%w", err)
	}
	if err := resumeManagedServiceProcess(uint32(command.Process.Pid)); err != nil {
		abort()
		return fmt.Errorf("恢复 agentd 后台进程失败：%w", err)
	}
	return command.Wait()
}

func createManagedServiceJob() (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
	); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

func assignProcessToManagedServiceJob(job windows.Handle, processID uint32) error {
	process, err := windows.OpenProcess(
		windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION,
		false,
		processID,
	)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(process)
	return windows.AssignProcessToJobObject(job, process)
}

func resumeManagedServiceProcess(processID uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)

	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	for err = windows.Thread32First(snapshot, &entry); err == nil; err = windows.Thread32Next(snapshot, &entry) {
		if entry.OwnerProcessID != processID {
			continue
		}
		thread, openErr := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
		if openErr != nil {
			return openErr
		}
		_, resumeErr := windows.ResumeThread(thread)
		windows.CloseHandle(thread)
		return resumeErr
	}
	return fmt.Errorf("找不到 agentd 的挂起主线程")
}

type boundedServiceOutput struct {
	buffer    bytes.Buffer
	limit     int
	truncated bool
}

func (b *boundedServiceOutput) Write(data []byte) (int, error) {
	written := len(data)
	remaining := b.limit - b.buffer.Len()
	if remaining > 0 {
		if remaining > len(data) {
			remaining = len(data)
		}
		_, _ = b.buffer.Write(data[:remaining])
	}
	if remaining < len(data) {
		b.truncated = true
	}
	return written, nil
}

func (b *boundedServiceOutput) Text() string {
	value := strings.TrimSpace(b.buffer.String())
	if b.truncated {
		value += " [stderr 已截断]"
	}
	return value
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

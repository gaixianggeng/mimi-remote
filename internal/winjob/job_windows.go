//go:build windows

// Package winjob starts Windows processes in a private kill-on-close Job Object.
package winjob

import (
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

type Job struct {
	mu     sync.Mutex
	handle windows.Handle
}

// Start assigns the command to a kill-on-close Job before its first thread runs.
func Start(cmd *exec.Cmd) (*Job, error) {
	if cmd == nil {
		return nil, fmt.Errorf("启动 Windows 进程组失败：命令为空")
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.CreationFlags |= windows.CREATE_SUSPENDED
	job, err := createJob()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		job.Close()
		return nil, err
	}
	abort := func(cause error) error {
		job.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
		return cause
	}

	pid := cmd.Process.Pid
	process, err := windows.OpenProcess(
		windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE,
		false,
		uint32(pid),
	)
	if err != nil {
		return nil, abort(fmt.Errorf("打开 Windows 进程失败 pid=%d：%w", pid, err))
	}
	assignErr := windows.AssignProcessToJobObject(job.handle, process)
	windows.CloseHandle(process)
	if assignErr != nil {
		return nil, abort(fmt.Errorf("绑定 Windows Job Object 失败 pid=%d：%w", pid, assignErr))
	}
	if err := resumeProcess(uint32(pid)); err != nil {
		return nil, abort(err)
	}

	return job, nil
}

func createJob() (*Job, error) {
	handle, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, fmt.Errorf("创建 Windows Job Object 失败：%w", err)
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(
		handle,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
	); err != nil {
		windows.CloseHandle(handle)
		return nil, fmt.Errorf("配置 Windows Job Object 失败：%w", err)
	}
	return &Job{handle: handle}, nil
}

func resumeProcess(pid uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return fmt.Errorf("枚举 Windows 进程线程失败 pid=%d：%w", pid, err)
	}
	defer windows.CloseHandle(snapshot)

	entry := windows.ThreadEntry32{}
	entry.Size = uint32(unsafe.Sizeof(entry))
	if err := windows.Thread32First(snapshot, &entry); err != nil {
		return fmt.Errorf("读取 Windows 进程线程失败 pid=%d：%w", pid, err)
	}
	for {
		if entry.OwnerProcessID == pid {
			thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
			if err != nil {
				return fmt.Errorf("打开 Windows 进程主线程失败 pid=%d：%w", pid, err)
			}
			_, resumeErr := windows.ResumeThread(thread)
			windows.CloseHandle(thread)
			if resumeErr != nil {
				return fmt.Errorf("恢复 Windows 进程主线程失败 pid=%d：%w", pid, resumeErr)
			}
			return nil
		}
		if err := windows.Thread32Next(snapshot, &entry); err != nil {
			return fmt.Errorf("未找到 Windows 进程主线程 pid=%d：%w", pid, err)
		}
	}
}

func (job *Job) Terminate(timeout time.Duration) bool {
	job.mu.Lock()
	defer job.mu.Unlock()
	if job.handle == 0 {
		return true
	}
	if err := windows.TerminateJobObject(job.handle, 1); err != nil {
		return false
	}
	event, err := windows.WaitForSingleObject(job.handle, uint32(timeout/time.Millisecond))
	return err == nil && event == windows.WAIT_OBJECT_0
}

func (job *Job) Close() {
	job.mu.Lock()
	defer job.mu.Unlock()
	if job.handle == 0 {
		return
	}
	windows.CloseHandle(job.handle)
	job.handle = 0
}

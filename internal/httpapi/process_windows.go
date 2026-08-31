//go:build windows

package httpapi

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const gatewayTaskkillTimeout = 5 * time.Second

type gatewayWindowsJob struct {
	mu     sync.Mutex
	handle windows.Handle
}

var gatewayWindowsJobs sync.Map

func configureGatewayCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	// 先挂起根进程，确保它在绑定 Job Object 前不会派生子进程。
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | windows.CREATE_SUSPENDED,
	}
}

func startGatewayCommand(cmd *exec.Cmd) error {
	if cmd == nil {
		return fmt.Errorf("启动 Windows 进程组失败：命令为空")
	}
	job, err := createGatewayWindowsJob()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		job.close()
		return err
	}
	abort := func(cause error) error {
		_ = job.terminate()
		job.close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
		return cause
	}

	pid := gatewayProcessID(cmd)
	process, err := windows.OpenProcess(
		windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE,
		false,
		uint32(pid),
	)
	if err != nil {
		return abort(fmt.Errorf("打开 Windows 进程失败 pid=%d：%w", pid, err))
	}
	assignErr := windows.AssignProcessToJobObject(job.handle, process)
	windows.CloseHandle(process)
	if assignErr != nil {
		return abort(fmt.Errorf("绑定 Windows Job Object 失败 pid=%d：%w", pid, assignErr))
	}
	if err := resumeGatewayWindowsProcess(uint32(pid)); err != nil {
		return abort(err)
	}

	gatewayWindowsJobs.Store(cmd, job)
	return nil
}

func releaseGatewayProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	value, ok := gatewayWindowsJobs.LoadAndDelete(cmd)
	if !ok {
		return
	}
	value.(*gatewayWindowsJob).close()
}

func terminateGatewayProcessGroup(cmd *exec.Cmd, _ bool) {
	if cmd == nil {
		return
	}
	if value, ok := gatewayWindowsJobs.Load(cmd); ok {
		if value.(*gatewayWindowsJob).terminate() {
			return
		}
	}

	// Job Object 无法使用时保留强制 taskkill 作为最后退路。
	pid := gatewayProcessID(cmd)
	if pid <= 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), gatewayTaskkillTimeout)
	defer cancel()
	args := []string{"/PID", strconv.Itoa(pid), "/T", "/F"}
	if err := exec.CommandContext(ctx, "taskkill.exe", args...).Run(); err != nil && cmd.Process != nil {
		// taskkill reports an error when the process already exited. Process.Kill is
		// likewise safe to ignore, and is a last resort if taskkill is unavailable.
		_ = cmd.Process.Kill()
	}
}

func createGatewayWindowsJob() (*gatewayWindowsJob, error) {
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
	return &gatewayWindowsJob{handle: handle}, nil
}

func resumeGatewayWindowsProcess(pid uint32) error {
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

func (job *gatewayWindowsJob) terminate() bool {
	job.mu.Lock()
	defer job.mu.Unlock()
	if job.handle == 0 {
		return true
	}
	if err := windows.TerminateJobObject(job.handle, 1); err != nil {
		return false
	}
	event, err := windows.WaitForSingleObject(job.handle, uint32(gatewayTaskkillTimeout/time.Millisecond))
	return err == nil && event == windows.WAIT_OBJECT_0
}

func (job *gatewayWindowsJob) close() {
	job.mu.Lock()
	defer job.mu.Unlock()
	if job.handle == 0 {
		return
	}
	windows.CloseHandle(job.handle)
	job.handle = 0
}

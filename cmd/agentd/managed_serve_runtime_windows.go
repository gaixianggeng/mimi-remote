//go:build windows

package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var managedServeLifetimeJob windows.Handle

func prepareManagedServeRuntime(enabled bool) (func(), error) {
	if !enabled {
		return nil, nil
	}
	pidPath, err := windowsManagedPIDPath()
	if err != nil {
		return nil, err
	}
	stopPath, err := windowsManagedStopPath()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(windowsManagedRuntimeDir(pidPath), 0o700); err != nil {
		return nil, fmt.Errorf("创建 Windows 后台服务状态目录失败：%w", err)
	}
	_ = os.Remove(stopPath)
	pid := strconv.Itoa(os.Getpid())
	tempPath := pidPath + "." + pid + ".tmp"
	if err := os.WriteFile(tempPath, []byte(pid+"\n"), 0o600); err != nil {
		return nil, fmt.Errorf("写入 Windows 后台服务 PID 失败：%w", err)
	}
	if err := os.Rename(tempPath, pidPath); err != nil {
		_ = os.Remove(tempPath)
		return nil, fmt.Errorf("发布 Windows 后台服务 PID 失败：%w", err)
	}
	if err := retainManagedServeProcessTree(); err != nil {
		_ = os.Remove(pidPath)
		return nil, err
	}
	return func() {
		data, readErr := os.ReadFile(pidPath)
		if readErr == nil && strings.TrimSpace(string(data)) == pid {
			_ = os.Remove(pidPath)
		}
		_ = os.Remove(stopPath)
	}, nil
}

func retainManagedServeProcessTree() error {
	if managedServeLifetimeJob != 0 {
		return nil
	}
	job, err := createManagedServeLifetimeJob()
	if err != nil {
		return err
	}
	// agentd 已由 Task Scheduler 直接启动，不需要挂起或枚举线程。把当前进程
	// 加入自持有的嵌套 Job，进程退出时句柄关闭，Windows 会清理全部后代。
	if err := windows.AssignProcessToJobObject(job, windows.CurrentProcess()); err != nil {
		windows.CloseHandle(job)
		return fmt.Errorf("绑定 Windows 后台服务进程树失败：%w", err)
	}
	// 句柄必须保持到进程退出；主动关闭会因 KILL_ON_JOB_CLOSE 终止当前 agentd。
	managedServeLifetimeJob = job
	return nil
}

func createManagedServeLifetimeJob() (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, fmt.Errorf("创建 Windows 后台服务 Job Object 失败：%w", err)
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
		return 0, fmt.Errorf("配置 Windows 后台服务 Job Object 失败：%w", err)
	}
	return job, nil
}

//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	darwinProcInfoCallPIDInfo = 2
	darwinProcPIDListFDs      = 1
)

// darwinProcFDInfo 与 Darwin 的 proc_fdinfo ABI 保持一致。PROC_PIDLISTFDS
// 返回的每一项都对应一个实际打开的描述符；不能使用 proc_bsdinfo.pbi_nfiles，
// 后者在实机上反映文件表容量，可能恰好等于 256 而不是当前打开数。
type darwinProcFDInfo struct {
	FD   int32
	Type uint32
}

// InspectSharedDaemonDiagnostics 从当前 Unix socket 的真实 peer PID 开始取证，
// 不信任 plist、缓存 PID 或进程名。诊断只读，不会启动、停止或迁移 daemon。
func InspectSharedDaemonDiagnostics(
	ctx context.Context,
	options LocalDaemonOptions,
) (SharedDaemonDiagnostics, error) {
	status := SharedDaemonDiagnostics{
		Supported:     true,
		OwnerState:    SharedDaemonOwnerStateUnknown,
		ResourceState: SharedDaemonResourceStateUnknown,
	}
	if err := ctx.Err(); err != nil {
		return status, err
	}
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return status, err
	}
	process, err := inspectSharedDaemonListenerIdentity(ctx, socketPath)
	if err != nil {
		return status, fmt.Errorf("读取共享 daemon listener 失败：%w", err)
	}
	openFiles, err := sharedDaemonProcessOpenFileCount(process.PID)
	if err != nil {
		return status, err
	}
	children, err := sharedDaemonDirectChildCount(process.PID)
	if err != nil {
		return status, err
	}

	status.ListenerPID = process.PID
	status.ListenerStartedAt = time.Unix(process.StartSec, int64(process.StartUsec)*int64(time.Microsecond)).UTC()
	status.OpenFileDescriptors = openFiles
	status.DirectChildProcesses = children
	status.OwnerState = inspectSharedDaemonOwnerState(ctx, options, socketPath, process.PID)
	if status.OwnerState == SharedDaemonOwnerStateStable {
		limit := sharedDaemonSoftFileLimit
		status.OwnerTargetFDSoftLimit = &limit
	}
	applySharedDaemonResourceState(&status)
	return status, nil
}

// inspectSharedDaemonListenerIdentity 只读取资源诊断实际需要的身份字段。
// 不读取命令行或环境变量，避免把接管校验的敏感取证面带入常规状态刷新。
func inspectSharedDaemonListenerIdentity(
	ctx context.Context,
	socketPath string,
) (sharedDaemonListenerProcess, error) {
	pid, peerUID, err := sharedDaemonSocketPeer(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	kinfo, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(kinfo.Proc.P_pid) != pid {
		return sharedDaemonListenerProcess{}, fmt.Errorf("读取 socket owner 进程身份失败")
	}
	if int(kinfo.Eproc.Ucred.Uid) != peerUID {
		return sharedDaemonListenerProcess{}, fmt.Errorf("socket peer UID 与进程 UID 不一致")
	}
	return sharedDaemonListenerProcess{
		PID:       pid,
		UID:       peerUID,
		StartSec:  kinfo.Proc.P_starttime.Sec,
		StartUsec: kinfo.Proc.P_starttime.Usec,
	}, nil
}

func inspectSharedDaemonOwnerState(
	ctx context.Context,
	options LocalDaemonOptions,
	socketPath string,
	listenerPID int,
) SharedDaemonOwnerState {
	if !options.StableOwner {
		return SharedDaemonOwnerStateExternal
	}
	owner, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return SharedDaemonOwnerStateUnknown
	}
	if !owner.Installed || !owner.Loaded || !owner.Secure {
		return SharedDaemonOwnerStateUnavailable
	}
	if owner.MigrationRequired || !owner.RunAtLoad {
		return SharedDaemonOwnerStateMigrationPending
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	if err != nil || !strings.EqualFold(strings.TrimSpace(lifecycle.Status), "running") {
		return SharedDaemonOwnerStateUnknown
	}
	if lifecycle.Backend == nil || lifecycle.PID == nil {
		return SharedDaemonOwnerStateUnmanagedListener
	}
	if !strings.EqualFold(strings.TrimSpace(*lifecycle.Backend), "pid") ||
		!sameCanonicalPath(lifecycle.SocketPath, socketPath) ||
		int(*lifecycle.PID) != listenerPID {
		return SharedDaemonOwnerStateListenerMismatch
	}
	return SharedDaemonOwnerStateStable
}

func sharedDaemonProcessOpenFileCount(pid int) (int, error) {
	if pid <= 1 {
		return 0, fmt.Errorf("共享 daemon PID 无效")
	}
	entrySize := unsafe.Sizeof(darwinProcFDInfo{})
	required, _, errno := unix.Syscall6(
		unix.SYS_PROC_INFO,
		darwinProcInfoCallPIDInfo,
		uintptr(pid),
		darwinProcPIDListFDs,
		0,
		0,
		0,
	)
	if errno != 0 {
		return 0, fmt.Errorf("读取共享 daemon FD 数失败：%w", errno)
	}
	if required == 0 {
		return 0, nil
	}
	// 在 size query 与实际读取之间目标可能打开新 FD；额外预留 32 项，并在
	// 内核仍填满缓冲区时放大重试，避免把瞬时增长截断成偏低水位。
	capacity := int(required/entrySize) + 32
	for attempt := 0; attempt < 3; attempt++ {
		entries := make([]darwinProcFDInfo, capacity)
		written, _, readErrno := unix.Syscall6(
			unix.SYS_PROC_INFO,
			darwinProcInfoCallPIDInfo,
			uintptr(pid),
			darwinProcPIDListFDs,
			0,
			uintptr(unsafe.Pointer(&entries[0])),
			uintptr(len(entries))*entrySize,
		)
		if readErrno != 0 {
			return 0, fmt.Errorf("读取共享 daemon FD 列表失败：%w", readErrno)
		}
		if written%entrySize != 0 {
			return 0, fmt.Errorf("共享 daemon FD 列表元数据不完整")
		}
		count := int(written / entrySize)
		if count < len(entries) {
			return count, nil
		}
		capacity *= 2
	}
	return 0, fmt.Errorf("共享 daemon FD 列表持续增长，无法取得稳定水位")
}

func sharedDaemonDirectChildCount(pid int) (int, error) {
	// Darwin 不提供稳定的 kern.proc.ppid sysctl selector；读取一次内核进程表
	// 后按 PPID 过滤，仍然不需要 fork ps/pgrep，daemon 接近 EMFILE 时也可用。
	processes, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return 0, fmt.Errorf("读取共享 daemon 子进程数失败：%w", err)
	}
	count := 0
	for index := range processes {
		if int(processes[index].Eproc.Ppid) == pid && processes[index].Proc.P_pid > 0 {
			count++
		}
	}
	return count, nil
}

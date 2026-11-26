//go:build darwin

package main

import (
	"context"
	"net"
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

func trustedForegroundPeer(ctx context.Context, conn net.Conn) bool {
	pid, err := darwinCoreSocketPID(ctx, conn.RemoteAddr().(*net.TCPAddr).AddrPort(), conn.LocalAddr().(*net.TCPAddr).AddrPort())
	if err != nil {
		return false
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(info.Proc.P_pid) != pid || info.Eproc.Ucred.Uid != uint32(os.Geteuid()) {
		return false
	}
	// proc_pidpath wraps proc_info(PROC_INFO_CALL_PIDINFO, PROC_PIDPATHINFO).
	// The kernel returns the executable vnode path, independent of argv.
	const procInfoCallPIDInfo, procPIDPathInfo = 2, 11
	var path [4096]byte
	_, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, procInfoCallPIDInfo, uintptr(pid), procPIDPathInfo, 0, uintptr(unsafe.Pointer(&path[0])), uintptr(len(path)))
	if errno != 0 {
		return false
	}
	exe, err := os.Executable()
	if err != nil {
		return false
	}
	self, err := os.Stat(exe)
	if err != nil {
		return false
	}
	actual, err := os.Stat(unix.ByteSliceToString(path[:]))
	return err == nil && os.SameFile(self, actual)
}

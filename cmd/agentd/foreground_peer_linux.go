//go:build linux

package main

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

func trustedForegroundPeer(ctx context.Context, conn net.Conn) bool {
	inode, err := linuxCoreSocketInode(ctx, conn.RemoteAddr().(*net.TCPAddr).AddrPort(), conn.LocalAddr().(*net.TCPAddr).AddrPort())
	if err != nil {
		return false
	}
	self, err := os.Stat("/proc/self/exe")
	if err != nil {
		return false
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if ctx.Err() != nil {
			return false
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		dir := filepath.Join("/proc", entry.Name())
		exe, err := os.Stat(filepath.Join(dir, "exe"))
		if err != nil || !os.SameFile(self, exe) {
			continue
		}
		proc, err := os.Stat(dir)
		if err == nil && proc.Sys().(*syscall.Stat_t).Uid == uint32(os.Geteuid()) && linuxOwnsCoreSocket(pid, inode) {
			return true
		}
	}
	return false
}

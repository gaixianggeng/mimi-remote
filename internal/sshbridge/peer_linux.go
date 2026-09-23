//go:build linux

package sshbridge

import (
	"errors"
	"net"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func validatePeer(conn net.Conn) error {
	local, ok := conn.(syscall.Conn)
	if !ok {
		return errors.New("SSH 命令桥必须使用本机 Unix socket")
	}
	raw, err := local.SyscallConn()
	if err != nil {
		return err
	}
	var credentials *unix.Ucred
	var peerErr error
	if err := raw.Control(func(fd uintptr) {
		credentials, peerErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return err
	}
	if peerErr != nil || credentials == nil || credentials.Uid != uint32(os.Getuid()) {
		return errors.New("SSH 命令桥对端不属于当前用户")
	}
	return nil
}

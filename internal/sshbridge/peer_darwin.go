//go:build darwin

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
	var credentials *unix.Xucred
	var peerErr error
	if err := raw.Control(func(fd uintptr) {
		credentials, peerErr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); err != nil {
		return err
	}
	if peerErr != nil || credentials == nil || credentials.Uid != uint32(os.Getuid()) {
		return errors.New("SSH 命令桥对端不属于当前用户")
	}
	return nil
}

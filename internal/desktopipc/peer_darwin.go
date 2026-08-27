//go:build darwin

package desktopipc

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"runtime"
	"unsafe"

	"golang.org/x/sys/unix"
)

func verifyPeer(conn net.Conn) error {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return fmt.Errorf("Desktop IPC peer is not a Unix socket")
	}
	raw, err := unixConn.SyscallConn()
	if err != nil {
		return fmt.Errorf("read Desktop IPC peer fd: %w", err)
	}
	var peerPID int
	var peerUID uint32
	var controlErr error
	if err := raw.Control(func(fd uintptr) {
		peerPID, controlErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
		if controlErr != nil {
			return
		}
		credentials, credentialsErr := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if credentialsErr != nil {
			controlErr = credentialsErr
			return
		}
		peerUID = credentials.Uid
	}); err != nil {
		return fmt.Errorf("read Desktop IPC peer: %w", err)
	}
	if controlErr != nil {
		return fmt.Errorf("read Desktop IPC peer identity: %w", controlErr)
	}
	if peerPID <= 1 || peerUID != uint32(os.Getuid()) {
		return fmt.Errorf("Desktop IPC peer is not owned by the current user")
	}
	identifier, err := csopsString(peerPID, 11)
	if err != nil {
		return err
	}
	teamID, err := csopsString(peerPID, 14)
	if err != nil {
		return err
	}
	var flags uint32
	_, _, errno := unix.Syscall6(
		unix.SYS_CSOPS,
		uintptr(peerPID),
		0,
		uintptr(unsafe.Pointer(&flags)),
		unsafe.Sizeof(flags),
		0,
		0,
	)
	runtime.KeepAlive(&flags)
	if errno != 0 {
		return fmt.Errorf("read Desktop IPC peer signature state: %w", errno)
	}
	const validHardenedRuntime = 0x00000001 | 0x00010000
	if flags&validHardenedRuntime != validHardenedRuntime ||
		identifier != "com.openai.codex" || teamID != "2DC432GLL2" {
		return fmt.Errorf("Desktop IPC peer is not the verified OpenAI Desktop bundle")
	}
	return nil
}

func csopsString(pid int, operation uintptr) (string, error) {
	buffer := make([]byte, 256)
	_, _, errno := unix.Syscall6(
		unix.SYS_CSOPS,
		uintptr(pid),
		operation,
		uintptr(unsafe.Pointer(&buffer[0])),
		uintptr(len(buffer)),
		0,
		0,
	)
	runtime.KeepAlive(buffer)
	if errno != 0 {
		return "", fmt.Errorf("read Desktop IPC peer signature identity: %w", errno)
	}
	if len(buffer) < 9 || binary.BigEndian.Uint32(buffer[0:4]) != 0 {
		return "", fmt.Errorf("Desktop IPC peer signature identity is invalid")
	}
	total := int(binary.BigEndian.Uint32(buffer[4:8]))
	if total < 9 || total > len(buffer) {
		return "", fmt.Errorf("Desktop IPC peer signature length is invalid")
	}
	payload := buffer[8:total]
	nul := bytes.IndexByte(payload, 0)
	if nul <= 0 || nul != len(payload)-1 {
		return "", fmt.Errorf("Desktop IPC peer signature is not terminated")
	}
	return string(payload[:nul]), nil
}

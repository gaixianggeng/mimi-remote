//go:build darwin

package desktopipc

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

func verifyPeer(conn net.Conn) (DesktopInfo, error) {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return DesktopInfo{}, fmt.Errorf("Desktop IPC peer is not a Unix socket")
	}
	raw, err := unixConn.SyscallConn()
	if err != nil {
		return DesktopInfo{}, fmt.Errorf("read Desktop IPC peer fd: %w", err)
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
		return DesktopInfo{}, fmt.Errorf("read Desktop IPC peer: %w", err)
	}
	if controlErr != nil {
		return DesktopInfo{}, fmt.Errorf("read Desktop IPC peer identity: %w", controlErr)
	}
	if peerPID <= 1 || peerUID != uint32(os.Getuid()) {
		return DesktopInfo{}, fmt.Errorf("Desktop IPC peer is not owned by the current user")
	}
	identifier, err := csopsString(peerPID, 11)
	if err != nil {
		return DesktopInfo{}, err
	}
	teamID, err := csopsString(peerPID, 14)
	if err != nil {
		return DesktopInfo{}, err
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
		return DesktopInfo{}, fmt.Errorf("read Desktop IPC peer signature state: %w", errno)
	}
	const validHardenedRuntime = 0x00000001 | 0x00010000
	if flags&validHardenedRuntime != validHardenedRuntime ||
		identifier != "com.openai.codex" || teamID != "2DC432GLL2" {
		return DesktopInfo{}, fmt.Errorf("Desktop IPC peer is not the verified OpenAI Desktop bundle")
	}

	// 签名只能识别连接进程。版本和 build 必须来自同一 PID，
	// 避免另一份 ChatGPT.app 安装副本错误通过 build gate。
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := desktopCommandOutput(ctx, "/bin/ps", "-p", strconv.Itoa(peerPID), "-o", "comm=")
	if err != nil {
		return DesktopInfo{}, fmt.Errorf("read Desktop IPC peer executable: %w", err)
	}
	bundle := desktopBundlePath(strings.TrimSpace(string(output)))
	if bundle == "" {
		return DesktopInfo{}, fmt.Errorf("Desktop IPC peer executable is outside an app bundle")
	}
	info, err := inspectDesktopBundle(bundle)
	if err != nil {
		return DesktopInfo{}, err
	}
	return info, nil
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

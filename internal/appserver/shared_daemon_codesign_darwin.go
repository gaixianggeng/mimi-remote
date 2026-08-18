//go:build darwin

package appserver

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"runtime"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	darwinCSOpsStatus   = 0
	darwinCSOpsIdentity = 11
	darwinCSOpsTeamID   = 14
	darwinCSValid       = 0x00000001
	darwinCSRuntime     = 0x00010000
)

type sharedDaemonRunningCodeSignature struct {
	Flags      uint32
	Identifier string
	TeamID     string
}

// sharedDaemonRunningCodeSignatureForPID 直接询问内核当前正在执行的 code
// object，而不是只解析磁盘 Mach-O 的声明。这样 App 更新、路径替换或损坏签名
// 不能借旧 metadata 通过最终父链验收。
func sharedDaemonRunningCodeSignatureForPID(pid int) (sharedDaemonRunningCodeSignature, error) {
	if pid <= 1 {
		return sharedDaemonRunningCodeSignature{}, fmt.Errorf("代码签名 PID 无效")
	}
	var flags uint32
	_, _, errno := unix.Syscall6(
		unix.SYS_CSOPS,
		uintptr(pid),
		darwinCSOpsStatus,
		uintptr(unsafe.Pointer(&flags)),
		unsafe.Sizeof(flags),
		0,
		0,
	)
	runtime.KeepAlive(&flags)
	if errno != 0 {
		return sharedDaemonRunningCodeSignature{}, fmt.Errorf("读取运行中代码签名状态失败：%w", errno)
	}
	identifier, err := sharedDaemonCSOpsString(pid, darwinCSOpsIdentity)
	if err != nil {
		return sharedDaemonRunningCodeSignature{}, err
	}
	teamID, err := sharedDaemonCSOpsString(pid, darwinCSOpsTeamID)
	if err != nil {
		return sharedDaemonRunningCodeSignature{}, err
	}
	return sharedDaemonRunningCodeSignature{
		Flags:      flags,
		Identifier: identifier,
		TeamID:     teamID,
	}, nil
}

func sharedDaemonCSOpsString(pid int, operation uintptr) (string, error) {
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
		return "", fmt.Errorf("读取运行中代码签名身份失败：%w", errno)
	}
	return parseSharedDaemonCSOpsStringBlob(buffer)
}

func parseSharedDaemonCSOpsStringBlob(buffer []byte) (string, error) {
	// CS_OPS_IDENTITY/TEAMID 返回 cs_blob：两个 big-endian uint32 header，
	// 第二项是 header + NUL payload 的总长度。
	if len(buffer) < 9 {
		return "", fmt.Errorf("运行中代码签名身份长度无效")
	}
	if binary.BigEndian.Uint32(buffer[0:4]) != 0 {
		return "", fmt.Errorf("运行中代码签名身份 header 无效")
	}
	total := int(binary.BigEndian.Uint32(buffer[4:8]))
	if total < 9 || total > len(buffer) {
		return "", fmt.Errorf("运行中代码签名身份 metadata 无效")
	}
	payload := buffer[8:total]
	nul := bytes.IndexByte(payload, 0)
	if nul <= 0 || nul != len(payload)-1 {
		return "", fmt.Errorf("运行中代码签名身份没有规范 NUL 结尾")
	}
	return string(payload[:nul]), nil
}

func validateSharedDaemonRunningCodeSignature(pid int, expectedIdentifier string) error {
	signature, err := sharedDaemonRunningCodeSignatureForPID(pid)
	if err != nil {
		return err
	}
	if signature.Flags&darwinCSValid == 0 || signature.Flags&darwinCSRuntime == 0 ||
		signature.Identifier != expectedIdentifier || signature.TeamID != sharedDaemonOpenAITeamIdentifier {
		return fmt.Errorf("运行中进程不是受支持的 OpenAI hardened runtime")
	}
	return nil
}

//go:build windows

package windowslan

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"golang.org/x/sys/windows"
)

func systemPowerShell() (string, error) {
	dir, err := windows.GetSystemDirectory()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "WindowsPowerShell", "v1.0", "powershell.exe"), nil
}

// Inspect the kernel's established socket and the process token without
// invoking CIM or starting a subprocess. Only managed operations also query
// the registered scheduler action, using the lightweight Task Scheduler COM API.
func TrustedPeer(ctx context.Context, conn net.Conn, expectedPID int, taskName string) bool {
	local, localOK := conn.LocalAddr().(*net.TCPAddr)
	remote, remoteOK := conn.RemoteAddr().(*net.TCPAddr)
	if !localOK || !remoteOK || !local.IP.IsLoopback() || !remote.IP.IsLoopback() || ctx.Err() != nil {
		return false
	}
	pid := loopbackPeerPID(remote.AddrPort(), local.AddrPort())
	for attempt := 0; pid == 0 && attempt < 3; attempt++ {
		select {
		case <-ctx.Done():
			return false
		case <-time.After(25 * time.Millisecond):
		}
		pid = loopbackPeerPID(remote.AddrPort(), local.AddrPort())
	}
	if pid == 0 || expectedPID > 0 && uint32(expectedPID) != pid {
		return false
	}
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(process)
	if !SameExecutableIdentity(process) || !sameProcessUser(process) {
		return false
	}
	if taskName == "" {
		return true
	}
	var parent windows.PROCESS_BASIC_INFORMATION
	if err := windows.NtQueryInformationProcess(process, windows.ProcessBasicInformation, unsafe.Pointer(&parent), uint32(unsafe.Sizeof(parent)), nil); err != nil {
		return false
	}
	wrapper, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(parent.InheritedFromUniqueProcessId))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(wrapper)
	image := processImage(wrapper)
	if strings.HasPrefix(image, `\\?\`) {
		canonical, err := CanonicalFirewallPath(image)
		if err != nil {
			return false
		}
		image = canonical
	}
	if image == "" || !sameProcessUser(wrapper) {
		return false
	}
	shell, err := systemPowerShell()
	if err != nil {
		return false
	}
	script := `$ErrorActionPreference='Stop'
$scheduler=New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$task=$scheduler.GetFolder('\').GetTask($env:MIMI_TASK_NAME)
` + verifyRunningTask
	env := append(os.Environ(), "MIMI_TASK_NAME="+taskName, "MIMI_OWNER_WRAPPER="+image,
		"MIMI_OWNER_WRAPPER_PID="+strconv.FormatUint(uint64(parent.InheritedFromUniqueProcessId), 10))
	out, err := cliinspect.Stdout(ctx, shell, env, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	return err == nil && strings.TrimSpace(string(out)) == "owned"
}

// The same installed wrapper can also be launched manually. Its image and
// the task's Running state alone do not identify the listener's task instance.
const verifyRunningTask = `
$actions=$task.Definition.Actions
$running=$task.GetInstances(0)
if ($task.State -eq 4 -and $actions.Count -eq 1 -and $actions.Item(1).Type -eq 0 -and
    $actions.Item(1).Path -ieq $env:MIMI_OWNER_WRAPPER -and $running.Count -eq 1 -and
    $running.Item(1).EnginePID -eq [uint32]$env:MIMI_OWNER_WRAPPER_PID) {
    [Console]::Out.Write('owned')
}`

const peerVolumeNameNT = 0x2

// SameExecutableIdentity compares a peer process image against the current
// executable using on-disk file identity (VolumeSerialNumber + FileIndex) and
// canonical NT native paths from non-reparse handles, so a broker launched by
// \\?\Volume{GUID} (or a long path) recognizes a managed service started by
// drive letter (or an 8.3 short path) without trusting raw path strings or
// reparse points.
func SameExecutableIdentity(process windows.Handle) bool {
	peerNative := processImageWithFlags(process, windows.PROCESS_NAME_NATIVE)
	selfNative := processImageWithFlags(windows.CurrentProcess(), windows.PROCESS_NAME_NATIVE)
	if peerNative == "" || selfNative == "" {
		return false
	}
	selfPath, err := os.Executable()
	if err != nil {
		return false
	}
	peerPath := processImage(process)
	if peerPath == "" {
		if !strings.HasPrefix(peerNative, `\Device\`) {
			return false
		}
		peerPath = `\\?\GLOBALROOT` + peerNative
	}
	selfInfo, selfFinalNative, okSelf := regularFileIdentityWithNative(selfPath)
	peerInfo, peerFinalNative, okPeer := regularFileIdentityWithNative(peerPath)
	if !okSelf || !okPeer {
		return false
	}
	if !sameByHandleFileInfo(selfInfo, peerInfo) || !strings.EqualFold(selfFinalNative, peerFinalNative) {
		return false
	}
	if !strings.EqualFold(peerNative, selfNative) {
		if !strings.HasPrefix(peerNative, `\Device\`) {
			return false
		}
		rawPeerInfo, rawPeerFinalNative, okRaw := regularFileIdentityWithNative(`\\?\GLOBALROOT` + peerNative)
		if !okRaw || !sameByHandleFileInfo(selfInfo, rawPeerInfo) || !strings.EqualFold(selfFinalNative, rawPeerFinalNative) {
			return false
		}
	}
	return true
}

// SameFileIdentity reports whether two paths open the exact same regular file
// (matching VolumeSerialNumber and FileIndex) without following reparse points.
func SameFileIdentity(pathA, pathB string) bool {
	infoA, okA := regularFileIdentity(pathA)
	infoB, okB := regularFileIdentity(pathB)
	if !okA || !okB {
		return false
	}
	return sameByHandleFileInfo(infoA, infoB)
}

func sameByHandleFileInfo(a, b windows.ByHandleFileInformation) bool {
	return a.VolumeSerialNumber == b.VolumeSerialNumber &&
		a.FileIndexHigh == b.FileIndexHigh &&
		a.FileIndexLow == b.FileIndexLow
}

func regularFileIdentity(path string) (windows.ByHandleFileInformation, bool) {
	info, _, ok := regularFileIdentityWithNative(path)
	return info, ok
}

func regularFileIdentityWithNative(path string) (windows.ByHandleFileInformation, string, bool) {
	var zero windows.ByHandleFileInformation
	utf16Path, err := windows.UTF16PtrFromString(strings.TrimSpace(path))
	if err != nil {
		return zero, "", false
	}
	handle, err := windows.CreateFile(
		utf16Path,
		windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		return zero, "", false
	}
	defer windows.CloseHandle(handle)

	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		return zero, "", false
	}
	if info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DEVICE|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		return zero, "", false
	}
	nativePath, ok := peerFinalNativePathByHandle(handle)
	if !ok {
		return zero, "", false
	}
	return info, nativePath, true
}

func peerFinalNativePathByHandle(handle windows.Handle) (string, bool) {
	buf := make([]uint16, 4096)
	for {
		n, err := windows.GetFinalPathNameByHandle(handle, &buf[0], uint32(len(buf)), peerVolumeNameNT)
		if err != nil || n == 0 {
			return "", false
		}
		if int(n) < len(buf) {
			return windows.UTF16ToString(buf[:n]), true
		}
		if n > 32768 {
			return "", false
		}
		buf = make([]uint16, n+1)
	}
}

func processImage(process windows.Handle) string {
	path := processImageWithFlags(process, 0)
	if path == "" {
		return ""
	}
	return filepath.Clean(path)
}

func processImageWithFlags(process windows.Handle, flags uint32) string {
	buffer := make([]uint16, 32768)
	size := uint32(len(buffer))
	if err := windows.QueryFullProcessImageName(process, flags, &buffer[0], &size); err != nil || size == 0 {
		return ""
	}
	return windows.UTF16ToString(buffer[:size])
}

func sameProcessUser(process windows.Handle) bool {
	var token windows.Token
	if err := windows.OpenProcessToken(process, windows.TOKEN_QUERY, &token); err != nil {
		return false
	}
	defer token.Close()
	owner, err := token.GetTokenUser()
	if err != nil {
		return false
	}
	current, err := windows.GetCurrentProcessToken().GetTokenUser()
	return err == nil && owner.User.Sid.Equals(current.User.Sid)
}

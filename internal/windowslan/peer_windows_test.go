//go:build windows

package windowslan

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestTaskOwnerRequiresMatchingRunningInstance(t *testing.T) {
	shell, err := systemPowerShell()
	if err != nil {
		t.Fatal(err)
	}
	const fixture = `
$ErrorActionPreference='Stop'
$action=@{Type=0;Path='fixture.exe'}
$actions=[pscustomobject]@{Count=1} | Add-Member ScriptMethod Item { $action } -PassThru
$instances=[pscustomobject]@{Count=1} | Add-Member ScriptMethod Item { @{EnginePID=42} } -PassThru
$task=[pscustomobject]@{State=4;Definition=@{Actions=$actions}} | Add-Member ScriptMethod GetInstances { $instances } -PassThru
$env:MIMI_OWNER_WRAPPER='fixture.exe'
foreach ($candidate in @(41,42)) {
    $env:MIMI_OWNER_WRAPPER_PID="$candidate"
    [Console]::Out.Write("$candidate=")
`
	ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, shell, "-NoProfile", "-NonInteractive", "-Command", fixture+verifyRunningTask+"\n}").CombinedOutput()
	if err != nil || string(out) != "41=42=owned" {
		t.Fatalf("instance attribution: %s (%v)", out, err)
	}
}

// A native loopback socket checks table-class selection, byte order, image and
// access token without starting a service or requiring Windows elevation.
func TestTrustedLoopbackPeerUsesEstablishedSocket(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	conn, err := net.Dial("tcp4", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	server, err := l.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if !TrustedPeer(ctx, conn, os.Getpid(), "") {
		t.Fatal("local test executable and user not recognized")
	}
	if TrustedPeer(ctx, conn, os.Getpid()+1, "") {
		t.Fatal("wrong expected PID accepted")
	}
}

func volumeGUIDPathForTest(t *testing.T, path string) string {
	t.Helper()
	cleaned := filepath.Clean(path)
	volume := filepath.VolumeName(cleaned)
	if len(volume) != 2 || volume[1] != ':' {
		t.Skipf("test executable not on a drive letter volume: %q", cleaned)
	}
	root, err := windows.UTF16PtrFromString(volume + `\`)
	if err != nil {
		t.Fatal(err)
	}
	var guid [64]uint16
	if err := windows.GetVolumeNameForVolumeMountPoint(root, &guid[0], uint32(len(guid))); err != nil {
		t.Fatal(err)
	}
	return strings.TrimSuffix(windows.UTF16ToString(guid[:]), `\`) + cleaned[len(volume):]
}

// Re-launches the test binary itself via its \\?\Volume{GUID} path and verifies
// both CanonicalFirewallPath and TrustedPeer against the drive-letter parent.
func TestGUIDLaunchedBrokerMatchesPeerAndCanonicalFirewallPath(t *testing.T) {
	if os.Getenv("MIMI_WINDOWSLAN_GUID_HELPER") == "1" {
		exe, err := os.Executable()
		if err != nil {
			t.Fatalf("os.Executable: %v", err)
		}
		if !strings.HasPrefix(exe, `\\?\Volume{`) {
			t.Fatalf("helper was not launched by volume GUID: %q", exe)
		}
		canonical, err := CanonicalFirewallPath(exe)
		if err != nil {
			t.Fatalf("CanonicalFirewallPath(%q): %v", exe, err)
		}
		wantCanonical := os.Getenv("MIMI_WINDOWSLAN_GUID_CANONICAL")
		if strings.HasPrefix(canonical, `\\?\`) || !strings.EqualFold(canonical, wantCanonical) {
			t.Fatalf("CanonicalFirewallPath = %q, want %q", canonical, wantCanonical)
		}
		if !SameFileIdentity(exe, canonical) {
			t.Fatalf("SameFileIdentity(%q, %q) = false", exe, canonical)
		}
		parentPID, err := strconv.Atoi(os.Getenv("MIMI_WINDOWSLAN_GUID_PID"))
		if err != nil || parentPID <= 0 {
			t.Fatalf("invalid parent PID: %v", err)
		}
		conn, err := net.Dial("tcp4", os.Getenv("MIMI_WINDOWSLAN_GUID_ADDR"))
		if err != nil {
			t.Fatalf("dial parent listener: %v", err)
		}
		defer conn.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if !TrustedPeer(ctx, conn, parentPID, "") {
			t.Fatal("GUID-launched broker rejected drive-letter parent peer with identical file identity")
		}
		if TrustedPeer(ctx, conn, parentPID+1, "") {
			t.Fatal("GUID-launched broker accepted wrong PID")
		}
		return
	}

	selfExe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	canonicalSelf, err := CanonicalFirewallPath(selfExe)
	if err != nil {
		t.Fatal(err)
	}
	guidExe := volumeGUIDPathForTest(t, canonicalSelf)

	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, guidExe, "-test.run=^TestGUIDLaunchedBrokerMatchesPeerAndCanonicalFirewallPath$", "-test.v")
	cmd.Env = append(
		os.Environ(),
		"MIMI_WINDOWSLAN_GUID_HELPER=1",
		"MIMI_WINDOWSLAN_GUID_ADDR="+listener.Addr().String(),
		"MIMI_WINDOWSLAN_GUID_PID="+strconv.Itoa(os.Getpid()),
		"MIMI_WINDOWSLAN_GUID_CANONICAL="+canonicalSelf,
	)
	out, runErr := cmd.CombinedOutput()
	select {
	case conn := <-accepted:
		_ = conn.Close()
	default:
	}
	if runErr != nil {
		t.Fatalf("GUID-launched helper failed: %v\n%s", runErr, string(out))
	}
}

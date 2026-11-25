//go:build windows

package windowslan

import (
	"context"
	"net"
	"os"
	"os/exec"
	"testing"
	"time"
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
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
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

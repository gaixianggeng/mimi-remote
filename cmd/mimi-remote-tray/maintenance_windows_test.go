//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func inspectNativeBrokerImage(t *testing.T, exePath string) pinnedBrokerImage {
	t.Helper()
	p, err := windows.UTF16PtrFromString(exePath)
	if err != nil {
		t.Fatal(err)
	}
	h, err := windows.CreateFile(
		p,
		windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(h)
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		t.Fatal(err)
	}
	nativePath, err := trayFinalNativePathByHandle(h)
	if err != nil {
		t.Fatal(err)
	}
	return pinnedBrokerImage{
		Path:            exePath,
		NativeImagePath: nativePath,
		VolumeSerial:    info.VolumeSerialNumber,
		FileIndexHigh:   info.FileIndexHigh,
		FileIndexLow:    info.FileIndexLow,
	}
}

func TestBoundTrayBrokerVerifiesImageIdentityBeforeResume(t *testing.T) {
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		t.Fatal(err)
	}
	cmdPath := filepath.Join(systemDir, "cmd.exe")
	valid := inspectNativeBrokerImage(t, cmdPath)

	stdout, _, exitCode, err := runBoundTrayProcess(context.Background(), valid, []string{"/c", "echo", "bound-ok"}, systemDir, 4096, 4096)
	if err != nil || exitCode != 0 || !strings.Contains(string(stdout), "bound-ok") {
		t.Fatalf("valid bound broker failed: exit=%d err=%v stdout=%q", exitCode, err, string(stdout))
	}

	// Mismatched file index must terminate suspended process BEFORE code runs.
	tampered := valid
	tampered.FileIndexLow ^= 1
	blockedMarker := filepath.Join(t.TempDir(), "should-not-exist.txt")
	_, _, _, err = runBoundTrayProcess(context.Background(), tampered, []string{"/c", "echo pwn > " + blockedMarker}, systemDir, 4096, 4096)
	var maintErr *maintenanceError
	if !errors.As(err, &maintErr) || maintErr.Kind != maintenanceFailureIdentityMismatch {
		t.Fatalf("expected identity_mismatch for tampered file ID, got %v", err)
	}
	if _, statErr := os.Stat(blockedMarker); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("tampered suspended broker ran before identity rejection: statErr=%v", statErr)
	}

	// Mismatched native NT path must also fail closed before resume.
	tamperedPath := valid
	tamperedPath.NativeImagePath = `\Device\HarddiskVolume99\fake\agentd.exe`
	_, _, _, err = runBoundTrayProcess(context.Background(), tamperedPath, []string{"/c", "echo pwn > " + blockedMarker}, systemDir, 4096, 4096)
	if !errors.As(err, &maintErr) || maintErr.Kind != maintenanceFailureIdentityMismatch {
		t.Fatalf("expected identity_mismatch for tampered native path, got %v", err)
	}
	if _, statErr := os.Stat(blockedMarker); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("tampered native path broker ran before identity rejection: statErr=%v", statErr)
	}
}

func TestBoundTrayBrokerTimeoutTerminatesEntireJobTreeBeforeReturning(t *testing.T) {
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		t.Fatal(err)
	}
	cmdPath := filepath.Join(systemDir, "cmd.exe")
	valid := inspectNativeBrokerImage(t, cmdPath)

	// Spawn a child ping process that would normally outlive the parent if only
	// the parent were killed, and confirm cancelling ctx terminates the whole job.
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	afterMarker := filepath.Join(t.TempDir(), "after-cancel.txt")
	start := time.Now()
	_, _, _, err = runBoundTrayProcess(ctx, valid, []string{"/c", "ping -n 30 127.0.0.1 >nul && echo late > " + afterMarker}, systemDir, 4096, 4096)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected DeadlineExceeded, got %v", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("job tree cancellation took too long: %v", elapsed)
	}
	if _, statErr := os.Stat(afterMarker); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("descendant continued executing after job termination: statErr=%v", statErr)
	}
}

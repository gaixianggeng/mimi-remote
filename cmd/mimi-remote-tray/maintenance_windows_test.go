//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
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
	powershellPath := filepath.Join(systemDir, "WindowsPowerShell", "v1.0", "powershell.exe")
	valid := inspectNativeBrokerImage(t, powershellPath)

	tempDir := t.TempDir()
	pidFile := filepath.Join(tempDir, "descendant.pid")
	tmpFile := pidFile + ".tmp"
	escapedTmp := strings.ReplaceAll(tmpFile, "'", "''")
	escapedPID := strings.ReplaceAll(pidFile, "'", "''")
	script := `$child = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList '-n','60','127.0.0.1' -NoNewWindow -PassThru; ` +
		`[IO.File]::WriteAllText('` + escapedTmp + `', [string]$child.Id); ` +
		`[IO.File]::Move('` + escapedTmp + `', '` + escapedPID + `'); ` +
		`$child.WaitForExit()`

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	type runOutcome struct {
		err error
	}
	done := make(chan runOutcome, 1)
	go func() {
		_, _, _, runErr := runBoundTrayProcess(ctx, valid, []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script}, systemDir, 4096, 4096)
		done <- runOutcome{err: runErr}
	}()

	var descendantPID int
	waitDeadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(waitDeadline) {
		if raw, readErr := os.ReadFile(pidFile); readErr == nil {
			if parsed, parseErr := strconv.Atoi(strings.TrimSpace(string(raw))); parseErr == nil && parsed > 0 {
				descendantPID = parsed
				break
			}
		}
		select {
		case res := <-done:
			t.Fatalf("bound process exited before spawning descendant: %v", res.err)
		case <-time.After(50 * time.Millisecond):
		}
	}
	if descendantPID <= 0 {
		cancel()
		<-done
		t.Fatal("timed out waiting for descendant PID file")
	}

	// Open a handle to the live descendant BEFORE cancelling so Windows cannot
	// recycle the PID and we can assert it has already exited upon return.
	descendantHandle, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_TERMINATE, false, uint32(descendantPID))
	if err != nil {
		cancel()
		<-done
		t.Fatalf("open descendant PID %d: %v", descendantPID, err)
	}
	defer func() {
		if res, _ := windows.WaitForSingleObject(descendantHandle, 0); res != windows.WAIT_OBJECT_0 {
			_ = windows.TerminateProcess(descendantHandle, 1)
		}
		_ = windows.CloseHandle(descendantHandle)
	}()
	if res, waitErr := windows.WaitForSingleObject(descendantHandle, 0); waitErr != nil || res != uint32(windows.WAIT_TIMEOUT) {
		cancel()
		<-done
		t.Fatalf("descendant PID %d was not alive before cancellation (wait=%d err=%v)", descendantPID, res, waitErr)
	}

	cancelStart := time.Now()
	cancel()
	res := <-done
	if !errors.Is(res.err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", res.err)
	}
	if elapsed := time.Since(cancelStart); elapsed > 10*time.Second {
		t.Fatalf("job tree cancellation took too long: %v", elapsed)
	}
	if waitRes, waitErr := windows.WaitForSingleObject(descendantHandle, 0); waitErr != nil || waitRes != windows.WAIT_OBJECT_0 {
		t.Fatalf("descendant PID %d was still running after bound runner returned (wait=%d err=%v)", descendantPID, waitRes, waitErr)
	}
}

func TestBoundTrayModifyModeCompletesDespiteContextCancellation(t *testing.T) {
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		t.Fatal(err)
	}
	cmdPath := filepath.Join(systemDir, "cmd.exe")
	valid := inspectNativeBrokerImage(t, cmdPath)

	tempDir := t.TempDir()
	startedMarker := filepath.Join(tempDir, "started.txt")
	finishedMarker := filepath.Join(tempDir, "finished.txt")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	type runOutcome struct {
		exitCode int
		err      error
	}
	done := make(chan runOutcome, 1)
	go func() {
		_, _, code, runErr := runBoundTrayProcessWithMode(
			ctx,
			valid,
			[]string{"/c", `echo started > "` + startedMarker + `" && ping -n 2 127.0.0.1 >nul && echo done > "` + finishedMarker + `"`},
			systemDir,
			4096,
			4096,
			false,
		)
		done <- runOutcome{exitCode: code, err: runErr}
	}()

	waitDeadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(waitDeadline) {
		if _, statErr := os.Stat(startedMarker); statErr == nil {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	// Cancel caller context AFTER the process has started; modify mode must let
	// it complete cleanly instead of killing it mid-apply.
	cancel()
	res := <-done
	if res.err != nil || res.exitCode != 0 {
		t.Fatalf("modify mode aborted on post-launch cancel: code=%d err=%v", res.exitCode, res.err)
	}
	if _, statErr := os.Stat(finishedMarker); statErr != nil {
		t.Fatalf("modify mode process did not finish cleanly: %v", statErr)
	}
}

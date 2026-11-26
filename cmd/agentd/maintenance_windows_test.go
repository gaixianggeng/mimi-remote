package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestMaintenanceRequestUsesFixedActions(t *testing.T) {
	for _, tc := range []struct {
		action, args string
		elevate      bool
	}{
		{"modify", "/MIMIMODE=modify", false},
		{"enable-lan", "/MIMIMODE=enable-lan /VERYSILENT /SUPPRESSMSGBOXES /NORESTART", true},
		{"disable-lan", "/MIMIMODE=disable-lan /VERYSILENT /SUPPRESSMSGBOXES /NORESTART", true},
	} {
		got, err := maintenanceRequest([]string{tc.action})
		if err != nil || got.parameters != tc.args || got.elevate != tc.elevate {
			t.Errorf("%s: %+v, %v", tc.action, got, err)
		}
	}
	for _, args := range [][]string{nil, {"uninstall"}, {"C:\\other.exe"}, {"modify", "/SILENT"}, {"enable-lan /DIR=other"}} {
		if _, err := maintenanceRequest(args); err == nil {
			t.Errorf("accepted %q", args)
		}
	}
}

func TestMaintenanceLocksVerifiedImageThroughLaunch(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Mimi Remote")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, maintenanceImageName)
	data := []byte("maintenance fixture")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(data))
	var verified os.FileInfo
	err := withLockedMaintenance(dir, digest, func(f *os.File) error {
		var err error
		verified, err = f.Stat()
		return err
	}, func(launchPath string) error {
		info, err := os.Stat(launchPath)
		if err != nil || verified == nil || !os.SameFile(verified, info) || !strings.HasPrefix(launchPath, "\\\\?\\Volume{") {
			t.Fatal("launch path does not identify verified image")
		}
		if err := os.Rename(path, path+".other"); err == nil {
			t.Fatal("image replaceable during launch")
		}
		if err := os.WriteFile(path, []byte("changed"), 0600); err == nil {
			t.Fatal("image writable during launch")
		}
		if err := os.Rename(dir, dir+".other"); err == nil {
			t.Fatal("ancestor replaceable during launch")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path, path+".other"); err != nil {
		t.Fatalf("still locked after child exit: %v", err)
	}
}

func TestMaintenanceRejectsWrongOrUnsignedImage(t *testing.T) {
	dir := t.TempDir()
	data := []byte("fixture for another program")
	digest := fmt.Sprintf("%x", sha256.Sum256(data))
	if err := os.WriteFile(filepath.Join(dir, "unins000.exe"), data, 0600); err != nil {
		t.Fatal(err)
	}
	launch := func(string) error { t.Fatal("unexpected launch"); return nil }
	unexpectedTrust := func(*os.File) error { t.Fatal("unexpected trust verification"); return nil }
	if err := withLockedMaintenance(dir, digest, unexpectedTrust, launch); !errors.Is(err, errMaintenanceIdentity) {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, maintenanceImageName), data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, wrong := range []string{"", "bad-pin", strings.Repeat("7f", 32)} {
		if err := withLockedMaintenance(dir, wrong, unexpectedTrust, launch); !errors.Is(err, errMaintenanceIdentity) {
			t.Fatal(err)
		}
	}
	if err := withLockedMaintenance(dir, digest, verifyMaintenancePublisher, launch); !errors.Is(err, errMaintenanceIdentity) {
		t.Fatal(err)
	}
}

func TestMaintenanceUACCancelledPropagatesDistinctExitCode(t *testing.T) {
	err := maintenanceUACCancelledError()
	var coded *exitCodeError
	if !errors.As(err, &coded) || coded.exitCode != maintenanceUACCancelledExitCode {
		t.Fatalf("expected exitCodeError(%d), got %T %v", maintenanceUACCancelledExitCode, err, err)
	}
	var typed *onboardingCommandError
	if !errors.As(err, &typed) || typed.code != "lan_firewall_blocked" || typed.step != "network_lan" {
		t.Fatalf("expected typed lan_firewall_blocked diagnostic, got %v", err)
	}
}

func TestBoundMaintenanceProcessVerifiesImageIdentityBeforeResume(t *testing.T) {
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		t.Fatal(err)
	}
	cmdPath := filepath.Join(systemDir, "cmd.exe")
	p, err := windows.UTF16PtrFromString(cmdPath)
	if err != nil {
		t.Fatal(err)
	}
	h, err := windows.CreateFile(p, windows.FILE_READ_ATTRIBUTES, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(h)
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		t.Fatal(err)
	}
	nativePath, err := finalNativePathByHandle(h)
	if err != nil {
		t.Fatal(err)
	}

	valid := pinnedFileIdentity{
		path:          cmdPath,
		nativePath:    nativePath,
		volumeSerial:  info.VolumeSerialNumber,
		fileIndexHigh: info.FileIndexHigh,
		fileIndexLow:  info.FileIndexLow,
	}
	marker := filepath.Join(t.TempDir(), "ran.txt")
	code, err := runBoundMaintenanceProcess(valid, `/c echo ok > "`+marker+`"`, systemDir)
	if err != nil || code != 0 {
		t.Fatalf("matching identity failed: code=%d err=%v", code, err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("expected matching bound process to execute: %v", err)
	}

	// Tampered identity must terminate the suspended process BEFORE any code runs.
	tampered := valid
	tampered.fileIndexLow ^= 1
	blockedMarker := filepath.Join(t.TempDir(), "must-not-run.txt")
	if _, err := runBoundMaintenanceProcess(tampered, `/c echo pwn > "`+blockedMarker+`"`, systemDir); !errors.Is(err, errMaintenanceIdentity) {
		t.Fatalf("tampered file index should fail with errMaintenanceIdentity, got %v", err)
	}
	if _, err := os.Stat(blockedMarker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("tampered suspended process executed before identity check: stat err=%v", err)
	}
}

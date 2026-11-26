package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
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

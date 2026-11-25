//go:build !windows

package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRepairOwnedModeWithoutReplacingOrFollowing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "existing")
	raw := []byte("synthetic-private-fixture")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(dir, "alias")
	if err := os.Symlink(path, alias); err != nil {
		t.Fatal(err)
	}
	if changed, err := RepairPrivatePermissions(alias); err == nil || changed {
		t.Fatal("followed symlink for permission repair")
	}
	if grew, err := os.Stat(path); err != nil || grew.Mode().Perm() != 0644 {
		t.Fatal("modified symlink target")
	}
	if changed, err := RepairPrivatePermissions(path); err != nil || !changed {
		t.Fatalf("repair changed=%v err=%v", changed, err)
	}
	after, err := os.Stat(path)
	if err != nil || !os.SameFile(before, after) || after.Mode().Perm() != 0600 {
		t.Fatal("changed file identity or failed to tighten mode")
	}
	saved, err := ReadPrivatePreflightFile(path, 1024)
	if err != nil || string(saved) != string(raw) {
		t.Fatal("changed credential bytes")
	}
	if changed, err := RepairPrivatePermissions(path); err != nil || changed {
		t.Fatalf("repeat repair changed=%v err=%v", changed, err)
	}
}

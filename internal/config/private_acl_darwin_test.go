package config

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestDarwinExtendedACLIsPreservedAndBroadGrantsAreRepairable(t *testing.T) {
	dir := t.TempDir()
	source, stage := filepath.Join(dir, "original"), filepath.Join(dir, "stage")
	for _, p := range []string{source, stage} {
		if err := os.WriteFile(p, []byte("synthetic-private-fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	add := func(path, rule string) {
		t.Helper()
		if output, err := exec.Command("/bin/chmod", "+a", rule, path).CombinedOutput(); err != nil {
			t.Fatalf("set ACL fixture: %v %s", err, output)
		}
	}
	read := func(path string) darwinFileACL {
		t.Helper()
		f, err := openSnapshotFile(path)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		a, err := readFileACL(f)
		if err != nil {
			t.Fatal(err)
		}
		return a
	}
	add(source, "everyone allow readattr")
	original := read(source)
	if len(original.data) == 0 {
		t.Fatal("missing ACL fixture")
	}
	if err := CopyPrivatePermissions(source, stage); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(read(stage).data, original.data) {
		t.Fatal("lost explicit ACL during staged copy")
	}
	add(stage, "everyone allow read")
	if _, err := ReadPrivatePreflightFile(stage, 100); !errors.Is(err, errPreflightFileNotPrivate) {
		t.Fatalf("accepted broad ACL: %v", err)
	}
	if changed, err := RepairPrivatePermissions(stage); err != nil || !changed {
		t.Fatalf("repair changed=%v err=%v", changed, err)
	}
	if _, err := ReadPrivatePreflightFile(stage, 100); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(read(source).data, original.data) {
		t.Fatal("changed original ACL")
	}
}

package config

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestDarwinRejectsAndStripsEveryExtendedACL(t *testing.T) {
	for _, rule := range []string{"everyone allow readattr", "everyone allow read", "everyone deny write"} {
		t.Run(rule, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "original")
			if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
				t.Fatal(err)
			}
			if output, err := exec.Command("/bin/chmod", "+a", rule, path).CombinedOutput(); err != nil {
				t.Fatalf("set ACL: %s %v", output, err)
			}
			if _, err := ReadPrivatePreflightFile(path, 100); !errors.Is(err, errPreflightFileNotPrivate) {
				t.Fatalf("accepted ACL: %v", err)
			}
			if changed, err := RepairPrivatePermissions(path); err != nil || !changed {
				t.Fatalf("repair changed=%v err=%v", changed, err)
			}
			raw, err := ReadPrivatePreflightFile(path, 100)
			if err != nil || string(raw) != "fixture" {
				t.Fatalf("repaired file: %v", err)
			}
		})
	}
}

func TestDarwinNewStageExcludesInheritedAccessAtCreation(t *testing.T) {
	dir := t.TempDir()
	if out, err := exec.Command("/bin/chmod", "+a", "everyone allow read,file_inherit", dir).CombinedOutput(); err != nil {
		t.Fatalf("parent ACL: %v %s", err, out)
	}
	path := filepath.Join(dir, "ordinary")
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := CheckPrivatePermissions(path); !errors.Is(err, errPreflightFileNotPrivate) {
		t.Fatalf("missing inherited ACL fixture: %v", err)
	}
	file, err := createPrivateNew(filepath.Join(dir, "stage"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := verifyPrivateFile(file); err != nil {
		t.Fatalf("stage not private at creation: %v", err)
	}
}

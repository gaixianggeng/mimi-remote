package privatefile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteReplacesCompletePrivateFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identity")
	if err := Write(path, []byte("first")); err != nil {
		t.Fatal(err)
	}
	before, err := identity(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := Write(path, []byte("second")); err != nil {
		t.Fatal(err)
	}
	after, err := identity(path)
	if err != nil || os.SameFile(before, after) {
		t.Fatalf("expected staged replacement: %v", err)
	}
	if raw, err := Read(path); err != nil || string(raw) != "second" {
		t.Fatalf("read replacement: %q, %v", raw, err)
	}
}

func assertRefusesNoncanonicalFile(t *testing.T, path string) {
	t.Helper()
	if raw, err := Read(path); err == nil || len(raw) != 0 {
		t.Fatalf("read unsafe file: %q, %v", raw, err)
	}
	if err := Write(path, []byte("replacement")); err == nil {
		t.Fatal("overwrote unsafe destination")
	}
	if raw, err := os.ReadFile(path); err != nil || string(raw) != "original" {
		t.Fatalf("original contents: %q, %v", raw, err)
	}
}

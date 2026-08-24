package appserver

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestCodexVersionAtLeastSingleWriterBaseline(t *testing.T) {
	tests := map[string]bool{
		"0.145.0":              false,
		"0.147.0-alpha.6.5":    false,
		"0.147.0":              true,
		"0.147.1":              true,
		"0.149.0-alpha.4.1":    true,
		"1.0.0":                true,
		"unrecognized-version": false,
	}
	for version, want := range tests {
		if got := codexVersionAtLeast(version, MinimumIndependentWriterVersion); got != want {
			t.Fatalf("version %q support mismatch: got=%t want=%t", version, got, want)
		}
	}
}

func TestValidateIndependentCodexRuntimeExplainsUnsafeVersion(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows command fixture is platform-specific")
	}
	path := filepath.Join(t.TempDir(), "codex-old.cmd")
	if err := os.WriteFile(path, []byte("@echo off\r\necho codex-cli 0.145.0\r\nexit /b 0\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := ValidateIndependentCodexRuntime(context.Background(), path)
	if !errors.Is(err, ErrIndependentWriterCapabilityUnavailable) ||
		!strings.Contains(err.Error(), "版本为 0.145.0") ||
		!strings.Contains(err.Error(), "需要 >= "+MinimumIndependentWriterVersion) {
		t.Fatalf("unsafe runtime should return an actionable diagnostic: %v", err)
	}
}

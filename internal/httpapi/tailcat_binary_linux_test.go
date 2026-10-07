package httpapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLinuxTailcatMissingBinaryProvidesUpgradePath(t *testing.T) {
	t.Setenv("AGENTD_TAILCAT_BIN", "")
	t.Setenv("PATH", t.TempDir())
	_, err := resolveTailcatSidecarBinary("")
	if err == nil || !strings.Contains(err.Error(), "bash ./scripts/install-linux.sh upgrade") {
		t.Fatalf("missing sidecar should explain how to repair the installation: %v", err)
	}
}

func TestLinuxTailcatBinaryFromInstallPath(t *testing.T) {
	dir := t.TempDir()
	binary := filepath.Join(dir, tailcatSidecarBinary)
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTD_TAILCAT_BIN", "")
	t.Setenv("PATH", dir)
	resolved, err := resolveTailcatSidecarBinary("")
	if err != nil || resolved != binary {
		t.Fatalf("resolve installed sidecar = %q, %v; want %q", resolved, err, binary)
	}
}

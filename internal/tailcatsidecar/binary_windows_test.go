//go:build windows

package tailcatsidecar

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWindowsTailcatMissingBinaryPointsToInstaller(t *testing.T) {
	t.Setenv("AGENTD_TAILCAT_BIN", "")
	t.Setenv("PATH", t.TempDir())
	_, err := Resolve("")
	if err == nil || !strings.Contains(err.Error(), "mimi-tailcat-experiment.exe") || !strings.Contains(err.Error(), "Windows 安装器") {
		t.Fatalf("missing helper should point to the Windows installer: %v", err)
	}
}

func TestWindowsTailcatBinaryUsesExeName(t *testing.T) {
	dir := t.TempDir()
	binary := filepath.Join(dir, BinaryName())
	if err := os.WriteFile(binary, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTD_TAILCAT_BIN", "")
	t.Setenv("PATH", dir)
	resolved, err := Resolve("")
	if err != nil || !strings.EqualFold(resolved, binary) {
		t.Fatalf("resolve Windows helper = %q, %v; want %q", resolved, err, binary)
	}
}

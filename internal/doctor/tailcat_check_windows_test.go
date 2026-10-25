//go:build windows

package doctor

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func fakeWindowsTailcatSidecar(t *testing.T, version string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "mimi-tailcat-experiment.cmd")
	if err := os.WriteFile(path, []byte("@echo "+version+"\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestWindowsTailcatCheckWarnsWhenDisabledHelperIsMissing(t *testing.T) {
	t.Setenv("AGENTD_TAILCAT_BIN", "")
	t.Setenv("PATH", t.TempDir())
	checker := &Checker{version: "1.2.3"}
	results := checker.results([]Check{checker.tailcatCheck(context.Background())})
	check := results.Checks[0]
	if check.Name != "tailcat" || check.OK || check.Level != "warning" || !results.OK {
		t.Fatalf("disabled Tailcat should only warn about a missing helper: %+v", results)
	}
	if !strings.Contains(check.Message, "mimi-tailcat-experiment.exe") || !strings.Contains(check.Message, "Windows 安装器") {
		t.Fatalf("missing helper should name the file and the repair path: %q", check.Message)
	}
}

func TestWindowsTailcatCheckFailsWhenEnabledHelperIsMissing(t *testing.T) {
	t.Setenv("AGENTD_TAILCAT_BIN", "")
	t.Setenv("PATH", t.TempDir())
	checker := &Checker{version: "1.2.3", cfg: config.Config{Tailcat: config.TailcatConfig{Enabled: true}}}
	results := checker.results([]Check{checker.tailcatCheck(context.Background())})
	if results.OK || results.Checks[0].Level != "error" {
		t.Fatalf("enabled Tailcat without its helper must fail doctor: %+v", results)
	}
}

func TestWindowsTailcatCheckReportsHelperVersion(t *testing.T) {
	sidecar := fakeWindowsTailcatSidecar(t, "1.2.3")
	checker := &Checker{version: "v1.2.3", cfg: config.Config{Tailcat: config.TailcatConfig{SidecarBin: sidecar}}}
	check := checker.tailcatCheck(context.Background())
	if !check.OK || !strings.Contains(check.Message, "1.2.3") || !strings.Contains(check.Message, "未启用") {
		t.Fatalf("available helper should report its version and disabled state: %+v", check)
	}
}

func TestWindowsTailcatCheckWarnsOnVersionMismatch(t *testing.T) {
	sidecar := fakeWindowsTailcatSidecar(t, "1.2.2")
	checker := &Checker{version: "1.2.3", cfg: config.Config{Tailcat: config.TailcatConfig{Enabled: true, SidecarBin: sidecar}}}
	results := checker.results([]Check{checker.tailcatCheck(context.Background())})
	check := results.Checks[0]
	if check.OK || check.Level != "warning" || !strings.Contains(check.Message, "版本不一致") {
		t.Fatalf("mismatched helper should be a warning: %+v", check)
	}
}

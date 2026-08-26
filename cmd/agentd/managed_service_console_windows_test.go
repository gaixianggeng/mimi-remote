//go:build windows

package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestManagedServiceRequested(t *testing.T) {
	for _, testCase := range []struct {
		name string
		args []string
		want bool
	}{
		{name: "managed serve", args: []string{"agentd.exe", "--managed-service", "--log-file", "agentd.log"}, want: true},
		{name: "ordinary serve", args: []string{"agentd.exe", "--log-file", "agentd.log"}},
		{name: "similar value", args: []string{"agentd.exe", "--managed-service=false"}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if got := managedServiceRequested(testCase.args); got != testCase.want {
				t.Fatalf("managedServiceRequested(%q) = %v, want %v", testCase.args, got, testCase.want)
			}
		})
	}
}

func TestShouldHideManagedServiceConsole(t *testing.T) {
	managedArgs := []string{"agentd.exe", "--managed-service"}
	if !shouldHideManagedServiceConsole(managedArgs, 1) {
		t.Fatal("a managed service with a standalone console should hide its window")
	}
	if shouldHideManagedServiceConsole(managedArgs, 2) {
		t.Fatal("a managed service sharing a console must not hide the user's terminal")
	}
	if shouldHideManagedServiceConsole([]string{"agentd.exe"}, 1) {
		t.Fatal("an ordinary agent process must not hide its console")
	}
}

func TestAppendManagedServiceFailure(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "logs", "agentd.log")
	appendManagedServiceFailure(
		[]string{"agentd.exe", "serve", "--managed-service", "--log-file", logPath},
		errors.New("startup failed"),
	)
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if text := string(raw); !strings.Contains(text, `managed_service_error="startup failed"`) {
		t.Fatalf("unexpected managed-service log: %q", text)
	}
}

func TestAppendManagedServiceFailureRequiresManagedFlag(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "agentd.log")
	appendManagedServiceFailure(
		[]string{"agentd.exe", "serve", "--log-file=" + logPath},
		errors.New("manual failure"),
	)
	if _, err := os.Stat(logPath); !os.IsNotExist(err) {
		t.Fatalf("ordinary serve should not create a managed-service log, stat error: %v", err)
	}
}

func TestAppendManagedServiceFailureUsesBoundedFallback(t *testing.T) {
	root := t.TempDir()
	primaryPath := filepath.Join(root, "primary-as-directory")
	if err := os.MkdirAll(primaryPath, 0o700); err != nil {
		t.Fatal(err)
	}
	fallbackPath := filepath.Join(root, "fallback", "agentd.last-error.log")
	previous := managedServiceFailureFallbackPath
	managedServiceFailureFallbackPath = func() (string, error) { return fallbackPath, nil }
	t.Cleanup(func() { managedServiceFailureFallbackPath = previous })

	args := []string{"agentd.exe", "serve", "--managed-service", "--log-file", primaryPath}
	appendManagedServiceFailure(args, errors.New("first failure"))
	appendManagedServiceFailure(args, errors.New("second failure"))
	raw, err := os.ReadFile(fallbackPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if strings.Contains(text, "first failure") || !strings.Contains(text, "second failure") {
		t.Fatalf("fallback should retain only the latest failure: %q", text)
	}
}

func TestAppendManagedServiceFailureBoundsFallbackBytes(t *testing.T) {
	root := t.TempDir()
	primaryPath := filepath.Join(root, "primary-as-directory")
	if err := os.MkdirAll(primaryPath, 0o700); err != nil {
		t.Fatal(err)
	}
	fallbackPath := filepath.Join(root, "fallback", "agentd.last-error.log")
	previous := managedServiceFailureFallbackPath
	managedServiceFailureFallbackPath = func() (string, error) { return fallbackPath, nil }
	t.Cleanup(func() { managedServiceFailureFallbackPath = previous })

	message := strings.Repeat("\n路径故障\\", managedServiceDiagnosticMaxBytes) + "final-cause"
	appendManagedServiceFailure(
		[]string{"agentd.exe", "serve", "--managed-service", "--log-file", primaryPath},
		errors.New(message),
	)
	raw, err := os.ReadFile(fallbackPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) > managedServiceDiagnosticMaxBytes {
		t.Fatalf("fallback exceeded byte limit: got=%d limit=%d", len(raw), managedServiceDiagnosticMaxBytes)
	}
	if !utf8.Valid(raw) || !bytes.Contains(raw, []byte("final-cause")) {
		t.Fatalf("fallback must keep a valid UTF-8 diagnostic tail: %q", raw)
	}
}

func TestAppendManagedServiceFailureRotatesEarlyPrimaryLog(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "agentd.log")
	if err := os.WriteFile(logPath, bytes.Repeat([]byte("x"), int(defaultManagedLogMaxBytes)), 0o600); err != nil {
		t.Fatal(err)
	}
	appendManagedServiceFailure(
		[]string{"agentd.exe", "serve", "--managed-service", "--log-file", logPath},
		errors.New("startup failure after full log"),
	)
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(raw)) > defaultManagedLogMaxBytes || !bytes.Contains(raw, []byte("startup failure after full log")) {
		t.Fatalf("primary log was not rotated before the early failure: size=%d text=%q", len(raw), raw)
	}
	if info, err := os.Stat(logPath + ".previous"); err != nil || info.Size() != defaultManagedLogMaxBytes {
		t.Fatalf("previous log was not retained at the configured limit: info=%v err=%v", info, err)
	}
}

func TestAppendManagedServiceFailureRedactsSensitiveDiagnostic(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "agentd.log")
	appendManagedServiceFailure(
		[]string{"agentd.exe", "serve", "--managed-service", "--log-file", logPath},
		errors.New("bearer token=super-secret"),
	)
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if strings.Contains(text, "super-secret") || !strings.Contains(text, "redacted sensitive") {
		t.Fatalf("managed-service diagnostic was not redacted: %q", text)
	}
}

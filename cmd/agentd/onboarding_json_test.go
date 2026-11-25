package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestOnboardingErrorCLIProcess(t *testing.T) {
	if os.Getenv("MIMI_TEST_ONBOARDING_ERROR_CLI") != "1" {
		return
	}
	i := slices.Index(os.Args, "--")
	if i < 0 {
		t.Fatal("missing command")
	}
	os.Args = append([]string{"agentd"}, os.Args[i+1:]...)
	main()
	os.Exit(0)
}

func TestOnboardingEarlyJSONFailures(t *testing.T) {
	for _, name := range []string{"preflight", "setup", "up", "start", "restart", "pair", "tailcat pair", "tailcat enable", "tailcat relay set", "tailcat PAIR", "tailcat ENABLE", "tailcat RELAY set", "network", "runtime", "workspace", "doctor --fix"} {
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			args := append([]string{"-test.run=^TestOnboardingErrorCLIProcess$", "--"}, strings.Fields(name)...)
			cmd := exec.Command(os.Args[0], append(args, "--invalid-private-input", "--json")...)
			cmd.Env = []string{"MIMI_TEST_ONBOARDING_ERROR_CLI=1", "HOME=" + home, "USERPROFILE=" + home, "APPDATA=" + home, "XDG_CONFIG_HOME=" + home, "PATH=" + home, "TMPDIR=" + home, "TEMP=" + home, "TMP=" + home, "SystemRoot=" + os.Getenv("SystemRoot")}
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			var exit *exec.ExitError
			if err := cmd.Run(); !errors.As(err, &exit) || exit.ExitCode() != 1 {
				t.Fatalf("command returned %v", err)
			}
			assertOnboardingError(t, stdout.Bytes(), stderr.String(), "invalid_request", "config_store")
		})
	}
}

func TestOnboardingMigrationFailure(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	// A legacy directory masquerading as config.json must fail before pair.
	if err := os.MkdirAll(config.LegacyDefaultPath(), 0o700); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if status := commandExit([]string{"agentd", "pair", "--json"}, &stdout, &stderr); status != 1 {
		t.Fatalf("status %d", status)
	}
	assertOnboardingError(t, stdout.Bytes(), stderr.String(), "config_recovery_required", "config_store")
}

func TestOnboardingUpReadinessFailure(t *testing.T) {
	fakeCoreManager(t, "homebrew", func(string, string) error { t.Fatal("unexpected start"); return nil })
	isolateOnboardingCommandEnv(t)
	prepareBrewSideEffectProbe(t)
	path := config.PlatformDefaultPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, path, []byte(`{"codex":{"enabled":false}}`))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(server.Close)
	originalSetup, originalInspect := runAgentSetup, inspectLegacyCodexExperimentResidue
	t.Cleanup(func() { runAgentSetup, inspectLegacyCodexExperimentResidue = originalSetup, originalInspect })
	runAgentSetup = func(ctx context.Context, _ setup.Options) (setup.Result, error) {
		return setup.Result{ConfigPath: path, Endpoint: server.URL, Token: "fixture-private-value"}, nil
	}
	inspectLegacyCodexExperimentResidue = func() (string, error) { return "", nil }
	var stdout, stderr bytes.Buffer
	if status := commandExit([]string{"agentd", "up", "--json", "--no-pair", "--wait=1ns"}, &stdout, &stderr); status != 1 {
		t.Fatalf("status %d", status)
	}
	assertOnboardingError(t, stdout.Bytes(), stderr.String(), "service_start_timeout", "service_daemon")
}

func isolateOnboardingCommandEnv(t *testing.T) {
	t.Helper()
	home := t.TempDir()
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(strings.ToUpper(key), "AGENTD_") {
			t.Setenv(key, "")
		}
	}
	for _, key := range []string{"HOME", "USERPROFILE", "XDG_CONFIG_HOME", "APPDATA", "LOCALAPPDATA", "PATH", "TMPDIR", "TEMP", "TMP"} {
		t.Setenv(key, home)
	}
}

func assertOnboardingError(t *testing.T, stdout []byte, stderr, code, step string) {
	t.Helper()
	var envelope struct {
		OK    *bool                 `json:"ok"`
		Error setup.OnboardingError `json:"error"`
	}
	// Unmarshal also rejects a second JSON object or trailing text.
	if err := json.Unmarshal(stdout, &envelope); err != nil || envelope.OK == nil || *envelope.OK || envelope.Error.Code != code || envelope.Error.Step != step || envelope.Error.Message == "" {
		t.Fatalf("unexpected stdout %q (%v)", stdout, err)
	}
	if stderr != "" || bytes.Contains(stdout, []byte("private")) {
		t.Fatalf("unexpected diagnostic material stdout=%q stderr=%q", stdout, stderr)
	}
}

func TestOnboardingJSONPreservesExistingIdentity(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	inspect := inspectLegacyCodexExperimentResidue
	inspectLegacyCodexExperimentResidue = func() (string, error) { return "", nil }
	t.Cleanup(func() { inspectLegacyCodexExperimentResidue = inspect })
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	companion := filepath.Join(dir, "app-server-token")
	original := []byte(`{"auth":{"token":"private-fixture-bearer"}`)
	token := []byte("private-fixture-companion")
	configtest.CreatePrivateFile(t, path, original)
	configtest.CreatePrivateFile(t, companion, token)
	for _, tc := range []struct{ cmd, flag, code string }{
		{"setup", "--force", "token_rotation_requires_approval"},
		{"doctor", "--fix", "config_invalid"},
	} {
		var out, stderr bytes.Buffer
		args := []string{"agentd", tc.cmd, tc.flag, "--json", "--config", path}
		if commandExit(args, &out, &stderr) != 1 {
			t.Fatalf("%s unexpectedly succeeded", tc.cmd)
		}
		assertOnboardingError(t, out.Bytes(), stderr.String(), tc.code, "config_store")
	}
	// The second legacy repair branch can be reached after a successful load.
	for _, tc := range []struct{ name, code string }{{"token", "config_recovery_required"}, {"projects", "token_rotation_requires_approval"}} {
		results := doctor.Results{Checks: []doctor.Check{{Name: tc.name, OK: false}}}
		_, _, _, _, err := repairDoctor(t.Context(), path, false, results, true)
		var typed *onboardingCommandError
		if !errors.As(err, &typed) || typed.code != tc.code {
			t.Fatalf("%s: %v", tc.name, err)
		}
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(original, after) {
		t.Fatal("host configuration changed")
	}
	after, err = os.ReadFile(companion)
	if err != nil || !bytes.Equal(token, after) {
		t.Fatal("companion credential changed")
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 2 {
		t.Fatal("unexpected recovery artifacts")
	}
}

func TestOnboardingJSONMissingConfigAndInvalidInputs(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	root := t.TempDir()
	path := filepath.Join(root, "absent.json")
	for _, tc := range []struct {
		args []string
		code string
	}{
		{[]string{"pair"}, "config_missing"},
		{[]string{"runtime", "--codex=disabled"}, "config_missing"},
		{[]string{"network", "--lan-enabled=false"}, "config_missing"},
		{[]string{"workspace", "--root", root}, "config_missing"},
		{[]string{"runtime", "--codex=bad"}, "invalid_request"},
		{[]string{"runtime", "--deepseek=inspect", "--deepseek-url-stdin"}, "invalid_request"},
		{[]string{"workspace", "--restore-state=null"}, "invalid_request"},
	} {
		var out, stderr bytes.Buffer
		args := append(append([]string{"agentd"}, tc.args...), "--config", path, "--json")
		if commandExit(args, &out, &stderr) != 1 {
			t.Fatalf("%v unexpectedly succeeded", tc.args)
		}
		assertOnboardingError(t, out.Bytes(), stderr.String(), tc.code, "config_store")
	}
}

func TestReadOnlyDoctorRetainsJSONHelp(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	t.Setenv("MIMI_TEST_ONBOARDING_ERROR_CLI", "1")
	cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestOnboardingErrorCLIProcess$", "--", "doctor", "--json", "--help")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil || len(out) != 0 || !strings.Contains(stderr.String(), "Usage of doctor") {
		t.Fatalf("help status %v, stdout=%q stderr=%q", err, out, stderr.String())
	}
}

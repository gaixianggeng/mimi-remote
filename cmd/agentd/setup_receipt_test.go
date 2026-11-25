package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func noFixtureAssistant(context.Context, string, config.Config, string, setup.PreflightHost) setup.PreflightObservation {
	available := false
	return setup.PreflightObservation{Available: &available}
}

func isolatedSaveCommand(t *testing.T) string {
	t.Helper()
	isolateOnboardingCommandEnv(t)
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	original, inspect := runAgentSetup, inspectLegacyCodexExperimentResidue
	t.Cleanup(func() { runAgentSetup, inspectLegacyCodexExperimentResidue = original, inspect })
	inspectLegacyCodexExperimentResidue = func() (string, error) { return "", nil }
	runAgentSetup = func(ctx context.Context, o setup.Options) (setup.Result, error) {
		o.ObserveAssistant = noFixtureAssistant
		return setup.Run(ctx, o)
	}
	return filepath.Join(t.TempDir(), "config.json")
}

func runSaveJSON(t *testing.T, path, command string, args ...string) []byte {
	t.Helper()
	argv := append([]string{"agentd", command, "--config", path, "--json"}, args...)
	var out, stderr bytes.Buffer
	if exit := commandExit(argv, &out, &stderr); exit != 0 || stderr.Len() != 0 || !json.Valid(out.Bytes()) {
		t.Fatalf("%s returned %d, stdout=%q stderr=%q", command, exit, out.Bytes(), stderr.Bytes())
	}
	return out.Bytes()
}

func savedFixtureConfig(t *testing.T, path string) ([]byte, config.Config) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	state := config.InspectCommittedDocument(raw)
	if state.Code != "" {
		t.Fatalf("invalid saved config: %s", state.Code)
	}
	return raw, state.Config
}

func TestSetupReceiptMatchesCommittedConfig(t *testing.T) {
	path := isolatedSaveCommand(t)
	t.Setenv("AGENTD_TOKEN", "ignored-fixture-process-token")
	root := t.TempDir()
	var previous []byte
	for _, fresh := range []bool{true, false} {
		raw := runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", root)
		var receipt map[string]any
		if err := json.Unmarshal(raw, &receipt); err != nil {
			t.Fatal(err)
		}
		stored, cfg := savedFixtureConfig(t, path)
		if len(cfg.ScanRoots) != 1 || len(cfg.BrowseRoots) != 1 {
			t.Fatal("unexpected number of root grants")
		}
		want := map[string]any{"ok": true, "configured": true, "created": fresh, "config_path": path, "scan_root": cfg.ScanRoots[0], "browse_root": cfg.BrowseRoots[0]}
		if !reflect.DeepEqual(receipt, want) {
			t.Fatalf("save receipt differs from committed config: %v", receipt)
		}
		resolved, _ := filepath.EvalSymlinks(root)
		actual, err := filepath.EvalSymlinks(cfg.ScanRoots[0])
		if err != nil || actual != resolved || cfg.BrowseRoots[0] != cfg.ScanRoots[0] || !cfg.WorkspaceConfirmed() {
			t.Fatal("unexpected effective root grant or confirmation")
		}
		if cfg.HasEnabledAgent() || cfg.Auth.Token == "" || cfg.Auth.Token == os.Getenv("AGENTD_TOKEN") || !strings.HasPrefix(cfg.Listen, "127.0.0.1:") || cfg.TailscaleAccessEnabled() || cfg.LANAccessEnabled() || cfg.Tailcat.Enabled {
			t.Fatal("fresh setup did not isolate credentials, assistants and network")
		}
		if previous != nil && !bytes.Equal(stored, previous) {
			t.Fatal("unchanged save modified config bytes")
		}
		previous = stored
	}
}

func TestWorkspaceCommandConfirmsAndRestoresPendingRoots(t *testing.T) {
	path := isolatedSaveCommand(t)
	service := httptest.NewServer(http.NotFoundHandler())
	t.Cleanup(service.Close)
	oldScan, oldBrowse, newScan := t.TempDir(), t.TempDir(), t.TempDir()
	_, err := setup.Run(t.Context(), setup.Options{ConfigPath: path, ScanRoot: oldScan, BrowseRoot: oldBrowse, Listen: strings.TrimPrefix(service.URL, "http://"), SaveOnly: true, PendingWorkspace: true, ObserveAssistant: noFixtureAssistant})
	if err != nil {
		t.Fatal(err)
	}
	// Task registration and discovery are unrelated to status/preflight projection.
	origPlatform, origPreflight := managedServicePlatform, runHostPreflight
	t.Cleanup(func() { managedServicePlatform, runHostPreflight = origPlatform, origPreflight })
	managedServicePlatform = "linux"
	runHostPreflight = func(ctx context.Context, o setup.PreflightOptions, progress func(setup.PreflightCheck)) setup.PreflightReport {
		return setup.InspectPreflight(ctx, o, setup.PreflightProbes{Platform: runtime.GOOS, Member: noFixtureAssistant}, progress)
	}
	checkMarker := func(confirmed bool) {
		t.Helper()
		status, stderr, err := captureMainCommandOutput(t, func() error { return runStatus([]string{"status", "--config", path, "--json"}) })
		if err != nil || stderr != "" {
			t.Fatalf("status failed: %v %q", err, stderr)
		}
		report := runSaveJSON(t, path, "preflight", "--stage", "setup")
		for _, response := range []string{status, string(report)} {
			var projection struct {
				Confirmed *bool `json:"workspace_confirmed"`
			}
			if err := json.Unmarshal([]byte(response), &projection); err != nil || projection.Confirmed == nil || *projection.Confirmed != confirmed {
				t.Fatal("workspace_confirmed missing or incorrect")
			}
		}
	}
	checkMarker(false)
	_, before := savedFixtureConfig(t, path)
	receipt := runSaveJSON(t, path, "workspace", "--scan-root", newScan)
	_, after := savedFixtureConfig(t, path)
	resolved, err := filepath.EvalSymlinks(newScan)
	if err != nil || !reflect.DeepEqual(after.ScanRoots, []string{resolved}) || !reflect.DeepEqual(after.BrowseRoots, before.BrowseRoots) || before.Auth.Token != after.Auth.Token {
		t.Fatal("editing scan scope changed another grant or identity")
	}
	checkMarker(true)
	runSaveJSON(t, path, "workspace", "--restore-state", string(receipt))
	original, restored := savedFixtureConfig(t, path)
	if !reflect.DeepEqual(before.ScanRoots, restored.ScanRoots) || !reflect.DeepEqual(before.BrowseRoots, restored.BrowseRoots) || before.Auth.Token != restored.Auth.Token {
		t.Fatal("rollback failed to restore distinct grants")
	}
	checkMarker(false)
	for _, args := range [][]string{{"--root", newScan, "--scan-root", oldScan}, {"--root", newScan, "--browse-root", oldBrowse}, {"--browse-root", oldBrowse}, {"--scan-root", newScan, "--restore-state", string(receipt)}} {
		var out, stderr bytes.Buffer
		argv := append([]string{"agentd", "workspace", "--json", "--config", path}, args...)
		if commandExit(argv, &out, &stderr) != 1 {
			t.Fatal("accepted ambiguous root mutation")
		}
		assertOnboardingError(t, out.Bytes(), stderr.String(), "invalid_request", "config_store")
		current, _ := savedFixtureConfig(t, path)
		if !bytes.Equal(original, current) {
			t.Fatal("rejected workspace edit changed config")
		}
	}
	selectedBrowse := t.TempDir()
	runSaveJSON(t, path, "workspace", "--scan-root", newScan, "--browse-root", selectedBrowse)
	_, explicit := savedFixtureConfig(t, path)
	browse, err := filepath.EvalSymlinks(selectedBrowse)
	if err != nil || !reflect.DeepEqual(explicit.BrowseRoots, []string{browse}) || !reflect.DeepEqual(explicit.ScanRoots, []string{resolved}) || !explicit.WorkspaceConfirmed() {
		t.Fatal("explicit directory pair was not saved")
	}
}

func TestRuntimePathCommandSetsAndClearsPins(t *testing.T) {
	path := isolatedSaveCommand(t)
	runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", t.TempDir())
	_, initial := savedFixtureConfig(t, path)
	pins := map[string]string{}
	for _, id := range []string{"codex", "claude", "agy"} {
		pins[id] = filepath.Join(t.TempDir(), id)
	}
	for _, automatic := range []bool{false, true} {
		var flags []string
		for _, id := range []string{"codex", "claude", "agy"} {
			value := pins[id]
			if automatic {
				value = "auto"
			}
			flags = append(flags, "--runtime-path", id+"="+value)
		}
		var first []byte
		for _, changed := range []bool{true, false} {
			out := runSaveJSON(t, path, "runtime", flags...)
			var result setup.RuntimePathResult
			if err := json.Unmarshal(out, &result); err != nil || result.Changed != changed || result.RestartRequired != changed {
				t.Fatalf("runtime receipt: %s", out)
			}
			raw, cfg := savedFixtureConfig(t, path)
			if first != nil && !bytes.Equal(raw, first) {
				t.Fatal("repeated pin command rewrote config")
			}
			first = raw
			c, hasClaude := cfg.Claude.Env["CLAUDE_BRIDGE_CLAUDE_BIN"]
			a, hasAgy := cfg.Agy.Env[agybridge.AgyBinaryEnvKey]
			if automatic {
				if cfg.Codex.Bin != "codex" || hasClaude || hasAgy {
					t.Fatal("automatic runtime selection retained a pin")
				}
			} else if cfg.Codex.Bin != pins["codex"] || c != pins["claude"] || a != pins["agy"] {
				t.Fatal("one or more runtime choices were lost")
			}
			if cfg.Auth.Token != initial.Auth.Token || cfg.HasEnabledAgent() {
				t.Fatal("selecting a path changed identity or activated an assistant")
			}
		}
	}
}

func TestWizardRejectsChoicesThatWouldSelectAnotherPath(t *testing.T) {
	path := isolatedSaveCommand(t)
	root := t.TempDir()
	runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", root)
	before, _ := savedFixtureConfig(t, path)
	choice := root + " "
	for _, args := range [][]string{
		{"preflight", "--stage", "setup", "--scan-root", choice},
		{"setup", "--no-pair", "--scan-root", choice, "--create-root"},
		{"setup", "--no-pair", "--scan-root", root, "--browse-root", choice},
		{"workspace", "--root", choice},
		{"workspace", "--scan-root", choice},
		{"runtime", "--runtime-path", "codex=" + choice},
	} {
		var out, stderr bytes.Buffer
		argv := append(append([]string{"agentd"}, args...), "--config", path, "--json")
		if commandExit(argv, &out, &stderr) != 1 {
			t.Fatalf("accepted ambiguous path for %s", args[0])
		}
		assertOnboardingError(t, out.Bytes(), stderr.String(), "invalid_request", "config_store")
	}
	after, _ := savedFixtureConfig(t, path)
	if !bytes.Equal(before, after) {
		t.Fatal("a different grant or executable was persisted")
	}
}

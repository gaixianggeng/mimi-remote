package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
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
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
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
	raw, initial := savedFixtureConfig(t, path)
	var legacy map[string]json.RawMessage
	if err := json.Unmarshal(raw, &legacy); err != nil {
		t.Fatal(err)
	}
	legacy["codex"] = json.RawMessage(`{"enabled":false,"future":true}`)
	raw, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	cleared := runSaveJSON(t, path, "runtime", "--runtime-path", "codex=auto")
	var noop setup.RuntimePathResult
	if err := json.Unmarshal(cleared, &noop); err != nil || noop.Changed || noop.RestartRequired {
		t.Fatal("clearing an implicit automatic selection requested a restart")
	}
	if stored, _ := savedFixtureConfig(t, path); !bytes.Equal(raw, stored) {
		t.Fatal("clearing an absent pin rewrote the legacy config")
	}
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

func TestSaveRefusesNoncanonicalPermissionsBeforeWritesAndDoctorRepairs(t *testing.T) {
	path := isolatedSaveCommand(t)
	runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", t.TempDir())
	_, cfg := savedFixtureConfig(t, path)
	token := filepath.Join(filepath.Dir(path), "deepseek.token")
	configtest.CreatePrivateFile(t, token, []byte("fixture-companion"))
	cfg.DeepSeek.TokenFile = token
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	configtest.WritePrivateFile(t, path, raw)
	targets := map[string]string{"config": path, "deepseek": token}
	if cfg.AppServer.Transport == "ws" {
		targets["ws"] = cfg.AppServer.WSTokenFile
	}
	for name, target := range targets {
		for _, scope := range []string{"broader", "narrower"} {
			t.Run(name+"/"+scope, func(t *testing.T) {
				prior, err := config.ReadPrivatePreflightFile(target, 4<<20)
				if err != nil {
					t.Fatal(err)
				}
				id, err := config.FileIdentity(target)
				if err != nil {
					t.Fatal(err)
				}
				configtest.SetNoncanonicalPermissions(t, target, scope == "narrower")
				if got := config.ReadPreflightSnapshot(path).Code; got != "config_permissions_unsafe" {
					t.Fatalf("preflight code %q", got)
				}
				root := filepath.Join(t.TempDir(), "new-workspace")
				var out, stderr bytes.Buffer
				args := []string{"agentd", "setup", "--config", path, "--json", "--no-pair", "--create-root", "--scan-root", root}
				if code := commandExit(args, &out, &stderr); code != 1 {
					t.Fatalf("save exit %d", code)
				}
				assertOnboardingError(t, out.Bytes(), stderr.String(), "config_permissions_unsafe", "config_store")
				assertPathDoesNotExist(t, root, "created workspace before checking permissions")
				if got := config.ReadPreflightSnapshot(path).Code; got != "config_permissions_unsafe" {
					t.Fatal("save changed permissions")
				}
				runSaveJSON(t, path, "doctor", "--fix")
				if got := config.ReadPreflightSnapshot(path).Code; got != "" {
					t.Fatalf("preflight after doctor: %s", got)
				}
				now, err := config.FileIdentity(target)
				if err != nil || !os.SameFile(id, now) {
					t.Fatal("repair replaced the file")
				}
				body, err := config.ReadPrivatePreflightFile(target, 4<<20)
				if err != nil || !bytes.Equal(body, prior) {
					t.Fatal("repair changed credential bytes")
				}
				if saved, _ := savedFixtureConfig(t, path); !bytes.Equal(saved, raw) {
					t.Fatal("config changed on refusal or repair")
				}
			})
		}
	}
	// A pre-canonical installation can need repairs to all three files at once.
	for _, target := range targets {
		configtest.SetNoncanonicalPermissions(t, target, true)
	}
	runSaveJSON(t, path, "doctor", "--fix")
	if got := config.ReadPreflightSnapshot(path).Code; got != "" {
		t.Fatalf("incomplete installation repair: %s", got)
	}
	runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", t.TempDir())
}

func TestSaveAndDoctorCheckInterruptedPublicationPermissions(t *testing.T) {
	for _, kind := range []string{"journal", "stage", "backup", "token stage", "identity"} {
		for _, scope := range []string{"broader", "narrower"} {
			t.Run(kind+"/"+scope, func(t *testing.T) {
				path := isolatedSaveCommand(t)
				root := t.TempDir()
				runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", root)
				raw, cfg := savedFixtureConfig(t, path)
				dir, journal := filepath.Dir(path), config.SetupJournalPath(path)
				sum := fmt.Sprintf("%x", sha256.Sum256(raw))
				record := config.SetupPublication{ConfigStage: ".config.json.tmp-permissions", After: sum, Before: sum, Backup: ".config.json.bak-permissions"}
				stage := filepath.Join(dir, record.ConfigStage)
				configtest.CreatePrivateFile(t, stage, raw)
				backup := filepath.Join(dir, record.Backup)
				if err := os.Link(path, backup); err != nil {
					t.Fatal(err)
				}
				token := []byte("test transaction companion")
				record.TokenStage, record.Companion = ".mimi-ws.tmp-permissions", "app-server-ws-token-permissions"
				record.TokenDigest = fmt.Sprintf("%x", sha256.Sum256(token))
				tokenStage := filepath.Join(dir, record.TokenStage)
				configtest.CreatePrivateFile(t, tokenStage, token)
				if err := os.Link(tokenStage, filepath.Join(dir, record.Companion)); err != nil {
					t.Fatal(err)
				}
				body, err := json.Marshal(record)
				if err != nil {
					t.Fatal(err)
				}
				configtest.CreatePrivateFile(t, journal, body)
				id, err := json.Marshal(map[string]string{"bearer": cfg.Auth.Token})
				if err != nil {
					t.Fatal(err)
				}
				configtest.CreatePrivateFile(t, journal+".identity", id)
				target := map[string]string{"journal": journal, "stage": stage, "backup": backup, "token stage": tokenStage, "identity": journal + ".identity"}[kind]
				configtest.SetNoncanonicalPermissions(t, target, scope == "narrower")
				if kind == "backup" {
					configtest.SetNoncanonicalPermissions(t, journal, true)
				}
				if got := config.ReadPreflightSnapshot(path).Code; got != "config_permissions_unsafe" {
					t.Fatalf("preflight: %s", got)
				}
				entries, err := os.ReadDir(dir)
				if err != nil {
					t.Fatal(err)
				}
				var out, stderr bytes.Buffer
				nextRoot := filepath.Join(root, "new")
				args := []string{"agentd", "setup", "--config", path, "--json", "--no-pair", "--create-root", "--scan-root", nextRoot}
				if commandExit(args, &out, &stderr) != 1 {
					t.Fatal("expected permission refusal")
				}
				assertOnboardingError(t, out.Bytes(), stderr.String(), "config_permissions_unsafe", "config_store")
				after, err := os.ReadDir(dir)
				if err != nil || len(entries) != len(after) {
					t.Fatal("refusal changed transaction files")
				}
				for i := range entries {
					if entries[i].Name() != after[i].Name() {
						t.Fatal("refusal changed transaction files")
					}
				}
				assertPathDoesNotExist(t, nextRoot, "workspace created before permission refusal")
				runSaveJSON(t, path, "doctor", "--fix")
				if err := config.CheckPrivatePermissions(target); err != nil {
					t.Fatal(err)
				}
				runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", root)
				assertPathDoesNotExist(t, journal, "save did not finish replay after repair")
				now, _ := savedFixtureConfig(t, path)
				if !bytes.Equal(now, raw) {
					t.Fatal("permission repair or replay changed saved configuration")
				}
			})
		}
	}
}

func TestDoctorFixesInterruptedIdentityBeforeFirstConfig(t *testing.T) {
	path := isolatedSaveCommand(t)
	witness := config.SetupJournalPath(path) + ".identity"
	configtest.CreatePrivateFile(t, witness, []byte(`{"bearer":"fixture-preserved-interrupted-bearer"}`))
	configtest.SetNoncanonicalPermissions(t, witness, true)
	if got := config.ReadPreflightSnapshot(path).Code; got != "config_permissions_unsafe" {
		t.Fatal(got)
	}
	runSaveJSON(t, path, "doctor", "--fix")
	assertPathDoesNotExist(t, path, "doctor published a config during access repair")
	runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", t.TempDir())
	_, cfg := savedFixtureConfig(t, path)
	if cfg.Auth.Token != "fixture-preserved-interrupted-bearer" {
		t.Fatal("lost interrupted identity")
	}
}

func TestDoctorExternalCredentialNeedsNamedTarget(t *testing.T) {
	path := isolatedSaveCommand(t)
	root := t.TempDir()
	runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", root)
	_, cfg := savedFixtureConfig(t, path)
	token := filepath.Join(t.TempDir(), "external.token")
	configtest.CreatePrivateFile(t, token, []byte("external fixture"))
	cfg.DeepSeek.TokenFile = token
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	configtest.WritePrivateFile(t, path, raw)
	for _, narrow := range []bool{false, true} {
		configtest.SetNoncanonicalPermissions(t, token, narrow)
		if e := runDoctorWithWriters([]string{"doctor", "--config", path, "--fix"}, io.Discard, io.Discard); e == nil {
			t.Fatal("doctor changed an external reference without an explicit target")
		}
		if err := config.CheckPrivatePermissions(token); config.PrivateFileDiagnostic(err) != "config_permissions_unsafe" {
			t.Fatalf("external reference was modified: %v", err)
		}
		runSaveJSON(t, path, "doctor", "--fix", "--permission-file", token)
		runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", root)
	}
}

func TestDoctorPreservesReplacedRecoveryEvidence(t *testing.T) {
	path := isolatedSaveCommand(t)
	stage := filepath.Join(filepath.Dir(path), ".config.json.tmp-fixture")
	replacement := []byte("unrelated replacement")
	configtest.CreatePrivateFile(t, stage, replacement)
	configtest.SetNoncanonicalPermissions(t, stage, true)
	record := config.SetupPublication{ConfigStage: filepath.Base(stage), After: fmt.Sprintf("%x", sha256.Sum256([]byte("expected stage")))}
	raw, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	journal := config.SetupJournalPath(path)
	configtest.CreatePrivateFile(t, journal, raw)
	if err := runDoctorWithWriters([]string{"doctor", "--config", path, "--fix"}, io.Discard, io.Discard); err == nil {
		t.Fatal("accepted unrelated recovery member")
	}
	if err := config.CheckPrivatePermissions(stage); config.PrivateFileDiagnostic(err) != "config_permissions_unsafe" {
		t.Fatal("changed unrelated file permissions")
	}
	now, err := os.ReadFile(stage)
	if err != nil || !bytes.Equal(now, replacement) {
		t.Fatal("changed unrelated file contents")
	}
	assertPathDoesNotExist(t, journal+".recovery", "created a marker during access repair")
}

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestInstallerBootstrapPreservesIdentityAndConfirmsOnlySelectedFolder(t *testing.T) {
	path := isolatedSaveCommand(t)
	lan := false
	o := setup.Options{
		ConfigPath: path, SaveOnly: true, LocalServiceOnly: true,
		PendingWorkspace: true, InstallerLAN: &lan, ObserveAssistant: noFixtureAssistant,
	}
	created, err := setup.Run(t.Context(), o)
	if err != nil {
		t.Fatal(err)
	}
	saved, pending := savedFixtureConfig(t, path)
	if !created.Created || pending.WorkspaceConfirmed() || pending.LANAccessEnabled() || len(pending.ScanRoots) != 1 ||
		!reflect.DeepEqual(pending.ScanRoots, pending.BrowseRoots) {
		t.Fatal("unexpected silent bootstrap state")
	}
	if _, err := setup.Run(t.Context(), o); err != nil {
		t.Fatal(err)
	}
	repeated, _ := savedFixtureConfig(t, path)
	if !bytes.Equal(saved, repeated) {
		t.Fatal("unchanged bootstrap rewrote config")
	}

	o.PendingWorkspace, o.RequireExisting, o.ScanRoot = false, true, t.TempDir()
	lan = true
	if _, err := setup.Run(t.Context(), o); err != nil {
		t.Fatal(err)
	}
	updated, confirmed := savedFixtureConfig(t, path)
	root, err := filepath.EvalSymlinks(o.ScanRoot)
	if err != nil || !confirmed.WorkspaceConfirmed() || !confirmed.LANAccessEnabled() ||
		confirmed.Auth != pending.Auth || !reflect.DeepEqual(confirmed.ScanRoots, []string{root}) ||
		!reflect.DeepEqual(confirmed.ScanRoots, confirmed.BrowseRoots) {
		t.Fatal("explicit choice did not produce the expected grant")
	}

	// Simulate a valid older host with multiple grants, unknown fields, a
	// wildcard bind and no independent network controls or onboarding marker.
	var doc map[string]any
	if err := json.Unmarshal(updated, &doc); err != nil {
		t.Fatal(err)
	}
	delete(doc, "onboarding")
	doc["scan_roots"] = []string{root, t.TempDir()}
	doc["browse_roots"] = []string{t.TempDir(), root}
	doc["listen"] = "0.0.0.0:9123"
	doc["network"] = map[string]any{"allow_lan": true, "future": 17}
	doc["future"] = "keep"
	original, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	configtest.WritePrivateFile(t, path, original)
	_, legacy := savedFixtureConfig(t, path)
	lan, o.ScanRoot = false, t.TempDir()
	if _, err := setup.Run(t.Context(), o); err != nil {
		t.Fatal(err)
	}
	raw, upgraded := savedFixtureConfig(t, path)
	if upgraded.Auth != pending.Auth || !upgraded.WorkspaceConfirmed() || upgraded.LANAccessEnabled() ||
		!upgraded.TailscaleAccessEnabled() || !reflect.DeepEqual(upgraded.ScanRoots, legacy.ScanRoots) ||
		!reflect.DeepEqual(upgraded.BrowseRoots, legacy.BrowseRoots) || !bytes.Contains(raw, []byte("keep")) {
		t.Fatal("upgrade changed identity, existing scope, or another route")
	}
}

func TestInstallerCannotReplaceMissingIdentity(t *testing.T) {
	path := isolatedSaveCommand(t)
	lan := false
	o := setup.Options{ConfigPath: path, RequireExisting: true, InstallerLAN: &lan, SaveOnly: true}
	if _, err := setup.Run(t.Context(), o); err == nil {
		t.Fatal("upgrade created missing identity")
	}
	o.RequireExisting = false
	configtest.CreatePrivateFile(t, filepath.Join(filepath.Dir(path), "app-server-ws-token"), []byte("test-companion"))
	if _, err := setup.Run(t.Context(), o); err == nil {
		t.Fatal("fresh install replaced orphaned credentials")
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unexpected config publication")
	}
}

func TestInstallerPreflightRequiresOfflineReport(t *testing.T) {
	root := t.TempDir()
	o := setup.PreflightOptions{ConfigPath: filepath.Join(root, "config.json"), ScanRoot: root, BrowseRoot: root}
	r := setup.PreflightReport{Schema: "mimi.onboarding.preflight/v1", Stage: "setup", OK: true, ConfigPath: o.ConfigPath, ScanRoot: root, BrowseRoot: root, ScanRootExists: true,
		Checks: []setup.PreflightCheck{{ID: "config_store", State: "ok"}, {ID: "workspace_root", State: "ok"}}}
	if !validInstallerPreflight(r, o) {
		t.Fatal("offline report rejected")
	}
	for _, change := range []func(*setup.PreflightReport){
		func(r *setup.PreflightReport) { r.Configured = true },
		func(r *setup.PreflightReport) { r.Checks = nil },
		func(r *setup.PreflightReport) { r.Schema = "old" },
		func(r *setup.PreflightReport) { r.ConfigPath = "other" },
		func(r *setup.PreflightReport) { r.ScanRootExists = false },
		func(r *setup.PreflightReport) { r.OK = false },
	} {
		bad := r
		change(&bad)
		if validInstallerPreflight(bad, o) {
			t.Fatal("unexpected installer report accepted")
		}
	}
}

func TestInstallerBootstrapCommandValidatesIntentBeforeTaskAccess(t *testing.T) {
	isolatedSaveCommand(t)
	previousPlatform, previousLookup := managedServicePlatform, windowsLookPath
	t.Cleanup(func() { managedServicePlatform, windowsLookPath = previousPlatform, previousLookup })
	managedServicePlatform = "windows"
	windowsLookPath = func(string) (string, error) { return "", errors.New("fixture task missing") }
	for _, tc := range []struct {
		flags      []string
		code, step string
	}{
		{[]string{"--installer-bootstrap", "--no-pair"}, "invalid_request", "config_store"},
		{[]string{"--installer-bootstrap", "--lan-enabled=false"}, "invalid_request", "config_store"},
		{[]string{"--no-pair", "--lan-enabled=false"}, "invalid_request", "config_store"},
		{[]string{"--installer-bootstrap", "--no-pair", "--lan-enabled=false", "--browse-root", "relative"}, "invalid_request", "config_store"},
		{[]string{"--installer-bootstrap", "--no-pair", "--lan-enabled=false"}, "service_not_registered", "service_daemon"},
	} {
		var out, stderr bytes.Buffer
		args := append([]string{"agentd", "up", "--json"}, tc.flags...)
		if commandExit(args, &out, &stderr) != 1 {
			t.Fatalf("unexpected success: %q", args)
		}
		assertOnboardingError(t, out.Bytes(), stderr.String(), tc.code, tc.step)
	}
}

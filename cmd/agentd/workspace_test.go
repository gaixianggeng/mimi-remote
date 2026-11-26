package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
)

func TestWorkspacePrimaryAndBrowseOnlyEditsPreserveMigratedRoots(t *testing.T) {
	path := isolatedSaveCommand(t)
	resolvedDir := func() string {
		t.Helper()
		root, err := filepath.EvalSymlinks(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		return root
	}
	first, extraScan, extraBrowse, selected := resolvedDir(), resolvedDir(), resolvedDir(), resolvedDir()
	runSaveJSON(t, path, "setup", "--no-pair", "--scan-root", first)
	raw, initial := savedFixtureConfig(t, path)
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	scan := []string{first, extraScan}
	browse := []string{first, extraBrowse}
	doc["scan_roots"], doc["browse_roots"] = scan, browse
	doc["onboarding"] = map[string]bool{"workspace_confirmed": false}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	check := func(wantScan, wantBrowse []string, confirmed bool) {
		t.Helper()
		_, state := savedFixtureConfig(t, path)
		if !slices.Equal(state.ScanRoots, wantScan) || !slices.Equal(state.BrowseRoots, wantBrowse) ||
			state.WorkspaceConfirmed() != confirmed || state.Auth.Token != initial.Auth.Token {
			t.Fatal("workspace edit changed an unrelated root, confirmation or identity")
		}
	}

	// Matching first paths do not imply that either list has only one root.
	receipt := runSaveJSON(t, path, "workspace", "--primary", "--browse-root", selected)
	check(scan, []string{selected, extraBrowse}, false)
	runSaveJSON(t, path, "workspace", "--restore-state", string(receipt))
	check(scan, browse, false)
	runSaveJSON(t, path, "workspace", "--primary", "--scan-root", first, "--browse-root", first)
	check(scan, browse, true)
	receipt = runSaveJSON(t, path, "workspace", "--primary", "--scan-root", selected, "--browse-root", selected)
	check([]string{selected, extraScan}, []string{selected, extraBrowse}, true)
	runSaveJSON(t, path, "workspace", "--restore-state", string(receipt))
	check(scan, browse, true)

	runSaveJSON(t, path, "workspace", "--primary", "--browse-root", selected)
	check(scan, []string{selected, extraBrowse}, true)
	receipt = runSaveJSON(t, path, "workspace", "--set-browse-root", first)
	check(scan, []string{first}, true)
	runSaveJSON(t, path, "workspace", "--restore-state", string(receipt))
	check(scan, []string{selected, extraBrowse}, true)

	for _, args := range [][]string{
		{"--primary"}, {"--primary", "--root", first}, {"--primary", "--restore-state", string(receipt)},
		{"--set-browse-root", selected, "--primary"}, {"--set-browse-root", selected, "--scan-root", first},
	} {
		var out, stderr bytes.Buffer
		if commandExit(append([]string{"agentd", "workspace", "--json", "--config", path}, args...), &out, &stderr) != 1 {
			t.Fatal("accepted conflicting workspace modes")
		}
		assertOnboardingError(t, out.Bytes(), stderr.String(), "invalid_request", "config_store")
		check(scan, []string{selected, extraBrowse}, true)
	}
}

func TestWorkspaceCLIChangesRootsWithoutDisclosingToken(t *testing.T) {
	root := filepath.Join(t.TempDir(), "code with spaces")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	server := config.DefaultSharedLocalAppServerConfig()
	if runtime.GOOS == "windows" {
		server = config.DefaultManagedAppServerConfig()

		token, err := config.CreatePrivateTemp(t.TempDir(), "app-server-token")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := token.WriteString("synthetic-test-companion"); err != nil {
			t.Fatal(err)
		}
		if err := token.Close(); err != nil {
			t.Fatal(err)
		}
		server.WSTokenFile = token.Name()
	}
	raw, err := json.Marshal(map[string]any{
		"listen": "127.0.0.1:8787", "auth": config.AuthConfig{Token: "workspace-cli-private"}, "app_server": server,
		"codex":    config.CodexConfig{Bin: "codex"},
		"projects": []config.ProjectConfig{{ID: "fixture", Name: "fixture", Path: root}},
	})
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, path, raw)
	var stdout, stderr bytes.Buffer
	if err := runWorkspaceWithWriters([]string{"workspace", "--config", path, "--root", root, "--json"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	if !json.Valid(stdout.Bytes()) || strings.Contains(stdout.String()+stderr.String(), "workspace-cli-private") {
		t.Fatal("CLI returned invalid JSON or a long-lived credential")
	}
	updated, err := config.Load(path)
	if err != nil || len(updated.ScanRoots) != 1 || updated.Auth.Token != "workspace-cli-private" {
		t.Fatalf("workspace was not applied safely: %v", err)
	}
	transaction := stdout.String()
	stdout.Reset()
	if err := runWorkspaceWithWriters([]string{"workspace", "--config", path, "--restore-state", transaction, "--json"}, &stdout, &stderr); err != nil {
		t.Fatalf("cannot restore the workspace from the CLI's JSON output: %v", err)
	}
	restored, err := config.Load(path)
	if err != nil || len(restored.ScanRoots) != 0 || len(restored.BrowseRoots) != 0 || restored.Auth.Token != "workspace-cli-private" {
		t.Fatalf("CLI rollback did not preserve the previous configuration: %v", err)
	}
	if err := runWorkspaceWithWriters([]string{"workspace", "--root", root, "--restore-state", "{}"}, &stdout, &stderr); err == nil {
		t.Fatal("ambiguous mutation accepted")
	}
}

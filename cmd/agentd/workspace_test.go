package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestWorkspaceCLIChangesRootsWithoutDisclosingToken(t *testing.T) {
	root := filepath.Join(t.TempDir(), "code with spaces")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	server := config.DefaultSharedLocalAppServerConfig()
	if runtime.GOOS == "windows" {
		server = config.DefaultManagedAppServerConfig()
		server.WSTokenFile = filepath.Join(t.TempDir(), "app-server-token")
	}
	raw, err := json.Marshal(map[string]any{
		"listen": "127.0.0.1:8787", "auth": config.AuthConfig{Token: "workspace-cli-private"}, "app_server": server,
		"codex":    config.CodexConfig{Bin: "codex"},
		"projects": []config.ProjectConfig{{ID: "fixture", Name: "fixture", Path: root}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
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
	if err := runWorkspaceWithWriters([]string{"workspace", "--root", root, "--restore-state", "{}"}, &stdout, &stderr); err == nil {
		t.Fatal("ambiguous mutation accepted")
	}
}

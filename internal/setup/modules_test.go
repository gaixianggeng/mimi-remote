package setup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func moduleTestConfig(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "config.json")
	raw, err := json.Marshal(map[string]any{
		"listen":   "127.0.0.1:8787",
		"auth":     map[string]any{"token": "test-token-with-at-least-32-characters"},
		"codex":    map[string]any{"enabled": false, "bin": "missing-codex", "future": "keep"},
		"projects": []map[string]any{{"id": "test", "path": root}},
		"future":   map[string]any{"preserve": true},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestModuleMutationPreservesSecretsUnknownFieldsAndUndo(t *testing.T) {
	path := moduleTestConfig(t)
	original, _ := os.ReadFile(path)
	change, err := ConfigureModule(context.Background(), path, "tailscale", false, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !change.Changed || !change.RestartRequired || change.Configuration.TailscaleEnabled {
		t.Fatalf("unexpected change: %+v", change)
	}
	if change.Previous.Tailscale != nil {
		t.Fatal("legacy absent value lost")
	}
	current, _ := os.ReadFile(path)
	var oldDoc, newDoc map[string]json.RawMessage
	json.Unmarshal(original, &oldDoc)
	json.Unmarshal(current, &newDoc)
	for _, field := range []string{"auth", "future"} {
		var a, b any
		json.Unmarshal(oldDoc[field], &a)
		json.Unmarshal(newDoc[field], &b)
		before, _ := json.Marshal(a)
		after, _ := json.Marshal(b)
		if string(before) != string(after) {
			t.Fatalf("%s changed", field)
		}
	}
	restored, err := ConfigureModule(context.Background(), path, "tailscale", true, change.Revision, &change.Previous)
	if err != nil {
		t.Fatal(err)
	}
	if !restored.Configuration.TailscaleEnabled || restored.Configuration.CodexEnabled {
		t.Fatal("incorrect restored intent")
	}
}

func TestModuleRollbackRefusesConcurrentWriter(t *testing.T) {
	path := moduleTestConfig(t)
	change, err := ConfigureModule(context.Background(), path, "tailscale", false, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	current, _ := os.ReadFile(path)
	external := append(current, '\n')
	os.WriteFile(path, external, 0600)
	if _, err := ConfigureModule(context.Background(), path, "tailscale", true, change.Revision, &change.Previous); err == nil {
		t.Fatal("stale rollback accepted")
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(external) {
		t.Fatal("concurrent edit overwritten")
	}
}

func TestModuleUnknownAndUnversionedRestoreDoNotWrite(t *testing.T) {
	path := moduleTestConfig(t)
	before, _ := os.ReadFile(path)
	if _, err := ConfigureModule(context.Background(), path, "deepseek", true, "", nil); err == nil {
		t.Fatal("unsupported module accepted")
	}
	if _, err := ConfigureModule(context.Background(), path, "codex", true, "", &ModulePreferences{}); err == nil {
		t.Fatal("unversioned restore accepted")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("invalid operation modified config")
	}
}

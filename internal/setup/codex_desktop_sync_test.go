package setup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestConfigureCodexDesktopSyncPreservesUnknownFields(t *testing.T) {
	path := writeDesktopSyncFixture(t, map[string]any{
		"unknown_root": map[string]any{"keep": true},
		"codex":        map[string]any{"bin": "codex", "future": "keep"},
		"app_server":   map[string]any{"transport": "ws", "future": "keep"},
	})
	withDesktopSyncLegacyHooks(t, false, nil)
	result, err := ConfigureCodexDesktopSync(context.Background(), path, true, false)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Changed || !result.ServiceRestartRequired || result.LegacyCleanupRequired {
		t.Fatalf("unexpected result: %+v", result)
	}
	document := readDesktopSyncFixture(t, path)
	codex := document["codex"].(map[string]any)
	if codex["desktop_sync_enabled"] != true || codex["future"] != "keep" {
		t.Fatalf("codex unknown fields were not preserved: %#v", codex)
	}
	if document["unknown_root"].(map[string]any)["keep"] != true {
		t.Fatalf("root unknown fields were not preserved: %#v", document)
	}
}

func TestConfigureCodexDesktopSyncRequiresExplicitLegacyCleanup(t *testing.T) {
	path := writeDesktopSyncFixture(t, map[string]any{
		"codex": map[string]any{"desktop_sync_enabled": false},
		"app_server": map[string]any{
			"transport":       "unix",
			"shared_fallback": map[string]any{"transport": "ws", "managed": true, "listen": "ws://127.0.0.1:4999", "future": "keep"},
		},
	})
	withDesktopSyncLegacyHooks(t, false, nil)
	before, _ := os.ReadFile(path)
	result, err := ConfigureCodexDesktopSync(context.Background(), path, true, false)
	if err != nil {
		t.Fatal(err)
	}
	if !result.LegacyCleanupRequired || result.Changed || result.Enabled {
		t.Fatalf("legacy config must block enable: %+v", result)
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("unconfirmed legacy cleanup must not modify config")
	}
}

func TestConfigureCodexDesktopSyncCleanupRestoresIndependentWS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("legacy cleanup is macOS-only")
	}
	path := writeDesktopSyncFixture(t, map[string]any{
		"codex": map[string]any{},
		"app_server": map[string]any{
			"transport": "unix", "managed": true, "future": "keep",
			"shared_fallback": map[string]any{
				"transport": "ws", "managed": true, "listen": "ws://127.0.0.1:4999",
				"ws_token_file": "/tmp/token", "future": "ignored",
			},
		},
	})
	cleaned := false
	withDesktopSyncLegacyHooks(t, true, func(context.Context) error { cleaned = true; return nil })
	result, err := ConfigureCodexDesktopSync(context.Background(), path, true, true)
	if err != nil {
		t.Fatal(err)
	}
	if !cleaned || result.LegacyCleanupRequired || !result.Enabled {
		t.Fatalf("cleanup was not completed: cleaned=%t result=%+v", cleaned, result)
	}
	document := readDesktopSyncFixture(t, path)
	appServer := document["app_server"].(map[string]any)
	if appServer["transport"] != "ws" || appServer["listen"] != "ws://127.0.0.1:4999" {
		t.Fatalf("fallback was not restored: %#v", appServer)
	}
	if _, exists := appServer["shared_fallback"]; exists || appServer["future"] != "keep" {
		t.Fatalf("legacy field was not removed cleanly: %#v", appServer)
	}
}

func withDesktopSyncLegacyHooks(t *testing.T, present bool, cleanup func(context.Context) error) {
	t.Helper()
	oldInspect := inspectDesktopSyncLegacyArtifacts
	oldRemove := removeDesktopSyncLegacyArtifacts
	inspectDesktopSyncLegacyArtifacts = func() (bool, error) { return present, nil }
	if cleanup == nil {
		cleanup = func(context.Context) error { return nil }
	}
	removeDesktopSyncLegacyArtifacts = cleanup
	t.Cleanup(func() {
		inspectDesktopSyncLegacyArtifacts = oldInspect
		removeDesktopSyncLegacyArtifacts = oldRemove
	})
}

func writeDesktopSyncFixture(t *testing.T, value map[string]any) string {
	t.Helper()
	payload, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, append(payload, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func readDesktopSyncFixture(t *testing.T, path string) map[string]any {
	t.Helper()
	payload, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	return value
}

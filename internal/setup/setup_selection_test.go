package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSetupSavesWithoutRequiredAssistants(t *testing.T) {
	for _, sole := range []string{"none", "claude", "deepseek"} {
		t.Run(sole, func(t *testing.T) {
			clearSetupEnv(t)
			old := observeSetupAssistant
			observeSetupAssistant = func(_ context.Context, id string, _ config.Config, _ string, _ PreflightHost) PreflightObservation {
				if id == sole {
					return PreflightObservation{Available: knownAvailability(true)}
				}
				return unavailable(id + "_not_found")
			}
			t.Cleanup(func() { observeSetupAssistant = old })
			path := filepath.Join(t.TempDir(), "config.json")
			opts := atomicSetupOptions(t, path, false)
			if _, err := Run(t.Context(), opts); err != nil {
				t.Fatal(err)
			}
			cfg, err := config.Load(path)
			if err != nil {
				t.Fatal(err)
			}
			if cfg.Codex.Enabled == nil || cfg.Codex.IsEnabled() || cfg.Agy.Enabled || cfg.Claude.Enabled != (sole == "claude") || cfg.DeepSeek.Enabled {
				t.Fatalf("unexpected fresh assistant settings (%s)", sole)
			}
			if sole != "deepseek" {
				return
			}
			// Simulate the already connected Harness. Setup never creates Harness credentials.
			secret := []byte("synthetic Harness fixture")
			token := filepath.Join(t.TempDir(), "harness-token")
			writeFileWithMode(t, token, secret, 0600)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var doc map[string]json.RawMessage
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatal(err)
			}
			doc["deepseek"], err = json.Marshal(map[string]any{"enabled": true, "token_file": token, "base_url": "https://harness.example.test", "future_harness_option": 63})
			if err != nil {
				t.Fatal(err)
			}
			doc["future_root"] = json.RawMessage(`{"keep":true}`)
			raw, err = json.Marshal(doc)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			opts.ScanRoot = t.TempDir()
			if _, err := Run(t.Context(), opts); err != nil {
				t.Fatal(err)
			}
			after, err := config.Load(path)
			if err != nil {
				t.Fatal(err)
			}
			if !after.DeepSeek.Enabled || after.DeepSeek.TokenFile != token || after.Codex.IsEnabled() || after.Claude.Enabled || after.Agy.Enabled {
				t.Fatal("save changed selected assistant or token reference")
			}
			raw, err = os.ReadFile(path)
			if err != nil || !bytes.Contains(raw, []byte("future_harness_option")) || !bytes.Contains(raw, []byte("future_root")) {
				t.Fatalf("lost future options: %v", err)
			}
			assertFileBytesAndMode(t, token, secret, 0600)
		})
	}
}

func TestSetupRevalidatesSelectionAndPreservesDistinctPriorGrants(t *testing.T) {
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	opts := atomicSetupOptions(t, path, false)
	first, err := Run(t.Context(), opts)
	if err != nil {
		t.Fatal(err)
	}
	if first.ScanRoot == first.BrowseRoot {
		t.Fatal("fixture must contain separate grants")
	}
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	replay := Options{ConfigPath: path, SaveOnly: true}
	noOp := defaultSetupFileTransactionOps()
	noOp.rename = func(string, string) error { t.Fatal("no-op rewrote committed config"); return nil }
	receipt, err := runWithFileOps(t.Context(), replay, noOp)
	if err != nil || receipt.Created || receipt.ScanRoot != first.ScanRoot || receipt.BrowseRoot != first.BrowseRoot {
		t.Fatalf("no-op lost committed selection: %v", err)
	}
	for _, test := range []string{"cancel widening", "mount disappeared", "mount replaced at same path"} {
		t.Run(test, func(t *testing.T) {
			change := replay
			next := t.TempDir()
			change.BrowseRoot = next
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			ops := defaultSetupFileTransactionOps()
			stage := ops.stage
			reachedStage := false
			ops.stage = func(dir, pattern string, raw []byte, permissionsFrom string) (string, error) {
				p, err := stage(dir, pattern, raw, permissionsFrom)
				if err == nil && !reachedStage {
					reachedStage = true
					switch test {
					case "cancel widening":
						cancel()
					case "mount disappeared":
						if err := os.Remove(next); err != nil {
							t.Fatal(err)
						}
					default:
						if err := os.Rename(next, next+".detached"); err != nil {
							t.Fatal(err)
						}
						if err := os.Mkdir(next, 0700); err != nil {
							t.Fatal(err)
						}
					}
				}
				return p, err
			}
			if _, err := runWithFileOps(ctx, change, ops); err == nil || !reachedStage {
				t.Fatalf("stale/cancelled selection committed (stage=%v): %v", reachedStage, err)
			}
			assertFileBytesAndMode(t, path, original, 0600)
		})
	}
}

func TestSetupCreatesSelectedDirectoryOnlyWhenConfirmed(t *testing.T) {
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	root := filepath.Join(t.TempDir(), "chosen")
	opts := Options{ConfigPath: path, ScanRoot: root, SaveOnly: true}
	if _, err := Run(t.Context(), opts); err == nil {
		t.Fatal("no confirmation supplied for absent root")
	}
	assertMissingPath(t, path)
	assertMissingPath(t, root)
	opts.CreateRoot = true
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		t.Fatalf("confirmed directory not created: %v", err)
	}
}

func TestSetupRuntimePinSetAndCleared(t *testing.T) {
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	pin := filepath.Join(t.TempDir(), "codex")
	writeFileWithMode(t, pin, []byte("synthetic executable"), 0700)
	opts := Options{ConfigPath: path, ScanRoot: t.TempDir(), SaveOnly: true, RuntimePaths: map[string]string{"codex": pin}}
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.LoadForDoctor(path)
	if err != nil || cfg.Codex.Bin != pin {
		t.Fatalf("explicit pin absent: %v", err)
	}
	opts.RuntimePaths["codex"] = "auto"
	if _, err := Run(t.Context(), opts); err != nil {
		t.Fatal(err)
	}
	cfg, err = config.LoadForDoctor(path)
	if err != nil || cfg.Codex.Bin != "codex" {
		t.Fatalf("stale pin persisted: %v", err)
	}
}

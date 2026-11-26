package setup

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
)

func moduleTestConfig(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	raw := []byte(`{"listen":"100.64.0.2:8787","auth":{"token":"module-test-only"},"app_server":{"transport":"local"},"codex":{"bin":"/missing/module-test-codex","future":{"keep":true}},"claude":{"enabled":false},"network":{"allow_lan":false,"future":17},"future_root":["keep"]}`)
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	document["codex"].(map[string]any)["bin"] = filepath.Join(t.TempDir(), "missing-codex")
	document["projects"] = []config.ProjectConfig{{ID: "module-test", Name: "Module test", Path: t.TempDir()}}
	if runtime.GOOS == "windows" {
		appServer := config.DefaultManagedAppServerConfig()

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
		appServer.WSTokenFile = token.Name()
		document["app_server"] = appServer
	}
	raw, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, path, raw)
	return path
}
func moduleConfig(t *testing.T, path string) config.Config {
	t.Helper()
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}
func assertModuleUnknowns(t *testing.T, path string) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err = json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if doc["auth"].(map[string]any)["token"] != "module-test-only" || doc["network"].(map[string]any)["future"] != float64(17) || doc["codex"].(map[string]any)["future"] == nil || doc["future_root"] == nil {
		t.Fatal("unrelated data lost")
	}
	// Windows protects private files with ACLs, not POSIX permission bits.
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0600 {
			t.Fatal("configuration permissions changed")
		}
	}
}

func TestNetworkModulesFreezeLegacyIntentAndRestoreExactPreference(t *testing.T) {
	path := moduleTestConfig(t)
	result, err := ConfigureNetworkAccess(path, "lan", true)
	if err != nil {
		t.Fatal(err)
	}
	cfg := moduleConfig(t, path)
	if !result.Changed || !result.RestartRequired || !cfg.LANAccessEnabled() || !cfg.TailscaleAccessEnabled() {
		t.Fatalf("unexpected enabled state %+v", result)
	}
	if cfg.Listen != "100.64.0.2:8787" {
		t.Fatal("listen changed")
	}
	// Disjoint configuration updates survive rollback.
	raw, _ := os.ReadFile(path)
	var doc map[string]any
	_ = json.Unmarshal(raw, &doc)
	doc["new_unrelated_field"] = "keep"
	raw, _ = json.Marshal(doc)
	_ = os.WriteFile(path, raw, 0600)
	restored, err := RestoreNetworkAccess(path, result)
	if err != nil {
		t.Fatal(err)
	}
	cfg = moduleConfig(t, path)
	if cfg.Network.AllowTailscale != nil || cfg.Network.AllowLAN || restored.LANEnabled || !restored.TailscaleEnabled {
		t.Fatal("legacy preference not restored")
	}
	raw, _ = os.ReadFile(path)
	_ = json.Unmarshal(raw, &doc)
	if doc["new_unrelated_field"] != "keep" {
		t.Fatal("rollback overwrote disjoint edit")
	}
	assertModuleUnknowns(t, path)
}

func TestNetworkModulesCannotRollbackOverNewerChoice(t *testing.T) {
	path := moduleTestConfig(t)
	result, err := ConfigureNetworkAccess(path, "lan", true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = ConfigureNetworkAccess(path, "tailscale", false); err != nil {
		t.Fatal(err)
	}
	if _, err = RestoreNetworkAccess(path, result); err == nil {
		t.Fatal("rollback overwrote newer network state")
	}
	cfg := moduleConfig(t, path)
	if !cfg.LANAccessEnabled() || cfg.TailscaleAccessEnabled() {
		t.Fatal("independent choice lost")
	}
	again, err := ConfigureNetworkAccess(path, "lan", true)
	if err != nil || again.Changed {
		t.Fatalf("no-op is not idempotent: %+v %v", again, err)
	}
}

func TestCodexDisableWithoutBinaryPreservesOtherModulesAndAutoDoesNotReenable(t *testing.T) {
	path := moduleTestConfig(t)
	result, err := ConfigureCodex(context.Background(), path, "disabled")
	if err != nil {
		t.Fatal(err)
	}
	cfg := moduleConfig(t, path)
	if cfg.Codex.IsEnabled() || !result.Changed || !result.RestartRequired || !cfg.TailscaleAccessEnabled() {
		t.Fatal("incorrect disabled state")
	}
	again, err := ConfigureCodex(context.Background(), path, "auto")
	if err != nil || again.Enabled || again.Changed {
		t.Fatalf("auto lost user intent: %+v %v", again, err)
	}
	enabled, err := ConfigureCodex(context.Background(), path, "enabled")
	if err != nil {
		t.Fatal(err)
	}
	if enabled.Enabled || enabled.Available || enabled.Changed {
		t.Fatalf("missing executable enabled: %+v", enabled)
	}
	restored, err := RestoreCodex(path, result)
	if err != nil {
		t.Fatal(err)
	}
	if !restored.Enabled || moduleConfig(t, path).Codex.Enabled != nil {
		t.Fatal("legacy nil was not restored")
	}
	assertModuleUnknowns(t, path)
}

func TestCodexRestoreRejectsNewerPreference(t *testing.T) {
	path := moduleTestConfig(t)
	result, err := ConfigureCodex(context.Background(), path, "disabled")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	var doc map[string]any
	_ = json.Unmarshal(raw, &doc)
	doc["codex"].(map[string]any)["activation"] = "auto"
	raw, _ = json.Marshal(doc)
	_ = os.WriteFile(path, raw, 0600)
	if _, err = RestoreCodex(path, result); err == nil {
		t.Fatal("rollback replaced new activation preference")
	}
}

func TestModulePairingHonorsDisabledRoutesAndAllDisabledAgents(t *testing.T) {
	off, on := false, true
	cfg := config.Config{Listen: "100.64.0.2:8787", Auth: config.AuthConfig{Token: "module-test-only"}, Network: config.NetworkConfig{AllowLAN: true, AllowTailscale: &off}}
	lookups := pairingNetworkLookups{tailscaleIP: func(context.Context) string { t.Fatal("disabled TS was probed"); return "" }, lanIP: func() string { return "192.168.50.2" }}
	endpoint, _, err := pairingEndpoint(context.Background(), cfg, PairingNetworkAuto, lookups)
	if err != nil || endpoint != "http://192.168.50.2:8787" {
		t.Fatalf("auto=%q %v", endpoint, err)
	}
	if _, _, err = pairingEndpoint(context.Background(), cfg, PairingNetworkTailscale, lookups); err == nil {
		t.Fatal("disabled TS accepted")
	}
	cfg.Network.AllowLAN = false
	if _, _, err = pairingEndpoint(context.Background(), cfg, PairingNetworkAuto, lookups); err == nil {
		t.Fatal("all off produced endpoint")
	}
	cfg.Codex.Enabled = &off
	cfg.Network.AllowTailscale = &on
	if _, err = resultFromConfigForNetwork(context.Background(), "config.json", cfg, PairingNetworkAuto, lookups); err == nil {
		t.Fatal("all agents off produced ticket")
	}
	status := ResultFromConfig(context.Background(), "config.json", cfg)
	if status.Token != cfg.Auth.Token || status.PairURL != "" || status.Endpoint != "http://127.0.0.1:8787" {
		t.Fatalf("status metadata lost with all off: %+v", status)
	}
}

func TestModuleFixtureIgnoresInheritedRuntimeBinaries(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex")
	script := "#!/bin/sh\nprintf 'called' > \"$0.called\"\ncase \"$1\" in\n--version) echo 'codex-cli 0.155.0';;\n*) echo '--listen --ws-auth --ws-token-file';;\nesac\n"
	if runtime.GOOS == "windows" {
		bin += ".cmd"
		script = "@echo off\r\necho called > \"%~f0.called\"\r\nif \"%~1\"==\"--version\" (echo codex-cli 0.155.0) else (echo --listen --ws-auth --ws-token-file)\r\n"
	}
	if err := os.WriteFile(bin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	// Run the existing missing-binary case in a fresh test process so its
	// TestMain receives a valid, executable inherited override.
	cmd := exec.Command(os.Args[0], "-test.run=^TestCodexDisableWithoutBinaryPreservesOtherModulesAndAutoDoesNotReenable$")
	cmd.Env = append(os.Environ(), "AGENTD_CODEX_BIN="+bin, "CLAUDE_BRIDGE_CLAUDE_BIN="+bin, "AGY_ADAPTER_AGY_BIN="+bin)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("inherited overrides changed module fixture: %s (%v)", out, err)
	}
	if _, err := os.Stat(bin + ".called"); !os.IsNotExist(err) {
		t.Fatalf("module fixture reached inherited executable: %v", err)
	}
}

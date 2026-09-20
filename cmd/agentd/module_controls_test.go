package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestModuleListenersAllOffRemainLocalAndDisabledCodexDoesNotStart(t *testing.T) {
	off, on := false, true
	cfg := config.Config{Listen: "100.64.0.2:8787", Network: config.NetworkConfig{AllowTailscale: &off}, Codex: config.CodexConfig{Enabled: &off, Bin: "/missing/module-test-codex"}}
	if got := moduleListenAddresses(cfg); !reflect.DeepEqual(got, []string{"127.0.0.1:8787"}) {
		t.Fatalf("off listeners %v", got)
	}
	cfg.Network.AllowTailscale = &on
	if got := moduleListenAddresses(cfg); !reflect.DeepEqual(got, []string{"0.0.0.0:8787"}) {
		t.Fatalf("gated listeners %v", got)
	}
	resident, err := prepareAgentAppServerRuntime(cfg)
	if err != nil || resident.routerOptions.AppServerSSH != nil || resident.managedWS != nil {
		t.Fatalf("disabled Codex started: %+v %v", resident, err)
	}
}

func TestModuleCLIRejectsAmbiguousMutations(t *testing.T) {
	if err := runRuntimeWithWriters([]string{"runtime", "--codex=disabled", "--claude=disabled"}, io.Discard, io.Discard); err == nil {
		t.Fatal("ambiguous runtime accepted")
	}
	if err := runNetworkWithWriters([]string{"network", "--lan-enabled=true", "--tailscale-enabled=false"}, io.Discard, io.Discard); err == nil {
		t.Fatal("ambiguous network accepted")
	}
}

func TestDisabledCodexStartupSkipsMigrationAndBinaryRepair(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"listen":"127.0.0.1:8787","auth":{"token":"module-test-only"},"codex":{"enabled":false,"bin":"/missing/module-test-codex"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := ensureCodexCLIAvailable(path); err != nil {
		t.Fatal(err)
	}
	if err := ensureAppServerTransportMigration(context.Background(), path, ""); err != nil {
		t.Fatal(err)
	}
}

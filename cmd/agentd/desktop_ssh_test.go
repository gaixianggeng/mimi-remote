package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestDesktopSSHDisabledDoesNotCreateListener(t *testing.T) {
	path := filepath.Join(t.TempDir(), "unused", "config.json")
	server, err := startDesktopSSHBridge(config.Config{}, path)
	if err != nil || server != nil {
		t.Fatalf("disabled bridge: %v %v", server, err)
	}
	if _, err := os.Stat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatal("disabled bridge changed filesystem")
	}
}

func TestDesktopSSHRejectsRemoteTransport(t *testing.T) {
	cfg := config.Config{DesktopSSH: config.DesktopSSHConfig{Enabled: true}, AppServer: config.AppServerConfig{Transport: "ssh"}}
	if server, err := startDesktopSSHBridge(cfg, filepath.Join(t.TempDir(), "config.json")); err == nil || server != nil {
		t.Fatal("accepted remote transport")
	}
}

func TestSSHBridgeRequiresForcedSSHCommand(t *testing.T) {
	t.Setenv("SSH_ORIGINAL_COMMAND", "")
	t.Setenv("SSH_CONNECTION", "")
	if err := runSSHBridge([]string{"ssh-bridge"}); err == nil {
		t.Fatal("accepted ordinary local invocation")
	}
	t.Setenv("SSH_ORIGINAL_COMMAND", "true")
	if err := runSSHBridge([]string{"ssh-bridge"}); err == nil {
		t.Fatal("accepted missing SSH connection")
	}
}

func TestDesktopSSHSettingRoundTripsWithoutEnablingByDefault(t *testing.T) {
	var cfg config.Config
	if err := json.Unmarshal([]byte(`{"app_server":{"transport":"local"}}`), &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.DesktopSSH.Enabled {
		t.Fatal("enabled by default")
	}
	cfg.DesktopSSH.Enabled = true
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var restored config.Config
	if err := json.Unmarshal(raw, &restored); err != nil || !restored.DesktopSSH.Enabled {
		t.Fatalf("setting lost: %v", err)
	}
}

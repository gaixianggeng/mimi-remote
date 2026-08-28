package setup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestRepairAndRotateRemoteGatewayTokenFile(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	raw := []byte(`{
  "auth": {"token": "keep-agent-token"},
  "future": {"keep": true},
  "app_server": {
    "transport": "ws",
    "managed": true,
    "listen": "ws://127.0.0.1:4222",
    "ws_token_file": "/tmp/upstream-token",
    "remote_gateway": {"enabled": true, "listen": "127.0.0.1:8788", "future": "keep"}
  }
}`)
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	tokenPath, repaired, err := RepairRemoteGatewayTokenFile(configPath)
	if err != nil || !repaired || tokenPath == "" {
		t.Fatalf("repair failed: path=%q repaired=%t err=%v", tokenPath, repaired, err)
	}
	info, err := os.Lstat(tokenPath)
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("token file invalid: %v", err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("token mode=%04o", info.Mode().Perm())
	}
	before, err := os.ReadFile(tokenPath)
	if err != nil {
		t.Fatal(err)
	}
	rotatedPath, err := RotateRemoteGatewayTokenFile(configPath)
	if err != nil || rotatedPath != tokenPath {
		t.Fatalf("rotate failed: path=%q err=%v", rotatedPath, err)
	}
	after, err := os.ReadFile(tokenPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) == string(after) {
		t.Fatal("rotation must replace token")
	}
	updated, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if json.Unmarshal(updated, &document) != nil || document["future"] == nil {
		t.Fatal("repair must preserve unknown top-level fields")
	}
	appServer := document["app_server"].(map[string]any)
	remote := appServer["remote_gateway"].(map[string]any)
	if remote["future"] != "keep" || remote["token_file"] != tokenPath {
		t.Fatalf("remote config not preserved: %+v", remote)
	}
}

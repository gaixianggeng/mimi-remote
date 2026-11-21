package agybridge

import (
	"strings"
	"testing"
)

func TestBuildEnvStripsAntigravityDesktopVariables(t *testing.T) {
	t.Setenv("ANTIGRAVITY_APP_DATA_DIR", "antigravity")
	t.Setenv("__CFBundleIdentifier", "com.google.antigravity")

	env := BuildEnv(map[string]string{
		AgyBinaryEnvKey:          "/usr/local/bin/agy",
		"ANTIGRAVITY_CSRF_TOKEN": "should-not-leak",
	})
	foundBin := false
	for _, entry := range env {
		if strings.HasPrefix(entry, "ANTIGRAVITY_") || strings.HasPrefix(entry, "__CFBundleIdentifier=") {
			t.Fatalf("unexpected desktop leak in env: %s", entry)
		}
		if entry == AgyBinaryEnvKey+"=/usr/local/bin/agy" {
			foundBin = true
		}
	}
	if !foundBin {
		t.Fatalf("expected %s in built env", AgyBinaryEnvKey)
	}
}

func TestParseAdapterCapabilitiesAndVersionGate(t *testing.T) {
	caps, err := ParseAdapterCapabilities([]byte(`{
		"name":"mimi-agy-adapter",
		"version":"0.1.0",
		"methods":["initialize","thread/list","turn/start","slashCommand/list"],
		"fullAccess":true,
		"agy":{"minimumVersion":"1.5.0"}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if !caps.FullAccess || !caps.Supports("slashCommand/list") {
		t.Fatalf("unexpected capabilities: %+v", caps)
	}
	if !caps.AgySupported("1.5.10") || caps.AgySupported("1.4.9") {
		t.Fatalf("version comparison mismatch")
	}
}

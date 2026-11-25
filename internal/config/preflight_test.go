package config

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestPreflightConfigReadsPersistedIdentityWithoutScanning(t *testing.T) {
	t.Setenv("AGENTD_TOKEN", "synthetic-environment-token")
	path := filepath.Join(t.TempDir(), "config.json")
	cases := []struct {
		name, body, code string
		confirmed        bool
	}{
		{"bad", "{", "config_invalid", false},
		{"identity", "{}", "config_recovery_required", false},
		{"newer", `{"auth":{"token":"synthetic-test-value"},"app_server":{"transport":"future"}}`, "config_requires_newer_version", false},
		{"null confirmation", `{"auth":{"token":"synthetic-test-value"},"onboarding":{"workspace_confirmed":null}}`, "config_invalid", false},
		{"pending", `{"auth":{"token":"synthetic-test-value"},"onboarding":{"workspace_confirmed":false}}`, "", false},
		{"legacy", `{"auth":{"token":"synthetic-test-value"},"scan_roots":["missing-root"]}`, "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(tc.body), 0600); err != nil {
				t.Fatal(err)
			}
			got := ReadPreflightSnapshot(path)
			if !got.Configured || got.Code != tc.code || got.Confirmed != tc.confirmed {
				t.Fatalf("configured %v, confirmed %v, diagnostic %q", got.Configured, got.Confirmed, got.Code)
			}
			if got.Code == "" && got.Config.Auth.Token != "synthetic-test-value" {
				t.Fatal("inherited environment replaced committed identity")
			}
		})
	}
	if runtime.GOOS != "windows" {
		alias := path + ".link"
		if err := os.Symlink(path, alias); err != nil {
			t.Fatal(err)
		}
		if got := ReadPreflightSnapshot(alias); got.Code != "config_invalid" || !got.Configured {
			t.Fatal("followed config symlink")
		}
		if err := os.Chmod(path, 0644); err != nil {
			t.Fatal(err)
		}
		if got := ReadPreflightSnapshot(path); got.Code != "config_recovery_required" {
			t.Fatal("unsafe config accepted")
		}
	}
}

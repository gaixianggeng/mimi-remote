package config

import (
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
)

func TestPreflightConfigReadsPersistedIdentityWithoutScanning(t *testing.T) {
	t.Setenv("AGENTD_TOKEN", "synthetic-environment-token")
	path := filepath.Join(t.TempDir(), "config.json")
	configtest.CreatePrivateFile(t, path, nil)
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
		dir := filepath.Dir(path)
		if err := os.Chmod(dir, 0500); err != nil {
			t.Fatal(err)
		}
		got := ReadPreflightSnapshot(path)
		if err := os.Chmod(dir, 0700); err != nil {
			t.Fatal(err)
		}
		if !got.Confirmed || got.Code != "config_dir_unwritable" {
			t.Fatal("a read-only directory lost the committed confirmation")
		}
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
		if got := ReadPreflightSnapshot(path); got.Code != "config_permissions_unsafe" {
			t.Fatal("unsafe config accepted")
		}
	}
}

func TestPreflightSnapshotPreservesWindowsRoots(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	// These are persisted strings. Reading a snapshot must work independently
	// of the host's path rules or whether the drive and share are mounted.
	configtest.CreatePrivateFile(t, path, []byte(`{
		"auth": {"token": "synthetic-test-value"},
		"scan_roots": ["D:\\work space\\src"],
		"browse_roots": ["\\\\fixture.invalid\\share\\code"]
	}`))
	got := ReadPreflightSnapshot(path)
	if got.Code != "" || !got.Configured || !got.Confirmed {
		t.Fatalf("configured %v, confirmed %v, diagnostic %q", got.Configured, got.Confirmed, got.Code)
	}
	if !slices.Equal(got.Config.ScanRoots, []string{`D:\work space\src`}) ||
		!slices.Equal(got.Config.BrowseRoots, []string{`\\fixture.invalid\share\code`}) {
		t.Fatalf("decoded scan roots %q, browse roots %q", got.Config.ScanRoots, got.Config.BrowseRoots)
	}
}

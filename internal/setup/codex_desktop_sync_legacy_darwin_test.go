//go:build darwin

package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestCleanupDesktopSyncLegacyArtifactsRestoresOwnedEnvironmentAndFixedFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("legacy"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	oldRunner := runDesktopSyncLegacyCommand
	var environmentWrites []string
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		joined := name + " " + strings.Join(args, " ")
		switch {
		case strings.Contains(joined, "lsappinfo find"):
			return nil, nil
		case strings.Contains(joined, "defaults read"):
			key := args[len(args)-1]
			values := map[string]string{
				"MimiRemoteMac.codexDesktop.previousValue":       "previous-daemon",
				"MimiRemoteMac.codexDesktop.writtenValue":        "mimi-daemon",
				"MimiRemoteMac.codexDesktop.ownsEnvironment":     "true",
				"MimiRemoteMac.codexDesktop.previousCodexHome":   "",
				"MimiRemoteMac.codexDesktop.writtenCodexHome":    "/tmp/mimi-codex",
				"MimiRemoteMac.codexDesktop.ownsCodexHome":       "true",
				"MimiRemoteMac.codexDesktop.writtenSessionEpoch": "epoch-1",
				"MimiRemoteMac.codexDesktop.ownsSessionEpoch":    "true",
			}
			if value := values[key]; value != "" {
				return []byte(value), nil
			}
			return nil, errors.New("missing")
		case strings.Contains(joined, "launchctl getenv "+legacyDaemonEnvKey):
			return []byte("mimi-daemon"), nil
		case strings.Contains(joined, "launchctl getenv "+legacyCodexHomeEnvKey):
			return []byte("/tmp/mimi-codex"), nil
		case strings.Contains(joined, "launchctl getenv "+legacyEpochEnvKey):
			return []byte("epoch-1"), nil
		case strings.Contains(joined, "launchctl setenv") || strings.Contains(joined, "launchctl unsetenv"):
			environmentWrites = append(environmentWrites, strings.Join(args, " "))
			return nil, nil
		default:
			return nil, nil
		}
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("legacy fixed file still exists: %s err=%v", path, err)
		}
	}
	want := []string{
		"setenv " + legacyDaemonEnvKey + " previous-daemon",
		"unsetenv " + legacyCodexHomeEnvKey,
		"unsetenv " + legacyEpochEnvKey,
	}
	if !reflect.DeepEqual(environmentWrites, want) {
		t.Fatalf("ownership-matched environment restore mismatch:\n got=%v\nwant=%v", environmentWrites, want)
	}
}

func TestRestoreOwnedLegacyDesktopEnvironmentIgnoresMismatchedEpoch(t *testing.T) {
	oldRunner := runDesktopSyncLegacyCommand
	var writes int
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		joined := name + " " + strings.Join(args, " ")
		if strings.Contains(joined, "launchctl getenv "+legacyEpochEnvKey) {
			return []byte("new-owner"), nil
		}
		if strings.Contains(joined, "launchctl setenv") || strings.Contains(joined, "launchctl unsetenv") {
			writes++
		}
		return []byte("mimi-value"), nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	ledger := legacyDesktopLedger{
		previousDaemon: "previous", writtenDaemon: "mimi-value", ownsDaemon: true,
		previousHome: "/previous", writtenHome: "mimi-value", ownsHome: true,
		writtenEpoch: "old-owner", ownsEpoch: true,
	}
	if err := restoreOwnedLegacyDesktopEnvironment(context.Background(), ledger); err != nil {
		t.Fatal(err)
	}
	if writes != 0 {
		t.Fatalf("mismatched ownership epoch must not change launchctl environment: writes=%d", writes)
	}
}

func TestCleanupDesktopSyncLegacyArtifactsRequiresDesktopExit(t *testing.T) {
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if strings.Contains(name+" "+strings.Join(args, " "), "lsappinfo find") {
			return []byte("ASN:0x1"), nil
		}
		return nil, nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	err := cleanupDesktopSyncLegacyArtifacts(context.Background())
	if err == nil || !strings.Contains(err.Error(), "仍在运行") {
		t.Fatalf("running Desktop must block cleanup: %v", err)
	}
}

package config

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestMain keeps package tests away from the signed-in user's real config.
// On Windows os.UserConfigDir ignores HOME and uses APPDATA, so tests that only
// redirected HOME could overwrite %APPDATA%\mimi-remote\config.json.
func TestMain(m *testing.M) {
	root, err := os.MkdirTemp("", "mimi-remote-config-tests-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "create isolated config test home:", err)
		os.Exit(1)
	}

	for key, value := range map[string]string{
		"HOME":            root,
		"USERPROFILE":     root,
		"APPDATA":         filepath.Join(root, "AppData", "Roaming"),
		"LOCALAPPDATA":    filepath.Join(root, "AppData", "Local"),
		"XDG_CONFIG_HOME": filepath.Join(root, ".config"),
		"XDG_CACHE_HOME":  filepath.Join(root, ".cache"),
	} {
		if err := os.Setenv(key, value); err != nil {
			fmt.Fprintf(os.Stderr, "set isolated config test environment %s: %v\n", key, err)
			_ = os.RemoveAll(root)
			os.Exit(1)
		}
	}

	code := m.Run()
	if err := os.RemoveAll(root); err != nil && code == 0 {
		fmt.Fprintln(os.Stderr, "remove isolated config test home:", err)
		code = 1
	}
	os.Exit(code)
}

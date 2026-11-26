package setup

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSetupUsesSharedLocalAppServerWithoutExplicitSSH(t *testing.T) {
	if !config.SupportsSharedLocalAppServer() {
		t.Skip("shared local transport selection only applies to macOS and Linux")
	}
	if setupUsesManagedLocalAppServer("") {
		t.Fatal("macOS 与 Linux 默认不应使用本机受管 WebSocket")
	}
	if !setupUsesSharedLocalAppServer("") {
		t.Fatal("macOS 与 Linux 默认应使用共享本机 App Server")
	}
	if setupUsesSharedLocalAppServer("127.0.0.1") {
		t.Fatal("显式 SSH target 时应保留远端 SSH 模式")
	}
}

func TestRunSavesWithoutStartingLocalAppServer(t *testing.T) {
	if !config.SupportsSharedLocalAppServer() {
		t.Skip("shared local App Server preflight only applies to macOS and Linux")
	}
	clearSetupEnv(t)
	originalPreflight := localAppServerPreflight
	localAppServerPreflight = func(context.Context, string, map[string]string) error {
		t.Fatal("setup attempted to start an optional App Server")
		return nil
	}
	t.Cleanup(func() { localAppServerPreflight = originalPreflight })

	configDir := t.TempDir()
	configPath := filepath.Join(configDir, "config.json")
	_, err := Run(context.Background(), Options{
		ConfigPath: configPath, SaveOnly: true,
		ScanRoot: t.TempDir(),
		Listen:   "127.0.0.1:8787",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(configPath); err != nil {
		t.Fatal(err)
	}
	assertMissingPath(t, filepath.Join(configDir, "app-server-ws-token"))
}

package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSetupUsesSharedLocalAppServerOnLinuxWithoutExplicitSSH(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux-specific transport selection")
	}
	if setupUsesManagedLocalAppServer("") {
		t.Fatal("Linux 默认不应使用本机受管 WebSocket")
	}
	if !setupUsesSharedLocalAppServer("") {
		t.Fatal("Linux 默认应使用共享本机 App Server")
	}
	if setupUsesSharedLocalAppServer("127.0.0.1") {
		t.Fatal("Linux 显式 SSH target 时应保留远端 SSH 模式")
	}
}

func TestRunLeavesLinuxConfigUntouchedWhenLocalAppServerPreflightFails(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux-specific local App Server preflight")
	}
	clearSetupEnv(t)
	originalPreflight := localAppServerPreflight
	preflightErr := errors.New("local initialize rejected")
	localAppServerPreflight = func(context.Context, string, map[string]string) error {
		return preflightErr
	}
	t.Cleanup(func() { localAppServerPreflight = originalPreflight })

	configDir := t.TempDir()
	configPath := filepath.Join(configDir, "config.json")
	_, err := Run(context.Background(), Options{
		ConfigPath: configPath,
		ScanRoot:   t.TempDir(),
		Listen:     "127.0.0.1:8787",
	})
	if err == nil || !errors.Is(err, preflightErr) || !strings.Contains(err.Error(), "Linux 本机 App Server 预检失败") {
		t.Fatalf("应返回本机预检错误，got %v", err)
	}
	for _, path := range []string{configPath, filepath.Join(configDir, "app-server-ws-token")} {
		if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Fatalf("预检失败不应写入 %s：%v", path, statErr)
		}
	}
}

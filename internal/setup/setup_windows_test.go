package setup

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestWindowsSetupSavesConfigWithOldAutomaticCodex(t *testing.T) {
	clearSetupEnv(t)
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex.cmd")
	if err := os.WriteFile(bin, []byte("@echo off\r\necho called > \"%~f0.called\"\r\necho codex-cli 0.149.0\r\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	path := filepath.Join(dir, "config.json")
	result, err := Run(context.Background(), Options{ConfigPath: path, ScanRoot: dir, BrowseRoot: dir, Listen: "127.0.0.1:8787", LocalServiceOnly: true})
	if err != nil || !result.Created {
		t.Fatalf("fresh automatic config was not saved: %v", err)
	}
	cfg, err := config.Load(path)
	if err != nil || cfg.Codex.Bin != "codex" || cfg.AppServer.Transport != "ws" {
		t.Fatalf("saved config: binary=%q, transport=%q, err=%v", cfg.Codex.Bin, cfg.AppServer.Transport, err)
	}
	if _, err := os.Stat(bin + ".called"); !os.IsNotExist(err) {
		t.Fatalf("automatic setup ran the old CLI: %v", err)
	}
}

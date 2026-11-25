package setup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveClaudeBinDoesNotApplyCodexVersionParser(t *testing.T) {
	f := newDiscoveryFixture(t)
	f.GOOS = "windows"
	path := filepath.Join(f.Home, "claude.exe")
	f.add(t, path, "Claude Code version=2.1.100")
	got, err := f.Resolve(context.Background(), RuntimeRequest{Name: "claude", Override: path})
	if err != nil || got.Path != path || got.Version != "2.1.100" {
		t.Fatalf("Claude executable: %+v, %v", got, err)
	}
}

func TestClaudeExecutableCandidatesIncludesOfficialNativeInstall(t *testing.T) {
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	want := filepath.Join(home, ".local", "bin", "claude.exe")
	for _, candidate := range NewRuntimeDiscovery().candidates(RuntimeRequest{Name: "claude"}) {
		if sameCleanPath(candidate, want) {
			return
		}
	}
	t.Fatalf("应检测官方 Windows 原生安装路径 %q", want)
}

func TestClaudeCommandEnvironmentOverridesWindowsKeysCaseInsensitively(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:10808")
	environment := claudeCommandEnvironment(map[string]string{
		"http_proxy": "http://127.0.0.1:18080",
	})
	found := 0
	for _, item := range environment {
		key, value, ok := strings.Cut(item, "=")
		if !ok || !strings.EqualFold(key, "HTTP_PROXY") {
			continue
		}
		found++
		if value != "http://127.0.0.1:18080" {
			t.Fatal("claude.env 应覆盖继承的代理")
		}
	}
	if found != 1 {
		t.Fatalf("Windows 环境不应包含大小写重复的代理键：%d", found)
	}
}

func TestNativeClaudeExecutableCandidateMigratesNPMShim(t *testing.T) {
	npmRoot := filepath.Join(t.TempDir(), "npm")
	shim := filepath.Join(npmRoot, "claude.cmd")
	native := filepath.Join(
		npmRoot,
		"node_modules",
		"@anthropic-ai",
		"claude-code",
		"bin",
		"claude.exe",
	)
	if err := os.MkdirAll(filepath.Dir(native), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(shim, []byte("@echo off\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(native, []byte("native"), 0o700); err != nil {
		t.Fatal(err)
	}

	resolved, err := NewRuntimeDiscovery().nativeClaude(shim)
	if err != nil || !filepath.IsAbs(resolved) || !sameCleanPath(resolved, native) {
		t.Fatalf("npm shim 应迁移到包内原生 claude.exe：resolved=%q err=%v", resolved, err)
	}
	d := NewRuntimeDiscovery()
	d.run = func(context.Context, string, RuntimeRequest, ...string) (string, error) {
		return "2.1.100 (Claude Code)", nil
	}
	selected, err := d.Resolve(context.Background(), RuntimeRequest{Name: "claude", Override: shim})
	if err != nil || !sameCleanPath(selected.Path, native) {
		t.Fatalf("npm shim selection: %+v, %v", selected, err)
	}
	if err := os.Remove(shim); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Resolve(context.Background(), RuntimeRequest{Name: "claude", Override: shim}); err == nil {
		t.Fatal("missing shim was accepted as a pin")
	}

}

func TestNativeClaudeExecutableCandidateRejectsUnmappableScript(t *testing.T) {
	shim := filepath.Join(t.TempDir(), "claude.cmd")
	if err := os.WriteFile(shim, []byte("@echo off\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if resolved, err := NewRuntimeDiscovery().nativeClaude(shim); err == nil {
		t.Fatalf("没有包内原生二进制时不应持久化脚本 shim：%q", resolved)
	}
}

func sameCleanPath(left string, right string) bool {
	return filepath.Clean(left) == filepath.Clean(right)
}

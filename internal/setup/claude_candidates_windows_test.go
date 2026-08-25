package setup

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveClaudeBinDoesNotApplyCodexVersionParser(t *testing.T) {
	// git.exe 提供稳定的非 Codex --version 输出，用来确认 Claude 路径探测只检查
	// 候选程序可启动，不会套用 codex-cli 的版本格式和最低版本限制。
	probe, err := exec.LookPath("git.exe")
	if err != nil {
		t.Skip("当前 Windows 环境没有可用的非 Codex 版本探测程序")
	}
	resolved, err := resolveClaudeBin(probe)
	if err != nil {
		t.Fatalf("Claude 路径探测不应要求 codex-cli 版本输出：%v", err)
	}
	want, err := filepath.Abs(probe)
	if err != nil {
		t.Fatal(err)
	}
	if !sameCleanPath(resolved, want) {
		t.Fatalf("Claude 路径解析异常：got=%q want=%q", resolved, want)
	}
}

func TestClaudeExecutableCandidatesIncludesOfficialNativeInstall(t *testing.T) {
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	want := filepath.Join(home, ".local", "bin", "claude.exe")
	for _, candidate := range claudeExecutableCandidates("") {
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
			t.Fatalf("claude.env 应覆盖继承的代理：%q", item)
		}
	}
	if found != 1 {
		t.Fatalf("Windows 环境不应包含大小写重复的代理键：%v", environment)
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

	resolved, ok := nativeClaudeExecutableCandidate(shim)
	if !ok || !filepath.IsAbs(resolved) || !sameCleanPath(resolved, native) {
		t.Fatalf("npm shim 应迁移到包内原生 claude.exe：resolved=%q ok=%t", resolved, ok)
	}
	candidates := claudeExecutableCandidates(shim)
	if len(candidates) == 0 || !sameCleanPath(candidates[0], native) {
		t.Fatalf("已配置 npm shim 时原生二进制应为首选：%v", candidates)
	}
}

func TestNativeClaudeExecutableCandidateRejectsUnmappableScript(t *testing.T) {
	shim := filepath.Join(t.TempDir(), "claude.cmd")
	if err := os.WriteFile(shim, []byte("@echo off\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if resolved, ok := nativeClaudeExecutableCandidate(shim); ok {
		t.Fatalf("没有包内原生二进制时不应持久化脚本 shim：%q", resolved)
	}
}

func sameCleanPath(left string, right string) bool {
	return filepath.Clean(left) == filepath.Clean(right)
}

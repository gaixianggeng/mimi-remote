package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
)

func TestLoadWithEnvOverrides(t *testing.T) {
	clearAgentdEnv(t)
	t.Setenv("AGENTD_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("AGENTD_PROJECTS", filepath.Join(t.TempDir(), "demo"))
	projectDir := os.Getenv("AGENTD_PROJECTS")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.Token == "" {
		t.Fatal("期望从环境变量读取 token")
	}
	if len(cfg.Projects) != 1 || cfg.Projects[0].ID != "demo" {
		t.Fatalf("项目解析异常：%+v", cfg.Projects)
	}
	if cfg.Voice.CodexTranscriptionBaseURL != "https://chatgpt.com/backend-api" {
		t.Fatalf("默认语音转写必须使用 Codex 登录态后端，实际 %q", cfg.Voice.CodexTranscriptionBaseURL)
	}
	if !cfg.AppServer.AutoTitle {
		t.Fatal("新安装默认应启用 Mac 端会话标题生成")
	}
}

func TestLoadNormalizesLegacyZeroClaudeBridgeLimit(t *testing.T) {
	clearAgentdEnv(t)
	projectDir := t.TempDir()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cfg := defaults()
	cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
	cfg.Claude.Enabled = true
	cfg.Claude.BridgeBin = executable
	cfg.Claude.MaxConcurrentBridges = 0
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: projectDir}}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	loaded, err := Load(path)
	if err != nil {
		t.Fatalf("legacy setup config should remain startable after Claude activation: %v", err)
	}
	if loaded.Claude.MaxConcurrentBridges != DefaultClaudeMaxConcurrentBridges {
		t.Fatalf("legacy zero bridge limit was not normalized: got=%d want=%d", loaded.Claude.MaxConcurrentBridges, DefaultClaudeMaxConcurrentBridges)
	}
}

func TestLoadRejectsExplicitZeroClaudeBridgeLimitFromEnvironment(t *testing.T) {
	clearAgentdEnv(t)
	projectDir := t.TempDir()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cfg := defaults()
	cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
	cfg.Claude.Enabled = true
	cfg.Claude.BridgeBin = executable
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: projectDir}}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTD_CLAUDE_MAX_CONCURRENT_BRIDGES", "0")

	if _, err := Load(path); err == nil {
		t.Fatal("an explicit zero bridge limit from the environment must remain invalid")
	}
}

func TestValidateRejectsEmptyToken(t *testing.T) {
	cfg := defaults()
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	if err := cfg.Validate(); err == nil {
		t.Fatal("期望空 token 被拒绝")
	}
}

func TestCapabilityDisableListAcceptsKnownAndFutureVersionedNames(t *testing.T) {
	cfg := defaults()
	cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	cfg.Capabilities.Disabled = []string{"file_upload_v1", "future_safe_path_v2"}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("本地开关应允许已知能力和未来合法能力名：%v", err)
	}
	if !cfg.Capabilities.IsDisabled("file_upload_v1") ||
		!cfg.Capabilities.IsDisabled("future_safe_path_v2") {
		t.Fatalf("能力禁用列表没有被稳定识别：%+v", cfg.Capabilities.Disabled)
	}
}

func TestCapabilityDisableListRejectsDuplicateOrUnversionedNames(t *testing.T) {
	base := func() Config {
		cfg := defaults()
		cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
		cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
		return cfg
	}

	duplicate := base()
	duplicate.Capabilities.Disabled = []string{"file_upload_v1", "file_upload_v1"}
	if err := duplicate.Validate(); err == nil {
		t.Fatal("重复 capability 必须被拒绝，避免开关语义含糊")
	}

	unversioned := base()
	unversioned.Capabilities.Disabled = []string{"file_upload"}
	if err := unversioned.Validate(); err == nil {
		t.Fatal("没有 _vN 版本后缀的 capability 必须被拒绝")
	}
}

// An installed app ships its own bridge next to agentd, so an empty
// claude.bridge_bin is a complete configuration there — that is what lets a
// fresh install work with no per-machine setup. Without a bundled copy it is
// still a misconfiguration and must be rejected.
func TestValidateAcceptsEmptyBridgeBinOnlyWhenOneShipsAlongside(t *testing.T) {
	newConfig := func() Config {
		cfg := defaults()
		cfg.Auth.Token = "0123456789abcdef0123456789abcdef"
		cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = ""
		cfg.Claude.MaxConcurrentBridges = 3
		return cfg
	}

	sibling := bundledSiblingPathForTest(t)
	if sibling == "" {
		t.Skip("拿不到可执行文件路径")
	}
	if _, err := os.Stat(sibling); err == nil {
		t.Skip("测试二进制旁已存在同名文件，跳过以免干扰")
	}

	cfg := newConfig()
	if err := cfg.Validate(); err == nil {
		t.Fatal("没有随包 bridge 时，空 bridge_bin 仍应被拒绝")
	}

	if err := os.WriteFile(sibling, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Skip("无法在测试二进制旁写入：" + err.Error())
	}
	t.Cleanup(func() { _ = os.Remove(sibling) })

	cfg = newConfig()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("随包 bridge 存在时应接受空 bridge_bin：%v", err)
	}
}

func bundledSiblingPathForTest(t *testing.T) string {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return filepath.Join(filepath.Dir(executable), claudebridge.BinaryName)
}

func TestPlatformDefaultPathIgnoresAgentdConfig(t *testing.T) {
	customPath := filepath.Join(t.TempDir(), "custom-config.json")
	t.Setenv("AGENTD_CONFIG", customPath)

	if got := DefaultPath(); got != customPath {
		t.Fatalf("普通前台命令仍应接受 AGENTD_CONFIG：got=%q want=%q", got, customPath)
	}
	platformDefault := PlatformDefaultPath()
	if platformDefault == customPath {
		t.Fatalf("Homebrew 平台默认路径不能受 AGENTD_CONFIG 影响：%q", platformDefault)
	}
	wantDir, err := UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	if platformDefault != filepath.Join(wantDir, "config.json") {
		t.Fatalf("平台默认配置路径异常：got=%q want=%q", platformDefault, filepath.Join(wantDir, "config.json"))
	}
}

func TestSameConfigPathResolvesEquivalentDirectorySymlink(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	platformDefault := PlatformDefaultPath()
	if err := os.MkdirAll(filepath.Dir(platformDefault), 0o755); err != nil {
		t.Fatal(err)
	}
	aliasRoot := filepath.Join(t.TempDir(), "config-alias")
	if err := os.Symlink(filepath.Dir(platformDefault), aliasRoot); err != nil {
		t.Fatal(err)
	}

	if !SameConfigPath(filepath.Join(aliasRoot, filepath.Base(platformDefault)), platformDefault) {
		t.Fatal("同一配置目录的 symlink 路径应取得同一把提交锁")
	}
	if SameConfigPath(filepath.Join(t.TempDir(), "custom.json"), platformDefault) {
		t.Fatal("不同配置文件不能共享提交锁身份")
	}
}

func TestConfigPathIdentityMatchesVolumeCaseSemantics(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	platformDefault := PlatformDefaultPath()
	if err := os.MkdirAll(filepath.Dir(platformDefault), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(platformDefault, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	caseVariant := filepath.Join(filepath.Dir(platformDefault), "Config.json")
	_, variantErr := os.Stat(caseVariant)
	if variantErr == nil {
		if !SameConfigPath(caseVariant, platformDefault) {
			t.Fatal("大小写不敏感卷上的同一文件必须取得同一把提交锁")
		}
		left, err := ConfigPathIdentity(platformDefault)
		if err != nil {
			t.Fatal(err)
		}
		right, err := ConfigPathIdentity(caseVariant)
		if err != nil {
			t.Fatal(err)
		}
		if left != right {
			t.Fatalf("大小写别名必须取得同一配置锁：left=%q right=%q", left, right)
		}
		return
	}
	if !os.IsNotExist(variantErr) {
		t.Fatal(variantErr)
	}
	if SameConfigPath(caseVariant, platformDefault) {
		t.Fatal("大小写敏感卷上的不同文件不能共享提交锁身份")
	}
}

func TestSameConfigPathRejectsDifferentHardLinkEntry(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	platformDefault := PlatformDefaultPath()
	if err := os.MkdirAll(filepath.Dir(platformDefault), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(platformDefault, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	hardLink := filepath.Join(t.TempDir(), "config-hardlink.json")
	if err := os.Link(platformDefault, hardLink); err != nil {
		t.Fatal(err)
	}
	if SameConfigPath(hardLink, platformDefault) {
		t.Fatal("不同 hard-link 目录项不能共享提交锁身份")
	}
}

package config

import (
	"os"
	"path/filepath"
	"testing"
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
	if cfg.Voice.TranscriptionProvider != "openai" {
		t.Fatalf("默认语音转写必须使用公开 OpenAI API，实际 %q", cfg.Voice.TranscriptionProvider)
	}
}

func TestValidateRejectsEmptyToken(t *testing.T) {
	cfg := defaults()
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	if err := cfg.Validate(); err == nil {
		t.Fatal("期望空 token 被拒绝")
	}
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

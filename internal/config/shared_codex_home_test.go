package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSharedCodexHomeRemainsOptInAndRoundTrips(t *testing.T) {
	cfg := Config{AppServer: DefaultSharedLocalAppServerConfig()}
	raw, err := json.Marshal(cfg)
	if err != nil || strings.Contains(string(raw), "shared_codex_home") {
		t.Fatalf("默认配置不能启用或写入目录隔离：%s %v", raw, err)
	}
	cfg.AppServer.SharedCodexHome = t.TempDir()
	raw, err = json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var restored Config
	if err := json.Unmarshal(raw, &restored); err != nil {
		t.Fatal(err)
	}
	if restored.AppServer.SharedCodexHome != cfg.AppServer.SharedCodexHome {
		t.Fatal("保存配置丢失独立会话目录")
	}
	err = restored.ValidateSharedCodexHome()
	if runtime.GOOS == "darwin" && err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "darwin" && err == nil {
		t.Fatal("非 Mac 前门不能声明隔离已生效")
	}
}

func TestSharedCodexHomeRejectsInvalidPathsAndTransports(t *testing.T) {
	home := t.TempDir()
	file := filepath.Join(home, "file")
	if err := os.WriteFile(file, nil, 0600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"relative", " ", filepath.Join(home, "missing"), file} {
		cfg := Config{AppServer: AppServerConfig{Transport: "local", SharedCodexHome: path}}
		if err := cfg.ValidateSharedCodexHome(); err == nil {
			t.Fatalf("不能接受独立目录 %q", path)
		}
	}
	for _, transport := range []string{"ssh", "ws"} {
		cfg := Config{AppServer: AppServerConfig{Transport: transport, SharedCodexHome: home}}
		if err := cfg.ValidateSharedCodexHome(); err == nil {
			t.Fatalf("%s 不能忽略独立目录配置", transport)
		}
	}
}

func TestEffectiveLocalCodexHomeUsesBackendPriority(t *testing.T) {
	userHome := t.TempDir()
	processHome := t.TempDir()
	configuredHome := t.TempDir()
	sharedHome := t.TempDir()
	t.Setenv("HOME", userHome)
	t.Setenv("USERPROFILE", userHome)
	t.Setenv("CODEX_HOME", processHome)

	cfg := Config{
		AppServer: AppServerConfig{Transport: "local", SharedCodexHome: sharedHome},
		Codex:     CodexConfig{Env: map[string]string{"CODEX_HOME": configuredHome}},
	}
	if got, ok := cfg.EffectiveLocalCodexHome(); !ok || got != sharedHome {
		t.Fatalf("共享后端目录应优先：got=%q ok=%v", got, ok)
	}
	cfg.AppServer.SharedCodexHome = ""
	if got, ok := cfg.EffectiveLocalCodexHome(); !ok || got != configuredHome {
		t.Fatalf("Codex 配置目录应优先进程环境：got=%q ok=%v", got, ok)
	}
	delete(cfg.Codex.Env, "CODEX_HOME")
	if got, ok := cfg.EffectiveLocalCodexHome(); !ok || got != processHome {
		t.Fatalf("应回退进程 CODEX_HOME：got=%q ok=%v", got, ok)
	}
	t.Setenv("CODEX_HOME", "")
	if got, ok := cfg.EffectiveLocalCodexHome(); !ok || got != filepath.Join(userHome, ".codex") {
		t.Fatalf("应回退用户默认目录：got=%q ok=%v", got, ok)
	}
}

func TestEffectiveLocalCodexHomeDoesNotResolveSSHBackend(t *testing.T) {
	cfg := Config{
		AppServer: AppServerConfig{Transport: "ssh", SharedCodexHome: t.TempDir()},
		Codex:     CodexConfig{Env: map[string]string{"CODEX_HOME": t.TempDir()}},
	}
	if got, ok := cfg.EffectiveLocalCodexHome(); ok || got != "" {
		t.Fatalf("SSH backend home 应留给远端解析：got=%q ok=%v", got, ok)
	}
}

func TestEffectiveLocalCodexHomePreservesSharedDirectoryCharacters(t *testing.T) {
	sharedHome := filepath.Join(t.TempDir(), `backend 'quoted' `)
	if err := os.Mkdir(sharedHome, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := Config{AppServer: AppServerConfig{Transport: "local", SharedCodexHome: sharedHome}}
	if got, ok := cfg.EffectiveLocalCodexHome(); !ok || got != sharedHome {
		t.Fatalf("共享目录中的空格和引号必须原样保留：got=%q want=%q ok=%v", got, sharedHome, ok)
	}
}

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

//go:build darwin

package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

func frontHomeFixture(t *testing.T) (string, string, *appserver.FrontDoor) {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "front-home-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	public, private := filepath.Join(root, "public"), filepath.Join(root, "private")
	for _, home := range []string{public, private} {
		if err := os.Mkdir(home, 0700); err != nil {
			t.Fatal(err)
		}
	}
	door, err := appserver.NewFrontDoor(appserver.SharedLocalOptions{
		Env: map[string]string{"CODEX_HOME": public}, BackendCodexHome: private,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	return public, private, door
}

func TestFrontDoorRejectsUninstalledOrChangedBackendHome(t *testing.T) {
	public, private, door := frontHomeFixture(t)
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", door.PublicSocketPath())
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	configPath := filepath.Join(t.TempDir(), "config.json")
	raw, _ := json.Marshal(map[string]any{
		"codex":      map[string]any{"env": map[string]string{"CODEX_HOME": public}},
		"app_server": map[string]any{"transport": "local", "shared_codex_home": private},
	})
	if err := os.WriteFile(configPath, raw, 0600); err != nil {
		t.Fatal(err)
	}
	for _, pinned := range []string{"", public} {
		t.Setenv(codexFrontBackendHomeKey, pinned)
		if _, err := loadCodexFrontDoor(configPath, listener, nil); err == nil {
			t.Fatal("旧前门不能因为配置改动而静默切到新历史")
		}
	}
	t.Setenv(codexFrontBackendHomeKey, door.BackendCodexHome())
	actual, err := loadCodexFrontDoor(configPath, listener, nil)
	if err != nil || actual.BackendCodexHome() != door.BackendCodexHome() {
		t.Fatalf("已登记独立目录应保持同一公共入口：%v", err)
	}
}

func TestRegisteredFrontHomeBlocksColdSwitchInBothDirections(t *testing.T) {
	_, _, door := frontHomeFixture(t)
	publicHome := filepath.Dir(filepath.Dir(door.PublicSocketPath()))
	path := filepath.Join(t.TempDir(), "front.plist")
	for _, pinned := range []string{"", publicHome, door.BackendCodexHome()} {
		plist := renderCodexFrontPlist("test.front", []string{"agentd"}, door.PublicSocketPath(), "test", pinned)
		if err := os.WriteFile(path, plist, 0600); err != nil {
			t.Fatal(err)
		}
		want := pinned
		if want == "" {
			want = publicHome
		}
		if got, err := codexFrontPlistBackendHome(path); err != nil || got != want {
			t.Fatalf("旧版与新版安装身份解析错误：%q %v", got, err)
		}
		if err := validateCodexFrontRegisteredHome(path, want); err != nil {
			t.Fatal(err)
		}
		other := door.BackendCodexHome()
		if want == other {
			other = publicHome
		}
		if err := validateCodexFrontRegisteredHome(path, other); err == nil || !strings.Contains(err.Error(), "--stop-idle-backend") {
			t.Fatalf("改变后端目录必须要求显式冷卸载，不能跳过旧后端检查：%v", err)
		}
	}
}

func TestIsolationRejectsLegacyBackendLeftAfterUninstall(t *testing.T) {
	_, _, door := frontHomeFixture(t)
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0700); err != nil {
		t.Fatal(err)
	}
	legacy := filepath.Join(filepath.Dir(door.PublicSocketPath()), "app-server-backend.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: legacy, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	install := codexFrontInstallation{Socket: door.PublicSocketPath(), BackendHome: door.BackendCodexHome()}
	if err := rejectLegacyBackendForIsolation(install); err == nil {
		t.Fatal("旧后端仍在运行，不能启用隔离")
	}
	conn, err := net.Dial("unix", legacy)
	if err != nil {
		t.Fatalf("拒绝切换不能停止旧后端：%v", err)
	}
	_ = conn.Close()
	listener.SetUnlinkOnClose(false)
	_ = listener.Close()
	if err := rejectLegacyBackendForIsolation(install); err != nil {
		t.Fatalf("已退出后端的残留 socket 不阻止隔离：%v", err)
	}
}

func TestFrontInstallationKeepsOriginalBackendWhenConfigChanges(t *testing.T) {
	public, private, door := frontHomeFixture(t)
	configPath := filepath.Join(t.TempDir(), "config.json")
	writeConfig := func(home string) {
		body, _ := json.Marshal(map[string]any{
			"codex":      map[string]any{"env": map[string]string{"CODEX_HOME": public}},
			"app_server": map[string]any{"transport": "local", "shared_codex_home": home},
		})
		if err := os.WriteFile(configPath, body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeConfig(private)
	install, err := resolveCodexFrontInstallation(configPath, "test.front", filepath.Join(t.TempDir(), "front.plist"))
	if err != nil {
		t.Fatal(err)
	}
	writeConfig("")
	if install.door.BackendCodexHome() != door.BackendCodexHome() || install.door.BackendSocketPath() != door.BackendSocketPath() {
		t.Fatal("配置变化不能改变已核对身份的卸载目标")
	}
	plist := renderCodexFrontPlist("test.front", []string{"agentd"}, install.Socket, "test", install.BackendHome)
	if err := os.WriteFile(install.PlistPath, plist, 0600); err != nil {
		t.Fatal(err)
	}
	registered, err := registeredCodexFrontDoor(install.PlistPath)
	if err != nil || registered.BackendCodexHome() != door.BackendCodexHome() {
		t.Fatalf("状态应读取旧登记目录，不应把新配置当作正在运行的后端：%v", err)
	}
	var output bytes.Buffer
	if err := runCodexFrontStatus([]string{"status", "--config", configPath, "--label", "test.mimi.front.unregistered", "--plist", install.PlistPath}, &output); err != nil {
		t.Fatal(err)
	}
	var status codexFrontStatus
	if err := json.Unmarshal(output.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.Loaded || status.IsolatedHistory || status.ConfigurationError == "" || status.BackendCodexHome != door.BackendCodexHome() {
		t.Fatalf("未加载的旧登记也必须报告配置漂移，不能误报隔离运行成功：%+v", status)
	}
}

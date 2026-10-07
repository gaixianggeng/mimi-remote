//go:build darwin

package main

import (
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestLoadCodexFrontDoorRejectsBrokenConfigAndSocketMismatch(t *testing.T) {
	newHome := func() string {
		home, err := os.MkdirTemp("/tmp", "mimi-front-")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.RemoveAll(home) })
		return home
	}
	aHome, bHome := newHome(), newHome()
	aSocket, err := appserver.SharedLocalSocketPath(map[string]string{"CODEX_HOME": aHome})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(aSocket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", aSocket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	configPath := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(configPath, []byte("{invalid"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadCodexFrontDoor(configPath, listener, nil); err == nil {
		t.Fatal("配置损坏时不能回退到默认 CODEX_HOME")
	}
	writeConfig := func(home string) {
		body, err := json.Marshal(map[string]any{"codex": map[string]any{"env": map[string]string{"CODEX_HOME": home}}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(configPath, body, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeConfig(bHome)
	if _, err := loadCodexFrontDoor(configPath, listener, nil); err == nil {
		t.Fatal("A 的 launchd listener 不能转发到 B 的 CODEX_HOME")
	}
	writeConfig(aHome)
	if _, err := loadCodexFrontDoor(configPath, listener, nil); err != nil {
		t.Fatalf("配置和 listener 一致时应启动：%v", err)
	}
}

func TestRenderCodexFrontPlistIsValidLaunchdSocketJob(t *testing.T) {
	socket := "/Users/example/.codex/app-server-control/app-server-control.sock"
	plist := renderCodexFrontPlist("com.example.front", []string{"/Applications/A & B.app/Contents/MacOS/Mimi Remote Mac", codexFrontAppFlag}, socket, "build-a", "/Users/example/.codex")
	path := filepath.Join(t.TempDir(), "front.plist")
	if err := os.WriteFile(path, plist, 0o644); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("/usr/bin/plutil", "-lint", path).CombinedOutput(); err != nil {
		t.Fatalf("plutil 校验失败：%s", output)
	}
	if got, err := codexFrontPlistSocket(path); err != nil || got != socket {
		t.Fatalf("前门 plist socket=%q err=%v", got, err)
	}
	text := string(plist)
	for _, want := range []string{
		"<string>" + socket + "</string>",
		"<integer>384</integer>",
		"<key>inetdCompatibility</key>",
		"<key>Wait</key>\n\t\t<true/>",
		"<string>Aqua</string>",
		"A &amp; B.app",
		"MIMI_CODEX_FRONT_REVISION",
		"build-a",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("plist 缺少 %q：\n%s", want, text)
		}
	}
}

func TestCodexFrontExecutableRevisionChangesWithBinary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd")
	if err := os.WriteFile(path, []byte("first"), 0o755); err != nil {
		t.Fatal(err)
	}
	first, err := codexFrontExecutableRevision(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("second"), 0o755); err != nil {
		t.Fatal(err)
	}
	second, err := codexFrontExecutableRevision(path)
	if err != nil || first == second {
		t.Fatalf("同路径覆盖升级必须改变前门修订号：first=%s second=%s err=%v", first, second, err)
	}
}

func TestCodexFrontProgramArgumentsPrefersAppMainExecutable(t *testing.T) {
	app := filepath.Join(t.TempDir(), "Mimi Remote Mac.app")
	agentd := filepath.Join(app, "Contents", "Resources", "agentd")
	main := filepath.Join(app, "Contents", "MacOS", "Mimi Remote Mac")
	for _, path := range []string{agentd, main} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, nil, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	got, err := codexFrontProgramArguments(agentd, false, config.DefaultPath(), "")
	if err != nil || !reflect.DeepEqual(got, []string{main, codexFrontAppFlag}) {
		t.Fatalf("默认配置应只传固定参数：%v %v", got, err)
	}
	custom := filepath.Join(t.TempDir(), "agentd.json")
	got, err = codexFrontProgramArguments(agentd, false, custom, "")
	if err != nil || !reflect.DeepEqual(got, []string{main, codexFrontAppFlag, "--config", custom}) {
		t.Fatalf("自定义配置应透传绝对路径：%v %v", got, err)
	}
	got, err = codexFrontProgramArguments(agentd, true, custom, "/tmp/front.log")
	want := []string{agentd, "codex-front", "serve", "--config", custom, "--log-file", "/tmp/front.log"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("--direct 应直接启动 agentd：%v %v", got, err)
	}
}

func TestCodexFrontProgramArgumentsRequiresDirectOutsideApp(t *testing.T) {
	agentd := filepath.Join(t.TempDir(), "bin", "agentd")
	if _, err := codexFrontProgramArguments(agentd, false, config.DefaultPath(), ""); err == nil {
		t.Fatal("开发环境没有 App 主程序时必须显式使用 --direct，避免后端丢失 App 的隐私授权")
	}
}

func TestInstalledMacAppAgentdDetectionExcludesStagedBundles(t *testing.T) {
	home := t.TempDir()
	relative := filepath.Join("Mimi Remote Mac.app", "Contents", "Resources", "agentd")
	for _, path := range []string{
		filepath.Join("/Applications", relative),
		filepath.Join(home, "Applications", relative),
	} {
		if !isInstalledMacAppAgentd(path, home) {
			t.Fatalf("已安装 App 的 agentd 未识别：%s", path)
		}
	}
	if isInstalledMacAppAgentd(filepath.Join(home, "scratch", relative), home) {
		t.Fatal("暂存构建不能自动登记为用户登录项")
	}
}

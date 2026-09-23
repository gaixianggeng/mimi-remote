//go:build darwin

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestRenderCodexFrontPlistIsValidLaunchdSocketJob(t *testing.T) {
	socket := "/Users/example/.codex/app-server-control/app-server-control.sock"
	plist := renderCodexFrontPlist("com.example.front", []string{"/Applications/A & B.app/Contents/MacOS/Mimi Remote Mac", codexFrontAppFlag}, socket)
	path := filepath.Join(t.TempDir(), "front.plist")
	if err := os.WriteFile(path, plist, 0o644); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("/usr/bin/plutil", "-lint", path).CombinedOutput(); err != nil {
		t.Fatalf("plutil 校验失败：%s", output)
	}
	text := string(plist)
	for _, want := range []string{
		"<string>" + socket + "</string>",
		"<integer>384</integer>",
		"<key>inetdCompatibility</key>",
		"<key>Wait</key>\n\t\t<true/>",
		"<string>Aqua</string>",
		"A &amp; B.app",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("plist 缺少 %q：\n%s", want, text)
		}
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

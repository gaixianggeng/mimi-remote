//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func writeFakeCodexBin(t *testing.T, dir string, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("写入假 codex 失败：%v", err)
	}
	return path
}

// Darwin 的 Unix socket 路径上限很短；owner 测试必须使用短 Home，且显式
// CODEX_HOME 要满足生产代码的“目录已存在”约束。
func sharedDaemonTestHome(t *testing.T) string {
	t.Helper()
	previousResolver := sharedDaemonResolveSupervisorNode
	previousValidator := sharedDaemonValidateSupervisor
	previousRuntimeValidator := sharedDaemonValidateSignedRuntime
	home, err := os.MkdirTemp("/tmp", "mimi-owner-")
	if err != nil {
		t.Fatalf("创建短测试 Home 失败：%v", err)
	}
	// 测试只注入路径解析和签名校验 seam，不依赖真实 ChatGPT.app 或真实
	// codesign 输出；owner 的两阶段/文件权限测试仍走完整生产流程。
	nodePath := filepath.Join(home, "node")
	if err := os.WriteFile(nodePath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("写入假 node supervisor 失败：%v", err)
	}
	sharedDaemonResolveSupervisorNode = func(string) (string, error) { return nodePath, nil }
	sharedDaemonValidateSupervisor = func(string, string) error { return nil }
	sharedDaemonValidateSignedRuntime = func(context.Context, LocalDaemonOptions, string) error {
		return fmt.Errorf("test listener lacks signed supervisor evidence")
	}
	t.Cleanup(func() { sharedDaemonResolveSupervisorNode = previousResolver })
	t.Cleanup(func() { sharedDaemonValidateSupervisor = previousValidator })
	t.Cleanup(func() { sharedDaemonValidateSignedRuntime = previousRuntimeValidator })
	t.Cleanup(func() { os.RemoveAll(home) })
	for _, name := range []string{".codex", "other-codex"} {
		if err := os.MkdirAll(filepath.Join(home, name), 0o700); err != nil {
			t.Fatalf("创建测试 CODEX_HOME 失败：%v", err)
		}
	}
	return home
}

func allowTestSignedSharedDaemonRuntime(t *testing.T) {
	t.Helper()
	previous := sharedDaemonValidateSignedRuntime
	sharedDaemonValidateSignedRuntime = func(context.Context, LocalDaemonOptions, string) error { return nil }
	t.Cleanup(func() { sharedDaemonValidateSignedRuntime = previous })
}

func TestValidateSharedDaemonCodeSignatureMetadataForNodeAndCodex(t *testing.T) {
	metadataFor := func(identifier string) string {
		return strings.Join([]string{
			"Executable=/Applications/ChatGPT.app/Contents/Resources/" + identifier,
			"Identifier=" + identifier,
			"CodeDirectory v=20500 flags=0x10000(runtime)",
			"TeamIdentifier=2DC432GLL2",
		}, "\n")
	}
	for _, identifier := range []string{"node", "codex"} {
		t.Run(identifier, func(t *testing.T) {
			valid := metadataFor(identifier)
			if err := validateSharedDaemonCodeSignatureMetadata(valid, identifier); err != nil {
				t.Fatalf("OpenAI 签名的 hardened %s 应通过：%v", identifier, err)
			}
			tests := map[string]string{
				"wrong identifier": strings.Replace(valid, "Identifier="+identifier, "Identifier=foreign", 1),
				"wrong team":       strings.Replace(valid, "TeamIdentifier=2DC432GLL2", "TeamIdentifier=OTHER", 1),
				"no runtime":       strings.Replace(valid, "(runtime)", "", 1),
			}
			for name, candidate := range tests {
				t.Run(name, func(t *testing.T) {
					if err := validateSharedDaemonCodeSignatureMetadata(candidate, identifier); err == nil {
						t.Fatal("不可信 supervisor metadata 必须 fail closed")
					}
				})
			}
			otherIdentifier := "node"
			if identifier == "node" {
				otherIdentifier = "codex"
			}
			if err := validateSharedDaemonCodeSignatureMetadata(valid, otherIdentifier); err == nil {
				t.Fatalf("%s metadata 不能冒充 %s 签名", identifier, otherIdentifier)
			}
		})
	}
}

func TestRenderSharedDaemonLaunchAgentUsesSignedNodeSupervisor(t *testing.T) {
	original := sharedDaemonResolveResponsibleSupervisor
	sharedDaemonResolveResponsibleSupervisor = func() (string, error) { return "", nil }
	t.Cleanup(func() { sharedDaemonResolveResponsibleSupervisor = original })

	nodeBin := "/opt/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codexBin := "/opt/codex bin/codex"
	rendered, err := renderSharedDaemonLaunchAgent(
		nodeBin,
		codexBin,
		map[string]string{"CODEX_HOME": "/Users/tester/.codex"},
		"/Users/tester/Library/Logs/mimi-remote/codex-shared-daemon.log",
	)
	if err != nil {
		t.Fatalf("渲染 plist 失败：%v", err)
	}
	content := string(rendered)

	if strings.Contains(content, "<string>/bin/sh</string>") || strings.Contains(content, "exec &#34;") ||
		strings.Contains(content, "<string>daemon</string>") || strings.Contains(content, "<string>start</string>") {
		t.Fatalf("plist 不能引入 shell 或旧 daemon start 责任主体：\n%s", content)
	}
	if !strings.Contains(content, "<string>"+nodeBin+"</string>") ||
		!strings.Contains(content, "<string>"+codexBin+"</string>") {
		t.Fatalf("plist 必须使用绝对 codex 路径：\n%s", content)
	}
	for _, argument := range sharedDaemonSupervisorProgramArguments(nodeBin, codexBin) {
		var escaped bytes.Buffer
		if err := xml.EscapeText(&escaped, []byte(argument)); err != nil {
			t.Fatalf("转义 supervisor 参数失败：%v", err)
		}
		if !strings.Contains(content, "<string>"+escaped.String()+"</string>") {
			t.Fatalf("plist 缺少 signed node supervisor 参数 %q：\n%s", argument, content)
		}
	}
	if strings.Contains(content, "&#xA;") {
		t.Fatalf("ProgramArguments 不能包含会被 launchctl 截断的换行实体：\n%s", content)
	}
	if !strings.Contains(content, "<key>RunAtLoad</key>\n\t<true/>") {
		t.Fatalf("plist 必须覆盖登录冷启动：\n%s", content)
	}
	if !strings.Contains(content, "<key>KeepAlive</key>\n\t<false/>") {
		t.Fatalf("supervisor 退出后不能被 launchd 反复重启：\n%s", content)
	}
	if strings.Contains(content, "<key>AbandonProcessGroup</key>") {
		t.Fatalf("持久 supervisor 不应放弃 app-server 所在进程组：\n%s", content)
	}
	if strings.Contains(content, "detached: true") || strings.Contains(content, ".unref()") {
		t.Fatalf("plist 不能再包含不可观测的 detached launcher：\n%s", content)
	}
	if !strings.Contains(content, "<key>Umask</key>\n\t<integer>63</integer>") {
		t.Fatalf("LaunchAgent 日志必须只允许当前用户读取：\n%s", content)
	}
	if !strings.Contains(content, "<key>CODEX_HOME</key>\n\t\t<string>/Users/tester/.codex</string>") {
		t.Fatalf("plist 必须固定 CODEX_HOME：\n%s", content)
	}
	for _, key := range sharedDaemonStrippedEnvKeys {
		if key == sharedDaemonPinnedCodexEnvironmentKey {
			continue
		}
		// 空值覆盖 launchd 用户域中 Desktop 写入的值，同时避免 shell wrapper。
		emptyEntry := "<key>" + key + "</key>\n\t\t<string></string>"
		if !strings.Contains(content, emptyEntry) {
			t.Fatalf("plist 必须以空值覆盖 Desktop 专属变量 %s：\n%s", key, content)
		}
	}
	if value := sharedDaemonPlistStringValue(rendered, "NODE_OPTIONS"); value != "" {
		t.Fatalf("supervisor 必须清空继承的 NODE_OPTIONS，实际=%q", value)
	}
	if value := sharedDaemonPlistStringValue(rendered, sharedDaemonPinnedCodexEnvironmentKey); value != codexBin {
		t.Fatalf("非 App 启动必须把已验证 codex 路径固定到 supervisor 环境，实际=%q", value)
	}
}

func TestRenderSharedDaemonLaunchAgentPendingDisablesRunAtLoad(t *testing.T) {
	rendered, err := renderSharedDaemonLaunchAgent(
		"/opt/ChatGPT.app/Contents/Resources/cua_node/bin/node",
		"/opt/codex/bin/codex",
		map[string]string{"CODEX_HOME": "/Users/tester/.codex"},
		"",
		false,
	)
	if err != nil {
		t.Fatal(err)
	}
	content := string(rendered)
	if !strings.Contains(content, "<key>RunAtLoad</key>\n\t<false/>") ||
		strings.Contains(content, "<key>RunAtLoad</key>\n\t<true/>") {
		t.Fatalf("待迁移 owner 必须禁止登录自动启动：\n%s", content)
	}
}

func TestRenderSharedDaemonLaunchAgentEscapesXML(t *testing.T) {
	rendered, err := renderSharedDaemonLaunchAgent(
		"/opt/ChatGPT.app/Contents/Resources/cua_node/bin/node",
		"/tmp/a&b/codex",
		map[string]string{"CODEX_HOME": "/tmp/<home>"},
		"",
	)
	if err != nil {
		t.Fatalf("渲染 plist 失败：%v", err)
	}
	content := string(rendered)
	if strings.Contains(content, "/tmp/a&b/codex") || strings.Contains(content, "<home>") {
		t.Fatalf("plist 未转义特殊字符：\n%s", content)
	}
	if !strings.Contains(content, "/tmp/a&amp;b/codex") {
		t.Fatalf("plist 缺少转义后的 codex 路径：\n%s", content)
	}
}

func TestRenderSharedDaemonLaunchAgentRejectsEmptyBin(t *testing.T) {
	if _, err := renderSharedDaemonLaunchAgent("  ", "/opt/codex/bin/codex", nil, ""); err == nil {
		t.Fatal("空 node supervisor 路径必须报错")
	}
	if _, err := renderSharedDaemonLaunchAgent("/opt/node", "  ", nil, ""); err == nil {
		t.Fatal("空 codex 路径必须报错")
	}
}

func TestEnsureSharedDaemonLaunchAgentRejectsUntrustedSupervisorBeforeWrite(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	previousValidator := sharedDaemonValidateSupervisor
	sharedDaemonValidateSupervisor = func(string, string) error {
		return fmt.Errorf("共享 daemon supervisor 不是受支持的 OpenAI 签名 codex")
	}
	t.Cleanup(func() { sharedDaemonValidateSupervisor = previousValidator })

	_, err := EnsureSharedDaemonLaunchAgent(LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	})
	if err == nil || !strings.Contains(err.Error(), "OpenAI 签名") {
		t.Fatalf("不可信 supervisor 必须在写 plist 前拒绝：%v", err)
	}
	path, pathErr := SharedDaemonLaunchAgentPath()
	if pathErr != nil {
		t.Fatal(pathErr)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("签名失败不能落盘 LaunchAgent：%v", statErr)
	}
}

func TestEnsureSharedDaemonLaunchAgentIsIdempotent(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	options := LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}

	changed, err := EnsureSharedDaemonLaunchAgent(options)
	if err != nil {
		t.Fatalf("首次安装失败：%v", err)
	}
	if !changed {
		t.Fatal("首次安装应报告已变更")
	}

	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		t.Fatalf("解析 plist 路径失败：%v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("plist 未落盘：%v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("plist 可能包含 MCP/API 环境变量，权限应为 0600，实际 %v", info.Mode().Perm())
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err = EnsureSharedDaemonLaunchAgent(options)
	if err != nil {
		t.Fatalf("重复安装失败：%v", err)
	}
	if changed {
		t.Fatal("内容未变时不应报告变更，否则每次启动都会重装 job")
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("旧版 0644 plist 应原地收紧为 0600：info=%v err=%v", info, err)
	}

	options.Env["CODEX_HOME"] = filepath.Join(home, "other-codex")
	changed, err = EnsureSharedDaemonLaunchAgent(options)
	if err != nil {
		t.Fatalf("更新安装失败：%v", err)
	}
	if !changed {
		t.Fatal("CODEX_HOME 变化必须触发重装")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取 plist 失败：%v", err)
	}
	if !strings.Contains(string(content), filepath.Join(home, "other-codex")) {
		t.Fatalf("plist 未更新 CODEX_HOME：\n%s", content)
	}

	// 临时文件必须清理，否则 LaunchAgents 目录会堆积半成品 plist。
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatalf("读取 LaunchAgents 目录失败：%v", err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".codex-shared-daemon-") {
			t.Fatalf("残留临时文件：%s", entry.Name())
		}
	}
}

func TestEnsureSharedDaemonLaunchAgentPinsEffectiveCodexHome(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")

	changed, err := EnsureSharedDaemonLaunchAgent(LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"TERM": "xterm-256color"},
	})
	if err != nil {
		t.Fatalf("安装 owner 失败：%v", err)
	}
	if !changed {
		t.Fatal("首次安装应报告已变更")
	}
	path, _ := SharedDaemonLaunchAgentPath()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	socketPath, err := LocalDaemonSocketPath(nil)
	if err != nil {
		t.Fatal(err)
	}
	effectiveHome := filepath.Dir(filepath.Dir(socketPath))
	expected := "<key>CODEX_HOME</key>\n\t\t<string>" + effectiveHome + "</string>"
	if !strings.Contains(string(content), expected) {
		t.Fatalf("plist 必须固定实际 CODEX_HOME：\n%s", content)
	}
}

func TestEnsureSharedDaemonLaunchAgentPreservesSanitizedUserToolingPath(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	firstUserBin := filepath.Join(home, "tools", "bin")
	secondUserBin := filepath.Join(home, "other-tools", "bin")
	t.Setenv("PATH", firstUserBin+":.:/usr/bin")
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	options := LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}

	if changed, err := EnsureSharedDaemonLaunchAgent(options); err != nil || !changed {
		t.Fatalf("首次安装失败：changed=%t err=%v", changed, err)
	}
	path, _ := SharedDaemonLaunchAgentPath()
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	toolingPath := sharedDaemonPlistStringValue(before, "PATH")
	for _, required := range []string{"/opt/homebrew/bin", "/opt/homebrew/sbin", firstUserBin} {
		if !strings.Contains(toolingPath, required) {
			t.Fatalf("稳定 owner PATH 缺少 %s：%s", required, toolingPath)
		}
	}
	if strings.Contains(toolingPath, ":.:") || strings.HasSuffix(toolingPath, ":.") {
		t.Fatalf("稳定 owner PATH 不能保留相对目录：%s", toolingPath)
	}

	// resident agentd 后续看到较窄或不同的进程 PATH 时，不能反向覆盖首次由
	// Mac App 捕获的用户工具目录，否则每次启动都会触发 owner 迁移。
	t.Setenv("PATH", secondUserBin+":/usr/bin")
	if changed, err := EnsureSharedDaemonLaunchAgent(options); err != nil || changed {
		t.Fatalf("进程 PATH 变化不应改写既有 owner：changed=%t err=%v", changed, err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("未显式配置 PATH 时必须保持已安装的稳定工具环境")
	}
}

func TestEnsureSharedDaemonOwnerMarksPreexistingDaemonForExplicitMigration(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	loaded := false
	commands := []string{}
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		commands = append(commands, strings.Join(arguments, " "))
		switch arguments[0] {
		case "print":
			if loaded {
				return "loaded", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "bootout":
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	status, err := EnsureSharedDaemonOwner(context.Background(), LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}, true)
	if err != nil {
		t.Fatalf("安装 owner 失败：%v", err)
	}
	if !status.Installed || !status.Loaded || !status.Secure || !status.Created ||
		!status.Changed || !status.MigrationRequired || status.RunAtLoad {
		t.Fatalf("旧 daemon 必须等待显式迁移：%+v", status)
	}
	if len(commands) == 0 || !strings.HasPrefix(commands[len(commands)-2], "bootstrap ") {
		t.Fatalf("首次安装必须 bootstrap job：%v", commands)
	}
	flagPath, err := sharedDaemonMigrationFlagPath()
	if err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(flagPath); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("迁移标记缺失或权限错误：info=%v err=%v", info, err)
	}

	if err := RemoveSharedDaemonOwner(context.Background()); err != nil {
		t.Fatalf("移除 owner 失败：%v", err)
	}
	plistPath, _ := SharedDaemonLaunchAgentPath()
	if _, err := os.Stat(plistPath); !os.IsNotExist(err) {
		t.Fatalf("plist 应被删除：%v", err)
	}
	if _, err := os.Stat(flagPath); !os.IsNotExist(err) {
		t.Fatalf("迁移标记应被删除：%v", err)
	}
}

func TestEnsureSharedDaemonOwnerRechecksListenerBeforeBootout(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	loaded := false
	bootstrapCalls := 0
	bootoutCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			bootstrapCalls++
			loaded = true
			return "", nil
		case "bootout":
			bootoutCalls++
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	oldOptions := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex-old"),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	if _, err := EnsureSharedDaemonOwner(context.Background(), oldOptions, false); err != nil {
		t.Fatal(err)
	}

	// 入口快照仍是“无 listener”，但在新 plan 的签名校验期间模拟另一条
	// Codex 启动链赢得 socket。bootout 前的二次取证必须把 owner 改成 manual。
	originalValidator := sharedDaemonValidateSupervisor
	var stopServer func()
	sharedDaemonValidateSupervisor = func(string, string) error {
		if stopServer == nil {
			_, _, stopServer = startLocalDaemonTestServer(
				t,
				codexHome,
				"Codex Desktop/0.147.0 (Mac OS; arm64)",
			)
		}
		return nil
	}
	t.Cleanup(func() {
		sharedDaemonValidateSupervisor = originalValidator
		if stopServer != nil {
			stopServer()
		}
	})

	status, err := EnsureSharedDaemonOwner(context.Background(), LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex-new"),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}, false)
	if err != nil {
		t.Fatalf("bootout 前出现 listener 应安全收敛为 pending：%v", err)
	}
	if !status.MigrationRequired || status.RunAtLoad || !loaded || bootoutCalls != 0 || bootstrapCalls != 1 {
		t.Fatalf("活跃 listener 不能被 bootout/rebootstrap：status=%+v loaded=%t bootout=%d bootstrap=%d", status, loaded, bootoutCalls, bootstrapCalls)
	}
}

func TestEnsureSharedDaemonOwnerFreshStartNeedsNoMigration(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	loaded := false
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "loaded", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	status, err := EnsureSharedDaemonOwner(context.Background(), LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}, false)
	if err != nil {
		t.Fatalf("安装 owner 失败：%v", err)
	}
	if status.MigrationRequired {
		t.Fatalf("全新冷启动不应要求迁移：%+v", status)
	}
	if !status.RunAtLoad {
		t.Fatalf("全新冷启动必须保留登录恢复：%+v", status)
	}
}

func TestEnsureSharedDaemonOwnerRestoresPreviousJobWhenReloadFails(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	loaded := false
	bootstrapCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = {\n\tstate = exited\n}", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			bootstrapCalls++
			if bootstrapCalls == 2 {
				return "", fmt.Errorf("new plist rejected")
			}
			loaded = true
			return "", nil
		case "bootout":
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	options := LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := EnsureSharedDaemonOwner(context.Background(), options, false); err != nil {
		t.Fatalf("安装初始 owner 失败：%v", err)
	}
	path, _ := SharedDaemonLaunchAgentPath()
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	options.Env = map[string]string{"CODEX_HOME": filepath.Join(home, "other-codex")}
	if _, err := EnsureSharedDaemonOwner(context.Background(), options, false); err == nil ||
		!strings.Contains(err.Error(), "已恢复原 daemon owner") {
		t.Fatalf("新 job 加载失败时必须报告已回滚：%v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Fatalf("回滚后 plist 必须逐字恢复：\nbefore=%s\nafter=%s", before, after)
	}
	if !loaded || bootstrapCalls != 3 {
		t.Fatalf("回滚后原 job 必须重新加载：loaded=%t bootstrapCalls=%d", loaded, bootstrapCalls)
	}
}

func TestRollbackSharedDaemonOwnerChangeRestoresPreviousOwnerAfterLaterFailure(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	loaded := false
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = {\n\tstate = exited\n}", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "bootout":
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	options := LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := EnsureSharedDaemonOwner(context.Background(), options, false); err != nil {
		t.Fatalf("安装初始 owner 失败：%v", err)
	}
	path, _ := SharedDaemonLaunchAgentPath()
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	options.Env = map[string]string{"CODEX_HOME": filepath.Join(home, "other-codex")}
	status, err := EnsureSharedDaemonOwner(context.Background(), options, true)
	if err != nil {
		t.Fatalf("更新 owner 失败：%v", err)
	}
	if status.Rollback == nil || !status.MigrationRequired {
		t.Fatalf("变更后的 owner 必须携带回滚令牌和迁移标记：%+v", status)
	}
	if err := RollbackSharedDaemonOwnerChange(context.Background(), status.Rollback); err != nil {
		t.Fatalf("后续配置失败时回滚 owner 失败：%v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Fatalf("回滚后 plist 必须恢复：\nbefore=%s\nafter=%s", before, after)
	}
	if !loaded {
		t.Fatal("回滚后原 job 必须保持加载")
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || required {
		t.Fatalf("回滚后必须恢复原迁移标记：required=%t err=%v", required, err)
	}
}

func TestRollbackSharedDaemonOwnerChangeRefusesConcurrentModification(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	loaded := false
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = {\n\tstate = exited\n}", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	status, err := EnsureSharedDaemonOwner(context.Background(), LocalDaemonOptions{
		CodexBin: codexBin,
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}, false)
	if err != nil {
		t.Fatalf("安装 owner 失败：%v", err)
	}
	if status.Rollback == nil {
		t.Fatal("首次创建 owner 必须提供回滚令牌")
	}
	path, _ := SharedDaemonLaunchAgentPath()
	concurrent := []byte("concurrent-owner\n")
	if err := os.WriteFile(path, concurrent, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := RollbackSharedDaemonOwnerChange(context.Background(), status.Rollback); err == nil ||
		!strings.Contains(err.Error(), "拒绝覆盖") {
		t.Fatalf("并发修改后必须拒绝回滚：%v", err)
	}
	current, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(current) != string(concurrent) {
		t.Fatalf("拒绝回滚时不能覆盖并发 owner：%q", current)
	}
}

func TestEnsureSharedDaemonOwnerRepairsPrivateMigrationMarkerMode(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path, err := sharedDaemonMigrationFlagPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("restart-required\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// 测试进程可能继承 LaunchAgent 的 0077 umask；显式放宽才能稳定复现
	// 来自旧版本的公开 marker。
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if required, err := SharedDaemonMigrationRequired(); err == nil || required {
		t.Fatalf("公开 marker 必须 fail closed：required=%t err=%v", required, err)
	}
	if err := repairSharedDaemonMigrationFlagPermissions(); err != nil {
		t.Fatalf("应能收紧旧 marker 权限：%v", err)
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || !required {
		t.Fatalf("修复后 marker 应可安全读取：required=%t err=%v", required, err)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("marker 权限必须为 0600：info=%v err=%v", info, err)
	}
}

func TestEnsureSharedDaemonOwnerRecoversMarkerFromManualPlist(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, false); err != nil {
		t.Fatal(err)
	}
	loaded := true
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		if arguments[0] == "print" && loaded {
			return "service = { state = exited }", nil
		}
		return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	status, err := EnsureSharedDaemonOwner(context.Background(), options, false)
	if err != nil {
		t.Fatal(err)
	}
	if !status.MigrationRequired || status.RunAtLoad {
		t.Fatalf("manual plist 必须补回 pending marker：%+v", status)
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || !required {
		t.Fatalf("崩溃窗口恢复后 marker 必须存在：required=%t err=%v", required, err)
	}
}

func TestStableOwnerNormalEnsureDoesNotKickstartPendingMigration(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	loaded := false
	kickstartCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "kickstart":
			kickstartCalls++
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })
	if _, err := EnsureSharedDaemonOwner(context.Background(), options, true); err != nil {
		t.Fatal(err)
	}

	_, err := ensureLocalDaemonWithStableOwner(context.Background(), options)
	if !errors.Is(err, ErrSharedDaemonMigrationPending) || kickstartCalls != 0 {
		t.Fatalf("pending + socket missing 必须等待用户确认：err=%v kickstart=%d", err, kickstartCalls)
	}
	if required, markerErr := SharedDaemonMigrationRequired(); markerErr != nil || !required {
		t.Fatalf("普通恢复失败后 marker 必须保留：required=%t err=%v", required, markerErr)
	}
}

func TestPreparedIntentCreatesManualOwnerBeforeFirstBootstrap(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin:            writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:                 map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
		ValidateStableOwner: func() error { return nil },
	}
	if err := markSharedDaemonEnablePrepared(); err != nil {
		t.Fatal(err)
	}
	bootstrapCalls := 0
	loaded := false
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			bootstrapCalls++
			path, err := SharedDaemonLaunchAgentPath()
			if err != nil {
				t.Fatal(err)
			}
			content, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if runAtLoad, ok := sharedDaemonPlistBoolValue(content, "RunAtLoad"); !ok || runAtLoad {
				t.Fatalf("prepared intent 首次 bootstrap 前必须已经是 manual：ok=%t runAtLoad=%t", ok, runAtLoad)
			}
			loaded = true
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	_, err := ensureLocalDaemonWithStableOwner(context.Background(), options)
	if err == nil || bootstrapCalls != 1 {
		t.Fatalf("无 socket 的 prepared 恢复会在 manual bootstrap 后尝试一次启动：err=%v bootstrap=%d", err, bootstrapCalls)
	}
	owner, inspectErr := InspectSharedDaemonOwner(context.Background())
	if inspectErr != nil {
		t.Fatal(inspectErr)
	}
	if owner.RunAtLoad || !owner.MigrationRequired {
		t.Fatalf("prepared 恢复失败必须保持 manual：%+v", owner)
	}
}

func TestRunAtLoadGraceAvoidsDuplicateKickstartWhileSocketStarts(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, true); err != nil {
		t.Fatal(err)
	}

	loaded := true
	kickstartCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "kickstart":
			kickstartCalls++
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		t.Fatal(err)
	}
	type listenResult struct {
		listener net.Listener
		err      error
	}
	result := make(chan listenResult, 1)
	go func() {
		time.Sleep(150 * time.Millisecond)
		listener, listenErr := net.Listen("unix", socketPath)
		result <- listenResult{listener: listener, err: listenErr}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	started, err := startLocalDaemonWithStableOwnerTracked(ctx, options)
	listenerResult := <-result
	if listenerResult.listener != nil {
		t.Cleanup(func() { _ = listenerResult.listener.Close() })
	}
	if listenerResult.err != nil {
		t.Fatal(listenerResult.err)
	}
	if err != nil {
		t.Fatalf("RunAtLoad supervisor 在 grace 内建立 socket 应直接复用：%v", err)
	}
	if started || kickstartCalls != 0 {
		t.Fatalf("RunAtLoad supervisor 正启动时不能创建第二套：started=%t kickstart=%d", started, kickstartCalls)
	}
}

func TestFailedExplicitMigrationCannotReuseFreshEnableIntent(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	loaded := false
	kickstartCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	originalDesktop := sharedDaemonDesktopRunning
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "kickstart":
			kickstartCalls++
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	sharedDaemonDesktopRunning = func(context.Context) (bool, error) { return true, nil }
	t.Cleanup(func() {
		sharedDaemonLaunchctl = originalLaunchctl
		sharedDaemonDesktopRunning = originalDesktop
	})
	if _, err := EnsureSharedDaemonOwner(context.Background(), options, true); err != nil {
		t.Fatal(err)
	}
	if err := markSharedDaemonEnablePrepared(); err != nil {
		t.Fatal(err)
	}

	_, err := RestartSharedDaemonWithStableOwner(context.Background(), options)
	if err == nil || !strings.Contains(err.Error(), "重新打开") {
		t.Fatalf("Desktop guard 应使显式迁移失败：%v", err)
	}
	if pending, pendingErr := sharedDaemonEnablePrepared(); pendingErr != nil || pending {
		t.Fatalf("显式迁移开始后必须消费 fresh intent：pending=%t err=%v", pending, pendingErr)
	}
	beforeEnsure := kickstartCalls
	sharedDaemonDesktopRunning = func(context.Context) (bool, error) { return false, nil }
	_, ensureErr := ensureLocalDaemonWithStableOwner(context.Background(), options)
	if !errors.Is(ensureErr, ErrSharedDaemonMigrationPending) {
		t.Fatalf("显式迁移失败后普通 Ensure 必须继续等待确认：%v", ensureErr)
	}
	if kickstartCalls != beforeEnsure {
		t.Fatalf("普通 Ensure 不能复用旧 intent 静默启动：before=%d after=%d", beforeEnsure, kickstartCalls)
	}
}

func TestReloadSharedDaemonLaunchAgentForMigrationReloadsManualOwner(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, false); err != nil {
		t.Fatal(err)
	}
	if err := writeSharedDaemonMigrationFlag(); err != nil {
		t.Fatal(err)
	}

	loaded := true
	commands := make([][]string, 0, 4)
	originalLaunchctl := sharedDaemonLaunchctl
	originalDesktop := sharedDaemonDesktopRunning
	sharedDaemonDesktopRunning = func(context.Context) (bool, error) { return false, nil }
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		commands = append(commands, append([]string(nil), arguments...))
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = {\n\tstate = exited\n}", nil
			}
			return "", errors.New("not loaded")
		case "bootout":
			if !loaded {
				return "", errors.New("not loaded")
			}
			loaded = false
			return "", nil
		case "bootstrap":
			loaded = true
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() {
		sharedDaemonLaunchctl = originalLaunchctl
		sharedDaemonDesktopRunning = originalDesktop
	})

	if err := reloadSharedDaemonLaunchAgentForMigration(context.Background()); err != nil {
		t.Fatalf("manual owner 应先 reload 再允许 kickstart：%v", err)
	}
	if !loaded {
		t.Fatal("reload 后 owner 必须重新 loaded")
	}
	if len(commands) != 4 || commands[0][0] != "print" || commands[1][0] != "bootout" ||
		commands[2][0] != "bootstrap" || commands[3][0] != "print" {
		t.Fatalf("迁移 reload 必须执行 print→bootout→bootstrap→print：%v", commands)
	}
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if runAtLoad, ok := sharedDaemonPlistBoolValue(content, "RunAtLoad"); !ok || runAtLoad {
		t.Fatalf("reload 期间 owner 必须保持 manual：ok=%t runAtLoad=%t", ok, runAtLoad)
	}
	owner, err := InspectSharedDaemonOwner(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !owner.Installed || !owner.Loaded || owner.Running || !owner.Secure || owner.RunAtLoad || !owner.MigrationRequired {
		t.Fatalf("reload 后必须复核 loaded/manual/pending owner：%+v", owner)
	}
}

func TestStableOwnerRecoveryGuardRunsBeforeAnyEnsureOrRestartMutation(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	guardErr := errors.New("shared config disabled")
	launchctlCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
		launchctlCalls++
		return "", nil
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	options := LocalDaemonOptions{
		CodexBin:    writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:         map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
		StableOwner: true,
		ValidateStableOwner: func() error {
			return guardErr
		},
	}
	_, err := EnsureLocalDaemon(context.Background(), options)
	if !errors.Is(err, guardErr) || launchctlCalls != 0 {
		t.Fatalf("Ensure 恢复权失效必须在任何 launchctl 动作前拒绝：err=%v calls=%d", err, launchctlCalls)
	}
	_, err = RestartSharedDaemonWithStableOwner(context.Background(), options)
	if !errors.Is(err, guardErr) || launchctlCalls != 0 {
		t.Fatalf("Restart 恢复权失效必须在任何 launchctl 动作前拒绝：err=%v calls=%d", err, launchctlCalls)
	}
	path, pathErr := SharedDaemonLaunchAgentPath()
	if pathErr != nil {
		t.Fatal(pathErr)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("恢复权失效不能创建 plist：%v", statErr)
	}
}

func TestCommitSharedDaemonDisableSerializesStaleRecovery(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	var shared atomic.Bool
	shared.Store(true)
	commitEntered := make(chan struct{})
	releaseCommit := make(chan struct{})
	transactionDone := make(chan error, 1)

	originalLaunchctl := sharedDaemonLaunchctl
	mutationCalls := 0
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		if arguments[0] == "print" {
			return "", fmt.Errorf("not loaded")
		}
		mutationCalls++
		return "", nil
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	go func() {
		transactionDone <- CommitSharedDaemonDisable(
			context.Background(),
			func() error { return nil },
			func() error {
				shared.Store(false)
				close(commitEntered)
				<-releaseCommit
				return nil
			},
		)
	}()
	<-commitEntered

	guardErr := errors.New("shared config disabled")
	ensureDone := make(chan error, 1)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	go func() {
		_, err := EnsureLocalDaemon(context.Background(), LocalDaemonOptions{
			CodexBin:    codexBin,
			Env:         map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
			StableOwner: true,
			ValidateStableOwner: func() error {
				if !shared.Load() {
					return guardErr
				}
				return nil
			},
		})
		ensureDone <- err
	}()
	select {
	case err := <-ensureDone:
		t.Fatalf("disable 持锁期间 stale Ensure 不得穿插：%v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(releaseCommit)
	if err := <-transactionDone; err != nil {
		t.Fatal(err)
	}
	if err := <-ensureDone; !errors.Is(err, guardErr) {
		t.Fatalf("disable 提交后 stale Ensure 必须读取新状态并拒绝：%v", err)
	}
	if mutationCalls != 0 {
		t.Fatalf("stale Ensure 不能 bootstrap/kickstart：%d", mutationCalls)
	}
}

func TestCommitConfigWithSharedDaemonLockSerializesStaleRecovery(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	var shared atomic.Bool
	shared.Store(true)
	commitEntered := make(chan struct{})
	releaseCommit := make(chan struct{})
	transactionDone := make(chan error, 1)

	originalLaunchctl := sharedDaemonLaunchctl
	launchctlCalls := 0
	sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
		launchctlCalls++
		return "", nil
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	go func() {
		transactionDone <- CommitConfigWithSharedDaemonLock(
			context.Background(),
			func() error { return nil },
			func() error {
				shared.Store(false)
				close(commitEntered)
				<-releaseCommit
				return nil
			},
		)
	}()
	<-commitEntered

	guardErr := errors.New("setup replaced shared config")
	ensureDone := make(chan error, 1)
	codexBin := writeFakeCodexBin(t, t.TempDir(), "codex")
	go func() {
		_, err := EnsureLocalDaemon(context.Background(), LocalDaemonOptions{
			CodexBin:    codexBin,
			Env:         map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
			StableOwner: true,
			ValidateStableOwner: func() error {
				if !shared.Load() {
					return guardErr
				}
				return nil
			},
		})
		ensureDone <- err
	}()
	select {
	case err := <-ensureDone:
		t.Fatalf("setup 持锁期间 stale Ensure 不得穿插：%v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(releaseCommit)
	if err := <-transactionDone; err != nil {
		t.Fatal(err)
	}
	if err := <-ensureDone; !errors.Is(err, guardErr) {
		t.Fatalf("setup 提交后 stale Ensure 必须读取新状态并拒绝：%v", err)
	}
	if launchctlCalls != 0 {
		t.Fatalf("stale Ensure 不能 bootstrap/kickstart：%d", launchctlCalls)
	}
}

func TestCommitConfigReplacingSharedDaemonCleansStaleOwnerBeforeCommit(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, true); err != nil {
		t.Fatal(err)
	}

	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		if arguments[0] == "print" {
			return "", fmt.Errorf("not loaded")
		}
		return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	committed := false
	if err := CommitConfigReplacingSharedDaemon(
		context.Background(),
		func() error { return nil },
		func() error {
			path, _ := SharedDaemonLaunchAgentPath()
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("非 shared 配置提交前必须先移除 stale owner：%v", err)
			}
			committed = true
			return nil
		},
	); err != nil {
		t.Fatal(err)
	}
	if !committed {
		t.Fatal("清理 stale owner 后应提交新配置")
	}
	if present, err := SharedDaemonOwnerArtifactsPresent(); err != nil || present {
		t.Fatalf("配置替换成功后不能残留 plist/marker/intent：present=%t err=%v", present, err)
	}
}

func TestConfigIdentityRepairPreservesPendingOwnerAndCannotKickstart(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	oldOptions := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, home, "old-codex"),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	newOptions := LocalDaemonOptions{
		CodexBin: writeManagedLifecycleCodexBin(t, codexHome),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	loaded := false
	kickstartCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "bootout":
			loaded = false
			return "", nil
		case "kickstart":
			kickstartCalls++
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	if _, err := ensureSharedDaemonLaunchAgent(oldOptions, false); err != nil {
		t.Fatal(err)
	}
	if err := writeSharedDaemonMigrationFlag(); err != nil {
		t.Fatal(err)
	}
	committed := false
	if err := CommitConfigRepairingSharedDaemonIdentity(
		context.Background(),
		func() error { return nil },
		func() error { committed = true; return nil },
	); err != nil {
		t.Fatal(err)
	}
	if !committed {
		t.Fatal("repair 配置提交回调未执行")
	}
	owner, err := InspectSharedDaemonOwner(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !owner.Installed || owner.RunAtLoad || !owner.MigrationRequired {
		t.Fatalf("Repair 必须保留 manual pending：%+v", owner)
	}

	newOptions.StableOwner = true
	_, err = EnsureLocalDaemon(context.Background(), newOptions)
	if !errors.Is(err, ErrSharedDaemonMigrationPending) || kickstartCalls != 0 {
		t.Fatalf("Repair 后普通 Ensure 仍必须等待用户确认：err=%v kickstart=%d", err, kickstartCalls)
	}
	owner, inspectErr := InspectSharedDaemonOwner(context.Background())
	if inspectErr != nil {
		t.Fatal(inspectErr)
	}
	if owner.RunAtLoad || !owner.MigrationRequired {
		t.Fatalf("更新 owner 身份后仍必须保持 pending：%+v", owner)
	}
}

func TestCommitSharedDaemonDisableLeavesOwnerManualWhenRemovalFails(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, false); err != nil {
		t.Fatal(err)
	}
	originalLaunchctl := sharedDaemonLaunchctl
	originalRemove := sharedDaemonRemoveLaunchAgentFile
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		if arguments[0] == "print" {
			return "", fmt.Errorf("not loaded")
		}
		return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
	}
	sharedDaemonRemoveLaunchAgentFile = func(string) error { return errors.New("disk read-only") }
	t.Cleanup(func() {
		sharedDaemonLaunchctl = originalLaunchctl
		sharedDaemonRemoveLaunchAgentFile = originalRemove
	})

	configState := "shared"
	err := CommitSharedDaemonDisable(
		context.Background(),
		func() error { return nil },
		func() error { configState = "ws"; return nil },
	)
	if err == nil || !strings.Contains(err.Error(), "manual 安全状态") || configState != "shared" {
		t.Fatalf("owner remove 失败必须发生在配置提交前并保留 manual：state=%s err=%v", configState, err)
	}
	path, _ := SharedDaemonLaunchAgentPath()
	content, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if runAtLoad, ok := sharedDaemonPlistBoolValue(content, "RunAtLoad"); !ok || runAtLoad {
		t.Fatalf("卸载失败后 owner 必须保持 manual：ok=%t runAtLoad=%t", ok, runAtLoad)
	}
	if required, markerErr := SharedDaemonMigrationRequired(); markerErr != nil || !required {
		t.Fatalf("卸载失败后必须保留 marker：required=%t err=%v", required, markerErr)
	}
}

func TestCommitSharedDaemonDisableDoesNotRestoreAutoOwnerAfterConfigConflict(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, true); err != nil {
		t.Fatal(err)
	}

	loaded := true
	bootstrapCalls := 0
	bootoutCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootout":
			bootoutCalls++
			loaded = false
			return "", nil
		case "bootstrap":
			bootstrapCalls++
			loaded = true
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	wantErr := errors.New("configuration changed to websocket")
	err := CommitSharedDaemonDisable(
		context.Background(),
		func() error { return nil },
		func() error {
			// 模拟不使用 Mimi operation lock 的外部编辑器已经提交 WS，导致
			// 最后一跳 CAS 拒绝覆盖。旧 auto owner 此时已经失去恢复权。
			return wantErr
		},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("应保留配置冲突错误：%v", err)
	}
	path, _ := SharedDaemonLaunchAgentPath()
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("配置失权后不能恢复旧 auto owner：%v", statErr)
	}
	if !loaded || bootstrapCalls != 0 || bootoutCalls != 0 {
		t.Fatalf("配置冲突后不能重新加载或 bootout 旧 job：loaded=%t bootstrap=%d bootout=%d", loaded, bootstrapCalls, bootoutCalls)
	}
}

func TestCommitSharedDaemonEnableKeepsOwnerManualUntilConfigCommit(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	options := LocalDaemonOptions{
		CodexBin: writeManagedLifecycleCodexBin(t, codexHome),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	loaded := false
	serverStarted := false
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "kickstart":
			if !serverStarted {
				startLocalDaemonTestServer(t, codexHome, "Codex Desktop/0.147.0 (Mac OS; arm64)")
				serverStarted = true
			}
			return "", nil
		case "bootout":
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	commitObserved := false
	wantErr := errors.New("simulate crash before config rename")
	_, err := CommitSharedDaemonEnable(
		context.Background(),
		options,
		func() error { return nil },
		func() error {
			commitObserved = true
			if serverStarted {
				t.Fatal("配置仍为 WS 时绝不能提前 kickstart Unix daemon")
			}
			path, pathErr := SharedDaemonLaunchAgentPath()
			if pathErr != nil {
				t.Fatal(pathErr)
			}
			content, readErr := os.ReadFile(path)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if strings.Contains(string(content), "<key>RunAtLoad</key>\n\t<true/>") {
				t.Fatal("配置 rename 前 owner 绝不能已经允许登录自启")
			}
			if required, markerErr := SharedDaemonMigrationRequired(); markerErr != nil || !required {
				t.Fatalf("配置 rename 前必须有 durable manual marker：required=%t err=%v", required, markerErr)
			}
			return wantErr
		},
	)
	if !errors.Is(err, wantErr) || !commitObserved {
		t.Fatalf("提交前失败应保留原错误并经过 manual 边界：observed=%t err=%v", commitObserved, err)
	}
	path, _ := SharedDaemonLaunchAgentPath()
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("非共享配置提交失败后应清理 Mimi owner：%v", statErr)
	}
}

func TestCommittedFreshEnableRecoversAfterCrashBeforeKickstart(t *testing.T) {
	home := sharedDaemonTestHome(t)
	allowTestSignedSharedDaemonRuntime(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	options := LocalDaemonOptions{
		CodexBin:                    writeManagedLifecycleCodexBin(t, codexHome),
		Env:                         map[string]string{"CODEX_HOME": codexHome},
		StableOwner:                 true,
		PrepareOwnerForConfigCommit: true,
	}
	loaded := false
	serverStarted := false
	kickstartCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "kickstart":
			kickstartCalls++
			if !serverStarted {
				startLocalDaemonTestServer(t, codexHome, "Codex Desktop/0.147.0 (Mac OS; arm64)")
				serverStarted = true
			}
			return "", nil
		case "bootout":
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	prepared, err := prepareSharedDaemonOwnerForConfigCommit(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if prepared.DaemonPreexisting || kickstartCalls != 0 {
		t.Fatalf("准备阶段只能落 manual owner：status=%+v kickstart=%d", prepared, kickstartCalls)
	}
	if err := markSharedDaemonEnablePrepared(); err != nil {
		t.Fatal(err)
	}
	// 此处等价于配置 rename 已成功后进程立即掉电：磁盘为 shared 配置，
	// manual owner/marker/enable intent 均已持久化，但 socket 尚不存在。
	recovery := options
	recovery.PrepareOwnerForConfigCommit = false
	recovery.ValidateStableOwner = func() error { return nil }
	status, err := EnsureLocalDaemon(context.Background(), recovery)
	if err != nil {
		t.Fatal(err)
	}
	if !status.StartedByStableOwner || kickstartCalls != 1 || !status.LifecycleValidated {
		t.Fatalf("已提交 fresh enable 必须由稳定 owner 恢复：status=%+v kickstart=%d", status, kickstartCalls)
	}
	owner, err := InspectSharedDaemonOwner(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if owner.RunAtLoad || !owner.MigrationRequired {
		t.Fatalf("恢复成功后仍应保持 manual 并等待用户确认：%+v", owner)
	}
	if pending, err := sharedDaemonEnablePrepared(); err != nil || pending {
		t.Fatalf("首次 manual 冷启动验证后必须消费 enable intent：pending=%t err=%v", pending, err)
	}
}

func TestPrepareSharedDaemonOwnerRejectsConnectableListenerWithoutHandshake(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	socketPath, err := LocalDaemonSocketPath(map[string]string{"CODEX_HOME": codexHome})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			_ = conn.Close()
		}
	}()

	launchctlCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
		launchctlCalls++
		return "", errors.New("unexpected launchctl call")
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	_, err = prepareSharedDaemonOwnerForConfigCommit(context.Background(), LocalDaemonOptions{
		CodexBin:                    "/missing/codex",
		Env:                         map[string]string{"CODEX_HOME": codexHome},
		StableOwner:                 true,
		PrepareOwnerForConfigCommit: true,
	})
	if err == nil || !strings.Contains(err.Error(), "完整握手失败") {
		t.Fatalf("只 accept、不完成 initialize 的 listener 必须阻止配置提交：%v", err)
	}
	if launchctlCalls != 0 {
		t.Fatalf("握手失败必须在 owner mutation 前终止：launchctl=%d", launchctlCalls)
	}
	ownerPath, pathErr := SharedDaemonLaunchAgentPath()
	if pathErr != nil {
		t.Fatal(pathErr)
	}
	if _, statErr := os.Lstat(ownerPath); !os.IsNotExist(statErr) {
		t.Fatalf("握手失败不能创建 owner：%v", statErr)
	}
}

func TestCommitSharedDaemonEnableKeepsManualUntilExplicitMigration(t *testing.T) {
	home := sharedDaemonTestHome(t)
	allowTestSignedSharedDaemonRuntime(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	options := LocalDaemonOptions{
		CodexBin: writeManagedLifecycleCodexBin(t, codexHome),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	loaded := false
	serverStarted := false
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "kickstart":
			if !serverStarted {
				startLocalDaemonTestServer(t, codexHome, "Codex Desktop/0.147.0 (Mac OS; arm64)")
				serverStarted = true
			}
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	configCommitted := false
	status, err := CommitSharedDaemonEnable(
		context.Background(),
		options,
		func() error { return nil },
		func() error {
			path, _ := SharedDaemonLaunchAgentPath()
			content, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			if strings.Contains(string(content), "<key>RunAtLoad</key>\n\t<true/>") {
				return fmt.Errorf("owner 在配置提交前提前提升")
			}
			configCommitted = true
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !configCommitted || !status.Started || !status.OwnerMigrationRequired {
		t.Fatalf("全新 managed daemon 应在配置提交后保持 pending：committed=%t status=%+v", configCommitted, status)
	}
	path, _ := SharedDaemonLaunchAgentPath()
	content, readErr := os.ReadFile(path)
	if readErr != nil || !strings.Contains(string(content), "<key>RunAtLoad</key>\n\t<false/>") {
		t.Fatalf("显式迁移前必须保持 manual：read=%v content=%s", readErr, content)
	}
	if required, markerErr := SharedDaemonMigrationRequired(); markerErr != nil || !required {
		t.Fatalf("显式迁移前必须保留 marker：required=%t err=%v", required, markerErr)
	}
	if prepared, preparedErr := sharedDaemonEnablePrepared(); preparedErr != nil || prepared {
		t.Fatalf("首次 manual 冷启动验证后必须消费 durable intent：prepared=%t err=%v", prepared, preparedErr)
	}
}

func TestAttachedManagedRecoveryConsumesFreshEnableIntentOnce(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	_, _, stopServer := startLocalDaemonTestServer(t, codexHome, "Codex Desktop/0.147.0 (Mac OS; arm64)")
	options := LocalDaemonOptions{
		CodexBin: writeManagedLifecycleCodexBin(t, codexHome),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	loaded := false
	kickstartCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			loaded = true
			return "", nil
		case "kickstart":
			kickstartCalls++
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })
	if _, err := EnsureSharedDaemonOwner(context.Background(), options, true); err != nil {
		t.Fatal(err)
	}
	if err := markSharedDaemonEnablePrepared(); err != nil {
		t.Fatal(err)
	}

	status, err := ensureLocalDaemonWithStableOwner(context.Background(), options)
	if err != nil || !status.LifecycleValidated || !status.OwnerMigrationRequired {
		t.Fatalf("已运行的 managed listener 应只 attach 并保持 pending：status=%+v err=%v", status, err)
	}
	if prepared, preparedErr := sharedDaemonEnablePrepared(); preparedErr != nil || prepared {
		t.Fatalf("generic managed 校验后必须消费 intent：prepared=%t err=%v", prepared, preparedErr)
	}
	stopServer()
	_, err = ensureLocalDaemonWithStableOwner(context.Background(), options)
	if !errors.Is(err, ErrSharedDaemonMigrationPending) || kickstartCalls != 0 {
		t.Fatalf("daemon 再掉线不能复用 intent：err=%v kickstart=%d", err, kickstartCalls)
	}
}

func writeManagedLifecycleCodexBin(t *testing.T, codexHome string) string {
	t.Helper()
	if canonical, err := filepath.EvalSymlinks(codexHome); err == nil {
		codexHome = canonical
	}
	path := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(codexHome, localDaemonSocketDir, localDaemonSocketName)
	payload := fmt.Sprintf(
		`{"status":"running","backend":"pid","managedCodexPath":"%s","managedCodexVersion":"0.147.0","socketPath":"%s","appServerVersion":"0.147.0"}`,
		path,
		socketPath,
	)
	script := "#!/bin/sh\nprintf '%s\\n' '" + payload + "'\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestStableOwnerNormalEnsurePreservesPendingOwnerOnLifecycleFailure(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	_, _, _ = startLocalDaemonTestServer(t, codexHome, "Codex Desktop/0.147.0 (Mac OS; arm64)")
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}

	loaded := false
	bootstrapCalls := 0
	bootoutCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			bootstrapCalls++
			loaded = true
			return "", nil
		case "bootout":
			bootoutCalls++
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	_, err := ensureLocalDaemonWithStableOwner(context.Background(), options)
	if err == nil || !strings.Contains(err.Error(), "解析 Codex local daemon 状态失败") {
		t.Fatalf("无效 lifecycle 输出必须 fail closed：%v", err)
	}
	if bootstrapCalls != 1 || bootoutCalls != 0 || !loaded {
		t.Fatalf("普通 lifecycle 故障不能回滚 pending owner：bootstrap=%d bootout=%d loaded=%t", bootstrapCalls, bootoutCalls, loaded)
	}
	path, pathErr := SharedDaemonLaunchAgentPath()
	if pathErr != nil {
		t.Fatal(pathErr)
	}
	content, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	runAtLoad, ok := sharedDaemonPlistBoolValue(content, "RunAtLoad")
	if !ok || runAtLoad {
		t.Fatalf("普通 lifecycle 故障后必须保留 manual plist：ok=%t runAtLoad=%t", ok, runAtLoad)
	}
	if required, markerErr := SharedDaemonMigrationRequired(); markerErr != nil || !required {
		t.Fatalf("普通 lifecycle 故障后必须保留 marker：required=%t err=%v", required, markerErr)
	}
}

func TestStableOwnerConfigurationRestoresPreviousOwnerWhenSocketDropsAfterInstall(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	codexHome := filepath.Join(home, ".codex")
	oldOptions := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex-old"),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	loaded := false
	bootstrapCalls := 0
	bootoutCalls := 0
	printCalls := 0
	var stopSocket func()
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			printCalls++
			// live listener 下的新 plist 只 stage 到磁盘，不发生 bootout/bootstrap。
			// 第四次 print 是新 owner 的 post-stage 复核；在它返回后模拟 socket
			// 竞态退出，外层应走 files-only rollback。
			if printCalls == 4 && stopSocket != nil {
				stopSocket()
			}
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootstrap":
			bootstrapCalls++
			loaded = true
			return "", nil
		case "bootout":
			bootoutCalls++
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	if _, err := EnsureSharedDaemonOwner(context.Background(), oldOptions, false); err != nil {
		t.Fatal(err)
	}
	path, pathErr := SharedDaemonLaunchAgentPath()
	if pathErr != nil {
		t.Fatal(pathErr)
	}
	before, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	_, _, stopSocket = startLocalDaemonTestServer(t, codexHome, "Codex Desktop/0.147.0 (Mac OS; arm64)")

	newOptions := LocalDaemonOptions{
		CodexBin:               writeFakeCodexBin(t, t.TempDir(), "codex-new"),
		Env:                    map[string]string{"CODEX_HOME": codexHome},
		StableOwner:            true,
		RollbackOwnerOnFailure: true,
	}
	_, err := ensureLocalDaemonWithStableOwner(context.Background(), newOptions)
	if !errors.Is(err, ErrSharedDaemonMigrationPending) {
		t.Fatalf("设置事务应报告 socket 竞态并回滚：%v", err)
	}
	after, readErr := os.ReadFile(path)
	if readErr != nil || !bytes.Equal(before, after) {
		t.Fatalf("设置未提交时必须逐字恢复原 plist：read=%v", readErr)
	}
	if !loaded || bootstrapCalls != 1 || bootoutCalls != 0 {
		t.Fatalf("live listener 的 stage/rollback 只能恢复磁盘 owner：loaded=%t bootstrap=%d bootout=%d", loaded, bootstrapCalls, bootoutCalls)
	}
	if required, markerErr := SharedDaemonMigrationRequired(); markerErr != nil || required {
		t.Fatalf("设置未提交时必须恢复原 marker：required=%t err=%v", required, markerErr)
	}
}

func TestCommitSharedDaemonMigrationPromotesAutoStartOnlyAfterExplicitSuccess(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, false); err != nil {
		t.Fatal(err)
	}
	if err := writeSharedDaemonMigrationFlag(); err != nil {
		t.Fatal(err)
	}
	if err := markSharedDaemonEnablePrepared(); err != nil {
		t.Fatal(err)
	}
	if err := commitSharedDaemonMigration(options); err != nil {
		t.Fatal(err)
	}
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	runAtLoad, ok := sharedDaemonPlistBoolValue(content, "RunAtLoad")
	required, markerErr := SharedDaemonMigrationRequired()
	if !ok || !runAtLoad || markerErr != nil || required {
		t.Fatalf("显式成功提交后才应恢复自动启动并清 marker：runAtLoad=%t ok=%t required=%t err=%v", runAtLoad, ok, required, markerErr)
	}
	if prepared, preparedErr := sharedDaemonEnablePrepared(); preparedErr != nil || prepared {
		t.Fatalf("显式成功提交后必须清理 enable intent：prepared=%t err=%v", prepared, preparedErr)
	}
}

func TestRemoveSharedDaemonOwnerKeepsManualStateWhenDeleteFails(t *testing.T) {
	testRemoveSharedDaemonOwnerFailureIsManual(t, "delete", func() {
		sharedDaemonRemoveLaunchAgentFile = func(string) error { return errors.New("disk read-only") }
	})
}

func TestRemoveSharedDaemonOwnerKeepsAutoEntryRemovedWhenMarkerClearFails(t *testing.T) {
	testRemoveSharedDaemonOwnerFailureIsManual(t, "marker", func() {
		sharedDaemonClearMigrationForRemoval = func() error { return errors.New("marker busy") }
	})
}

func testRemoveSharedDaemonOwnerFailureIsManual(t *testing.T, stage string, injectFailure func()) {
	t.Helper()
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		CodexBin: writeFakeCodexBin(t, t.TempDir(), "codex"),
		Env:      map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	if _, err := ensureSharedDaemonLaunchAgent(options, true); err != nil {
		t.Fatal(err)
	}
	path, _ := SharedDaemonLaunchAgentPath()

	loaded := true
	bootoutCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	originalRemove := sharedDaemonRemoveLaunchAgentFile
	originalClear := sharedDaemonClearMigrationForRemoval
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootout":
			bootoutCalls++
			loaded = false
			return "", nil
		case "bootstrap":
			loaded = true
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	injectFailure()
	t.Cleanup(func() {
		sharedDaemonLaunchctl = originalLaunchctl
		sharedDaemonRemoveLaunchAgentFile = originalRemove
		sharedDaemonClearMigrationForRemoval = originalClear
	})

	err := removeSharedDaemonOwnerUnlocked(context.Background())
	if err == nil {
		t.Fatalf("%s 注入失败必须返回错误", stage)
	}
	after, readErr := os.ReadFile(path)
	if stage == "delete" {
		if readErr != nil {
			t.Fatalf("delete 失败应留下 manual plist：%v", readErr)
		}
		if runAtLoad, ok := sharedDaemonPlistBoolValue(after, "RunAtLoad"); !ok || runAtLoad {
			t.Fatalf("delete 失败不能恢复 auto：ok=%t runAtLoad=%t", ok, runAtLoad)
		}
	} else if !os.IsNotExist(readErr) {
		t.Fatalf("marker clear 失败时 auto 入口必须已删除：%v", readErr)
	}
	if !loaded || bootoutCalls != 0 {
		t.Fatalf("%s 失败后当前 loaded job 不应被 bootout：loaded=%t bootout=%d", stage, loaded, bootoutCalls)
	}
	if required, markerErr := SharedDaemonMigrationRequired(); markerErr != nil || !required {
		t.Fatalf("%s 失败后 marker 必须保持 fail-closed：required=%t err=%v", stage, required, markerErr)
	}
}

func TestRemoveSharedDaemonOwnerRecoversLoadedJobWithoutPlist(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	if err := writeSharedDaemonMigrationFlag(); err != nil {
		t.Fatal(err)
	}
	if err := markSharedDaemonEnablePrepared(); err != nil {
		t.Fatal(err)
	}
	loaded := true
	bootoutCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = { state = exited }", nil
			}
			return "", fmt.Errorf("not loaded")
		case "bootout":
			bootoutCalls++
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	if err := removeSharedDaemonOwnerUnlocked(context.Background()); err != nil {
		t.Fatalf("plist 已删后的禁用重试应幂等完成：%v", err)
	}
	if bootoutCalls != 0 || !loaded {
		t.Fatalf("孤立 loaded job 必须保留到注销：bootout=%d loaded=%t", bootoutCalls, loaded)
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || required {
		t.Fatalf("幂等禁用必须清理 marker：required=%t err=%v", required, err)
	}
	if prepared, err := sharedDaemonEnablePrepared(); err != nil || prepared {
		t.Fatalf("幂等禁用必须清理 fresh-enable intent：prepared=%t err=%v", prepared, err)
	}
}

func TestSharedDaemonOperationLockSerializesCallers(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	firstEntered := make(chan struct{})
	releaseFirst := make(chan struct{})
	firstDone := make(chan error, 1)
	go func() {
		_, err := withSharedDaemonOperationLock(context.Background(), func() (LocalDaemonStatus, error) {
			close(firstEntered)
			<-releaseFirst
			return LocalDaemonStatus{}, nil
		})
		firstDone <- err
	}()
	<-firstEntered

	var secondEntered atomic.Bool
	secondDone := make(chan error, 1)
	go func() {
		_, err := withSharedDaemonOperationLock(context.Background(), func() (LocalDaemonStatus, error) {
			secondEntered.Store(true)
			return LocalDaemonStatus{}, nil
		})
		secondDone <- err
	}()
	time.Sleep(150 * time.Millisecond)
	if secondEntered.Load() {
		t.Fatal("第二个恢复/迁移不能插入第一个操作")
	}
	close(releaseFirst)
	if err := <-firstDone; err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-secondDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("第一个操作结束后第二个应取得文件锁")
	}
	if !secondEntered.Load() {
		t.Fatal("第二个操作未执行")
	}
}

func TestInspectLaunchAgentStateDistinguishesLoadedFromRunning(t *testing.T) {
	originalLaunchctl := sharedDaemonLaunchctl
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
		return "service = {\n\tstate = exited\n}", nil
	}
	loaded, running, err := inspectLaunchAgentState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !loaded || running {
		t.Fatalf("exited job 应为 loaded 但非 running：loaded=%t running=%t", loaded, running)
	}

	sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
		return "service = {\n\tstate = running\n}", nil
	}
	loaded, running, err = inspectLaunchAgentState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !loaded || !running {
		t.Fatalf("running job 状态解析错误：loaded=%t running=%t", loaded, running)
	}

	sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
		return "", fmt.Errorf("not loaded")
	}
	loaded, running, err = inspectLaunchAgentState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if loaded || running {
		t.Fatalf("launchctl print 失败时应为未加载：loaded=%t running=%t", loaded, running)
	}

	sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
		return "", fmt.Errorf("permission denied")
	}
	if _, _, err := inspectLaunchAgentState(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("非 not-loaded 的 launchctl 错误必须上报：%v", err)
	}
}

func TestRemoveSharedDaemonLaunchAgentKeepsLoadedJobWithoutPlist(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	loaded := true
	bootoutCalls := 0
	originalLaunchctl := sharedDaemonLaunchctl
	sharedDaemonLaunchctl = func(_ context.Context, arguments ...string) (string, error) {
		switch arguments[0] {
		case "print":
			if loaded {
				return "service = {\n\tstate = exited\n}", nil
			}
			return "", fmt.Errorf("no such service")
		case "bootout":
			bootoutCalls++
			loaded = false
			return "", nil
		default:
			return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
		}
	}
	t.Cleanup(func() { sharedDaemonLaunchctl = originalLaunchctl })

	if err := RemoveSharedDaemonLaunchAgent(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !loaded || bootoutCalls != 0 {
		t.Fatalf("磁盘 plist 缺失时只删除未来入口，不能 bootout 当前 job：loaded=%t bootoutCalls=%d", loaded, bootoutCalls)
	}
}

func TestResolveSharedDaemonCodexBinRequiresExecutable(t *testing.T) {
	dir := t.TempDir()
	plain := filepath.Join(dir, "codex")
	if err := os.WriteFile(plain, []byte("not executable"), 0o644); err != nil {
		t.Fatalf("写入文件失败：%v", err)
	}
	if _, err := resolveSharedDaemonCodexBin(plain); err == nil {
		t.Fatal("不可执行的 codex 必须报错")
	}
	if _, err := resolveSharedDaemonCodexBin(dir); err == nil {
		t.Fatal("目录不能被当成 codex")
	}

	executable := writeFakeCodexBin(t, dir, "codex-real")
	resolved, err := resolveSharedDaemonCodexBin(executable)
	if err != nil {
		t.Fatalf("解析可执行 codex 失败：%v", err)
	}
	expected, err := filepath.EvalSymlinks(executable)
	if err != nil {
		t.Fatalf("解析测试 codex 真实路径失败：%v", err)
	}
	if resolved != expected {
		t.Fatalf("解析结果不一致：got=%s want=%s", resolved, expected)
	}
}

func TestSharedDaemonLaunchAgentEnvDropsDesktopKeys(t *testing.T) {
	values := sharedDaemonLaunchAgentEnv(map[string]string{
		"CODEX_HOME":              "/tmp/.codex",
		LocalDaemonEnvironmentKey: "1",
		"CODEX_APP_SERVER_WS_URL": "ws://127.0.0.1:4222",
		"  ":                      "ignored",
	})
	if values["CODEX_HOME"] != "/tmp/.codex" {
		t.Fatalf("CODEX_HOME 丢失：%v", values)
	}
	if value, ok := values[LocalDaemonEnvironmentKey]; !ok || value != "" {
		t.Fatalf("Desktop transport 开关必须被空值覆盖：%v", values)
	}
	if value, ok := values["CODEX_APP_SERVER_WS_URL"]; !ok || value != "" {
		t.Fatalf("Desktop 外部 WS 地址必须被空值覆盖：%v", values)
	}
	if values["PATH"] == "" {
		t.Fatalf("launchd 不做 PATH 查找，必须给出默认 PATH：%v", values)
	}
	if !strings.Contains(values["PATH"], "/opt/homebrew/bin") {
		t.Fatalf("Apple Silicon Homebrew 工具目录必须进入默认 PATH：%v", values)
	}
}

// 官方 `daemon stop` 不删除 socket 文件；stale socket 必须被判为未就绪，
// 否则启动失败会被误报成成功。
func TestSharedDaemonSocketAcceptsConnectionRejectsStaleSocket(t *testing.T) {
	// sockaddr_un.sun_path 在 Darwin 只有 104 字节，t.TempDir() 的 /var/folders
	// 路径会直接 bind 失败，这里显式用短路径。
	dir, err := os.MkdirTemp("/tmp", "mimi-sock-")
	if err != nil {
		t.Fatalf("创建测试目录失败：%v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "app.sock")

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("创建测试 socket 失败：%v", err)
	}
	if !sharedDaemonSocketAcceptsConnection(socketPath) {
		listener.Close()
		t.Fatal("正在监听的 socket 应判为就绪")
	}

	// 保留 socket 文件再关闭监听，复现官方 daemon stop 之后的现场。
	unixListener, ok := listener.(*net.UnixListener)
	if !ok {
		listener.Close()
		t.Fatal("期望 UnixListener")
	}
	unixListener.SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		t.Fatalf("关闭监听失败：%v", err)
	}
	if info, statErr := os.Lstat(socketPath); statErr != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("stale socket 文件应保留：%v", statErr)
	}
	if sharedDaemonSocketAcceptsConnection(socketPath) {
		t.Fatal("stale socket 必须判为未就绪")
	}

	if sharedDaemonSocketAcceptsConnection(filepath.Join(dir, "missing.sock")) {
		t.Fatal("不存在的 socket 必须判为未就绪")
	}
}

func TestStopSharedDaemonAlreadyDisconnectedCanResumeWithoutSecondSignal(t *testing.T) {
	codexHome := sharedDaemonTestHome(t)
	socketPath, err := LocalDaemonSocketPath(map[string]string{"CODEX_HOME": codexHome})
	if err != nil {
		t.Fatal(err)
	}
	// 故意传入不存在的 CLI；如果代码仍调用 lifecycle version，
	// 本测试必然失败。无 listener 表示上一次的唯一 TERM 已经
	// 完成，重试只应进入稳定断开确认，不再 stop/signal。
	options := LocalDaemonOptions{
		CodexBin: filepath.Join(t.TempDir(), "missing-codex"),
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	owner := SharedDaemonOwnerStatus{
		Installed:         true,
		Loaded:            true,
		Secure:            true,
		MigrationRequired: true,
	}
	if err := stopSharedDaemon(context.Background(), options, owner); err != nil {
		t.Fatalf("已断开时重试不应再要求 lifecycle：%v", err)
	}
	started := time.Now()
	if err := waitForSharedDaemonStopped(context.Background(), socketPath); err != nil {
		t.Fatalf("稳定断开确认失败：%v", err)
	}
	if time.Since(started) < sharedDaemonStoppedConfirmationWindow {
		t.Fatal("不可连状态必须持续一个确认窗口后才允许 kickstart")
	}
}

func TestKickstartSharedDaemonFailsClosedWhenDesktopIsRunningOrUnknown(t *testing.T) {
	tests := []struct {
		name        string
		desktop     func(context.Context) (bool, error)
		wantMessage string
	}{
		{
			name:        "running",
			desktop:     func(context.Context) (bool, error) { return true, nil },
			wantMessage: "重新打开",
		},
		{
			name:        "query failure",
			desktop:     func(context.Context) (bool, error) { return false, errors.New("LaunchServices unavailable") },
			wantMessage: "确认 Codex Desktop 已退出失败",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			originalDesktop := sharedDaemonDesktopRunning
			originalLaunchctl := sharedDaemonLaunchctl
			launchctlCalls := 0
			sharedDaemonDesktopRunning = test.desktop
			sharedDaemonLaunchctl = func(context.Context, ...string) (string, error) {
				launchctlCalls++
				return "", nil
			}
			t.Cleanup(func() {
				sharedDaemonDesktopRunning = originalDesktop
				sharedDaemonLaunchctl = originalLaunchctl
			})

			err := kickstartSharedDaemon(context.Background())
			if err == nil || !strings.Contains(err.Error(), test.wantMessage) || launchctlCalls != 0 {
				t.Fatalf("最终 Desktop guard 必须阻止 kickstart：err=%v calls=%d", err, launchctlCalls)
			}
		})
	}
}

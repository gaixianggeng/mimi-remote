//go:build darwin

package appserver

import (
	"bytes"
	"context"
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
	home, err := os.MkdirTemp("/tmp", "mimi-owner-")
	if err != nil {
		t.Fatalf("创建短测试 Home 失败：%v", err)
	}
	t.Cleanup(func() { os.RemoveAll(home) })
	for _, name := range []string{".codex", "other-codex"} {
		if err := os.MkdirAll(filepath.Join(home, name), 0o700); err != nil {
			t.Fatalf("创建测试 CODEX_HOME 失败：%v", err)
		}
	}
	return home
}

func TestRenderSharedDaemonLaunchAgentExecsOfficialCodexDirectly(t *testing.T) {
	rendered, err := renderSharedDaemonLaunchAgent(
		"/opt/codex bin/codex",
		map[string]string{"CODEX_HOME": "/Users/tester/.codex"},
		"/Users/tester/Library/Logs/mimi-remote/codex-shared-daemon.log",
	)
	if err != nil {
		t.Fatalf("渲染 plist 失败：%v", err)
	}
	content := string(rendered)

	if strings.Contains(content, "<string>/bin/sh</string>") || strings.Contains(content, "exec &#34;") {
		t.Fatalf("plist 不能引入 shell 责任主体：\n%s", content)
	}
	if !strings.Contains(content, "<string>/opt/codex bin/codex</string>") {
		t.Fatalf("plist 必须使用绝对 codex 路径：\n%s", content)
	}
	for _, argument := range []string{"app-server", "daemon", "start"} {
		if !strings.Contains(content, "<string>"+argument+"</string>") {
			t.Fatalf("plist 缺少官方 daemon 参数 %s：\n%s", argument, content)
		}
	}
	if !strings.Contains(content, "<key>RunAtLoad</key>\n\t<true/>") {
		t.Fatalf("plist 必须覆盖登录冷启动：\n%s", content)
	}
	if !strings.Contains(content, "<key>KeepAlive</key>\n\t<false/>") {
		t.Fatalf("一次性控制命令不能被 launchd 反复重启：\n%s", content)
	}
	if !strings.Contains(content, "<key>Umask</key>\n\t<integer>63</integer>") {
		t.Fatalf("LaunchAgent 日志必须只允许当前用户读取：\n%s", content)
	}
	if !strings.Contains(content, "<key>CODEX_HOME</key>\n\t\t<string>/Users/tester/.codex</string>") {
		t.Fatalf("plist 必须固定 CODEX_HOME：\n%s", content)
	}
	for _, key := range sharedDaemonStrippedEnvKeys {
		// 空值覆盖 launchd 用户域中 Desktop 写入的值，同时避免 shell wrapper。
		emptyEntry := "<key>" + key + "</key>\n\t\t<string></string>"
		if !strings.Contains(content, emptyEntry) {
			t.Fatalf("plist 必须以空值覆盖 Desktop 专属变量 %s：\n%s", key, content)
		}
	}
}

func TestRenderSharedDaemonLaunchAgentEscapesXML(t *testing.T) {
	rendered, err := renderSharedDaemonLaunchAgent(
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
	if _, err := renderSharedDaemonLaunchAgent("  ", nil, ""); err == nil {
		t.Fatal("空 codex 路径必须报错")
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
		!status.Changed || !status.MigrationRequired {
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

func TestFinalizedStableOwnerRecoveryClearsOldMigrationMarker(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	if err := writeSharedDaemonMigrationFlag(); err != nil {
		t.Fatal(err)
	}
	status := LocalDaemonStatus{Started: true}
	owner := SharedDaemonOwnerStatus{Installed: true, MigrationRequired: true}
	if err := finalizeRecoveredSharedDaemonMigration(&status, &owner, true); err != nil {
		t.Fatal(err)
	}
	if owner.MigrationRequired {
		t.Fatal("稳定 owner 本次启动并验证 daemon 后应清除内存迁移状态")
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || required {
		t.Fatalf("稳定 owner 恢复完成后应清除持久 marker：required=%t err=%v", required, err)
	}
}

func TestOwnerChangeKeepsMigrationMarkerForExplicitApply(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	if err := writeSharedDaemonMigrationFlag(); err != nil {
		t.Fatal(err)
	}
	status := LocalDaemonStatus{Started: true}
	owner := SharedDaemonOwnerStatus{Installed: true, Changed: true, MigrationRequired: true}
	if err := finalizeRecoveredSharedDaemonMigration(&status, &owner, true); err != nil {
		t.Fatal(err)
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || !required {
		t.Fatalf("owner 本次也变化时必须保留显式迁移与事务回滚边界：required=%t err=%v", required, err)
	}
}

func TestSocketShortCircuitCannotClearMigrationMarker(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	if err := writeSharedDaemonMigrationFlag(); err != nil {
		t.Fatal(err)
	}
	status := LocalDaemonStatus{Started: true}
	owner := SharedDaemonOwnerStatus{Installed: true, MigrationRequired: true}
	if err := finalizeRecoveredSharedDaemonMigration(&status, &owner, false); err != nil {
		t.Fatal(err)
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || !required {
		t.Fatalf("未实际 kickstart 时不能用 Started 误清 marker：required=%t err=%v", required, err)
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

func TestRemoveSharedDaemonLaunchAgentBootsOutLoadedJobWithoutPlist(t *testing.T) {
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
	if loaded || bootoutCalls != 1 {
		t.Fatalf("磁盘 plist 缺失也必须清理已加载 job：loaded=%t bootoutCalls=%d", loaded, bootoutCalls)
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
	if resolved != executable {
		t.Fatalf("解析结果不一致：%s", resolved)
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

func TestWaitForSharedDaemonStoppedResetsConfirmationAfterReconnect(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mimi-stop-flap-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "app.sock")
	ready := make(chan error, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		// 先给 wait loop 一个短暂不可连窗口，但尚未达到
		// 500 ms 的稳定确认条件。
		time.Sleep(200 * time.Millisecond)
		listener, listenErr := net.Listen("unix", socketPath)
		ready <- listenErr
		if listenErr != nil {
			return
		}
		time.Sleep(300 * time.Millisecond)
		_ = listener.Close()
	}()

	started := time.Now()
	if err := waitForSharedDaemonStopped(context.Background(), socketPath); err != nil {
		t.Fatalf("断开抖动确认失败：%v", err)
	}
	listenErr := <-ready
	<-done
	if listenErr != nil {
		t.Fatalf("创建中途恢复 listener 失败：%v", listenErr)
	}
	// 200 ms 后重连、300 ms 后再断开，之后还必须重新
	// 等满 500 ms。如果没有重置 disconnectedSince，会在约 500 ms 时错误返回。
	if elapsed := time.Since(started); elapsed < 850*time.Millisecond {
		t.Fatalf("中途重连后必须重新计算稳定断开窗口：elapsed=%s", elapsed)
	}
}

func TestStopUnmanagedSharedDaemonRequiresDesktopStopped(t *testing.T) {
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return true, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				t.Fatal("Desktop 运行时不应读取或终止 socket owner")
				return sharedDaemonListenerProcess{}, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "仍在运行") || termCalls != 0 {
		t.Fatalf("Desktop 未退出必须 fail closed：err=%v term=%d", err, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonSignalsOneStrictlyMatchedProcess(t *testing.T) {
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex -c features.code_mode_host=true app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	inspectCalls := 0
	desktopChecks := 0
	var signaled []int
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { desktopChecks++; return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				return process, nil
			},
			signalTERM: func(pid int) error { signaled = append(signaled, pid); return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err != nil {
		t.Fatalf("严格匹配的原生 SSH daemon 应允许一次 TERM：%v", err)
	}
	if desktopChecks != 2 || inspectCalls != 2 || len(signaled) != 1 || signaled[0] != process.PID {
		t.Fatalf("接管必须两次确认 Desktop、双重确认 PID 且只 TERM 一次：desktop=%d inspect=%d signaled=%v", desktopChecks, inspectCalls, signaled)
	}
}

func TestStopUnmanagedSharedDaemonRejectsDesktopReopenedBeforeSignal(t *testing.T) {
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	desktopChecks := 0
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) {
				desktopChecks++
				return desktopChecks == 2, nil
			},
			inspect:    func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "重新打开") || desktopChecks != 2 || termCalls != 0 {
		t.Fatalf("Desktop 在信号前重开时必须 fail closed：err=%v checks=%d term=%d", err, desktopChecks, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsFinalDesktopCheckFailure(t *testing.T) {
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	desktopChecks := 0
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) {
				desktopChecks++
				if desktopChecks == 2 {
					return false, fmt.Errorf("查询失败")
				}
				return false, nil
			},
			inspect:    func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "信号前再次确认") || termCalls != 0 {
		t.Fatalf("Desktop 最终检查失败时必须 fail closed：err=%v term=%d", err, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsUnsafeListener(t *testing.T) {
	base := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex -c features.code_mode_host=true app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	tests := []struct {
		name    string
		mutate  func(*sharedDaemonListenerProcess)
		message string
	}{
		{name: "wrong uid", mutate: func(p *sharedDaemonListenerProcess) { p.UID = 502 }, message: "不属于当前用户"},
		{name: "wrong executable", mutate: func(p *sharedDaemonListenerProcess) { p.Executable = "/tmp/foreign" }, message: "不是官方 managed standalone"},
		{name: "wrong argv", mutate: func(p *sharedDaemonListenerProcess) { p.Command = "codex app-server --listen ws://127.0.0.1:4222" }, message: "命令行不符合"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			process := base
			test.mutate(&process)
			termCalls := 0
			err := stopUnmanagedSharedDaemonWithHooks(
				context.Background(),
				"/tmp/app.sock",
				"/tmp/codex-real",
				unmanagedSharedDaemonHooks{
					desktopRunning: func(context.Context) (bool, error) { return false, nil },
					inspect:        func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
					signalTERM:     func(int) error { termCalls++; return nil },
					currentUID:     func() int { return 501 },
				},
			)
			if err == nil || !strings.Contains(err.Error(), test.message) || termCalls != 0 {
				t.Fatalf("不安全 listener 必须拒绝：err=%v term=%d", err, termCalls)
			}
		})
	}
}

func TestStopUnmanagedSharedDaemonRejectsPIDReuseBeforeSignal(t *testing.T) {
	first := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	second := first
	second.StartSec++
	inspectCalls := 0
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				if inspectCalls == 1 {
					return first, nil
				}
				return second, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "发生变化") || termCalls != 0 {
		t.Fatalf("PID/start-time 复用必须在 TERM 前停止：err=%v term=%d", err, termCalls)
	}
}

func TestDirectUnixAppServerCommandAcceptsNativeNULSeparatedArgv(t *testing.T) {
	command := strings.Join([]string{
		"codex",
		"-c",
		"features.code_mode_host=true",
		"app-server",
		"--listen",
		"unix://",
	}, "\x00")
	if !isDirectUnixAppServerCommand(command) {
		t.Fatal("原生 procargs2 argv 应识别为直接 Unix app-server")
	}
	if isDirectUnixAppServerCommand(strings.Replace(command, "unix://", "ws://127.0.0.1:4222", 1)) {
		t.Fatal("非 Unix transport 必须拒绝")
	}
	if isDirectUnixAppServerCommand("codex app-server daemon start --listen unix://") {
		t.Fatal("官方 daemon 控制命令不能当成 SSH 直接 listener 接管")
	}
	if isDirectUnixAppServerCommand("codex app-server proxy --listen unix://") {
		t.Fatal("官方 proxy 不能当成 SSH 直接 listener 接管")
	}
}

func TestSharedDaemonSocketPeerAndProcIdentityUseNativeDarwinMetadata(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mimi-peer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "app.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	accepted := make(chan net.Conn, 1)
	acceptErr := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			acceptErr <- err
			return
		}
		accepted <- conn
	}()

	pid, uid, err := sharedDaemonSocketPeer(context.Background(), socketPath)
	if err != nil {
		t.Fatalf("读取本机 Unix peer 失败：%v", err)
	}
	select {
	case conn := <-accepted:
		conn.Close()
	case err := <-acceptErr:
		t.Fatalf("接受测试连接失败：%v", err)
	case <-time.After(time.Second):
		t.Fatal("测试 listener 未收到连接")
	}
	if pid != os.Getpid() || uid != os.Getuid() {
		t.Fatalf("peer 身份不匹配：pid=%d/%d uid=%d/%d", pid, os.Getpid(), uid, os.Getuid())
	}
	executable, arguments, err := sharedDaemonProcessArguments(pid)
	if err != nil {
		t.Fatalf("读取原生 procargs2 失败：%v", err)
	}
	if !filepath.IsAbs(executable) || len(arguments) == 0 {
		t.Fatalf("进程身份缺少绝对 executable 或 argv：exe=%q argv=%v", executable, arguments)
	}
}

func TestValidatePrivateSharedDaemonSocketRequiresModeAndOwner(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mimi-private-sock-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "app.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(socketPath, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := validatePrivateSharedDaemonSocket(socketPath, os.Getuid()); err != nil {
		t.Fatalf("当前用户私有 socket 应通过：%v", err)
	}
	if err := os.Chmod(socketPath, 0o666); err != nil {
		t.Fatal(err)
	}
	if err := validatePrivateSharedDaemonSocket(socketPath, os.Getuid()); err == nil {
		t.Fatal("公开 socket 必须拒绝接管")
	}
}

func TestLiveSharedDaemonListenerIdentity(t *testing.T) {
	socketPath := strings.TrimSpace(os.Getenv("MIMI_LIVE_SHARED_DAEMON_SOCKET"))
	if socketPath == "" {
		t.Skip("仅在显式提供真实共享 socket 时运行")
	}
	process, err := inspectSharedDaemonListenerProcess(context.Background(), socketPath)
	if err != nil {
		t.Fatalf("读取真实共享 daemon 身份失败：%v", err)
	}
	if process.PID <= 1 || process.UID != os.Getuid() || process.StartSec <= 0 ||
		!filepath.IsAbs(process.Executable) || !isDirectUnixAppServerCommand(process.Command) {
		t.Fatalf("真实共享 daemon 身份不完整或不是直接 Unix app-server：%+v", process)
	}
}

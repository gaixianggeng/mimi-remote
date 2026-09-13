package setup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
)

func TestConfigureClaudeAutoEnablesReadyRuntimeAndPreservesConfig(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	configPath := writeClaudeConfigurationFixture(t, 0, false)

	result, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationAuto,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || !result.Changed || !result.RestartRequired {
		t.Fatalf("就绪环境应自动开启并要求重启：%+v", result)
	}
	if result.Preference != ClaudeActivationAuto || result.Reason != "ready" {
		t.Fatalf("自动检测结果异常：%+v", result)
	}

	document := readClaudeConfigurationFixture(t, configPath)
	claude := document["claude"].(map[string]any)
	if claude["enabled"] != true || claude["activation"] != "auto" {
		t.Fatalf("Claude 开关未按 auto 结果写入：%v", claude)
	}
	if claude["future_option"] != "keep" || document["future_top_level"] == nil {
		t.Fatalf("未知配置字段不应丢失：%v", document)
	}
	env := claude["env"].(map[string]any)
	if env["FUTURE_ENV"] != "keep" || env[claudeBinaryEnvKey] == "" {
		t.Fatalf("Claude env 应保留未知字段并记录 CLI 绝对路径：%v", env)
	}
	info, err := os.Stat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("配置权限必须保持 0600，实际 %v", info.Mode().Perm())
	}
}

func TestConfigureClaudeAutoKeepsRuntimeOffWhenSignedOut(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	configPath := writeClaudeConfigurationFixture(t, 1, false)

	result, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationAuto,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || result.Available || result.Reason != "claude_signed_out" {
		t.Fatalf("未登录时必须保持关闭并给出明确原因：%+v", result)
	}
	document := readClaudeConfigurationFixture(t, configPath)
	claude := document["claude"].(map[string]any)
	if claude["enabled"] != false || claude["activation"] != "auto" {
		t.Fatalf("未登录时应保持 auto + disabled：%v", claude)
	}
}

func TestConfigureClaudeExplicitDisableSurvivesLaterAutoDetection(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	configPath := writeClaudeConfigurationFixture(t, 0, true)

	disabled, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationDisabled,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if disabled.Enabled || disabled.Preference != ClaudeActivationDisabled {
		t.Fatalf("显式关闭结果异常：%+v", disabled)
	}

	automatic, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationAuto,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if automatic.Enabled || automatic.Preference != ClaudeActivationDisabled ||
		automatic.Reason != "disabled_by_user" {
		t.Fatalf("后续启动不得覆盖用户显式关闭：%+v", automatic)
	}
}

func TestConfigureClaudeLegacyEnabledFailsClosedButPreservesExplicitChoice(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	document := map[string]any{
		"auth": map[string]any{"token": "0123456789abcdef0123456789abcdef"},
		"claude": map[string]any{
			"enabled":                true,
			"bridge_bin":             filepath.Join(t.TempDir(), "missing-bridge"),
			"max_concurrent_bridges": 3,
		},
	}
	writeClaudeDocument(t, configPath, document)

	result, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationAuto,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || result.Preference != ClaudeActivationEnabled ||
		!result.RestartRequired || result.Reason != "bridge_missing" {
		t.Fatalf("旧版手工偏好应保留，但运行状态必须 fail closed：%+v", result)
	}
	document = readClaudeConfigurationFixture(t, configPath)
	claude := document["claude"].(map[string]any)
	if claude["enabled"] != false || claude["activation"] != "enabled" {
		t.Fatalf("启动检测失败后应关闭运行状态并保留明确偏好：%v", claude)
	}
}

func TestConfigureClaudeFailedManualEnableDoesNotChangeConfig(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	configPath := writeClaudeConfigurationFixture(t, 1, false)
	before, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}

	result, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationEnabled,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if result.Changed || result.Enabled || result.Reason != "claude_signed_out" {
		t.Fatalf("前置条件失败时不应把设置显示为成功：%+v", result)
	}
	if string(before) != string(after) {
		t.Fatal("手动启用失败时配置文件不应发生变化")
	}
}

func TestConfigureClaudeRestoreWritesExactPreviousState(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	configPath := writeClaudeConfigurationFixture(t, 0, true)
	restoreEnabled := false

	result, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationAuto,
		&restoreEnabled,
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || result.Preference != ClaudeActivationAuto ||
		result.Reason != "restored" {
		t.Fatalf("回滚必须精确恢复 auto + disabled：%+v", result)
	}
}

func TestConfigureClaudeReplacesStaleConfiguredClaudeBin(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	// 夹具里已配置的 CLI 是 2.1.220；官方安装器的 ~/.local/bin/claude 更新。
	configPath := writeClaudeConfigurationFixture(t, 0, false)
	newer := filepath.Join(os.Getenv("HOME"), ".local", "bin", "claude")
	writeClaudeCLIFixture(t, newer, "2.1.270 (Claude Code)", true)

	result, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationAuto,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || !result.RestartRequired {
		t.Fatalf("发现更新的 CLI 时应启用并要求重启：%+v", result)
	}
	if result.ClaudeBin != newer || result.ClaudeVersion != "2.1.270" {
		t.Fatalf("应改用版本最高的候选：bin=%q version=%q", result.ClaudeBin, result.ClaudeVersion)
	}
	document := readClaudeConfigurationFixture(t, configPath)
	claude := document["claude"].(map[string]any)
	env := claude["env"].(map[string]any)
	if env[claudeBinaryEnvKey] != newer || env["FUTURE_ENV"] != "keep" {
		t.Fatalf("陈旧路径应被替换且其他 env 字段保留：%v", env)
	}
	if claude["future_option"] != "keep" || document["future_top_level"] == nil {
		t.Fatalf("未知配置字段不应丢失：%v", document)
	}
	info, err := os.Stat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("配置权限必须保持 0600，实际 %v", info.Mode().Perm())
	}

	again, err := ConfigureClaude(
		context.Background(),
		configPath,
		ClaudeActivationAuto,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if again.Changed || again.RestartRequired || again.ClaudeBin != newer {
		t.Fatalf("已是最新候选时下次启动不应再改配置：%+v", again)
	}
}

func TestResolveClaudeBinPrefersHighestVersionAcrossCandidates(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	home := t.TempDir()
	pathDir := filepath.Join(t.TempDir(), "homebrew-bin")
	t.Setenv("HOME", home)
	t.Setenv("PATH", pathDir)
	brew := filepath.Join(pathDir, "claude")
	native := filepath.Join(home, ".local", "bin", "claude")
	npm := filepath.Join(home, ".npm-global", "bin", "claude")
	writeClaudeCLIFixture(t, brew, "2.1.224 (Claude Code)", true)
	writeClaudeCLIFixture(t, native, "2.1.270 (Claude Code)", true)
	writeClaudeCLIFixture(t, npm, "2.1.224 (Claude Code)", true)
	environment := claudeCommandEnvironment(nil)

	// 已配置路径已不可用：回退到候选，并在候选里择优而不是取 PATH 上的第一个。
	resolved, err := resolveClaudeBin(context.Background(), filepath.Join(home, "gone", "claude"), environment)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.path != native || resolved.version != "2.1.270" {
		t.Fatalf("应选择版本最高的候选：%+v", resolved)
	}

	// 已配置路径落后于其他候选时同样被替换。
	resolved, err = resolveClaudeBin(context.Background(), brew, environment)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.path != native {
		t.Fatalf("已配置的旧版本不应继续优先：%+v", resolved)
	}

	// 同版本按候选顺序：已配置值仍排在 PATH 与默认安装位置之前。
	if err := os.Remove(native); err != nil {
		t.Fatal(err)
	}
	resolved, err = resolveClaudeBin(context.Background(), npm, environment)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.path != npm || resolved.version != "2.1.224" {
		t.Fatalf("同版本时应保留已配置路径：%+v", resolved)
	}
}

func TestResolveClaudeBinDoesNotPreferUnparseableVersion(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	home := t.TempDir()
	pathDir := filepath.Join(t.TempDir(), "bin")
	t.Setenv("HOME", home)
	t.Setenv("PATH", pathDir)
	configured := filepath.Join(home, "configured", "claude")
	onPath := filepath.Join(pathDir, "claude")
	writeClaudeCLIFixture(t, configured, "claude dev build", true)
	writeClaudeCLIFixture(t, onPath, "2.1.100 (Claude Code)", true)
	environment := claudeCommandEnvironment(nil)

	resolved, err := resolveClaudeBin(context.Background(), configured, environment)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.path != onPath || resolved.version != "2.1.100" {
		t.Fatalf("版本无法解析的候选不得胜过可解析的候选：%+v", resolved)
	}

	// 全部候选都无法解析时退回第一个可启动候选，版本留空交给上层报告 claude_version_unknown。
	writeClaudeCLIFixture(t, onPath, "nightly", true)
	resolved, err = resolveClaudeBin(context.Background(), configured, environment)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.path != configured || resolved.version != "" {
		t.Fatalf("全部无法解析时应退回首个候选且不伪造版本：%+v", resolved)
	}
}

func TestParseClaudeActivationPreferenceRejectsUnknownValue(t *testing.T) {
	if _, err := ParseClaudeActivationPreference("sometimes"); err == nil {
		t.Fatal("未知 Claude 启用策略必须拒绝")
	}
}

func TestParseClaudeAuthStatusRequiresExplicitLoggedInField(t *testing.T) {
	loggedIn, ok := parseClaudeAuthStatus([]byte(`{"loggedIn":true,"authMethod":"claude.ai"}`))
	if !ok || !loggedIn {
		t.Fatal("有效 Claude auth status 应解析为已登录")
	}
	if _, ok := parseClaudeAuthStatus([]byte(`{"authMethod":"claude.ai"}`)); ok {
		t.Fatal("缺少 loggedIn 时不得猜测登录状态")
	}
	if _, ok := parseClaudeAuthStatus([]byte(`not-json`)); ok {
		t.Fatal("无效输出不得误报为已登出")
	}
}

func TestProbeClaudeAuthStatusDoesNotTurnTimeoutIntoSignedOut(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	claude := filepath.Join(t.TempDir(), "claude")
	writeExecutableFixture(t, claude, "if [ \"$1\" = \"auth\" ]; then printf '%s\\n' '{\"loggedIn\":false}'; exec sleep 10; fi\n")

	loggedIn, err := probeClaudeAuthStatus(
		context.Background(),
		claude,
		claudeCommandEnvironment(nil),
		50*time.Millisecond,
	)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("输出 false 后超时必须保留 timeout 分类，got=%v", err)
	}
	if loggedIn == nil || *loggedIn {
		t.Fatalf("诊断仍应保留进程输出的 loggedIn=false，got=%v", loggedIn)
	}
}

func TestProbeClaudeAuthStatusRejectsUnexpectedExit(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix 可执行脚本模拟 Claude CLI")
	}
	claude := filepath.Join(t.TempDir(), "claude")
	writeExecutableFixture(t, claude, "if [ \"$1\" = \"auth\" ]; then printf '%s\\n' '{\"loggedIn\":false}'; exit 2; fi\n")

	loggedIn, err := probeClaudeAuthStatus(
		context.Background(),
		claude,
		claudeCommandEnvironment(nil),
		time.Second,
	)
	if err == nil {
		t.Fatal("非约定退出码不得被误报为正常未登录")
	}
	if loggedIn == nil || *loggedIn {
		t.Fatalf("诊断仍应保留进程输出的 loggedIn=false，got=%v", loggedIn)
	}
}

func TestProbeClaudeAuthStatusDoesNotTurnSignalExitIntoSignedOut(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("本测试使用 Unix signal 模拟 Claude CLI 异常退出")
	}
	claude := filepath.Join(t.TempDir(), "claude")
	writeExecutableFixture(t, claude, "if [ \"$1\" = \"auth\" ]; then printf '%s\\n' '{\"loggedIn\":false}'; kill -TERM $$; fi\n")

	loggedIn, err := probeClaudeAuthStatus(
		context.Background(),
		claude,
		claudeCommandEnvironment(nil),
		time.Second,
	)
	if err == nil {
		t.Fatal("signal 终止不得被误报为正常未登录")
	}
	if loggedIn == nil || *loggedIn {
		t.Fatalf("诊断仍应保留进程输出的 loggedIn=false，got=%v", loggedIn)
	}
}

func writeClaudeConfigurationFixture(t *testing.T, authExit int, enabled bool) string {
	t.Helper()
	root := t.TempDir()
	// CLI 择优会扫描 $HOME 下的默认安装位置和 PATH；隔离两者，避免开发机上真实安装的
	// claude 版本更高而抢过夹具。夹具脚本只用 shell 内建命令，保留系统目录仅为兜底。
	t.Setenv("HOME", root)
	t.Setenv("PATH", filepath.Join(root, "bin")+string(os.PathListSeparator)+"/usr/bin:/bin")
	bridge := filepath.Join(root, "alleycat-claude-bridge")
	claude := filepath.Join(root, "claude")
	// 测试夹具跟随 agentd 的最低兼容版本，避免能力门禁升级后测试仍伪装成旧 bridge。
	writeExecutableFixture(t, bridge, "printf 'alleycat-claude-bridge "+claudebridge.MinimumVersion+"\\n'\n")
	writeClaudeCLIFixture(t, claude, "claude 2.1.220", authExit == 0)
	configPath := filepath.Join(root, "config.json")
	document := map[string]any{
		"auth": map[string]any{"token": "0123456789abcdef0123456789abcdef"},
		"claude": map[string]any{
			"enabled":    enabled,
			"bridge_bin": bridge,
			"env": map[string]any{
				claudeBinaryEnvKey: claude,
				"FUTURE_ENV":       "keep",
			},
			"max_concurrent_bridges": 3,
			"future_option":          "keep",
		},
		"future_top_level": map[string]any{"keep": true},
	}
	writeClaudeDocument(t, configPath, document)
	return configPath
}

// writeClaudeCLIFixture 写一个假 Claude CLI：--version 原样打印 versionLine，
// auth status 按 loggedIn 返回 Claude CLI 约定的 JSON 与退出码。
func writeClaudeCLIFixture(t *testing.T, path string, versionLine string, loggedIn bool) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	authExit := 0
	if !loggedIn {
		authExit = 1
	}
	writeExecutableFixture(t, path,
		"if [ \"$1\" = \"auth\" ]; then printf '%s\\n' '{\"loggedIn\":"+strconv.FormatBool(loggedIn)+"}'; exit "+strconv.Itoa(authExit)+"; fi\n"+
			"printf '%s\\n' '"+versionLine+"'\n")
}

func writeExecutableFixture(t *testing.T, path string, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o700); err != nil {
		t.Fatal(err)
	}
}

func writeClaudeDocument(t *testing.T, path string, document map[string]any) {
	t.Helper()
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readClaudeConfigurationFixture(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	document := map[string]any{}
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	return document
}

package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const deepSeekTestToken = "deepseek-startup-secret-never-output"

func TestConfigureDeepSeekConnectValidatesThenStoresPrivateManagedToken(t *testing.T) {
	configPath, original := writeDeepSeekConfigFixture(t, false, "", "")
	var probed deepSeekConnectionCandidate
	dependencies := deepSeekTestDependencies()
	dependencies.probe = func(_ context.Context, candidate deepSeekConnectionCandidate) error {
		probed = candidate
		return nil
	}

	result, err := configureDeepSeek(
		t.Context(),
		configPath,
		DeepSeekRuntimeConnect,
		"http://127.0.0.1:5173/?token="+deepSeekTestToken,
		dependencies,
	)
	if err != nil {
		t.Fatalf("connect 失败：%v", err)
	}
	if !result.Enabled || !result.Available || result.Discovered || !result.RestartRequired {
		t.Fatalf("connect 结果不符：%+v", result)
	}
	if probed.BaseURL != "http://127.0.0.1:5173" || probed.Token != deepSeekTestToken {
		t.Fatalf("预检候选不符：%+v", probed)
	}

	stored := readJSONDocument(t, configPath)
	var futureRoot map[string]bool
	if err := json.Unmarshal(stored["future_root"], &futureRoot); err != nil || !futureRoot["keep"] {
		t.Fatalf("未知根字段丢失：%s", stored["future_root"])
	}
	var deepSeek map[string]json.RawMessage
	if err := json.Unmarshal(stored["deepseek"], &deepSeek); err != nil {
		t.Fatal(err)
	}
	var futureDeepSeek map[string]string
	if err := json.Unmarshal(deepSeek["future_deepseek"], &futureDeepSeek); err != nil || futureDeepSeek["mode"] != "keep" {
		t.Fatalf("未知 DeepSeek 字段丢失：%s", deepSeek["future_deepseek"])
	}
	var enabled bool
	var autoDiscover bool
	var tokenPath, baseURL string
	_ = json.Unmarshal(deepSeek["enabled"], &enabled)
	_ = json.Unmarshal(deepSeek["auto_discover"], &autoDiscover)
	_ = json.Unmarshal(deepSeek["token_file"], &tokenPath)
	_ = json.Unmarshal(deepSeek["base_url"], &baseURL)
	if !enabled || autoDiscover || baseURL != probed.BaseURL || tokenPath != filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename) {
		t.Fatalf("DeepSeek 配置不符：%s", stored["deepseek"])
	}
	assertDeepSeekFile(t, tokenPath, []byte(deepSeekTestToken+"\n"), true)
	if bytes.Equal(original, mustReadFile(t, configPath)) {
		t.Fatal("成功 connect 应更新配置")
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), deepSeekTestToken) || strings.Contains(string(encoded), "?token=") {
		t.Fatalf("安全结果泄漏启动凭据：%s", encoded)
	}
}

func TestConfigureDeepSeekFailedProbeLeavesConfigAndTokenUntouched(t *testing.T) {
	configPath, original := writeDeepSeekConfigFixture(t, false, "", "")
	tokenPath := filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename)
	oldToken := []byte("old-token-byte-identical\n")
	if err := os.WriteFile(tokenPath, oldToken, 0o600); err != nil {
		t.Fatal(err)
	}
	dependencies := deepSeekTestDependencies()
	dependencies.probe = func(_ context.Context, candidate deepSeekConnectionCandidate) error {
		return errors.New("remote echoed " + candidate.Token)
	}

	result, err := configureDeepSeek(
		t.Context(), configPath, DeepSeekRuntimeConnect,
		"http://127.0.0.1:5173/?token="+deepSeekTestToken,
		dependencies,
	)
	if err != nil {
		t.Fatalf("预检失败应返回安全结果：%v", err)
	}
	if result.Available || result.Enabled || result.RestartRequired {
		t.Fatalf("预检失败状态不符：%+v", result)
	}
	if strings.Contains(result.Message, deepSeekTestToken) {
		t.Fatalf("预检失败消息泄漏 token：%q", result.Message)
	}
	assertDeepSeekFile(t, configPath, original, false)
	assertDeepSeekFile(t, tokenPath, oldToken, true)
}

func TestConfigureDeepSeekDiscoveredPIDRaceDoesNotCommit(t *testing.T) {
	configPath, original := writeDeepSeekConfigFixture(t, false, "", "")
	dependencies := deepSeekTestDependencies()
	dependencies.currentPID = func(context.Context) (int, error) { return 778, nil }

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeConnect, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if result.Available || !result.Discovered || result.RestartRequired {
		t.Fatalf("PID 变化必须拒绝提交：%+v", result)
	}
	assertDeepSeekFile(t, configPath, original, false)
	assertMissingDeepSeekPath(t, filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename))
}

func TestConfigureDeepSeekAutomaticConnectRecordsDiscoveryPreference(t *testing.T) {
	configPath, _ := writeDeepSeekConfigFixture(t, false, "", "")
	result, err := configureDeepSeek(
		t.Context(), configPath, DeepSeekRuntimeConnect, "", deepSeekTestDependencies(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Discovered || !result.Available {
		t.Fatalf("自动连接结果不符：%+v", result)
	}
	stored := readJSONDocument(t, configPath)
	var deepSeek map[string]json.RawMessage
	if err := json.Unmarshal(stored["deepseek"], &deepSeek); err != nil {
		t.Fatal(err)
	}
	var autoDiscover bool
	if err := json.Unmarshal(deepSeek["auto_discover"], &autoDiscover); err != nil || !autoDiscover {
		t.Fatalf("自动连接必须记录 auto_discover=true：%s", stored["deepseek"])
	}
}

func TestConfigureDeepSeekInspectIsReadOnly(t *testing.T) {
	configPath, original := writeDeepSeekConfigFixture(t, false, "", "")
	dependencies := deepSeekTestDependencies()

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeInspect, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || !result.Available || !result.Discovered || result.RestartRequired {
		t.Fatalf("inspect 结果不符：%+v", result)
	}
	assertDeepSeekFile(t, configPath, original, false)
	assertMissingDeepSeekPath(t, filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename))
}

func TestConfigureDeepSeekDisableOnlyChangesEnabled(t *testing.T) {
	configPath, _ := writeDeepSeekConfigFixture(
		t, true, "http://127.0.0.1:5173", filepath.Join(t.TempDir(), "external.token"),
	)
	before := readJSONDocument(t, configPath)
	var beforeDeepSeek map[string]json.RawMessage
	_ = json.Unmarshal(before["deepseek"], &beforeDeepSeek)

	result, err := configureDeepSeek(
		t.Context(), configPath, DeepSeekRuntimeDisabled, "", deepSeekTestDependencies(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || !result.RestartRequired {
		t.Fatalf("disabled 结果不符：%+v", result)
	}
	after := readJSONDocument(t, configPath)
	var afterDeepSeek map[string]json.RawMessage
	_ = json.Unmarshal(after["deepseek"], &afterDeepSeek)
	if len(beforeDeepSeek) != len(afterDeepSeek) {
		t.Fatalf("disabled 只能改 enabled，不得增删字段：before=%s after=%s", before["deepseek"], after["deepseek"])
	}
	for key, beforeValue := range beforeDeepSeek {
		if key == "enabled" {
			continue
		}
		if !bytes.Equal(beforeValue, afterDeepSeek[key]) {
			t.Fatalf("disabled 不得改 %s：before=%s after=%s", key, beforeValue, afterDeepSeek[key])
		}
	}
}

func TestConfigureDeepSeekFailedReplacementKeepsCurrentBaseURL(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	tokenPath := filepath.Join(dir, managedDeepSeekTokenFilename)
	writeDeepSeekConfigAtPath(t, configPath, true, "http://127.0.0.1:4000", tokenPath)
	if err := os.WriteFile(tokenPath, []byte("current-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dependencies := deepSeekTestDependencies()
	dependencies.probe = func(context.Context, deepSeekConnectionCandidate) error {
		return errors.New("probe failed")
	}

	result, err := configureDeepSeek(
		t.Context(), configPath, DeepSeekRuntimeConnect,
		"http://127.0.0.1:5000/?token="+deepSeekTestToken,
		dependencies,
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.BaseURL != "http://127.0.0.1:4000" || !result.Enabled || result.Available {
		t.Fatalf("失败候选不得覆盖当前连接结果：%+v", result)
	}
}

func TestConfigureDeepSeekRefreshNeverEnablesExplicitDisabled(t *testing.T) {
	configPath, original := writeDeepSeekConfigFixture(t, false, "", "")
	result, err := configureDeepSeek(
		t.Context(), configPath, DeepSeekRuntimeRefresh, "", deepSeekTestDependencies(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || result.RestartRequired || !result.Discovered || !result.Available {
		t.Fatalf("关闭状态 refresh 只应检测：%+v", result)
	}
	assertDeepSeekFile(t, configPath, original, false)
	assertMissingDeepSeekPath(t, filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename))
}

func TestConfigureDeepSeekRefreshUpdatesEnabledManagedConnection(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	tokenPath := filepath.Join(dir, managedDeepSeekTokenFilename)
	writeDeepSeekConfigAtPath(t, configPath, true, "http://127.0.0.1:4000", tokenPath)
	setDeepSeekAutoDiscover(t, configPath, true)
	if err := os.WriteFile(tokenPath, []byte("old-managed-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dependencies := deepSeekTestDependencies()

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeRefresh, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || !result.Discovered || !result.RestartRequired {
		t.Fatalf("managed refresh 结果不符：%+v", result)
	}
	assertDeepSeekFile(t, tokenPath, []byte(deepSeekTestToken+"\n"), true)
}

func TestConfigureDeepSeekManualConnectionIsNotReplacedByRefresh(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	tokenPath := filepath.Join(dir, managedDeepSeekTokenFilename)
	writeDeepSeekConfigAtPath(t, configPath, true, "http://127.0.0.1:4000", tokenPath)
	oldToken := []byte("manual-token\n")
	if err := os.WriteFile(tokenPath, oldToken, 0o600); err != nil {
		t.Fatal(err)
	}
	dependencies := deepSeekTestDependencies()
	var probed deepSeekConnectionCandidate
	dependencies.probe = func(_ context.Context, candidate deepSeekConnectionCandidate) error {
		probed = candidate
		return nil
	}

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeRefresh, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || result.Discovered || result.RestartRequired {
		t.Fatalf("手动连接 refresh 不得跟随发现服务：%+v", result)
	}
	if probed.BaseURL != "http://127.0.0.1:4000" || probed.Token != "manual-token" {
		t.Fatalf("refresh 应验证当前手动连接：%+v", probed)
	}
	assertDeepSeekFile(t, tokenPath, oldToken, true)
}

func TestConfigureDeepSeekRefreshDoesNotReplaceExternalTokenFile(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	externalTokenPath := filepath.Join(dir, "external.token")
	writeDeepSeekConfigAtPath(t, configPath, true, "http://127.0.0.1:4000", externalTokenPath)
	setDeepSeekAutoDiscover(t, configPath, true)
	oldToken := []byte("external-token\n")
	if err := os.WriteFile(externalTokenPath, oldToken, 0o600); err != nil {
		t.Fatal(err)
	}
	dependencies := deepSeekTestDependencies()
	dependencies.probe = func(_ context.Context, candidate deepSeekConnectionCandidate) error {
		if candidate.BaseURL != "http://127.0.0.1:4000" || candidate.Token != "external-token" {
			t.Fatalf("应验证外部配置而不是发现候选：%+v", candidate)
		}
		return nil
	}
	dependencies.discover = func(context.Context) (deepSeekConnectionCandidate, error) {
		t.Fatal("外部 token file 不应触发自动发现")
		return deepSeekConnectionCandidate{}, nil
	}

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeRefresh, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || result.RestartRequired {
		t.Fatalf("外部连接 refresh 只能验证：%+v", result)
	}
	assertDeepSeekFile(t, externalTokenPath, oldToken, true)
	assertMissingDeepSeekPath(t, filepath.Join(dir, managedDeepSeekTokenFilename))
}

func TestConfigureDeepSeekEnabledInspectShowsConfiguredConnection(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	tokenPath := filepath.Join(dir, managedDeepSeekTokenFilename)
	writeDeepSeekConfigAtPath(t, configPath, true, "http://127.0.0.1:4000", tokenPath)
	if err := os.WriteFile(tokenPath, []byte("configured-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dependencies := deepSeekTestDependencies()
	dependencies.probe = func(_ context.Context, candidate deepSeekConnectionCandidate) error {
		if candidate.BaseURL != "http://127.0.0.1:4000" || candidate.Token != "configured-token" {
			t.Fatalf("inspect 不得改探测另一个服务：%+v", candidate)
		}
		return nil
	}
	dependencies.discover = func(context.Context) (deepSeekConnectionCandidate, error) {
		t.Fatal("enabled inspect 不应运行自动发现")
		return deepSeekConnectionCandidate{}, nil
	}

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeInspect, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if result.BaseURL != "http://127.0.0.1:4000" || !result.Available || result.Discovered {
		t.Fatalf("enabled inspect 结果不符：%+v", result)
	}
}

func TestLoadDeepSeekConfigRejectsSecretBearingBaseURLWithoutEcho(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	secret := "must-not-echo"
	raw := []byte(`{"deepseek":{"enabled":false,"base_url":"http://127.0.0.1:5173/?token=` + secret + `"}}`)
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := loadDeepSeekConfigDocument(configPath)
	if err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("非法 base_url 应固定脱敏失败：%v", err)
	}
}

func TestConfigureDeepSeekCASConflictPreservesNewerConfigAndOldToken(t *testing.T) {
	configPath, _ := writeDeepSeekConfigFixture(t, false, "", "")
	tokenPath := filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename)
	oldToken := []byte("old-managed-token\n")
	if err := os.WriteFile(tokenPath, oldToken, 0o600); err != nil {
		t.Fatal(err)
	}
	newer := []byte("{\"newer\":true}\n")
	dependencies := deepSeekTestDependencies()
	dependencies.probe = func(context.Context, deepSeekConnectionCandidate) error {
		return os.WriteFile(configPath, newer, 0o600)
	}

	_, err := configureDeepSeek(
		t.Context(), configPath, DeepSeekRuntimeConnect,
		"http://127.0.0.1:5173/?token="+deepSeekTestToken,
		dependencies,
	)
	if err == nil || !strings.Contains(err.Error(), "其他进程修改") {
		t.Fatalf("CAS 冲突应明确失败：%v", err)
	}
	if strings.Contains(err.Error(), deepSeekTestToken) {
		t.Fatalf("CAS 错误泄漏 token：%v", err)
	}
	assertDeepSeekFile(t, configPath, newer, false)
	assertDeepSeekFile(t, tokenPath, oldToken, true)
}

func TestConfigureDeepSeekRepairsUnsafeManagedTokenMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 使用 ACL，不检查 POSIX mode")
	}
	configPath, _ := writeDeepSeekConfigFixture(t, false, "", "")
	startupURL := "http://127.0.0.1:5173/?token=" + deepSeekTestToken
	dependencies := deepSeekTestDependencies()
	if _, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeConnect, startupURL, dependencies); err != nil {
		t.Fatal(err)
	}
	tokenPath := filepath.Join(filepath.Dir(configPath), managedDeepSeekTokenFilename)
	if err := os.Chmod(tokenPath, 0o644); err != nil {
		t.Fatal(err)
	}
	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeConnect, startupURL, dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.RestartRequired {
		t.Fatalf("不安全 mode 不能走 no-op：%+v", result)
	}
	assertDeepSeekFile(t, tokenPath, []byte(deepSeekTestToken+"\n"), true)
}

func TestParseDeepSeekStartupURLRejectsUnsafeOrAmbiguousLinks(t *testing.T) {
	tests := []string{
		"",
		"not-a-url",
		"http://example.com:5173/?token=secret",
		"http://127.0.0.1:5173/?token=",
		"http://127.0.0.1:5173/?token=one&token=two",
		"http://127.0.0.1:5173/?token=one&extra=value",
		"http://user@127.0.0.1:5173/?token=one",
		"http://127.0.0.1:5173/?token=one%0Atwo",
		"http://127.0.0.1:5173/?token=one%00two",
		"http://127.0.0.1:5173/?token=" + strings.Repeat("x", maxDeepSeekTokenBytes+1),
	}
	for _, raw := range tests {
		if _, err := parseDeepSeekStartupURL(raw); err == nil {
			t.Fatalf("应拒绝不安全链接：%q", raw)
		}
	}
}

func deepSeekTestDependencies() deepSeekRuntimeDependencies {
	candidate := deepSeekConnectionCandidate{
		BaseURL: "http://127.0.0.1:5173",
		Token:   deepSeekTestToken,
		PID:     777,
	}
	return deepSeekRuntimeDependencies{
		discover:   func(context.Context) (deepSeekConnectionCandidate, error) { return candidate, nil },
		currentPID: func(context.Context) (int, error) { return candidate.PID, nil },
		probe:      func(context.Context, deepSeekConnectionCandidate) error { return nil },
	}
}

func writeDeepSeekConfigFixture(t *testing.T, enabled bool, baseURL, tokenFile string) (string, []byte) {
	t.Helper()
	configPath := filepath.Join(t.TempDir(), "config.json")
	return configPath, writeDeepSeekConfigAtPath(t, configPath, enabled, baseURL, tokenFile)
}

func writeDeepSeekConfigAtPath(t *testing.T, configPath string, enabled bool, baseURL, tokenFile string) []byte {
	t.Helper()
	deepSeek := map[string]any{
		"enabled":                 enabled,
		"max_concurrent_sessions": 2,
		"future_deepseek":         map[string]any{"mode": "keep"},
	}
	if baseURL != "" {
		deepSeek["base_url"] = baseURL
	}
	if tokenFile != "" {
		deepSeek["token_file"] = tokenFile
	}
	document := map[string]any{
		"future_root": map[string]any{"keep": true},
		"deepseek":    deepSeek,
	}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return raw
}

func setDeepSeekAutoDiscover(t *testing.T, configPath string, enabled bool) {
	t.Helper()
	document := readJSONDocument(t, configPath)
	var deepSeek map[string]any
	if err := json.Unmarshal(document["deepseek"], &deepSeek); err != nil {
		t.Fatal(err)
	}
	deepSeek["auto_discover"] = enabled
	rawDeepSeek, err := json.Marshal(deepSeek)
	if err != nil {
		t.Fatal(err)
	}
	document["deepseek"] = rawDeepSeek
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readJSONDocument(t *testing.T, path string) map[string]json.RawMessage {
	t.Helper()
	raw := mustReadFile(t, path)
	var document map[string]json.RawMessage
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	return document
}

func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func assertDeepSeekFile(t *testing.T, path string, expected []byte, private bool) {
	t.Helper()
	if raw := mustReadFile(t, path); !bytes.Equal(raw, expected) {
		t.Fatalf("文件内容变化：path=%s got=%q want=%q", path, raw, expected)
	}
	if private && runtime.GOOS != "windows" {
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
			t.Fatalf("凭据文件必须是 0600 regular file：mode=%v", info.Mode())
		}
	}
}

func assertMissingDeepSeekPath(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("路径不应存在：%s err=%v", path, err)
	}
}

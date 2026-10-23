package setup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeClaudeTurnHintsFixture(t *testing.T, claude map[string]any) string {
	t.Helper()
	raw, err := json.MarshalIndent(map[string]any{
		"listen": "127.0.0.1:8787",
		"claude": claude,
		"future": map[string]any{"preserve": true},
	}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func readClaudeTurnHintsFixture(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	return document
}

func TestConfigureClaudeTurnHintsDefaultsOnAndRestoresAbsentState(t *testing.T) {
	path := writeClaudeTurnHintsFixture(t, map[string]any{"enabled": true, "bridge_bin": "bridge"})
	result, err := ConfigureClaudeTurnHints(path, false)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || !result.PreviousEnabled || !result.Changed || !result.RestartRequired || result.Previous.Enabled != nil || result.Applied.Enabled == nil || *result.Applied.Enabled {
		t.Fatalf("关闭事务结果异常：%+v", result)
	}
	document := readClaudeTurnHintsFixture(t, path)
	claude := document["claude"].(map[string]any)
	if claude["turn_hints_enabled"] != false || document["future"].(map[string]any)["preserve"] != true {
		t.Fatalf("只应修改提示卡开关并保留未知字段：%+v", document)
	}

	unchanged, err := ConfigureClaudeTurnHints(path, false)
	if err != nil || unchanged.Changed || unchanged.RestartRequired {
		t.Fatalf("重复关闭应无写入：result=%+v err=%v", unchanged, err)
	}
	restored, err := RestoreClaudeTurnHints(path, result)
	if err != nil {
		t.Fatal(err)
	}
	if !restored.Enabled || !restored.Changed {
		t.Fatalf("恢复结果异常：%+v", restored)
	}
	claude = readClaudeTurnHintsFixture(t, path)["claude"].(map[string]any)
	if _, exists := claude["turn_hints_enabled"]; exists {
		t.Fatalf("恢复旧配置时应还原为省略字段：%+v", claude)
	}
}

func TestRestoreClaudeTurnHintsRejectsConcurrentChange(t *testing.T) {
	path := writeClaudeTurnHintsFixture(t, map[string]any{"turn_hints_enabled": true})
	result, err := ConfigureClaudeTurnHints(path, false)
	if err != nil {
		t.Fatal(err)
	}
	document := readClaudeTurnHintsFixture(t, path)
	document["claude"].(map[string]any)["turn_hints_enabled"] = true
	raw, _ := json.MarshalIndent(document, "", "  ")
	if err := os.WriteFile(path, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := RestoreClaudeTurnHints(path, result); err == nil {
		t.Fatal("并发修改后不得覆盖新设置")
	}
}

func TestConfigureClaudeTurnHintsRejectsInvalidStoredType(t *testing.T) {
	path := writeClaudeTurnHintsFixture(t, map[string]any{"turn_hints_enabled": "yes"})
	if _, err := ConfigureClaudeTurnHints(path, false); err == nil {
		t.Fatal("非法存量类型必须拒绝")
	}
}

func TestConfigureClaudeTurnHintsTreatsNullAsOmittedAndEnabled(t *testing.T) {
	path := writeClaudeTurnHintsFixture(t, map[string]any{"turn_hints_enabled": nil})
	result, err := ConfigureClaudeTurnHints(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.PreviousEnabled || result.Changed || result.RestartRequired || result.Previous.Enabled != nil {
		t.Fatalf("null 应与省略字段一致并默认开启：%+v", result)
	}
}

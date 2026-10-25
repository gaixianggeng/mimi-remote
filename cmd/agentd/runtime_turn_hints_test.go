package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestRunRuntimeClaudeTurnHintsUsesIndependentTransactionalCommand(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(configPath, []byte(`{"claude":{"enabled":true},"future":{"preserve":true}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr strings.Builder
	if err := runRuntimeWithIO([]string{
		"runtime", "--config", configPath, "--claude-turn-hints=disabled", "--json",
	}, strings.NewReader(""), &stdout, &stderr); err != nil {
		t.Fatalf("关闭提示卡失败：%v stderr=%s", err, stderr.String())
	}
	var changed agentsetup.ClaudeTurnHintsConfigurationResult
	if err := json.Unmarshal([]byte(stdout.String()), &changed); err != nil {
		t.Fatalf("事务结果不可解析：%v output=%s", err, stdout.String())
	}
	if changed.Enabled || !changed.Changed || !changed.RestartRequired {
		t.Fatalf("事务结果异常：%+v", changed)
	}

	payload, _ := json.Marshal(changed)
	stdout.Reset()
	stderr.Reset()
	if err := runRuntimeWithIO([]string{
		"runtime", "--config", configPath, "--restore-claude-turn-hints", string(payload), "--json",
	}, strings.NewReader(""), &stdout, &stderr); err != nil {
		t.Fatalf("恢复提示卡失败：%v stderr=%s", err, stderr.String())
	}
	var restored agentsetup.ClaudeTurnHintsConfigurationResult
	if err := json.Unmarshal([]byte(stdout.String()), &restored); err != nil || !restored.Enabled {
		t.Fatalf("恢复结果异常：result=%+v err=%v output=%s", restored, err, stdout.String())
	}
}

func TestRunRuntimeClaudeTurnHintsRejectsUnknownValue(t *testing.T) {
	var stdout, stderr strings.Builder
	err := runRuntimeWithIO([]string{"runtime", "--claude-turn-hints=auto"}, strings.NewReader(""), &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "enabled 或 disabled") {
		t.Fatalf("未知值应拒绝：%v", err)
	}
}

package setup

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestResolveCodexBinFallsBackFromStaleConfiguredPath(t *testing.T) {
	lookups := []string{}
	lookup := func(candidate string) (string, error) {
		lookups = append(lookups, candidate)
		switch candidate {
		case "/opt/homebrew/bin/codex":
			return "", errors.New("missing")
		case "codex":
			return "/Applications/ChatGPT.app/Contents/Resources/codex", nil
		default:
			return "", errors.New("unexpected")
		}
	}

	resolved, err := resolveCodexBin("/opt/homebrew/bin/codex", lookup, []string{"/known/app/codex"})
	if err != nil {
		t.Fatal(err)
	}
	if resolved != "/Applications/ChatGPT.app/Contents/Resources/codex" {
		t.Fatalf("应从 PATH 恢复 Codex：%s", resolved)
	}
	if !reflect.DeepEqual(lookups, []string{"/opt/homebrew/bin/codex", "codex"}) {
		t.Fatalf("查找顺序异常：%v", lookups)
	}
}

func TestResolveCodexBinFallsBackToDesktopApp(t *testing.T) {
	const embedded = "/Applications/ChatGPT.app/Contents/Resources/codex"
	lookup := func(candidate string) (string, error) {
		if candidate == embedded {
			return embedded, nil
		}
		return "", errors.New("missing")
	}

	resolved, err := resolveCodexBin("/deleted/codex", lookup, []string{embedded})
	if err != nil {
		t.Fatal(err)
	}
	if resolved != embedded {
		t.Fatalf("应恢复桌面 App 内置 Codex：%s", resolved)
	}
}

func TestRepairCodexBinPreservesUserConfigAndSecrets(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	original := map[string]any{
		"listen": "100.64.0.1:8787",
		"auth":   map[string]any{"token": "must-not-change"},
		"codex": map[string]any{
			"bin":           "/opt/homebrew/bin/codex",
			"default_args":  []string{"--no-alt-screen", "--keep"},
			"future_option": map[string]any{"enabled": true},
		},
		"projects":    []map[string]any{{"id": "demo", "path": "/tmp/demo"}},
		"future_root": map[string]any{"keep": []any{"value", 42.0}},
	}
	raw, err := json.MarshalIndent(original, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	var expected map[string]any
	if err := json.Unmarshal(raw, &expected); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	const recovered = "/Applications/ChatGPT.app/Contents/Resources/codex"
	path, repaired, err := repairCodexBin(configPath, func(configured string) (string, error) {
		if configured != "/opt/homebrew/bin/codex" {
			t.Fatalf("收到意外旧路径：%s", configured)
		}
		return recovered, nil
	}, writePrivateFileAtomically)
	if err != nil {
		t.Fatal(err)
	}
	if !repaired || path != recovered {
		t.Fatalf("应修复 Codex 路径：path=%q repaired=%v", path, repaired)
	}

	updatedRaw, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var updated map[string]any
	if err := json.Unmarshal(updatedRaw, &updated); err != nil {
		t.Fatal(err)
	}
	updatedCodex := updated["codex"].(map[string]any)
	if updatedCodex["bin"] != recovered {
		t.Fatalf("Codex 路径未持久化：%+v", updatedCodex)
	}
	expectedCodex := expected["codex"].(map[string]any)
	delete(updatedCodex, "bin")
	delete(expectedCodex, "bin")
	if !reflect.DeepEqual(updated, expected) {
		t.Fatalf("修复不能改写其他配置：\nwant=%+v\n got=%+v", expected, updated)
	}
	info, err := os.Lstat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("修复后的配置必须保持 0600 regular file：%v", info.Mode())
	}
}

func TestRepairCodexBinDoesNotRewriteValidAbsolutePath(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	original := []byte("{\n  \"codex\": {\"bin\": \"/valid/codex\"},\n  \"future\": true\n}\n")
	if err := os.WriteFile(configPath, original, 0o600); err != nil {
		t.Fatal(err)
	}
	writeCalled := false
	path, repaired, err := repairCodexBin(configPath, func(configured string) (string, error) {
		return configured, nil
	}, func(string, []byte) error {
		writeCalled = true
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if repaired || writeCalled || path != "/valid/codex" {
		t.Fatalf("有效绝对路径不应重写：path=%q repaired=%v write=%v", path, repaired, writeCalled)
	}
}

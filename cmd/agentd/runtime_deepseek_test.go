package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunRuntimeDeepSeekConnectReadsSecretOnlyFromStdin(t *testing.T) {
	const token = "cli-startup-secret-never-output"
	server := newRuntimeDeepSeekHarness(t, token, true)
	defer server.Close()
	configPath := writeRuntimeDeepSeekConfig(t)
	var stdout, stderr strings.Builder

	err := runRuntimeWithIO([]string{
		"runtime",
		"--config", configPath,
		"--deepseek", "connect",
		"--deepseek-url-stdin",
		"--json",
	}, strings.NewReader(server.URL+"/?token="+token), &stdout, &stderr)
	if err != nil {
		t.Fatalf("DeepSeek connect CLI 失败：%v stderr=%s", err, stderr.String())
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(stdout.String()), &result); err != nil {
		t.Fatalf("CLI JSON 无法解析：%v output=%s", err, stdout.String())
	}
	wantKeys := []string{"enabled", "available", "discovered", "base_url", "message", "restart_required"}
	if len(result) != len(wantKeys) {
		t.Fatalf("CLI JSON 字段必须固定：%v", result)
	}
	for _, key := range wantKeys {
		if _, ok := result[key]; !ok {
			t.Fatalf("CLI JSON 缺少 %s：%v", key, result)
		}
	}
	if result["enabled"] != true || result["available"] != true || result["discovered"] != false {
		t.Fatalf("CLI connect 状态不符：%v", result)
	}
	combined := stdout.String() + stderr.String()
	if strings.Contains(combined, token) || strings.Contains(combined, "?token=") {
		t.Fatalf("CLI 输出泄漏启动凭据：%q", combined)
	}
}

func TestRunRuntimeDeepSeekRejectsOversizedStdinBeforeConfigRead(t *testing.T) {
	secret := strings.Repeat("s", maxDeepSeekStartupURLBytes+1)
	var stdout, stderr strings.Builder
	err := runRuntimeWithIO([]string{
		"runtime", "--config", filepath.Join(t.TempDir(), "missing.json"),
		"--deepseek", "connect", "--deepseek-url-stdin", "--json",
	}, strings.NewReader(secret), &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "不能超过") {
		t.Fatalf("超长 stdin 应在读取配置前失败：%v", err)
	}
	if strings.Contains(err.Error()+stdout.String()+stderr.String(), secret) {
		t.Fatal("超长 stdin 不得进入错误或输出")
	}
}

func TestRunRuntimeDeepSeekRejectsPositionalStartupURLWithoutEcho(t *testing.T) {
	const secretURL = "http://127.0.0.1:5173/?token=positional-secret"
	var stdout, stderr strings.Builder
	err := runRuntimeWithIO([]string{
		"runtime", "--deepseek", "connect", "--json", secretURL,
	}, strings.NewReader(""), &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "标准输入") {
		t.Fatalf("位置参数必须被拒绝：%v", err)
	}
	if strings.Contains(err.Error()+stdout.String()+stderr.String(), secretURL) {
		t.Fatal("位置参数错误不得复述含凭据链接")
	}
}

func TestRunRuntimeDeepSeekRejectsEmptyModelCatalogWithoutWriting(t *testing.T) {
	const token = "empty-catalog-secret"
	server := newRuntimeDeepSeekHarness(t, token, false)
	defer server.Close()
	configPath := writeRuntimeDeepSeekConfig(t)
	original, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var stdout, stderr strings.Builder
	err = runRuntimeWithIO([]string{
		"runtime", "--config", configPath,
		"--deepseek", "connect", "--deepseek-url-stdin", "--json",
	}, strings.NewReader(server.URL+"/?token="+token), &stdout, &stderr)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(stdout.String()), &result); err != nil {
		t.Fatal(err)
	}
	if result["enabled"] != false || result["available"] != false || result["restart_required"] != false {
		t.Fatalf("空模型目录不得启用：%v", result)
	}
	after, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(original) {
		t.Fatal("空模型目录不得修改配置")
	}
	if _, err := os.Lstat(filepath.Join(filepath.Dir(configPath), "deepseek.token")); !os.IsNotExist(err) {
		t.Fatalf("空模型目录不得创建 token：%v", err)
	}
	if strings.Contains(stdout.String()+stderr.String(), token) {
		t.Fatal("失败输出不得泄漏 token")
	}
}

func newRuntimeDeepSeekHarness(t *testing.T, token string, withModel bool) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/" || request.URL.Query().Get("token") != token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "fixture", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/session/modelCatalog", func(w http.ResponseWriter, request *http.Request) {
		if cookie, err := request.Cookie("harness_session"); err != nil || cookie.Value != "fixture" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		models := []map[string]any{}
		if withModel {
			models = append(models, map[string]any{"id": "deepseek-fixture"})
		}
		response := map[string]any{
			"result": map[string]any{
				"ok": true,
				"value": map[string]any{
					"groups": []map[string]any{{"id": "fixture", "models": models}},
				},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(response); err != nil {
			t.Errorf("编码 fake Harness 响应失败：%v", err)
		}
	})
	return httptest.NewServer(mux)
}

func writeRuntimeDeepSeekConfig(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	raw := []byte("{\n  \"future_root\": true,\n  \"deepseek\": {\"enabled\": false}\n}\n")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

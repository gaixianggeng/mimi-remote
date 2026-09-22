package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiagnosticsCLIUsesLocalBearerAndDoesNotFollowRedirect(t *testing.T) {
	for _, redirect := range []bool{false, true} {
		t.Run(map[bool]string{false: "success", true: "redirect"}[redirect], func(t *testing.T) {
			called := false
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				called = true
				if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 64) || r.URL.Path != "/api/local/diagnostics/start" || r.Method != "POST" {
					t.Errorf("request contract mismatch")
				}
				if redirect {
					w.Header().Set("Location", "http://example.invalid/private")
					w.WriteHeader(302)
					return
				}
				_, _ = w.Write([]byte(`{"enabled":true,"max_total_bytes":10485760,"retention_days":7}`))
			}))
			defer server.Close()
			u, _ := url.Parse(server.URL)
			path := filepath.Join(t.TempDir(), "config.json")
			// 配置中的主机名必须被丢弃，控制命令始终只连接本机同端口。
			cfg := map[string]any{"listen": "example.invalid:" + u.Port(), "auth": map[string]any{"token": "test-diagnostic-secret"}, "codex": map[string]any{"enabled": false}}
			data, _ := json.Marshal(cfg)
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path+".diagnostics.token", []byte(strings.Repeat("a", 64)), 0o600); err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			err := runDiagnosticsWithWriter([]string{"agentd", "start", "--config", path, "--json"}, &output)
			if !called {
				t.Fatalf("未访问回环服务: %v", err)
			}
			if redirect {
				if err == nil || strings.Contains(err.Error(), "example.invalid") {
					t.Fatal("重定向必须拒绝且不能回显地址")
				}
			} else if err != nil || !strings.Contains(output.String(), `"enabled":true`) {
				t.Fatalf("result=%s err=%v", output.String(), err)
			}
		})
	}
}

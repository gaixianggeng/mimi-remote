package main

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiagnosticsCLIFollowsLoopbackListener(t *testing.T) {
	for _, tc := range []struct {
		name, configuredHost, boundHost string
		network                         map[string]any
	}{
		{"ipv6-only", "::1", "::1", nil},
		{"lan-rebuilds-ipv4", "::1", "127.0.0.1", map[string]any{"allow_lan": true}},
		{"module-controls-rebuild-alias", "127.0.0.2", "127.0.0.1", map[string]any{"allow_tailscale": false}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			listener, err := net.Listen("tcp", net.JoinHostPort(tc.boundHost, "0"))
			if err != nil {
				t.Fatal(err)
			}
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 64) {
					t.Error("必须使用独立本机凭据")
				}
				_, _ = w.Write([]byte(`{"enabled":false}`))
			}))
			server.Listener = listener
			server.Start()
			defer server.Close()
			_, port, _ := net.SplitHostPort(listener.Addr().String())
			cfg := map[string]any{
				"listen": net.JoinHostPort(tc.configuredHost, port), "network": tc.network,
				"auth": map[string]any{"token": "paired-token"}, "codex": map[string]any{"enabled": false},
			}
			data, err := json.Marshal(cfg)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path+".diagnostics.token", []byte(strings.Repeat("a", 64)), 0o600); err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			if err := runDiagnosticsWithWriter([]string{"agentd", "status", "--config", path, "--json"}, &output); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(output.String(), `"enabled":false`) {
				t.Fatalf("没有读取到本机诊断状态：%s", output.String())
			}
		})
	}
}

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

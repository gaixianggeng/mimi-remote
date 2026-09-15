package doctor

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// harnessStub 是只覆盖 doctor 需要的最小 Harness 服务：认证握手 + 模型目录。
func harnessStub(t *testing.T, token string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("token") != token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "c", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/session/modelCatalog", func(w http.ResponseWriter, r *http.Request) {
		if _, err := r.Cookie("harness_session"); err != nil {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"type": "server-response",
			"result": map[string]any{
				"ok":    true,
				"value": map[string]any{"groups": []any{}},
			},
		})
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func writeTokenFile(t *testing.T, token string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "deepseek.token")
	if err := os.WriteFile(path, []byte(token+"\n"), 0o600); err != nil {
		t.Fatalf("写入 token 文件失败：%v", err)
	}
	return path
}

// deepSeekTestConfig 只填 deepseek 段：deepSeekCheck 是 cfg.DeepSeek 的纯函数，
// 不读其它字段，也不依赖整份配置通过 Validate。
func deepSeekTestConfig(ds config.DeepSeekConfig) config.Config {
	return config.Config{DeepSeek: ds}
}

// 未启用时诊断必须是明确的通过态，而不是静默跳过。
func TestDeepSeekCheckSkipsWhenDisabled(t *testing.T) {
	checker := &Checker{cfg: deepSeekTestConfig(config.DefaultDeepSeekConfig())}
	check := checker.deepSeekCheck(context.Background())
	if check.Name != "deepseek-harness" {
		t.Fatalf("检查名不符：%s", check.Name)
	}
	if !check.OK {
		t.Fatalf("未启用时应通过：%+v", check)
	}
	if !strings.Contains(check.Message, "未启用") {
		t.Fatalf("消息应说明未启用：%s", check.Message)
	}
}

// 启用后缺字段、地址非法、凭据不可读都必须失败并给出修复建议。
func TestDeepSeekCheckFailsClosed(t *testing.T) {
	token := "startup-token-fixture"

	cases := []struct {
		name string
		cfg  func(t *testing.T) config.Config
		want string
	}{
		{
			name: "missing base url",
			cfg: func(t *testing.T) config.Config {
				return deepSeekTestConfig(config.DeepSeekConfig{
					Enabled:               true,
					TokenFile:             writeTokenFile(t, token),
					MaxConcurrentSessions: 1,
				})
			},
			want: "base_url",
		},
		{
			name: "plaintext non loopback base url",
			cfg: func(t *testing.T) config.Config {
				return deepSeekTestConfig(config.DeepSeekConfig{
					Enabled:               true,
					BaseURL:               "http://10.0.0.5:5173",
					TokenFile:             writeTokenFile(t, token),
					MaxConcurrentSessions: 1,
				})
			},
			want: "回环",
		},
		{
			name: "missing token file",
			cfg: func(t *testing.T) config.Config {
				return deepSeekTestConfig(config.DeepSeekConfig{
					Enabled:               true,
					BaseURL:               "http://127.0.0.1:5173",
					TokenFile:             filepath.Join(t.TempDir(), "absent.token"),
					MaxConcurrentSessions: 1,
				})
			},
			want: "token",
		},
		{
			name: "world readable token file",
			cfg: func(t *testing.T) config.Config {
				path := filepath.Join(t.TempDir(), "loose.token")
				if err := os.WriteFile(path, []byte(token+"\n"), 0o644); err != nil {
					t.Fatalf("写入 token 文件失败：%v", err)
				}
				return deepSeekTestConfig(config.DeepSeekConfig{
					Enabled:               true,
					BaseURL:               "http://127.0.0.1:5173",
					TokenFile:             path,
					MaxConcurrentSessions: 1,
				})
			},
			want: "权限",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			checker := &Checker{cfg: tc.cfg(t)}
			check := checker.deepSeekCheck(context.Background())
			if check.OK {
				t.Fatalf("应失败：%+v", check)
			}
			if !strings.Contains(check.Message, tc.want) {
				t.Fatalf("消息应提到 %q：%s", tc.want, check.Message)
			}
			if strings.TrimSpace(check.Fix) == "" {
				t.Fatal("失败检查必须给出修复建议")
			}
		})
	}
}

// 服务不可达时失败，但错误里不能出现凭据本身。
func TestDeepSeekCheckReportsUnreachableWithoutLeakingToken(t *testing.T) {
	token := "super-secret-startup-token"
	// 指向一个关闭的端口。
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := server.URL
	server.Close()

	cfg := deepSeekTestConfig(config.DeepSeekConfig{
		Enabled:               true,
		BaseURL:               url,
		TokenFile:             writeTokenFile(t, token),
		MaxConcurrentSessions: 1,
	})
	check := (&Checker{cfg: cfg}).deepSeekCheck(context.Background())
	if check.OK {
		t.Fatalf("不可达服务应失败：%+v", check)
	}
	if strings.Contains(check.Message, token) {
		t.Fatalf("诊断消息不得包含凭据：%s", check.Message)
	}
}

// 服务正常时应通过，且能力描述提到认证与模型目录。
func TestDeepSeekCheckPassesAgainstReachableService(t *testing.T) {
	token := "startup-token-fixture"
	server := harnessStub(t, token)

	cfg := deepSeekTestConfig(config.DeepSeekConfig{
		Enabled:               true,
		BaseURL:               server.URL,
		TokenFile:             writeTokenFile(t, token),
		MaxConcurrentSessions: 1,
	})
	check := (&Checker{cfg: cfg}).deepSeekCheck(context.Background())
	if !check.OK {
		t.Fatalf("可达服务应通过：%+v", check)
	}
	if strings.Contains(check.Message, token) {
		t.Fatalf("诊断消息不得包含凭据：%s", check.Message)
	}
}

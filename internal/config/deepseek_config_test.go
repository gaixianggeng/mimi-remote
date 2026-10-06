package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Harness 服务地址：明文 HTTP 只允许回环，远端必须 HTTPS。
func TestNormalizeDeepSeekBaseURL(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		want    string
		wantErr bool
	}{
		{"empty stays empty", "", "", false},
		{"loopback http", "http://127.0.0.1:5173", "http://127.0.0.1:5173", false},
		{"localhost http", "http://localhost:5173", "http://localhost:5173", false},
		{"ipv6 loopback http", "http://[::1]:5173", "http://[::1]:5173", false},
		{"trailing slash trimmed", "http://127.0.0.1:5173/", "http://127.0.0.1:5173", false},
		{"surrounding whitespace trimmed", "  http://127.0.0.1:5173  ", "http://127.0.0.1:5173", false},
		{"remote https allowed", "https://harness.example.com", "https://harness.example.com", false},
		// 明文 HTTP 会把启动 token 暴露在查询串里，非回环一律拒绝。
		{"remote http rejected", "http://10.0.0.5:5173", "", true},
		{"lan http rejected", "http://192.168.1.20:5173", "", true},
		{"no scheme rejected", "127.0.0.1:5173", "", true},
		{"unsupported scheme rejected", "ftp://127.0.0.1:5173", "", true},
		{"userinfo rejected", "http://user:pass@127.0.0.1:5173", "", true},
		{"query rejected", "http://127.0.0.1:5173/?token=secret", "", true},
		{"fragment rejected", "http://127.0.0.1:5173/#x", "", true},
		{"path rejected", "http://127.0.0.1:5173/api", "", true},
		{"too long rejected", "http://127.0.0.1:5173/" + strings.Repeat("a", 2048), "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := NormalizeDeepSeekBaseURL(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("应返回错误，得到 %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("不应返回错误：%v", err)
			}
			if got != tc.want {
				t.Fatalf("规范化结果不符：got=%q want=%q", got, tc.want)
			}
		})
	}
}

// 默认必须是关闭状态，且并发上限有默认值。
func TestDeepSeekDefaultsAreDisabled(t *testing.T) {
	cfg := defaults().DeepSeek
	if cfg.Enabled {
		t.Fatal("DeepSeek 必须默认关闭")
	}
	if cfg.AutoDiscover {
		t.Fatal("DeepSeek 默认不能自动改写手动连接")
	}
	if cfg.MaxConcurrentSessions != DefaultDeepSeekMaxConcurrentSessions {
		t.Fatalf("并发上限默认值不符：%d", cfg.MaxConcurrentSessions)
	}
	if cfg.BaseURL != "" || cfg.TokenFile != "" {
		t.Fatalf("默认不应预置地址或凭据路径：%+v", cfg)
	}
}

// deepSeekTestConfig 构造一份除 DeepSeek 段外都合法的配置，
// 避免无关的鉴权与项目校验干扰本文件的断言。
func deepSeekTestConfig(t *testing.T) Config {
	t.Helper()
	cfg := defaults()
	cfg.DevInsecure = true
	cfg.Projects = []ProjectConfig{{ID: "demo", Name: "demo", Path: t.TempDir()}}
	return cfg
}

// 启用时必须给齐地址与凭据路径；关闭时留空不应报错。
func TestDeepSeekValidateRequiresConnectionFieldsWhenEnabled(t *testing.T) {
	// 关闭且留空：合法。
	cfg := deepSeekTestConfig(t)
	if err := cfg.Validate(); err != nil {
		t.Fatalf("默认配置应合法：%v", err)
	}

	cases := []struct {
		name    string
		mutate  func(*Config)
		wantErr bool
	}{
		{"enabled without base url", func(c *Config) { c.DeepSeek.Enabled = true; c.DeepSeek.TokenFile = "/etc/mimi/deepseek.token" }, true},
		{"enabled without token file", func(c *Config) { c.DeepSeek.Enabled = true; c.DeepSeek.BaseURL = "http://127.0.0.1:5173" }, true},
		{"enabled with remote plaintext http", func(c *Config) {
			c.DeepSeek.Enabled = true
			c.DeepSeek.BaseURL = "http://10.0.0.5:5173"
			c.DeepSeek.TokenFile = "/etc/mimi/deepseek.token"
		}, true},
		{"enabled with zero concurrency", func(c *Config) {
			c.DeepSeek.Enabled = true
			c.DeepSeek.BaseURL = "http://127.0.0.1:5173"
			c.DeepSeek.TokenFile = "/etc/mimi/deepseek.token"
			c.DeepSeek.MaxConcurrentSessions = 0
		}, true},
		{"enabled with negative concurrency", func(c *Config) {
			c.DeepSeek.Enabled = true
			c.DeepSeek.BaseURL = "http://127.0.0.1:5173"
			c.DeepSeek.TokenFile = "/etc/mimi/deepseek.token"
			c.DeepSeek.MaxConcurrentSessions = -1
		}, true},
		{"enabled with loopback http", func(c *Config) {
			c.DeepSeek.Enabled = true
			c.DeepSeek.BaseURL = "http://127.0.0.1:5173"
			c.DeepSeek.TokenFile = "/etc/mimi/deepseek.token"
		}, false},
		{"disabled with invalid base url still rejected", func(c *Config) {
			c.DeepSeek.BaseURL = "ftp://127.0.0.1:5173"
		}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := deepSeekTestConfig(t)
			tc.mutate(&cfg)
			err := cfg.Validate()
			if tc.wantErr && err == nil {
				t.Fatal("应返回错误")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("不应返回错误：%v", err)
			}
		})
	}
}

// 环境变量覆盖要与既有 runtime 一致。
func TestDeepSeekEnvOverrides(t *testing.T) {
	t.Setenv("AGENTD_DEEPSEEK_ENABLED", "true")
	t.Setenv("AGENTD_DEEPSEEK_BASE_URL", "http://127.0.0.1:9000")
	t.Setenv("AGENTD_DEEPSEEK_TOKEN_FILE", "/tmp/deepseek.token")
	t.Setenv("AGENTD_DEEPSEEK_MAX_CONCURRENT_SESSIONS", "5")

	cfg := defaults()
	applyEnv(&cfg)

	if !cfg.DeepSeek.Enabled {
		t.Fatal("环境变量应打开 DeepSeek")
	}
	if cfg.DeepSeek.BaseURL != "http://127.0.0.1:9000" {
		t.Fatalf("base_url 覆盖失败：%s", cfg.DeepSeek.BaseURL)
	}
	if cfg.DeepSeek.TokenFile != "/tmp/deepseek.token" {
		t.Fatalf("token_file 覆盖失败：%s", cfg.DeepSeek.TokenFile)
	}
	if cfg.DeepSeek.MaxConcurrentSessions != 5 {
		t.Fatalf("并发覆盖失败：%d", cfg.DeepSeek.MaxConcurrentSessions)
	}
	// 非法并发值不覆盖，保留默认。
	t.Setenv("AGENTD_DEEPSEEK_MAX_CONCURRENT_SESSIONS", "not-a-number")
	cfg = defaults()
	applyEnv(&cfg)
	if cfg.DeepSeek.MaxConcurrentSessions != DefaultDeepSeekMaxConcurrentSessions {
		t.Fatalf("非法并发值不应覆盖默认：%d", cfg.DeepSeek.MaxConcurrentSessions)
	}
}

// 手工只写 enabled 时并发字段为零值，应按默认处理而不是报错；
// 显式写负数仍然非法。
func TestDeepSeekZeroConcurrencyFallsBackToDefault(t *testing.T) {
	project := t.TempDir()
	prefix := fmt.Sprintf(`{"dev_insecure":true,"projects":[{"id":"demo","name":"demo","path":%q}],"deepseek":`, project)

	raw := []byte(prefix + `{"enabled":true,"base_url":"http://127.0.0.1:5173","token_file":"/tmp/deepseek.token"}}`)
	cfg, err := LoadSnapshot(raw)
	if err != nil {
		t.Fatalf("缺少并发字段不应加载失败：%v", err)
	}
	if cfg.DeepSeek.MaxConcurrentSessions != DefaultDeepSeekMaxConcurrentSessions {
		t.Fatalf("零值并发应回落默认：%d", cfg.DeepSeek.MaxConcurrentSessions)
	}

	negative := []byte(prefix + `{"enabled":true,"base_url":"http://127.0.0.1:5173","token_file":"/tmp/deepseek.token","max_concurrent_sessions":-1}}`)
	if _, err := LoadSnapshot(negative); err == nil {
		t.Fatal("负并发应被拒绝")
	}
}

// 配置里只能出现凭据路径，不能出现凭据本身。
func TestDeepSeekConfigHasNoSecretField(t *testing.T) {
	// 用一份完整配置序列化后再解析，确认 token 不会随配置往返。
	cfg := defaults()
	cfg.DeepSeek = DeepSeekConfig{
		Enabled:               true,
		BaseURL:               "http://127.0.0.1:5173",
		TokenFile:             filepath.Join(os.TempDir(), "deepseek.token"),
		MaxConcurrentSessions: 2,
	}
	encoded, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("序列化失败：%v", err)
	}
	if strings.Contains(string(encoded), "access_token") || strings.Contains(string(encoded), "secret") {
		t.Fatalf("配置不应包含凭据字段：%s", encoded)
	}
	if !strings.Contains(string(encoded), "token_file") {
		t.Fatalf("配置应保存凭据路径：%s", encoded)
	}
}

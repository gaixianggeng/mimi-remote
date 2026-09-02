package setup

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestConfigureTailcatPreservesUnknownConfiguration(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{
  "listen": "127.0.0.1:8787",
  "auth": {"token": "0123456789abcdef0123456789abcdef"},
  "future": {"kept": true},
  "tailcat": {"enabled": false, "derp_map_url": "https://relay.example/map", "future": 7}
}
`)
	if err := os.WriteFile(configPath, original, 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := ConfigureTailcat(configPath, true)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Changed || result.PreviousEnabled {
		t.Fatalf("切换结果异常：%+v", result)
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	var future map[string]bool
	if err := json.Unmarshal(document["future"], &future); err != nil || !future["kept"] {
		t.Fatalf("未知顶层字段未保留：%s", document["future"])
	}
	var tailcat map[string]json.RawMessage
	if err := json.Unmarshal(document["tailcat"], &tailcat); err != nil {
		t.Fatal(err)
	}
	if string(tailcat["enabled"]) != "true" || string(tailcat["future"]) != "7" {
		t.Fatalf("Tailcat 未知字段未保留：%v", tailcat)
	}
}

func TestConfigureTailcatDERPMapSupportsCustomAndDefaultModes(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{
  "listen": "127.0.0.1:8787",
  "auth": {"token": "0123456789abcdef0123456789abcdef"},
  "future": {"kept": true},
  "tailcat": {"enabled": true, "future": 7}
}
`)
	if err := os.WriteFile(configPath, original, 0o600); err != nil {
		t.Fatal(err)
	}

	configured, err := ConfigureTailcatDERPMap(configPath, "  https://relay.example/derpmap/default  ")
	if err != nil {
		t.Fatal(err)
	}
	if !configured.Changed || configured.DERPMapURL != "https://relay.example/derpmap/default" || configured.PreviousDERPMapURL != "" {
		t.Fatalf("自定义中继结果异常：%+v", configured)
	}

	restored, err := ConfigureTailcatDERPMap(configPath, "")
	if err != nil {
		t.Fatal(err)
	}
	if !restored.Changed || restored.DERPMapURL != "" || restored.PreviousDERPMapURL != configured.DERPMapURL {
		t.Fatalf("恢复默认中继结果异常：%+v", restored)
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	var tailcat map[string]json.RawMessage
	if err := json.Unmarshal(document["tailcat"], &tailcat); err != nil {
		t.Fatal(err)
	}
	if _, exists := tailcat["derp_map_url"]; exists {
		t.Fatalf("默认模式必须删除 derp_map_url：%v", tailcat)
	}
	var future map[string]bool
	if err := json.Unmarshal(document["future"], &future); err != nil || !future["kept"] {
		t.Fatalf("未知顶层字段未保留：%s", document["future"])
	}
	if string(tailcat["future"]) != "7" {
		t.Fatalf("未知字段未保留：tailcat=%v document=%v", tailcat, document)
	}
}

func TestConfigureTailcatDERPMapRejectsUnsafeURLWithoutChangingConfig(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"tailcat":{"enabled":true,"derp_map_url":"https://relay.example/map"}}`)
	if err := os.WriteFile(configPath, original, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, candidate := range []string{
		"http://relay.example/map",
		"https://user:password@relay.example/map",
		"not-a-url",
	} {
		if _, err := ConfigureTailcatDERPMap(configPath, candidate); err == nil {
			t.Fatalf("不安全地址必须拒绝：%q", candidate)
		}
		data, err := os.ReadFile(configPath)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != string(original) {
			t.Fatalf("校验失败不能修改配置：got=%s want=%s", data, original)
		}
	}
}

func TestTailcatPairContainsOnlyShortLivedTicketAndPairAddress(t *testing.T) {
	const token = "0123456789abcdef0123456789abcdef"
	configPath := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(configPath, []byte(`{
  "listen": "127.0.0.1:8787",
  "auth": {"token": "`+token+`"}
}`), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := TailcatPair(configPath, "tailcat-temporary-address")
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(result.PairURL)
	if err != nil {
		t.Fatal(err)
	}
	query := parsed.Query()
	if result.Network != PairingNetworkTailcat || query.Get("transport") != "tailcat" || query.Get("tailcat_pair_address") != "tailcat-temporary-address" {
		t.Fatalf("Tailcat 配对链接字段异常：%s", result.PairURL)
	}
	if query.Get("pair_sig") == "" || query.Get("expires_at") == "" {
		t.Fatalf("Tailcat 配对链接缺少签名或有效期：%s", result.PairURL)
	}
	if query.Get("token") != "" || result.Token != "" || result.ConnectURL != "" {
		t.Fatalf("Tailcat 配对不能暴露长期凭据：%+v", result)
	}
}

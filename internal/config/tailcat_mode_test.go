package config

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTailcatManagedModeConfigCompatibilityAndValidation(t *testing.T) {
	var legacy TailcatConfig
	if err := json.Unmarshal([]byte(`{"enabled":true,"derp_map_url":"https://custom.example.invalid/map"}`), &legacy); err != nil {
		t.Fatal(err)
	}
	if legacy.ConnectionMode() != TailcatModeSelfHosted || legacy.Validate() != nil {
		t.Fatal("旧配置必须保持自建模式")
	}
	if got, err := legacy.ManagedRelayURL(); err != nil || got != DefaultManagedTailcatDERPMapURL {
		t.Fatalf("默认官方中继：%q %v", got, err)
	}
	if DefaultManagedTailcatDERPMapURL != "https://api.code89757.com/v1/relay/tailcat-derp-map.json" {
		t.Fatal("官方中继地址异常")
	}
	for _, previous := range []string{"", "https://custom.example.invalid/map"} {
		cfg := TailcatConfig{Mode: TailcatModeManaged, DERPMapURL: "https://test.example.invalid/map", ManagedDERPMapURL: "https://test.example.invalid/map", PreviousDERPMapURL: previous}
		if err := cfg.Validate(); err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(cfg)
		var restored TailcatConfig
		if err := json.Unmarshal(data, &restored); err != nil || restored != cfg {
			t.Fatalf("配置往返丢失原值：%s %v", data, err)
		}
	}
	// 模式与中继记录不一致不能阻止 agentd 启动：否则以后更换官方地址或手工改过配置，
	// 整个 agentd 起不来，局域网与 Tailscale 也一起断。
	for _, cfg := range []TailcatConfig{
		{Mode: TailcatModeManaged},
		{Mode: TailcatModeManaged, DERPMapURL: "https://public.example.invalid/map"},
		{PreviousDERPMapURL: "https://custom.example.invalid/map"},
	} {
		if err := cfg.Validate(); err != nil {
			t.Fatalf("不一致但可解析的配置不能阻止启动：%+v %v", cfg, err)
		}
	}
	for _, cfg := range []TailcatConfig{
		{Mode: "unknown"},
		{ManagedDERPMapURL: "http://test.example.invalid/map"},
		{ManagedDERPMapURL: "https://user:password@test.example.invalid/map"},
		{ManagedDERPMapURL: "https://test.example.invalid/map#fragment"},
		{ManagedDERPMapURL: strings.Repeat("a", 2049)},
		{PreviousDERPMapURL: "http://custom.example.invalid/map"},
	} {
		if err := cfg.Validate(); err == nil {
			t.Fatalf("无法解析的托管配置必须拒绝：%+v", cfg)
		}
		root := defaults()
		root.Auth.Token = "0123456789abcdef0123456789abcdef"
		root.Tailcat = cfg
		if err := root.Validate(); err == nil {
			t.Fatal("完整配置校验未覆盖托管配置")
		}
	}
}

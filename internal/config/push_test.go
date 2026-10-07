package config

import "testing"

func TestLoadPushDefaultsAndExplicitChoices(t *testing.T) {
	clearAgentdEnv(t)
	for _, tt := range []struct {
		name string
		raw  string
		want PushConfig
	}{
		{name: "missing file", want: DefaultPushConfig()},
		{name: "missing section", raw: `{}`, want: DefaultPushConfig()},
		{name: "empty section", raw: `{"push":{}}`, want: DefaultPushConfig()},
		{name: "explicit disable", raw: `{"push":{"enabled":false}}`, want: PushConfig{ProviderURL: DefaultPushProviderURL}},
		{name: "custom provider", raw: `{"push":{"provider_url":"https://push.example/mimi-push"}}`, want: PushConfig{Enabled: true, ProviderURL: "https://push.example/mimi-push"}},
		{name: "disabled custom provider", raw: `{"push":{"enabled":false,"provider_url":"https://push.example/mimi-push","environment":"sandbox"}}`, want: PushConfig{ProviderURL: "https://push.example/mimi-push", Environment: "sandbox"}},
		{name: "explicit empty provider", raw: `{"push":{"provider_url":""}}`, want: PushConfig{Enabled: true}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var raw []byte
			if tt.raw != "" {
				raw = []byte(tt.raw)
			}
			cfg, err := loadRawWithoutProjectDiscovery(raw)
			if err != nil {
				t.Fatal(err)
			}
			if cfg.Push != tt.want {
				t.Fatalf("push 配置未保留默认值或显式选择：got=%+v want=%+v", cfg.Push, tt.want)
			}
		})
	}
}

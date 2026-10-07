package setup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSetupPreservesPushChoices(t *testing.T) {
	for _, tt := range []struct {
		name     string
		original string
		force    bool
		want     config.PushConfig
	}{
		{name: "new install", want: config.DefaultPushConfig()},
		{name: "forced missing section", original: `{}`, force: true, want: config.DefaultPushConfig()},
		{name: "disabled", original: `{"enabled":false}`, want: config.PushConfig{ProviderURL: config.DefaultPushProviderURL}},
		{name: "forced disabled", original: `{"enabled":false}`, force: true, want: config.PushConfig{ProviderURL: config.DefaultPushProviderURL}},
		{name: "custom provider", original: `{"enabled":true,"provider_url":"https://push.example/mimi-push","environment":"sandbox"}`, want: config.PushConfig{Enabled: true, ProviderURL: "https://push.example/mimi-push", Environment: "sandbox"}},
		{name: "forced custom provider", original: `{"enabled":true,"provider_url":"https://push.example/mimi-push","environment":"sandbox"}`, force: true, want: config.PushConfig{Enabled: true, ProviderURL: "https://push.example/mimi-push", Environment: "sandbox"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			clearSetupEnv(t)
			path := filepath.Join(t.TempDir(), "config.json")
			options := Options{ConfigPath: path, ScanRoot: t.TempDir(), BrowseRoot: t.TempDir(), Listen: "127.0.0.1:8787"}
			if _, err := Run(context.Background(), options); err != nil {
				t.Fatal(err)
			}
			if tt.original != "" {
				raw, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				var document map[string]json.RawMessage
				if err := json.Unmarshal(raw, &document); err != nil {
					t.Fatal(err)
				}
				if tt.original == `{}` {
					delete(document, "push")
				} else {
					document["push"] = json.RawMessage(tt.original)
				}
				raw, err = json.Marshal(document)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, raw, 0o600); err != nil {
					t.Fatal(err)
				}
				options.Force = tt.force
				if _, err := Run(context.Background(), options); err != nil {
					t.Fatal(err)
				}
			}
			loaded, err := config.LoadForDoctor(path)
			if err != nil {
				t.Fatal(err)
			}
			if loaded.Push != tt.want {
				t.Fatalf("setup 未保留通知选择：got=%+v want=%+v", loaded.Push, tt.want)
			}
			// 首次安装和强制重建都必须写入正确值，不能靠 Load 的默认值掩盖旧的 false。
			if tt.original == "" || tt.force {
				raw, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				var stored config.Config
				if err := json.Unmarshal(raw, &stored); err != nil {
					t.Fatal(err)
				}
				if stored.Push != tt.want {
					t.Fatalf("setup 写入的通知配置错误：got=%+v want=%+v", stored.Push, tt.want)
				}
			}
		})
	}
}

package setup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestConfigureTailcatModePreservesUnknownFieldsAndOriginalRelay(t *testing.T) {
	for _, previousURL := range []string{"", "https://custom.example.invalid/map"} {
		t.Run(previousURL, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			previous := config.TailcatConfig{DERPMapURL: previousURL, ManagedDERPMapURL: "https://official.example.invalid/map"}
			tailcat, _ := json.Marshal(previous)
			var fields map[string]any
			_ = json.Unmarshal(tailcat, &fields)
			fields["future"] = 7
			data, _ := json.Marshal(map[string]any{"tailcat": fields, "future": true})
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			next := previous
			next.Mode = config.TailcatModeManaged
			next.PreviousDERPMapURL = previousURL
			next.DERPMapURL = next.ManagedDERPMapURL
			if err := ConfigureTailcatMode(path, previous, next); err != nil {
				t.Fatal(err)
			}
			persisted, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(persisted), `"future": 7`) || !strings.Contains(string(persisted), `"future": true`) {
				t.Fatal("未知字段丢失")
			}
			if _, err := ConfigureTailcatDERPMap(path, ""); err == nil {
				t.Fatal("不能绕过托管模式手动改中继")
			}
			unchanged, _ := os.ReadFile(path)
			if string(unchanged) != string(persisted) {
				t.Fatal("拒绝操作修改了配置")
			}
			restored := next
			restored.Mode = config.TailcatModeSelfHosted
			restored.DERPMapURL = next.PreviousDERPMapURL
			restored.PreviousDERPMapURL = ""
			if err := ConfigureTailcatMode(path, next, restored); err != nil {
				t.Fatal(err)
			}
			persisted, _ = os.ReadFile(path)
			var cfg struct {
				Tailcat config.TailcatConfig `json:"tailcat"`
			}
			if err := json.Unmarshal(persisted, &cfg); err != nil {
				t.Fatal(err)
			}
			if cfg.Tailcat.DERPMapURL != previousURL || cfg.Tailcat.Mode != config.TailcatModeSelfHosted {
				t.Fatal("退出未恢复原值")
			}
			if strings.Contains(string(persisted), "previous_derp_map_url") {
				t.Fatal("退出后必须删除原值字段")
			}
			if previousURL == "" && strings.Contains(string(persisted), `"derp_map_url"`) {
				t.Fatal("默认中继必须删除 URL 字段")
			}
		})
	}
}

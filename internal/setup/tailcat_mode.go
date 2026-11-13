package setup

import (
	"encoding/json"
	"fmt"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// ConfigureTailcatMode 在一次配置提交中保存模式、中继和原值，保留未知字段。
func ConfigureTailcatMode(configPath string, previous, next config.TailcatConfig) error {
	if err := next.Validate(); err != nil {
		return err
	}
	path, original, document, tailcat, err := readTailcatConfiguration(configPath)
	if err != nil {
		return err
	}
	raw, _ := json.Marshal(tailcat)
	var current config.TailcatConfig
	if err := json.Unmarshal(raw, &current); err != nil {
		return err
	}
	// 不能覆盖运行时切换期间由其他入口改写的模式或中继。
	if current.ConnectionMode() != previous.ConnectionMode() || current.DERPMapURL != previous.DERPMapURL ||
		current.PreviousDERPMapURL != previous.PreviousDERPMapURL || current.ManagedDERPMapURL != previous.ManagedDERPMapURL {
		return fmt.Errorf("Tailcat 配置已变化，请重启 agentd 后重试")
	}
	for key, value := range map[string]string{
		"mode":                  next.ConnectionMode(),
		"derp_map_url":          next.DERPMapURL,
		"previous_derp_map_url": next.PreviousDERPMapURL,
	} {
		if value == "" {
			delete(tailcat, key)
		} else {
			tailcat[key], _ = json.Marshal(value)
		}
	}
	_, err = commitTailcatConfiguration(path, original, document, tailcat)
	return err
}

package config

import (
	"fmt"
	"strings"
)

const (
	TailcatModeSelfHosted           = "self_hosted"
	TailcatModeManaged              = "managed"
	DefaultManagedTailcatDERPMapURL = "https://api.code89757.com/v1/relay/tailcat-derp-map.json"
)

// ConnectionMode 将旧配置的空模式解释为自建，不自动迁移已有配对。
func (c TailcatConfig) ConnectionMode() string {
	if c.Mode == "" {
		return TailcatModeSelfHosted
	}
	return c.Mode
}

func (c TailcatConfig) ManagedRelayURL() (string, error) {
	value := strings.TrimSpace(c.ManagedDERPMapURL)
	if value == "" {
		value = DefaultManagedTailcatDERPMapURL
	}
	normalized, err := NormalizeTailcatDERPMapURL(value)
	if err != nil {
		return "", fmt.Errorf("tailcat.managed_derp_map_url：%w", err)
	}
	return normalized, nil
}

func (c TailcatConfig) Validate() error {
	current, err := NormalizeTailcatDERPMapURL(c.DERPMapURL)
	if err != nil {
		return err
	}
	if _, err := NormalizeTailcatDERPMapURL(c.PreviousDERPMapURL); err != nil {
		return fmt.Errorf("tailcat.previous_derp_map_url：%w", err)
	}
	official, err := c.ManagedRelayURL()
	if err != nil {
		return err
	}
	switch c.ConnectionMode() {
	case TailcatModeSelfHosted:
		if c.PreviousDERPMapURL != "" {
			return fmt.Errorf("自建模式不能保留 tailcat.previous_derp_map_url")
		}
	case TailcatModeManaged:
		// 配置不一致时拒绝启动，不能把托管身份静默带回默认公共中继。
		if current != official {
			return fmt.Errorf("托管模式的 tailcat.derp_map_url 必须等于托管中继地址")
		}
	default:
		return fmt.Errorf("tailcat.mode 只支持 self_hosted 或 managed")
	}
	return nil
}

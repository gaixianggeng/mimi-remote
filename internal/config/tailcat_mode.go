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

// FreeRelayURL 是托管模式下免费节点使用的中继：进入托管前用户自己的中继。官方中继只接受
// 开通过的节点，不能给免费节点用，这时退回 Tailcat 默认中继。退出托管也恢复到这里。
func (c TailcatConfig) FreeRelayURL() string {
	previous, err := NormalizeTailcatDERPMapURL(c.PreviousDERPMapURL)
	if err != nil || c.IsManagedRelay(previous) {
		return ""
	}
	return previous
}

// IsManagedRelay 判断地址是否为官方中继。managed_derp_map_url 可被测试或自建控制面覆盖，
// 两个地址都算。
func (c TailcatConfig) IsManagedRelay(rawURL string) bool {
	normalized, err := NormalizeTailcatDERPMapURL(rawURL)
	if err != nil || normalized == "" {
		return false
	}
	if normalized == DefaultManagedTailcatDERPMapURL {
		return true
	}
	managed, err := c.ManagedRelayURL()
	return err == nil && normalized == managed
}

func (c TailcatConfig) Validate() error {
	if _, err := NormalizeTailcatDERPMapURL(c.DERPMapURL); err != nil {
		return err
	}
	if _, err := NormalizeTailcatDERPMapURL(c.PreviousDERPMapURL); err != nil {
		return fmt.Errorf("tailcat.previous_derp_map_url：%w", err)
	}
	if _, err := c.ManagedRelayURL(); err != nil {
		return err
	}
	// 校验失败会让整个 agentd 起不来，局域网和 Tailscale 也一起断。这里只拒绝
	// 无法解析的值；托管模式下中继与当前内置官方地址不一致（例如以后的版本更换
	// 官方地址）、自建模式残留原中继记录，都不阻止启动，由模式切换负责收敛。
	switch c.ConnectionMode() {
	case TailcatModeSelfHosted, TailcatModeManaged:
		return nil
	default:
		return fmt.Errorf("tailcat.mode 只支持 self_hosted 或 managed")
	}
}

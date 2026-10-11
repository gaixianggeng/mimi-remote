package claudebridge

import (
	"encoding/json"
	"errors"
	"strings"
)

// AdapterName 是基于 Claude Agent SDK 的适配器（bridges/claude-sdk）在 `--version`
// 输出里的名字。它的版本号与旧 Rust bridge 不在同一序列，能力不能按旧 bridge 的
// 版本门槛推断，必须读它自己用 `--capabilities` 声明的能力。
const AdapterName = "mimi-claude-adapter"

// AdapterCapabilities 是适配器 `--capabilities` 输出的能力声明。
type AdapterCapabilities struct {
	Methods    []string `json:"methods"`
	FullAccess bool     `json:"fullAccess"`
}

// IsAdapterVersionOutput 判断 `--version` 输出是否来自 SDK 适配器。
func IsAdapterVersionOutput(output string) bool {
	return strings.HasPrefix(strings.TrimSpace(output), AdapterName+" ")
}

// ParseAdapterCapabilities 解析能力声明；方法列表为空视为无效声明。
func ParseAdapterCapabilities(output []byte) (AdapterCapabilities, error) {
	var capabilities AdapterCapabilities
	if err := json.Unmarshal(output, &capabilities); err != nil {
		return AdapterCapabilities{}, err
	}
	if len(capabilities.Methods) == 0 {
		return AdapterCapabilities{}, errors.New("适配器没有声明任何方法")
	}
	return capabilities, nil
}

// Supports 判断适配器是否实现了某个方法。
func (c AdapterCapabilities) Supports(method string) bool {
	for _, declared := range c.Methods {
		if declared == method {
			return true
		}
	}
	return false
}

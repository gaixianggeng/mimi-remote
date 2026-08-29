package config

import (
	"fmt"
	"strings"
	"unicode"
)

// ValidateAppServerSSHTarget 校验将作为 OpenSSH 单独参数传入的目标。
// 不允许空白、控制字符和前导连字符；目标不会经过 shell 拼接，但仍需拒绝
// 可能被 OpenSSH 当作 option 的值，避免配置错误扩大命令边界。
func ValidateAppServerSSHTarget(raw string) error {
	if raw == "" {
		return fmt.Errorf("不能为空")
	}
	if strings.HasPrefix(raw, "-") {
		return fmt.Errorf("不能以 - 开头")
	}
	for _, r := range raw {
		if r == '\x00' {
			return fmt.Errorf("不能包含 NUL")
		}
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return fmt.Errorf("不能包含空白或控制字符")
		}
	}
	return nil
}

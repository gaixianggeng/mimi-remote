//go:build !darwin

package hostinfo

import "context"

// platformComputerName 只在 macOS 读取系统「电脑名称」；其它平台没有等价字段，
// 返回空值让调用方统一退回主机名。
func platformComputerName(context.Context) string {
	return ""
}

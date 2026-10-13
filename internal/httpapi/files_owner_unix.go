//go:build !windows

package httpapi

import (
	"os"
	"syscall"
)

// fileOwnedByCurrentUserWithSingleLink 只用于临时目录特例：文件必须由 agentd 运行用户创建，
// 且没有额外硬链接，避免其他本机用户投放文件或用硬链接把授权外内容伪装成可信产物。
func fileOwnedByCurrentUserWithSingleLink(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid() && stat.Nlink == 1
}

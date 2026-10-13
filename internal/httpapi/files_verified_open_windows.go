//go:build windows

package httpapi

import "os"

// Windows 不支持授权根之外的预览特例，这里明确拒绝：Go 在 Windows 上对普通文件执行
// os.Lstat 时只保存路径，文件 ID 要到 os.SameFile 比较时才按路径重新读取，无法证明读取的
// 仍是解析时校验过的那个文件；也没有与 O_NOFOLLOW 等价的逐级打开。
func openPreviewFileNoFollow(string, string) (*os.File, error) {
	return nil, errFilePathOutsideScope
}

//go:build windows

package httpapi

import "os"

// Windows 没有临时目录截图特例，这里保持拒绝。
func fileOwnedByCurrentUserWithSingleLink(os.FileInfo) bool { return false }

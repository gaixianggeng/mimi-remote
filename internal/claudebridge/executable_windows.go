//go:build windows

package claudebridge

import (
	"os"
	"path/filepath"
	"strings"
)

// commandCandidates 是 PATH 里某个目录下同名命令的候选文件：没有可执行扩展名时按常见扩展名补齐。
func commandCandidates(path string) []string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".exe", ".com", ".bat", ".cmd":
		return []string{path}
	default:
		return []string{path + ".exe", path + ".cmd", path + ".bat", path + ".com"}
	}
}

// Windows executable permissions are ACL based; FileMode's Unix execute bits
// are not meaningful.  Keep explicit paths constrained to launchable suffixes.
func isExecutableFile(path string, info os.FileInfo) bool {
	if !info.Mode().IsRegular() {
		return false
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".exe", ".com", ".bat", ".cmd":
		return true
	default:
		return false
	}
}

//go:build windows

package agybridge

import (
	"os"
	"path/filepath"
	"strings"
)

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

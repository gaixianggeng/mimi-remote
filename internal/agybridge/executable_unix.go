//go:build !windows

package agybridge

import "os"

func isExecutableFile(_ string, info os.FileInfo) bool {
	return info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

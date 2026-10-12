//go:build !windows

package claudebridge

import "os"

// commandCandidates 是 PATH 里某个目录下同名命令的候选文件。
func commandCandidates(path string) []string {
	return []string{path}
}

func isExecutableFile(_ string, info os.FileInfo) bool {
	return info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

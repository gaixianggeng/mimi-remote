package claudebridge

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// LookPathIn 按给定环境变量里的 PATH 查找命令，与用这份环境启动的进程（适配器以及它起的
// claude）看到的一致。name 带路径分隔符时只检查它本身；环境里没有 PATH 时退回当前进程的查找。
func LookPathIn(name string, env []string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", exec.ErrNotFound
	}
	if strings.ContainsAny(name, `/\`) {
		if path, ok := resolveExecutable(name); ok {
			return path, nil
		}
		return "", exec.ErrNotFound
	}
	pathValue, found := "", false
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if ok && (key == "PATH" || (runtime.GOOS == "windows" && strings.EqualFold(key, "PATH"))) {
			pathValue, found = value, true
		}
	}
	if !found {
		return exec.LookPath(name)
	}
	for _, dir := range filepath.SplitList(pathValue) {
		if dir == "" {
			continue
		}
		for _, candidate := range commandCandidates(filepath.Join(dir, name)) {
			if info, err := os.Stat(candidate); err == nil && isExecutableFile(candidate, info) {
				return candidate, nil
			}
		}
	}
	return "", exec.ErrNotFound
}

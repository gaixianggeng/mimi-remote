package sshbridge

import (
	"crypto/sha256"
	"fmt"
	"path/filepath"
)

type Options struct {
	Shell string
	Home  string
	Env   []string
}

func SocketPath(configPath string) (string, error) {
	absolute, err := filepath.Abs(configPath)
	if err != nil {
		return "", err
	}
	dir := filepath.Dir(absolute)
	if canonical, err := filepath.EvalSymlinks(dir); err == nil {
		dir = canonical
	}
	// 同目录的测试/自定义配置互不占用；IPC 留在 Mimi 目录，避免修改 Codex 状态布局。
	identity := sha256.Sum256([]byte(filepath.Join(dir, filepath.Base(absolute))))
	return filepath.Join(dir, "ssh", fmt.Sprintf("%x.sock", identity[:4])), nil
}

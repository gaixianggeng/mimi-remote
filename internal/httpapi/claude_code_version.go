package httpapi

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
)

// claudeCodeVersionCache 记住上次探测到的 Claude Code 版本。网关探测按 TTL 刷新，CLI 文件没换就
// 不再起进程：npm 安装的 claude 每次 --version 都要拉起 node。
type claudeCodeVersionCache struct {
	mu      sync.Mutex
	path    string
	modTime time.Time
	size    int64
	known   string
}

// version 返回适配器将要使用的 Claude Code 的版本：claude.env 里的 CLAUDE_BRIDGE_CLAUDE_BIN，
// 否则 PATH 里的 claude。找不到或无法确认时返回 false，交给适配器起进程前的检查给出提示。
func (c *claudeCodeVersionCache) version(env map[string]string) (string, bool) {
	bin := strings.TrimSpace(env["CLAUDE_BRIDGE_CLAUDE_BIN"])
	if bin == "" {
		bin = "claude"
	}
	path, err := exec.LookPath(bin)
	if err != nil {
		return "", false
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.known != "" && c.path == path && c.modTime.Equal(info.ModTime()) && c.size == info.Size() {
		return c.known, true
	}
	version, err := claudebridge.ClaudeCodeVersion(context.Background(), path, buildClaudeBridgeEnv(env))
	if err != nil {
		return "", false
	}
	c.path, c.modTime, c.size, c.known = path, info.ModTime(), info.Size(), version
	return version, true
}

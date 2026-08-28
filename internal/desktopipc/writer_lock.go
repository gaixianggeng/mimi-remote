package desktopipc

import (
	"os"
	"path/filepath"
	"strings"
)

// Codex 用 $CODEX_HOME/thread-writer-locks/<thread-id>.lock 记录每条 Thread 的
// 唯一 writer。加载会话时创建并 flock，放弃会话时连文件一起删除，因此文件不存在
// 就说明当前没有任何 app-server 在驱动这条 Thread。
const writerLockDirName = "thread-writer-locks"

// ThreadHasLiveWriter 只做 stat，不尝试加锁。Codex 自己的 acquire 会先取目录级
// coordination lock，这里若跟着 flock 就可能与之交错，让一条空闲 Thread 被误报成
// “already has an active writer”。进程崩溃留下的锁文件会被读成“有 writer”，代价
// 只是放弃快路径、退回原有探测，不会得出错误结论。
func (b *Bridge) ThreadHasLiveWriter(threadID string) (held bool, known bool) {
	threadID = strings.TrimSpace(threadID)
	if b == nil || threadID == "" || strings.ContainsAny(threadID, `/\`) {
		return false, false
	}
	directory := strings.TrimSpace(b.writerLockDir)
	if directory == "" {
		return false, false
	}
	switch _, err := os.Lstat(filepath.Join(directory, threadID+".lock")); {
	case err == nil:
		return true, true
	case os.IsNotExist(err):
		return false, true
	default:
		return false, false
	}
}

func writerLockDirForCodexHome(codexHome string) string {
	codexHome = strings.TrimSpace(codexHome)
	if codexHome == "" {
		return ""
	}
	return filepath.Join(codexHome, writerLockDirName)
}

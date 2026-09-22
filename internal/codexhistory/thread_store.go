package codexhistory

import (
	"path/filepath"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

// ThreadStore 把 Codex 的 SQLite 线程元数据读取收在同一个边界里。
// 它只服务 /api/debug/codex-history 的诊断读取；会话消息由 iOS 直接向
// app-server 读写，不再经过这里的 rollout 解析。
type ThreadStore struct {
	db string
}

func NewThreadStore(db string) ThreadStore {
	return ThreadStore{db: strings.TrimSpace(db)}
}

func defaultThreadStore() ThreadStore {
	return NewThreadStore(filepath.Join(homeDir(), ".codex", "state_5.sqlite"))
}

func (s ThreadStore) databasePath() string {
	if s.db != "" {
		return s.db
	}
	return filepath.Join(homeDir(), ".codex", "state_5.sqlite")
}

func (s ThreadStore) ListThreadsWithStats(project *projects.Project, limit int, includeSubagents bool, cursor PageCursor) ([]row, map[string]bool, HistoryScanStats, error) {
	return loadHistorySnapshotWithStats(s.databasePath(), project, limit, includeSubagents, cursor)
}

package codexhistory

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

// ThreadStore 把 Codex 的 SQLite 线程元数据和 rollout 消息读取收在同一个边界里。
// 当前仍复用轻量 sqlite3/JSONL 实现；先把入口稳定下来，后续再扩展 turns summary/full 分页。
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

func (s ThreadStore) ListThreads(project *projects.Project, limit int, includeSubagents bool, cursor PageCursor) ([]row, map[string]bool, error) {
	return loadHistorySnapshot(s.databasePath(), project, limit, includeSubagents, cursor)
}

func (s ThreadStore) ListThreadsWithStats(project *projects.Project, limit int, includeSubagents bool, cursor PageCursor) ([]row, map[string]bool, HistoryScanStats, error) {
	return loadHistorySnapshotWithStats(s.databasePath(), project, limit, includeSubagents, cursor)
}

func (s ThreadStore) ReadMessagesWithLimit(threadID string, limit int) ([]Message, error) {
	path, err := s.RolloutPath(threadID)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if messages, ok := cachedMessages(path, info, limit); ok {
		return messages, nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	messages, err := messagesFromFile(file, info, limit)
	if err != nil {
		return nil, err
	}
	storeCachedMessages(path, info, limit, messages)
	return cloneMessages(messages), nil
}

func (s ThreadStore) ReadMessagesPage(threadID string, before string, limit int) (MessagePage, error) {
	path, err := s.RolloutPath(threadID)
	if err != nil {
		return MessagePage{}, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return MessagePage{}, err
	}
	if limit <= 0 && strings.TrimSpace(before) == "" {
		messages, err := s.ReadMessagesWithLimit(threadID, 0)
		return MessagePage{Messages: messages}, err
	}
	if limit <= 0 {
		limit = defaultMessagePageLimit
	}
	beforeOffset, ok := decodeMessageCursor(before)
	if !ok || beforeOffset > info.Size() {
		beforeOffset = info.Size()
	}
	if page, ok := cachedMessagePage(path, info, beforeOffset, limit); ok {
		return page, nil
	}
	if indexed, ok := cachedMessageIndex(path, info); ok {
		page := pageFromIndexedMessages(indexed, beforeOffset, limit)
		storeCachedMessagePage(path, info, beforeOffset, limit, page)
		return page, nil
	}
	file, err := os.Open(path)
	if err != nil {
		return MessagePage{}, err
	}
	defer file.Close()

	if indexed, ok, err := extendCachedMessageIndex(path, info, file); err != nil {
		return MessagePage{}, err
	} else if ok {
		page := pageFromIndexedMessages(indexed, beforeOffset, limit)
		storeCachedMessagePage(path, info, beforeOffset, limit, page)
		return cloneMessagePage(page), nil
	}

	if beforeOffset < info.Size() && shouldBuildMessageIndex(info) {
		indexed, err := indexedMessagesFromFile(file)
		if err != nil {
			return MessagePage{}, err
		}
		storeCachedMessageIndex(path, info, indexed)
		page := pageFromIndexedMessages(indexed, beforeOffset, limit)
		storeCachedMessagePage(path, info, beforeOffset, limit, page)
		return cloneMessagePage(page), nil
	}

	page, err := messagesPageFromTail(file, beforeOffset, limit)
	if err != nil {
		return MessagePage{}, err
	}
	storeCachedMessagePage(path, info, beforeOffset, limit, page)
	return cloneMessagePage(page), nil
}

func (s ThreadStore) RolloutPath(threadID string) (string, error) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return "", os.ErrNotExist
	}
	db := s.databasePath()
	signature, err := readDBSignature(db)
	if err != nil {
		return "", err
	}
	cacheKey := rolloutDBPathCacheKey(db, threadID)
	if path, ok := cachedRolloutDBPath(cacheKey, signature); ok {
		if cachedRolloutPathExists(path) {
			return path, nil
		}
		return "", os.ErrNotExist
	}

	out, err := sqliteQueryFunc(db, "select rollout_path from threads where id = "+sqlQuote(threadID)+" limit 1")
	if err != nil {
		return "", err
	}
	var rows []struct {
		RolloutPath string `json:"rollout_path"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return "", err
	}
	if len(rows) == 0 {
		return "", os.ErrNotExist
	}
	path := strings.TrimSpace(rows[0].RolloutPath)
	if path == "" {
		return "", os.ErrNotExist
	}
	if !cachedRolloutPathExists(path) {
		return "", os.ErrNotExist
	}
	storeRolloutDBPath(cacheKey, signature, path)
	return path, nil
}

func rolloutPath(threadID string) (string, error) {
	return defaultThreadStore().RolloutPath(threadID)
}

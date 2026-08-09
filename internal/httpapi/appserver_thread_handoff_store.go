package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
)

const (
	appServerThreadHandoffStoreVersion  = 1
	appServerThreadHandoffStoreMaxBytes = 128 * 1024
	appServerThreadHandoffStoreLimit    = 512
)

type appServerThreadHandoffStoreFile struct {
	Version           int      `json:"version"`
	UnarchiveRequired []string `json:"unarchive_required,omitempty"`
}

// appServerThreadHandoffRecoveryStore 是 archive -> unarchive 极短事务的恢复日志。
// 必须先把 thread_id 原子落盘再 archive，只有 unarchive 成功且日志清理成功后，
// 才能把 thread 当作已释放；这样 agentd 在任意一步退出都不会永久隐藏用户会话。
type appServerThreadHandoffRecoveryStore struct {
	mu       sync.Mutex
	path     string
	disabled bool
	loadErr  error
	entries  map[string]struct{}
}

var appServerThreadHandoffStoreWriteMu sync.Mutex

func newAppServerThreadHandoffRecoveryStore(path string) *appServerThreadHandoffRecoveryStore {
	store := &appServerThreadHandoffRecoveryStore{entries: map[string]struct{}{}}
	path = strings.TrimSpace(path)
	if path == "" {
		// 仅旧构造器和普通单元测试使用内存模式；agentd 生产入口始终注入绝对路径。
		store.disabled = true
		return store
	}
	if !filepath.IsAbs(path) {
		store.loadErr = fmt.Errorf("thread handoff 恢复日志必须使用绝对路径")
		return store
	}
	store.path = filepath.Clean(path)
	stored, err := store.load()
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			store.loadErr = err
		}
		return store
	}
	for _, threadID := range stored.UnarchiveRequired {
		threadID = strings.TrimSpace(threadID)
		if threadID != "" {
			store.entries[threadID] = struct{}{}
		}
	}
	return store
}

func (s *appServerThreadHandoffRecoveryStore) LoadError() error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadErr
}

func (s *appServerThreadHandoffRecoveryStore) ThreadIDs() []string {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]string, 0, len(s.entries))
	for threadID := range s.entries {
		result = append(result, threadID)
	}
	sort.Strings(result)
	return result
}

func (s *appServerThreadHandoffRecoveryStore) RequiresUnarchive(threadID string) bool {
	if s == nil {
		return false
	}
	threadID = strings.TrimSpace(threadID)
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.entries[threadID]
	return ok
}

func (s *appServerThreadHandoffRecoveryStore) MarkUnarchiveRequired(threadID string) error {
	if s == nil {
		return fmt.Errorf("thread handoff 恢复日志未初始化")
	}
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return fmt.Errorf("thread_id 不能为空")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.loadErr != nil {
		return fmt.Errorf("thread handoff 恢复日志不可用：%w", s.loadErr)
	}
	if _, ok := s.entries[threadID]; ok {
		return nil
	}
	next := cloneThreadHandoffStoreEntries(s.entries)
	next[threadID] = struct{}{}
	if len(next) > appServerThreadHandoffStoreLimit {
		return fmt.Errorf("thread handoff 恢复日志超过数量上限")
	}
	if err := s.saveEntries(next); err != nil {
		return err
	}
	s.entries = next
	return nil
}

func (s *appServerThreadHandoffRecoveryStore) ClearUnarchiveRequired(threadID string) error {
	if s == nil {
		return fmt.Errorf("thread handoff 恢复日志未初始化")
	}
	threadID = strings.TrimSpace(threadID)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.loadErr != nil {
		return fmt.Errorf("thread handoff 恢复日志不可用：%w", s.loadErr)
	}
	if _, ok := s.entries[threadID]; !ok {
		return nil
	}
	next := cloneThreadHandoffStoreEntries(s.entries)
	delete(next, threadID)
	if err := s.saveEntries(next); err != nil {
		return err
	}
	s.entries = next
	return nil
}

func cloneThreadHandoffStoreEntries(source map[string]struct{}) map[string]struct{} {
	result := make(map[string]struct{}, len(source))
	for threadID := range source {
		result[threadID] = struct{}{}
	}
	return result
}

func (s *appServerThreadHandoffRecoveryStore) load() (appServerThreadHandoffStoreFile, error) {
	info, err := os.Lstat(s.path)
	if err != nil {
		return appServerThreadHandoffStoreFile{}, err
	}
	if !info.Mode().IsRegular() {
		return appServerThreadHandoffStoreFile{}, fmt.Errorf("thread handoff 恢复日志不是普通文件")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return appServerThreadHandoffStoreFile{}, fmt.Errorf("thread handoff 恢复日志权限过宽")
	}
	if info.Size() <= 0 || info.Size() > appServerThreadHandoffStoreMaxBytes {
		return appServerThreadHandoffStoreFile{}, fmt.Errorf("thread handoff 恢复日志大小无效")
	}
	raw, err := os.ReadFile(s.path)
	if err != nil {
		return appServerThreadHandoffStoreFile{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var stored appServerThreadHandoffStoreFile
	if err := decoder.Decode(&stored); err != nil {
		return appServerThreadHandoffStoreFile{}, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return appServerThreadHandoffStoreFile{}, fmt.Errorf("thread handoff 恢复日志包含尾随内容")
	}
	if stored.Version != appServerThreadHandoffStoreVersion {
		return appServerThreadHandoffStoreFile{}, fmt.Errorf("不支持的 thread handoff 恢复日志版本 %d", stored.Version)
	}
	if len(stored.UnarchiveRequired) > appServerThreadHandoffStoreLimit {
		return appServerThreadHandoffStoreFile{}, fmt.Errorf("thread handoff 恢复日志超过数量上限")
	}
	seen := make(map[string]struct{}, len(stored.UnarchiveRequired))
	for _, rawThreadID := range stored.UnarchiveRequired {
		threadID := strings.TrimSpace(rawThreadID)
		if threadID == "" || threadID != rawThreadID {
			return appServerThreadHandoffStoreFile{}, fmt.Errorf("thread handoff 恢复日志包含无效 thread_id")
		}
		if _, ok := seen[threadID]; ok {
			return appServerThreadHandoffStoreFile{}, fmt.Errorf("thread handoff 恢复日志包含重复 thread_id")
		}
		seen[threadID] = struct{}{}
	}
	return stored, nil
}

func (s *appServerThreadHandoffRecoveryStore) saveEntries(entries map[string]struct{}) error {
	if s.disabled {
		return nil
	}
	threadIDs := make([]string, 0, len(entries))
	for threadID := range entries {
		threadIDs = append(threadIDs, threadID)
	}
	sort.Strings(threadIDs)
	raw, err := json.Marshal(appServerThreadHandoffStoreFile{
		Version:           appServerThreadHandoffStoreVersion,
		UnarchiveRequired: threadIDs,
	})
	if err != nil {
		return err
	}
	if len(raw)+1 > appServerThreadHandoffStoreMaxBytes {
		return fmt.Errorf("thread handoff 恢复日志编码后超过大小上限")
	}

	appServerThreadHandoffStoreWriteMu.Lock()
	defer appServerThreadHandoffStoreWriteMu.Unlock()
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	dirInfo, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !dirInfo.IsDir() || dirInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("thread handoff 恢复日志目录无效")
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	staged, err := os.CreateTemp(dir, ".thread-handoff-recovery-*.tmp")
	if err != nil {
		return err
	}
	stagedPath := staged.Name()
	cleanup := true
	defer func() {
		_ = staged.Close()
		if cleanup {
			_ = os.Remove(stagedPath)
		}
	}()
	if runtime.GOOS != "windows" {
		if err := staged.Chmod(0o600); err != nil {
			return err
		}
	}
	if _, err := staged.Write(append(raw, '\n')); err != nil {
		return err
	}
	if err := staged.Sync(); err != nil {
		return err
	}
	if err := staged.Close(); err != nil {
		return err
	}
	if err := os.Rename(stagedPath, s.path); err != nil {
		return err
	}
	cleanup = false
	if runtime.GOOS != "windows" {
		if err := os.Chmod(s.path, 0o600); err != nil {
			return err
		}
		dirFile, err := os.Open(dir)
		if err != nil {
			return err
		}
		syncErr := dirFile.Sync()
		closeErr := dirFile.Close()
		if syncErr != nil {
			return syncErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

package appserver

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	writerLockDirName      = "thread-writer-locks"
	writerLockSuffix       = ".lock"
	writerLockCacheTTL     = 3 * time.Second
	writerLockFirstWait    = 350 * time.Millisecond
	writerLockLookupBudget = 2 * time.Second
	// lsof 的参数长度有上限；同时被持有的会话通常只有个位数，超出时只查前面这些。
	writerLockMaxPaths = 256
)

// WriterLockInspector 只读地回答“哪些 Codex 会话的 writer 锁正被某个进程持有”。
//
// 普通 Desktop “This Mac” 和 Mimi 使用的共享 App Server 是两个实例，公开协议查不到另一个
// 实例的占用，共享实例对这类会话只会回 notLoaded。Codex 在 CODEX_HOME 下为每个持有 writer
// 的会话保留一个锁文件，释放时删除，所以目录能实时给出候选，再用 lsof 排除崩溃遗留的文件。
//
// 这里绝不打开、加锁或删除锁文件：试探性加锁可能让真正的 writer 抢锁失败。目录格式不是公开
// 接口，任何一步失败都按“不知道”上报，调用方不得据此下结论。
//
// lsof 要扫全部进程（实测 200 ms 以上），而调用方在网关响应通道上，不能排队等它：
// 只有第一次遇到候选时短暂等待，之后读缓存并在后台刷新。
type WriterLockInspector struct {
	dir       string
	ttl       time.Duration
	firstWait time.Duration
	lookup    func(ctx context.Context, paths []string) (map[string]bool, error)

	mu          sync.Mutex
	verdicts    map[string]bool
	refreshedAt time.Time
	refreshing  chan struct{}
}

// NewWriterLockInspector 按 App Server 实际使用的 CODEX_HOME 创建检查器。
func NewWriterLockInspector(codexHome string) *WriterLockInspector {
	return &WriterLockInspector{
		dir:       filepath.Join(codexHome, writerLockDirName),
		ttl:       writerLockCacheTTL,
		firstWait: writerLockFirstWait,
		lookup:    lsofOpenWriterLocks,
	}
}

// HeldThreads 返回 threadIDs 中锁正被持有的子集。known=false 表示至少有一条无法确认，
// 这些会话既不在结果里，也不能当成未被持有。
func (i *WriterLockInspector) HeldThreads(threadIDs []string) (held map[string]struct{}, known bool) {
	if i == nil {
		return nil, false
	}
	entries, err := os.ReadDir(i.dir)
	if err != nil {
		// 没有目录说明没有任何会话持有 writer，或这个 Codex 版本不用这种格式；后者由
		// 下面的 known 口径兜底不了，但此时本来也不会产生任何“已占用”的结论。
		return nil, errors.Is(err, os.ErrNotExist)
	}
	present := make(map[string]struct{}, len(entries))
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), writerLockSuffix)
		if !ok || id == "" || entry.IsDir() {
			continue
		}
		present[id] = struct{}{}
		if len(paths) < writerLockMaxPaths {
			paths = append(paths, filepath.Join(i.dir, entry.Name()))
		}
	}
	candidates := make([]string, 0, len(threadIDs))
	for _, id := range threadIDs {
		if _, ok := present[id]; ok {
			candidates = append(candidates, id)
		}
	}
	if len(candidates) == 0 {
		return nil, true
	}

	i.waitForFirstVerdict(i.refreshIfStale(paths))

	i.mu.Lock()
	defer i.mu.Unlock()
	known = true
	for _, id := range candidates {
		isHeld, ok := i.verdicts[id]
		if !ok {
			known = false
			continue
		}
		if isHeld {
			if held == nil {
				held = make(map[string]struct{}, len(candidates))
			}
			held[id] = struct{}{}
		}
	}
	return held, known
}

// refreshIfStale 在缓存过期时启动唯一的后台刷新。返回值只在还没有任何结论时非空。
func (i *WriterLockInspector) refreshIfStale(paths []string) <-chan struct{} {
	i.mu.Lock()
	defer i.mu.Unlock()
	firstLookup := i.verdicts == nil
	if i.refreshing == nil && time.Since(i.refreshedAt) >= i.ttl {
		done := make(chan struct{})
		i.refreshing = done
		go i.refresh(paths, done)
	}
	if firstLookup {
		return i.refreshing
	}
	return nil
}

func (i *WriterLockInspector) waitForFirstVerdict(done <-chan struct{}) {
	if done == nil {
		return
	}
	timer := time.NewTimer(i.firstWait)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	}
}

func (i *WriterLockInspector) refresh(paths []string, done chan struct{}) {
	ctx, cancel := context.WithTimeout(context.Background(), writerLockLookupBudget)
	defer cancel()
	open, err := i.lookup(ctx, paths)

	i.mu.Lock()
	defer i.mu.Unlock()
	defer close(done)
	i.refreshing = nil
	// 失败也计入时间，避免 lsof 缺失或超时时每个列表请求都再起一个进程。
	i.refreshedAt = time.Now()
	if err != nil {
		i.verdicts = nil
		return
	}
	verdicts := make(map[string]bool, len(paths))
	for _, path := range paths {
		id := strings.TrimSuffix(filepath.Base(path), writerLockSuffix)
		verdicts[id] = open[filepath.Base(path)]
	}
	i.verdicts = verdicts
}

// lsofOpenWriterLocks 返回至少被一个进程打开的锁文件名。lsof 在部分文件没人打开或已被删除
// 时也以 1 退出，这是正常结果，所以只把启动失败和超时当错误。
func lsofOpenWriterLocks(ctx context.Context, paths []string) (map[string]bool, error) {
	args := append([]string{"-nP", "-Fn", "--"}, paths...)
	var stdout bytes.Buffer
	cmd := exec.CommandContext(ctx, "lsof", args...)
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) || ctx.Err() != nil || exitErr.ExitCode() != 1 {
			return nil, err
		}
	}
	return parseLsofOpenFiles(stdout.Bytes()), nil
}

func parseLsofOpenFiles(output []byte) map[string]bool {
	open := map[string]bool{}
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		line := scanner.Text()
		if name, ok := strings.CutPrefix(line, "n"); ok {
			// 按文件名比较：lsof 会解析符号链接，打印的目录可能与传入的不同。
			open[filepath.Base(name)] = true
		}
	}
	return open
}

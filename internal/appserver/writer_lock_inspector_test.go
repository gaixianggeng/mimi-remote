package appserver

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func newTestWriterLockInspector(t *testing.T, ids ...string) *WriterLockInspector {
	t.Helper()
	home := t.TempDir()
	inspector := NewWriterLockInspector(home)
	if err := os.MkdirAll(inspector.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		if err := os.WriteFile(filepath.Join(inspector.dir, id+writerLockSuffix), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return inspector
}

func TestWriterLockInspectorMissingDirectoryMeansNothingHeld(t *testing.T) {
	inspector := NewWriterLockInspector(t.TempDir())
	inspector.lookup = func(context.Context, []string) (map[string]bool, error) {
		t.Fatal("没有锁文件时不应启动 lsof")
		return nil, nil
	}
	held, known := inspector.HeldThreads([]string{"a"})
	if len(held) != 0 || !known {
		t.Fatalf("held=%v known=%t", held, known)
	}
}

func TestWriterLockInspectorSkipsLookupWithoutCandidates(t *testing.T) {
	inspector := newTestWriterLockInspector(t, "other")
	inspector.lookup = func(context.Context, []string) (map[string]bool, error) {
		t.Fatal("请求的会话都没有锁文件时不应启动 lsof")
		return nil, nil
	}
	held, known := inspector.HeldThreads([]string{"a"})
	if len(held) != 0 || !known {
		t.Fatalf("held=%v known=%t", held, known)
	}
}

func TestWriterLockInspectorDistinguishesHeldFromStaleFile(t *testing.T) {
	inspector := newTestWriterLockInspector(t, "held", "stale")
	inspector.lookup = func(context.Context, []string) (map[string]bool, error) {
		return map[string]bool{"held" + writerLockSuffix: true}, nil
	}
	held, known := inspector.HeldThreads([]string{"held", "stale", "absent"})
	if !known {
		t.Fatal("lsof 成功时应能确认")
	}
	if _, ok := held["held"]; !ok || len(held) != 1 {
		t.Fatalf("只有被打开的锁算持有：%v", held)
	}
}

func TestWriterLockInspectorLookupFailureIsUnknownNotFree(t *testing.T) {
	inspector := newTestWriterLockInspector(t, "held")
	inspector.lookup = func(context.Context, []string) (map[string]bool, error) {
		return nil, errors.New("lsof 不可用")
	}
	held, known := inspector.HeldThreads([]string{"held"})
	if len(held) != 0 || known {
		t.Fatalf("查询失败不能当成未持有：held=%v known=%t", held, known)
	}
}

func TestWriterLockInspectorReleaseIsVisibleBeforeCacheExpires(t *testing.T) {
	inspector := newTestWriterLockInspector(t, "held")
	inspector.lookup = func(context.Context, []string) (map[string]bool, error) {
		return map[string]bool{"held" + writerLockSuffix: true}, nil
	}
	if held, _ := inspector.HeldThreads([]string{"held"}); len(held) != 1 {
		t.Fatalf("held=%v", held)
	}
	if err := os.Remove(filepath.Join(inspector.dir, "held"+writerLockSuffix)); err != nil {
		t.Fatal(err)
	}
	held, known := inspector.HeldThreads([]string{"held"})
	if len(held) != 0 || !known {
		t.Fatalf("锁文件删除后应立即视为释放：held=%v known=%t", held, known)
	}
}

func TestWriterLockInspectorCachesLookupsWithinTTL(t *testing.T) {
	inspector := newTestWriterLockInspector(t, "held")
	var calls atomic.Int32
	inspector.lookup = func(context.Context, []string) (map[string]bool, error) {
		calls.Add(1)
		return map[string]bool{"held" + writerLockSuffix: true}, nil
	}
	for range 5 {
		inspector.HeldThreads([]string{"held"})
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("TTL 内应只查询一次，实际 %d 次", got)
	}
}

// 慢查询不能卡住网关响应通道：第一次最多等 firstWait，之后立刻返回。
func TestWriterLockInspectorDoesNotBlockOnSlowLookup(t *testing.T) {
	inspector := newTestWriterLockInspector(t, "held")
	inspector.firstWait = 20 * time.Millisecond
	release := make(chan struct{})
	defer close(release)
	inspector.lookup = func(ctx context.Context, _ []string) (map[string]bool, error) {
		<-release
		return nil, ctx.Err()
	}
	start := time.Now()
	held, known := inspector.HeldThreads([]string{"held"})
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("等待过久：%s", elapsed)
	}
	if len(held) != 0 || known {
		t.Fatalf("查询未完成时应为未知：held=%v known=%t", held, known)
	}
}

func TestWriterLockInspectorLsofSeesOpenFile(t *testing.T) {
	if _, err := exec.LookPath("lsof"); err != nil {
		t.Skip("当前环境没有 lsof")
	}
	inspector := newTestWriterLockInspector(t, "held", "stale")
	file, err := os.Open(filepath.Join(inspector.dir, "held"+writerLockSuffix))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	inspector.firstWait = 10 * time.Second
	held, known := inspector.HeldThreads([]string{"held", "stale"})
	if !known {
		t.Fatal("lsof 应能给出结论")
	}
	if _, ok := held["held"]; !ok || len(held) != 1 {
		t.Fatalf("held=%v", held)
	}
}

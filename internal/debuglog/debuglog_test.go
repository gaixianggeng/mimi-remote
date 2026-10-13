package debuglog

import (
	"bytes"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func TestPrintfWritesOnlyInsideTheDiagnosticWindow(t *testing.T) {
	var out syncBuffer
	var window atomic.Bool
	sink := New(&out, window.Load)
	restore := Install(sink)
	defer restore()

	Printf("gateway", "before window")
	if Enabled() {
		t.Fatal("窗口外不应报告启用")
	}
	window.Store(true)
	Printf("gateway", "inside window method=%s", "thread/list")
	window.Store(false)
	Printf("gateway", "after window")
	sink.Close()

	text := out.String()
	if strings.Contains(text, "before window") || strings.Contains(text, "after window") {
		t.Fatalf("窗口外不应写入：%q", text)
	}
	line := strings.TrimSpace(text)
	fields := strings.SplitN(line, " ", 3)
	if len(fields) != 3 || fields[1] != "gateway" || fields[2] != "inside window method=thread/list" {
		t.Fatalf("行格式不对：%q", line)
	}
	if _, err := time.Parse(time.RFC3339Nano, fields[0]); err != nil {
		t.Fatalf("时间戳不是 RFC3339：%q", fields[0])
	}
}

func TestSanitizeRedactsCredentialsHomeAndLineBreaks(t *testing.T) {
	got := Sanitize("Authorization: Bearer abc.DEF-123 token=s3cr3t api_key: \"k-1\" https://user:pw@example.com/x /Users/me/code/repo\nnext", "/Users/me")
	for _, leaked := range []string{"abc.DEF-123", "s3cr3t", "k-1", "user:pw", "/Users/me", "\n"} {
		if strings.Contains(got, leaked) {
			t.Fatalf("没有脱敏 %q：%q", leaked, got)
		}
	}
	for _, kept := range []string{"Authorization: <redacted>", "token=<redacted>", "https://<redacted>@example.com/x", "~/code/repo", "next"} {
		if !strings.Contains(got, kept) {
			t.Fatalf("缺少 %q：%q", kept, got)
		}
	}
}

type blockingWriter struct {
	release chan struct{}
	out     syncBuffer
}

func (w *blockingWriter) Write(p []byte) (int, error) {
	<-w.release
	return w.out.Write(p)
}

func TestFullQueueDropsInsteadOfBlocking(t *testing.T) {
	writer := &blockingWriter{release: make(chan struct{})}
	sink := New(writer, func() bool { return true })
	restore := Install(sink)
	defer restore()

	done := make(chan struct{})
	go func() {
		for i := 0; i < queueSize*2; i++ {
			Printf("gateway", "line %d", i)
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("磁盘卡住时记录方不应被阻塞")
	}
	if sink.Dropped() == 0 {
		t.Fatal("队列满时应丢弃并计数")
	}
	close(writer.release)
	sink.Close()
}

func TestLongLinesAreTruncated(t *testing.T) {
	var out syncBuffer
	sink := New(&out, func() bool { return true })
	restore := Install(sink)
	defer restore()
	Printf("claude-bridge", "%s", strings.Repeat("x", maxLineBytes*2))
	sink.Close()
	if line := strings.TrimSuffix(out.String(), "\n"); len(line) > maxLineBytes+len("…") {
		t.Fatalf("超长行没有截断：%d 字节", len(line))
	}
}

type slowWriter struct {
	mu    sync.Mutex
	lines int
	gate  chan struct{}
}

func (w *slowWriter) Write(p []byte) (int, error) {
	<-w.gate
	w.mu.Lock()
	w.lines++
	w.mu.Unlock()
	return len(p), nil
}

func (w *slowWriter) count() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.lines
}

func TestSyncRunsAfterEveryEarlierQueuedLine(t *testing.T) {
	writer := &slowWriter{gate: make(chan struct{})}
	sink := New(writer, func() bool { return true })
	restore := Install(sink)
	defer restore()
	for i := 0; i < 10; i++ {
		Printf("gateway", "queued %d", i)
	}
	seen := make(chan int, 1)
	go func() {
		_ = sink.Sync(func() error {
			seen <- writer.count()
			return nil
		})
	}()
	close(writer.gate)
	select {
	case written := <-seen:
		if written != 10 {
			t.Fatalf("屏障执行时应已写完之前排队的 10 行，实际 %d 行", written)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("屏障没有执行")
	}
	sink.Close()
}

package diagnosticlog

import (
	"bytes"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestRecorderDefaultsExpiryAndStop(t *testing.T) {
	var output bytes.Buffer
	r, err := New(&output)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	now := time.Now()
	r.now = func() time.Time { return now }
	r.Record("rpc_request", "sent", Fields{Operation: "turn/start"})
	if output.Len() != 0 {
		t.Fatal("详细日志应默认关闭")
	}
	r.Record("http", "failed", Fields{StatusCode: 503})
	if err := r.Sync(nil); err != nil {
		t.Fatal(err)
	}
	if output.Len() == 0 {
		t.Fatal("必要故障必须默认保留")
	}
	output.Reset()
	r.Start()
	r.Record("rpc_request", "sent", Fields{Operation: "turn/start"})
	if err := r.Sync(nil); err != nil {
		t.Fatal(err)
	}
	if output.Len() == 0 || r.ExpiresAt() == nil {
		t.Fatal("详细窗口未开启")
	}
	output.Reset()
	now = now.Add(DetailDuration)
	r.Record("rpc_request", "sent", Fields{})
	if output.Len() != 0 || r.ExpiresAt() != nil {
		t.Fatal("到期后必须立即停止详细采集")
	}
	r.Start()
	r.Stop()
	r.Record("rpc_request", "sent", Fields{})
	if output.Len() != 0 {
		t.Fatal("手动停止后仍在写入")
	}
}

type failOnceWriter struct {
	failed bool
	output bytes.Buffer
}

func (w *failOnceWriter) Write(data []byte) (int, error) {
	if !w.failed {
		w.failed = true
		return 0, errors.New("disk unavailable")
	}
	return w.output.Write(data)
}

func TestRecorderReportsLostRecordsAfterDiskRecovers(t *testing.T) {
	w := &failOnceWriter{}
	r, _ := New(w)
	defer r.Close()
	r.Record("service", "started", Fields{})
	if err := r.Sync(nil); err != nil {
		t.Fatal(err)
	}
	if r.WriteError() == nil || r.Dropped() != 1 {
		t.Fatal("写入失败必须可见并计入缺失记录")
	}
	r.Record("service", "started", Fields{})
	if err := r.Sync(nil); err != nil {
		t.Fatal(err)
	}
	if r.WriteError() != nil || r.Dropped() != 1 {
		t.Fatal("恢复后保留缺失计数，不能强迫删除现有证据")
	}
}

type blockedLogWriter struct {
	once    sync.Once
	entered chan struct{}
	release chan struct{}
}

func (w *blockedLogWriter) Write(data []byte) (int, error) {
	w.once.Do(func() { close(w.entered) })
	<-w.release
	return len(data), nil
}

func TestRecorderNeverBlocksCallerOnSlowDiskAndDrainsOnClose(t *testing.T) {
	w := &blockedLogWriter{entered: make(chan struct{}), release: make(chan struct{})}
	r, _ := New(w)
	r.Record("http", "failed", Fields{StatusCode: 500})
	<-w.entered
	done := make(chan struct{})
	go func() {
		for i := 0; i < 1000; i++ {
			r.Record("http", "failed", Fields{StatusCode: 500})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		close(w.release)
		r.Close()
		t.Fatal("慢盘阻塞业务调用")
	}
	if r.Dropped() == 0 {
		close(w.release)
		r.Close()
		t.Fatal("队列必须有界")
	}
	close(w.release)
	if err := r.Stop(); err != nil {
		t.Fatal(err)
	}
	r.Close()
	// 与卸载相撞的最后一次调用应安全丢弃，不能向已关闭channel发送。
	r.Record("http", "failed", Fields{StatusCode: 500})
	if err := r.Sync(nil); err == nil {
		t.Fatal("关闭后控制调用应报告不可用")
	}
}

func TestRecorderShutdownDrainsAcceptedEvents(t *testing.T) {
	var output bytes.Buffer
	r, _ := New(&output)
	for i := 0; i < 100; i++ {
		r.Record("service", "started", Fields{})
	}
	r.Close()
	if strings.Count(output.String(), "\n") != 100 {
		t.Fatal("退出前必须落盘已经接受的记录")
	}
}

func TestDiagnosticSchemaRejectsUserFieldsAndReserializes(t *testing.T) {
	now := time.Now().UTC()
	base := Event{At: now, Stage: "http", Outcome: "failed"}
	for _, field := range []string{"stage", "outcome", "operation", "reference"} {
		e := base
		switch field {
		case "stage":
			e.Stage = "/private/project"
		case "outcome":
			e.Outcome = "secret error"
		case "operation":
			e.Operation = "http://example.invalid"
		case "reference":
			e.Reference = "session-id"
		}
		if _, ok := Format(e); ok {
			t.Fatalf("未拒绝用户字段 %s", field)
		}
	}
	line, _ := Format(base)
	line = strings.TrimSuffix(line, "}") + `,"message":"private body","token":"fake-private-token"}`
	e, ok := Parse(line)
	if !ok {
		t.Fatal("固定字段应该可读")
	}
	safe, _ := Format(e)
	if strings.Contains(safe, "private") || strings.Contains(safe, "token") {
		t.Fatal("导出泄露未知字段")
	}
}

func TestReferencesAreProcessScoped(t *testing.T) {
	r, _ := New(&bytes.Buffer{})
	defer r.Close()
	restore := Install(r)
	a := Reference("private-thread-id")
	if a == "" || a != Reference("private-thread-id") || strings.Contains(a, "private") {
		t.Fatal("关联标记无效")
	}
	restore()
	next, _ := New(&bytes.Buffer{})
	defer next.Close()
	restore = Install(next)
	defer restore()
	if a == Reference("private-thread-id") {
		t.Fatal("关联标记不应跨进程稳定")
	}
}

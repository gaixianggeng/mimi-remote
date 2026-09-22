// Package diagnosticlog 只接受固定阶段和结果，不收集业务载荷或错误原文。
package diagnosticlog

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const DetailDuration = 15 * time.Minute

type Event struct {
	At             time.Time `json:"at"`
	Stage          string    `json:"stage"`
	Outcome        string    `json:"outcome"`
	Operation      string    `json:"operation,omitempty"`
	Reference      string    `json:"reference,omitempty"`
	StatusCode     int       `json:"status_code,omitempty"`
	DurationMillis int64     `json:"duration_ms,omitempty"`
}

type Fields struct {
	Operation  string
	Reference  string
	StatusCode int
	Duration   time.Duration
}

type writeOperation struct {
	line    string
	control func() error
	done    chan error
}

// 业务线程只做有界入队。慢盘、导出或清理不得持有网关状态锁等待磁盘。
type Recorder struct {
	mu        sync.Mutex
	controlMu sync.Mutex
	output    io.Writer
	now       func() time.Time
	expiresAt time.Time
	writeErr  error
	salt      [32]byte
	queue     chan writeOperation
	done      chan struct{}
	closed    bool
	dropped   int64
}

var active atomic.Pointer[Recorder]

func New(output io.Writer) (*Recorder, error) {
	r := &Recorder{output: output, now: time.Now, queue: make(chan writeOperation, 256), done: make(chan struct{})}
	if _, err := rand.Read(r.salt[:]); err != nil {
		return nil, err
	}
	go r.writeLoop()
	return r, nil
}

func (r *Recorder) writeLoop() {
	defer close(r.done)
	for operation := range r.queue {
		if operation.done != nil {
			var err error
			if operation.control != nil {
				err = operation.control()
			}
			operation.done <- err
			continue
		}
		_, err := io.WriteString(r.output, operation.line+"\n")
		r.mu.Lock()
		r.writeErr = err
		if err != nil {
			r.dropped++
		}
		r.mu.Unlock()
	}
}

func Install(r *Recorder) func() {
	previous := active.Swap(r)
	return func() { active.CompareAndSwap(r, previous) }
}

func Record(stage, outcome string, fields Fields) {
	if r := active.Load(); r != nil {
		r.Record(stage, outcome, fields)
	}
}

func Reference(value string) string {
	if value == "" {
		return ""
	}
	r := active.Load()
	if r == nil {
		return ""
	}
	mac := hmac.New(sha256.New, r.salt[:])
	_, _ = mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil)[:8])
}

func (r *Recorder) Start() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.expiresAt = r.now().Add(DetailDuration)
}

func (r *Recorder) Stop() error {
	r.mu.Lock()
	r.expiresAt = time.Time{}
	r.mu.Unlock()
	return r.Sync(nil)
}

func (r *Recorder) ExpiresAt() *time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.now().Before(r.expiresAt) {
		return nil
	}
	value := r.expiresAt.UTC()
	return &value
}

func (r *Recorder) Record(stage, outcome string, fields Fields) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	if r.closed {
		return
	}
	// 正常高频阶段只在临时详细窗口内记录，故障和服务启停始终保留。
	if outcome != "failed" && stage != "service" && !now.Before(r.expiresAt) {
		return
	}
	event := Event{At: now.UTC(), Stage: stage, Outcome: outcome, Operation: fields.Operation,
		Reference: fields.Reference, StatusCode: fields.StatusCode, DurationMillis: max(0, fields.Duration.Milliseconds())}
	line, ok := Format(event)
	if ok {
		// 为故障预留 63 条，为串行控制命令预留 1 个位置；满队列绝不阻塞请求。
		limit := cap(r.queue) - 1
		if outcome != "failed" {
			limit = 192
		}
		if len(r.queue) >= limit {
			r.dropped++
			return
		}
		r.queue <- writeOperation{line: line}
	}
}

func (r *Recorder) WriteError() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.writeErr
}

// Sync 是写入队列屏障：之前的记录已落盘，控制操作与之后的记录不会交错。
func (r *Recorder) Sync(fn func() error) error {
	r.controlMu.Lock()
	defer r.controlMu.Unlock()
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return io.ErrClosedPipe
	}
	done := make(chan error, 1)
	// 只有一个控制调用可入队；记录始终留出一个空位，因此此处不会等待磁盘。
	r.queue <- writeOperation{control: fn, done: done}
	r.mu.Unlock()
	return <-done
}

func (r *Recorder) ClearError() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.writeErr = nil
	r.dropped = 0
}

func (r *Recorder) Dropped() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.dropped
}

func (r *Recorder) Close() {
	r.controlMu.Lock()
	defer r.controlMu.Unlock()
	r.mu.Lock()
	if !r.closed {
		r.closed = true
		close(r.queue)
	}
	r.mu.Unlock()
	<-r.done
}

func Format(event Event) (string, bool) {
	if !valid(event) {
		return "", false
	}
	data, err := json.Marshal(event)
	return string(data), err == nil
}

// Parse 重建白名单结构，丢弃未知字段；导出绝不透传旧的自由文本日志。
func Parse(line string) (Event, bool) {
	var event Event
	if json.Unmarshal([]byte(line), &event) != nil || !valid(event) {
		return Event{}, false
	}
	return event, true
}

func valid(e Event) bool {
	if e.At.IsZero() || e.DurationMillis < 0 || (e.StatusCode != 0 && (e.StatusCode < 100 || e.StatusCode > 599)) {
		return false
	}
	switch e.Stage {
	case "service", "http", "gateway_connect", "gateway_disconnect", "rpc_request", "rpc_response", "policy", "turn_started", "turn_completed", "approval", "bridge", "permissions":
	default:
		return false
	}
	switch e.Outcome {
	case "started", "stopped", "sent", "received", "succeeded", "failed", "cancelled", "rejected":
	default:
		return false
	}
	if e.Operation != "" && Operation(e.Operation) != e.Operation {
		return false
	}
	if e.Reference != "" {
		if len(e.Reference) != 16 || strings.ToLower(e.Reference) != e.Reference {
			return false
		}
		if _, err := hex.DecodeString(e.Reference); err != nil {
			return false
		}
	}
	return true
}

// Operation 不使用路径、URL 或任意方法名作为日志字段，未知方法归为 other。
func Operation(method string) string {
	switch method {
	case "thread/list", "thread/read", "thread/resume", "thread/start", "thread/turns/list", "thread/items/list", "turn/start", "turn/steer", "turn/interrupt", "thread/takeover", "approval", "other":
		return method
	default:
		return "other"
	}
}

// Package debuglog 写本机调试日志：只在「详细记录」诊断窗口内，记录关键处的排查信息。
//
// 与 diagnosticlog 不同，这里可以写方法名、会话 ID 和错误原因，便于把一条链路串起来；
// 但仍不记录消息正文、提示词、工具输入输出、令牌与凭据。文件只留在本机，不进入
// 「导出安全日志」。窗口关闭或到期后不再写入；写盘走有界队列，满了就丢弃并计数，
// 绝不阻塞请求路径。
package debuglog

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	queueSize    = 1024
	maxLineBytes = 4096
)

// operation 是写入队列里的一项：一行日志，或一个控制操作（屏障）。
type operation struct {
	line    string
	control func() error
	done    chan error
}

type Sink struct {
	out     io.Writer
	enabled func() bool
	now     func() time.Time
	home    string
	queue   chan operation
	done    chan struct{}
	// 入队与 Sync 只取读锁，Close 取写锁后才关闭队列，避免向已关闭的队列发送。
	mu      sync.RWMutex
	closed  bool
	dropped atomic.Int64
}

var current atomic.Pointer[Sink]

// New 创建一个写入 out 的调试日志；enabled 决定此刻是否在诊断窗口内。
func New(out io.Writer, enabled func() bool) *Sink {
	home, _ := os.UserHomeDir()
	s := &Sink{out: out, enabled: enabled, now: time.Now, home: home, queue: make(chan operation, queueSize), done: make(chan struct{})}
	go s.writeLoop()
	return s
}

func (s *Sink) writeLoop() {
	defer close(s.done)
	for op := range s.queue {
		if op.done != nil {
			op.done <- op.control()
			continue
		}
		if _, err := io.WriteString(s.out, op.line+"\n"); err != nil {
			s.dropped.Add(1)
		}
	}
}

// Sync 是写入队列的屏障：之前排队的行全部写完后才执行 fn，返回 fn 的结果。用于清除文件，
// 保证清除之前排队的记录不会在清除之后被写回。队列满时会等待写入，不丢弃屏障。
func (s *Sink) Sync(fn func() error) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.closed {
		return fn()
	}
	done := make(chan error, 1)
	s.queue <- operation{control: fn, done: done}
	return <-done
}

// Install 设为进程内当前的调试日志，返回撤销函数。
func Install(s *Sink) func() {
	previous := current.Swap(s)
	return func() { current.CompareAndSwap(s, previous) }
}

// Enabled 报告是否在诊断窗口内；调用方可以据此跳过昂贵的字段准备。
func Enabled() bool {
	s := current.Load()
	return s != nil && s.enabled()
}

// Printf 记录一行：component 标明来源（gateway、claude-bridge 等），其余是自由文本。
func Printf(component, format string, args ...any) {
	s := current.Load()
	if s == nil || !s.enabled() {
		return
	}
	s.enqueue(component, fmt.Sprintf(format, args...))
}

func (s *Sink) enqueue(component, message string) {
	line := s.now().UTC().Format(time.RFC3339Nano) + " " + component + " " + Sanitize(message, s.home)
	if len(line) > maxLineBytes {
		line = line[:maxLineBytes] + "…"
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.closed {
		return
	}
	select {
	case s.queue <- operation{line: line}:
	default:
		s.dropped.Add(1)
	}
}

// Dropped 返回因队列已满或写盘失败而丢弃的行数。
func (s *Sink) Dropped() int64 {
	return s.dropped.Load()
}

// Close 写完已入队的行后停止。
func (s *Sink) Close() {
	s.mu.Lock()
	if !s.closed {
		s.closed = true
		close(s.queue)
	}
	s.mu.Unlock()
	<-s.done
}

var (
	bearerPattern   = regexp.MustCompile(`(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+`)
	secretPattern   = regexp.MustCompile(`(?i)\b([A-Za-z_-]*(?:token|secret|password|passwd|api[_-]?key|authorization|cookie)[A-Za-z_-]*)(["']?\s*[:=]\s*["']?)[^\s"',}&]+`)
	userinfoPattern = regexp.MustCompile(`(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@`)
	controlPattern  = regexp.MustCompile(`[\x00-\x08\x0b-\x1f\x7f]`)
)

// Sanitize 去掉令牌、凭据与 URL 里的用户信息，把用户主目录换成 ~，并去掉控制字符，
// 保证一条记录始终是一行。
func Sanitize(message, home string) string {
	message = strings.ReplaceAll(message, "\r", " ")
	message = strings.ReplaceAll(message, "\n", " ")
	message = controlPattern.ReplaceAllString(message, "")
	message = bearerPattern.ReplaceAllString(message, "$1 <redacted>")
	message = secretPattern.ReplaceAllString(message, "$1$2<redacted>")
	message = userinfoPattern.ReplaceAllString(message, "$1<redacted>@")
	if home != "" && home != "/" {
		message = strings.ReplaceAll(message, home, "~")
	}
	return message
}

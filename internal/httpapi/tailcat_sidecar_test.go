package httpapi

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// startFakeTailcatControl 在临时 unix socket 上起一个假辅助程序控制接口。
func startFakeTailcatControl(t *testing.T, handler http.Handler) string {
	t.Helper()
	// macOS 的 unix socket 路径上限约 104 字节，t.TempDir() 太长；用系统临时目录。
	dir, err := os.MkdirTemp("", "tailcat-ctl-")
	if err != nil {
		t.Fatalf("创建临时目录失败：%v", err)
	}
	socket := filepath.Join(dir, "control.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatalf("监听 unix socket 失败：%v", err)
	}
	server := &http.Server{Handler: handler}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		_ = server.Close()
		_ = os.RemoveAll(dir)
	})
	return socket
}

func slowTailcatControl(delay time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		time.Sleep(delay)
		writeJSON(w, http.StatusOK, map[string]any{
			"running":      true,
			"pair_address": "pair.example.invalid",
		})
	})
}

func TestTailcatSupervisorPairWaitsLongerThanControlCalls(t *testing.T) {
	socket := startFakeTailcatControl(t, slowTailcatControl(150*time.Millisecond))
	supervisor := &tailcatSidecarSupervisor{
		controlPath:    socket,
		controlTimeout: 40 * time.Millisecond,
		pairTimeout:    2 * time.Second,
	}

	status, err := supervisor.Pair(context.Background())
	if err != nil {
		t.Fatalf("配对应等到辅助程序返回，而不是按普通控制超时失败：%v", err)
	}
	if status.PairAddress != "pair.example.invalid" {
		t.Fatalf("配对结果未透传：%+v", status)
	}

	var probe tailcatStatus
	err = supervisor.call(context.Background(), supervisor.controlCallTimeout(), http.MethodGet, "/status", nil, &probe)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("普通控制调用仍应受短超时约束，got %v", err)
	}
}

func TestTailcatSupervisorPairTimeoutExplainsRetry(t *testing.T) {
	socket := startFakeTailcatControl(t, slowTailcatControl(300*time.Millisecond))
	supervisor := &tailcatSidecarSupervisor{
		controlPath: socket,
		pairTimeout: 50 * time.Millisecond,
	}

	_, err := supervisor.Pair(context.Background())
	if err == nil {
		t.Fatal("超过配对超时应返回错误")
	}
	message := err.Error()
	if !strings.Contains(message, "稍后重试") || !strings.Contains(message, "中继授权") {
		t.Fatalf("超时错误应说明授权未完成、可重试，got %q", message)
	}
	if strings.Contains(message, "context deadline exceeded") || strings.Contains(message, "tailcat.local") {
		t.Fatalf("超时错误不应把底层 HTTP 细节交给用户，got %q", message)
	}
}

// fakePairingSidecar 模拟辅助程序的配对语义：每次 /pair 都生成新节点；配对期间持有状态锁，
// 所以 /status 会等到那次配对结束（与 managed.Manager.StartPairing 一致）。
type fakePairingSidecar struct {
	mu        sync.Mutex
	delay     time.Duration
	ttl       time.Duration
	pairCalls atomic.Int32
	address   string
	expiresAt time.Time
}

func (f *fakePairingSidecar) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	switch req.URL.Path {
	case "/pair":
		call := f.pairCalls.Add(1)
		f.mu.Lock()
		time.Sleep(f.delay)
		f.address = fmt.Sprintf("pair-%d.example.invalid", call)
		f.expiresAt = time.Now().Add(f.ttl)
		status := f.statusLocked()
		f.mu.Unlock()
		writeJSON(w, http.StatusOK, status)
	case "/status":
		f.mu.Lock()
		status := f.statusLocked()
		f.mu.Unlock()
		writeJSON(w, http.StatusOK, status)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *fakePairingSidecar) statusLocked() map[string]any {
	status := map[string]any{"running": true}
	if f.address != "" && time.Now().Before(f.expiresAt) {
		status["pair_address"] = f.address
		status["pair_expires_at"] = f.expiresAt.UTC().Format(time.RFC3339Nano)
	}
	return status
}

// PR #428 评审：超时后按提示重试时，重发 /pair 会先销毁辅助程序刚建好的节点、再走一遍慢授权。
// 重试必须取回那次配对的结果。
func TestTailcatSupervisorPairRetryReclaimsNodeFinishedAfterTimeout(t *testing.T) {
	fake := &fakePairingSidecar{delay: 500 * time.Millisecond, ttl: 10 * time.Minute}
	socket := startFakeTailcatControl(t, fake)
	supervisor := &tailcatSidecarSupervisor{controlPath: socket, pairTimeout: 60 * time.Millisecond}

	if _, err := supervisor.Pair(context.Background()); err == nil {
		t.Fatal("首次配对应按配对超时返回")
	}
	// 立刻重试：那次配对仍在进行，/status 等不到结果，继续提示稍后重试，不能重发 /pair。
	if _, err := supervisor.Pair(context.Background()); err == nil || !strings.Contains(err.Error(), "稍后重试") {
		t.Fatalf("配对仍在进行时应继续提示稍后重试，got %v", err)
	}
	if got := fake.pairCalls.Load(); got != 1 {
		t.Fatalf("配对进行中不应重发 /pair：calls=%d", got)
	}

	time.Sleep(600 * time.Millisecond)
	status, err := supervisor.Pair(context.Background())
	if err != nil {
		t.Fatalf("那次配对建好后，重试应直接取回：%v", err)
	}
	if status.PairAddress != "pair-1.example.invalid" {
		t.Fatalf("应复用超时后建好的节点，got %q", status.PairAddress)
	}
	if got := fake.pairCalls.Load(); got != 1 {
		t.Fatalf("取回时不应重发 /pair 拆掉刚建好的节点：calls=%d", got)
	}

	// 取回之后恢复正常语义：再次配对（刷新二维码）生成新节点。
	supervisor.pairTimeout = 2 * time.Second
	status, err = supervisor.Pair(context.Background())
	if err != nil || status.PairAddress != "pair-2.example.invalid" || fake.pairCalls.Load() != 2 {
		t.Fatalf("取回后的下一次配对应生成新节点：status=%+v err=%v calls=%d", status, err, fake.pairCalls.Load())
	}
}

func TestTailcatSupervisorPairRetryRegeneratesWhenReclaimedNodeNearlyExpired(t *testing.T) {
	fake := &fakePairingSidecar{delay: 200 * time.Millisecond, ttl: time.Minute}
	socket := startFakeTailcatControl(t, fake)
	supervisor := &tailcatSidecarSupervisor{controlPath: socket, pairTimeout: 60 * time.Millisecond}

	if _, err := supervisor.Pair(context.Background()); err == nil {
		t.Fatal("首次配对应按配对超时返回")
	}
	time.Sleep(300 * time.Millisecond)
	supervisor.pairTimeout = 2 * time.Second
	status, err := supervisor.Pair(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if status.PairAddress != "pair-2.example.invalid" || fake.pairCalls.Load() != 2 {
		t.Fatalf("剩余有效期不足时应重新生成：status=%+v calls=%d", status, fake.pairCalls.Load())
	}
}

func TestTailcatSupervisorPairKeepsSidecarFailureMessage(t *testing.T) {
	socket := startFakeTailcatControl(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "启动短期 Tailcat 配对服务：中继拒绝"})
	}))
	supervisor := &tailcatSidecarSupervisor{controlPath: socket}

	_, err := supervisor.Pair(context.Background())
	if err == nil || err.Error() != "启动短期 Tailcat 配对服务：中继拒绝" {
		t.Fatalf("辅助程序的明确失败应原样返回，got %v", err)
	}
}

func TestTailcatSidecarLogWriterForwardsCompleteLines(t *testing.T) {
	var captured bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&captured)
	t.Cleanup(func() { log.SetOutput(previous) })

	writer := &tailcatSidecarLogWriter{}
	if _, err := writer.Write([]byte("Tailcat 实验失败：中继不可达\r\npair: 短期")); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("配对节点启动耗时 6.2s\n\n")); err != nil {
		t.Fatal(err)
	}

	output := captured.String()
	for _, want := range []string{
		"tailcat sidecar: Tailcat 实验失败：中继不可达",
		"tailcat sidecar: pair: 短期配对节点启动耗时 6.2s",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("缺少日志行 %q，实际输出：%q", want, output)
		}
	}
	if got := strings.Count(output, "tailcat sidecar:"); got != 2 {
		t.Fatalf("空行不应产生日志，且半行要等到换行再写；实际 %d 行：%q", got, output)
	}
}

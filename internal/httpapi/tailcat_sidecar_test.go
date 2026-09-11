package httpapi

import (
	"bytes"
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
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

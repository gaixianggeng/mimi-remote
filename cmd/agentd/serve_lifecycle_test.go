package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

func TestServeShutdownDrainsHTTPBeforeRuntimeCleanup(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	server, listener, serveReturned := startLifecycleHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(started)
		<-release
		w.WriteHeader(http.StatusNoContent)
	}))

	requestDone := make(chan error, 1)
	go func() {
		resp, err := lifecycleHTTPClient().Get("http://" + listener.Addr().String())
		if resp != nil {
			_ = resp.Body.Close()
		}
		requestDone <- err
	}()
	waitLifecycleSignal(t, started, "等待测试请求进入 handler")

	var cleanupCount atomic.Int32
	cleanupCalled := make(chan struct{})
	shutdownDone := make(chan error, 1)
	go func() {
		shutdownDone <- shutdownServe(server, 2*time.Second, func() error {
			if cleanupCount.Add(1) == 1 {
				close(cleanupCalled)
			}
			return nil
		})
	}()
	waitListenerClosed(t, listener.Addr().String())
	select {
	case <-cleanupCalled:
		t.Fatal("HTTP handler 尚未排空时不能先停止 runtime/upstream")
	case <-time.After(50 * time.Millisecond):
	}

	close(release)
	if err := <-shutdownDone; err != nil {
		t.Fatalf("graceful shutdown 失败：%v", err)
	}
	if err := <-requestDone; err != nil {
		t.Fatalf("drain 中的普通 HTTP 请求应完成：%v", err)
	}
	if got := cleanupCount.Load(); got != 1 {
		t.Fatalf("并发终止事件只能回收 runtime 一次，got=%d", got)
	}
	if err := <-serveReturned; !errors.Is(err, http.ErrServerClosed) {
		t.Fatalf("HTTP Serve 应由 Shutdown 正常结束：%v", err)
	}
}

func TestServeShutdownTimeoutStillClosesHTTPAndCleansRuntime(t *testing.T) {
	started := make(chan struct{})
	handlerDone := make(chan struct{})
	server, listener, serveReturned := startLifecycleHTTPServer(t, http.HandlerFunc(func(_ http.ResponseWriter, req *http.Request) {
		close(started)
		<-req.Context().Done()
		close(handlerDone)
	}))
	go func() {
		resp, _ := lifecycleHTTPClient().Get("http://" + listener.Addr().String())
		if resp != nil {
			_ = resp.Body.Close()
		}
	}()
	waitLifecycleSignal(t, started, "等待超时测试请求进入 handler")

	var cleanupCount atomic.Int32
	err := shutdownServe(server, 30*time.Millisecond, func() error {
		cleanupCount.Add(1)
		return nil
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("drain 超时应保留 context deadline 错误：%v", err)
	}
	if cleanupCount.Load() != 1 {
		t.Fatalf("Shutdown 超时后仍必须回收 runtime，got=%d", cleanupCount.Load())
	}
	waitLifecycleSignal(t, handlerDone, "等待 server.Close 取消超时 handler")
	if err := <-serveReturned; !errors.Is(err, http.ErrServerClosed) {
		t.Fatalf("强制 Close 后 HTTP Serve 应结束：%v", err)
	}
}

func TestWaitForServeExitHandlesSignalHTTPAndManagedFailures(t *testing.T) {
	sentinelHTTP := errors.New("synthetic HTTP serve failure")
	sentinelManaged := errors.New("synthetic managed upstream exit")
	tests := []struct {
		name      string
		signal    bool
		event     error
		wantCause error
	}{
		{name: "signal", signal: true},
		{name: "HTTP Serve error", event: sentinelHTTP, wantCause: sentinelHTTP},
		{name: "managed upstream exit", event: sentinelManaged, wantCause: sentinelManaged},
		{name: "concurrent signal and managed exit", signal: true, event: sentinelManaged},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusNoContent)
			})}
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			events := make(chan error, 2)
			serveReturned := make(chan error, 1)
			go func() {
				err := server.Serve(listener)
				serveReturned <- err
				events <- err
			}()
			stop := make(chan os.Signal, 1)
			if tc.signal {
				stop <- os.Interrupt
			}
			if tc.event != nil {
				events <- tc.event
			}
			var cleanupCount atomic.Int32
			err = waitForServeExit(stop, events, func() error {
				return shutdownServe(server, time.Second, func() error {
					cleanupCount.Add(1)
					return nil
				})
			})
			if tc.wantCause != nil && !errors.Is(err, tc.wantCause) {
				t.Fatalf("应保留原始退出原因 want=%v got=%v", tc.wantCause, err)
			}
			if tc.wantCause == nil && tc.event == nil && err != nil {
				t.Fatalf("正常信号退出应返回 nil：%v", err)
			}
			if cleanupCount.Load() != 1 {
				t.Fatalf("每条退出路径只能回收一次，got=%d", cleanupCount.Load())
			}
			waitListenerClosed(t, listener.Addr().String())
			if serveErr := <-serveReturned; !errors.Is(serveErr, http.ErrServerClosed) {
				t.Fatalf("退出事件必须同步关闭 HTTP server：%v", serveErr)
			}
		})
	}
}

func startLifecycleHTTPServer(t *testing.T, handler http.Handler) (*http.Server, net.Listener, <-chan error) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	serveReturned := make(chan error, 1)
	go func() { serveReturned <- server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	return server, listener, serveReturned
}

func lifecycleHTTPClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{Proxy: nil},
		Timeout:   2 * time.Second,
	}
}

func waitLifecycleSignal(t *testing.T, ch <-chan struct{}, message string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal(message)
	}
}

func waitListenerClosed(t *testing.T, address string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", address, 20*time.Millisecond)
		if err != nil {
			return
		}
		_ = conn.Close()
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("HTTP listener 未及时关闭：%s", address)
}

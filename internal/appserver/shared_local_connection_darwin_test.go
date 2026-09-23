//go:build darwin

package appserver

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestSharedLocalBusinessConnectionRechecksReplacementSession(t *testing.T) {
	home := shortSharedLocalCodexHome(t)
	socket := filepath.Join(home, sharedLocalSocketDir, sharedLocalSocketName)
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": home}})
	if err != nil {
		t.Fatal(err)
	}
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		t.Fatal("连接校验不能启动或替换现有服务")
		return nil
	}
	for _, manager := range []string{"Aqua", "Background", "Aqua"} {
		t.Run(manager, func(t *testing.T) {
			stop := startSharedLocalTestServerWithSession(t, socket, manager)
			defer stop()
			dialer, err := transport.WebSocketDialer(time.Second)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			conn, response, err := dialer.DialContext(ctx, sharedLocalHandshakeURL, nil)
			if response != nil && response.Body != nil {
				_ = response.Body.Close()
			}
			if manager == "Background" {
				var sessionErr *SharedLocalSessionError
				if conn != nil || !errors.As(err, &sessionErr) || sessionErr.Kind != "background" {
					t.Fatalf("直接业务拨号必须拒绝重建的 Background 实例：conn=%v err=%v", conn, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if err := initializeWebSocket(ctx, conn); err != nil {
				t.Fatalf("探针不能提前消费业务连接的 initialize：%v", err)
			}
		})
	}
}

func TestSharedLocalRepairCanStillInspectBackgroundServer(t *testing.T) {
	home := shortSharedLocalCodexHome(t)
	stop := startSharedLocalTestServerWithSession(t, filepath.Join(home, sharedLocalSocketDir, sharedLocalSocketName), "Background")
	defer stop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := dialSharedLocalRepairConnection(ctx, SharedLocalOptions{Env: map[string]string{"CODEX_HOME": home}})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.Initialize(ctx); err != nil {
		t.Fatal(err)
	}
	var sessionErr *SharedLocalSessionError
	if err := conn.ValidateSession(ctx); !errors.As(err, &sessionErr) || sessionErr.Kind != "background" {
		t.Fatalf("显式修复仍需读取被业务连接拒绝的环境：%v", err)
	}
}

func TestSharedLocalConnectionRejectsUnverifiablePeer(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	transport := &SharedLocalTransport{}
	var sessionErr *SharedLocalSessionError
	if err := transport.validateConnectionSession(context.Background(), left); !errors.As(err, &sessionErr) || sessionErr.Kind != "peer_identity" {
		t.Fatalf("无法验证 peer 的连接必须失败：%v", err)
	}
}

func TestSharedLocalBusinessConnectionCancellationClosesProbe(t *testing.T) {
	home := shortSharedLocalCodexHome(t)
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": home}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(transport.socket), 0700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", transport.socket)
	if err != nil {
		t.Fatal(err)
	}
	initialized := make(chan struct{})
	upgrader := websocket.Upgrader{}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		if _, _, err := conn.ReadMessage(); err != nil {
			return
		}
		close(initialized)
		// 不回答 initialize，让调用方取消来关闭探针，而不是等固定三秒超时。
		_, _, _ = conn.ReadMessage()
	})}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dialer, err := transport.WebSocketDialer(time.Second)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		conn, _, err := dialer.DialContext(ctx, sharedLocalHandshakeURL, nil)
		if conn != nil {
			_ = conn.Close()
		}
		done <- err
	}()
	select {
	case <-initialized:
	case <-time.After(2 * time.Second):
		t.Fatal("探针没有进入 initialize")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("取消必须保留 context 语义：%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("取消后仍在等待探针响应")
	}
}

func TestSharedLocalConnectionRejectsDifferentProbeOwner(t *testing.T) {
	home := shortSharedLocalCodexHome(t)
	originalSocket := filepath.Join(home, "original.sock")
	stop := startSharedLocalTestServer(t, originalSocket)
	defer stop()
	conn, err := net.Dial("unix", originalSocket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	otherSocket := filepath.Join(home, "replacement.sock")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSharedLocalProbePeerHelper$")
	cmd.Env = append(os.Environ(), "MIMI_TEST_SHARED_LOCAL_HELPER="+otherSocket)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = stdin.Close()
		if err := cmd.Wait(); err != nil {
			t.Errorf("隔离的 probe owner 退出失败：%v", err)
		}
	}()
	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() || scanner.Text() != "ready" {
		t.Fatal("隔离的 probe owner 未就绪")
	}
	transport := &SharedLocalTransport{socket: otherSocket}
	var sessionErr *SharedLocalSessionError
	if err := transport.validateConnectionSession(ctx, conn); !errors.As(err, &sessionErr) || sessionErr.Kind != "peer_changed" {
		t.Fatalf("不能用替换进程的 Aqua 检查授权旧连接：%v", err)
	}
}

func TestSharedLocalProbePeerHelper(t *testing.T) {
	path := os.Getenv("MIMI_TEST_SHARED_LOCAL_HELPER")
	if path == "" {
		return
	}
	stop := startSharedLocalTestServer(t, path)
	defer stop()
	fmt.Println("ready")
	_, _ = io.Copy(io.Discard, os.Stdin)
}

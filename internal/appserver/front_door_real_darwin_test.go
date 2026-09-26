//go:build darwin

package appserver

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// 本机显式启用时，使用独立 CODEX_HOME 验证真实 Codex 的 RPC、lsof 与 SIGHUP 退出。
func TestFrontDoorRealBackendIdleShutdown(t *testing.T) {
	if os.Getenv("MIMI_TEST_REAL_CODEX_FRONT") != "1" {
		t.Skip("仅在显式隔离实测时运行")
	}
	bin, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	home, err := os.MkdirTemp("/tmp", "mimi-real-front-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(home)
	door, err := NewFrontDoor(SharedLocalOptions{CodexBin: bin, Env: map[string]string{"CODEX_HOME": home}}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(door.BackendSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	processCtx, stop := context.WithCancel(context.Background())
	defer stop()
	cmd := exec.CommandContext(processCtx, bin, "app-server", "--listen", "unix://"+door.BackendSocketPath())
	cmd.Env = []string{"HOME=" + os.Getenv("HOME"), "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + home}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	defer func() {
		stop()
		<-exited
	}()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if conn, err := door.dialBackendOnce(context.Background()); err == nil {
			_ = conn.Close()
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	busy, err := dialSharedLocalRepairTransport(ctx, &SharedLocalTransport{socket: door.BackendSocketPath()})
	if err != nil {
		t.Fatal(err)
	}
	if err := busy.Initialize(ctx); err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	if err := door.CanReload(ctx); err == nil {
		_ = busy.Close()
		t.Fatal("仍有业务连接时不能换代前门")
	}
	_ = busy.Close()
	if err := door.CanReload(ctx); err != nil {
		t.Fatalf("真实空闲 backend 应允许前门换代：%v", err)
	}
	if err := door.StopIdleBackend(ctx); err != nil {
		t.Fatalf("真实空闲 backend 应优雅退出：%v", err)
	}
}

func TestFrontDoorRealOrphanBlocksUntilOldResidentExits(t *testing.T) {
	if os.Getenv("MIMI_TEST_REAL_CODEX_FRONT") != "1" {
		t.Skip("仅在显式隔离实测时运行")
	}
	bin, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	home, err := os.MkdirTemp("/tmp", "mimi-real-orphan-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(home)
	door, err := NewFrontDoor(SharedLocalOptions{CodexBin: bin, Env: map[string]string{"CODEX_HOME": home}}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	processCtx, stop := context.WithCancel(context.Background())
	defer stop()
	cmd := exec.CommandContext(processCtx, bin, "app-server", "--listen", "unix://")
	cmd.Env = []string{"HOME=" + os.Getenv("HOME"), "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + home}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	defer func() {
		stop()
		<-exited
	}()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if conn, err := net.Dial("unix", door.PublicSocketPath()); err == nil {
			_ = conn.Close()
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	busy, err := dialSharedLocalRepairTransport(ctx, &SharedLocalTransport{socket: door.PublicSocketPath()})
	if err != nil {
		t.Fatal(err)
	}
	if err := busy.Initialize(ctx); err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	if err := os.Remove(door.PublicSocketPath()); err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	newListener, err := net.Listen("unix", door.PublicSocketPath())
	if err != nil {
		_ = busy.Close()
		t.Fatal(err)
	}
	defer newListener.Close()
	blockedCtx, blockedCancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer blockedCancel()
	if _, err := door.DialBackend(blockedCtx); err == nil {
		_ = busy.Close()
		t.Fatal("旧 resident 仍有客户端时不能开放 backend")
	}
	if _, err := os.Stat(door.BackendSocketPath()); !os.IsNotExist(err) {
		_ = busy.Close()
		t.Fatalf("旧 resident 未退出却出现私有 backend：%v", err)
	}
	_ = busy.Close()
	var stopEcho func()
	door.launch = func(context.Context, SharedLocalOptions, string) error {
		stopEcho = echoBackend(t, door.BackendSocketPath())
		return nil
	}
	defer func() {
		if stopEcho != nil {
			stopEcho()
		}
	}()
	conn, err := door.DialBackend(ctx)
	if err != nil {
		t.Fatalf("旧 resident 退出后应开放 backend：%v", err)
	}
	_ = conn.Close()
}

// 使用两个全新临时 CODEX_HOME 创建真实 Thread，验证普通 Codex 与独立 backend
// 的历史完全隔离，同时验证 Mimi 公共 socket 与 SSH 使用的 Codex proxy 看到同一列表。
func TestFrontDoorRealSeparateBackendThreadIsolation(t *testing.T) {
	if os.Getenv("MIMI_TEST_REAL_CODEX_FRONT") != "1" {
		t.Skip("仅在显式隔离实测时运行")
	}
	bin, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	publicHome := shortSharedLocalCodexHome(t)
	backendHome := shortSharedLocalCodexHome(t)
	ordinaryWorkspace := t.TempDir()
	backendWorkspace := t.TempDir()
	mockModel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "event: response.created\n"+
			"data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp-test\"}}\n\n"+
			"event: response.output_item.done\n"+
			"data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"id\":\"msg-test\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n"+
			"event: response.completed\n"+
			"data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-test\",\"usage\":{\"input_tokens\":0,\"input_tokens_details\":null,\"output_tokens\":0,\"output_tokens_details\":null,\"total_tokens\":0}}}\n\n")
	}))
	defer mockModel.Close()
	writeRealCodexMockConfig(t, publicHome, mockModel.URL)
	writeRealCodexMockConfig(t, backendHome, mockModel.URL)
	door, err := NewFrontDoor(SharedLocalOptions{
		CodexBin:         bin,
		Env:              map[string]string{"CODEX_HOME": publicHome},
		BackendCodexHome: backendHome,
	}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) { return nil, nil }
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(door.BackendSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	ordinarySocket := filepath.Join(publicHome, "ordinary.sock")
	stopOrdinary := startRealCodexSocketServer(t, bin, publicHome, ordinarySocket)
	defer stopOrdinary()
	stopBackend := startRealCodexSocketServer(t, bin, backendHome, door.BackendSocketPath())
	defer stopBackend()

	listener, err := net.Listen("unix", door.PublicSocketPath())
	if err != nil {
		t.Fatal(err)
	}
	serveCtx, stopServing := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- door.Serve(serveCtx, listener) }()
	defer func() {
		stopServing()
		_ = listener.Close()
		if err := <-serveDone; err != nil {
			t.Errorf("前门退出失败：%v", err)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ordinary := dialRealCodexWebSocket(t, ctx, ordinarySocket)
	defer ordinary.Close()
	ordinaryInit, err := initializeWebSocketResult(ctx, ordinary)
	if err != nil {
		t.Fatal(err)
	}
	if ordinaryInit.CodexHome != publicHome {
		t.Fatalf("普通实例 CODEX_HOME=%q want %q", ordinaryInit.CodexHome, publicHome)
	}
	ordinaryID := startRealCodexThread(t, ctx, ordinary, 101, ordinaryWorkspace)
	materializeRealCodexThread(t, ctx, ordinary, 103, ordinaryID)

	public := dialRealCodexWebSocket(t, ctx, door.PublicSocketPath())
	defer public.Close()
	publicInit, err := initializeWebSocketResult(ctx, public)
	if err != nil {
		t.Fatal(err)
	}
	if publicInit.CodexHome != backendHome {
		t.Fatalf("公共 socket 应连接独立 backend：codexHome=%q want %q", publicInit.CodexHome, backendHome)
	}
	backendID := startRealCodexThread(t, ctx, public, 201, backendWorkspace)
	materializeRealCodexThread(t, ctx, public, 203, backendID)

	ordinaryIDs := listRealCodexThreads(t, ctx, ordinary, 102)
	publicIDs := listRealCodexThreads(t, ctx, public, 202)
	if !ordinaryIDs[ordinaryID] || ordinaryIDs[backendID] {
		t.Fatalf("普通 CODEX_HOME 列表未隔离：ordinary=%q backend=%q list=%v", ordinaryID, backendID, ordinaryIDs)
	}
	if !publicIDs[backendID] || publicIDs[ordinaryID] {
		t.Fatalf("独立 backend 列表未隔离：ordinary=%q backend=%q list=%v", ordinaryID, backendID, publicIDs)
	}

	proxy := dialRealCodexProxyWebSocket(t, ctx, bin, publicHome)
	defer proxy.Close()
	proxyInit, err := initializeWebSocketResult(ctx, proxy)
	if err != nil {
		t.Fatal(err)
	}
	if proxyInit.CodexHome != backendHome {
		t.Fatalf("Codex proxy 应经公共 socket 进入独立 backend：codexHome=%q want %q", proxyInit.CodexHome, backendHome)
	}
	proxyIDs := listRealCodexThreads(t, ctx, proxy, 301)
	if fmt.Sprint(proxyIDs) != fmt.Sprint(publicIDs) {
		t.Fatalf("Codex proxy 与 Mimi 公共 socket 列表不同：proxy=%v public=%v", proxyIDs, publicIDs)
	}
}

func writeRealCodexMockConfig(t *testing.T, codexHome, serverURL string) {
	t.Helper()
	config := fmt.Sprintf(`model = "mock-model"
model_provider = "mock_provider"
approval_policy = "never"
sandbox_mode = "read-only"

[model_providers.mock_provider]
name = "Isolated test model"
base_url = %q
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
`, serverURL+"/v1")
	if err := os.WriteFile(filepath.Join(codexHome, "config.toml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
}

func startRealCodexSocketServer(t *testing.T, bin, codexHome, socket string) func() {
	t.Helper()
	processCtx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(processCtx, bin, "app-server", "--listen", "unix://"+socket)
	cmd.Env = []string{
		"HOME=" + codexHome,
		"PATH=" + os.Getenv("PATH"),
		"CODEX_HOME=" + codexHome,
		"CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1",
	}
	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for {
		conn, err := net.DialTimeout("unix", socket, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			break
		}
		select {
		case err := <-exited:
			cancel()
			t.Fatalf("真实 Codex App Server 提前退出：%v", err)
		case <-deadline.C:
			cancel()
			t.Fatalf("等待真实 Codex App Server socket 超时：%v", err)
		case <-time.After(50 * time.Millisecond):
		}
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			cancel()
			select {
			case <-exited:
			case <-time.After(5 * time.Second):
				t.Errorf("真实 Codex App Server 未按取消退出：%s", socket)
			}
		})
	}
}

func dialRealCodexWebSocket(t *testing.T, ctx context.Context, socket string) *websocket.Conn {
	t.Helper()
	netDialer := net.Dialer{Timeout: 2 * time.Second}
	dialer := websocket.Dialer{
		HandshakeTimeout: 3 * time.Second,
		NetDialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return netDialer.DialContext(ctx, "unix", socket)
		},
	}
	conn, response, err := dialer.DialContext(ctx, sharedLocalHandshakeURL, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func startRealCodexThread(t *testing.T, ctx context.Context, conn *websocket.Conn, id int, cwd string) string {
	t.Helper()
	var response struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	callRealCodexRPC(t, ctx, conn, id, "thread/start", map[string]any{"cwd": cwd, "ephemeral": false}, &response)
	if response.Thread.ID == "" {
		t.Fatal("thread/start 未返回 thread id")
	}
	return response.Thread.ID
}

func materializeRealCodexThread(t *testing.T, ctx context.Context, conn *websocket.Conn, id int, threadID string) {
	t.Helper()
	var response map[string]any
	callRealCodexRPC(t, ctx, conn, id, "turn/start", map[string]any{
		"threadId": threadID,
		"input": []map[string]any{{
			"type": "text",
			"text": "persist this isolated test thread",
		}},
	}, &response)
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		var frame struct {
			Method string `json:"method"`
		}
		if json.Unmarshal(raw, &frame) == nil && frame.Method == "turn/completed" {
			return
		}
	}
}

func listRealCodexThreads(t *testing.T, ctx context.Context, conn *websocket.Conn, id int) map[string]bool {
	t.Helper()
	var response struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
		Threads []struct {
			ID string `json:"id"`
		} `json:"threads"`
	}
	callRealCodexRPC(t, ctx, conn, id, "thread/list", map[string]any{
		"limit": 100,
		"sourceKinds": []string{
			"cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
			"subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
		},
	}, &response)
	ids := make(map[string]bool, len(response.Data))
	for _, thread := range response.Data {
		ids[thread.ID] = true
	}
	for _, thread := range response.Threads {
		ids[thread.ID] = true
	}
	return ids
}

func callRealCodexRPC(t *testing.T, ctx context.Context, conn *websocket.Conn, id int, method string, params, result any) {
	t.Helper()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(deadline)
		_ = conn.SetWriteDeadline(deadline)
	}
	if err := conn.WriteJSON(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		t.Fatal(err)
	}
	wantID := fmt.Sprint(id)
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
			Error  *RPCError       `json:"error"`
		}
		if json.Unmarshal(raw, &frame) != nil || frame.Method != "" || string(frame.ID) != wantID {
			continue
		}
		if frame.Error != nil {
			t.Fatalf("%s 失败：%v", method, frame.Error)
		}
		if err := json.Unmarshal(frame.Result, result); err != nil {
			t.Fatalf("解析 %s 响应失败：%v", method, err)
		}
		return
	}
}

func dialRealCodexProxyWebSocket(t *testing.T, ctx context.Context, bin, publicHome string) *websocket.Conn {
	t.Helper()
	dialer := websocket.Dialer{
		HandshakeTimeout: 3 * time.Second,
		NetDialContext: func(context.Context, string, string) (net.Conn, error) {
			return startRealCodexProxy(bin, publicHome)
		},
	}
	conn, response, err := dialer.DialContext(ctx, CodexAppServerWebSocketURL, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

type realCodexProxyConn struct {
	net.Conn
	cmd      *exec.Cmd
	waitDone <-chan error
	once     sync.Once
}

func startRealCodexProxy(bin, publicHome string) (net.Conn, error) {
	cmd := exec.Command(bin, "app-server", "proxy")
	cmd.Env = []string{"HOME=" + publicHome, "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + publicHome}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, err
	}
	client, bridge := net.Pipe()
	waitDone := make(chan error, 1)
	go func() {
		waitDone <- cmd.Wait()
		_ = bridge.Close()
	}()
	go func() {
		_, _ = io.Copy(stdin, bridge)
		_ = stdin.Close()
	}()
	go func() {
		_, _ = io.Copy(bridge, stdout)
		_ = stdout.Close()
		_ = bridge.Close()
	}()
	return &realCodexProxyConn{Conn: client, cmd: cmd, waitDone: waitDone}, nil
}

func (c *realCodexProxyConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(func() {
		if c.cmd.Process != nil {
			_ = c.cmd.Process.Kill()
		}
		select {
		case <-c.waitDone:
		case <-time.After(2 * time.Second):
		}
	})
	return err
}

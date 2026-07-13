package appserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

type pipeHarness struct {
	client             *Client
	clientToServerRead *io.PipeReader
	clientToServer     *io.PipeWriter
	serverToClientRead *io.PipeReader
	serverToClient     *io.PipeWriter
}

func newPipeHarness(t *testing.T, options ClientOptions) *pipeHarness {
	t.Helper()
	clientToServerRead, clientToServer := io.Pipe()
	serverToClientRead, serverToClient := io.Pipe()
	h := &pipeHarness{
		clientToServerRead: clientToServerRead,
		clientToServer:     clientToServer,
		serverToClientRead: serverToClientRead,
		serverToClient:     serverToClient,
	}
	h.client = NewClient(serverToClientRead, clientToServer, options)
	t.Cleanup(func() {
		_ = h.client.Close()
		_ = clientToServerRead.Close()
		_ = clientToServer.Close()
		_ = serverToClientRead.Close()
		_ = serverToClient.Close()
	})
	return h
}

func TestClientSendsInitializeThenInitializedBeforeOtherRequests(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	serverDone := make(chan error, 1)
	go func() {
		initMsg, err := readClientWire(h.clientToServerRead)
		if err != nil {
			serverDone <- err
			return
		}
		if initMsg.Method != "initialize" {
			serverDone <- fmt.Errorf("第一条消息应为 initialize，实际 %s", initMsg.Method)
			return
		}
		writeServerLine(t, h.serverToClient, `{"id":1,"result":{"userAgent":"fake","platformFamily":"macos"}}`)
		initialized, err := readClientWire(h.clientToServerRead)
		if err != nil {
			serverDone <- err
			return
		}
		if initialized.Method != "initialized" || initialized.ID != nil {
			serverDone <- fmt.Errorf("第二条消息应为 initialized notification：%+v", initialized)
			return
		}
		listMsg, err := readClientWire(h.clientToServerRead)
		if err != nil {
			serverDone <- err
			return
		}
		if listMsg.Method != "thread/list" {
			serverDone <- fmt.Errorf("第三条消息应为 thread/list，实际 %s", listMsg.Method)
			return
		}
		writeServerLine(t, h.serverToClient, `{"id":2,"result":{"threads":[]}}`)
		serverDone <- nil
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	result, err := h.client.Initialize(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if result.UserAgent != "fake" {
		t.Fatalf("initialize result 异常：%+v", result)
	}
	var list struct {
		Threads []any `json:"threads"`
	}
	if err := h.client.Call(ctx, "thread/list", map[string]any{}, &list); err != nil {
		t.Fatal(err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	if !h.client.Diagnostics().Initialized {
		t.Fatal("初始化成功后 diagnostics 应标记 initialized")
	}
}

func TestClientMatchesResponsesByRequestIDOutOfOrder(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	errs := make(chan error, 2)
	call := func(method string) {
		defer wg.Done()
		var out struct {
			Method string `json:"method"`
		}
		if err := h.client.Call(ctx, method, map[string]any{}, &out); err != nil {
			errs <- err
			return
		}
		if out.Method != method {
			errs <- fmt.Errorf("响应错配：call=%s result=%s", method, out.Method)
		}
	}
	wg.Add(2)
	go call("thread/list")
	go call("thread/read")

	first, err := readClientWire(h.clientToServerRead)
	if err != nil {
		t.Fatal(err)
	}
	second, err := readClientWire(h.clientToServerRead)
	if err != nil {
		t.Fatal(err)
	}
	writeResponseForMethod(t, h.serverToClient, second)
	writeResponseForMethod(t, h.serverToClient, first)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestClientReturnsJsonRPCError(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	go func() {
		req, _ := readClientWire(h.clientToServerRead)
		writeServerLine(t, h.serverToClient, fmt.Sprintf(`{"id":%s,"error":{"code":123,"message":"boom"}}`, string(*req.ID)))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := h.client.Call(ctx, "thread/list", map[string]any{}, nil)
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) || rpcErr.Code != 123 || rpcErr.Message != "boom" {
		t.Fatalf("应返回 JSON-RPC error，got=%v", err)
	}
}

func TestClientRejectsMalformedJsonLine(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	go func() {
		_, _ = readClientWire(h.clientToServerRead)
		_, _ = h.serverToClient.Write([]byte("{bad json\n"))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := h.client.Call(ctx, "thread/list", map[string]any{}, nil)
	if err == nil || !strings.Contains(err.Error(), "合法 JSON") {
		t.Fatalf("坏 JSON 应关闭 client 并返回诊断错误，got=%v", err)
	}
}

func TestClientHandlesServerEOF(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	go func() {
		_, _ = readClientWire(h.clientToServerRead)
		_ = h.serverToClient.Close()
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := h.client.Call(ctx, "thread/list", map[string]any{}, nil)
	if err == nil || !strings.Contains(err.Error(), "输出已关闭") {
		t.Fatalf("server EOF 应让 pending request 失败，got=%v", err)
	}
}

func TestClientRequestTimeout(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	go func() {
		_, _ = readClientWire(h.clientToServerRead)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	err := h.client.Call(ctx, "thread/list", map[string]any{}, nil)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("未响应请求应按 context 超时，got=%v", err)
	}
	if got := h.client.Diagnostics().PendingRequests; got != 0 {
		t.Fatalf("超时后 pending request 应清理，got=%d", got)
	}
}

func TestClientRetriesBackpressureError32001(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{OverloadRetries: 1, OverloadBackoff: time.Millisecond})
	go func() {
		first, _ := readClientWire(h.clientToServerRead)
		writeServerLine(t, h.serverToClient, fmt.Sprintf(`{"id":%s,"error":{"code":-32001,"message":"Server overloaded; retry later."}}`, string(*first.ID)))
		second, _ := readClientWire(h.clientToServerRead)
		writeServerLine(t, h.serverToClient, fmt.Sprintf(`{"id":%s,"result":{"ok":true}}`, string(*second.ID)))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var out struct {
		OK bool `json:"ok"`
	}
	if err := h.client.Call(ctx, "thread/list", map[string]any{}, &out); err != nil {
		t.Fatal(err)
	}
	if !out.OK {
		t.Fatalf("重试后的响应异常：%+v", out)
	}
}

func TestClientClampsNegativeOverloadRetries(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{OverloadRetries: -1})
	go func() {
		req, _ := readClientWire(h.clientToServerRead)
		writeServerLine(t, h.serverToClient, fmt.Sprintf(`{"id":%s,"result":{"ok":true}}`, string(*req.ID)))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var out struct {
		OK bool `json:"ok"`
	}
	if err := h.client.Call(ctx, "thread/list", map[string]any{}, &out); err != nil {
		t.Fatal(err)
	}
	if !out.OK {
		t.Fatalf("负重试次数应被 clamp 后至少执行一次请求：%+v", out)
	}
}

func TestDispatcherRoutesNotificationsWithoutBlockingResponses(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{NotificationBuffer: 1})
	h.client.Start()
	for i := 0; i < 3; i++ {
		writeServerLine(t, h.serverToClient, `{"method":"item/agentMessage/delta","params":{"delta":"ok"}}`)
	}
	waitFor(t, func() bool {
		return h.client.Diagnostics().DroppedNotifications > 0
	}, "等待 notification 背压丢弃计数")

	go func() {
		req, _ := readClientWire(h.clientToServerRead)
		writeServerLine(t, h.serverToClient, fmt.Sprintf(`{"id":%s,"result":{"ok":true}}`, string(*req.ID)))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var out struct {
		OK bool `json:"ok"`
	}
	if err := h.client.Call(ctx, "thread/list", map[string]any{}, &out); err != nil {
		t.Fatal(err)
	}
	if !out.OK {
		t.Fatal("慢 notification 消费者不应阻塞 response reader")
	}
}

func TestServerRequestDefaultsFailClosed(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	h.client.Start()
	writeServerLine(t, h.serverToClient, `{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"rm -rf tmp"}}`)
	response, err := readClientWire(h.clientToServerRead)
	if err != nil {
		t.Fatal(err)
	}
	if response.ID == nil || string(*response.ID) != "99" || response.Result == nil {
		t.Fatalf("server request 应回同 id result：%+v", response)
	}
	var result struct {
		Decision string `json:"decision"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatal(err)
	}
	if result.Decision != "decline" {
		t.Fatalf("默认审批必须 fail closed，got=%q", result.Decision)
	}
}

func TestServerRequestFailClosedCoversPermissionsAndLegacyApprovals(t *testing.T) {
	tests := []struct {
		name            string
		method          string
		wantDecision    string
		wantPermissions bool
		wantUnsupported bool
	}{
		{name: "command execution", method: "item/commandExecution/requestApproval", wantDecision: "decline"},
		{name: "file change", method: "item/fileChange/requestApproval", wantDecision: "decline"},
		{name: "permissions", method: "item/permissions/requestApproval", wantPermissions: true},
		{name: "legacy exec", method: "execCommandApproval", wantDecision: "denied"},
		{name: "legacy patch", method: "applyPatchApproval", wantDecision: "denied"},
		{name: "unsupported", method: "item/tool/call", wantUnsupported: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, rpcErr := failClosedResult(ServerRequest{Method: tt.method}, "test decline")
			if tt.wantUnsupported {
				if rpcErr == nil {
					t.Fatalf("不在移动端审批 allowlist 的请求应返回 RPC error，got result=%v", result)
				}
				return
			}
			if rpcErr != nil {
				t.Fatal(rpcErr)
			}
			typed := result.(map[string]any)
			if tt.wantPermissions {
				if _, ok := typed["permissions"].(map[string]any); !ok || typed["scope"] != "turn" {
					t.Fatalf("permissions 拒绝必须返回空权限和 turn scope：%+v", typed)
				}
				if _, hasDecision := typed["decision"]; hasDecision {
					t.Fatalf("permissions 响应不能包含 decision 字段：%+v", typed)
				}
				return
			}
			if typed["decision"] != tt.wantDecision {
				t.Fatalf("审批拒绝 decision 异常：%+v", typed)
			}
			if _, hasMessage := typed["message"]; hasMessage {
				t.Fatalf("默认审批响应必须匹配 app-server 协议，不能携带额外 message 字段：%+v", typed)
			}
		})
	}
}

func TestServerRequestHandlerCanApprove(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{
		ServerRequestHandler: func(ctx context.Context, req ServerRequest) (any, *RPCError) {
			if req.Method != "item/commandExecution/requestApproval" {
				t.Fatalf("审批 handler 收到异常 method=%s", req.Method)
			}
			return map[string]any{
				"decision": "accept",
			}, nil
		},
	})
	h.client.Start()
	writeServerLine(t, h.serverToClient, `{"id":101,"method":"item/commandExecution/requestApproval","params":{"command":"go test ./..."}}`)
	response, err := readClientWire(h.clientToServerRead)
	if err != nil {
		t.Fatal(err)
	}
	if response.ID == nil || string(*response.ID) != "101" || response.Result == nil || response.Error != nil {
		t.Fatalf("server request 应回同 id 成功响应：%+v", response)
	}
	var result struct {
		Decision string `json:"decision"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatal(err)
	}
	if result.Decision != "accept" {
		t.Fatalf("显式审批通过应透传 accept，got=%+v", result)
	}
}

func TestServerRequestTimesOutFailClosed(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{
		ServerRequestTimeout: 20 * time.Millisecond,
		ServerRequestHandler: func(ctx context.Context, req ServerRequest) (any, *RPCError) {
			<-ctx.Done()
			time.Sleep(time.Second)
			return map[string]any{"decision": "accept"}, nil
		},
	})
	h.client.Start()
	writeServerLine(t, h.serverToClient, `{"id":100,"method":"item/fileChange/requestApproval","params":{}}`)
	response, err := readClientWire(h.clientToServerRead)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Decision string `json:"decision"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatal(err)
	}
	if result.Decision != "decline" {
		t.Fatalf("审批超时必须拒绝，got=%+v", result)
	}
}

func TestDispatchNotificationAfterCloseDoesNotPanic(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	if err := h.client.Close(); err != nil {
		t.Fatal(err)
	}
	h.client.dispatchNotification(Notification{Method: "warning"})
}

func TestClientCloseIsIdempotent(t *testing.T) {
	h := newPipeHarness(t, ClientOptions{})
	if err := h.client.Close(); err != nil {
		t.Fatal(err)
	}
	if err := h.client.Close(); err != nil {
		t.Fatal(err)
	}
}

func readClientWire(reader *io.PipeReader) (wireMessage, error) {
	var message wireMessage
	var line []byte
	for {
		chunk := make([]byte, 1)
		n, err := reader.Read(chunk)
		if n > 0 {
			if chunk[0] == '\n' {
				break
			}
			line = append(line, chunk[0])
		}
		if err != nil {
			return message, err
		}
	}
	if err := json.Unmarshal(line, &message); err != nil {
		return message, err
	}
	return message, nil
}

func writeServerLine(t *testing.T, writer *io.PipeWriter, line string) {
	t.Helper()
	if _, err := writer.Write([]byte(line + "\n")); err != nil {
		t.Fatalf("写 fake app-server 输出失败：%v", err)
	}
}

func writeResponseForMethod(t *testing.T, writer *io.PipeWriter, request wireMessage) {
	t.Helper()
	writeServerLine(t, writer, fmt.Sprintf(`{"id":%s,"result":{"method":%q}}`, string(*request.ID), request.Method))
}

func waitFor(t *testing.T, condition func() bool, reason string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal(reason)
}

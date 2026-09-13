package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeClaudeBridgeState 记录假 bridge 收到的请求。它用 net.Pipe 模拟 bridge socket，
// 只实现自动标题任务需要的 initialize / thread/read / thread/name/set。
type fakeClaudeBridgeState struct {
	mu                 sync.Mutex
	name               string
	readCalls          int
	setName            string
	initialized        bool
	serverRequestReply string
}

func newFakeClaudeBridge(t *testing.T, existingName string, injectServerRequest bool) (func(context.Context) (*claudeBridgeRPC, error), *fakeClaudeBridgeState) {
	t.Helper()
	state := &fakeClaudeBridgeState{name: existingName}
	dial := func(ctx context.Context) (*claudeBridgeRPC, error) {
		clientEnd, serverEnd := net.Pipe()
		go serveFakeClaudeBridge(t, serverEnd, state, injectServerRequest)
		rpc := newClaudeBridgeRPC(clientEnd)
		rpc.stopCancelClose = context.AfterFunc(ctx, func() { _ = clientEnd.Close() })
		return rpc, nil
	}
	return dial, state
}

func serveFakeClaudeBridge(t *testing.T, conn net.Conn, state *fakeClaudeBridgeState, injectServerRequest bool) {
	t.Helper()
	defer conn.Close()
	reader := bufio.NewReader(conn)
	writeLine := func(payload map[string]any) bool {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return false
		}
		_, err = conn.Write(append(encoded, '\n'))
		return err == nil
	}
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return
		}
		var frame runtimeWebSocketFrame
		if json.Unmarshal(line, &frame) != nil {
			continue
		}
		switch frame.Method {
		case "initialize":
			state.mu.Lock()
			state.initialized = true
			state.mu.Unlock()
			writeLine(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(frame.ID), "result": map[string]any{"userAgent": "alleycat-claude-bridge/0.2.10"}})
		case "initialized":
			continue
		case "thread/read":
			state.mu.Lock()
			state.readCalls++
			name := state.name
			state.mu.Unlock()
			if injectServerRequest {
				// bridge 反向 request（如审批）不属于内部任务：客户端必须回标准错误，
				// 且不能把它当成 thread/read 的响应。
				writeLine(map[string]any{"jsonrpc": "2.0", "id": "server-1", "method": "item/tool/call", "params": map[string]any{}})
				reply, err := reader.ReadBytes('\n')
				if err != nil {
					return
				}
				state.mu.Lock()
				state.serverRequestReply = strings.TrimSpace(string(reply))
				state.mu.Unlock()
			}
			var wireName any
			if name != "" {
				wireName = name
			}
			writeLine(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(frame.ID), "result": map[string]any{"thread": map[string]any{"id": "thread-claude", "name": wireName}}})
		case "thread/name/set":
			params, _ := decodeGatewayParams(frame.Params)
			name, _ := gatewayStringParam(params, "name")
			state.mu.Lock()
			state.setName = name
			state.name = name
			state.mu.Unlock()
			writeLine(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(frame.ID), "result": map[string]any{}})
		default:
			writeLine(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(frame.ID), "error": map[string]any{"code": -32601, "message": "unexpected method " + frame.Method}})
		}
	}
}

func TestClaudeAutoThreadTitleWritesBackThroughBridge(t *testing.T) {
	upstreamURL, codex := newAutoThreadTitleUpstream(t, "", `{"title":"排查 SSH 连接报错"}`)
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(t, upstreamURL))
	dial, bridge := newFakeClaudeBridge(t, "", true)
	generator.dialClaudeBridge = dial

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	title, updated, err := generator.GenerateAndSet(ctx, autoThreadTitleRequest{
		ThreadID:  "thread-claude",
		CWD:       t.TempDir(),
		Prompt:    "有过用户反馈在配置的时候报这个错误，帮我看一下",
		RuntimeID: "claude",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !updated || title != "排查 SSH 连接报错" {
		t.Fatalf("Claude 标题生成结果异常：updated=%t title=%q", updated, title)
	}

	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if !bridge.initialized {
		t.Fatal("内部连接必须先 initialize bridge")
	}
	if bridge.readCalls != 2 {
		t.Fatalf("写回前后应各通过 bridge 读取一次目标线程，got=%d", bridge.readCalls)
	}
	if bridge.setName != title {
		t.Fatalf("thread/name/set 必须写到 bridge：got=%q want=%q", bridge.setName, title)
	}
	if !strings.Contains(bridge.serverRequestReply, `"code":-32601`) || !strings.Contains(bridge.serverRequestReply, `"server-1"`) {
		t.Fatalf("bridge 反向 request 必须被内部客户端拒绝：%s", bridge.serverRequestReply)
	}

	codex.mu.Lock()
	defer codex.mu.Unlock()
	if codex.readCalls != 0 || codex.setTitle != "" {
		t.Fatalf("Claude 线程的读取和写回不得落到 Codex app-server：reads=%d set=%q", codex.readCalls, codex.setTitle)
	}
	if codex.threadStart["ephemeral"] != true || codex.turnStart["effort"] != "low" {
		t.Fatalf("标题文本仍应由 Codex 临时线程生成：threadStart=%v turnStart=%v", codex.threadStart, codex.turnStart)
	}
}

func TestClaudeAutoThreadTitleDoesNotOverwriteTranscriptTitle(t *testing.T) {
	upstreamURL, codex := newAutoThreadTitleUpstream(t, "", `{"title":"模型标题"}`)
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(t, upstreamURL))
	// bridge 已从 transcript 读到 Claude 自己写的标题（custom-title / ai-title）。
	dial, bridge := newFakeClaudeBridge(t, "Claude 自己的标题", false)
	generator.dialClaudeBridge = dial

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	title, updated, err := generator.GenerateAndSet(ctx, autoThreadTitleRequest{
		ThreadID:  "thread-claude",
		CWD:       t.TempDir(),
		Prompt:    "随便聊聊",
		RuntimeID: "claude",
	})
	if err != nil {
		t.Fatal(err)
	}
	if updated || title != "" {
		t.Fatalf("已有标题的 Claude 线程不得被覆盖：updated=%t title=%q", updated, title)
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.setName != "" {
		t.Fatalf("不应调用 thread/name/set：%q", bridge.setName)
	}
	codex.mu.Lock()
	defer codex.mu.Unlock()
	if codex.threadStart != nil {
		t.Fatal("已命名线程不应再消耗 Codex 生成请求")
	}
}

func TestClaudeAutoThreadTitleSkipsWhenBridgeUnavailable(t *testing.T) {
	upstreamURL, codex := newAutoThreadTitleUpstream(t, "", `{"title":"模型标题"}`)
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(t, upstreamURL))
	generator.dialClaudeBridge = func(context.Context) (*claudeBridgeRPC, error) {
		return nil, errors.New("Claude bridge 未运行")
	}

	_, updated, err := generator.GenerateAndSet(context.Background(), autoThreadTitleRequest{
		ThreadID:  "thread-claude",
		CWD:       t.TempDir(),
		Prompt:    "随便聊聊",
		RuntimeID: "claude",
	})
	if err == nil || updated {
		t.Fatalf("bridge 不可用时应跳过本次任务：updated=%t err=%v", updated, err)
	}
	codex.mu.Lock()
	defer codex.mu.Unlock()
	if codex.threadStart != nil || codex.readCalls != 0 {
		t.Fatal("bridge 不可用时不应再连 Codex 生成标题")
	}
}

func TestAutoThreadTitleRequestConsumesNewClaudeThreadOnce(t *testing.T) {
	policy := &appServerGatewayPolicy{
		runtimeID: "claude",
		allowedThreads: map[string]appServerGatewayAllowedThread{
			"thread-claude": {
				id:                "thread-claude",
				runtimeID:         "claude",
				cwd:               "/tmp/project",
				scopeID:           "project",
				autoTitleEligible: true,
			},
		},
	}
	payload, err := json.Marshal(map[string]any{
		"id":     3,
		"method": "turn/start",
		"params": map[string]any{
			"threadId": "thread-claude",
			"input":    []any{map[string]any{"type": "text", "text": "检查 SSH 报错"}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	request, ok := policy.takeAutoThreadTitleRequest(payload)
	if !ok {
		t.Fatal("新 Claude thread 的首个 turn/start 应生成标题请求")
	}
	if request.RuntimeID != "claude" || request.ThreadID != "thread-claude" || request.CWD != "/tmp/project" {
		t.Fatalf("标题请求必须带上 runtime 与线程绑定：%+v", request)
	}
	if _, ok := policy.takeAutoThreadTitleRequest(payload); ok {
		t.Fatal("同一新 thread 的标题资格只能消费一次")
	}
}

func TestAutoThreadTitleRuntimeSupported(t *testing.T) {
	for runtimeID, want := range map[string]bool{"codex": true, "claude": true, "Claude": true, "": true, "pi": false} {
		if got := autoThreadTitleRuntimeSupported(runtimeID); got != want {
			t.Fatalf("runtime %q: got=%t want=%t", runtimeID, got, want)
		}
	}
}

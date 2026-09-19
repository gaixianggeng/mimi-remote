package httpapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件覆盖 turn/start 的 turn 对账。
//
// 对账口径只有一条：user/message 的 source.rpcId 等于本次 prompt 的 requestId。
// 任何"等下一个出现的 turn"的做法都会在多端（Harness Web 页面、子 Agent）或排队
// 投递的场景下把另一轮的编号回给客户端，而客户端的乐观消息绑定、中断对账与 active
// 清理全部以这个编号为准——错配不会报错，只会让这些操作指向别的轮次。

// turnForRequest 必须只认 source.rpcId 相同的那条消息。
func TestDeepSeekTurnForRequestBindsToItsOwnMessage(t *testing.T) {
	follow := &deepSeekFollow{threadID: "s-1", updated: make(chan struct{}, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 1, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventUserMessage, Seq: 2, Data: json.RawMessage(
			`{"id":"um-a","source":{"kind":"user","rpcId":"msg-a"}}`)},
		{Type: deepSeekEventTurnStart, Seq: 3, Data: json.RawMessage(`{"turn":2}`)},
		// 没有 source 的 user/message 无法证明属于哪次投递。
		{Type: deepSeekEventUserMessage, Seq: 4, Data: json.RawMessage(`{"id":"um-bare"}`)},
		{Type: deepSeekEventUserMessage, Seq: 5, Data: json.RawMessage(
			`{"id":"um-b","source":{"kind":"user","rpcId":"msg-b"}}`)},
	})

	tests := []struct {
		name      string
		requestID string
		want      int64
		wantOK    bool
	}{
		{name: "第一次投递", requestID: "msg-a", want: 1, wantOK: true},
		{name: "第二次投递", requestID: "msg-b", want: 2, wantOK: true},
		{name: "别人的投递", requestID: "msg-other", wantOK: false},
		{name: "空 requestId", requestID: "", wantOK: false},
		{name: "只有空白", requestID: "   ", wantOK: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			turn, ok := follow.turnForRequest(test.requestID)
			if ok != test.wantOK || turn != test.want {
				t.Fatalf("requestID=%q => (%d, %v), want (%d, %v)",
					test.requestID, turn, ok, test.want, test.wantOK)
			}
		})
	}
}

// 本次投递的消息到达时必须唤醒等待者，而不是靠超时收尾：超时收尾会让正常投递
// 也要等满整个超时才拿到（或干脆拿不到）turn id。
func TestDeepSeekAwaitTurnForRequestWakesOnItsOwnTurn(t *testing.T) {
	follow := &deepSeekFollow{threadID: "s-1", updated: make(chan struct{}, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 1, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventUserMessage, Seq: 2, Data: json.RawMessage(
			`{"id":"um-other","source":{"kind":"user","rpcId":"other-msg"}}`)},
	})

	type outcome struct {
		turn int64
		ok   bool
	}
	settled := make(chan outcome, 1)
	go func() {
		turn, ok := follow.awaitTurnForRequest(context.Background(), "msg-1", 10*time.Second)
		settled <- outcome{turn: turn, ok: ok}
	}()

	// 等等待者进入等待之后再投递，否则可能被"先查缓存"这条路径兜住，测不到唤醒。
	time.Sleep(100 * time.Millisecond)
	start := time.Now()
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 3, Data: json.RawMessage(`{"turn":2}`)},
		{Type: deepSeekEventUserMessage, Seq: 4, Data: json.RawMessage(
			`{"id":"um-1","source":{"kind":"user","rpcId":"msg-1"}}`)},
	})

	select {
	case got := <-settled:
		if !got.ok || got.turn != 2 {
			t.Fatalf("应等到本次投递自己的 turn：(%d, %v)", got.turn, got.ok)
		}
		if elapsed := time.Since(start); elapsed > 2*time.Second {
			t.Fatalf("消息到达后应立即唤醒，实际用了 %s", elapsed)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("本次投递的 turn 到达后必须唤醒等待者")
	}
}

// 别人的消息永远不满足本次等待：必须超时返回 false，由调用方按"拿不到 turn id"处理。
func TestDeepSeekAwaitTurnForRequestTimesOutWithoutItsOwnTurn(t *testing.T) {
	follow := &deepSeekFollow{threadID: "s-1", updated: make(chan struct{}, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 1, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventUserMessage, Seq: 2, Data: json.RawMessage(
			`{"id":"um-other","source":{"kind":"user","rpcId":"other-msg"}}`)},
	})

	start := time.Now()
	if turn, ok := follow.awaitTurnForRequest(context.Background(), "msg-1", 200*time.Millisecond); ok {
		t.Fatalf("不得认领别人的 turn：%d", turn)
	}
	if elapsed := time.Since(start); elapsed < 150*time.Millisecond {
		t.Fatalf("应在超时后才放弃，实际 %s", elapsed)
	}
}

// ctx 取消时要立刻返回，不能把超时耗完——连接关闭时读协程需要它及时退出。
func TestDeepSeekAwaitTurnForRequestStopsOnContextCancel(t *testing.T) {
	follow := &deepSeekFollow{threadID: "s-1", updated: make(chan struct{}, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	if _, ok := follow.awaitTurnForRequest(ctx, "msg-1", 30*time.Second); ok {
		t.Fatal("ctx 取消后不得返回 turn")
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("ctx 取消后应立即返回，实际 %s", elapsed)
	}
}

// 回归：等待期间别的会话/别的端插进来一轮时，本次 ACK 仍必须绑定本次投递的 turn。
//
// 原先的实现先 drain 掉已有编号、再等"下一个出现的 turn"，于是在"等第一个 turn 编号"
// 这个口径下会把先到的外来轮次回给客户端。用户看到的是消息发出去之后绑定到了一个
// 不是它的轮次上：中断会指向别人的轮次，active 状态也会被别人的 turn/end 清掉。
func TestDeepSeekTurnStartAckIgnoresForeignTurnDuringWait(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{}}, nil
	})
	harness.handle(harnessclient.MethodSessionCreate, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"sessionId": "s-new", "agentPreset": "default"}, nil
	})

	var mu sync.Mutex
	var followConn *websocket.Conn
	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		switch endpoint, _ := open["endpoint"].(string); endpoint {
		case harnessclient.EndpointEvents:
			return writeDeepSeekMuxValue(conn, "", map[string]any{
				"type":     "ready",
				"clientId": "client-fixture",
			})
		case harnessclient.MethodSessionFollow:
			mu.Lock()
			followConn = conn
			mu.Unlock()
			return writeDeepSeekMuxValue(conn, "", map[string]any{
				"type":    "snapshot",
				"cursor":  12,
				"header":  map[string]any{"id": "s-new"},
				"records": []any{},
			})
		}
		return nil
	}
	harness.handle(harnessclient.MethodSessionPrompt, func(args json.RawMessage) (any, *harnessclient.RemoteError) {
		var envelope struct {
			Request map[string]any `json:"request"`
		}
		if err := json.Unmarshal(args, &envelope); err != nil {
			return nil, &harnessclient.RemoteError{Code: "gateway/bad-request", Message: err.Error()}
		}
		mu.Lock()
		conn := followConn
		mu.Unlock()
		if conn != nil {
			// 另一台端（Harness Web 页面）先跑起来的一轮，编号比本次小。
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "turn/start",
					"seq":  13,
					"data": map[string]any{"turn": 2},
				},
			})
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "user/message",
					"seq":  14,
					"data": map[string]any{
						"id":     "um-foreign",
						"role":   "user",
						"source": map[string]any{"kind": "user", "rpcId": "another-client-msg"},
					},
				},
			})
			// 本次投递自己的一轮。
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "turn/start",
					"seq":  15,
					"data": map[string]any{"turn": 3},
				},
			})
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "user/message",
					"seq":  16,
					"data": map[string]any{
						"id":      "um-1",
						"role":    "user",
						"content": []any{map[string]any{"type": "text", "text": "你好"}},
						"source":  map[string]any{"kind": "user", "rpcId": envelope.Request["requestId"]},
					},
				},
			})
		}
		return map[string]any{"accepted": true}, nil
	})

	harnessServer := harness.serve()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = harnessServer.URL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, harness.token)
	})
	workspace := server.router.cfg.Projects[0].Path

	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	callDeepSeekGateway(t, conn, 1, "initialize", map[string]any{})
	callDeepSeekGateway(t, conn, 2, "thread/start", map[string]any{"cwd": workspace})

	turn := callDeepSeekGateway(t, conn, 3, "turn/start", map[string]any{
		"threadId":            "s-new",
		"cwd":                 workspace,
		"clientUserMessageId": "msg-1",
		"input":               []any{map[string]any{"type": "text", "text": "你好"}},
	})
	turnInfo, _ := turn["turn"].(map[string]any)
	if turnInfo == nil {
		t.Fatalf("turn/start 应答缺少 turn：%+v", turn)
	}
	if turnInfo["id"] != "t3" {
		t.Fatalf("必须绑定本次 requestId 对应的 turn（t3），得到 %+v", turnInfo)
	}
}

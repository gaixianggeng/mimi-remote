package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

func TestDeepSeekInterruptChecksCurrentTurn(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	var cancels atomic.Int32
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{map[string]any{"sessionId": "s-stop", "cwd": harness.workspace}}}, nil
	})
	harness.handle(harnessclient.MethodSessionCancel, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		cancels.Add(1)
		return map[string]any{"accepted": true}, nil
	})
	opened := make(chan *websocket.Conn, 1)
	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		if open["endpoint"] == harnessclient.EndpointEvents {
			return writeDeepSeekMuxValue(conn, "", map[string]any{"type": "ready", "clientId": "interrupt-client"})
		}
		err := writeDeepSeekMuxValue(conn, "", map[string]any{
			"type": "snapshot", "cursor": 3, "hasMore": false,
			"records": []any{
				map[string]any{"type": "turn/start", "seq": 1, "data": map[string]any{"turn": 1}},
				map[string]any{"type": "turn/end", "seq": 2, "data": map[string]any{"turn": 1}},
				map[string]any{"type": "turn/start", "seq": 3, "data": map[string]any{"turn": 2}},
			},
		})
		opened <- conn
		return err
	}
	hs := harness.serve()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek = config.DeepSeekConfig{Enabled: true, BaseURL: hs.URL,
			TokenFile: writeDeepSeekTestTokenFile(t, harness.token), MaxConcurrentSessions: 2}
	})
	harness.setWorkspace(server.router.cfg.Projects[0].Path)
	ws := httptest.NewServer(server.handler)
	defer ws.Close()
	client := dialDeepSeekGateway(t, ws.URL)
	defer client.Close()
	callDeepSeekGateway(t, client, 101, "initialize", map[string]any{})
	callDeepSeekGateway(t, client, 102, "thread/list", map[string]any{"cwd": harness.workspace})
	// 不预先建 follow：中断路径必须先读取上游快照，不能凭线程授权就执行 Cancel。
	for i, target := range []any{"t1", "t-1", "invalid", "", nil, 2} {
		code, _ := callDeepSeekGatewayError(t, client, 200+i, "turn/interrupt", map[string]any{"threadId": "s-stop", "turnId": target})
		if code == 0 || cancels.Load() != 0 {
			t.Fatalf("目标 %v 不得取消当前 t2：code=%v cancels=%d", target, code, cancels.Load())
		}
	}
	callDeepSeekGateway(t, client, 300, "turn/interrupt", map[string]any{"threadId": "s-stop", "turnId": "t2"})
	if cancels.Load() != 1 {
		t.Fatalf("匹配的运行轮次应恰好取消一次：%d", cancels.Load())
	}
	upstream := <-opened
	if err := writeDeepSeekMuxValue(upstream, "", map[string]any{
		"type": "event", "event": map[string]any{"type": "turn/end", "seq": 4, "data": map[string]any{"turn": 2}},
	}); err != nil {
		t.Fatal(err)
	}
	readDeepSeekGatewayFrame(t, client) // 收到终态后再发送请求，确定网关已处理该边界。
	code, _ := callDeepSeekGatewayError(t, client, 301, "turn/interrupt", map[string]any{"threadId": "s-stop", "turnId": "t2"})
	if code == 0 || cancels.Load() != 1 {
		t.Fatalf("已结束的轮次不得再调用会话级 Cancel：code=%v cancels=%d", code, cancels.Load())
	}
}

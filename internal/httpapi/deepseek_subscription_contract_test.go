package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

func TestDeepSeekEvictedFollowNotifiesClientAndResubscribes(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	opened := make(chan *websocket.Conn, 4)
	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		if open["endpoint"] == harnessclient.EndpointEvents {
			return writeDeepSeekMuxValue(conn, "", map[string]any{"type": "ready", "clientId": "fixture"})
		}
		err := writeDeepSeekMuxValue(conn, "", map[string]any{
			"type": "snapshot", "cursor": 10, "hasMore": false, "records": []any{},
		})
		opened <- conn
		return err
	}
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		items := []any{}
		for _, id := range []string{"session-a", "session-b", "session-c"} {
			items = append(items, map[string]any{"sessionId": id, "cwd": harness.workspace})
		}
		return map[string]any{"items": items}, nil
	})
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
	callDeepSeekGateway(t, client, 1, "initialize", map[string]any{})
	callDeepSeekGateway(t, client, 2, "thread/list", map[string]any{"cwd": harness.workspace})
	callDeepSeekGateway(t, client, 3, "thread/turns/list", map[string]any{"threadId": "session-a"})
	<-opened
	callDeepSeekGateway(t, client, 4, "thread/turns/list", map[string]any{"threadId": "session-b"})
	<-opened
	if err := client.WriteJSON(map[string]any{"id": 5, "method": "thread/turns/list",
		"params": map[string]any{"threadId": "session-c"}}); err != nil {
		t.Fatal(err)
	}
	// 回收通知必须先于新订阅成功响应，以便 iOS 不再信任 A 的旧 binding。
	var actual, expected any
	if err := json.Unmarshal(readDeepSeekGatewayFrame(t, client), &actual); err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("../../contracts/mimi-protocol/fixtures/deepseek-follow-invalidated.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(fixture, &expected); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("回收通知与跨端契约不符：%v", actual)
	}
	if response := readDeepSeekGatewayResponse(t, client, 5); response["error"] != nil {
		t.Fatalf("C 订阅失败：%v", response)
	}
	<-opened
	callDeepSeekGateway(t, client, 6, "thread/turns/list", map[string]any{"threadId": "session-a"})
	upstream := <-opened
	for _, frame := range []map[string]any{
		{"type": "event", "event": map[string]any{"seq": 11, "type": "turn/start", "data": map[string]any{"turn": 1}}},
		{"type": "assistant-stream", "frame": map[string]any{"type": "start", "attemptId": "attempt-a", "turn": 1, "step": 1}},
		{"type": "assistant-stream", "frame": map[string]any{"type": "chunk", "attemptId": "attempt-a", "chunk": map[string]any{"type": "text-delta", "text": "external reply"}}},
		{"type": "event", "event": map[string]any{"seq": 12, "type": "turn/end", "data": map[string]any{"turn": 1, "reason": map[string]any{"kind": "completed"}}}},
	} {
		if err := writeDeepSeekMuxValue(upstream, "", frame); err != nil {
			t.Fatal(err)
		}
	}
	for _, method := range []string{"turn/started", "item/agentMessage/delta", "turn/completed"} {
		var frame map[string]any
		if err := json.Unmarshal(readDeepSeekGatewayFrame(t, client), &frame); err != nil {
			t.Fatal(err)
		}
		params, _ := frame["params"].(map[string]any)
		if frame["method"] != method || params["threadId"] != "session-a" {
			t.Fatalf("重新订阅后应收到 A 的 %s：%v", method, frame)
		}
	}
}

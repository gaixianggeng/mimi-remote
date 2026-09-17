package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

func TestDeepSeekSnapshotActivity(t *testing.T) {
	for _, tc := range []struct {
		name     string
		complete bool
		events   []string
		active   int
		known    bool
	}{
		{"empty complete", true, nil, 0, true},
		{"empty truncated", false, nil, 0, false},
		{"running", true, []string{"turn/start"}, 1, true},
		{"running truncated", false, []string{"turn/start"}, 1, true},
		{"ended truncated", false, []string{"turn/end"}, 0, true},
		{"restarted", true, []string{"turn/start", "turn/end", "turn/start"}, 1, true},
		{"no boundary", false, []string{"assistant/message"}, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &deepSeekFollow{reachedStart: tc.complete}
			for i, kind := range tc.events {
				f.records = append(f.records, harnessclient.SessionWireEvent{Seq: int64(i), Type: kind, Data: json.RawMessage(`{"turn":1}`)})
			}
			active, known := f.snapshotActivity()
			if active != tc.active || known != tc.known {
				t.Fatalf("activity = (%d, %v), want (%d, %v)", active, known, tc.active, tc.known)
			}
		})
	}
}

func TestDeepSeekUnknownSnapshotCannotBeReclaimed(t *testing.T) {
	follow := &deepSeekFollow{threadID: "session-a"}
	conn := &deepSeekGatewayConn{
		follows:     map[string]*deepSeekFollow{"session-a": follow},
		activeTurns: map[string]int{},
	}
	if conn.reclaimIdleFollow() || conn.follows["session-a"] != follow {
		t.Fatal("没有完整历史或 turn 边界时，不能把未知状态当成空闲")
	}
	conn.noteEventContext("session-a", harnessclient.SessionWireEvent{Type: deepSeekEventTurnStart, Data: json.RawMessage(`{"turn":2}`)})
	if conn.activeTurns["session-a"] != 1 || !follow.activityKnown {
		t.Fatal("实时 start 应把未知状态恢复为运行中")
	}
	conn.noteEventContext("session-a", harnessclient.SessionWireEvent{Type: deepSeekEventTurnEnd, Data: json.RawMessage(`{}`)})
	if conn.reclaimIdleFollow() {
		t.Fatal("残缺的结束事件不能使订阅可回收")
	}
	conn.noteEventContext("session-a", harnessclient.SessionWireEvent{Type: deepSeekEventTurnEnd, Data: json.RawMessage(`{"turn":2}`)})
	if conn.activeTurns["session-a"] != 0 || !follow.activityKnown {
		t.Fatal("有效的结束事件应恢复已知空闲状态")
	}
}

// start 只在 snapshot 中出现：回收名额不得让 A 的 delta 和完成事件静默消失。
func TestDeepSeekSnapshotRunningFollowSurvivesReclaim(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	followReady := make(chan *websocket.Conn, 2)
	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		if open["endpoint"] == harnessclient.EndpointEvents {
			return writeDeepSeekMuxValue(conn, "", map[string]any{"type": "ready", "clientId": "client-fixture"})
		}
		err := writeDeepSeekMuxValue(conn, "", map[string]any{
			"type": "snapshot", "cursor": 10, "hasMore": false,
			"records": []any{map[string]any{"type": "event", "event": map[string]any{
				"seq": 10, "type": "turn/start", "data": map[string]any{"turn": 1},
			}}},
		})
		followReady <- conn
		return err
	}
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{
			map[string]any{"sessionId": "session-a", "cwd": harness.workspace},
			map[string]any{"sessionId": "session-b", "cwd": harness.workspace},
		}}, nil
	})
	hs := harness.serve()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = hs.URL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, harness.token)
		cfg.DeepSeek.MaxConcurrentSessions = 1
	})
	harness.setWorkspace(server.router.cfg.Projects[0].Path)
	ws := httptest.NewServer(server.handler)
	defer ws.Close()
	client := dialDeepSeekGateway(t, ws.URL)
	defer client.Close()
	callDeepSeekGateway(t, client, 1, "initialize", map[string]any{})
	callDeepSeekGateway(t, client, 2, "thread/list", map[string]any{"cwd": harness.workspace})
	callDeepSeekGateway(t, client, 3, "thread/turns/list", map[string]any{"threadId": "session-a"})
	upstream := <-followReady
	response := sendDeepSeekGatewayRequest(t, client, 4, "thread/turns/list", map[string]any{"threadId": "session-b"})
	if response["error"] == nil {
		t.Fatalf("运行中的 A 不得被 B 回收：%v", response)
	}
	for _, frame := range []map[string]any{
		{"type": "assistant-stream", "frame": map[string]any{"type": "start", "attemptId": "attempt-a", "turn": 1, "step": 1}},
		{"type": "assistant-stream", "frame": map[string]any{"type": "chunk", "attemptId": "attempt-a", "chunk": map[string]any{"type": "text-delta", "text": "still running"}}},
		{"type": "event", "event": map[string]any{"seq": 11, "type": "turn/end", "data": map[string]any{"turn": 1, "reason": map[string]any{"kind": "completed"}}}},
	} {
		if err := writeDeepSeekMuxValue(upstream, "", frame); err != nil {
			t.Fatal(err)
		}
	}
	for _, method := range []string{"item/agentMessage/delta", "turn/completed"} {
		var frame map[string]any
		if err := json.Unmarshal(readDeepSeekGatewayFrame(t, client), &frame); err != nil {
			t.Fatal(err)
		}
		params, _ := frame["params"].(map[string]any)
		if frame["method"] != method || params["threadId"] != "session-a" {
			t.Fatalf("应继续收到 A 的 %s：%v", method, frame)
		}
	}
	// 完成事件到达后名额应恢复可回收，避免保护变成永久占用。
	callDeepSeekGateway(t, client, 5, "thread/turns/list", map[string]any{"threadId": "session-b"})
}

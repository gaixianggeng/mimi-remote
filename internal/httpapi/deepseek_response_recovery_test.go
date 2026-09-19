package httpapi

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

// 只让交互 HTTP 回传失败；$events 与 follow 两条 WebSocket 都保持健康。
// 经过真实 policy 消费 pending，再验证网关断线、重新授权与同一交互重投。
func TestDeepSeekInteractionResponseFailureClosesAndReplays(t *testing.T) {
	for _, test := range []struct {
		name             string
		question         bool
		clientError      bool
		acceptedThenLost bool
	}{
		{name: "approval"},
		{name: "question", question: true},
		{name: "client error", clientError: true},
		{name: "accepted but response lost", acceptedThenLost: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			harness := newFakeDeepSeekHarness(t)
			request := deepSeekApprovalRequest("event-response-recovery")
			request.AgentID = "s-recovery"
			if test.question {
				request.Event = harnessclient.WaterfallUserQuestions
				request.Request = harnessclient.WaterfallPayload{Questions: []harnessclient.Question{{
					ID: "q1", Question: "是否继续？", Options: []harnessclient.QuestionOption{{Label: "继续"}},
				}}}
			}
			var pending atomic.Bool
			pending.Store(true)
			var attempts, effects atomic.Int32
			harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
				if open["endpoint"] == harnessclient.EndpointEvents {
					if err := writeDeepSeekMuxValue(conn, "", map[string]any{"type": "ready", "clientId": "recovery-client"}); err != nil {
						return err
					}
					if pending.Load() {
						return writeDeepSeekMuxValue(conn, "", request)
					}
					return nil
				}
				return writeDeepSeekMuxValue(conn, "", map[string]any{
					"type": "snapshot", "cursor": 1, "hasMore": false,
					"records": []any{map[string]any{"type": "turn/start", "seq": 1, "data": map[string]any{"turn": 1}}},
				})
			}
			harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
				return map[string]any{"items": []any{map[string]any{"sessionId": request.AgentID, "cwd": harness.workspace}}}, nil
			})
			harness.handle(harnessclient.EndpointEventsResult, func(raw json.RawMessage) (any, *harnessclient.RemoteError) {
				var response struct {
					EventID string `json:"eventId"`
				}
				if err := json.Unmarshal(raw, &response); err != nil || response.EventID != request.EventID {
					t.Errorf("应答必须对应原交互：%s", raw)
				}
				if pending.Swap(false) {
					effects.Add(1)
				}
				return map[string]any{}, nil
			})
			hs := harness.serve()
			faultServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/api/"+harnessclient.EndpointEventsResult && attempts.Add(1) == 1 {
					if test.acceptedThenLost && pending.Swap(false) {
						effects.Add(1)
					}
					http.Error(w, "temporary failure", http.StatusServiceUnavailable)
					return
				}
				hs.Config.Handler.ServeHTTP(w, r)
			}))
			defer faultServer.Close()
			server := newTestServerWithConfig(t, func(cfg *config.Config) {
				cfg.DeepSeek = config.DeepSeekConfig{Enabled: true, BaseURL: faultServer.URL,
					TokenFile: writeDeepSeekTestTokenFile(t, harness.token), MaxConcurrentSessions: 2}
			})
			harness.setWorkspace(server.router.cfg.Projects[0].Path)
			ws := httptest.NewServer(server.handler)
			defer ws.Close()
			cards := map[*websocket.Conn]map[string]any{}
			connect := func() *websocket.Conn {
				client := dialDeepSeekGateway(t, ws.URL)
				t.Cleanup(func() { _ = client.Close() })
				for i, call := range []struct {
					method string
					params map[string]any
				}{
					{"initialize", map[string]any{}},
					{"thread/list", map[string]any{"cwd": harness.workspace}},
					{"thread/turns/list", map[string]any{"threadId": request.AgentID}},
				} {
					id := 101 + i
					if err := client.WriteJSON(map[string]any{"id": id, "method": call.method, "params": call.params}); err != nil {
						t.Fatal(err)
					}
					for {
						var frame map[string]any
						if err := json.Unmarshal(readDeepSeekGatewayFrame(t, client), &frame); err != nil {
							t.Fatal(err)
						}
						// 上游重投可能先于首读响应；保留卡片，不能被普通 RPC helper 跳过。
						if frame["method"] != nil && frame["id"] != nil {
							cards[client] = frame
						} else if frame["id"] == float64(id) {
							if frame["error"] != nil {
								t.Fatalf("%s 失败：%v", call.method, frame)
							}
							break
						}
					}
				}
				return client
			}
			answer := func(client *websocket.Conn) map[string]any {
				t.Helper()
				card := cards[client]
				if card == nil {
					if err := json.Unmarshal(readDeepSeekGatewayFrame(t, client), &card); err != nil {
						t.Fatal(err)
					}
				}
				if card["id"] == nil || card["method"] == nil {
					t.Fatalf("重连必须重新下发原交互：%v", card)
				}
				response := map[string]any{"id": card["id"], "result": map[string]any{"decision": "accept"}}
				if test.question {
					response["result"] = map[string]any{"answers": map[string]any{"q1": map[string]any{"answers": []string{"继续"}}}}
				} else if test.clientError {
					delete(response, "result")
					response["error"] = map[string]any{"code": -32000, "message": "unavailable"}
				}
				if err := client.WriteJSON(response); err != nil {
					t.Fatal(err)
				}
				return response
			}

			client := connect()
			if len(harness.openedEndpoints()) != 2 {
				t.Fatal("故障前必须同时建立 $events 与 follow")
			}
			answer(client)
			if err := client.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
				t.Fatal(err)
			}
			if _, _, err := client.ReadMessage(); err == nil {
				t.Fatal("应答失败必须结束连接")
			} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
				t.Fatal("应答失败后连接仍保持打开，pending 无法恢复")
			}
			reconnected := connect()
			if test.acceptedThenLost && cards[reconnected] != nil {
				t.Fatal("Harness 已接受的交互不得重投")
			}
			if !test.acceptedThenLost {
				response := answer(reconnected)
				// 重复点击经过公共 policy；不得再次回传或再次产生上游效果。
				if err := reconnected.WriteJSON(response); err != nil {
					t.Fatal(err)
				}
			}
			callDeepSeekGateway(t, reconnected, 900, "initialize", map[string]any{})
			wantAttempts := int32(2)
			if test.acceptedThenLost {
				wantAttempts = 1
			}
			if attempts.Load() != wantAttempts || effects.Load() != 1 {
				t.Fatalf("只能重答仍 pending 的交互：attempts=%d effects=%d", attempts.Load(), effects.Load())
			}
		})
	}
}

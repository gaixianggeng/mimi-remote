package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

// 两个活跃观察者占满名额时，第三个观察者必须明确失败；最后一个 observer detach 后，
// 标准 unsubscribe 解除租约，第三个会话才能按普通 LRU 回收 A 并建立观察。
func TestDeepSeekObservationLeasesBlockEvictionUntilUnsubscribe(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	opened := make(chan string, 4)
	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		if open["endpoint"] == harnessclient.EndpointEvents {
			return writeDeepSeekMuxValue(conn, "", map[string]any{"type": "ready", "clientId": "fixture"})
		}
		endpoint, _ := open["endpoint"].(string)
		err := writeDeepSeekMuxValue(conn, "", map[string]any{
			"type": "snapshot", "cursor": 10, "hasMore": false, "records": []any{},
		})
		opened <- endpoint
		return err
	}
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		items := make([]any, 0, 3)
		for _, id := range []string{"session-a", "session-b", "session-c"} {
			items = append(items, map[string]any{"sessionId": id, "cwd": harness.workspace})
		}
		return map[string]any{"items": items}, nil
	})
	hs := harness.serve()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek = config.DeepSeekConfig{
			Enabled: true, BaseURL: hs.URL, TokenFile: writeDeepSeekTestTokenFile(t, harness.token),
			MaxConcurrentSessions: 2,
		}
	})
	harness.setWorkspace(server.router.cfg.Projects[0].Path)
	ws := httptest.NewServer(server.handler)
	defer ws.Close()
	client := dialDeepSeekGateway(t, ws.URL)
	defer client.Close()

	callDeepSeekGateway(t, client, 1, "initialize", map[string]any{})
	callDeepSeekGateway(t, client, 2, "thread/list", map[string]any{"cwd": harness.workspace})
	for index, id := range []string{"session-a", "session-b"} {
		callDeepSeekGateway(t, client, 3+index, "thread/turns/list", map[string]any{
			"threadId": id, "_mimi_observe": true,
		})
		<-opened
	}
	if code, _ := callDeepSeekGatewayError(t, client, 5, "thread/turns/list", map[string]any{
		"threadId": "session-c", "_mimi_observe": true,
	}); code == 0 {
		t.Fatal("两个观察租约占满名额时，第三个观察者必须明确失败")
	}
	select {
	case endpoint := <-opened:
		t.Fatalf("容量失败不得偷偷订阅 C：%s", endpoint)
	default:
	}

	// 未 pin 的 unsubscribe 也必须幂等；随后真正解除 A 的租约。
	for _, unsubscribe := range []struct {
		requestID int
		threadID  string
	}{{6, "session-c"}, {7, "session-a"}} {
		result := callDeepSeekGateway(t, client, unsubscribe.requestID, "thread/unsubscribe", map[string]any{"threadId": unsubscribe.threadID})
		if result["status"] != "unsubscribed" {
			t.Fatalf("标准 unsubscribe 回包不符：thread=%s result=%+v", unsubscribe.threadID, result)
		}
	}
	callDeepSeekGateway(t, client, 8, "thread/turns/list", map[string]any{
		"threadId": "session-c", "_mimi_observe": true,
	})
	if endpoint := <-opened; endpoint != harnessclient.MethodSessionFollow {
		t.Fatalf("A 解除租约后 C 应建立 follow：%s", endpoint)
	}
}

func TestDeepSeekObservedRunningAndPendingFollowsCannotBeReclaimed(t *testing.T) {
	for _, tc := range []struct {
		name       string
		observed   bool
		active     int
		waterfalls map[string]deepSeekPendingWaterfall
	}{
		{name: "observed", observed: true},
		{name: "running", active: 1},
		{name: "pending", waterfalls: map[string]deepSeekPendingWaterfall{
			"event-1": {threadID: "session-a"},
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			follow := &deepSeekFollow{
				threadID: "session-a", activityKnown: true, observed: tc.observed,
				lastUsed: time.Unix(1, 0),
			}
			conn := &deepSeekGatewayConn{
				follows:     map[string]*deepSeekFollow{"session-a": follow},
				activeTurns: map[string]int{"session-a": tc.active},
				waterfalls:  tc.waterfalls, pendingInteractions: map[string]deepSeekPendingInteraction{},
			}
			if conn.reclaimIdleFollow() {
				t.Fatalf("%s follow 不得被回收", tc.name)
			}
			if conn.follows["session-a"] != follow {
				t.Fatalf("%s follow 必须仍在连接内", tc.name)
			}
		})
	}
}

func TestDeepSeekObserveFlagIsPrivateAndStrictlyTyped(t *testing.T) {
	for _, value := range []string{"true", "false"} {
		policy, _ := newInboundPolicyForTest(t, appServerRuntimeDeepSeekID)
		payload := []byte(`{"id":1,"method":"thread/turns/list","params":{"threadId":"allowed","_mimi_observe":` + value + `}}`)
		rewritten, policyErr := policy.validateClientFrame(websocket.TextMessage, payload)
		if policyErr != nil {
			t.Fatalf("DeepSeek 合法观察标志必须放行：value=%s err=%v", value, policyErr)
		}
		var frame struct {
			Params map[string]any `json:"params"`
		}
		if err := json.Unmarshal(rewritten, &frame); err != nil {
			t.Fatal(err)
		}
		if got, ok := frame.Params["_mimi_observe"].(bool); !ok || got != (value == "true") {
			t.Fatalf("DeepSeek 观察标志必须原样保留：%s", rewritten)
		}
	}

	for _, malformed := range []string{`"true"`, `1`, `null`, `{}`} {
		policy, _ := newInboundPolicyForTest(t, appServerRuntimeDeepSeekID)
		payload := []byte(`{"id":2,"method":"thread/turns/list","params":{"threadId":"allowed","_mimi_observe":` + malformed + `}}`)
		if _, policyErr := policy.validateClientFrame(websocket.TextMessage, payload); policyErr == nil {
			t.Fatalf("非布尔观察标志必须拒绝：%s", malformed)
		}
	}

	for _, runtimeID := range []string{appServerRuntimeCodexID, appServerRuntimeClaudeID} {
		policy, _ := newInboundPolicyForTest(t, runtimeID)
		payload := []byte(`{"id":3,"method":"thread/turns/list","params":{"threadId":"allowed","_mimi_observe":true}}`)
		if _, policyErr := policy.validateClientFrame(websocket.TextMessage, payload); policyErr == nil {
			t.Fatalf("%s 不得接受 DeepSeek 私有观察标志", runtimeID)
		}
	}
}

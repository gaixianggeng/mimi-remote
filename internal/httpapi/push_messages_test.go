package httpapi

import (
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
	"github.com/gorilla/websocket"
)

func TestTurnMessageClassification(t *testing.T) {
	cases := []struct{ name, method, params, event string }{
		{"complete", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"completed"}}`, pushbridge.EventTurnCompleted},
		{"failed", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"failed","error":{"message":"private"}}}`, pushbridge.EventTurnFailed},
		{"stopped", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"interrupted"}}`, pushbridge.EventTurnInterrupted},
		{"legacy", "turn/completed", `{"threadId":"t","turnId":"r"}`, pushbridge.EventTurnCompleted},
		{"terminal error", "error", `{"threadId":"t","turnId":"r","willRetry":false}`, pushbridge.EventTurnFailed},
		{"retry", "error", `{"threadId":"t","turnId":"r","willRetry":true}`, ""},
		{"delta", "item/agentMessage/delta", `{"threadId":"t","turnId":"r","delta":"private"}`, ""},
		{"missing turn", "turn/completed", `{"threadId":"t"}`, ""},
		{"not terminal", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"inProgress"}}`, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frame := appServerGatewayFrame{Method: tc.method, Params: json.RawMessage(tc.params)}
			got, ok := turnMessageFromFrame(&frame)
			if ok != (tc.event != "") || got.Event != tc.event {
				t.Fatalf("got %+v %v", got, ok)
			}
		})
	}
}

func TestAuthorizedCompletionNotifiesAndRoutesWithoutApprovalRights(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-one")
	policy := newAppServerGatewayPolicy(router, "codex")
	payload := []byte(`{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-one","status":"completed","items":[{"text":"PRIVATE REPLY"}]}}}`)
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || !forward {
		t.Fatalf("frame rejected: %v", err)
	}
	notification := provider.waitFor(t, pushbridge.EventTurnCompleted)
	if _, exists := notification["text"]; exists {
		t.Fatal("reply leaked")
	}
	if notification["approval_kind"] != "" {
		t.Fatal("message grants approval type")
	}
	actionID := notification["action_id"].(string)
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/push/actions/route?action_id="+url.QueryEscape(actionID)+"&device_id=device-one", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var route map[string]any
	json.NewDecoder(response.Body).Decode(&route)
	if response.StatusCode != 200 || route["thread_id"] != "thread-1" {
		t.Fatalf("route failed: %d %v", response.StatusCode, route)
	}
	status, _ := postDecide(t, server, actionID, "device-one", "allow")
	if status == http.StatusOK {
		t.Fatal("message was accepted as approval")
	}
	policy.observeUpstreamFrame(websocket.TextMessage, payload)
	private := []byte(`{"method":"turn/completed","params":{"threadId":"not-authorized","turn":{"id":"another","status":"completed"}}}`)
	if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, private); forward {
		t.Fatal("unauthorized frame forwarded")
	}
	time.Sleep(50 * time.Millisecond)
	if provider.count() != 1 {
		t.Fatalf("duplicate or unauthorized push: %d", provider.count())
	}
}

func TestRetryableErrorPreservesBackgroundObservation(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-one")
	policy := newAppServerGatewayPolicy(router, "codex")
	started := []byte(`{"method":"turn/started","params":{"threadId":"thread-1","turnId":"turn-one"}}`)
	retry := []byte(`{"method":"error","params":{"threadId":"thread-1","turnId":"turn-one","willRetry":true}}`)
	policy.observeUpstreamFrame(websocket.TextMessage, started)
	policy.observeUpstreamFrame(websocket.TextMessage, retry)
	active, _ := policy.approvalObservationSnapshot()
	if _, ok := active["thread-1"]; !ok {
		t.Fatal("retry closed active turn observation")
	}
	broker := &codexGatewayBroker{router: router, policy: policy, key: "session", activeTurns: map[string]struct{}{}, startingTurns: map[string]string{}, detachedAt: time.Now().Add(-20 * time.Minute)}
	broker.observeLifecycle(websocket.TextMessage, started)
	broker.observeLifecycle(websocket.TextMessage, retry)
	if _, ok := broker.activeTurns["thread-1"]; !ok {
		t.Fatal("retry removed active broker turn")
	}
	if reason := broker.sweepCloseReason(time.Now()); reason != "" {
		t.Fatalf("long task prematurely closed: %s", reason)
	}
	broker.detachedAt = time.Now().Add(-codexGatewayBrokerDetachTTL - time.Second)
	if reason := broker.sweepCloseReason(time.Now()); reason != "broker_detach_ttl" {
		t.Fatalf("missing upper bound: %s", reason)
	}
}

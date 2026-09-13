package httpapi

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestBrokerQueuedMessageKeepsUpstreamBeforeTurnStarted(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, up.url, provider.server.URL)
	registerPushDevice(t, server, "device-a")
	client := brokerDial(t, server, pushTestSession)
	upstream := up.accept(t)
	request := `{"id":15,"method":"thread/queue/add","params":{"threadId":"thread-1","clientUserMessageId":"queued-one","input":[{"type":"text","text":"test"}]}}`
	if err := client.WriteMessage(websocket.TextMessage, []byte(request)); err != nil {
		t.Fatal(err)
	}
	up.waitForUpstreamFrame(t, func(p []byte) bool {
		var f appServerGatewayFrame
		return json.Unmarshal(p, &f) == nil && f.Method == "thread/queue/add"
	}, time.Second)
	broker := waitForBroker(t, router, pushTestSession, true)
	_ = client.Close()
	waitForDetachedBroker(t, broker)
	if reason := broker.sweepCloseReason(time.Now()); reason != "" {
		t.Fatalf("queued task lost on detach: %s", reason)
	}
	up.emit(t, upstream, brokerTurnStartedFrame)
	up.emit(t, upstream, `{"method":"item/started","params":{"threadId":"thread-1","item":{"type":"userMessage","id":"user-one","clientId":"queued-one"}}}`)
	up.emit(t, upstream, brokerTurnDoneFrame)
	provider.waitFor(t, "turn.completed")
}

func TestBrokerPageUnsubscribeKeepsActiveTaskUntilCompletion(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, up.url, provider.server.URL)
	registerPushDevice(t, server, "device-a")
	client := brokerDial(t, server, pushTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, client, "turn/started", time.Second)
	request := `{"id":16,"method":"thread/unsubscribe","params":{"threadId":"thread-1"}}`
	if err := client.WriteMessage(websocket.TextMessage, []byte(request)); err != nil {
		t.Fatal(err)
	}
	select {
	case payload := <-up.frames:
		t.Fatalf("page exit removed the active upstream subscription: %s", payload)
	case <-time.After(80 * time.Millisecond):
	}
	_ = client.SetReadDeadline(time.Now().Add(time.Second))
	var response struct {
		ID     int `json:"id"`
		Result struct {
			Status string `json:"status"`
		} `json:"result"`
	}
	if err := client.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response.ID != 16 || response.Result.Status != "unsubscribed" {
		t.Fatalf("missing local unsubscribe receipt: %+v", response)
	}
	// 页面已离开，但 App 的共享 WebSocket 仍开着。后到审批也必须推送。
	up.emit(t, upstream, brokerApprovalFrame)
	provider.waitFor(t, "approval.pending")
	up.emit(t, upstream, brokerTurnDoneFrame)
	provider.waitFor(t, "turn.completed")
	up.waitForUpstreamFrame(t, func(p []byte) bool {
		var f appServerGatewayFrame
		return json.Unmarshal(p, &f) == nil && f.Method == "thread/unsubscribe"
	}, time.Second)
	_ = router
}

func waitForDetachedBroker(t *testing.T, broker *codexGatewayBroker) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		broker.mu.Lock()
		detached, closed := broker.sink == nil, broker.closed
		broker.mu.Unlock()
		if closed {
			t.Fatal("broker closed before the queued task started")
		}
		if detached {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("client did not detach")
}

func TestBrokerQueueKeepsNextMessageAcrossPreviousCompletion(t *testing.T) {
	_, router := brokerTestServer(t, "ws://unused", true)
	b := &codexGatewayBroker{router: router, policy: newAppServerGatewayPolicy(router, "codex"), activeTurns: map[string]struct{}{}, startingTurns: map[string]string{}}
	b.observeLifecycle(websocket.TextMessage, []byte(brokerTurnStartedFrame))
	rollback := b.trackClientFrameForward(websocket.TextMessage, []byte(`{"id":1,"method":"thread/queue/add","params":{"threadId":"thread-1","clientUserMessageId":"next"}}`))
	b.observeLifecycle(websocket.TextMessage, []byte(brokerTurnDoneFrame))
	if reason := b.sweepCloseReason(time.Now()); reason != "" {
		t.Fatalf("previous completion lost the next message: %s", reason)
	}
	b.observeLifecycle(websocket.TextMessage, []byte(brokerTurnStartedFrame))
	b.observeLifecycle(websocket.TextMessage, []byte(`{"method":"item/started","params":{"threadId":"thread-1","item":{"type":"userMessage","clientId":"previous"}}}`))
	if len(b.queuedTurns) != 1 {
		t.Fatal("a different message consumed the queue reservation")
	}
	b.observeLifecycle(websocket.TextMessage, []byte(`{"method":"item/started","params":{"threadId":"thread-1","item":{"type":"userMessage","clientId":"next"}}}`))
	if len(b.queuedTurns) != 0 {
		t.Fatal("started message kept its queue reservation")
	}
	rollback() // 迟到的旧写入回滚不得重新创建已消费的条目。
	b.observeLifecycle(websocket.TextMessage, []byte(brokerTurnDoneFrame))
	if reason := b.sweepCloseReason(time.Now()); reason != "broker_idle_expired" {
		t.Fatalf("finished queue retained the broker: %s", reason)
	}
}

func TestBrokerRejectedQueueReleasesReservation(t *testing.T) {
	_, router := brokerTestServer(t, "ws://unused", true)
	b := &codexGatewayBroker{router: router, policy: newAppServerGatewayPolicy(router, "codex"), activeTurns: map[string]struct{}{}, startingTurns: map[string]string{}}
	request := []byte(`{"id":1,"method":"thread/queue/add","params":{"threadId":"thread-1","clientUserMessageId":"next"}}`)
	rollback := b.trackClientFrameForward(websocket.TextMessage, request)
	rollback()
	if len(b.queuedTurns) != 0 {
		t.Fatal("write failure retained queue reservation")
	}
	b.trackClientFrameForward(websocket.TextMessage, request)
	b.observeLifecycle(websocket.TextMessage, []byte(`{"id":1,"error":{"code":-1,"message":"rejected"}}`))
	if len(b.queuedTurns) != 0 {
		t.Fatal("rejected queue retained reservation")
	}
}

func TestBrokerResumeKeepsAlreadyRunningTaskWithoutNewStartedEvent(t *testing.T) {
	for _, status := range []string{"active", "idle"} {
		t.Run(status, func(t *testing.T) {
			_, router := brokerTestServer(t, "ws://unused", true)
			b := &codexGatewayBroker{router: router, policy: newAppServerGatewayPolicy(router, "codex"), activeTurns: map[string]struct{}{}, startingTurns: map[string]string{}}
			b.trackClientFrameForward(websocket.TextMessage, []byte(`{"id":1,"method":"thread/resume","params":{"threadId":"thread-1"}}`))
			if reason := b.sweepCloseReason(time.Now()); reason != "" {
				t.Fatalf("resume in flight was retired: %s", reason)
			}
			b.observeLifecycle(websocket.TextMessage, []byte(fmt.Sprintf(`{"id":1,"result":{"thread":{"id":"thread-1","status":{"type":%q}}}}`, status)))
			if len(b.startingTurns) != 0 {
				t.Fatal("resume receipt retained starting reservation")
			}
			_, active := b.activeTurns["thread-1"]
			if active != (status == "active") {
				t.Fatalf("active state=%v for %s", active, status)
			}
		})
	}
}

func TestBrokerResumeWaitsForDeferredUnsubscribeAcknowledgement(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, true)
	client := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, client, "turn/started", time.Second)
	if err := client.WriteMessage(websocket.TextMessage, []byte(`{"id":1,"method":"thread/unsubscribe","params":{"threadId":"thread-1"}}`)); err != nil {
		t.Fatal(err)
	}
	var response map[string]any
	_ = client.SetReadDeadline(time.Now().Add(time.Second))
	if err := client.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	up.emit(t, upstream, brokerTurnDoneFrame)
	readFrameWithMethod(t, client, "turn/completed", time.Second)
	payload := up.waitForUpstreamFrame(t, func(p []byte) bool {
		var f appServerGatewayFrame
		return json.Unmarshal(p, &f) == nil && f.Method == "thread/unsubscribe"
	}, time.Second)
	var release appServerGatewayFrame
	if err := json.Unmarshal(payload, &release); err != nil {
		t.Fatal(err)
	}
	broker := waitForBroker(t, router, brokerTestSession, true)
	thread, _ := broker.policy.allowedThread("thread-1")
	if err := client.WriteJSON(map[string]any{"id": 2, "method": "thread/resume", "params": map[string]string{"threadId": "thread-1", "cwd": thread.cwd}}); err != nil {
		t.Fatal(err)
	}
	select {
	case p := <-up.frames:
		t.Fatalf("resume overtook unsubscribe ACK: %s", p)
	case <-time.After(50 * time.Millisecond):
	}
	up.emit(t, upstream, fmt.Sprintf(`{"id":%s,"result":{"status":"unsubscribed"}}`, *release.ID))
	up.waitForUpstreamFrame(t, func(p []byte) bool {
		var f appServerGatewayFrame
		return json.Unmarshal(p, &f) == nil && f.Method == "thread/resume"
	}, time.Second)
}

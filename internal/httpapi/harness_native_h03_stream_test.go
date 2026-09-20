package httpapi

import (
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

// 此文件复用真实 Router + HTTP/WS harnessNativeStreamStub，不通过 handler 内部跳过授权。
// 所有场景使用夹具响应，不调用真实供应商。通道控制故障切点，不用 sleep 猜时序。
func h03SendUpstream(t *testing.T, conn *websocket.Conn, streamID string, value any) {
	t.Helper()
	if err := conn.WriteJSON(map[string]any{
		"type": harnessclient.CarrierItem, "streamId": streamID, "value": value,
	}); err != nil {
		t.Errorf("write upstream: %v", err)
	}
}

func h03Open(t *testing.T, conn *websocket.Conn, streamID, endpoint, sessionID string) {
	t.Helper()
	frame := map[string]any{"type": "open", "streamId": streamID, "endpoint": endpoint}
	if sessionID != "" {
		frame["payload"] = map[string]any{"args": map[string]any{"request": map[string]any{
			"address": map[string]any{"kind": "session", "sessionId": sessionID},
		}}}
	}
	sendHarnessNativeFrame(t, conn, frame)
}

func h03Value(t *testing.T, frame map[string]any) map[string]any {
	t.Helper()
	value, ok := frame["value"].(map[string]any)
	if !ok || frame["type"] != harnessclient.CarrierItem {
		t.Fatalf("expected item, got %v", frame)
	}
	return value
}

func h03Approval(sessionID, eventID string) map[string]any {
	return map[string]any{
		"type": "waterfall", "event": "approval/request", "eventId": eventID,
		"agentId": sessionID, "request": map[string]any{"toolName": "write", "callId": "call-a"},
	}
}

// h03RespondAck 断言一帧是某个 eventId 的应答回执，并返回它。
//
// 回执必须带 eventId：移动端靠它把结论关联到具体卡片。没有它，手机只能把
// "帧写出成功"当成"上游已接受"，而上游随后可能拒绝。
func h03RespondAck(t *testing.T, frame map[string]any, eventID string) map[string]any {
	t.Helper()
	if frame["type"] != harnessclient.CarrierItem {
		t.Fatalf("respond ack must ride the item carrier: %v", frame)
	}
	value := h03Value(t, frame)
	if value["type"] != "responded" {
		t.Fatalf("expected responded frame, got %v", value)
	}
	if value["eventId"] != eventID {
		t.Fatalf("respond ack carried eventId %v, want %v", value["eventId"], eventID)
	}
	if frame["streamId"] == "" || frame["streamId"] == nil {
		// 无 streamId 的帧会被移动端判为"无法归属"而丢弃，等于没有回执。
		t.Fatalf("respond ack must be attributable: %v", frame)
	}
	return value
}

// h03RespondOutcome 断言回执的结论判别值。
//
// 四态不能合并：`rejected` 要放回重试，而 `unknown` 必须保持锁定——
// 把后者当成前者会让一次可能已生效的审批被重复执行。
func h03RespondOutcome(t *testing.T, value map[string]any, want string) {
	t.Helper()
	if value["outcome"] != want {
		t.Fatalf("respond outcome = %v, want %v", value["outcome"], want)
	}
}

func h03AssertTransportClosed(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, err := conn.ReadMessage()
	if err == nil {
		t.Fatal("expected connection to close")
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("silent timeout is not a connection-close signal")
	}
}

func TestHarnessNativeH03ControlBaselineFiltersAtRouter(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stop := make(chan struct{})
	defer close(stop)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		id := open["streamId"].(string)
		h03SendUpstream(t, conn, id, map[string]any{
			"type": "baseline", "value": map[string]any{
				"queues":      map[string]any{"allowed": []any{}, "private": []any{"SECRET-QUEUE"}},
				"jobs":        map[string]any{"allowed": []any{}, "private": []any{"SECRET-JOB"}},
				"projections": map[string]any{"allowed": map[string]any{"asOfSeq": 1, "values": map[string]any{}}, "private": map[string]any{"title": "SECRET-TITLE"}},
			},
		})
		<-stop
	}
	url, cwd := harnessNativeStreamFixture(t, stub)
	stub.mu.Lock()
	stub.sessions = []harnessclient.SessionSummary{
		harnessNativeFixtureSession("allowed", cwd),
		harnessNativeFixtureSession("private", t.TempDir()),
	}
	stub.mu.Unlock()
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "control", "session/control", "")
	frame := readHarnessNativeFrame(t, conn)
	value := h03Value(t, frame)
	encoded, _ := json.Marshal(value)
	if strings.Contains(string(encoded), "private") || strings.Contains(string(encoded), "SECRET") {
		t.Fatalf("unauthorized control data escaped: %s", encoded)
	}
	baseline := value["value"].(map[string]any)
	for _, name := range []string{"queues", "jobs", "projections"} {
		entries := baseline[name].(map[string]any)
		if len(entries) != 1 || entries["allowed"] == nil {
			t.Fatalf("authorized %s missing: %v", name, entries)
		}
	}
	_, listCalls := stub.upstreamTouches()
	if listCalls != 1 {
		t.Fatalf("baseline should authorize against one directory read, got %d", listCalls)
	}
}

func TestHarnessNativeH03UnexpectedFollowEOFClosesDownstream(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	disconnect := make(chan struct{})
	defer func() {
		select {
		case <-disconnect:
		default:
			close(disconnect)
		}
	}()
	var cwd string
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		h03SendUpstream(t, conn, open["streamId"].(string), map[string]any{
			"type": "snapshot", "header": map[string]any{"id": "session-a", "cwd": cwd},
			"cursor": 0, "records": []any{}, "hasMore": false,
		})
		<-disconnect // return closes only the upstream physical socket; no carrier end.
	}
	url, authorized := harnessNativeStreamFixture(t, stub)
	cwd = authorized
	stub.mu.Lock()
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
	stub.mu.Unlock()
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "follow", "session/follow", "session-a")
	if h03Value(t, readHarnessNativeFrame(t, conn))["type"] != "snapshot" {
		t.Fatal("missing snapshot")
	}
	close(disconnect)
	frame := readHarnessNativeFrame(t, conn)
	if frame["type"] != harnessclient.CarrierError || frame["streamId"] != "follow" {
		t.Fatalf("physical EOF must be observable: %v", frame)
	}
	h03AssertTransportClosed(t, conn)
}

func TestHarnessNativeH03FollowUnsubscribeKeepsPendingAnswer(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stop := make(chan struct{})
	defer close(stop)
	var cwd string
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		id := open["streamId"].(string)
		switch open["endpoint"] {
		case "$events":
			h03SendUpstream(t, conn, id, map[string]any{"type": "ready", "clientId": "client-a"})
			h03SendUpstream(t, conn, id, h03Approval("session-a", "event-a"))
		case "session/follow":
			h03SendUpstream(t, conn, id, map[string]any{
				"type": "snapshot", "header": map[string]any{"id": "session-a", "cwd": cwd},
				"cursor": 0, "records": []any{}, "hasMore": false,
			})
		}
		<-stop
	}
	url, authorized := harnessNativeStreamFixture(t, stub)
	cwd = authorized
	stub.mu.Lock()
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
	stub.mu.Unlock()
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "events", "$events", "")
	_ = h03Value(t, readHarnessNativeFrame(t, conn))
	if h03Value(t, readHarnessNativeFrame(t, conn))["eventId"] != "event-a" {
		t.Fatal("approval missing before any follow is opened")
	}
	h03Open(t, conn, "follow", "session/follow", "session-a")
	_ = h03Value(t, readHarnessNativeFrame(t, conn))
	sendHarnessNativeFrame(t, conn, map[string]any{"type": "cancel", "streamId": "follow"})
	if frame := readHarnessNativeFrame(t, conn); frame["type"] != harnessclient.CarrierEnd {
		t.Fatalf("cancel must end follow: %v", frame)
	}
	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "respond", "eventId": "event-a", "outcome": map[string]any{"kind": "result", "value": "rejected"},
	})
	// 应答成功必须有可关联的回执：卡片撤下要等它，而不是等帧写进 socket。
	ack := h03RespondAck(t, readHarnessNativeFrame(t, conn), "event-a")
	h03RespondOutcome(t, ack, harnessNativeRespondOutcomeAccepted)
	count := 0
	for _, method := range stub.recordedRPCs() {
		if method == "$events/result" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("expected one answer sent upstream, got %d", count)
	}
}

func TestHarnessNativeH03DuplicateInteractionIsNotOverflow(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stop := make(chan struct{})
	defer close(stop)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		id := open["streamId"].(string)
		h03SendUpstream(t, conn, id, map[string]any{"type": "ready", "clientId": "client-a"})
		h03SendUpstream(t, conn, id, h03Approval("session-a", "event-a"))
		h03SendUpstream(t, conn, id, h03Approval("session-a", "event-a"))
		h03SendUpstream(t, conn, id, h03Approval("session-a", "event-marker"))
		<-stop
	}
	url, cwd := harnessNativeStreamFixture(t, stub)
	stub.mu.Lock()
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
	stub.mu.Unlock()
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "events", "$events", "")
	_ = h03Value(t, readHarnessNativeFrame(t, conn))
	if h03Value(t, readHarnessNativeFrame(t, conn))["eventId"] != "event-a" {
		t.Fatal("first delivery missing")
	}
	if h03Value(t, readHarnessNativeFrame(t, conn))["eventId"] != "event-marker" {
		t.Fatal("redelivery created a duplicate or an overflow error")
	}
}

func TestHarnessNativeH03OnlyOneEventsBindingPerConnection(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stop := make(chan struct{})
	defer close(stop)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		h03SendUpstream(t, conn, open["streamId"].(string), map[string]any{"type": "ready", "clientId": "client-a"})
		<-stop
	}
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "events-a", "$events", "")
	_ = h03Value(t, readHarnessNativeFrame(t, conn))
	h03Open(t, conn, "events-b", "$events", "")
	if frame := readHarnessNativeFrame(t, conn); frame["type"] != harnessclient.CarrierError || frame["streamId"] != "events-b" {
		t.Fatalf("second binding must be rejected: %v", frame)
	}
	if opens, _ := stub.upstreamTouches(); opens != 1 {
		t.Fatalf("duplicate subscription reached upstream: %d", opens)
	}
	sendHarnessNativeFrame(t, conn, map[string]any{"type": "cancel", "streamId": "events-a"})
	if frame := readHarnessNativeFrame(t, conn); frame["type"] != harnessclient.CarrierEnd {
		t.Fatalf("expected logical end: %v", frame)
	}
	h03AssertTransportClosed(t, conn)
}

func TestHarnessNativeH03UnknownHostEventsAreNotForwarded(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stop := make(chan struct{})
	defer close(stop)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		id := open["streamId"].(string)
		h03SendUpstream(t, conn, id, map[string]any{"type": "ready", "clientId": "client-a"})
		h03SendUpstream(t, conn, id, map[string]any{"type": "emit", "event": "private-host-event", "args": []any{"SECRET"}})
		h03SendUpstream(t, conn, id, h03Approval("session-a", "event-marker"))
		<-stop
	}
	url, cwd := harnessNativeStreamFixture(t, stub)
	stub.mu.Lock()
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
	stub.mu.Unlock()
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "events", "$events", "")
	_ = h03Value(t, readHarnessNativeFrame(t, conn))
	if h03Value(t, readHarnessNativeFrame(t, conn))["eventId"] != "event-marker" {
		t.Fatal("unfiltered host event escaped")
	}
}

func TestHarnessNativeH03RevokedInteractionDoesNotReachUpstream(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stop := make(chan struct{})
	defer close(stop)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		id := open["streamId"].(string)
		h03SendUpstream(t, conn, id, map[string]any{"type": "ready", "clientId": "client-a"})
		h03SendUpstream(t, conn, id, h03Approval("session-a", "event-a"))
		<-stop
	}
	url, cwd := harnessNativeStreamFixture(t, stub)
	stub.mu.Lock()
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
	stub.mu.Unlock()
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "events", "$events", "")
	_ = h03Value(t, readHarnessNativeFrame(t, conn))
	if h03Value(t, readHarnessNativeFrame(t, conn))["eventId"] != "event-a" {
		t.Fatal("approval was not delivered")
	}
	// The trusted directory now places the same session outside the allowed scope.
	stub.mu.Lock()
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", t.TempDir())}
	stub.mu.Unlock()
	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "respond", "eventId": "event-a", "outcome": map[string]any{"kind": "result", "value": "allowed-once"},
	})
	// 撤权后的拒绝必须带 eventId 回传：手机靠它知道是哪张卡被拒，
	// 才能撤卡或放回重试，而不是把失败挂在一个无关的帧上。
	ack := h03RespondAck(t, readHarnessNativeFrame(t, conn), "event-a")
	// 撤权是"没转发"的明确结论，不是结果未知——移动端应放回而不是锁死。
	h03RespondOutcome(t, ack, harnessNativeRespondOutcomeRejected)
	for _, method := range stub.recordedRPCs() {
		if method == "$events/result" {
			t.Fatal("revoked answer reached upstream")
		}
	}
}

func TestHarnessNativeH03IncompleteSnapshotIdentityIsRejected(t *testing.T) {
	for _, missing := range []string{"id", "cwd"} {
		t.Run(missing, func(t *testing.T) {
			stub := newHarnessNativeStreamStub(t)
			stop := make(chan struct{})
			defer close(stop)
			var cwd string
			stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
				header := map[string]any{"id": "session-a", "cwd": cwd}
				delete(header, missing)
				h03SendUpstream(t, conn, open["streamId"].(string), map[string]any{
					"type": "snapshot", "header": header, "records": []any{}, "cursor": 0,
				})
				<-stop
			}
			url, authorized := harnessNativeStreamFixture(t, stub)
			cwd = authorized
			stub.mu.Lock()
			stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
			stub.mu.Unlock()
			conn := dialHarnessNativeStream(t, url)
			h03Open(t, conn, "follow", "session/follow", "session-a")
			frame := readHarnessNativeFrame(t, conn)
			if frame["type"] != harnessclient.CarrierError || frame["streamId"] != "follow" {
				t.Fatalf("incomplete snapshot escaped: %v", frame)
			}
		})
	}
}

func TestHarnessNativeH03FinishedFollowKeepsPending(t *testing.T) {
	r := newHarnessNativeInteractionRegistry()
	r.deliver(h03Interaction("e1"))
	stream := &harnessNativeWSStream{streamID: "f1", endpoint: harnessclient.MethodSessionFollow, sessionID: "session-a"}
	c := &harnessNativeStreamConn{
		streams: map[string]*harnessNativeWSStream{"f1": stream}, registry: r,
	}
	c.finishStream(stream)
	if _, result, err := r.claim("e1", 1); err != nil || result != harnessNativeClaimAccepted {
		t.Fatalf("finishing observation withdrew an authorized interaction: %v / %v", result, err)
	}
}

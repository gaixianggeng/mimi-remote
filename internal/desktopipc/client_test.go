package desktopipc

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"testing"
	"time"
)

type fakeDesktopIPC struct {
	mu        sync.Mutex
	listeners []net.Conn
	requests  []envelope
	respond   func(net.Conn, envelope)
}

func (f *fakeDesktopIPC) dial(context.Context, string, string) (net.Conn, error) {
	client, server := net.Pipe()
	f.mu.Lock()
	f.listeners = append(f.listeners, server)
	f.mu.Unlock()
	go f.serve(server)
	return client, nil
}

func (f *fakeDesktopIPC) serve(conn net.Conn) {
	defer conn.Close()
	for {
		payload, err := ReadFrame(conn)
		if err != nil {
			return
		}
		var request envelope
		if json.Unmarshal(payload, &request) != nil {
			return
		}
		f.mu.Lock()
		f.requests = append(f.requests, request)
		f.mu.Unlock()
		if request.Method == "initialize" {
			writeTestEnvelope(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{"clientId": "desktop-test-client"},
			})
			continue
		}
		if f.respond != nil {
			f.respond(conn, request)
		}
	}
}

func writeTestEnvelope(conn net.Conn, value any) {
	payload, _ := json.Marshal(value)
	_ = WriteFrame(conn, payload)
}

func newStartedTestClient(t *testing.T, fake *fakeDesktopIPC, timeout time.Duration) *Client {
	t.Helper()
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: func(net.Conn) error { return nil },
		RequestTimeout: timeout, ReconnectDelay: 10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	client.Start(ctx)
	t.Cleanup(func() { cancel(); client.Close() })
	readyCtx, readyCancel := context.WithTimeout(context.Background(), time.Second)
	defer readyCancel()
	if err := client.WaitReady(readyCtx); err != nil {
		t.Fatal(err)
	}
	return client
}

func TestClientCorrelatesResponses(t *testing.T) {
	fake := &fakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request envelope) {
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID),
			"resultType": "success", "result": map[string]any{"method": request.Method},
		})
	}
	client := newStartedTestClient(t, fake, time.Second)

	result, err := client.Request(context.Background(), "thread-follower-start-turn", map[string]any{"conversationId": "thread-1"})
	if err != nil {
		t.Fatal(err)
	}
	if string(result) != `{"method":"thread-follower-start-turn"}` {
		t.Fatalf("unexpected result: %s", result)
	}
}

func TestClientFindsOwnerWithOfficialDiscoveryMethod(t *testing.T) {
	fake := &fakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request envelope) {
		if request.Method != "thread-owner-discovery" {
			return
		}
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID),
			"resultType": "success", "result": map[string]any{}, "handledByClientId": "desktop-owner",
		})
	}
	client := newStartedTestClient(t, fake, time.Second)
	ownerClientID, err := client.FindHandler(context.Background(), "thread-owner-discovery", map[string]any{
		"hostId": "local", "conversationId": "thread-1",
	})
	if err != nil || ownerClientID != "desktop-owner" {
		t.Fatalf("unexpected discovery result: owner=%q err=%v", ownerClientID, err)
	}
	fake.mu.Lock()
	requests := append([]envelope(nil), fake.requests...)
	fake.mu.Unlock()
	for _, request := range requests {
		if request.Type == "request" && request.Method == "thread-owner-discovery" {
			return
		}
	}
	t.Fatal("official owner discovery request was not sent")
}

func TestClientTargetsDiscoveredOwner(t *testing.T) {
	fake := &fakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request envelope) {
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID),
			"resultType": "success", "result": map[string]any{},
		})
	}
	client := newStartedTestClient(t, fake, time.Second)
	if _, err := client.RequestTo(context.Background(), "desktop-owner", "thread-follower-start-turn", map[string]any{}); err != nil {
		t.Fatal(err)
	}
	fake.mu.Lock()
	requests := append([]envelope(nil), fake.requests...)
	fake.mu.Unlock()
	for _, request := range requests {
		if request.Method == "thread-follower-start-turn" && request.TargetClientID == "desktop-owner" {
			return
		}
	}
	t.Fatal("follower request was not pinned to the discovered owner")
}

func TestSupportedMethodVersionsMatchDesktop7119(t *testing.T) {
	for method, expected := range map[string]int{
		"thread-stream-state-changed":            11,
		"thread-owner-discovery":                 1,
		"thread-follower-start-turn":             2,
		"thread-follower-interrupt-turn":         4,
		"thread-follower-update-thread-settings": 1,
	} {
		version, ok := MethodVersion(method)
		if !ok || version != expected {
			t.Fatalf("%s version=%d ok=%t, want %d", method, version, ok, expected)
		}
	}
	for _, unsupported := range []string{"thread-follower-set-model-and-reasoning", "thread-follower-set-collaboration-mode"} {
		if _, ok := MethodVersion(unsupported); ok {
			t.Fatalf("unsupported Desktop 7119 method is still registered: %s", unsupported)
		}
	}
}

func TestClientOnlyNoClientFoundAllowsFallback(t *testing.T) {
	fake := &fakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request envelope) {
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID),
			"resultType": "error", "error": "no-client-found: owner unavailable",
		})
	}
	client := newStartedTestClient(t, fake, time.Second)
	_, err := client.Request(context.Background(), "thread-follower-start-turn", nil)
	if !SafeToFallback(err) {
		t.Fatalf("no-client-found must allow fallback: %v", err)
	}

	fake.respond = func(net.Conn, envelope) {}
	_, err = client.Request(context.Background(), "thread-follower-start-turn", nil)
	if SafeToFallback(err) {
		t.Fatalf("timeout delivery is uncertain and must not allow fallback: %v", err)
	}
	var requestErr *RequestError
	if !errors.As(err, &requestErr) || requestErr.Delivery != DeliveryUncertain {
		t.Fatalf("unexpected timeout error: %v", err)
	}
}

func TestNoClientFoundClassifierRejectsOtherRemoteFailures(t *testing.T) {
	for _, value := range []string{
		"no-client-found",
		"No Codex IPC client can handle thread-follower-load-complete-history.",
	} {
		if !isNoClientFound(value) {
			t.Fatalf("explicit no-client result was not recognized: %q", value)
		}
	}
	for _, value := range []string{"target disconnected", "request timed out", "permission denied"} {
		if isNoClientFound(value) {
			t.Fatalf("uncertain failure must not allow fallback: %q", value)
		}
	}
}

func TestClientKeepsIdleConnectionAfterInitializeTimeout(t *testing.T) {
	fake := &fakeDesktopIPC{}
	client := newStartedTestClient(t, fake, 20*time.Millisecond)
	time.Sleep(80 * time.Millisecond)
	if status := client.Status(); status.State != StateReady {
		t.Fatalf("idle initialized connection changed state: %#v", status)
	}
	fake.mu.Lock()
	connections := len(fake.listeners)
	fake.mu.Unlock()
	if connections != 1 {
		t.Fatalf("idle connection unexpectedly reconnected %d times", connections)
	}
}

func TestClientRejectsUnknownBuildBeforeDial(t *testing.T) {
	dialed := false
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: "9999",
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			dialed = true
			return nil, errors.New("unexpected")
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	client.Start(context.Background())
	client.Close()
	if dialed {
		t.Fatal("unknown build must be rejected before connecting")
	}
	if client.Status().State != StateUnsupportedBuild {
		t.Fatalf("unexpected state: %s", client.Status().State)
	}
}

func TestClientHandlesNestedDiscoveryAndFollowerRequest(t *testing.T) {
	fake := &fakeDesktopIPC{}
	handled := make(chan IncomingRequest, 1)
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: func(net.Conn) error { return nil },
		RequestTimeout: time.Second, ReconnectDelay: time.Second,
		CanHandle: func(request IncomingRequest) bool {
			return request.Method == "thread-follower-start-turn"
		},
		HandleRequest: func(_ context.Context, request IncomingRequest) (any, error) {
			handled <- request
			return map[string]any{"ok": true}, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	client.Start(ctx)
	t.Cleanup(func() { cancel(); client.Close() })
	readyCtx, readyCancel := context.WithTimeout(context.Background(), time.Second)
	defer readyCancel()
	if err := client.WaitReady(readyCtx); err != nil {
		t.Fatal(err)
	}
	fake.mu.Lock()
	server := fake.listeners[0]
	fake.mu.Unlock()
	writeTestEnvelope(server, map[string]any{
		"type": "client-discovery-request", "requestId": "discovery-1",
		"request": map[string]any{
			"type": "request", "requestId": "inner-1", "method": "thread-follower-start-turn", "version": 2,
			"params": map[string]any{"conversationId": "thread-1"},
		},
	})
	writeTestEnvelope(server, map[string]any{
		"type": "request", "requestId": "request-1", "sourceClientId": "desktop",
		"method": "thread-follower-start-turn", "version": 2,
		"params": map[string]any{"conversationId": "thread-1"},
	})
	select {
	case request := <-handled:
		if request.Method != "thread-follower-start-turn" {
			t.Fatalf("unexpected request: %+v", request)
		}
	case <-time.After(time.Second):
		t.Fatal("follower request was not handled")
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		fake.mu.Lock()
		requests := append([]envelope(nil), fake.requests...)
		fake.mu.Unlock()
		var discovered, responded bool
		for _, response := range requests {
			if response.Type == "client-discovery-response" && rawMessageKey(response.RequestID) == "discovery-1" {
				var value struct {
					CanHandle bool `json:"canHandle"`
				}
				_ = json.Unmarshal(response.Response, &value)
				discovered = value.CanHandle
			}
			if response.Type == "response" && rawMessageKey(response.RequestID) == "request-1" && response.ResultType == "success" {
				responded = true
			}
		}
		if discovered && responded {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("client did not return discovery and follower responses")
}

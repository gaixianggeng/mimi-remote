package desktopipc

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeDesktopIPC struct {
	mu        sync.Mutex
	listeners []net.Conn
	requests  []envelope
	respond   func(net.Conn, envelope)
}

func supportedTestPeer(net.Conn) (DesktopInfo, error) {
	return DesktopInfo{Version: SupportedVersion, Build: SupportedBuild}, nil
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
		DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
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

func TestClientCancelsIncomingFollowerHandlerOnDisconnect(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	handlerStarted := make(chan struct{})
	handlerCanceled := make(chan struct{})
	client, err := NewClient(ClientOptions{
		RequestTimeout: time.Second,
		CanHandle:      func(IncomingRequest) bool { return true },
		HandleRequest: func(ctx context.Context, _ IncomingRequest) (any, error) {
			close(handlerStarted)
			<-ctx.Done()
			close(handlerCanceled)
			return nil, ctx.Err()
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	connectionCtx, connectionCancel := context.WithCancel(context.Background())
	client.mu.Lock()
	client.conn = clientConn
	client.clientID = "mimi-client"
	client.generation = 7
	client.connectionCtx = connectionCtx
	client.connectionCancel = connectionCancel
	client.mu.Unlock()
	go client.handleIncomingRequest(clientConn, envelope{
		Type: "request", RequestID: json.RawMessage(`"incoming"`), Method: "thread-follower-start-turn",
		Version: 2, SourceClientID: "desktop-owner", Params: json.RawMessage(`{"conversationId":"thread-1"}`),
	})
	select {
	case <-handlerStarted:
	case <-time.After(time.Second):
		t.Fatal("incoming follower handler did not start")
	}
	client.disconnect(errors.New("test disconnect"))
	select {
	case <-handlerCanceled:
	case <-time.After(time.Second):
		t.Fatal("disconnect did not cancel the old generation follower handler")
	}
	_ = serverConn.Close()
}

func TestClientWriteDeadlineClosesConnectionAndInvalidatesGeneration(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client := &Client{
		opts:    ClientOptions{RequestTimeout: 20 * time.Millisecond},
		pending: make(map[string]pendingResponse),
	}
	client.mu.Lock()
	client.conn = clientConn
	client.clientID = "mimi-client"
	client.generation = 7
	client.mu.Unlock()

	startedAt := time.Now()
	err := client.write(clientConn, []byte(`{"type":"broadcast"}`))
	elapsed := time.Since(startedAt)
	if err == nil {
		t.Fatal("blocked write unexpectedly succeeded")
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("blocked write exceeded its deadline: %s", elapsed)
	}
	if generation := client.ConnectionGeneration(); generation != 0 {
		t.Fatalf("failed write kept the current generation: %d", generation)
	}
	if _, err := clientConn.Write([]byte("after-close")); err == nil {
		t.Fatal("failed write did not close the connection")
	}
}

func TestClientStaleWriteFailureDoesNotCloseNewGeneration(t *testing.T) {
	oldConn, oldPeer := net.Pipe()
	newConn, newPeer := net.Pipe()
	t.Cleanup(func() {
		_ = oldPeer.Close()
		_ = newConn.Close()
		_ = newPeer.Close()
	})
	client := &Client{pending: make(map[string]pendingResponse)}
	client.mu.Lock()
	client.conn = newConn
	client.clientID = "new-client"
	client.generation = 8
	client.mu.Unlock()

	client.disconnectConn(oldConn, errors.New("stale write failed"))
	if generation := client.ConnectionGeneration(); generation != 8 {
		t.Fatalf("stale write failure invalidated the new generation: %d", generation)
	}
	client.mu.RLock()
	current := client.conn
	client.mu.RUnlock()
	if current != newConn {
		t.Fatal("stale write failure replaced or closed the new connection")
	}
	if _, err := oldConn.Write([]byte("closed")); err == nil {
		t.Fatal("stale connection was not closed")
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
			"resultType": "success", "result": map[string]any{}, "handledByClientId": "desktop-owner",
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

func TestClientRejectsResponseFromWrongLogicalHandler(t *testing.T) {
	fake := &fakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request envelope) {
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID),
			"resultType": "success", "result": map[string]any{}, "handledByClientId": "other-client",
		})
	}
	client := newStartedTestClient(t, fake, time.Second)
	_, err := client.RequestTo(context.Background(), "desktop-owner", "thread-follower-start-turn", map[string]any{})
	var requestErr *RequestError
	if !errors.As(err, &requestErr) || requestErr.Delivery != DeliveryUncertain {
		t.Fatalf("wrong logical handler must fail closed: %v", err)
	}
}

func TestSupportedMethodVersionsMatchVerifiedDesktopProfiles(t *testing.T) {
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
			t.Fatalf("unsupported verified Desktop method is still registered: %s", unsupported)
		}
	}
}

func TestVerifiedDesktopProfilesRemainBuildScoped(t *testing.T) {
	for _, profile := range []struct {
		version string
		build   string
		want    string
	}{
		{version: SupportedVersion, build: SupportedBuild, want: SupportedProfile},
		{version: desktopVersion7287, build: desktopBuild7287, want: desktopProfile7287},
	} {
		got, ok := verifiedDesktopProfile(profile.version, profile.build)
		if !ok || got != profile.want {
			t.Fatalf("verified profile %s (%s) resolved to %q ok=%t", profile.version, profile.build, got, ok)
		}
	}
	for _, unknown := range [][2]string{
		{SupportedVersion, desktopBuild7287},
		{desktopVersion7287, SupportedBuild},
		{desktopVersion7287, "future-build"},
	} {
		if profile, ok := verifiedDesktopProfile(unknown[0], unknown[1]); ok || profile != "" {
			t.Fatalf("unknown Desktop build escaped the exact gate: %v profile=%q", unknown, profile)
		}
	}
}

func TestClientOnlyNoClientFoundAllowsFallback(t *testing.T) {
	fake := &fakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request envelope) {
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID),
			"resultType": "error", "error": "no-client-found",
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
		if !isNoClientFound(value, "thread-follower-load-complete-history") {
			t.Fatalf("explicit no-client result was not recognized: %q", value)
		}
	}
	for _, value := range []string{
		"target disconnected", "request timed out", "permission denied",
		"no-client-found: owner unavailable", "operation failed because no-client-found was not returned",
	} {
		if isNoClientFound(value, "thread-follower-load-complete-history") {
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

func TestClientRejectsUnknownConnectedPeerBuildBeforeInitialize(t *testing.T) {
	fake := &fakeDesktopIPC{}
	dialed := false
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			dialed = true
			return fake.dial(context.Background(), "unix", "test")
		},
		VerifySocket: func(string) error { return nil },
		VerifyPeer: func(net.Conn) (DesktopInfo, error) {
			return DesktopInfo{Version: SupportedVersion, Build: "9999"}, nil
		},
		ReconnectDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	client.Start(ctx)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && client.Status().State != StateUnsupportedBuild {
		time.Sleep(time.Millisecond)
	}
	cancel()
	client.Close()
	if !dialed {
		t.Fatal("peer build gate must inspect the connected socket owner")
	}
	if client.Status().State != StateUnsupportedBuild {
		t.Fatalf("unexpected state: %s", client.Status().State)
	}
}

func TestClientDoesNotDialWhileDesktopIsNotRunning(t *testing.T) {
	var dials atomic.Int64
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		Preflight: func() (State, error) { return StateDesktopNotRunning, nil },
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			dials.Add(1)
			return nil, errors.New("unexpected dial")
		},
		VerifySocket:   func(string) error { return nil },
		ReconnectDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	client.Start(ctx)
	time.Sleep(20 * time.Millisecond)
	cancel()
	client.Close()
	if status := client.Status(); status.State != StateDesktopNotRunning {
		t.Fatalf("unexpected inactive Desktop state: %#v", status)
	}
	if dials.Load() != 0 {
		t.Fatalf("Desktop IPC dialed while Desktop was closed: %d", dials.Load())
	}
}

func TestClientRechecksPeerBuildOnReconnect(t *testing.T) {
	fake := &fakeDesktopIPC{}
	var inspections atomic.Int64
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		DialContext: fake.dial, VerifySocket: func(string) error { return nil },
		VerifyPeer: func(net.Conn) (DesktopInfo, error) {
			if inspections.Add(1) == 1 {
				return DesktopInfo{Version: SupportedVersion, Build: SupportedBuild}, nil
			}
			return DesktopInfo{Version: SupportedVersion, Build: "future-build"}, nil
		},
		RequestTimeout: time.Second, ReconnectDelay: time.Millisecond,
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
	_ = server.Close()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && client.Status().State != StateUnsupportedBuild {
		time.Sleep(time.Millisecond)
	}
	if status := client.Status(); status.State != StateUnsupportedBuild || status.DesktopBuild != "future-build" {
		t.Fatalf("reconnected peer bypassed the build gate: %#v", status)
	}
}

func TestClientGenerationBoundCallsRejectStaleGenerationWithoutSending(t *testing.T) {
	fake := &fakeDesktopIPC{}
	client := newStartedTestClient(t, fake, time.Second)
	oldGeneration := client.ConnectionGeneration()
	if oldGeneration == 0 {
		t.Fatal("initial connection generation is unavailable")
	}
	fake.mu.Lock()
	if len(fake.listeners) != 1 {
		fake.mu.Unlock()
		t.Fatalf("unexpected initial connection count: %d", len(fake.listeners))
	}
	oldServer := fake.listeners[0]
	fake.mu.Unlock()
	if err := oldServer.Close(); err != nil {
		t.Fatalf("close old test connection: %v", err)
	}

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		fake.mu.Lock()
		connectionCount := len(fake.listeners)
		fake.mu.Unlock()
		if connectionCount >= 2 && client.Status().State == StateReady && client.ConnectionGeneration() > oldGeneration {
			break
		}
		time.Sleep(time.Millisecond)
	}
	newGeneration := client.ConnectionGeneration()
	if newGeneration <= oldGeneration {
		t.Fatalf("client did not advance connection generation: old=%d new=%d", oldGeneration, newGeneration)
	}

	fake.mu.Lock()
	requestsBefore := len(fake.requests)
	fake.mu.Unlock()
	assertNotSent := func(label string, err error) {
		t.Helper()
		var requestErr *RequestError
		if !errors.As(err, &requestErr) || requestErr.Delivery != DeliveryNotSent {
			t.Fatalf("%s must be rejected as not sent: %v", label, err)
		}
	}

	_, err := client.RequestToGeneration(context.Background(), "desktop-owner", "thread-follower-start-turn", nil, oldGeneration)
	assertNotSent("RequestToGeneration", err)
	_, err = client.FindHandlerGeneration(context.Background(), "thread-owner-discovery", nil, oldGeneration)
	assertNotSent("FindHandlerGeneration", err)
	err = client.BroadcastGeneration("thread-stream-following-changed", nil, oldGeneration)
	assertNotSent("BroadcastGeneration", err)

	fake.mu.Lock()
	requestsAfter := append([]envelope(nil), fake.requests...)
	fake.mu.Unlock()
	if len(requestsAfter) != requestsBefore {
		t.Fatalf("stale generation calls wrote %d envelope(s) to the replacement connection", len(requestsAfter)-requestsBefore)
	}
}

func TestClientHandlesNestedDiscoveryAndFollowerRequest(t *testing.T) {
	fake := &fakeDesktopIPC{}
	handled := make(chan IncomingRequest, 1)
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
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

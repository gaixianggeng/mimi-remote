package httpapi

import (
	"context"
	"encoding/json"
	"net"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/desktopipc"
)

type gatewayFakeIPCEnvelope struct {
	Type      string                  `json:"type"`
	RequestID json.RawMessage         `json:"requestId"`
	Method    string                  `json:"method"`
	Params    json.RawMessage         `json:"params"`
	Request   *gatewayFakeIPCEnvelope `json:"request"`
}

type gatewayFakeDesktopIPC struct {
	mu      sync.Mutex
	writes  sync.Mutex
	methods []string
	respond func(net.Conn, gatewayFakeIPCEnvelope)
}

func (f *gatewayFakeDesktopIPC) dial(context.Context, string, string) (net.Conn, error) {
	client, server := net.Pipe()
	go f.serve(server)
	return client, nil
}

func (f *gatewayFakeDesktopIPC) serve(conn net.Conn) {
	defer conn.Close()
	for {
		payload, err := desktopipc.ReadFrame(conn)
		if err != nil {
			return
		}
		var request gatewayFakeIPCEnvelope
		if json.Unmarshal(payload, &request) != nil {
			return
		}
		method := request.Method
		if request.Type == "client-discovery-request" && request.Request != nil {
			method = "discover:" + request.Request.Method
		}
		f.mu.Lock()
		f.methods = append(f.methods, method)
		f.mu.Unlock()
		if request.Method == "initialize" {
			f.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{"clientId": "desktop-test"},
			})
			continue
		}
		if f.respond != nil {
			f.respond(conn, request)
		}
	}
}

func (f *gatewayFakeDesktopIPC) write(conn net.Conn, value any) {
	payload, _ := json.Marshal(value)
	f.writes.Lock()
	_ = desktopipc.WriteFrame(conn, payload)
	f.writes.Unlock()
}

func (f *gatewayFakeDesktopIPC) methodCount(method string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	count := 0
	for _, current := range f.methods {
		if current == method {
			count++
		}
	}
	return count
}

func newReadyGatewayBridge(t *testing.T, fake *gatewayFakeDesktopIPC, requestTimeout time.Duration) *desktopipc.Bridge {
	t.Helper()
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: desktopipc.SupportedVersion, DesktopBuild: desktopipc.SupportedBuild,
		ClientOptions: desktopipc.ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: func(net.Conn) error { return nil },
			RequestTimeout: requestTimeout, ReconnectDelay: time.Second,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	bridge.Start(ctx)
	t.Cleanup(func() { cancel(); bridge.Close() })
	deadline := time.Now().Add(time.Second)
	for bridge.Status().State != desktopipc.StateReady && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if bridge.Status().State != desktopipc.StateReady {
		t.Fatalf("bridge did not become ready: %+v", bridge.Status())
	}
	return bridge
}

func TestDesktopIPCOverlayRoutesDesktopOwnedTurnWithoutAppServerFallback(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		switch request.Method {
		case "thread-stream-following-changed":
			fake.write(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{
					"conversationId": "thread-desktop",
					"change": map[string]any{"type": "snapshot", "revision": 1, "conversationState": map[string]any{
						"title": "Desktop", "cwd": "/tmp", "turns": []any{},
					}},
				},
			})
		case "thread-owner-discovery":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
		case "thread-follower-load-complete-history":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{"revision": 1},
			})
		case "thread-follower-update-thread-settings":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success", "result": map[string]any{},
			})
		case "thread-follower-start-turn":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{"result": map[string]any{"turn": map[string]any{"id": "turn-desktop"}}},
			})
		}
	}
	bridge := newReadyGatewayBridge(t, fake, time.Second)
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":7,"method":"turn/start","params":{"threadId":"thread-desktop","model":"gpt-5.6-sol","input":[]}
	}`))
	if policyErr != nil || !handled {
		t.Fatalf("Desktop-owned turn was not routed: handled=%v err=%+v", handled, policyErr)
	}
	var decoded map[string]any
	if json.Unmarshal(response, &decoded) != nil {
		t.Fatalf("invalid response: %s", response)
	}
	result, _ := decoded["result"].(map[string]any)
	turn, _ := result["turn"].(map[string]any)
	if turn["id"] != "turn-desktop" {
		t.Fatalf("unexpected follower result: %s", response)
	}
	for _, method := range []string{
		"thread-stream-following-changed", "thread-follower-load-complete-history",
		"thread-follower-update-thread-settings", "thread-follower-start-turn",
	} {
		if fake.methodCount(method) != 1 {
			t.Fatalf("expected one %s request, methods=%v", method, fake.methods)
		}
	}
}

func TestDesktopIPCOverlayTimeoutNeverFallsBackToAppServer(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		switch request.Method {
		case "thread-stream-following-changed":
			fake.write(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{"conversationId": "thread-timeout", "change": map[string]any{
					"type": "snapshot", "revision": 1, "conversationState": map[string]any{"turns": []any{}},
				}},
			})
		case "thread-owner-discovery":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
		case "thread-follower-load-complete-history":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{"revision": 1},
			})
		}
	}
	bridge := newReadyGatewayBridge(t, fake, 50*time.Millisecond)
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":8,"method":"turn/start","params":{"threadId":"thread-timeout","input":[]}
	}`))
	if !handled || len(response) != 0 || policyErr == nil {
		t.Fatalf("timeout must be a handled uncertain error: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
	if policyErr.data["reason"] != "desktop_sync_delivery_uncertain" || policyErr.data["accepted"] != nil {
		t.Fatalf("unexpected delivery metadata: %#v", policyErr.data)
	}
}

func TestDesktopIPCOverlayOnlyExplicitNoClientAllowsFallback(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		if request.Method == "thread-owner-discovery" {
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "error", "error": "no-client-found",
			})
		}
	}
	bridge := newReadyGatewayBridge(t, fake, time.Second)
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":9,"method":"turn/start","params":{"threadId":"thread-local","input":[]}
	}`))
	if handled || len(response) != 0 || policyErr != nil {
		t.Fatalf("no-client-found must be the only local fallback: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
	if !bridge.LocalOwnerIs("thread-local", overlay.ownerID) {
		t.Fatal("fallback writer must be atomically reserved for this gateway")
	}
}

func TestDesktopIPCOverlayKeepsUnknownOwnershipReadOnlyWhileConnecting(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: desktopipc.SupportedVersion, DesktopBuild: desktopipc.SupportedBuild,
	})
	if err != nil {
		t.Fatal(err)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":10,"method":"turn/start","params":{"threadId":"thread-unknown","input":[]}
	}`))
	if !handled || len(response) != 0 || policyErr == nil {
		t.Fatalf("unknown ownership write must be rejected: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
	if policyErr.data["reason"] != "desktop_sync_owner_unknown" || policyErr.data["accepted"] != false {
		t.Fatalf("unexpected owner metadata: %#v", policyErr.data)
	}
}

func TestDesktopIPCOverlayIsInactiveForUnsupportedBuild(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: desktopipc.SupportedVersion, DesktopBuild: "future-build",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	bridge.Start(ctx)
	t.Cleanup(func() { cancel(); bridge.Close() })
	deadline := time.Now().Add(time.Second)
	for bridge.Status().State != desktopipc.StateUnsupportedBuild && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":11,"method":"turn/start","params":{"threadId":"thread-stable","input":[]}
	}`))
	if handled || len(response) != 0 || policyErr != nil {
		t.Fatalf("unsupported build must leave stable App Server path untouched: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
}

func TestDesktopIPCMimiOwnerRoutesDesktopFollowerTurnToOneAppServerWriter(t *testing.T) {
	var projectDir string
	var turnStarts atomic.Int64
	turnParams := make(chan map[string]any, 1)
	upstreamURL, _, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var frame appServerGatewayFrame
		if json.Unmarshal(payload, &frame) != nil || frame.ID == nil {
			return
		}
		params, _ := decodeGatewayParams(frame.Params)
		var result any
		switch frame.Method {
		case "thread/list":
			result = map[string]any{"data": []any{map[string]any{"id": "thread-local", "cwd": projectDir}}}
		case "thread/resume":
			result = map[string]any{"thread": map[string]any{"id": "thread-local", "cwd": projectDir, "turns": []any{}}}
		case "turn/start":
			turnStarts.Add(1)
			turnParams <- params
			result = map[string]any{"turn": map[string]any{"id": "turn-local"}}
		default:
			return
		}
		response, _ := json.Marshal(map[string]any{"id": rawGatewayID(frame.ID), "result": result})
		_ = conn.WriteMessage(websocket.TextMessage, response)
		if frame.Method == "turn/start" {
			notification, _ := json.Marshal(map[string]any{
				"method": "turn/started", "params": map[string]any{
					"threadId": "thread-local", "turn": map[string]any{"id": "turn-local"},
				},
			})
			_ = conn.WriteMessage(websocket.TextMessage, notification)
		}
	})
	handler, router, fixtureProjectDir := buildAppServerGatewayFixture(t, upstreamURL, nil)
	projectDir = fixtureProjectDir
	router.desktopIPC.Close()

	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		if request.Method == "thread-owner-discovery" {
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "error", "error": "no-client-found",
			})
		}
	}
	bridge := newReadyGatewayBridge(t, fake, time.Second)
	router.desktopIPC = bridge
	router.cfg.Codex.DesktopSyncEnabled = true

	server := httptest.NewServer(handler)
	defer server.Close()
	client := dialAuthedGateway(t, server.URL)
	defer client.Close()
	if err := client.WriteMessage(websocket.TextMessage, []byte(`{"id":1,"method":"thread/list","params":{"cwd":`+mustJSONTestString(projectDir)+`}}`)); err != nil {
		t.Fatal(err)
	}
	_ = readGatewayRaw(t, client)
	resume := map[string]any{
		"id": 2, "method": "thread/resume", "params": map[string]any{
			"threadId": "thread-local", "cwd": projectDir, "sandbox": "workspace-write", "approvalPolicy": "on-request",
		},
	}
	resumePayload, _ := json.Marshal(resume)
	if err := client.WriteMessage(websocket.TextMessage, resumePayload); err != nil {
		t.Fatal(err)
	}
	_ = readGatewayRaw(t, client)
	if !bridge.HasLocalOwner("thread-local") {
		t.Fatal("explicit no-client-found must assign the App Server gateway as the sole writer")
	}

	result, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
		"turnStart": map[string]any{
			"request": map[string]any{
				"cwd": projectDir, "input": []any{map[string]any{"type": "text", "text": "from Desktop"}},
				"sandboxPolicy":  map[string]any{"type": "workspaceWrite", "writableRoots": []any{projectDir}, "networkAccess": false},
				"approvalPolicy": "on-request",
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result == nil || turnStarts.Load() != 1 || fake.methodCount("thread-follower-start-turn") != 0 {
		t.Fatalf("turn must enter exactly one App Server writer: result=%#v appServer=%d desktop=%d", result, turnStarts.Load(), fake.methodCount("thread-follower-start-turn"))
	}
	select {
	case params := <-turnParams:
		if params["approvalPolicy"] != "on-request" || params["cwd"] != projectDir {
			t.Fatalf("Desktop follower request did not pass Gateway policy: %#v", params)
		}
	default:
		t.Fatal("App Server did not receive the follower turn")
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		projection, ok := bridge.LocalProjection("thread-local")
		if ok && len(projection.Turns) == 1 {
			turn := projection.Turns[0].(map[string]any)
			items, _ := turn["items"].([]any)
			if len(items) == 0 {
				t.Fatalf("Desktop prompt was not projected: %#v", turn)
			}
			content, _ := items[0].(map[string]any)["content"].([]any)
			if len(content) != 1 || content[0].(map[string]any)["text"] != "from Desktop" {
				t.Fatalf("Desktop prompt was not attached to the canonical App Server turn: %#v", turn)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("turn/started was not projected to Desktop state")
}

func TestDesktopFollowerPermissionDecisionRestoresRequestedGrant(t *testing.T) {
	pending := desktopIPCServerRequest{
		method: "item/permissions/requestApproval",
		params: map[string]any{"permissions": map[string]any{"network": map[string]any{"enabled": true}}},
	}
	accepted := desktopFollowerServerResponse(pending, map[string]any{"decision": "acceptForSession"})
	permissions, _ := accepted["permissions"].(map[string]any)
	if accepted["scope"] != "session" || permissions["network"] == nil {
		t.Fatalf("permission acceptance did not restore the requested grant: %#v", accepted)
	}
	declined := desktopFollowerServerResponse(pending, map[string]any{"decision": "decline"})
	declinedPermissions, _ := declined["permissions"].(map[string]any)
	if declined["scope"] != "turn" || len(declinedPermissions) != 0 {
		t.Fatalf("permission decline must return an empty turn grant: %#v", declined)
	}
}

func mustJSONTestString(value string) string {
	payload, _ := json.Marshal(value)
	return string(payload)
}

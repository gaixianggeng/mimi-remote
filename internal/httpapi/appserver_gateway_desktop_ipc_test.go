package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/desktopipc"
)

type gatewayFakeIPCEnvelope struct {
	Type           string                  `json:"type"`
	RequestID      json.RawMessage         `json:"requestId"`
	Method         string                  `json:"method"`
	Version        int                     `json:"version"`
	SourceClientID string                  `json:"sourceClientId"`
	Params         json.RawMessage         `json:"params"`
	Request        *gatewayFakeIPCEnvelope `json:"request"`
	ResultType     string                  `json:"resultType"`
	Result         json.RawMessage         `json:"result"`
	Error          string                  `json:"error"`
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
	return newReadyGatewayBridgeWithActivator(t, fake, requestTimeout, nil)
}

func newReadyGatewayBridgeWithActivator(
	t *testing.T,
	fake *gatewayFakeDesktopIPC,
	requestTimeout time.Duration,
	activator desktopipc.DesktopThreadActivator,
) *desktopipc.Bridge {
	t.Helper()
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: desktopipc.SupportedVersion, DesktopBuild: desktopipc.SupportedBuild,
		ActivateDesktopThread: activator,
		ClientOptions: desktopipc.ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: func(net.Conn) (desktopipc.DesktopInfo, error) {
				return desktopipc.DesktopInfo{Version: desktopipc.SupportedVersion, Build: desktopipc.SupportedBuild}, nil
			},
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
	steerParams := make(chan map[string]any, 1)
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		switch request.Method {
		case "thread-owner-discovery":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
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
		case "thread-follower-load-complete-history":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{"revision": 1}, "handledByClientId": "desktop-owner",
			})
		case "thread-follower-update-thread-settings":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success", "result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
		case "thread-follower-start-turn":
			fake.write(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{
					"conversationId": "thread-desktop",
					"change": map[string]any{"type": "snapshot", "revision": 2, "conversationState": map[string]any{
						"title": "Desktop", "cwd": "/tmp", "turns": []any{map[string]any{
							"id": "turn-desktop", "status": "inProgress", "items": []any{},
						}},
					}},
				},
			})
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"handledByClientId": "desktop-owner",
				"result":            map[string]any{"result": map[string]any{"turn": map[string]any{"id": "turn-desktop"}}},
			})
		case "thread-follower-steer-turn":
			var params map[string]any
			_ = json.Unmarshal(request.Params, &params)
			steerParams <- params
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
		}
	}
	bridge := newReadyGatewayBridge(t, fake, time.Second)
	policy := &appServerGatewayPolicy{allowedThreads: map[string]appServerGatewayAllowedThread{
		"thread-desktop": {id: "thread-desktop", cwd: "/tmp", scopeID: "demo"},
	}}
	overlay := newDesktopIPCGatewayOverlay(bridge, policy, nil, nil)
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
	handled, _, policyErr = overlay.routeClientFrame(context.Background(), []byte(`{
		"id":8,"method":"turn/steer","params":{"threadId":"thread-desktop","expectedTurnId":"turn-desktop","clientUserMessageId":"client-steer","input":[{"type":"text","text":"调整方向"}],"attachments":[],"additionalContext":{"source":"ipad"}}
	}`))
	if policyErr != nil || !handled {
		t.Fatalf("Desktop-owned steer was not routed: handled=%v err=%+v", handled, policyErr)
	}
	select {
	case params := <-steerParams:
		if params["conversationId"] != "thread-desktop" || params["input"] == nil ||
			params["clientUserMessageId"] != "client-steer" {
			t.Fatalf("Desktop-owned steer fields were lost: %#v", params)
		}
		if _, exists := params["expectedTurnId"]; exists {
			t.Fatalf("verified Desktop follower Steer must not receive unsupported expectedTurnId: %#v", params)
		}
		restoreMessage, _ := params["restoreMessage"].(map[string]any)
		restoreContext, _ := restoreMessage["context"].(map[string]any)
		workspaceRoots, _ := restoreContext["workspaceRoots"].([]any)
		attachments, _ := params["attachments"].([]any)
		if restoreMessage["id"] != "client-steer" || restoreMessage["text"] != "调整方向" ||
			restoreMessage["cwd"] != "/tmp" || restoreContext["prompt"] != "调整方向" ||
			len(workspaceRoots) != 1 || workspaceRoots[0] != "/tmp" || len(attachments) != 0 {
			t.Fatalf("Desktop-owned steer restore context is invalid: %#v", params)
		}
	default:
		t.Fatal("Desktop follower steer was not delivered")
	}
	for _, method := range []string{
		"thread-stream-following-changed", "thread-follower-load-complete-history",
		"thread-follower-update-thread-settings", "thread-follower-start-turn", "thread-follower-steer-turn",
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
		case "thread-owner-discovery":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
		case "thread-stream-following-changed":
			fake.write(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{"conversationId": "thread-timeout", "change": map[string]any{
					"type": "snapshot", "revision": 1, "conversationState": map[string]any{"turns": []any{}},
				}},
			})
		case "thread-follower-load-complete-history":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "result": map[string]any{"revision": 1}, "handledByClientId": "desktop-owner",
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

func TestDesktopIPCOverlayRejectsStartWhileDesktopTurnIsActive(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		switch request.Method {
		case "thread-owner-discovery":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
		case "thread-stream-following-changed":
			fake.write(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{
					"conversationId": "thread-active",
					"change": map[string]any{"type": "snapshot", "revision": 1, "conversationState": map[string]any{
						"cwd": "/tmp", "turns": []any{map[string]any{"id": "turn-active", "status": "inProgress", "items": []any{}}},
					}},
				},
			})
		case "thread-follower-load-complete-history":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{"revision": 1}, "handledByClientId": "desktop-owner",
			})
		}
	}
	bridge := newReadyGatewayBridge(t, fake, time.Second)
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":9,"method":"turn/start","params":{"threadId":"thread-active","input":[]}
	}`))
	if !handled || len(response) != 0 || policyErr == nil || policyErr.data["reason"] != "desktop_sync_active_turn" || policyErr.data["accepted"] != false {
		t.Fatalf("active Desktop turn was not failed closed: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
	if fake.methodCount("thread-follower-start-turn") != 0 {
		t.Fatal("active Desktop turn received a duplicate follower start")
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

func TestDesktopIPCCurrentMimiOwnerStartsTurnDirectlyThroughItsAppServer(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	bridge := newReadyGatewayBridge(t, fake, time.Second)
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	overlay.seedFromGatewayResult("", "thread/start", json.RawMessage(`{
		"thread":{"id":"thread-new","cwd":"/tmp","turns":[]}
	}`))
	if !bridge.LocalOwnerIs("thread-new", overlay.ownerID) {
		t.Fatal("new App Server thread was not assigned to the creating gateway")
	}

	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":10,"method":"turn/start","params":{"threadId":"thread-new","input":[]}
	}`))
	if handled || len(response) != 0 || policyErr != nil {
		t.Fatalf("current writer must forward directly to its App Server: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
	if fake.methodCount(desktopIPCLocalForwardMethod) != 0 {
		t.Fatal("current writer turn looped through the local-owner follower route")
	}
}

func TestDesktopIPCMimiOwnerLifecycleActivatesRunningDesktopRoute(t *testing.T) {
	newOverlay := func(t *testing.T, activated chan<- string) (*desktopIPCGatewayOverlay, string) {
		t.Helper()
		fake := &gatewayFakeDesktopIPC{}
		bridge := newReadyGatewayBridgeWithActivator(t, fake, time.Second, func(_ context.Context, threadID, _ string) error {
			select {
			case activated <- threadID:
			default:
			}
			return nil
		})
		overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
		rolloutPath := filepath.Join(t.TempDir(), "rollout.jsonl")
		if err := os.WriteFile(rolloutPath, []byte("{}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return overlay, rolloutPath
	}
	assertActivated := func(t *testing.T, activated <-chan string, want string) {
		t.Helper()
		select {
		case got := <-activated:
			if got != want {
				t.Fatalf("activated Thread %q, want %q", got, want)
			}
		case <-time.After(time.Second):
			t.Fatalf("Desktop route for %q was not activated", want)
		}
	}

	t.Run("new thread materialized", func(t *testing.T) {
		activated := make(chan string, 1)
		overlay, rolloutPath := newOverlay(t, activated)
		result, _ := json.Marshal(map[string]any{"thread": map[string]any{
			"id": "thread-new-route", "cwd": "/tmp", "path": rolloutPath, "turns": []any{},
		}})
		overlay.seedFromGatewayResult("", "thread/start", result)
		assertActivated(t, activated, "thread-new-route")
	})

	t.Run("existing Mimi owner starts turn", func(t *testing.T) {
		activated := make(chan string, 1)
		overlay, rolloutPath := newOverlay(t, activated)
		if err := overlay.claimNewLocalOwner("thread-existing-route"); err != nil {
			t.Fatal(err)
		}
		_, state, err := overlay.local.SeedThread(map[string]any{
			"id": "thread-existing-route", "cwd": "/tmp", "path": rolloutPath, "turns": []any{},
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := overlay.bridge.PublishLocalConversation("thread-existing-route", overlay.ownerID, state); err != nil {
			t.Fatal(err)
		}
		overlay.observeClientForward([]byte(`{
			"id":12,"method":"turn/start","params":{"threadId":"thread-existing-route","input":[]}
		}`))
		assertActivated(t, activated, "thread-existing-route")
	})

	t.Run("fork claims and activates the new thread", func(t *testing.T) {
		activated := make(chan string, 1)
		overlay, rolloutPath := newOverlay(t, activated)
		if err := overlay.claimNewLocalOwner("thread-fork-source"); err != nil {
			t.Fatal(err)
		}
		overlay.observeClientForward([]byte(`{
			"id":13,"method":"thread/fork","params":{"threadId":"thread-fork-source"}
		}`))
		result, _ := json.Marshal(map[string]any{"thread": map[string]any{
			"id": "thread-fork-route", "cwd": "/tmp", "path": rolloutPath, "turns": []any{},
		}})
		response, _ := json.Marshal(map[string]any{"id": 13, "result": json.RawMessage(result)})
		overlay.observeAcceptedUpstreamFrame(response)
		assertActivated(t, activated, "thread-fork-route")
		if !overlay.bridge.LocalOwnerIs("thread-fork-route", overlay.ownerID) {
			t.Fatal("fork result did not claim the new Mimi owner")
		}
	})
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

func TestDesktopIPCOverlayBlocksWritesForRunningUnsupportedBuild(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: desktopipc.SupportedVersion, DesktopBuild: desktopipc.SupportedBuild,
		ClientOptions: desktopipc.ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil },
			VerifyPeer: func(net.Conn) (desktopipc.DesktopInfo, error) {
				return desktopipc.DesktopInfo{Version: desktopipc.SupportedVersion, Build: "future-build"}, nil
			},
			ReconnectDelay: time.Hour,
		},
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
	var localWriterCalled atomic.Bool
	if err := bridge.ClaimNewLocalOwner("thread-stable", "existing-mimi-owner", func(context.Context, string, json.RawMessage) (any, error) {
		localWriterCalled.Store(true)
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":11,"method":"turn/start","params":{"threadId":"thread-stable","input":[]}
	}`))
	if !handled || len(response) != 0 || policyErr == nil || policyErr.data["reason"] != "desktop_sync_owner_unknown" {
		t.Fatalf("running unsupported Desktop must block an uncoordinated writer: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
	if localWriterCalled.Load() {
		t.Fatal("running unsupported Desktop must also pause an existing Mimi writer")
	}
}

func TestDesktopIPCOverlayIsInactiveWhenDesktopIsNotRunning(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, InitialState: desktopipc.StateDesktopNotRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":12,"method":"turn/start","params":{"threadId":"thread-stable","input":[]}
	}`))
	if handled || len(response) != 0 || policyErr != nil {
		t.Fatalf("closed Desktop must leave the independent App Server path untouched: handled=%v response=%s err=%+v", handled, response, policyErr)
	}
}

func TestDesktopIPCOverlayKeepsMimiProjectionCurrentWhileDesktopIsClosed(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, InitialState: desktopipc.StateDesktopNotRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	if err := bridge.ClaimNewLocalOwner("thread-offline", overlay.ownerID, overlay.handleDesktopFollowerRequest); err != nil {
		t.Fatal(err)
	}
	_, state, err := overlay.local.SeedThread(map[string]any{
		"id": "thread-offline", "cwd": "/tmp", "turns": []any{},
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = bridge.PublishLocalConversation("thread-offline", overlay.ownerID, state)
	overlay.observeAcceptedUpstreamFrame([]byte(`{
		"method":"turn/started","params":{"threadId":"thread-offline","turn":{"id":"turn-offline"}}
	}`))
	projection, ok := bridge.LocalProjection("thread-offline")
	if !ok || projection.ActiveTurnID != "turn-offline" || !projection.ActiveTurnIDTrusted {
		t.Fatalf("Desktop-closed App Server activity was not retained: %#v", projection)
	}
	overlay.observeAcceptedUpstreamFrame([]byte(`{
		"method":"turn/completed","params":{"threadId":"thread-offline","turn":{"id":"turn-offline","status":"completed"}}
	}`))
	projection, ok = bridge.LocalProjection("thread-offline")
	if !ok || projection.ActiveTurnID != "" || len(projection.Turns) != 1 {
		t.Fatalf("Desktop-closed completion was not retained: %#v", projection)
	}
}

func TestDesktopIPCMimiOwnerRoutesDesktopFollowerTurnToOneAppServerWriter(t *testing.T) {
	var projectDir string
	var turnStarts atomic.Int64
	turnParams := make(chan map[string]any, 1)
	steerParams := make(chan map[string]any, 1)
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
		case "turn/steer":
			steerParams <- params
			result = map[string]any{}
		case "thread/name/set":
			result = map[string]any{}
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
	if bridge.HasLocalOwner("thread-local") {
		t.Fatal("read-only resume must not claim App Server writer ownership")
	}
	if err := client.WriteMessage(websocket.TextMessage, []byte(`{
		"id":3,"method":"thread/name/set","params":{"threadId":"thread-local","name":"Local owner"}
	}`)); err != nil {
		t.Fatal(err)
	}
	_ = readGatewayRaw(t, client)
	if !bridge.HasLocalOwner("thread-local") {
		t.Fatal("explicit write claim must assign the App Server gateway as the sole writer")
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
	projected := false
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
			projected = true
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !projected {
		t.Fatal("turn/started was not projected to Desktop state")
	}
	_, err = bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-steer-turn", map[string]any{
		"conversationId":      "thread-local",
		"input":               []any{map[string]any{"type": "text", "text": "adjust"}},
		"clientUserMessageId": "client-steer", "additionalContext": map[string]any{"source": "desktop"},
		"responsesapiClientMetadata": map[string]any{"source": "desktop"},
	})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case params := <-steerParams:
		if params["expectedTurnId"] != "turn-local" || params["clientUserMessageId"] != "client-steer" ||
			params["additionalContext"] == nil || params["responsesapiClientMetadata"] == nil {
			t.Fatalf("Desktop follower steer fields were lost: %#v", params)
		}
	default:
		t.Fatal("App Server did not receive the Desktop follower steer")
	}
}

func TestDesktopIPCLocalOwnerHubSurvivesMobileDisconnectAndDelayedDesktopStart(t *testing.T) {
	var projectDir string
	var turnStarts atomic.Int64
	hubConnections := make(chan *websocket.Conn, 2)
	followingConfirmed := make(chan struct{})
	startFollower := make(chan struct{})
	startTurn := make(chan struct{})
	followerResult := make(chan gatewayFakeIPCEnvelope, 2)
	approvalResponses := make(chan struct{}, 1)
	var reissuedApproval atomic.Bool
	upstreamURL, received, connections := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var frame appServerGatewayFrame
		if json.Unmarshal(payload, &frame) != nil || frame.ID == nil {
			return
		}
		if strings.TrimSpace(frame.Method) == "" {
			if gatewayRequestIDKey(frame.ID) == scalarRequestIDKey("approval-new") {
				approvalResponses <- struct{}{}
			}
			return
		}
		params, _ := decodeGatewayParams(frame.Params)
		var result any
		switch frame.Method {
		case "initialize":
			var initialize struct {
				Params struct {
					ClientInfo struct {
						Name string `json:"name"`
					} `json:"clientInfo"`
				} `json:"params"`
			}
			_ = json.Unmarshal(payload, &initialize)
			if initialize.Params.ClientInfo.Name == "mimi_remote_owner" {
				hubConnections <- conn
			}
			result = map[string]any{"userAgent": "codex-test"}
		case "thread/list":
			result = map[string]any{"data": []any{map[string]any{"id": "thread-resident", "cwd": projectDir}}}
		case "thread/resume", "thread/read":
			result = map[string]any{"thread": map[string]any{
				"id": "thread-resident", "cwd": projectDir, "turns": []any{},
			}}
		case "thread/name/set":
			result = map[string]any{}
		case "turn/start":
			turnStarts.Add(1)
			result = map[string]any{"turn": map[string]any{"id": "turn-after-mobile-disconnect"}}
		default:
			return
		}
		response, _ := json.Marshal(map[string]any{"id": rawGatewayID(frame.ID), "result": result})
		_ = conn.WriteMessage(websocket.TextMessage, response)
		if frame.Method == "thread/name/set" {
			request, _ := json.Marshal(map[string]any{
				"id": "approval-old", "method": "item/commandExecution/requestApproval",
				"params": map[string]any{"threadId": "thread-resident", "itemId": "command-old"},
			})
			_ = conn.WriteMessage(websocket.TextMessage, request)
		}
		if frame.Method == "thread/read" && reissuedApproval.CompareAndSwap(false, true) {
			request, _ := json.Marshal(map[string]any{
				"id": "approval-new", "method": "item/commandExecution/requestApproval",
				"params": map[string]any{"threadId": "thread-resident", "itemId": "command-new"},
			})
			_ = conn.WriteMessage(websocket.TextMessage, request)
		}
		if frame.Method == "turn/start" {
			notification, _ := json.Marshal(map[string]any{
				"method": "turn/started", "params": map[string]any{
					"threadId": "thread-resident",
					"turn":     map[string]any{"id": "turn-after-mobile-disconnect"},
				},
			})
			_ = conn.WriteMessage(websocket.TextMessage, notification)
		}
		_ = params
	})
	drainDone := make(chan struct{})
	go func() {
		for {
			select {
			case <-received:
			case <-drainDone:
				return
			}
		}
	}()
	t.Cleanup(func() { close(drainDone) })
	handler, router, fixtureProjectDir := buildAppServerGatewayFixture(t, upstreamURL, nil)
	projectDir = fixtureProjectDir
	router.desktopIPC.Close()

	fake := &gatewayFakeDesktopIPC{}
	var followingOnce sync.Once
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		switch request.Method {
		case "thread-owner-discovery":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "error", "error": "no-client-found",
			})
		case "thread-stream-state-changed":
			followingOnce.Do(func() {
				fake.write(conn, map[string]any{
					"type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
					"sourceClientId": "desktop-renderer", "params": map[string]any{
						"conversationId": "thread-resident", "following": true,
					},
				})
				close(followingConfirmed)
				go func() {
					<-startFollower
					fake.write(conn, map[string]any{
						"type": "request", "requestId": "delayed-history", "method": "thread-follower-load-complete-history",
						"version": 1, "sourceClientId": "desktop-renderer",
						"params": map[string]any{"conversationId": "thread-resident"},
					})
					<-startTurn
					fake.write(conn, map[string]any{
						"type": "request", "requestId": "delayed-start", "method": "thread-follower-start-turn",
						"version": 2, "sourceClientId": "desktop-renderer", "params": map[string]any{
							"conversationId": "thread-resident", "turnStart": map[string]any{"request": map[string]any{
								"cwd": projectDir, "input": []any{map[string]any{"type": "text", "text": "after disconnect"}},
								"sandboxPolicy":  map[string]any{"type": "workspaceWrite", "writableRoots": []any{projectDir}},
								"approvalPolicy": "on-request",
							}},
						},
					})
				}()
			})
		default:
			if request.Type == "response" &&
				(string(request.RequestID) == `"delayed-history"` || string(request.RequestID) == `"delayed-start"`) {
				followerResult <- request
			}
		}
	}
	bridge := newReadyGatewayBridge(t, fake, time.Second)
	router.desktopIPC = bridge
	router.cfg.Codex.DesktopSyncEnabled = true
	router.desktopIPCLocalOwner = newDesktopIPCLocalOwnerHub(router, bridge)
	t.Cleanup(router.desktopIPCLocalOwner.Close)

	server := httptest.NewServer(handler)
	defer server.Close()
	mobile := dialAuthedGateway(t, server.URL)
	if err := mobile.WriteMessage(websocket.TextMessage, []byte(`{"id":1,"method":"thread/list","params":{"cwd":`+mustJSONTestString(projectDir)+`}}`)); err != nil {
		t.Fatal(err)
	}
	_ = readGatewayRaw(t, mobile)
	resumePayload, _ := json.Marshal(map[string]any{
		"id": 2, "method": "thread/resume", "params": map[string]any{
			"threadId": "thread-resident", "cwd": projectDir,
			"sandbox": "workspace-write", "approvalPolicy": "on-request",
		},
	})
	if err := mobile.WriteMessage(websocket.TextMessage, resumePayload); err != nil {
		t.Fatal(err)
	}
	_ = readGatewayRaw(t, mobile)
	if err := mobile.WriteMessage(websocket.TextMessage, []byte(`{
		"id":3,"method":"thread/name/set","params":{"threadId":"thread-resident","name":"Resident owner"}
	}`)); err != nil {
		t.Fatal(err)
	}
	_ = readGatewayRaw(t, mobile)
	if !bridge.LocalOwnerIs("thread-resident", desktopIPCLocalOwnerID) {
		t.Fatal("process-level hub did not claim the Mimi owner")
	}
	approvalDeadline := time.Now().Add(time.Second)
	for time.Now().Before(approvalDeadline) {
		state, _ := router.desktopIPCLocalOwner.local.State("thread-resident")
		if len(desktopIPCTestRequests(state)) == 1 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	state, _ := router.desktopIPCLocalOwner.local.State("thread-resident")
	if requests := desktopIPCTestRequests(state); len(requests) != 1 ||
		requests[0].(map[string]any)["id"] != "approval-old" {
		t.Fatalf("old session approval fixture was not projected: %#v", requests)
	}
	select {
	case <-followingConfirmed:
	case <-time.After(time.Second):
		t.Fatal("Desktop renderer did not confirm following the resident owner")
	}
	var firstHubConnection *websocket.Conn
	select {
	case firstHubConnection = <-hubConnections:
	case <-time.After(time.Second):
		t.Fatal("resident owner App Server connection was not established")
	}
	// The process-level owner must keep its own authorization after the short
	// reconnect cache expires. Desktop follower requests can arrive much later.
	router.gatewayThreadsMu.Lock()
	delete(router.gatewayThreads, gatewayThreadCacheKey("codex", "thread-resident"))
	router.gatewayThreadsMu.Unlock()
	if err := mobile.Close(); err != nil {
		t.Fatal(err)
	}
	if err := firstHubConnection.Close(); err != nil {
		t.Fatal(err)
	}
	recoveryDeadline := time.Now().Add(time.Second)
	for time.Now().Before(recoveryDeadline) {
		state, _ = router.desktopIPCLocalOwner.local.State("thread-resident")
		if bridge.LocalOwnerNeedsRecovery("thread-resident") && len(desktopIPCTestRequests(state)) == 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !bridge.LocalOwnerNeedsRecovery("thread-resident") {
		t.Fatal("resident App Server disconnect did not fence the Mimi owner for history recovery")
	}
	state, _ = router.desktopIPCLocalOwner.local.State("thread-resident")
	if requests := desktopIPCTestRequests(state); len(requests) != 0 {
		t.Fatalf("dead App Server approval remained replayable: %#v", requests)
	}

	// Reproduce the delayed Desktop writer check instead of asserting only the
	// first frame after navigation.
	time.Sleep(150 * time.Millisecond)
	close(startFollower)
	var response gatewayFakeIPCEnvelope
	select {
	case response = <-followerResult:
	case <-time.After(2 * time.Second):
		t.Fatal("Desktop complete-history request did not receive an IPC response after mobile disconnect")
	}
	if string(response.RequestID) != `"delayed-history"` || response.ResultType != "success" {
		t.Fatalf("Desktop complete-history request failed after mobile disconnect: %#v", response)
	}
	recoveredDeadline := time.Now().Add(time.Second)
	for bridge.LocalOwnerNeedsRecovery("thread-resident") && time.Now().Before(recoveredDeadline) {
		time.Sleep(time.Millisecond)
	}
	if bridge.LocalOwnerNeedsRecovery("thread-resident") {
		t.Fatal("successful complete-history response did not reopen the resident writer")
	}
	approvalDeadline = time.Now().Add(time.Second)
	for time.Now().Before(approvalDeadline) {
		state, _ = router.desktopIPCLocalOwner.local.State("thread-resident")
		requests := desktopIPCTestRequests(state)
		if len(requests) == 1 && requests[0].(map[string]any)["id"] == "approval-new" {
			break
		}
		time.Sleep(time.Millisecond)
	}
	state, _ = router.desktopIPCLocalOwner.local.State("thread-resident")
	if requests := desktopIPCTestRequests(state); len(requests) != 1 ||
		requests[0].(map[string]any)["id"] != "approval-new" {
		t.Fatalf("replacement App Server approval was not reissued: %#v", requests)
	}
	if _, err := bridge.RequestLocalOwner(
		context.Background(), "thread-resident", "thread-follower-command-approval-decision",
		map[string]any{"conversationId": "thread-resident", "requestId": "approval-new", "decision": "accept"},
	); err != nil {
		t.Fatalf("reissued approval could not reach the replacement App Server: %v", err)
	}
	select {
	case <-approvalResponses:
	case <-time.After(time.Second):
		t.Fatal("replacement App Server did not receive the reissued approval response")
	}
	close(startTurn)
	select {
	case response = <-followerResult:
	case <-time.After(2 * time.Second):
		t.Fatal("Desktop start request did not receive an IPC response after mobile disconnect")
	}
	if response.ResultType != "success" || turnStarts.Load() != 1 {
		t.Fatalf("delayed Desktop start did not enter exactly one writer: response=%#v starts=%d", response, turnStarts.Load())
	}
	if connections.Load() != 3 {
		t.Fatalf("expected mobile, lost resident, and recovered resident transports; got=%d", connections.Load())
	}
}

func TestDesktopIPCFirstOfflineMutationUsesResidentWriter(t *testing.T) {
	var turnStarts atomic.Int64
	upstreamURL, _, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var frame appServerGatewayFrame
		if json.Unmarshal(payload, &frame) != nil || frame.ID == nil {
			return
		}
		var result any
		switch frame.Method {
		case "initialize":
			result = map[string]any{"userAgent": "codex-test"}
		case "turn/start":
			turnStarts.Add(1)
			result = map[string]any{"turn": map[string]any{"id": "turn-offline-hub"}}
		default:
			return
		}
		response, _ := json.Marshal(map[string]any{"id": rawGatewayID(frame.ID), "result": result})
		_ = conn.WriteMessage(websocket.TextMessage, response)
	})
	_, router, projectDir := buildAppServerGatewayFixture(t, upstreamURL, nil)
	router.desktopIPC.Close()
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, InitialState: desktopipc.StateDesktopNotRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	router.desktopIPC = bridge
	router.cfg.Codex.DesktopSyncEnabled = true
	hub := newDesktopIPCLocalOwnerHub(router, bridge)
	router.desktopIPCLocalOwner = hub
	t.Cleanup(hub.Close)
	allowed := appServerGatewayAllowedThread{id: "thread-offline-hub", cwd: projectDir, scopeID: "demo"}
	hub.allowed["thread-offline-hub"] = allowed
	policy := newAppServerGatewayPolicy(router)
	policy.allowedThreads["thread-offline-hub"] = allowed
	overlay := newDesktopIPCGatewayOverlayWithHub(
		bridge, policy, nil, nil, hub, false,
	)
	handled, response, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":41,"method":"turn/start","params":{"threadId":"thread-offline-hub","cwd":`+
		mustJSONTestString(projectDir)+`,"input":[]}
	}`))
	if !handled || policyErr != nil || len(response) == 0 {
		t.Fatalf("first offline mutation was not routed: handled=%t response=%s err=%+v", handled, response, policyErr)
	}
	if !bridge.LocalOwnerIs("thread-offline-hub", desktopIPCLocalOwnerID) || turnStarts.Load() != 1 {
		t.Fatalf("first offline mutation bypassed the resident writer: owner=%t starts=%d",
			bridge.LocalOwnerIs("thread-offline-hub", desktopIPCLocalOwnerID), turnStarts.Load())
	}
}

func TestDesktopIPCLocalOwnerReadReplaysPendingRequestOnce(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	policy := &appServerGatewayPolicy{allowedThreads: map[string]appServerGatewayAllowedThread{
		"thread-approval-replay": {id: "thread-approval-replay", cwd: "/tmp"},
	}}
	overlay := newDesktopIPCGatewayOverlay(bridge, policy, nil, nil)
	var responseMethod string
	if err := bridge.ClaimNewLocalOwner("thread-approval-replay", overlay.ownerID, func(
		_ context.Context, method string, _ json.RawMessage,
	) (any, error) {
		responseMethod = method
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	_ = bridge.PublishLocalConversation("thread-approval-replay", overlay.ownerID, map[string]any{
		"id": "thread-approval-replay", "cwd": "/tmp", "turns": []any{},
		"requests": []any{map[string]any{
			"id": "approval-1", "method": "item/commandExecution/requestApproval",
			"params": map[string]any{"threadId": "thread-approval-replay", "itemId": "command-1"},
		}},
	})
	updates, unsubscribe := bridge.Subscribe()
	defer unsubscribe()
	read := func(id string) desktopipc.ThreadEvent {
		rawID, _ := json.Marshal(id)
		requestID := json.RawMessage(rawID)
		handled, response, policyErr := overlay.routeLocalOwner(
			context.Background(), &requestID, "thread/read", "thread-approval-replay",
			map[string]any{"threadId": "thread-approval-replay"},
		)
		if !handled || policyErr != nil || len(response) == 0 {
			t.Fatalf("local read failed: handled=%t response=%s err=%+v", handled, response, policyErr)
		}
		overlay.afterClientResponse(response)
		select {
		case event := <-updates:
			return event
		case <-time.After(time.Second):
			t.Fatal("local read did not replay its current pending requests")
		}
		return desktopipc.ThreadEvent{}
	}
	first := overlay.syncServerRequests(read("read-1"))
	if len(first) != 1 || first[0].Method != "item/commandExecution/requestApproval" {
		t.Fatalf("pending approval was not replayed on attach: %#v", first)
	}
	if duplicate := overlay.syncServerRequests(read("read-2")); len(duplicate) != 0 {
		t.Fatalf("pending approval was replayed more than once: %#v", duplicate)
	}
	responsePayload, _ := json.Marshal(map[string]any{
		"id": first[0].ID, "result": map[string]any{"decision": "accept"},
	})
	handled, _, responseErr := overlay.routeClientFrame(context.Background(), responsePayload)
	if !handled || responseErr != nil || responseMethod != "thread-follower-command-approval-decision" {
		t.Fatalf("replayed approval could not return to the local owner: handled=%t method=%q err=%+v", handled, responseMethod, responseErr)
	}
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

func TestDesktopIPCOverlayErrorReleasesValidatedRequestState(t *testing.T) {
	id := json.RawMessage(`"desktop-error"`)
	key := gatewayRequestIDKey(&id)
	policy := &appServerGatewayPolicy{
		pendingThreads: map[string]appServerGatewayPendingThreadRequest{
			key: {method: "thread/read", threadID: "thread-1"},
		},
		pendingHistory: map[string]appServerGatewayPendingHistoryRequest{
			key: {method: "thread/read", threadID: "thread-1"},
		},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{
			key: {method: "account/usage/read"},
		},
	}
	payload := []byte(`{"id":"desktop-error","method":"thread/read","params":{"threadId":"thread-1"}}`)
	policy.abortValidatedRequest(payload)
	if len(policy.pendingThreads) != 0 || len(policy.pendingHistory) != 0 || len(policy.pendingClientRequests) != 0 {
		t.Fatalf("Desktop overlay error leaked request state: threads=%d history=%d clients=%d",
			len(policy.pendingThreads), len(policy.pendingHistory), len(policy.pendingClientRequests))
	}
}

func TestDesktopIPCOverlayRestoresConsumedReverseResponseBeforeDelivery(t *testing.T) {
	id := json.RawMessage(`"approval-1"`)
	policy := &appServerGatewayPolicy{}
	overlay := &desktopIPCGatewayOverlay{
		policy: policy,
		pendingActions: map[string]desktopipc.ServerRequest{
			gatewayRequestIDKey(&id): {
				ID: "approval-1", Method: "item/commandExecution/requestApproval",
				Params: map[string]any{"threadId": "thread-1", "turnId": "turn-1", "itemId": "item-1"},
			},
		},
		pendingActionLocal: map[string]bool{gatewayRequestIDKey(&id): true},
		uncertainActions:   map[string]bool{},
	}
	frame := appServerGatewayFrame{ID: &id}
	handled, _, policyErr := overlay.routeServerRequestResponse(
		context.Background(), frame, []byte(`{"id":"approval-1","error":{"message":"client rejected"}}`),
	)
	if !handled || policyErr == nil {
		t.Fatalf("invalid reverse response was not rejected: handled=%t err=%+v", handled, policyErr)
	}
	if _, ok := policy.pendingServerRequest(&id); !ok {
		t.Fatal("pre-delivery reverse response failure did not restore Gateway pending state")
	}
	if !overlay.pendingActionLocal[gatewayRequestIDKey(&id)] {
		t.Fatal("invalid response lost its local-owner routing before retry")
	}
}

func TestDesktopIPCOverlayRearmsUncertainReverseResponseAfterConfirmedHistory(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		switch request.Method {
		case "thread-stream-following-changed":
			fake.write(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{
					"conversationId": "thread-approval",
					"change": map[string]any{"type": "snapshot", "revision": 1, "conversationState": map[string]any{
						"title": "approval", "cwd": "/tmp", "turns": []any{},
					}},
				},
			})
		case "thread-owner-discovery":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{}, "handledByClientId": "desktop-owner",
			})
		case "thread-follower-load-complete-history":
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"result": map[string]any{"revision": 1}, "handledByClientId": "desktop-owner",
			})
		case "thread-follower-command-approval-decision":
			// Leave delivery uncertain so the policy token cannot be restored until
			// complete history proves the approval is still pending.
			return
		}
	}
	bridge := newReadyGatewayBridge(t, fake, 30*time.Millisecond)

	id := json.RawMessage(`"approval-uncertain"`)
	action := desktopipc.ServerRequest{
		ID: "approval-uncertain", Method: "item/commandExecution/requestApproval",
		Params: map[string]any{
			"threadId": "thread-approval", "turnId": "turn-1", "itemId": "item-1",
		},
	}
	actionParams, _ := json.Marshal(action.Params)
	policy := &appServerGatewayPolicy{}
	if err := policy.rememberPendingServerRequest(&id, action.Method, actionParams); err != nil {
		t.Fatal(err)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, policy, nil, nil)
	projection, owned, err := overlay.discoverDesktopOwner(context.Background(), "thread-approval")
	if err != nil || !owned || projection.Thread == nil {
		t.Fatalf("Desktop approval fixture did not become authoritative: owned=%t projection=%+v err=%v", owned, projection, err)
	}
	validated, policyErr := policy.validateClientFrameContext(
		context.Background(), websocket.TextMessage,
		[]byte(`{"id":"approval-uncertain","result":{"decision":"accept"}}`),
	)
	if policyErr != nil {
		t.Fatalf("public policy rejected the fixture: %+v", policyErr)
	}
	key := gatewayRequestIDKey(&id)
	overlay.pendingActions[key] = action
	handled, _, routeErr := overlay.routeClientFrame(context.Background(), validated)
	if !handled || routeErr == nil || routeErr.data["delivery"] != string(desktopipc.DeliveryUncertain) {
		t.Fatalf("uncertain reverse response was not retained: handled=%t err=%+v", handled, routeErr)
	}
	if _, ok := policy.pendingServerRequest(&id); ok {
		t.Fatal("uncertain response was rearmed before authoritative history")
	}
	overlay.mu.Lock()
	uncertain := overlay.uncertainActions[key]
	overlay.mu.Unlock()
	if !uncertain {
		t.Fatal("uncertain reverse response was not tracked")
	}
	messages := overlay.syncServerRequests(desktopipc.ThreadEvent{
		ThreadID: "thread-approval", HistoryConfirmed: true,
		Requests: []desktopipc.ServerRequest{action},
	})
	if len(messages) != 1 || messages[0].Method != action.Method {
		t.Fatalf("confirmed pending approval was not replayed: %#v", messages)
	}
	if _, ok := policy.pendingServerRequest(&id); !ok {
		t.Fatal("confirmed pending approval did not restore the Gateway response token")
	}
	overlay.mu.Lock()
	uncertain = overlay.uncertainActions[key]
	overlay.mu.Unlock()
	if uncertain {
		t.Fatal("confirmed approval remained marked uncertain")
	}
}

func TestDesktopIPCOverlayBlocksFirstWriteAfterUncertainLocalOwnerRelease(t *testing.T) {
	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		if request.Method == "thread-owner-discovery" {
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "error", "error": "no-client-found",
			})
		}
	}
	bridge := newReadyGatewayBridge(t, fake, 40*time.Millisecond)
	if err := bridge.ClaimNewLocalOwner("thread-local-release", "gateway-old", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, context.Canceled
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local-release", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local-release",
	}); !errors.Is(err, context.Canceled) {
		t.Fatalf("uncertain local fixture failed: %v", err)
	}
	bridge.ReleaseLocalOwner("thread-local-release", "gateway-old")
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	handled, _, policyErr := overlay.routeClientFrame(context.Background(), []byte(`{
		"id":91,"method":"turn/start","params":{"threadId":"thread-local-release","input":[]}
	}`))
	if !handled || policyErr == nil {
		t.Fatalf("replacement gateway bypassed the local recovery gate: handled=%t err=%+v", handled, policyErr)
	}
	if !bridge.LocalOwnerNeedsRecovery("thread-local-release") {
		t.Fatal("replacement gateway cleared local uncertainty without complete history")
	}
}

func TestDesktopIPCReadResponseDoesNotClaimMimiWriter(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: desktopipc.SupportedVersion,
		DesktopBuild: desktopipc.SupportedBuild,
	})
	if err != nil {
		t.Fatal(err)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	overlay.seedFromGatewayResult("thread-read-only", "thread/read", json.RawMessage(`{
		"thread":{"id":"thread-read-only","cwd":"/tmp","turns":[]}
	}`))
	if bridge.HasLocalOwner("thread-read-only") {
		t.Fatal("thread/read response claimed Mimi writer ownership")
	}
}

func TestDesktopIPCLocalReadForcesHistoryWhileRecoveryPending(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	historyCalls := 0
	if err := bridge.ClaimNewLocalOwner("thread-recovery", "gateway", func(
		_ context.Context, method string, _ json.RawMessage,
	) (any, error) {
		if method == "thread-follower-load-complete-history" {
			historyCalls++
			return map[string]any{"revision": 2}, nil
		}
		return nil, context.Canceled
	}); err != nil {
		t.Fatal(err)
	}
	_ = bridge.PublishLocalConversation("thread-recovery", "gateway", map[string]any{
		"id": "thread-recovery", "cwd": "/tmp", "turns": []any{},
	})
	if _, err := bridge.RequestLocalOwner(
		context.Background(), "thread-recovery", "thread-follower-start-turn",
		map[string]any{"conversationId": "thread-recovery"},
	); !errors.Is(err, context.Canceled) {
		t.Fatalf("local uncertainty fixture failed: %v", err)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, &appServerGatewayPolicy{}, nil, nil)
	overlay.ownerID = "gateway"
	handled, _, policyErr := overlay.routeLocalOwner(
		context.Background(), nil, "thread/read", "thread-recovery", map[string]any{"threadId": "thread-recovery"},
	)
	if !handled || policyErr != nil || historyCalls != 1 || bridge.LocalOwnerNeedsRecovery("thread-recovery") {
		t.Fatalf("authoritative local history did not clear recovery: handled=%t calls=%d err=%+v", handled, historyCalls, policyErr)
	}
}

func TestDesktopIPCSteerRequiresAuthorizedProjectionWorkspace(t *testing.T) {
	policy := &appServerGatewayPolicy{allowedThreads: map[string]appServerGatewayAllowedThread{
		"thread-workspace": {id: "thread-workspace", cwd: "/workspace/allowed", scopeID: "demo"},
	}}
	overlay := &desktopIPCGatewayOverlay{policy: policy}
	params := map[string]any{"input": []any{map[string]any{"type": "text", "text": "steer"}}}
	for _, cwd := range []string{"", "/workspace/other"} {
		if _, err := overlay.desktopSteerFollowerParams(
			"thread-workspace", params, desktopipc.Projection{Thread: map[string]any{"cwd": cwd}},
		); err == nil {
			t.Fatalf("projection cwd %q bypassed the authorized workspace", cwd)
		}
	}
	result, err := overlay.desktopSteerFollowerParams(
		"thread-workspace", params, desktopipc.Projection{Thread: map[string]any{"cwd": "/workspace/allowed"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	restore, _ := result["restoreMessage"].(map[string]any)
	if restore["cwd"] != "/workspace/allowed" {
		t.Fatalf("Steer did not use the canonical authorized cwd: %#v", restore)
	}
}

func TestDesktopIPCTraceLogsLifecycleWithoutPrivatePayload(t *testing.T) {
	var output bytes.Buffer
	previousWriter := log.Writer()
	previousFlags := log.Flags()
	log.SetOutput(&output)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(previousWriter)
		log.SetFlags(previousFlags)
	})
	event := desktopipc.ThreadEvent{
		ThreadID: "thread-1234567890-private", Projection: desktopipc.Projection{
			Turns: []any{map[string]any{
				"id": "turn-1234567890-private", "status": "interrupted", "items": []any{map[string]any{
					"id": "item-1234567890-private", "type": "commandExecution", "status": "completed",
					"command": "SECRET_COMMAND", "cwd": "/private/workspace", "output": "SECRET_OUTPUT",
				}},
			}},
		},
	}
	logDesktopIPCProjectionTrace(event)
	text := output.String()
	for _, forbidden := range []string{
		"SECRET_COMMAND", "SECRET_OUTPUT", "/private/workspace",
		"thread-1234567890-private", "turn-1234567890-private", "item-1234567890-private",
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("Desktop IPC trace leaked private payload %q: %s", forbidden, text)
		}
	}
	if !strings.Contains(text, "desktop_ipc_trace") || !strings.Contains(text, "desktoptoolitemstate") {
		t.Fatalf("Desktop IPC lifecycle trace is missing: %s", text)
	}
}

func TestDesktopIPCOverlayDoesNotLeakDesktopResponseWhenDesktopCloses(t *testing.T) {
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, InitialState: desktopipc.StateDesktopNotRunning,
	})
	if err != nil {
		t.Fatal(err)
	}
	id := json.RawMessage(`"approval-offline"`)
	params := json.RawMessage(`{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}`)
	policy := &appServerGatewayPolicy{}
	if err := policy.rememberPendingServerRequest(&id, "item/commandExecution/requestApproval", params); err != nil {
		t.Fatal(err)
	}
	validated, policyErr := policy.validateClientFrameContext(
		context.Background(), websocket.TextMessage, []byte(`{"id":"approval-offline","result":{"decision":"accept"}}`),
	)
	if policyErr != nil {
		t.Fatalf("public policy rejected the fixture: %+v", policyErr)
	}
	overlay := newDesktopIPCGatewayOverlay(bridge, policy, nil, nil)
	overlay.pendingActions[gatewayRequestIDKey(&id)] = desktopipc.ServerRequest{
		ID: "approval-offline", Method: "item/commandExecution/requestApproval",
		Params: map[string]any{"threadId": "thread-1", "turnId": "turn-1", "itemId": "item-1"},
	}
	handled, _, routeErr := overlay.routeClientFrame(context.Background(), validated)
	if !handled || routeErr == nil || routeErr.data["response_to_server_request"] != true {
		t.Fatalf("closed Desktop response was not rejected locally: handled=%t err=%+v", handled, routeErr)
	}
	if _, ok := policy.pendingServerRequest(&id); !ok {
		t.Fatal("closed Desktop response did not restore the consumed policy pending request")
	}
}

func mustJSONTestString(value string) string {
	payload, _ := json.Marshal(value)
	return string(payload)
}

func desktopIPCTestRequests(state map[string]any) []any {
	requests, _ := state["requests"].([]any)
	return requests
}

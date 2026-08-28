package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/desktopipc"
)

// handoffHubFixture wires a resident owner hub on top of a Desktop IPC bridge
// whose route activation is observable. Desktop rejects owner discovery, so
// every Thread here is Mimi-owned and must still be mounted as a Desktop
// follower route.
type handoffHubFixture struct {
	overlay    *desktopIPCGatewayOverlay
	hub        *desktopIPCLocalOwnerHub
	bridge     *desktopipc.Bridge
	projectDir string
	activated  <-chan string
	// desktopRunning gates the bridge preflight the same way the real process
	// check does, so the test can close and open Desktop without test hooks.
	desktopRunning *atomic.Bool
}

func newHandoffHubFixture(t *testing.T, desktopRunning bool) *handoffHubFixture {
	t.Helper()
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
			result = map[string]any{"turn": map[string]any{"id": "turn-handoff"}}
		case "thread/read":
			result = map[string]any{"thread": map[string]any{
				"id": "thread-handoff", "cwd": "/tmp", "turns": []any{},
			}}
		default:
			return
		}
		response, _ := json.Marshal(map[string]any{"id": rawGatewayID(frame.ID), "result": result})
		_ = conn.WriteMessage(websocket.TextMessage, response)
	})
	_, router, projectDir := buildAppServerGatewayFixture(t, upstreamURL, nil)
	router.desktopIPC.Close()

	activated := make(chan string, 8)
	running := &atomic.Bool{}
	running.Store(desktopRunning)
	fake := &gatewayFakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request gatewayFakeIPCEnvelope) {
		if request.Method == "thread-owner-discovery" {
			fake.write(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "error", "error": "no-client-found",
			})
		}
	}
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test",
		DesktopVersion: desktopipc.SupportedVersion, DesktopBuild: desktopipc.SupportedBuild,
		ActivateDesktopThread: func(_ context.Context, threadID, _ string) error {
			select {
			case activated <- threadID:
			default:
			}
			return nil
		},
		ClientOptions: desktopipc.ClientOptions{
			DialContext:  fake.dial,
			VerifySocket: func(string) error { return nil },
			VerifyPeer: func(net.Conn) (desktopipc.DesktopInfo, error) {
				return desktopipc.DesktopInfo{
					Version: desktopipc.SupportedVersion, Build: desktopipc.SupportedBuild,
				}, nil
			},
			Preflight: func() (desktopipc.State, error) {
				if running.Load() {
					return "", nil
				}
				return desktopipc.StateDesktopNotRunning, nil
			},
			RequestTimeout: time.Second,
			ReconnectDelay: 50 * time.Millisecond,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	bridge.Start(ctx)
	t.Cleanup(func() { cancel(); bridge.Close() })

	wantState := desktopipc.StateDesktopNotRunning
	if desktopRunning {
		wantState = desktopipc.StateReady
	}
	waitForDesktopIPCState(t, bridge, wantState)

	router.desktopIPC = bridge
	router.cfg.Codex.DesktopSyncEnabled = true
	hub := newDesktopIPCLocalOwnerHub(router, bridge)
	router.desktopIPCLocalOwner = hub
	t.Cleanup(hub.Close)

	allowed := appServerGatewayAllowedThread{id: "thread-handoff", cwd: projectDir, scopeID: "demo"}
	hub.allowed["thread-handoff"] = allowed
	policy := newAppServerGatewayPolicy(router)
	policy.allowedThreads["thread-handoff"] = allowed
	return &handoffHubFixture{
		overlay:        newDesktopIPCGatewayOverlayWithHub(bridge, policy, nil, nil, hub, false),
		hub:            hub,
		bridge:         bridge,
		projectDir:     projectDir,
		activated:      activated,
		desktopRunning: running,
	}
}

func waitForDesktopIPCState(t *testing.T, bridge *desktopipc.Bridge, want desktopipc.State) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if bridge.Status().State == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("Desktop IPC state is %q, want %q", bridge.Status().State, want)
}

func (f *handoffHubFixture) startTurn(t *testing.T, requestID int) {
	t.Helper()
	frame := fmt.Sprintf(
		`{"id":%d,"method":"turn/start","params":{"threadId":"thread-handoff","cwd":%s,"input":[]}}`,
		requestID, mustJSONTestString(f.projectDir),
	)
	handled, response, policyErr := f.overlay.routeClientFrame(context.Background(), []byte(frame))
	if policyErr != nil {
		t.Fatalf("Mimi turn was rejected: %+v", policyErr)
	}
	if !handled || len(response) == 0 {
		t.Fatalf("Mimi turn did not use the resident writer: handled=%t response=%s", handled, response)
	}
}

func (f *handoffHubFixture) awaitActivation(t *testing.T) {
	t.Helper()
	select {
	case got := <-f.activated:
		if got != "thread-handoff" {
			t.Fatalf("activated Thread %q, want thread-handoff", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Desktop follower route for thread-handoff was never activated")
	}
}

// A Mimi-owned turn must mount the Desktop follower route. Without it Codex
// Desktop never opens the Thread and cannot read anything the app created.
func TestDesktopIPCResidentHubActivatesDesktopRouteForMimiTurn(t *testing.T) {
	fixture := newHandoffHubFixture(t, true)
	fixture.startTurn(t, 1)
	fixture.awaitActivation(t)
}

// Codex deletes a thread's writer lock file when its owner lets the thread go,
// so a missing lock file already proves Desktop cannot own it. Owner discovery
// must answer from that instead of waiting out the IPC probe.
func TestDesktopIPCOwnerDiscoverySkipsProbeWithoutWriterLock(t *testing.T) {
	// The fake never answers thread-owner-discovery, so any probe burns the full
	// request timeout.
	fake := &gatewayFakeDesktopIPC{}
	lockDir := t.TempDir()
	bridge, err := desktopipc.NewBridge(desktopipc.BridgeOptions{
		Enabled: true, SocketPath: "test", WriterLockDir: lockDir,
		DesktopVersion: desktopipc.SupportedVersion, DesktopBuild: desktopipc.SupportedBuild,
		ClientOptions: desktopipc.ClientOptions{
			DialContext:  fake.dial,
			VerifySocket: func(string) error { return nil },
			VerifyPeer: func(net.Conn) (desktopipc.DesktopInfo, error) {
				return desktopipc.DesktopInfo{
					Version: desktopipc.SupportedVersion, Build: desktopipc.SupportedBuild,
				}, nil
			},
			RequestTimeout: 30 * time.Second,
			ReconnectDelay: 50 * time.Millisecond,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() { cancel(); bridge.Close() })
	bridge.Start(ctx)
	waitForDesktopIPCState(t, bridge, desktopipc.StateReady)

	overlay := newDesktopIPCGatewayOverlay(bridge, newAppServerGatewayPolicy(nil), nil, nil)
	started := time.Now()
	projection, owned, discoverErr := overlay.discoverDesktopOwner(context.Background(), "thread-unlocked")
	elapsed := time.Since(started)

	if discoverErr != nil || owned || projection.Thread != nil {
		t.Fatalf("unlocked Thread must be reported as unowned: owned=%t err=%v", owned, discoverErr)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("owner discovery waited %s for a Thread with no writer lock", elapsed)
	}
	if count := fake.methodCount("discover:thread-owner-discovery"); count != 0 {
		t.Fatalf("owner discovery probed Desktop %d times despite a free writer lock", count)
	}
}

// A Thread claimed while Desktop was closed must be mounted once Desktop comes
// back. Otherwise it stays invisible for the rest of the agentd process.
func TestDesktopIPCResidentHubActivatesOfflineClaimAfterDesktopStarts(t *testing.T) {
	fixture := newHandoffHubFixture(t, false)
	fixture.startTurn(t, 1)
	select {
	case threadID := <-fixture.activated:
		t.Fatalf("closed Desktop must not be routed to, got %q", threadID)
	case <-time.After(200 * time.Millisecond):
	}

	fixture.desktopRunning.Store(true)
	waitForDesktopIPCState(t, fixture.bridge, desktopipc.StateReady)
	fixture.awaitActivation(t)
}

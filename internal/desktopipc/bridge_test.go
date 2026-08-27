package desktopipc

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"testing"
	"time"
)

func TestBridgeProjectsDesktopSnapshotAndRejectsOwnerCompetition(t *testing.T) {
	fake := &fakeDesktopIPC{}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: func(net.Conn) error { return nil },
			RequestTimeout: time.Second, ReconnectDelay: 10 * time.Millisecond,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	bridge.Start(ctx)
	t.Cleanup(func() { cancel(); bridge.Close() })
	readyCtx, readyCancel := context.WithTimeout(context.Background(), time.Second)
	defer readyCancel()
	if err := bridge.client.WaitReady(readyCtx); err != nil {
		t.Fatal(err)
	}
	updates, unsubscribe := bridge.Subscribe()
	defer unsubscribe()
	payload, _ := json.Marshal(map[string]any{
		"conversationId": "thread-1",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "Desktop", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{Method: "thread-stream-state-changed", Version: 11, SourceClientID: "desktop-owner", Params: payload})
	select {
	case event := <-updates:
		if event.ThreadID != "thread-1" || event.Projection.Thread["title"] != "Desktop" {
			t.Fatalf("unexpected event: %+v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("Desktop snapshot was not projected")
	}
	if err := bridge.ClaimLocalOwner("thread-1", "gateway-1", func(context.Context, string, json.RawMessage) (any, error) { return nil, nil }); err == nil {
		t.Fatal("Mimi must not claim a Desktop-owned thread")
	}
}

func TestProjectPendingServerRequests(t *testing.T) {
	requests := ProjectPendingServerRequests("thread-1", map[string]any{
		"requests": []any{
			map[string]any{"id": 7, "method": "item/tool/requestUserInput", "params": map[string]any{"questions": []any{"q"}}},
			map[string]any{"id": 8, "method": "unknown/request", "params": map[string]any{}},
		},
	})
	if len(requests) != 1 || requests[0].Method != "item/tool/requestUserInput" || requests[0].Params["threadId"] != "thread-1" {
		t.Fatalf("unexpected requests: %#v", requests)
	}
}

func TestBridgePublishesLocalSnapshotThenContiguousPatch(t *testing.T) {
	fake := &fakeDesktopIPC{}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: func(net.Conn) error { return nil },
			RequestTimeout: time.Second, ReconnectDelay: 10 * time.Millisecond,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	bridge.Start(ctx)
	t.Cleanup(func() { cancel(); bridge.Close() })
	readyCtx, readyCancel := context.WithTimeout(context.Background(), time.Second)
	defer readyCancel()
	if err := bridge.client.WaitReady(readyCtx); err != nil {
		t.Fatal(err)
	}
	if err := bridge.ClaimLocalOwner("thread-local", "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	first := map[string]any{"title": "Before", "turns": []any{}}
	if err := bridge.PublishLocalConversation("thread-local", first); err != nil {
		t.Fatal(err)
	}
	second := map[string]any{"title": "After", "turns": []any{}}
	if err := bridge.PublishLocalConversation("thread-local", second); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation("thread-local", second); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(time.Second)
	var changes []StreamChange
	for time.Now().Before(deadline) {
		fake.mu.Lock()
		requests := append([]envelope(nil), fake.requests...)
		fake.mu.Unlock()
		changes = changes[:0]
		for _, request := range requests {
			if request.Method != "thread-stream-state-changed" {
				continue
			}
			var params struct {
				Change StreamChange `json:"change"`
			}
			if json.Unmarshal(request.Params, &params) == nil {
				changes = append(changes, params.Change)
			}
		}
		if len(changes) == 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(changes) != 2 {
		t.Fatalf("expected exactly snapshot and patch, got %#v", changes)
	}
	if changes[0].Type != "snapshot" || changes[0].Revision != 1 {
		t.Fatalf("unexpected snapshot: %#v", changes[0])
	}
	if changes[1].Type != "patches" || changes[1].BaseRevision != 1 || changes[1].Revision != 2 {
		t.Fatalf("unexpected patch revision: %#v", changes[1])
	}
}

func TestBridgeSlowSubscriberReceivesFreshSnapshotInsteadOfRevisionGap(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	updates := make(chan ThreadEvent, 32)
	for revision := 1; revision <= 33; revision++ {
		previous := Projection{Thread: map[string]any{"title": "previous"}}
		bridge.publishThreadEvent([]chan ThreadEvent{updates}, ThreadEvent{
			ThreadID: "thread-1",
			Projection: Projection{Thread: map[string]any{
				"title": revision,
			}},
			Previous: &previous,
		})
	}
	if len(updates) != 1 {
		t.Fatalf("overflow must coalesce queued deltas into one snapshot, queued=%d", len(updates))
	}
	event := <-updates
	if event.Previous != nil || event.Projection.Thread["title"] != 33 {
		t.Fatalf("unexpected coalesced snapshot: %#v", event)
	}
}

func TestSystemBridgeReportsLegacyCleanupBeforeDesktopInspection(t *testing.T) {
	bridge, err := NewSystemBridge(false, true, "/missing/codex", nil)
	if err != nil {
		t.Fatal(err)
	}
	status := bridge.Status()
	if status.State != StateLegacyCleanupRequired || status.Enabled {
		t.Fatalf("unexpected legacy status: %+v", status)
	}
}

func TestBridgeProtocolErrorBlocksDesktopOwnerWritesAndFollowerHandling(t *testing.T) {
	fake := &fakeDesktopIPC{}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: func(net.Conn) error { return nil },
			RequestTimeout: time.Second, ReconnectDelay: 10 * time.Millisecond,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	bridge.Start(ctx)
	t.Cleanup(func() { cancel(); bridge.Close() })
	readyCtx, readyCancel := context.WithTimeout(context.Background(), time.Second)
	defer readyCancel()
	if err := bridge.client.WaitReady(readyCtx); err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	bridge.desktopOwners["thread-desktop"] = "desktop-owner"
	bridge.localOwners["thread-local"] = localOwner{
		ownerID: "gateway", handle: func(context.Context, string, json.RawMessage) (any, error) { return nil, nil },
	}
	bridge.mu.Unlock()
	bridge.client.status.update(func(status *Status) { status.State = StateProtocolError })

	_, err = bridge.RequestDesktopOwner(context.Background(), "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-desktop",
	})
	var requestErr *RequestError
	if !errors.As(err, &requestErr) || requestErr.Delivery != DeliveryNotSent {
		t.Fatalf("protocol error must block the Desktop write before delivery: %v", err)
	}
	params, _ := json.Marshal(map[string]any{"conversationId": "thread-local"})
	if bridge.canHandleIncoming(IncomingRequest{
		Method: "thread-follower-start-turn", Version: 2, Params: params,
	}) {
		t.Fatal("protocol error must reject Desktop follower discovery")
	}
}

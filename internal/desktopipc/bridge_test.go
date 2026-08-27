package desktopipc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"
)

func TestBridgeProjectsDesktopSnapshotAndRejectsOwnerCompetition(t *testing.T) {
	fake := &fakeDesktopIPC{}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
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
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
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

func TestBridgeSerializesConcurrentLocalRevisionsPerThread(t *testing.T) {
	fake := &fakeDesktopIPC{}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
			RequestTimeout: time.Second, ReconnectDelay: time.Hour,
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
	if err := bridge.ClaimLocalOwner("thread-concurrent", "gateway", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	const publishes = 24
	var wait sync.WaitGroup
	errs := make(chan error, publishes)
	for index := 0; index < publishes; index++ {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			errs <- bridge.PublishLocalConversation("thread-concurrent", map[string]any{
				"title": fmt.Sprintf("revision-%d", index), "turns": []any{},
			})
		}(index)
	}
	wait.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		fake.mu.Lock()
		requests := append([]envelope(nil), fake.requests...)
		fake.mu.Unlock()
		changes := make([]StreamChange, 0, publishes)
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
		if len(changes) == publishes {
			for index, change := range changes {
				want := int64(index + 1)
				if change.Revision != want || index > 0 && change.BaseRevision != want-1 {
					t.Fatalf("non-contiguous concurrent revisions at %d: %#v", index, changes)
				}
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("concurrent publications did not reach the Desktop IPC client")
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
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
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
	bridge.owners["thread-desktop"] = threadOwner{
		kind: threadOwnerDesktop, ownerID: "desktop-owner", connectionGeneration: bridge.connectionGeneration,
	}
	bridge.owners["thread-local"] = threadOwner{
		kind: threadOwnerMimi, ownerID: "gateway",
		handle: func(context.Context, string, json.RawMessage) (any, error) { return nil, nil },
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

func TestBridgeDiscoveryCannotOverwriteConcurrentMimiClaim(t *testing.T) {
	fake := &fakeDesktopIPC{}
	discoveryStarted := make(chan struct{})
	allowResponse := make(chan struct{})
	fake.respond = func(conn net.Conn, request envelope) {
		if request.Method != "thread-owner-discovery" {
			return
		}
		close(discoveryStarted)
		<-allowResponse
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID),
			"resultType": "success", "result": map[string]any{}, "handledByClientId": "desktop-owner",
		})
	}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
			RequestTimeout: time.Second, ReconnectDelay: time.Hour,
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
	result := make(chan error, 1)
	go func() {
		_, err := bridge.DiscoverDesktopOwner(context.Background(), "thread-race")
		result <- err
	}()
	<-discoveryStarted
	if err := bridge.ClaimLocalOwner("thread-race", "gateway", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	close(allowResponse)
	if err := <-result; err == nil {
		t.Fatal("late Desktop discovery must not overwrite a concurrent Mimi claim")
	}
	if !bridge.HasLocalOwner("thread-race") {
		t.Fatal("Mimi must remain the only owner after the discovery race")
	}
}

func TestBridgeMalformedBroadcastCannotClaimDesktopOwnership(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.connectionGeneration = 1
	payload, _ := json.Marshal(map[string]any{
		"conversationId": "thread-malformed", "change": map[string]any{"type": "patches", "revision": 2},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11, SourceClientID: "desktop-owner", Params: payload,
	})
	bridge.mu.RLock()
	owner := bridge.owners["thread-malformed"]
	bridge.mu.RUnlock()
	if owner.kind != 0 {
		t.Fatalf("malformed state change claimed Desktop ownership: %#v", owner)
	}
}

func TestBridgeDisconnectInvalidatesDesktopProjection(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.connectionGeneration = 7
	bridge.owners["thread-stale"] = threadOwner{
		kind: threadOwnerDesktop, ownerID: "desktop-owner", connectionGeneration: 7,
	}
	bridge.projections["thread-stale"] = Projection{Thread: map[string]any{"id": "thread-stale"}}
	bridge.followed["thread-stale"] = struct{}{}
	updates, unsubscribe := bridge.Subscribe()
	defer unsubscribe()
	bridge.handleDisconnect(7)
	if _, ok := bridge.DesktopProjection("thread-stale"); ok {
		t.Fatal("disconnected Desktop projection remained readable")
	}
	select {
	case event := <-updates:
		if !event.Stale || event.ThreadID != "thread-stale" {
			t.Fatalf("unexpected disconnect event: %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("disconnect did not publish stale ownership")
	}
}

func TestBridgeBindsMimiFollowerRequestsToOneDesktopClient(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	if err := bridge.ClaimLocalOwner("thread-local", "gateway", func(context.Context, string, json.RawMessage) (any, error) {
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	params, _ := json.Marshal(map[string]any{"conversationId": "thread-local"})
	if !bridge.canHandleIncoming(IncomingRequest{
		Method: "thread-owner-discovery", Version: 1, SourceClientID: "desktop-a", Params: params,
	}) {
		t.Fatal("owner discovery did not bind the Desktop follower client")
	}
	if bridge.canHandleIncoming(IncomingRequest{
		Method: "thread-follower-start-turn", Version: 2, SourceClientID: "desktop-b", Params: params,
	}) {
		t.Fatal("a different logical Desktop client could mutate the Mimi-owned thread")
	}
	if !bridge.canHandleIncoming(IncomingRequest{
		Method: "thread-follower-start-turn", Version: 2, SourceClientID: "desktop-a", Params: params,
	}) {
		t.Fatal("the bound Desktop follower client was rejected")
	}
}

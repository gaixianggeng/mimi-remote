package desktopipc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"sync/atomic"
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
	if err := bridge.ClaimNewLocalOwner("thread-1", "gateway-1", func(context.Context, string, json.RawMessage) (any, error) { return nil, nil }); err == nil {
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
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	first := map[string]any{"title": "Before", "turns": []any{}}
	if err := bridge.PublishLocalConversation("thread-local", "gateway-1", first); err != nil {
		t.Fatal(err)
	}
	second := map[string]any{"title": "After", "turns": []any{}}
	if err := bridge.PublishLocalConversation("thread-local", "gateway-1", second); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation("thread-local", "gateway-1", second); err != nil {
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
	if err := bridge.ClaimNewLocalOwner("thread-concurrent", "gateway", func(context.Context, string, json.RawMessage) (any, error) {
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
			errs <- bridge.PublishLocalConversation("thread-concurrent", "gateway", map[string]any{
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
	if err := bridge.ClaimNewLocalOwner("thread-race", "gateway", func(context.Context, string, json.RawMessage) (any, error) {
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

func TestBridgeNoClientDiscoveryCannotClearConcurrentDesktopSnapshot(t *testing.T) {
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
			"resultType": "error", "error": "no-client-found",
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
	result := make(chan struct {
		owned bool
		err   error
	}, 1)
	go func() {
		owned, err := bridge.DiscoverDesktopOwner(context.Background(), "thread-race")
		result <- struct {
			owned bool
			err   error
		}{owned: owned, err: err}
	}()
	<-discoveryStarted
	payload, _ := json.Marshal(map[string]any{
		"conversationId": "thread-race",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "Desktop won", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11, SourceClientID: "desktop-owner", Params: payload,
	})
	close(allowResponse)
	discovery := <-result
	if discovery.err != nil || !discovery.owned {
		t.Fatalf("concurrent Desktop snapshot must win negative discovery: owned=%t err=%v", discovery.owned, discovery.err)
	}
	projection, ok := bridge.DesktopProjection("thread-race")
	if !ok || projection.Thread["title"] != "Desktop won" {
		t.Fatalf("negative discovery cleared the committed Desktop owner: %#v", projection)
	}
	if err := bridge.ClaimNewLocalOwner("thread-race", "gateway", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err == nil {
		t.Fatal("Mimi claimed a thread after Desktop won the discovery race")
	}
}

func TestBridgeReservesDesktopStartAcrossConcurrentAndAckSnapshotWindow(t *testing.T) {
	fake := &fakeDesktopIPC{}
	startSeen := make(chan struct{})
	allowAck := make(chan struct{})
	fake.respond = func(conn net.Conn, request envelope) {
		if request.Method == "thread-follower-update-thread-settings" {
			writeTestEnvelope(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
				"handledByClientId": "desktop-owner", "result": map[string]any{},
			})
			return
		}
		if request.Method != "thread-follower-start-turn" {
			return
		}
		close(startSeen)
		<-allowAck
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
			"handledByClientId": "desktop-owner",
			"result":            map[string]any{"result": map[string]any{"turn": map[string]any{"id": "turn-1"}}},
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
	generation := bridge.client.ConnectionGeneration()
	bridge.mu.Lock()
	bridge.setOwnerLocked("thread-start", threadOwner{
		kind: threadOwnerDesktop, ownerID: "desktop-owner", connectionGeneration: generation,
	})
	bridge.projections["thread-start"] = Projection{Thread: map[string]any{"id": "thread-start"}}
	bridge.mu.Unlock()
	first := make(chan error, 1)
	go func() {
		_, err := bridge.RequestDesktopTurnStart(
			context.Background(),
			map[string]any{"conversationId": "thread-start", "threadSettings": map[string]any{"model": "model-a"}},
			map[string]any{"conversationId": "thread-start"},
		)
		first <- err
	}()
	<-startSeen
	_, err = bridge.RequestDesktopTurnStart(
		context.Background(),
		map[string]any{"conversationId": "thread-start", "threadSettings": map[string]any{"model": "model-b"}},
		map[string]any{"conversationId": "thread-start"},
	)
	if !errors.Is(err, ErrDesktopStartInFlight) {
		t.Fatalf("concurrent Desktop start was not blocked before delivery: %v", err)
	}
	close(allowAck)
	if err := <-first; err != nil {
		t.Fatal(err)
	}
	unrelatedSnapshot, _ := json.Marshal(map[string]any{
		"conversationId": "thread-start",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "unrelated update", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11, SourceClientID: "desktop-owner", Params: unrelatedSnapshot,
	})
	_, err = bridge.RequestDesktopTurnStart(
		context.Background(),
		map[string]any{"conversationId": "thread-start", "threadSettings": map[string]any{"model": "model-b"}},
		map[string]any{"conversationId": "thread-start"},
	)
	if !errors.Is(err, ErrDesktopStartInFlight) {
		t.Fatalf("Desktop start ACK-to-snapshot window was not reserved: %v", err)
	}
	completedSnapshot, _ := json.Marshal(map[string]any{
		"conversationId": "thread-start",
		"change": map[string]any{
			"type": "snapshot", "revision": 2,
			"conversationState": map[string]any{
				"title": "completed", "turns": []any{map[string]any{"id": "turn-1", "status": "completed"}},
			},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11, SourceClientID: "desktop-owner", Params: completedSnapshot,
	})
	bridge.mu.RLock()
	_, stillReserved := bridge.desktopStarts["thread-start"]
	bridge.mu.RUnlock()
	if stillReserved {
		t.Fatal("terminal Desktop snapshot did not release the start reservation")
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	startCount := 0
	settingsCount := 0
	for _, request := range fake.requests {
		switch request.Method {
		case "thread-follower-start-turn":
			startCount++
		case "thread-follower-update-thread-settings":
			settingsCount++
		}
	}
	if startCount != 1 || settingsCount != 1 {
		t.Fatalf("reservation allowed duplicate settings/start delivery: settings=%d start=%d", settingsCount, startCount)
	}
}

func TestBridgeCoalescesRevisionGapResyncAndWaitsForSnapshot(t *testing.T) {
	fake := &fakeDesktopIPC{}
	var historyRequests atomic.Int64
	fake.respond = func(conn net.Conn, request envelope) {
		if request.Method != "thread-follower-load-complete-history" {
			return
		}
		historyRequests.Add(1)
		writeTestEnvelope(conn, map[string]any{
			"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
			"sourceClientId": "desktop-owner",
			"params": map[string]any{
				"conversationId": "thread-gap",
				"change": map[string]any{
					"type": "snapshot", "revision": 3,
					"conversationState": map[string]any{"title": "recovered", "turns": []any{}},
				},
			},
		})
		writeTestEnvelope(conn, map[string]any{
			"type": "response", "requestId": json.RawMessage(request.RequestID), "resultType": "success",
			"handledByClientId": "desktop-owner", "result": map[string]any{"revision": 3},
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
	initial, _ := json.Marshal(map[string]any{
		"conversationId": "thread-gap",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "before", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11, SourceClientID: "desktop-owner", Params: initial,
	})
	gap, _ := json.Marshal(map[string]any{
		"conversationId": "thread-gap",
		"change": map[string]any{
			"type": "patches", "baseRevision": 2, "revision": 3,
			"patches": []any{map[string]any{"op": "replace", "path": []any{"title"}, "value": "gap"}},
		},
	})
	for index := 0; index < 2; index++ {
		bridge.handleBroadcast(Broadcast{
			Method: "thread-stream-state-changed", Version: 11, SourceClientID: "desktop-owner", Params: gap,
		})
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		projection, ok := bridge.DesktopProjection("thread-gap")
		bridge.mu.RLock()
		resyncing := bridge.resyncing["thread-gap"]
		bridge.mu.RUnlock()
		if ok && projection.Thread["title"] == "recovered" && resyncing == 0 {
			if historyRequests.Load() != 1 {
				t.Fatalf("revision gap launched %d complete-history requests", historyRequests.Load())
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("revision gap did not recover to the acknowledged snapshot")
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
	bridge.connectionGeneration = 1
	bridge.client.mu.Lock()
	bridge.client.generation = 1
	bridge.client.mu.Unlock()
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway", func(context.Context, string, json.RawMessage) (any, error) {
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	params, _ := json.Marshal(map[string]any{"conversationId": "thread-local"})
	if !bridge.canHandleIncoming(IncomingRequest{
		Method: "thread-owner-discovery", Version: 1, SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}) {
		t.Fatal("owner discovery did not bind the Desktop follower client")
	}
	if bridge.canHandleIncoming(IncomingRequest{
		Method: "thread-follower-start-turn", Version: 2, SourceClientID: "desktop-b", ConnectionGeneration: 1, Params: params,
	}) {
		t.Fatal("a different logical Desktop client could mutate the Mimi-owned thread")
	}
	if !bridge.canHandleIncoming(IncomingRequest{
		Method: "thread-follower-start-turn", Version: 2, SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}) {
		t.Fatal("the bound Desktop follower client was rejected")
	}
}

func TestBridgeBlocksNewFollowerWritesAfterUncertainOldGenerationDelivery(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.connectionGeneration = 1
	bridge.client.mu.Lock()
	bridge.client.generation = 1
	bridge.client.mu.Unlock()
	var writes int
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway", func(_ context.Context, method string, _ json.RawMessage) (any, error) {
		switch method {
		case "thread-follower-load-complete-history":
			return map[string]any{"revision": 1}, nil
		default:
			writes++
			if writes == 1 {
				return nil, context.Canceled
			}
			return map[string]any{}, nil
		}
	}); err != nil {
		t.Fatal(err)
	}
	params, _ := json.Marshal(map[string]any{"conversationId": "thread-local"})
	if _, err := bridge.handleIncoming(context.Background(), IncomingRequest{
		Method: "thread-owner-discovery", Version: 1, SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}); err != nil {
		t.Fatal(err)
	}
	writeRequest := IncomingRequest{
		Method: "thread-follower-start-turn", Version: 2, SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}
	if _, err := bridge.handleIncoming(context.Background(), writeRequest); !errors.Is(err, context.Canceled) {
		t.Fatalf("first uncertain follower write returned unexpected error: %v", err)
	}
	if _, err := bridge.handleIncoming(context.Background(), writeRequest); err == nil {
		t.Fatal("second follower write was allowed while the prior delivery was uncertain")
	}
	if writes != 1 {
		t.Fatalf("uncertain write reached the App Server more than once: %d", writes)
	}
	historyRequest := IncomingRequest{
		RequestID: json.RawMessage(`"history-1"`), Method: "thread-follower-load-complete-history", Version: 1,
		SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}
	if _, err := bridge.handleIncoming(context.Background(), historyRequest); err != nil {
		t.Fatal(err)
	}
	bridge.handleIncomingResponse(historyRequest, nil)
	if _, err := bridge.handleIncoming(context.Background(), writeRequest); err != nil {
		t.Fatalf("complete history did not clear the conservative write block: %v", err)
	}
	if writes != 2 {
		t.Fatalf("write did not resume after complete history: %d", writes)
	}
}

func TestBridgeMarksLocalDeliveryUncertainWhenIPCResponseWriteFails(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	clientConn, serverConn := net.Pipe()
	connectionCtx, connectionCancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		connectionCancel()
		_ = clientConn.Close()
		_ = serverConn.Close()
	})
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.client.mu.Lock()
	bridge.client.conn = clientConn
	bridge.client.clientID = "mimi-client"
	bridge.client.generation = 1
	bridge.client.connectionCtx = connectionCtx
	bridge.client.connectionCancel = connectionCancel
	bridge.client.mu.Unlock()
	bridge.connectionGeneration = 1

	handlerStarted := make(chan struct{})
	handlerReturned := make(chan struct{})
	releaseHandler := make(chan struct{})
	var writes atomic.Int64
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway", func(_ context.Context, method string, _ json.RawMessage) (any, error) {
		if method == "thread-follower-load-complete-history" {
			return map[string]any{"revision": 1}, nil
		}
		writes.Add(1)
		if writes.Load() == 1 {
			close(handlerStarted)
			<-releaseHandler
			close(handlerReturned)
		}
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	params := json.RawMessage(`{"conversationId":"thread-local"}`)
	discovery := IncomingRequest{
		RequestID: json.RawMessage(`"discovery-1"`), Method: "thread-owner-discovery", Version: 1,
		SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}
	if !bridge.canHandleIncoming(discovery) {
		bridge.mu.RLock()
		owner := bridge.owners["thread-local"]
		bridgeGeneration := bridge.connectionGeneration
		bridge.mu.RUnlock()
		t.Fatalf("test follower discovery was not routable: status=%s clientGeneration=%d bridgeGeneration=%d owner=%#v",
			bridge.Status().State, bridge.client.ConnectionGeneration(), bridgeGeneration, owner)
	}
	go bridge.client.handleIncomingRequest(clientConn, envelope{
		Type: "request", RequestID: json.RawMessage(`"request-1"`),
		Method: "thread-follower-start-turn", Version: 2,
		SourceClientID: "desktop-a", Params: params,
	})
	select {
	case <-handlerStarted:
	case <-time.After(time.Second):
		t.Fatal("follower handler did not start")
	}
	close(releaseHandler)
	select {
	case <-handlerReturned:
	case <-time.After(time.Second):
		t.Fatal("follower handler did not return")
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err == nil {
		t.Fatal("local write was allowed before the Desktop response was delivered")
	}
	if writes.Load() != 1 {
		t.Fatalf("concurrent local write reached the App Server: %d", writes.Load())
	}
	_ = serverConn.Close()
	deadline := time.Now().Add(time.Second)
	for {
		bridge.mu.RLock()
		uncertain := bridge.localUncertain["thread-local"]
		_, inFlight := bridge.localInFlight["thread-local"]
		bridge.mu.RUnlock()
		if uncertain && !inFlight {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("failed IPC response did not leave the local owner uncertain")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err == nil {
		t.Fatal("a second write was allowed after the first response failed")
	}
	if writes.Load() != 1 {
		t.Fatalf("uncertain request reached the App Server more than once: %d", writes.Load())
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-load-complete-history", map[string]any{
		"conversationId": "thread-local",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err != nil {
		t.Fatalf("complete history did not reopen the local owner: %v", err)
	}
	if writes.Load() != 2 {
		t.Fatalf("write did not resume exactly once after recovery: %d", writes.Load())
	}
}

func TestBridgeClearsLocalUncertaintyOnlyAfterHistoryResponseIsSent(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	clientConn, serverConn := net.Pipe()
	connectionCtx, connectionCancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		connectionCancel()
		_ = clientConn.Close()
		_ = serverConn.Close()
	})
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.client.mu.Lock()
	bridge.client.conn = clientConn
	bridge.client.clientID = "mimi-client"
	bridge.client.generation = 1
	bridge.client.connectionCtx = connectionCtx
	bridge.client.connectionCancel = connectionCancel
	bridge.client.mu.Unlock()
	bridge.connectionGeneration = 1

	historyReturned := make(chan struct{})
	var writes atomic.Int64
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway", func(_ context.Context, method string, _ json.RawMessage) (any, error) {
		if method == "thread-follower-load-complete-history" {
			close(historyReturned)
			return map[string]any{"revision": 1}, nil
		}
		writes.Add(1)
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	bridge.localUncertain["thread-local"] = true
	bridge.mu.Unlock()
	params := json.RawMessage(`{"conversationId":"thread-local"}`)
	go bridge.client.handleIncomingRequest(clientConn, envelope{
		Type: "request", RequestID: json.RawMessage(`"history-1"`),
		Method: "thread-follower-load-complete-history", Version: 1,
		SourceClientID: "desktop-a", Params: params,
	})
	select {
	case <-historyReturned:
	case <-time.After(time.Second):
		t.Fatal("complete-history handler did not return")
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err == nil {
		t.Fatal("local write was allowed before the history response reached Desktop")
	}
	if writes.Load() != 0 {
		t.Fatalf("blocked local write reached the App Server: %d", writes.Load())
	}
	readDone := make(chan error, 1)
	go func() {
		_, readErr := ReadFrame(serverConn)
		readDone <- readErr
	}()
	select {
	case readErr := <-readDone:
		if readErr != nil {
			t.Fatal(readErr)
		}
	case <-time.After(time.Second):
		t.Fatal("complete-history response was not written")
	}
	deadline := time.Now().Add(time.Second)
	for {
		bridge.mu.RLock()
		uncertain := bridge.localUncertain["thread-local"]
		_, inFlight := bridge.localInFlight["thread-local"]
		bridge.mu.RUnlock()
		if !uncertain && !inFlight {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("successful history response did not clear local uncertainty")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err != nil {
		t.Fatalf("local write did not resume after history response delivery: %v", err)
	}
	if writes.Load() != 1 {
		t.Fatalf("local write resumed an unexpected number of times: %d", writes.Load())
	}
}

func TestBridgeKeepsLocalUncertaintyWhenHistoryResponseWriteFails(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	clientConn, serverConn := net.Pipe()
	connectionCtx, connectionCancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		connectionCancel()
		_ = clientConn.Close()
		_ = serverConn.Close()
	})
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.client.mu.Lock()
	bridge.client.conn = clientConn
	bridge.client.clientID = "mimi-client"
	bridge.client.generation = 1
	bridge.client.connectionCtx = connectionCtx
	bridge.client.connectionCancel = connectionCancel
	bridge.client.mu.Unlock()
	bridge.connectionGeneration = 1

	historyReturned := make(chan struct{})
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway", func(_ context.Context, method string, _ json.RawMessage) (any, error) {
		if method == "thread-follower-load-complete-history" {
			close(historyReturned)
			return map[string]any{"revision": 1}, nil
		}
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	bridge.localUncertain["thread-local"] = true
	bridge.mu.Unlock()
	params := json.RawMessage(`{"conversationId":"thread-local"}`)
	go bridge.client.handleIncomingRequest(clientConn, envelope{
		Type: "request", RequestID: json.RawMessage(`"history-1"`),
		Method: "thread-follower-load-complete-history", Version: 1,
		SourceClientID: "desktop-a", Params: params,
	})
	select {
	case <-historyReturned:
	case <-time.After(time.Second):
		t.Fatal("complete-history handler did not return")
	}
	_ = serverConn.Close()
	deadline := time.Now().Add(time.Second)
	for {
		bridge.mu.RLock()
		uncertain := bridge.localUncertain["thread-local"]
		_, inFlight := bridge.localInFlight["thread-local"]
		bridge.mu.RUnlock()
		if uncertain && !inFlight {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("failed history response did not preserve local uncertainty")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err == nil {
		t.Fatal("local write was allowed after the history response failed")
	}
}

func TestBridgePreservesLocalUncertaintyAcrossOwnerRelease(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway-old", func(context.Context, string, json.RawMessage) (any, error) {
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	bridge.localInFlight["thread-local"] = localRequestInFlight{requestID: "old-request"}
	bridge.mu.Unlock()
	bridge.ReleaseLocalOwner("thread-local", "gateway-old")
	var writes atomic.Int64
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway-new", func(_ context.Context, method string, _ json.RawMessage) (any, error) {
		if method == "thread-follower-load-complete-history" {
			return map[string]any{"revision": 1}, nil
		}
		writes.Add(1)
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err == nil {
		t.Fatal("replacement owner wrote before recovering uncertain history")
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-load-complete-history", map[string]any{
		"conversationId": "thread-local",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err != nil {
		t.Fatalf("replacement owner did not resume after history recovery: %v", err)
	}
	if writes.Load() != 1 {
		t.Fatalf("replacement owner wrote an unexpected number of times: %d", writes.Load())
	}
}

func TestBridgeBlocksDesktopWritesUntilCompleteHistoryConfirmsUncertainDelivery(t *testing.T) {
	fake := &fakeDesktopIPC{}
	var steerRequests atomic.Int64
	var interruptRequests atomic.Int64
	fake.respond = func(conn net.Conn, request envelope) {
		switch request.Method {
		case "thread-follower-steer-turn":
			if steerRequests.Add(1) == 1 {
				return
			}
			writeTestEnvelope(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "handledByClientId": "desktop-owner", "result": map[string]any{},
			})
		case "thread-follower-interrupt-turn":
			interruptRequests.Add(1)
		case "thread-follower-load-complete-history":
			writeTestEnvelope(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{
					"conversationId": "thread-desktop",
					"change": map[string]any{
						"type": "snapshot", "revision": 2,
						"conversationState": map[string]any{"title": "recovered", "turns": []any{}},
					},
				},
			})
			writeTestEnvelope(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "handledByClientId": "desktop-owner",
				"result": map[string]any{"revision": 2},
			})
		}
	}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
			RequestTimeout: 40 * time.Millisecond, ReconnectDelay: time.Hour,
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
	initial, _ := json.Marshal(map[string]any{
		"conversationId": "thread-desktop",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "initial", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11,
		SourceClientID: "desktop-owner", Params: initial,
	})
	_, err = bridge.RequestDesktopOwner(context.Background(), "thread-follower-steer-turn", map[string]any{
		"conversationId": "thread-desktop", "input": []any{},
	})
	var requestErr *RequestError
	if !errors.As(err, &requestErr) || requestErr.Delivery != DeliveryUncertain {
		t.Fatalf("first timed-out Desktop write was not uncertain: %v", err)
	}
	_, err = bridge.RequestDesktopOwner(context.Background(), "thread-follower-interrupt-turn", map[string]any{
		"conversationId": "thread-desktop",
	})
	if !errors.Is(err, ErrDesktopDeliveryUncertain) {
		t.Fatalf("later Desktop write was not blocked by uncertainty: %v", err)
	}
	if interruptRequests.Load() != 0 {
		t.Fatalf("blocked Desktop write reached IPC: %d", interruptRequests.Load())
	}
	history, err := bridge.RequestDesktopOwner(context.Background(), "thread-follower-load-complete-history", map[string]any{
		"conversationId": "thread-desktop",
	})
	if err != nil {
		t.Fatal(err)
	}
	revision, ok := completeHistoryRevision(history)
	if !ok {
		t.Fatalf("invalid complete-history response: %s", history)
	}
	waitCtx, waitCancel := context.WithTimeout(context.Background(), time.Second)
	_, projected := bridge.WaitDesktopProjectionRevision(waitCtx, "thread-desktop", revision)
	waitCancel()
	if !projected || !bridge.ConfirmDesktopHistory("thread-desktop", revision) {
		t.Fatal("authoritative complete history did not clear Desktop uncertainty")
	}
	if _, err := bridge.RequestDesktopOwner(context.Background(), "thread-follower-steer-turn", map[string]any{
		"conversationId": "thread-desktop", "input": []any{},
	}); err != nil {
		t.Fatalf("Desktop write did not resume after recovery: %v", err)
	}
	if steerRequests.Load() != 2 {
		t.Fatalf("unexpected Desktop steer deliveries: %d", steerRequests.Load())
	}
}

func TestBridgeRejectsHistoryResponseStartedBeforeUncertainDesktopWrite(t *testing.T) {
	fake := &fakeDesktopIPC{}
	historyStarted := make(chan struct{})
	releaseHistory := make(chan struct{})
	fake.respond = func(conn net.Conn, request envelope) {
		switch request.Method {
		case "thread-follower-load-complete-history":
			writeTestEnvelope(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{
					"conversationId": "thread-history-race",
					"change": map[string]any{
						"type": "snapshot", "revision": 2,
						"conversationState": map[string]any{"title": "before-start", "turns": []any{}},
					},
				},
			})
			close(historyStarted)
			go func() {
				<-releaseHistory
				writeTestEnvelope(conn, map[string]any{
					"type": "response", "requestId": json.RawMessage(request.RequestID),
					"resultType": "success", "handledByClientId": "desktop-owner",
					"result": map[string]any{"revision": 2},
				})
			}()
		case "thread-follower-start-turn":
			// Force an uncertain start while the older history response is delayed.
			return
		}
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
	initial, _ := json.Marshal(map[string]any{
		"conversationId": "thread-history-race",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "initial", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11,
		SourceClientID: "desktop-owner", Params: initial,
	})
	historyResult := make(chan error, 1)
	go func() {
		_, requestErr := bridge.RequestDesktopOwner(context.Background(), "thread-follower-load-complete-history", map[string]any{
			"conversationId": "thread-history-race",
		})
		historyResult <- requestErr
	}()
	select {
	case <-historyStarted:
	case <-time.After(time.Second):
		t.Fatal("older complete-history request did not start")
	}
	startCtx, startCancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	_, err = bridge.RequestDesktopOwner(startCtx, "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-history-race",
	})
	startCancel()
	var requestErr *RequestError
	if !errors.As(err, &requestErr) || requestErr.Delivery != DeliveryUncertain {
		t.Fatalf("start fixture was not uncertain: %v", err)
	}
	close(releaseHistory)
	if err := <-historyResult; err != nil {
		t.Fatalf("older history request failed unexpectedly: %v", err)
	}
	if bridge.ConfirmDesktopHistory("thread-history-race", 2) {
		t.Fatal("history started before the uncertain start was accepted as recovery")
	}
	if _, err := bridge.RequestDesktopOwner(context.Background(), "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-history-race",
	}); !errors.Is(err, ErrDesktopDeliveryUncertain) {
		t.Fatalf("older history response reopened Desktop writes: %v", err)
	}
}

func TestBridgeKeepsDesktopUncertaintyAndStartReservationAcrossReconnect(t *testing.T) {
	fake := &fakeDesktopIPC{}
	fake.respond = func(conn net.Conn, request envelope) {
		switch request.Method {
		case "thread-owner-discovery":
			writeTestEnvelope(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "error", "error": "no-client-found",
			})
		case "thread-follower-start-turn":
			return
		case "thread-follower-load-complete-history":
			writeTestEnvelope(conn, map[string]any{
				"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
				"sourceClientId": "desktop-owner",
				"params": map[string]any{
					"conversationId": "thread-reconnect",
					"change": map[string]any{
						"type": "snapshot", "revision": 2,
						"conversationState": map[string]any{"title": "recovered", "turns": []any{}},
					},
				},
			})
			writeTestEnvelope(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "handledByClientId": "desktop-owner",
				"result": map[string]any{"revision": 2},
			})
		case "thread-follower-update-thread-settings":
			writeTestEnvelope(conn, map[string]any{
				"type": "response", "requestId": json.RawMessage(request.RequestID),
				"resultType": "success", "handledByClientId": "desktop-owner", "result": map[string]any{},
			})
		}
	}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ClientOptions: ClientOptions{
			DialContext: fake.dial, VerifySocket: func(string) error { return nil }, VerifyPeer: supportedTestPeer,
			RequestTimeout: time.Second, ReconnectDelay: 5 * time.Millisecond,
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
	initial, _ := json.Marshal(map[string]any{
		"conversationId": "thread-reconnect",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "initial", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11,
		SourceClientID: "desktop-owner", Params: initial,
	})
	startCtx, startCancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	_, err = bridge.RequestDesktopOwner(startCtx, "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-reconnect",
	})
	startCancel()
	if err == nil {
		t.Fatal("start fixture unexpectedly succeeded")
	}
	fake.mu.Lock()
	if len(fake.listeners) == 0 {
		fake.mu.Unlock()
		t.Fatal("fake Desktop connection is missing")
	}
	firstServer := fake.listeners[0]
	fake.mu.Unlock()
	_ = firstServer.Close()
	deadline := time.Now().Add(time.Second)
	for bridge.client.ConnectionGeneration() < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if bridge.client.ConnectionGeneration() < 2 {
		t.Fatal("Desktop IPC did not reconnect")
	}
	if owned, err := bridge.DiscoverDesktopOwner(context.Background(), "thread-reconnect"); owned ||
		!errors.Is(err, ErrDesktopDeliveryUncertain) {
		t.Fatalf("new-generation no-client incorrectly cleared old uncertain delivery: owned=%t err=%v", owned, err)
	}
	ordinary, _ := json.Marshal(map[string]any{
		"conversationId": "thread-reconnect",
		"change": map[string]any{
			"type": "snapshot", "revision": 1,
			"conversationState": map[string]any{"title": "ordinary-reconnect", "turns": []any{}},
		},
	})
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-state-changed", Version: 11,
		SourceClientID: "desktop-owner", Params: ordinary,
	})
	if _, err := bridge.RequestDesktopOwner(context.Background(), "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-reconnect",
	}); !errors.Is(err, ErrDesktopDeliveryUncertain) {
		t.Fatalf("ordinary reconnect snapshot reopened writes before history: %v", err)
	}
	history, err := bridge.RequestDesktopOwner(context.Background(), "thread-follower-load-complete-history", map[string]any{
		"conversationId": "thread-reconnect",
	})
	if err != nil {
		t.Fatal(err)
	}
	revision, ok := completeHistoryRevision(history)
	if !ok {
		t.Fatalf("invalid complete-history response: %s", history)
	}
	waitCtx, waitCancel := context.WithTimeout(context.Background(), time.Second)
	_, projected := bridge.WaitDesktopProjectionRevision(waitCtx, "thread-reconnect", revision)
	waitCancel()
	if !projected || !bridge.ConfirmDesktopHistory("thread-reconnect", revision) {
		t.Fatal("reconnect complete history did not recover the Desktop owner")
	}
	if _, err := bridge.RequestDesktopOwner(context.Background(), "thread-follower-update-thread-settings", map[string]any{
		"conversationId": "thread-reconnect", "threadSettings": map[string]any{},
	}); err != nil {
		t.Fatalf("writes did not resume after reconnect recovery: %v", err)
	}
}

func TestBridgeRejectsDesktopStartWithoutAuthoritativeProjection(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.connectionGeneration = 1
	bridge.client.mu.Lock()
	bridge.client.generation = 1
	bridge.client.mu.Unlock()
	bridge.mu.Lock()
	bridge.setOwnerLocked("thread-missing", threadOwner{
		kind: threadOwnerDesktop, ownerID: "desktop-owner", connectionGeneration: 1,
	})
	bridge.mu.Unlock()

	_, err = bridge.RequestDesktopTurnStart(
		context.Background(),
		map[string]any{"conversationId": "thread-missing", "threadSettings": map[string]any{}},
		map[string]any{"conversationId": "thread-missing"},
	)
	var requestErr *RequestError
	if !errors.As(err, &requestErr) || requestErr.Delivery != DeliveryNotSent ||
		!strings.Contains(requestErr.Error(), "snapshot") {
		t.Fatalf("start without an authoritative snapshot was not rejected before delivery: %v", err)
	}
}

func TestBridgeRequestLocalOwnerHonorsUncertainGate(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.connectionGeneration = 1
	bridge.client.mu.Lock()
	bridge.client.generation = 1
	bridge.client.mu.Unlock()
	var calls int
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway-a", func(_ context.Context, method string, _ json.RawMessage) (any, error) {
		calls++
		if method == "thread-follower-load-complete-history" {
			return map[string]any{"revision": 1}, nil
		}
		return map[string]any{}, nil
	}); err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	bridge.localUncertain["thread-local"] = true
	bridge.mu.Unlock()
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err == nil {
		t.Fatal("mobile local-owner path bypassed the uncertain-delivery gate")
	}
	if calls != 0 {
		t.Fatalf("blocked local-owner request reached the handler: %d", calls)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-load-complete-history", map[string]any{
		"conversationId": "thread-local",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-local",
	}); err != nil {
		t.Fatalf("authoritative history did not reopen the local owner: %v", err)
	}
	if calls != 2 {
		t.Fatalf("unexpected local owner handler calls: %d", calls)
	}
}

func TestBridgeSessionLossFenceWinsAfterConcurrentHistory(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.connectionGeneration = 1
	bridge.client.mu.Lock()
	bridge.client.generation = 1
	bridge.client.mu.Unlock()
	historyEntered := make(chan struct{})
	releaseHistory := make(chan struct{})
	if err := bridge.ClaimNewLocalOwner("thread-recovery-race", "agentd-owner", func(
		_ context.Context, method string, _ json.RawMessage,
	) (any, error) {
		if method == "thread-follower-load-complete-history" {
			close(historyEntered)
			<-releaseHistory
		}
		return map[string]any{"revision": 1}, nil
	}); err != nil {
		t.Fatal(err)
	}
	params := json.RawMessage(`{"conversationId":"thread-recovery-race"}`)
	discoveryVersion, _ := MethodVersion("thread-owner-discovery")
	if _, err := bridge.handleIncoming(context.Background(), IncomingRequest{
		Method: "thread-owner-discovery", Version: discoveryVersion, SourceClientID: "desktop-a",
		ConnectionGeneration: 1, Params: params,
	}); err != nil {
		t.Fatal(err)
	}
	bridge.MarkLocalOwnerRecoveryRequired("thread-recovery-race", "agentd-owner")
	historyVersion, _ := MethodVersion("thread-follower-load-complete-history")
	history := IncomingRequest{
		RequestID: json.RawMessage(`"history-race"`), Method: "thread-follower-load-complete-history",
		Version: historyVersion, SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}
	historyDone := make(chan error, 1)
	go func() {
		_, requestErr := bridge.handleIncoming(context.Background(), history)
		historyDone <- requestErr
	}()
	<-historyEntered
	markDone := make(chan struct{})
	go func() {
		bridge.MarkLocalOwnerRecoveryRequired("thread-recovery-race", "agentd-owner")
		close(markDone)
	}()
	select {
	case <-markDone:
	case <-time.After(time.Second):
		t.Fatal("session-loss fence waited for the in-flight history operation")
	}
	close(releaseHistory)
	if err := <-historyDone; err != nil {
		t.Fatal(err)
	}
	bridge.handleIncomingResponse(history, nil)
	if !bridge.LocalOwnerNeedsRecovery("thread-recovery-race") {
		t.Fatal("successful stale history incorrectly cleared the later session-loss fence")
	}
}

func TestBridgeStaleHistoryResponseCannotClearNewSessionLossFence(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.connectionGeneration = 1
	bridge.client.mu.Lock()
	bridge.client.generation = 1
	bridge.client.mu.Unlock()
	if err := bridge.ClaimNewLocalOwner("thread-response-race", "agentd-owner", func(
		_ context.Context, _ string, _ json.RawMessage,
	) (any, error) {
		return map[string]any{"revision": 1}, nil
	}); err != nil {
		t.Fatal(err)
	}
	params := json.RawMessage(`{"conversationId":"thread-response-race"}`)
	discoveryVersion, _ := MethodVersion("thread-owner-discovery")
	if _, err := bridge.handleIncoming(context.Background(), IncomingRequest{
		Method: "thread-owner-discovery", Version: discoveryVersion, SourceClientID: "desktop-a",
		ConnectionGeneration: 1, Params: params,
	}); err != nil {
		t.Fatal(err)
	}
	bridge.MarkLocalOwnerRecoveryRequired("thread-response-race", "agentd-owner")
	historyVersion, _ := MethodVersion("thread-follower-load-complete-history")
	history := IncomingRequest{
		RequestID: json.RawMessage(`"history-old"`), Method: "thread-follower-load-complete-history",
		Version: historyVersion, SourceClientID: "desktop-a", ConnectionGeneration: 1, Params: params,
	}
	if _, err := bridge.handleIncoming(context.Background(), history); err != nil {
		t.Fatal(err)
	}
	// The App Server session disappears after history was prepared but before
	// the Desktop response is written. That newer fence must win.
	bridge.MarkLocalOwnerRecoveryRequired("thread-response-race", "agentd-owner")
	bridge.handleIncomingResponse(history, nil)
	if !bridge.LocalOwnerNeedsRecovery("thread-response-race") {
		t.Fatal("stale complete-history response cleared a newer session-loss fence")
	}
	history.RequestID = json.RawMessage(`"history-new"`)
	if _, err := bridge.handleIncoming(context.Background(), history); err != nil {
		t.Fatal(err)
	}
	bridge.handleIncomingResponse(history, nil)
	if bridge.LocalOwnerNeedsRecovery("thread-response-race") {
		t.Fatal("fresh complete-history response did not clear its own recovery fence")
	}
}

func TestBridgeReservesLocalTurnStartUntilProjectedTerminalState(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	var calls int
	if err := bridge.ClaimNewLocalOwner("thread-local-start", "agentd-owner", func(_ context.Context, method string, _ json.RawMessage) (any, error) {
		if method != "thread-follower-start-turn" {
			return map[string]any{}, nil
		}
		calls++
		return map[string]any{"result": map[string]any{
			"turn": map[string]any{"id": fmt.Sprintf("turn-%d", calls)},
		}}, nil
	}); err != nil {
		t.Fatal(err)
	}
	params := map[string]any{"conversationId": "thread-local-start"}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local-start", "thread-follower-start-turn", params); err != nil {
		t.Fatal(err)
	}
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local-start", "thread-follower-start-turn", params); !errors.Is(err, ErrDesktopStartInFlight) {
		t.Fatalf("second start crossed the ACK-to-projection reservation: %v", err)
	}
	_ = bridge.PublishLocalConversation("thread-local-start", "agentd-owner", map[string]any{
		"id": "thread-local-start", "turns": []any{map[string]any{
			"id": "turn-1", "status": "completed", "items": []any{},
		}},
	})
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-local-start", "thread-follower-start-turn", params); err != nil {
		t.Fatalf("terminal projection did not release the start reservation: %v", err)
	}
	if calls != 2 {
		t.Fatalf("unexpected handler calls: %d", calls)
	}
}

func TestBridgeRejectedIncomingStartDoesNotLeakReservation(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.client.status.update(func(status *Status) { status.State = StateReady })
	bridge.connectionGeneration = 1
	bridge.client.mu.Lock()
	bridge.client.generation = 1
	bridge.client.mu.Unlock()
	if err := bridge.ClaimNewLocalOwner("thread-pending-response", "agentd-owner", func(
		_ context.Context, _ string, _ json.RawMessage,
	) (any, error) {
		return map[string]any{"turn": map[string]any{"id": "turn-after-pending"}}, nil
	}); err != nil {
		t.Fatal(err)
	}
	params := json.RawMessage(`{"conversationId":"thread-pending-response"}`)
	discovery := IncomingRequest{
		Method: "thread-owner-discovery", Version: 1, SourceClientID: "desktop-a",
		ConnectionGeneration: 1, Params: params,
	}
	if _, err := bridge.handleIncoming(context.Background(), discovery); err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	bridge.localInFlight["thread-pending-response"] = localRequestInFlight{
		requestID: "s:previous", ownerID: "agentd-owner", ownerEpoch: bridge.ownerEpochs["thread-pending-response"],
		connectionGeneration: 1,
	}
	bridge.mu.Unlock()
	start := IncomingRequest{
		Method: "thread-follower-start-turn", Version: 2, SourceClientID: "desktop-a",
		ConnectionGeneration: 1, Params: params,
	}
	if _, err := bridge.handleIncoming(context.Background(), start); err == nil {
		t.Fatal("incoming start bypassed the pending response fence")
	}
	bridge.mu.Lock()
	delete(bridge.localInFlight, "thread-pending-response")
	bridge.mu.Unlock()
	if _, err := bridge.RequestLocalOwner(context.Background(), "thread-pending-response", "thread-follower-start-turn", map[string]any{
		"conversationId": "thread-pending-response",
	}); err != nil {
		t.Fatalf("rejected incoming start leaked its reservation: %v", err)
	}
}

func TestBridgeRejectsProjectionFromReleasedOwner(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway-a", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	bridge.ReleaseLocalOwner("thread-local", "gateway-a")
	if err := bridge.ClaimNewLocalOwner("thread-local", "gateway-b", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation("thread-local", "gateway-b", map[string]any{"title": "owner-b", "turns": []any{}}); err == nil {
		t.Fatal("offline test publish unexpectedly reached Desktop")
	}
	if err := bridge.PublishLocalConversation("thread-local", "gateway-a", map[string]any{"title": "stale-a", "turns": []any{}}); err == nil {
		t.Fatal("released owner was allowed to publish a stale projection")
	}
	projection, ok := bridge.LocalProjection("thread-local")
	if !ok || projection.Thread["title"] != "owner-b" {
		t.Fatalf("released owner changed the current projection: %#v", projection)
	}
}

func TestBridgeNoClientCannotClearDesktopRecoveryBarriers(t *testing.T) {
	for _, test := range []struct {
		name  string
		block func(*Bridge)
	}{
		{
			name: "start reservation",
			block: func(bridge *Bridge) {
				bridge.desktopStarts["thread-barrier"] = desktopStartReservation{token: 1}
			},
		},
		{
			name: "revision resync",
			block: func(bridge *Bridge) {
				bridge.resyncing["thread-barrier"] = 1
			},
		},
		{
			name: "active projection",
			block: func(bridge *Bridge) {
				bridge.projections["thread-barrier"] = Projection{ActiveTurnID: "turn-active"}
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			bridge, err := NewBridge(BridgeOptions{})
			if err != nil {
				t.Fatal(err)
			}
			bridge.connectionGeneration = 1
			bridge.mu.Lock()
			bridge.setOwnerLocked("thread-barrier", threadOwner{
				kind: threadOwnerDesktop, ownerID: "desktop-owner", connectionGeneration: 1,
			})
			test.block(bridge)
			owner := bridge.owners["thread-barrier"]
			ownerEpoch := bridge.ownerEpochs["thread-barrier"]
			bridge.mu.Unlock()

			bridge.recordDesktopRequestOutcome(
				"thread-barrier", owner, ownerEpoch, "thread-follower-compact-thread",
				&RequestError{Method: "thread-follower-compact-thread", Delivery: DeliveryNoClient},
			)
			bridge.mu.RLock()
			current := bridge.owners["thread-barrier"]
			_, permitted := bridge.localClaimPermits["thread-barrier"]
			bridge.mu.RUnlock()
			if current.kind != threadOwnerDesktop || permitted {
				t.Fatalf("no-client cleared a live recovery barrier: owner=%#v permit=%t", current, permitted)
			}
			if err := bridge.ClaimPermittedLocalOwner(
				"thread-barrier", "gateway", func(context.Context, string, json.RawMessage) (any, error) { return nil, nil },
			); err == nil {
				t.Fatal("blocked no-client unexpectedly produced a local claim permit")
			}
		})
	}
}

func TestBridgeRejectsLocalClaimWhileDesktopDeliveryIsUncertain(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	bridge.desktopUncertain["thread-uncertain"] = true
	bridge.mu.Unlock()

	err = bridge.ClaimNewLocalOwner(
		"thread-uncertain", "gateway", func(context.Context, string, json.RawMessage) (any, error) { return nil, nil },
	)
	if !errors.Is(err, ErrDesktopDeliveryUncertain) || bridge.HasLocalOwner("thread-uncertain") {
		t.Fatalf("Desktop uncertainty was bypassed by a local claim: err=%v", err)
	}
}

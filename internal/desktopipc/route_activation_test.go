package desktopipc

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestActivateLocalThreadBindsDesktopFollowerAndForcesSnapshot(t *testing.T) {
	fake := &fakeDesktopIPC{}
	var bridge *Bridge
	var activations atomic.Int32
	activated := make(chan string, 1)
	activator := func(_ context.Context, threadID, nonce string) error {
		activations.Add(1)
		params, _ := json.Marshal(map[string]any{
			"conversationId": threadID,
			"following":      true,
		})
		bridge.handleBroadcast(Broadcast{
			Method: "thread-stream-following-changed", Version: 1,
			SourceClientID: "desktop-renderer", ConnectionGeneration: bridge.client.ConnectionGeneration(), Params: params,
		})
		activated <- nonce
		return nil
	}
	var err error
	bridge, err = NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ActivateDesktopThread: activator,
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

	const threadID = "thread-local-follow"
	if err := bridge.ClaimNewLocalOwner(threadID, "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	rolloutPath := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(rolloutPath, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{
		"title": "Before", "rolloutPath": rolloutPath, "turns": []any{},
	}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{
		"title": "After", "rolloutPath": rolloutPath, "turns": []any{},
	}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.ActivateNewLocalThread(threadID, "gateway-1"); err != nil {
		t.Fatal(err)
	}
	// A duplicate lifecycle signal must reuse the pending activation.
	if err := bridge.ActivateNewLocalThread(threadID, "gateway-1"); err != nil {
		t.Fatal(err)
	}
	select {
	case nonce := <-activated:
		if nonce == "" {
			t.Fatal("Desktop activation nonce is empty")
		}
	case <-time.After(time.Second):
		t.Fatal("Desktop route was not activated")
	}

	deadline := time.Now().Add(time.Second)
	var changes []StreamChange
	for time.Now().Before(deadline) {
		changes = localStreamChanges(fake.requestsSnapshot(), threadID)
		if len(changes) >= 3 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(changes) != 3 {
		t.Fatalf("expected snapshot, patch, forced snapshot; got %#v", changes)
	}
	if changes[0].Type != "snapshot" || changes[0].Revision != 1 ||
		changes[1].Type != "patches" || changes[1].Revision != 2 ||
		changes[2].Type != "snapshot" || changes[2].Revision != 3 {
		t.Fatalf("unexpected revision sequence: %#v", changes)
	}
	if got := stringValue(changes[2].ConversationState["title"]); got != "After" {
		t.Fatalf("forced snapshot rolled back the latest state: %q", got)
	}
	if got := activations.Load(); got != 1 {
		t.Fatalf("expected one Desktop activation, got %d", got)
	}
	bridge.mu.RLock()
	followerID := bridge.owners[threadID].followerClientID
	bridge.mu.RUnlock()
	if followerID != "desktop-renderer" {
		t.Fatalf("Desktop follower was not bound: %q", followerID)
	}
}

func TestDesktopFollowNonceIsUniqueAcrossAttempts(t *testing.T) {
	first := desktopFollowNonce(1, 1)
	second := desktopFollowNonce(1, 2)
	third := desktopFollowNonce(2, 1)
	if first == "" || first == second || first == third || second == third {
		t.Fatalf("Desktop follow nonces are not unique: %q %q %q", first, second, third)
	}
}

func TestExistingActivationUpgradesMaterializationWaitAndRequiresFollowingConfirmation(t *testing.T) {
	fake := &fakeDesktopIPC{}
	var bridge *Bridge
	activated := make(chan struct{}, 1)
	activator := func(_ context.Context, threadID, _ string) error {
		params, _ := json.Marshal(map[string]any{"conversationId": threadID, "following": true})
		bridge.handleBroadcast(Broadcast{
			Method: "thread-stream-following-changed", Version: 1,
			SourceClientID: "desktop-renderer", ConnectionGeneration: bridge.client.ConnectionGeneration(), Params: params,
		})
		activated <- struct{}{}
		return nil
	}
	var err error
	bridge, err = NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ActivateDesktopThread: activator,
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

	const threadID = "thread-existing-follow"
	if err := bridge.ClaimNewLocalOwner(threadID, "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{
		"title": "Existing", "turns": []any{},
	}); err != nil {
		t.Fatal(err)
	}
	bridge.mu.Lock()
	if !bridge.bindFollowerClientLocked(threadID, "thread-owner-discovery", "desktop-renderer") {
		bridge.mu.Unlock()
		t.Fatal("Desktop discovery did not bind the request route")
	}
	if bridge.owners[threadID].confirmedFollowerID != "" {
		bridge.mu.Unlock()
		t.Fatal("Desktop discovery incorrectly confirmed route activation")
	}
	bridge.mu.Unlock()

	started := time.Now()
	if err := bridge.ActivateNewLocalThread(threadID, "gateway-1"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := bridge.ActivateLocalThread(threadID, "gateway-1"); err != nil {
		t.Fatal(err)
	}
	select {
	case <-activated:
		if elapsed := time.Since(started); elapsed >= time.Second {
			t.Fatalf("existing Thread still waited for materialization: %s", elapsed)
		}
	case <-time.After(time.Second):
		t.Fatal("existing Thread route was not activated")
	}
}

func TestReadyActivatesOnlyLatestLocalRouteIntent(t *testing.T) {
	fake := &fakeDesktopIPC{}
	var bridge *Bridge
	activated := make(chan string, 2)
	activator := func(_ context.Context, threadID, _ string) error {
		params, _ := json.Marshal(map[string]any{"conversationId": threadID, "following": true})
		bridge.handleBroadcast(Broadcast{
			Method: "thread-stream-following-changed", Version: 1,
			SourceClientID: "desktop-renderer", ConnectionGeneration: bridge.client.ConnectionGeneration(), Params: params,
		})
		activated <- threadID
		return nil
	}
	var err error
	bridge, err = NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ActivateDesktopThread: activator,
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

	for _, threadID := range []string{"thread-old-intent", "thread-latest-intent"} {
		if err := bridge.ClaimNewLocalOwner(threadID, "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
			return nil, nil
		}); err != nil {
			t.Fatal(err)
		}
		if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{
			"title": threadID, "turns": []any{},
		}); err != nil {
			t.Fatal(err)
		}
	}
	bridge.mu.Lock()
	bridge.connectionGeneration = 0
	bridge.mu.Unlock()
	if err := bridge.ActivateLocalThread("thread-old-intent", "gateway-1"); err != nil {
		t.Fatal(err)
	}
	bridge.mu.RLock()
	staleIntent := bridge.latestLocalFollowIntent
	bridge.mu.RUnlock()
	if err := bridge.ActivateLocalThread("thread-latest-intent", "gateway-1"); err != nil {
		t.Fatal(err)
	}
	generation := bridge.client.ConnectionGeneration()
	bridge.mu.Lock()
	bridge.connectionGeneration = generation
	bridge.refollow["thread-blocking-desktop-recovery"] = struct{}{}
	_, staleStarted := bridge.startLocalFollowActivationLocked(staleIntent, generation)
	bridge.mu.Unlock()
	if staleStarted {
		t.Fatal("captured stale intent replaced the latest Desktop route")
	}

	bridge.handleReady(generation)
	select {
	case threadID := <-activated:
		if threadID != "thread-latest-intent" {
			t.Fatalf("ready mounted stale route %q", threadID)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("slow Desktop-owned recovery delayed the latest local route")
	}
	select {
	case threadID := <-activated:
		t.Fatalf("ready mounted more than one route: %q", threadID)
	case <-time.After(250 * time.Millisecond):
	}
}

func TestLocalRouteDispatchIsSerializedAndLatestIntentWins(t *testing.T) {
	fake := &fakeDesktopIPC{}
	entered := make(chan string, 2)
	releaseFirst := make(chan struct{}, 1)
	t.Cleanup(func() {
		select {
		case releaseFirst <- struct{}{}:
		default:
		}
	})
	var active atomic.Int32
	var maxActive atomic.Int32
	var bridge *Bridge
	activator := func(_ context.Context, threadID, _ string) error {
		current := active.Add(1)
		defer active.Add(-1)
		for {
			maximum := maxActive.Load()
			if current <= maximum || maxActive.CompareAndSwap(maximum, current) {
				break
			}
		}
		entered <- threadID
		if threadID == "thread-route-a" {
			<-releaseFirst
			return nil
		}
		params, _ := json.Marshal(map[string]any{"conversationId": threadID, "following": true})
		bridge.handleBroadcast(Broadcast{
			Method: "thread-stream-following-changed", Version: 1,
			SourceClientID: "desktop-renderer", ConnectionGeneration: bridge.client.ConnectionGeneration(), Params: params,
		})
		return nil
	}
	var err error
	bridge, err = NewBridge(BridgeOptions{
		Enabled: true, SocketPath: "test", DesktopVersion: SupportedVersion, DesktopBuild: SupportedBuild,
		ActivateDesktopThread: activator,
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

	for _, threadID := range []string{"thread-route-a", "thread-route-b"} {
		if err := bridge.ClaimNewLocalOwner(threadID, "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
			return nil, nil
		}); err != nil {
			t.Fatal(err)
		}
		if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{"turns": []any{}}); err != nil {
			t.Fatal(err)
		}
	}
	if err := bridge.ActivateLocalThread("thread-route-a", "gateway-1"); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-entered:
		if got != "thread-route-a" {
			t.Fatalf("first route=%q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("first route did not enter opener")
	}
	if err := bridge.ActivateLocalThread("thread-route-b", "gateway-1"); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-entered:
		t.Fatalf("route %q entered while the first opener was active", got)
	case <-time.After(100 * time.Millisecond):
	}
	releaseFirst <- struct{}{}
	select {
	case got := <-entered:
		if got != "thread-route-b" {
			t.Fatalf("latest route=%q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("latest route did not run after the first opener exited")
	}
	if got := maxActive.Load(); got != 1 {
		t.Fatalf("Desktop route openers overlapped: max=%d", got)
	}
}

func TestReadyKeepsMimiSnapshotRevisionMonotonic(t *testing.T) {
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

	const threadID = "thread-reconnect-revision"
	if err := bridge.ClaimNewLocalOwner(threadID, "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{"title": "one", "turns": []any{}}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{"title": "two", "turns": []any{}}); err != nil {
		t.Fatal(err)
	}
	bridge.handleReady(bridge.client.ConnectionGeneration())

	deadline := time.Now().Add(time.Second)
	var changes []StreamChange
	for time.Now().Before(deadline) {
		changes = localStreamChanges(fake.requestsSnapshot(), threadID)
		if len(changes) >= 3 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(changes) < 3 {
		t.Fatalf("missing reconnect snapshot: %#v", changes)
	}
	if changes[0].Revision != 1 || changes[1].Revision != 2 ||
		changes[2].Type != "snapshot" || changes[2].Revision != 3 {
		t.Fatalf("revision rolled back across ready: %#v", changes)
	}
}

func TestFollowingChangedIgnoresOwnClientAndClearsDisconnectedFollower(t *testing.T) {
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
	const threadID = "thread-follow-status"
	if err := bridge.ClaimNewLocalOwner(threadID, "gateway-1", func(context.Context, string, json.RawMessage) (any, error) {
		return nil, nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.PublishLocalConversation(threadID, "gateway-1", map[string]any{"turns": []any{}}); err != nil {
		t.Fatal(err)
	}
	following, _ := json.Marshal(map[string]any{"conversationId": threadID, "following": true})
	generation := bridge.client.ConnectionGeneration()
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-following-changed", Version: 1,
		SourceClientID: bridge.client.ClientID(), ConnectionGeneration: generation, Params: following,
	})
	bridge.mu.RLock()
	selfFollower := bridge.owners[threadID].followerClientID
	bridge.mu.RUnlock()
	if selfFollower != "" {
		t.Fatalf("Bridge accepted its own following echo: %q", selfFollower)
	}
	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-following-changed", Version: 1,
		SourceClientID: "stale-renderer", ConnectionGeneration: generation + 1, Params: following,
	})
	bridge.mu.RLock()
	staleFollower := bridge.owners[threadID].followerClientID
	bridge.mu.RUnlock()
	if staleFollower != "" {
		t.Fatalf("Bridge accepted following from a stale generation: %q", staleFollower)
	}

	bridge.handleBroadcast(Broadcast{
		Method: "thread-stream-following-changed", Version: 1,
		SourceClientID: "desktop-renderer", ConnectionGeneration: generation, Params: following,
	})
	disconnected, _ := json.Marshal(map[string]any{"clientId": "desktop-renderer", "status": "disconnected"})
	bridge.handleBroadcast(Broadcast{
		Method: "client-status-changed", Version: 1,
		SourceClientID: "desktop-renderer", ConnectionGeneration: generation + 1, Params: disconnected,
	})
	bridge.mu.RLock()
	followerAfterStaleDisconnect := bridge.owners[threadID].followerClientID
	bridge.mu.RUnlock()
	if followerAfterStaleDisconnect != "desktop-renderer" {
		t.Fatalf("stale disconnect cleared current follower: %q", followerAfterStaleDisconnect)
	}
	bridge.handleBroadcast(Broadcast{
		Method: "client-status-changed", Version: 1,
		SourceClientID: "desktop-renderer", ConnectionGeneration: generation, Params: disconnected,
	})
	bridge.mu.RLock()
	disconnectedFollower := bridge.owners[threadID].followerClientID
	bridge.mu.RUnlock()
	if disconnectedFollower != "" {
		t.Fatalf("disconnected Desktop follower remained bound: %q", disconnectedFollower)
	}
}

func (f *fakeDesktopIPC) requestsSnapshot() []envelope {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]envelope(nil), f.requests...)
}

func localStreamChanges(requests []envelope, threadID string) []StreamChange {
	changes := make([]StreamChange, 0)
	for _, request := range requests {
		if request.Method != "thread-stream-state-changed" {
			continue
		}
		var params struct {
			ConversationID string       `json:"conversationId"`
			Change         StreamChange `json:"change"`
		}
		if json.Unmarshal(request.Params, &params) == nil && params.ConversationID == threadID {
			changes = append(changes, params.Change)
		}
	}
	return changes
}

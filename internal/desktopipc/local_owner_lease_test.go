package desktopipc

import (
	"context"
	"encoding/json"
	"testing"
)

// A Mimi-owned Turn runs on Mimi's own App Server. Codex Desktop connecting or
// quitting while that write is in flight changes nothing about its delivery, so
// it must not fence the Thread behind a complete-history recovery.
func TestLocalOwnerWriteSurvivesDesktopConnectionChange(t *testing.T) {
	bridge, err := NewBridge(BridgeOptions{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bridge.Close)

	const threadID = "thread-lease"
	const ownerID = "gateway-lease"
	starts := 0
	handler := func(ctx context.Context, method string, _ json.RawMessage) (any, error) {
		if method != "thread-follower-start-turn" {
			return map[string]any{}, nil
		}
		starts++
		if starts == 1 {
			// Codex Desktop finishes connecting while Mimi's own write is in
			// flight. This is exactly what launching Desktop mid-Turn does.
			bridge.mu.Lock()
			bridge.connectionGeneration = 9
			bridge.mu.Unlock()
		}
		if err := bridge.ValidateLocalOwnerLease(ctx, threadID); err != nil {
			return nil, err
		}
		return map[string]any{"turn": map[string]any{"id": "turn-1"}}, nil
	}
	if err := bridge.ClaimNewLocalOwner(threadID, ownerID, handler); err != nil {
		t.Fatal(err)
	}

	params := map[string]any{"conversationId": threadID, "turnStart": map[string]any{}}
	if _, err := bridge.RequestLocalOwner(
		context.Background(), threadID, "thread-follower-start-turn", params,
	); err != nil {
		t.Fatalf("Mimi write failed while Desktop was connecting: %v", err)
	}

	if bridge.LocalOwnerNeedsRecovery(threadID) {
		t.Fatal("Desktop connecting mid-write fenced the Thread behind a history recovery")
	}

	// A later Desktop disconnect must not fence it either.
	bridge.mu.Lock()
	bridge.connectionGeneration = 0
	bridge.mu.Unlock()
	if _, err := bridge.RequestLocalOwner(
		context.Background(), threadID, "thread-follower-interrupt-turn", params,
	); err != nil {
		t.Fatalf("Desktop disconnect fenced later Mimi writes: %v", err)
	}
	if bridge.LocalOwnerNeedsRecovery(threadID) {
		t.Fatal("Desktop disconnect fenced the Thread behind a history recovery")
	}
}

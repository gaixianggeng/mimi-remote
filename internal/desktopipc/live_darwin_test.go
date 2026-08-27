//go:build darwin

package desktopipc

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"
)

// This opt-in test only initializes a Desktop IPC client. It does not follow,
// mutate, or publish any thread.
func TestLiveVerifiedDesktopIPCInitialize(t *testing.T) {
	if os.Getenv("MIMI_DESKTOP_IPC_LIVE") != "1" {
		t.Skip("set MIMI_DESKTOP_IPC_LIVE=1 to verify the installed Desktop build")
	}
	info, err := InspectDesktop("/Applications/ChatGPT.app/Contents/Resources/codex", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Installed || !info.Running {
		t.Fatalf("supported Desktop is not running: %#v", info)
	}
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: info.Socket,
		DesktopVersion: info.Version, DesktopBuild: info.Build,
		RequestTimeout: 15 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	client.Start(ctx)
	if err := client.WaitReady(ctx); err != nil {
		client.Close()
		t.Fatal(err)
	}
	if status := client.Status(); status.State != StateReady || status.Profile != SupportedProfile {
		client.Close()
		t.Fatalf("unexpected live status: %#v", status)
	}
	cancel()
	client.Close()
}

func TestLiveDesktopIPCReportsNoOwnerExplicitly(t *testing.T) {
	if os.Getenv("MIMI_DESKTOP_IPC_LIVE") != "1" {
		t.Skip("set MIMI_DESKTOP_IPC_LIVE=1 to verify the installed Desktop build")
	}
	info, err := InspectDesktop("/Applications/ChatGPT.app/Contents/Resources/codex", nil)
	if err != nil {
		t.Fatal(err)
	}
	client, err := NewClient(ClientOptions{
		Enabled: true, SocketPath: info.Socket,
		DesktopVersion: info.Version, DesktopBuild: info.Build,
		RequestTimeout: 15 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	client.Start(ctx)
	if err := client.WaitReady(ctx); err != nil {
		client.Close()
		t.Fatal(err)
	}
	ownerClientID, requestErr := client.FindHandler(ctx, "thread-owner-discovery", map[string]any{
		"hostId": "local", "conversationId": "mimi-live-probe-no-such-thread",
	})
	if !SafeToFallback(requestErr) || ownerClientID != "" {
		client.Close()
		t.Fatalf("Desktop did not return an explicit no-owner result: owner=%q err=%v", ownerClientID, requestErr)
	}
	cancel()
	client.Close()
}

func TestLiveDesktopIPCFollowsCurrentDesktopThread(t *testing.T) {
	if os.Getenv("MIMI_DESKTOP_IPC_LIVE") != "1" {
		t.Skip("set MIMI_DESKTOP_IPC_LIVE=1 to verify the installed Desktop build")
	}
	threadID := os.Getenv("CODEX_THREAD_ID")
	if threadID == "" {
		t.Skip("CODEX_THREAD_ID is unavailable")
	}
	info, err := InspectDesktop("/Applications/ChatGPT.app/Contents/Resources/codex", nil)
	if err != nil {
		t.Fatal(err)
	}
	bridge, err := NewBridge(BridgeOptions{
		Enabled: true, SocketPath: info.Socket,
		DesktopVersion: info.Version, DesktopBuild: info.Build,
		ClientOptions: ClientOptions{RequestTimeout: 15 * time.Second},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	bridge.Start(ctx)
	defer bridge.Close()
	if err := bridge.client.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	owned, err := bridge.DiscoverDesktopOwner(ctx, threadID)
	if err != nil || !owned {
		t.Fatalf("current Desktop thread owner was not found: owned=%t err=%v", owned, err)
	}
	if err := bridge.FollowThread(ctx, threadID); err != nil {
		t.Fatal(err)
	}
	result, err := bridge.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		t.Fatal(err)
	}
	var history struct {
		Revision int64 `json:"revision"`
	}
	if json.Unmarshal(result, &history) != nil || history.Revision <= 0 {
		t.Fatalf("Desktop complete-history response is invalid")
	}
	projection, ok := bridge.WaitDesktopProjection(ctx, threadID)
	if !ok || projection.Thread["id"] != threadID || len(projection.Turns) == 0 {
		state, revision, stored := bridge.store.Get(threadID)
		t.Fatalf("current Desktop thread projection invalid: projected=%t turns=%d stored=%t revision=%d rawTurns=%d", ok, len(projection.Turns), stored, revision, len(conversationTurns(state)))
	}
}

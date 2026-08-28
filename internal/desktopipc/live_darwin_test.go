//go:build darwin

package desktopipc

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
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
	expectedProfile, supported := verifiedDesktopProfile(info.Version, info.Build)
	if status := client.Status(); !supported || status.State != StateReady || status.Profile != expectedProfile {
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
	if err := bridge.FollowThread(ctx, threadID); err != nil {
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

// 这个显式开启的测试会向 Desktop-owned 当前会话执行一次真实写入。
// timeout 表示交付状态不确定，因此测试绝不自动重试。
func TestLiveDesktopIPCSendsMessageToCurrentThread(t *testing.T) {
	if os.Getenv("MIMI_DESKTOP_IPC_LIVE") != "1" || os.Getenv("MIMI_DESKTOP_IPC_LIVE_SEND") != "1" {
		t.Skip("set MIMI_DESKTOP_IPC_LIVE=1 and MIMI_DESKTOP_IPC_LIVE_SEND=1 to send one live message")
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
	if err := bridge.FollowThread(ctx, threadID); err != nil {
		t.Fatal(err)
	}
	owned, err := bridge.DiscoverDesktopOwner(ctx, threadID)
	if err != nil || !owned {
		t.Fatalf("current Desktop thread owner was not found: owned=%t err=%v", owned, err)
	}
	historyResult, err := bridge.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		t.Fatal(err)
	}
	var history struct {
		Revision int64 `json:"revision"`
	}
	if json.Unmarshal(historyResult, &history) != nil || history.Revision <= 0 {
		t.Fatal("Desktop complete-history response is invalid")
	}
	projection, ok := bridge.WaitDesktopProjectionRevision(ctx, threadID, history.Revision)
	if !ok {
		t.Fatal("Desktop complete history was not projected")
	}
	if projection.ActiveTurnID != "" {
		t.Skipf("refusing live start-turn while Desktop turn %s is active", projection.ActiveTurnID)
	}
	message := "MIM-148 IPC follower 实时发送测试。看到这条消息后，请只回复：IPC_TEST_OK"
	result, err := bridge.RequestDesktopOwner(ctx, "thread-follower-start-turn", map[string]any{
		"conversationId": threadID,
		"turnStart": map[string]any{
			"request": map[string]any{
				"threadId": threadID,
				"input":    []any{map[string]any{"type": "text", "text": message}},
			},
			"context": map[string]any{"inheritThreadSettings": true},
		},
	})
	if err != nil {
		t.Fatalf("live follower message was not acknowledged; delivery may be uncertain: %v", err)
	}
	if len(result) == 0 || string(result) == "null" {
		t.Fatal("live follower message returned an empty acknowledgement")
	}
	turnID := desktopStartTurnID(result)
	if turnID == "" {
		t.Fatal("live follower message acknowledgement is missing turn id")
	}
	turn := waitLiveTurnTerminal(t, ctx, bridge, threadID, turnID)
	if text := liveAssistantText(turn); strings.TrimSpace(text) != "IPC_TEST_OK" {
		t.Fatalf("live follower message completed with unexpected assistant text: %q", text)
	}
}

// 这个显式开启的测试启动一个可中断的 Turn，并在 Desktop 投影确认其活跃后发送一次 Steer。
// 两次写入都不重试，避免超时后的重复交付。
func TestLiveDesktopIPCSteersActiveTurn(t *testing.T) {
	if os.Getenv("MIMI_DESKTOP_IPC_LIVE") != "1" || os.Getenv("MIMI_DESKTOP_IPC_LIVE_STEER") != "1" {
		t.Skip("set MIMI_DESKTOP_IPC_LIVE=1 and MIMI_DESKTOP_IPC_LIVE_STEER=1 to run the live steer test")
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
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	bridge.Start(ctx)
	defer bridge.Close()
	if err := bridge.client.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	if err := bridge.FollowThread(ctx, threadID); err != nil {
		t.Fatal(err)
	}
	owned, err := bridge.DiscoverDesktopOwner(ctx, threadID)
	if err != nil || !owned {
		t.Fatalf("current Desktop thread owner was not found: owned=%t err=%v", owned, err)
	}
	historyResult, err := bridge.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		t.Fatal(err)
	}
	var history struct {
		Revision int64 `json:"revision"`
	}
	if json.Unmarshal(historyResult, &history) != nil || history.Revision <= 0 {
		t.Fatal("Desktop complete-history response is invalid")
	}
	projection, ok := bridge.WaitDesktopProjectionRevision(ctx, threadID, history.Revision)
	if !ok {
		t.Fatal("Desktop complete history was not projected")
	}
	if projection.ActiveTurnID != "" {
		t.Skipf("refusing live start-turn while Desktop turn %s is active", projection.ActiveTurnID)
	}

	startResult, err := bridge.RequestDesktopOwner(ctx, "thread-follower-start-turn", map[string]any{
		"conversationId": threadID,
		"turnStart": map[string]any{
			"request": map[string]any{
				"threadId": threadID,
				"input": []any{map[string]any{
					"type": "text",
					"text": "MIM-148 IPC Steer 修复验证：请先调用终端运行 sleep 20，然后只回复 SHOULD_NOT_APPEAR_2。若收到调整方向，则立即只回复 IPC_STEER_FIXED_OK。不要修改文件。",
				}},
			},
			"context": map[string]any{"inheritThreadSettings": true},
		},
	})
	if err != nil {
		t.Fatalf("live follower start was not acknowledged; delivery may be uncertain: %v", err)
	}
	var startAck struct {
		Result struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
		} `json:"result"`
	}
	if json.Unmarshal(startResult, &startAck) != nil || startAck.Result.Turn.ID == "" {
		t.Fatal("live follower start returned an invalid acknowledgement; no steer was attempted")
	}
	turnID := startAck.Result.Turn.ID

	activeDeadline := time.NewTimer(10 * time.Second)
	defer activeDeadline.Stop()
	activeTicker := time.NewTicker(25 * time.Millisecond)
	defer activeTicker.Stop()
	for projection.ActiveTurnID != turnID {
		select {
		case <-ctx.Done():
			t.Fatal("live follower turn did not become active before context ended; no steer was attempted")
		case <-activeDeadline.C:
			t.Fatal("live follower turn did not become active within 10 seconds; no steer was attempted")
		case <-activeTicker.C:
			projection, _ = bridge.DesktopProjection(threadID)
		}
	}

	steerText := "调整方向：停止等待，现在只回复 IPC_STEER_FIXED_OK。"
	cwd := strings.TrimSpace(stringValue(projection.Thread["cwd"]))
	if cwd == "" {
		cwd = "/"
	}
	clientUserMessageID := fmt.Sprintf("mimi-live-steer-%d", time.Now().UnixNano())
	steerResult, err := bridge.RequestDesktopOwner(ctx, "thread-follower-steer-turn", map[string]any{
		"conversationId":      threadID,
		"clientUserMessageId": clientUserMessageID,
		"input": []any{map[string]any{
			"type": "text", "text": steerText,
		}},
		"serviceTier": nil,
		"attachments": []any{},
		"restoreMessage": map[string]any{
			"id": clientUserMessageID, "text": steerText, "cwd": cwd, "createdAt": time.Now().UnixMilli(),
			"context": map[string]any{
				"prompt": steerText, "addedFiles": []any{}, "fileAttachments": []any{},
				"ideContext": nil, "imageAttachments": []any{}, "workspaceRoots": []any{cwd},
			},
		},
	})
	if err != nil {
		t.Fatalf("live follower steer was not acknowledged; delivery may be uncertain: %v", err)
	}
	if len(steerResult) == 0 || string(steerResult) == "null" {
		t.Fatal("live follower steer returned an empty acknowledgement")
	}
	turn := waitLiveTurnTerminal(t, ctx, bridge, threadID, turnID)
	assistantText := liveAssistantText(turn)
	if !strings.Contains(assistantText, "IPC_STEER_FIXED_OK") || strings.Contains(assistantText, "SHOULD_NOT_APPEAR_2") {
		t.Fatalf("Steer did not replace the original direction: %q", assistantText)
	}
}

// 这个显式开启的测试启动一个长 Turn，并在 Desktop 投影确认其活跃后中断一次。
// Start 或 Interrupt 的交付状态不确定时都立即停止，不执行补偿写入。
func TestLiveDesktopIPCInterruptsActiveTurn(t *testing.T) {
	if os.Getenv("MIMI_DESKTOP_IPC_LIVE") != "1" || os.Getenv("MIMI_DESKTOP_IPC_LIVE_INTERRUPT") != "1" {
		t.Skip("set MIMI_DESKTOP_IPC_LIVE=1 and MIMI_DESKTOP_IPC_LIVE_INTERRUPT=1 to run the live interrupt test")
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
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	bridge.Start(ctx)
	defer bridge.Close()
	if err := bridge.client.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	if err := bridge.FollowThread(ctx, threadID); err != nil {
		t.Fatal(err)
	}
	owned, err := bridge.DiscoverDesktopOwner(ctx, threadID)
	if err != nil || !owned {
		t.Fatalf("current Desktop thread owner was not found: owned=%t err=%v", owned, err)
	}
	historyResult, err := bridge.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		t.Fatal(err)
	}
	var history struct {
		Revision int64 `json:"revision"`
	}
	if json.Unmarshal(historyResult, &history) != nil || history.Revision <= 0 {
		t.Fatal("Desktop complete-history response is invalid")
	}
	projection, ok := bridge.WaitDesktopProjectionRevision(ctx, threadID, history.Revision)
	if !ok {
		t.Fatal("Desktop complete history was not projected")
	}
	if projection.ActiveTurnID != "" {
		t.Skipf("refusing live start-turn while Desktop turn %s is active", projection.ActiveTurnID)
	}

	startResult, err := bridge.RequestDesktopOwner(ctx, "thread-follower-start-turn", map[string]any{
		"conversationId": threadID,
		"turnStart": map[string]any{
			"request": map[string]any{
				"threadId": threadID,
				"input": []any{map[string]any{
					"type": "text",
					"text": "MIM-148 IPC Interrupt 验证：请调用终端运行 sleep 8，然后只回复 SHOULD_NOT_COMPLETE_INTERRUPT。不要修改文件。",
				}},
			},
			"context": map[string]any{"inheritThreadSettings": true},
		},
	})
	if err != nil {
		t.Fatalf("live follower start was not acknowledged; delivery may be uncertain: %v", err)
	}
	var startAck struct {
		Result struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
		} `json:"result"`
	}
	if json.Unmarshal(startResult, &startAck) != nil || startAck.Result.Turn.ID == "" {
		t.Fatal("live follower start returned an invalid acknowledgement; no interrupt was attempted")
	}
	turnID := startAck.Result.Turn.ID

	activeDeadline := time.NewTimer(10 * time.Second)
	defer activeDeadline.Stop()
	activeTicker := time.NewTicker(25 * time.Millisecond)
	defer activeTicker.Stop()
	for projection.ActiveTurnID != turnID {
		select {
		case <-ctx.Done():
			t.Fatal("live follower turn did not become active before context ended; no interrupt was attempted")
		case <-activeDeadline.C:
			t.Fatal("live follower turn did not become active within 10 seconds; no interrupt was attempted")
		case <-activeTicker.C:
			projection, _ = bridge.DesktopProjection(threadID)
		}
	}
	commandID := waitLiveCommandRunning(t, ctx, bridge, threadID, turnID)

	interruptResult, err := bridge.RequestDesktopOwner(ctx, "thread-follower-interrupt-turn", map[string]any{
		"conversationId": threadID,
		"mode":           "user-stop",
		"expectedTurnId": turnID,
	})
	if err != nil {
		t.Fatalf("live follower interrupt was not acknowledged; delivery may be uncertain: %v", err)
	}
	var interruptAck struct {
		InterruptedTurnID string `json:"interruptedTurnId"`
		OK                bool   `json:"ok"`
	}
	if json.Unmarshal(interruptResult, &interruptAck) != nil || !interruptAck.OK || interruptAck.InterruptedTurnID != turnID {
		t.Fatal("live follower interrupt returned an invalid acknowledgement")
	}
	turn := waitLiveTurnTerminal(t, ctx, bridge, threadID, turnID)
	if normalizeTurnStatus(turn["status"]) != "interrupted" {
		t.Fatalf("interrupted live Turn reached unexpected terminal state: %#v", turn)
	}
	if strings.Contains(liveAssistantText(turn), "SHOULD_NOT_COMPLETE_INTERRUPT") {
		t.Fatalf("interrupted Turn produced the forbidden completion: %#v", turn)
	}
	// Desktop 先终止 Turn，底层工具项再按 Desktop 自身的生命周期收敛。
	// 等待原命令的最长执行时间后记录最终工具状态，用于区分 Turn 中断和工具进程终止。
	time.Sleep(9 * time.Second)
	historyResult, err = bridge.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if json.Unmarshal(historyResult, &history) != nil || history.Revision <= 0 {
		t.Fatal("Desktop complete-history response after interrupt is invalid")
	}
	projection, ok = bridge.WaitDesktopProjectionRevision(ctx, threadID, history.Revision)
	if !ok {
		t.Fatal("Desktop complete history after interrupt was not projected")
	}
	t.Logf("post-interrupt command %s status=%s", commandID, liveItemStatus(projection, turnID, commandID))
}

func waitLiveCommandRunning(
	t *testing.T,
	ctx context.Context,
	bridge *Bridge,
	threadID string,
	turnID string,
) string {
	t.Helper()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		projection, _ := bridge.DesktopProjection(threadID)
		for _, raw := range projection.Turns {
			turn, _ := raw.(map[string]any)
			if firstString(turn, "id", "turnId", "turn_id") != turnID {
				continue
			}
			for _, rawItem := range anySlice(turn["items"]) {
				item, _ := rawItem.(map[string]any)
				if normalizeToken(stringValue(item["type"])) == "commandexecution" &&
					normalizeToken(stringValue(item["status"])) == "inprogress" {
					return firstString(item, "id", "itemId", "item_id")
				}
			}
		}
		select {
		case <-ctx.Done():
			t.Fatalf("live Turn %s did not start a command: %v", turnID, ctx.Err())
		case <-ticker.C:
		}
	}
}

func liveItemStatus(projection Projection, turnID string, itemID string) string {
	for _, raw := range projection.Turns {
		turn, _ := raw.(map[string]any)
		if firstString(turn, "id", "turnId", "turn_id") != turnID {
			continue
		}
		for _, rawItem := range anySlice(turn["items"]) {
			item, _ := rawItem.(map[string]any)
			if firstString(item, "id", "itemId", "item_id") == itemID {
				return normalizeToken(stringValue(item["status"]))
			}
		}
	}
	return ""
}

func waitLiveTurnTerminal(
	t *testing.T,
	ctx context.Context,
	bridge *Bridge,
	threadID string,
	turnID string,
) map[string]any {
	t.Helper()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		projection, _ := bridge.DesktopProjection(threadID)
		matches := 0
		var turn map[string]any
		for _, raw := range projection.Turns {
			candidate, _ := raw.(map[string]any)
			if firstString(candidate, "id", "turnId", "turn_id") == turnID {
				matches++
				turn = candidate
			}
		}
		if matches > 1 {
			t.Fatalf("live IPC produced duplicate Turn %s", turnID)
		}
		if matches == 1 && normalizeTurnStatus(turn["status"]) != "inProgress" {
			return turn
		}
		select {
		case <-ctx.Done():
			t.Fatalf("live Turn %s did not reach a terminal state: %v", turnID, ctx.Err())
		case <-ticker.C:
		}
	}
}

func liveAssistantText(turn map[string]any) string {
	parts := make([]string, 0)
	for _, raw := range anySlice(turn["items"]) {
		item, _ := raw.(map[string]any)
		switch normalizeToken(stringValue(item["type"])) {
		case "agentmessage", "assistantmessage", "message":
			if text := strings.TrimSpace(itemText(item)); text != "" {
				parts = append(parts, text)
			}
		}
	}
	return strings.Join(parts, "\n")
}

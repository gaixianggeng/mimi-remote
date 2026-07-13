//go:build real_codex_smoke

package appserver

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRealCodexAppServerSmoke(t *testing.T) {
	if os.Getenv("AGENTD_REAL_CODEX_SMOKE") != "1" {
		t.Skip("set AGENTD_REAL_CODEX_SMOKE=1 to run real Codex app-server smoke")
	}
	repoRoot, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	process, _, err := StartManaged(ctx, ManagedOptions{
		CodexBin:   os.Getenv("AGENTD_CODEX_BIN"),
		ClientInfo: ClientInfo{Name: "mimi_remote", Title: "Mimi Remote Smoke", Version: "test"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		_ = process.Shutdown(shutdownCtx)
	}()
	client := process.Client()

	var list map[string]any
	if err := client.Call(ctx, "thread/list", map[string]any{"limit": 1}, &list); err != nil {
		t.Fatalf("thread/list 失败：%v diagnostics=%+v", err, process.Diagnostics())
	}

	var started map[string]any
	if err := client.Call(ctx, "thread/start", map[string]any{"cwd": repoRoot}, &started); err != nil {
		t.Fatalf("thread/start 失败：%v diagnostics=%+v", err, process.Diagnostics())
	}
	threadID := extractString(started, "thread", "id")
	if threadID == "" {
		t.Fatalf("thread/start 未返回 thread.id：%s", mustJSON(started))
	}

	var turn map[string]any
	if err := client.Call(ctx, "turn/start", map[string]any{
		"threadId":            threadID,
		"clientUserMessageId": "agentd-real-smoke",
		"input": []map[string]string{
			{"type": "text", "text": "只回复 ok"},
		},
	}, &turn); err != nil {
		t.Fatalf("turn/start 失败：%v diagnostics=%+v", err, process.Diagnostics())
	}

	seenDelta := false
	seenCompleted := false
	for !seenCompleted {
		select {
		case notification, ok := <-client.Notifications():
			if !ok {
				t.Fatalf("notification channel 提前关闭：diagnostics=%+v", process.Diagnostics())
			}
			switch notification.Method {
			case "item/agentMessage/delta":
				if strings.TrimSpace(string(notification.Params)) != "" {
					seenDelta = true
				}
			case "turn/completed":
				seenCompleted = true
			}
		case <-ctx.Done():
			t.Fatalf("等待真实 Codex smoke 超时，seenDelta=%v diagnostics=%+v", seenDelta, process.Diagnostics())
		}
	}
	if !seenDelta {
		t.Fatal("真实 Codex smoke 没有收到 assistant delta")
	}
}

func extractString(value map[string]any, keys ...string) string {
	var current any = value
	for _, key := range keys {
		obj, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current = obj[key]
	}
	text, _ := current.(string)
	return text
}

func mustJSON(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return "<invalid json>"
	}
	return string(data)
}

package pushprovider

import (
	"encoding/json"
	"reflect"
	"sort"
	"testing"
	"time"
)

func decodeAPS(t *testing.T, n ApprovalNotification) map[string]any {
	t.Helper()
	raw, err := BuildAPNsPayload(n)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatal(err)
	}
	aps, ok := payload["aps"].(map[string]any)
	if !ok {
		t.Fatalf("missing aps: %s", raw)
	}
	return aps
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func TestTurnMessagePayloadHasOnlyDetailsAndNoContent(t *testing.T) {
	now := time.Now()
	for _, event := range []string{completedPushEvent, failedPushEvent, interruptedPushEvent} {
		t.Run(event, func(t *testing.T) {
			message := ApprovalNotification{Version: 1, Event: event, ActionID: "route-123", DeviceID: "device-123", ProfileID: "profile-123", Runtime: "codex", HostTag: "ABCD", SessionTag: "0123456789ABCDEF", ExpiresAt: now.Add(23 * time.Hour).UTC().Format(time.RFC3339)}
			if err := message.Validate(now); err != nil {
				t.Fatal(err)
			}
			aps := decodeAPS(t, message)
			if aps["category"] != ApprovalDetailsCategory || aps["sound"] != "default" {
				t.Fatalf("invalid alert: %v", aps)
			}
			// mutable-content 只授权设备上的通知扩展改写文案；标题来自本机 App Group
			// 缓存，Payload 里除此之外不能多出任何字段。
			if aps["mutable-content"] != float64(1) {
				t.Fatalf("message must allow the on-device extension to rewrite it: %v", aps)
			}
			if aps["thread-id"] != "0123456789ABCDEF" {
				t.Fatalf("thread-id must stay the hashed session tag: %v", aps)
			}
			if got, want := sortedKeys(aps), []string{"alert", "category", "mutable-content", "sound", "thread-id"}; !reflect.DeepEqual(got, want) {
				t.Fatalf("unexpected aps keys: got=%v want=%v", got, want)
			}
			alert := aps["alert"].(map[string]any)
			if len(alert) != 2 || alert["title-loc-key"] != "push.message.title.codex" {
				t.Fatal("unexpected text or arguments")
			}
			if _, ok := aps["content-available"]; ok {
				t.Fatal("message must be a visible alert")
			}
			message.ApprovalKind = "command"
			if message.Validate(now) == nil {
				t.Fatal("message with approval kind accepted")
			}
			message.ApprovalKind = ""
			message.ExpiresAt = now.Add(25 * time.Hour).UTC().Format(time.RFC3339)
			if message.Validate(now) == nil {
				t.Fatal("unbounded expiry")
			}
		})
	}
}

// 给消息加 mutable-content 不能顺带改动审批与 resolved 的 Payload。
func TestApprovalAndResolvedPayloadsUnchangedByMessageRewrite(t *testing.T) {
	now := time.Now()
	base := ApprovalNotification{Version: 1, ActionID: "route-123", DeviceID: "device-123", ProfileID: "profile-123", Runtime: "claude", ApprovalKind: "command", HostTag: "ABCD", SessionTag: "0123456789ABCDEF", ExpiresAt: now.Add(5 * time.Minute).UTC().Format(time.RFC3339)}

	approval := base
	approval.Event = approvalPushEvent
	if err := approval.Validate(now); err != nil {
		t.Fatal(err)
	}
	aps := decodeAPS(t, approval)
	if got, want := sortedKeys(aps), []string{"alert", "category", "interruption-level", "mutable-content", "sound", "thread-id"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected approval aps keys: got=%v want=%v", got, want)
	}
	if aps["mutable-content"] != float64(1) || aps["category"] != ApprovalCategory || aps["interruption-level"] != "time-sensitive" || aps["sound"] != "default" || aps["thread-id"] != "0123456789ABCDEF" {
		t.Fatalf("approval aps changed: %v", aps)
	}
	wantAlert := map[string]any{
		"title-loc-key":  "push.approval.title.claude",
		"title-loc-args": []any{"ABCD"},
		"loc-key":        "push.approval.body.command",
		"loc-args":       []any{"0123456789ABCDEF"},
	}
	if !reflect.DeepEqual(aps["alert"], wantAlert) {
		t.Fatalf("approval alert changed: got=%v want=%v", aps["alert"], wantAlert)
	}

	resolved := base
	resolved.Event = resolvedPushEvent
	if err := resolved.Validate(now); err != nil {
		t.Fatal(err)
	}
	if aps := decodeAPS(t, resolved); !reflect.DeepEqual(aps, map[string]any{"content-available": float64(1)}) {
		t.Fatalf("resolved must stay a silent wake-up without mutable-content: %v", aps)
	}
}

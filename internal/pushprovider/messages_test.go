package pushprovider

import (
	"encoding/json"
	"testing"
	"time"
)

func TestTurnMessagePayloadHasOnlyDetailsAndNoContent(t *testing.T) {
	now := time.Now()
	for _, event := range []string{completedPushEvent, failedPushEvent, interruptedPushEvent} {
		t.Run(event, func(t *testing.T) {
			message := ApprovalNotification{Version: 1, Event: event, ActionID: "route-123", DeviceID: "device-123", ProfileID: "profile-123", Runtime: "codex", HostTag: "ABCD", SessionTag: "0123456789ABCDEF", ExpiresAt: now.Add(23 * time.Hour).UTC().Format(time.RFC3339)}
			if err := message.Validate(now); err != nil {
				t.Fatal(err)
			}
			raw, err := BuildAPNsPayload(message)
			if err != nil {
				t.Fatal(err)
			}
			var payload map[string]any
			if err := json.Unmarshal(raw, &payload); err != nil {
				t.Fatal(err)
			}
			aps := payload["aps"].(map[string]any)
			if aps["category"] != ApprovalDetailsCategory || aps["sound"] != "default" {
				t.Fatalf("invalid alert: %v", aps)
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

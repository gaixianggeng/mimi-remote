package desktopipc

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestDesktopRouteTraceUsesStableRedactedJSON(t *testing.T) {
	var output bytes.Buffer
	restore := setDesktopRouteTraceWriter(&output)
	defer restore()

	threadID := "thread-with-sensitive-route-id"
	desktopRouteTrace(desktopRouteTraceRequested, threadID, 0, "", 0)
	desktopRouteTrace(desktopRouteTraceOpened, threadID, 2, "", 1250*time.Millisecond)

	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected two trace lines, got %d: %q", len(lines), output.String())
	}
	for index, line := range lines {
		if strings.Contains(line, threadID) {
			t.Fatalf("trace leaked raw Thread ID: %q", line)
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("trace is not one JSON object per line: %v", err)
		}
		if entry["thread_hash"] != desktopRouteThreadHash(threadID) {
			t.Fatalf("unexpected thread hash: %#v", entry["thread_hash"])
		}
		for field := range entry {
			switch field {
			case "event", "thread_hash", "attempt", "reason", "duration_ms":
			default:
				t.Fatalf("trace contains unexpected field %q", field)
			}
		}
		if index == 0 {
			if entry["event"] != desktopRouteTraceRequested {
				t.Fatalf("unexpected requested event: %#v", entry["event"])
			}
			if _, ok := entry["attempt"]; ok {
				t.Fatal("requested event unexpectedly contains an attempt")
			}
			continue
		}
		if entry["event"] != desktopRouteTraceOpened || entry["attempt"] != float64(2) ||
			entry["duration_ms"] != float64(1250) {
			t.Fatalf("unexpected opened event: %#v", entry)
		}
	}
}

func TestDesktopRouteDeferredReasonDoesNotExposeError(t *testing.T) {
	cases := []struct {
		err    error
		reason string
	}{
		{errors.New("Codex Desktop is not running: /private/socket"), "desktop_not_running"},
		{errors.New("Desktop route is supported only on macOS"), "unsupported_platform"},
		{errors.New("route open failed for codex://threads/private-id"), "route_open_failed"},
	}
	for _, test := range cases {
		t.Run(test.reason, func(t *testing.T) {
			if got := desktopRouteDeferredReason(test.err); got != test.reason {
				t.Fatalf("reason=%q, want %q", got, test.reason)
			}
		})
	}
}

func TestDesktopRouteStateReasonUsesStablePublicStates(t *testing.T) {
	cases := []struct {
		state  State
		reason string
	}{
		{StateDesktopNotRunning, "desktop_not_running"},
		{StateConnecting, "connecting"},
		{StateUnsupportedBuild, "unsupported_build"},
		{StateReady, "activation_not_started"},
	}
	for _, test := range cases {
		if got := desktopRouteStateReason(test.state); got != test.reason {
			t.Fatalf("state=%q reason=%q, want %q", test.state, got, test.reason)
		}
	}
}

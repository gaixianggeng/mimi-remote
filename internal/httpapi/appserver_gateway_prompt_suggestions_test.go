package httpapi

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/gorilla/websocket"
)

func TestClaudeGatewayPromptSuggestionPreservesScopeAndRequiresThreadAuthorization(t *testing.T) {
	policy := &appServerGatewayPolicy{
		runtimeID: "claude",
		allowedThreads: map[string]appServerGatewayAllowedThread{
			"thread-1": {id: "thread-1", runtimeID: "claude", cwd: "/repo", scopeID: "repo"},
		},
	}
	for _, test := range []struct {
		name     string
		threadID string
		allowed  bool
	}{
		{name: "authorized", threadID: "thread-1", allowed: true},
		{name: "another thread", threadID: "thread-2"},
		{name: "missing thread"},
	} {
		t.Run(test.name, func(t *testing.T) {
			frame, err := json.Marshal(map[string]any{
				"jsonrpc": "2.0", "method": "_mimi/turn/promptSuggestion",
				"params": map[string]any{"threadId": test.threadID, "turnId": "turn-1", "id": "suggestion-1", "text": "补上回归测试"},
			})
			if err != nil {
				t.Fatal(err)
			}
			forwarded, allowed, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, frame)
			if policyErr != nil || allowed != test.allowed {
				t.Fatalf("suggestion authorization: allowed=%v want=%v err=%v", allowed, test.allowed, policyErr)
			}
			if allowed && !bytes.Equal(forwarded, frame) {
				t.Fatalf("suggestion must preserve its turn, id and text: %s", forwarded)
			}
		})
	}
}

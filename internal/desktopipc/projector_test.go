package desktopipc

import (
	"strings"
	"testing"
	"time"
)

func TestProjectConversationStateBuildsStandardThreadAndFiltersContext(t *testing.T) {
	projection, err := ProjectConversationState("thread-1", map[string]any{
		"title": "Desktop thread", "cwd": "/workspace", "latestModel": "gpt-5.6-sol",
		"turns": []any{map[string]any{
			"id": "turn-1", "status": "running",
			"params": map[string]any{"input": []any{map[string]any{"type": "text", "text": "prompt"}}},
			"items": []any{
				map[string]any{"id": "hidden", "type": "userMessage", "content": []any{"<environment_context>secret</environment_context>"}},
				map[string]any{"id": "user", "type": "userMessage", "content": []any{"hello"}},
				map[string]any{"id": "tool", "type": "mcpToolCall", "status": "inProgress"},
			},
		}},
	}, time.Unix(100, 0))
	if err != nil {
		t.Fatal(err)
	}
	if projection.Thread["id"] != "thread-1" || projection.ActiveTurnID != "turn-1" || !projection.ActiveTurnIDTrusted {
		t.Fatalf("unexpected projection: %#v", projection)
	}
	turn := projection.Turns[0].(map[string]any)
	items := turn["items"].([]any)
	if len(items) != 3 {
		t.Fatalf("hidden context must not reach mobile: %#v", items)
	}
	prompt := items[0].(map[string]any)
	if prompt["type"] != "userMessage" || prompt["id"] != "turn-1:input" {
		t.Fatalf("turn params input was not projected: %#v", prompt)
	}
	tool := items[2].(map[string]any)
	if tool["type"] != "mcpToolCall" {
		t.Fatalf("Desktop tool alias was not normalized: %#v", tool)
	}
}

func TestProjectConversationStateNormalizesDesktopMessageAliases(t *testing.T) {
	projection, err := ProjectConversationState("thread-alias", map[string]any{
		"turns": []any{map[string]any{"id": "turn-1", "items": []any{
			map[string]any{"id": "assistant", "type": "assistant_message", "text": "done"},
			map[string]any{"id": "tool", "type": "tool_call", "name": "browser"},
		}}},
	}, time.Unix(100, 0))
	if err != nil {
		t.Fatal(err)
	}
	items := projection.Turns[0].(map[string]any)["items"].([]any)
	if items[0].(map[string]any)["type"] != "agentMessage" || items[1].(map[string]any)["type"] != "dynamicToolCall" {
		t.Fatalf("unexpected aliases: %#v", items)
	}
}

func TestProjectConversationStateDoesNotDuplicatePromptWithDifferentEntryShape(t *testing.T) {
	projection, err := ProjectConversationState("thread-prompt", map[string]any{
		"turns": []any{map[string]any{
			"id": "turn-1",
			"params": map[string]any{"input": []any{map[string]any{
				"type": "input_text", "text": "same prompt",
			}}},
			"items": []any{map[string]any{
				"id": "canonical-user", "type": "userMessage",
				"content": []any{map[string]any{"type": "text", "text": "same   prompt"}},
			}},
		}},
	}, time.Unix(100, 0))
	if err != nil {
		t.Fatal(err)
	}
	items := projection.Turns[0].(map[string]any)["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["id"] != "turn-1:input" {
		t.Fatalf("prompt was duplicated: %#v", items)
	}
}

func TestProjectConversationStateReadsCanonicalTurnHistory(t *testing.T) {
	state := map[string]any{
		"turns": []any{},
		"turnHistory": map[string]any{
			"kind": "canonical",
			"history": map[string]any{
				"entitiesByKey": map[string]any{
					"turn:a": map[string]any{"turnId": "turn-a", "status": "completed", "items": []any{}},
					"turn:b": map[string]any{"turnId": "turn-b", "status": "inProgress", "items": []any{}},
				},
				"islands": []any{
					map[string]any{"entries": []any{map[string]any{"value": "turn:a"}}},
					map[string]any{"entries": []any{map[string]any{"value": "turn:b"}}},
				},
			},
		},
	}
	projection, err := ProjectConversationState("thread-canonical", state, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(projection.Turns) != 2 || projection.ActiveTurnID != "turn-b" || !projection.ActiveTurnIDTrusted {
		t.Fatalf("canonical history was not projected in order: %#v", projection)
	}
}

func TestProjectConversationStateNeverTrustsSyntheticOrAmbiguousActiveTurnID(t *testing.T) {
	for name, turns := range map[string][]any{
		"missing id": {
			map[string]any{"status": "inProgress", "items": []any{}},
		},
		"multiple active": {
			map[string]any{"id": "turn-a", "status": "inProgress", "items": []any{}},
			map[string]any{"id": "turn-b", "status": "inProgress", "items": []any{}},
		},
	} {
		t.Run(name, func(t *testing.T) {
			state := map[string]any{"turns": turns}
			projection, err := ProjectConversationState("thread-unsafe", state, time.Unix(0, 0))
			if err != nil {
				t.Fatal(err)
			}
			if projection.ActiveTurnID == "" || projection.ActiveTurnIDTrusted {
				t.Fatalf("unsafe active Turn must remain display-only: %#v", projection)
			}
			if activeTurnID, ok := RealActiveTurnID(state); ok || activeTurnID != "" {
				t.Fatalf("raw active Turn must not authorize writes: id=%q ok=%t", activeTurnID, ok)
			}
		})
	}
}

func TestProjectConversationStateUsesExplicitMobileItemSchema(t *testing.T) {
	projection, err := ProjectConversationState("thread-private", map[string]any{
		"turns": []any{map[string]any{
			"id": "turn-1", "status": "completed", "items": []any{
				map[string]any{"id": "hook", "type": "hookPrompt", "prompt": "internal prompt"},
				map[string]any{"id": "user", "type": "userMessage", "content": []any{
					map[string]any{"type": "developerContext", "instructions": "secret"},
					map[string]any{"type": "text", "text": "visible", "developerInstructions": "secret", "privateMetadata": map[string]any{"host": true}},
				}},
				map[string]any{
					"id": "tool", "type": "mcpToolCall", "status": "completed", "name": "browser",
					"input": map[string]any{
						"query": "visible", "internalMetadata": map[string]any{
							"developerPrompt": "secret", "socketPath": "/private/ipc.sock",
						},
					},
					"output": "done", "privatePrompt": "secret", "socketPath": "/private/ipc.sock",
				},
			},
		}},
	}, time.Unix(100, 0))
	if err != nil {
		t.Fatal(err)
	}
	items := projection.Turns[0].(map[string]any)["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("private Desktop item types must be dropped: %#v", items)
	}
	user := items[0].(map[string]any)
	content := user["content"].([]any)
	if len(content) != 1 {
		t.Fatalf("structured hidden user context reached the mobile projection: %#v", content)
	}
	textEntry := content[0].(map[string]any)
	if textEntry["text"] != "visible" || textEntry["developerInstructions"] != nil || textEntry["privateMetadata"] != nil {
		t.Fatalf("text user content leaked Desktop-only sibling fields: %#v", textEntry)
	}
	tool := items[1].(map[string]any)
	if tool["privatePrompt"] != nil || tool["socketPath"] != nil || tool["output"] != "done" {
		t.Fatalf("tool projection did not enforce the allowlist: %#v", tool)
	}
	input, _ := tool["input"].(map[string]any)
	if input["query"] != "visible" || input["internalMetadata"] != nil ||
		strings.Contains(projectionJSON(input), "developerPrompt") || strings.Contains(projectionJSON(input), "ipc.sock") {
		t.Fatalf("nested tool metadata reached the mobile projection: %#v", input)
	}
}

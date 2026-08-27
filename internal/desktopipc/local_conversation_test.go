package desktopipc

import (
	"testing"
	"time"
)

func TestLocalConversationProjectsLifecycleReasoningAndApproval(t *testing.T) {
	conversation := NewLocalConversation()
	threadID, state, err := conversation.SeedThread(map[string]any{
		"id": "thread-local", "title": "Local", "turns": []any{},
	})
	if err != nil || threadID != "thread-local" || state["title"] != "Local" {
		t.Fatalf("seed failed: thread=%s state=%#v err=%v", threadID, state, err)
	}
	_, _, changed := conversation.Apply("turn/started", map[string]any{
		"threadId": "thread-local", "turn": map[string]any{"id": "turn-1"},
	})
	if !changed {
		t.Fatal("turn/started was not applied")
	}
	_, _, changed = conversation.Apply("item/reasoning/summaryTextDelta", map[string]any{
		"threadId": "thread-local", "turnId": "turn-1", "itemId": "reason-1", "delta": "正在检查",
	})
	if !changed {
		t.Fatal("reasoning delta was not applied")
	}
	_, state, changed = conversation.RememberRequest(7, "item/commandExecution/requestApproval", map[string]any{
		"threadId": "thread-local", "turnId": "turn-1", "itemId": "command-1",
	})
	if !changed || len(anySlice(state["requests"])) != 1 {
		t.Fatalf("approval was not projected: %#v", state)
	}
	projection, err := ProjectConversationState("thread-local", state, time.Unix(0, 0))
	if err != nil || projection.ActiveTurnID != "turn-1" {
		t.Fatalf("local projection failed: %+v err=%v", projection, err)
	}
	turn := projection.Turns[0].(map[string]any)
	item := anySlice(turn["items"])[0].(map[string]any)
	if summary := anySlice(item["summary"]); len(summary) != 1 || summary[0] != "正在检查" {
		t.Fatalf("reasoning text was lost: %#v", item)
	}
	state, changed = conversation.ResolveRequest("thread-local", 7)
	if !changed || len(anySlice(state["requests"])) != 0 {
		t.Fatalf("approval was not resolved: %#v", state)
	}
}

func TestLocalConversationBuildsDesktopStateAndAdoptsHydratedPrompt(t *testing.T) {
	conversation := NewLocalConversation()
	_, state, err := conversation.SeedThread(map[string]any{
		"id": "thread-local", "name": "Hydrated", "cwd": "/tmp/project",
		"createdAt": float64(1_700_000_000), "updatedAt": float64(1_700_000_001),
		"model": "gpt-5.6-sol", "status": map[string]any{"type": "idle"},
		"turns": []any{map[string]any{
			"id": "turn-1", "status": "completed", "startedAt": float64(1_700_000_000),
			"items": []any{
				map[string]any{"id": "context", "type": "userMessage", "content": []any{map[string]any{"type": "text", "text": "<environment_context>hidden</environment_context>"}}},
				map[string]any{"id": "prompt", "type": "userMessage", "content": []any{map[string]any{"type": "inputText", "text": "请检查实现"}}},
				map[string]any{"id": "agent", "type": "agentMessage", "text": "完成"},
				map[string]any{"id": "collab", "type": "collabAgentToolCall", "receiverThreadIds": []any{"child-1"}},
			},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if state["hostId"] != "local" || localTimestampMillis(state["createdAt"]) != int64(1_700_000_000_000) {
		t.Fatalf("Desktop state metadata is invalid: %#v", state)
	}
	turn := anySlice(state["turns"])[0].(map[string]any)
	params := turn["params"].(map[string]any)
	input := anySlice(params["input"])
	if len(input) != 1 || input[0].(map[string]any)["text"] != "请检查实现" {
		t.Fatalf("hydrated prompt was not adopted: %#v", params)
	}
	items := anySlice(turn["items"])
	if len(items) != 2 {
		t.Fatalf("context or duplicate prompt leaked into Desktop items: %#v", items)
	}
	collab := items[1].(map[string]any)
	if threads := anySlice(collab["receiverThreads"]); len(threads) != 1 || threads[0].(map[string]any)["threadId"] != "child-1" {
		t.Fatalf("collaboration item is not Desktop-compatible: %#v", collab)
	}
}

func TestLocalConversationAppliesPendingTurnStartOnce(t *testing.T) {
	conversation := NewLocalConversation()
	conversation.SeedThread(map[string]any{"id": "thread-local", "turns": []any{}})
	forgotten := conversation.RememberTurnStart("thread-local", map[string]any{
		"input": []any{map[string]any{"type": "text", "text": "discarded"}},
	})
	conversation.ForgetTurnStart("thread-local", forgotten)
	conversation.RememberTurnStart("thread-local", map[string]any{
		"input": []any{map[string]any{"type": "text", "text": "from Mimi"}},
		"model": "gpt-5.6-sol", "effort": "high",
	})
	_, state, changed := conversation.Apply("turn/started", map[string]any{
		"threadId": "thread-local", "turn": map[string]any{"id": "turn-1"},
	})
	if !changed {
		t.Fatal("turn/started was not applied")
	}
	turn := anySlice(state["turns"])[0].(map[string]any)
	params := turn["params"].(map[string]any)
	if got := anySlice(params["input"])[0].(map[string]any)["text"]; got != "from Mimi" {
		t.Fatalf("pending prompt mismatch: %#v", params)
	}
	if state["latestModel"] != "gpt-5.6-sol" || state["latestReasoningEffort"] != "high" {
		t.Fatalf("runtime metadata was not projected: %#v", state)
	}
	_, next, _ := conversation.Apply("turn/started", map[string]any{
		"threadId": "thread-local", "turn": map[string]any{"id": "turn-2"},
	})
	second := anySlice(next["turns"])[1].(map[string]any)
	if len(anySlice(second["params"].(map[string]any)["input"])) != 0 {
		t.Fatalf("pending start was reused: %#v", second)
	}
}

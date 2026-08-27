package desktopipc

import "testing"

func TestProjectionMessagesEmitsLifecycleAndAssistantDelta(t *testing.T) {
	previous := Projection{
		Thread: map[string]any{"id": "thread-1", "status": map[string]any{"type": "active"}},
		Turns: []any{map[string]any{
			"id": "turn-1", "status": "inProgress",
			"items": []any{map[string]any{"id": "item-1", "type": "agentMessage", "text": "Hello"}},
		}}, ActiveTurnID: "turn-1",
	}
	next := Projection{
		Thread: map[string]any{"id": "thread-1", "status": map[string]any{"type": "active"}},
		Turns: []any{map[string]any{
			"id": "turn-1", "status": "inProgress",
			"items": []any{map[string]any{"id": "item-1", "type": "agentMessage", "text": "Hello world"}},
		}}, ActiveTurnID: "turn-1",
	}
	messages := ProjectionMessages("thread-1", &previous, next)
	if len(messages) != 1 || messages[0].Method != "item/agentMessage/delta" || messages[0].Params["delta"] != " world" {
		t.Fatalf("unexpected delta messages: %#v", messages)
	}

	next.ActiveTurnID = ""
	next.Turns[0].(map[string]any)["status"] = "completed"
	messages = ProjectionMessages("thread-1", &previous, next)
	if len(messages) == 0 || messages[0].Method != "turn/completed" {
		t.Fatalf("turn completion was not emitted: %#v", messages)
	}
}

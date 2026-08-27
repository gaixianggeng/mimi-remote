package desktopipc

import (
	"encoding/json"
	"reflect"
)

type AppServerMessage struct {
	ID     any
	Method string
	Params map[string]any
}

func ProjectionMessages(threadID string, previous *Projection, next Projection) []AppServerMessage {
	if previous == nil {
		messages := []AppServerMessage{notification("thread/started", map[string]any{
			"threadId": threadID,
			"thread":   cloneValue(next.Thread),
		})}
		if next.ActiveTurnID != "" {
			if turn := projectionTurn(next, next.ActiveTurnID); turn != nil {
				messages = append(messages, turnStartedMessage(threadID, turn))
				for _, rawItem := range anySlice(turn["items"]) {
					item, _ := rawItem.(map[string]any)
					messages = append(messages, itemStartedMessage(threadID, next.ActiveTurnID, item))
					if itemTerminal(item) {
						messages = append(messages, itemCompletedMessage(threadID, next.ActiveTurnID, item))
					}
				}
			}
		}
		return messages
	}
	messages := make([]AppServerMessage, 0)
	if firstString(previous.Thread, "title", "name") != firstString(next.Thread, "title", "name") {
		messages = append(messages, notification("thread/name/updated", map[string]any{
			"threadId": threadID, "threadName": firstString(next.Thread, "title", "name"),
		}))
	}
	if !reflect.DeepEqual(previous.Thread["status"], next.Thread["status"]) {
		messages = append(messages, notification("thread/status/changed", map[string]any{
			"threadId": threadID, "status": cloneValue(next.Thread["status"]),
		}))
	}
	if !reflect.DeepEqual(previous.Thread["tokenUsage"], next.Thread["tokenUsage"]) && next.Thread["tokenUsage"] != nil {
		messages = append(messages, notification("thread/tokenUsage/updated", map[string]any{
			"threadId": threadID, "tokenUsage": cloneValue(next.Thread["tokenUsage"]),
		}))
	}
	if previous.ActiveTurnID != next.ActiveTurnID {
		if previous.ActiveTurnID != "" {
			turn := projectionTurn(next, previous.ActiveTurnID)
			if turn == nil {
				turn = projectionTurn(*previous, previous.ActiveTurnID)
			}
			if turn != nil {
				messages = append(messages, turnCompletedMessage(threadID, turn))
			}
		}
		if next.ActiveTurnID != "" {
			if turn := projectionTurn(next, next.ActiveTurnID); turn != nil {
				messages = append(messages, turnStartedMessage(threadID, turn))
			}
		}
	}
	previousTurns := projectionTurnsByID(*previous)
	for turnID, nextTurn := range projectionTurnsByID(next) {
		previousTurn := previousTurns[turnID]
		previousItems := projectionItemsByID(previousTurn)
		for itemID, nextItem := range projectionItemsByID(nextTurn) {
			previousItem := previousItems[itemID]
			if previousItem == nil {
				messages = append(messages, itemStartedMessage(threadID, turnID, nextItem))
				if turnID != next.ActiveTurnID || itemTerminal(nextItem) {
					messages = append(messages, itemCompletedMessage(threadID, turnID, nextItem))
				}
				continue
			}
			if reflect.DeepEqual(previousItem, nextItem) {
				continue
			}
			if delta := appendedItemDelta(previousItem, nextItem); delta.Method != "" {
				delta.Params["threadId"] = threadID
				delta.Params["turnId"] = turnID
				delta.Params["itemId"] = itemID
				messages = append(messages, delta)
			} else if !itemTerminal(previousItem) && itemTerminal(nextItem) {
				messages = append(messages, itemCompletedMessage(threadID, turnID, nextItem))
			}
		}
	}
	return messages
}

func MarshalAppServerMessage(message AppServerMessage) ([]byte, error) {
	value := map[string]any{"method": message.Method, "params": message.Params}
	if message.ID != nil {
		value["id"] = message.ID
	}
	return json.Marshal(value)
}

func projectionTurn(projection Projection, turnID string) map[string]any {
	return projectionTurnsByID(projection)[turnID]
}

func projectionTurnsByID(projection Projection) map[string]map[string]any {
	result := make(map[string]map[string]any)
	for _, raw := range projection.Turns {
		turn, _ := raw.(map[string]any)
		if id := firstString(turn, "id", "turnId"); id != "" {
			result[id] = turn
		}
	}
	return result
}

func projectionItemsByID(turn map[string]any) map[string]map[string]any {
	result := make(map[string]map[string]any)
	for _, raw := range anySlice(turn["items"]) {
		item, _ := raw.(map[string]any)
		if id := firstString(item, "id", "itemId", "item_id"); id != "" {
			result[id] = item
		}
	}
	return result
}

func turnStartedMessage(threadID string, turn map[string]any) AppServerMessage {
	return notification("turn/started", map[string]any{
		"threadId": threadID, "turnId": firstString(turn, "id", "turnId"), "turn": cloneValue(turn),
	})
}

func turnCompletedMessage(threadID string, turn map[string]any) AppServerMessage {
	return notification("turn/completed", map[string]any{
		"threadId": threadID, "turnId": firstString(turn, "id", "turnId"),
		"turn": cloneValue(turn), "status": turn["status"], "error": cloneValue(turn["error"]),
	})
}

func itemStartedMessage(threadID, turnID string, item map[string]any) AppServerMessage {
	return notification("item/started", map[string]any{
		"threadId": threadID, "turnId": turnID, "itemId": firstString(item, "id", "itemId", "item_id"), "item": cloneValue(item),
	})
}

func itemCompletedMessage(threadID, turnID string, item map[string]any) AppServerMessage {
	return notification("item/completed", map[string]any{
		"threadId": threadID, "turnId": turnID, "itemId": firstString(item, "id", "itemId", "item_id"), "item": cloneValue(item),
	})
}

func notification(method string, params map[string]any) AppServerMessage {
	params["mimiDesktopIPCMirror"] = true
	return AppServerMessage{Method: method, Params: params}
}

func itemTerminal(item map[string]any) bool {
	switch normalizeToken(stringValue(item["status"])) {
	case "completed", "succeeded", "success", "failed", "error", "interrupted",
		"cancelled", "canceled", "rejected", "denied":
		return true
	default:
		return false
	}
}

func appendedItemDelta(previous, next map[string]any) AppServerMessage {
	typeToken := normalizeToken(stringValue(next["type"]))
	method := ""
	previousText, nextText := "", ""
	switch typeToken {
	case "agentmessage", "assistantmessage", "message":
		method = "item/agentMessage/delta"
		previousText, nextText = itemText(previous), itemText(next)
	case "reasoning":
		method = "item/reasoning/summaryTextDelta"
		previousText, nextText = reasoningText(previous), reasoningText(next)
	case "plan", "todolist":
		method = "item/plan/delta"
		previousText, nextText = itemText(previous), itemText(next)
	case "commandexecution":
		method = "item/commandExecution/outputDelta"
		previousText, nextText = itemOutput(previous), itemOutput(next)
	case "filechange":
		method = "item/fileChange/outputDelta"
		previousText, nextText = itemOutput(previous), itemOutput(next)
	case "toolcall":
		method = "item/toolCall/outputDelta"
		previousText, nextText = itemOutput(previous), itemOutput(next)
	}
	if method == "" || previousText == nextText || !startsWithExact(nextText, previousText) {
		return AppServerMessage{}
	}
	params := map[string]any{"delta": nextText[len(previousText):]}
	if typeToken == "reasoning" {
		params["summaryIndex"] = 0
	}
	return notification(method, params)
}

func startsWithExact(value, prefix string) bool {
	return len(value) > len(prefix) && value[:len(prefix)] == prefix
}

func itemText(item map[string]any) string {
	if value := firstString(item, "text", "message"); value != "" {
		return value
	}
	return renderContentText(item["content"])
}

func itemOutput(item map[string]any) string {
	for _, key := range []string{"aggregatedOutput", "aggregated_output", "output", "stdout", "diff", "patch", "result", "response"} {
		if value := stringValue(item[key]); value != "" {
			return value
		}
	}
	return renderContentText(item["content"])
}

func reasoningText(item map[string]any) string {
	if value := firstString(item, "summaryText", "summary_text", "text"); value != "" {
		return value
	}
	return renderContentText(item["summary"])
}

func renderContentText(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	var result string
	for _, raw := range anySlice(value) {
		switch entry := raw.(type) {
		case string:
			result += entry
		case map[string]any:
			result += firstString(entry, "text", "content")
		}
	}
	return result
}

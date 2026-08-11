package httpapi

import (
	"encoding/json"
	"strings"
	"time"
)

// rewriteInterruptedGatewayHistoryResponse 只改写已经由 managed runtime 代际
// 精确确认中断的 Thread+Turn。它不按 thread 或时间猜测，避免同一会话后续真正的
// 新 Turn 被旧中断状态清掉。
func (r *Router) rewriteInterruptedGatewayHistoryResponse(
	payload []byte,
	request appServerGatewayPendingHistoryRequest,
) ([]byte, bool) {
	if r == nil {
		return payload, false
	}
	source, ok := r.externalActivity.(gatewayInterruptedTurnSource)
	if !ok {
		return payload, false
	}
	threadID := strings.TrimSpace(request.threadID)
	var interrupted map[string]time.Time
	if threadID != "" {
		interrupted = source.GatewayInterruptedTurns(threadID)
		if len(interrupted) == 0 {
			return payload, false
		}
	}

	var frame map[string]any
	if err := json.Unmarshal(payload, &frame); err != nil {
		return payload, false
	}
	result, ok := frame["result"].(map[string]any)
	if !ok {
		return payload, false
	}

	changed := false
	switch request.method {
	case "thread/list", "thread/search":
		threads, ok := result["data"].([]any)
		if !ok {
			break
		}
		for _, rawThread := range threads {
			thread, ok := rawThread.(map[string]any)
			if !ok {
				continue
			}
			listedThreadID := gatewayHistoryObjectID(thread)
			listedInterrupted := source.GatewayInterruptedTurns(listedThreadID)
			if len(listedInterrupted) > 0 && rewriteInterruptedGatewayThread(thread, listedInterrupted) {
				changed = true
			}
		}
	case "thread/turns/list":
		turns, ok := result["data"].([]any)
		if ok {
			changed = rewriteInterruptedGatewayTurns(turns, interrupted)
		}
	case "thread/read", "thread/resume":
		thread, ok := result["thread"].(map[string]any)
		if ok && gatewayHistoryObjectID(thread) == threadID {
			changed = rewriteInterruptedGatewayThread(thread, interrupted)
		}
	}
	if !changed {
		return payload, false
	}
	rewritten, err := json.Marshal(frame)
	if err != nil {
		return payload, false
	}
	return rewritten, true
}

func rewriteInterruptedGatewayThread(thread map[string]any, interrupted map[string]time.Time) bool {
	turns, ok := thread["turns"].([]any)
	if !ok {
		return false
	}
	changed := rewriteInterruptedGatewayTurns(turns, interrupted)
	if !changed {
		return false
	}
	for _, rawTurn := range turns {
		turn, ok := rawTurn.(map[string]any)
		if !ok || !gatewayHistoryTurnTerminal(turn) {
			// 未知或非终态可能是更新的真实 Turn；保留 active thread 状态。
			return true
		}
	}
	thread["status"] = map[string]any{"type": "idle"}
	return true
}

func rewriteInterruptedGatewayTurns(turns []any, interrupted map[string]time.Time) bool {
	changed := false
	for _, rawTurn := range turns {
		turn, ok := rawTurn.(map[string]any)
		if !ok {
			continue
		}
		turnID := gatewayHistoryObjectID(turn)
		interruptedAt, ok := interrupted[turnID]
		if !ok || gatewayHistoryTurnTerminal(turn) {
			continue
		}
		turn["status"] = "interrupted"
		if completedAt, exists := turn["completedAt"]; !exists || completedAt == nil {
			turn["completedAt"] = interruptedAt.Unix()
		}
		changed = true
	}
	return changed
}

func gatewayHistoryObjectID(object map[string]any) string {
	for _, key := range []string{"id", "turnId", "threadId", "sessionId"} {
		if value, ok := object[key].(string); ok {
			if value = strings.TrimSpace(value); value != "" {
				return value
			}
		}
	}
	return ""
}

func gatewayHistoryTurnTerminal(turn map[string]any) bool {
	status, _ := turn["status"].(string)
	status = strings.ToLower(strings.TrimSpace(status))
	status = strings.NewReplacer("_", "", "-", "", " ", "").Replace(status)
	switch status {
	case "completed", "complete", "failed", "error", "interrupted", "cancelled", "canceled", "aborted":
		return true
	default:
		return false
	}
}

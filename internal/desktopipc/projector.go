package desktopipc

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
)

var nonTokenCharacter = regexp.MustCompile(`[^a-z0-9]+`)

var supportedItemTypes = map[string]bool{
	"usermessage":  true,
	"agentmessage": true, "assistantmessage": true, "message": true,
	"plan": true, "todolist": true, "reasoning": true, "commandexecution": true,
	"filechange": true, "toolcall": true, "mcptoolcall": true, "dynamictoolcall": true,
	"collabagenttoolcall": true, "collabtoolcall": true, "websearch": true,
	"imageview": true, "imagegeneration": true,
}

var mobileItemType = map[string]string{
	"usermessage": "userMessage", "agentmessage": "agentMessage",
	"assistantmessage": "agentMessage", "message": "agentMessage",
	"plan": "plan", "todolist": "plan", "reasoning": "reasoning",
	"commandexecution": "commandExecution", "filechange": "fileChange",
	"toolcall": "dynamicToolCall", "mcptoolcall": "mcpToolCall",
	"dynamictoolcall": "dynamicToolCall", "collabagenttoolcall": "collabAgentToolCall",
	"collabtoolcall": "collabAgentToolCall", "websearch": "webSearch",
	"imageview": "imageView", "imagegeneration": "imageGeneration",
}

type Projection struct {
	Thread              map[string]any
	Turns               []any
	ActiveTurnID        string
	ActiveTurnIDTrusted bool
}

func ProjectConversationState(threadID string, state map[string]any, now time.Time) (Projection, error) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" || state == nil {
		return Projection{}, fmt.Errorf("Desktop conversation state is incomplete")
	}
	turns := make([]any, 0)
	activeTurnID := ""
	for index, raw := range conversationTurns(state) {
		turn, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		projected := projectTurn(turn, index)
		if projected == nil {
			continue
		}
		turns = append(turns, projected)
		if normalizeTurnStatus(projected["status"]) == "inProgress" {
			activeTurnID = stringValue(projected["id"])
		}
	}
	createdAt := timestampValue(firstValue(state, "createdAt", "created_at"))
	if createdAt == nil {
		createdAt = now.UnixMilli()
	}
	updatedAt := timestampValue(firstValue(state, "updatedAt", "updated_at"))
	if updatedAt == nil {
		updatedAt = now.UnixMilli()
	}
	title := stringValue(state["title"])
	runtimeSettings, _ := firstValue(state, "mimiRuntimeSettings", "remodexRuntimeSettings", "remodex_runtime_settings").(map[string]any)
	thread := map[string]any{
		"id": threadID, "threadId": threadID, "sessionId": threadID, "session_id": threadID,
		"title": nullableString(title), "name": nullableString(title),
		"preview":       threadPreview(turns),
		"createdAt":     createdAt,
		"updatedAt":     updatedAt,
		"cwd":           firstString(state, "cwd", "current_working_directory"),
		"path":          nullableString(firstString(state, "rolloutPath", "rollout_path")),
		"modelProvider": firstString(state, "modelProvider", "model_provider"),
		"model":         firstNonEmptyString(stringValue(runtimeSettings["model"]), firstString(state, "latestModel", "latest_model")),
		"cliVersion":    firstString(state, "cliVersion", "cli_version"),
		"source":        cloneValue(state["source"]),
		"gitInfo":       cloneValue(firstValue(state, "gitInfo", "git_info")),
		"agentNickname": nullableString(firstString(state, "agentNickname", "agent_nickname")),
		"agentRole":     nullableString(firstString(state, "agentRole", "agent_role")),
		"status":        projectedThreadStatus(state, activeTurnID),
		"tokenUsage":    cloneValue(firstValue(state, "latestTokenUsageInfo", "latest_token_usage_info")),
		"turns":         turns,
	}
	if runtimeSettings != nil {
		thread["reasoningEffort"] = nullableString(stringValue(runtimeSettings["reasoningEffort"]))
		thread["serviceTier"] = nullableString(stringValue(runtimeSettings["serviceTier"]))
		thread["runtimeSettingsRevision"] = runtimeSettings["revision"]
		thread["runtimeSettingsUpdatedAt"] = runtimeSettings["updatedAt"]
		thread["runtimeSettingsSource"] = nullableString(stringValue(runtimeSettings["source"]))
	}
	realActiveTurnID, trusted := RealActiveTurnID(state)
	return Projection{
		Thread: thread, Turns: turns, ActiveTurnID: activeTurnID,
		ActiveTurnIDTrusted: trusted && realActiveTurnID == activeTurnID,
	}, nil
}

// RealActiveTurnID returns an ID only when the raw owner state contains one
// unambiguous active Turn. Synthetic projection IDs are display-only and must
// never authorize Steer or Interrupt.
func RealActiveTurnID(state map[string]any) (string, bool) {
	activeTurnID := ""
	for _, raw := range conversationTurns(state) {
		turn, ok := raw.(map[string]any)
		if !ok || normalizeTurnStatus(turn["status"]) != "inProgress" {
			continue
		}
		turnID := firstString(turn, "turnId", "turn_id", "id")
		if turnID == "" || activeTurnID != "" {
			return "", false
		}
		activeTurnID = turnID
	}
	return activeTurnID, activeTurnID != ""
}

// 已验证的 Desktop profile 会把 hydrated history 存为 canonical island graph。Legacy
// state keeps using the flat turns array.
func conversationTurns(state map[string]any) []any {
	turnHistory, _ := state["turnHistory"].(map[string]any)
	if normalizeToken(stringValue(turnHistory["kind"])) != "canonical" {
		return anySlice(state["turns"])
	}
	history, _ := turnHistory["history"].(map[string]any)
	entities, _ := history["entitiesByKey"].(map[string]any)
	if len(entities) == 0 {
		return nil
	}
	turns := make([]any, 0, len(entities))
	for _, rawIsland := range anySlice(history["islands"]) {
		island, _ := rawIsland.(map[string]any)
		for _, rawEntry := range anySlice(island["entries"]) {
			entry, _ := rawEntry.(map[string]any)
			turn, ok := entities[stringValue(entry["value"])].(map[string]any)
			if ok {
				turns = append(turns, turn)
			}
		}
	}
	return turns
}

func projectTurn(raw map[string]any, index int) map[string]any {
	turnID := firstString(raw, "turnId", "turn_id", "id")
	if turnID == "" {
		turnID = fmt.Sprintf("ipc-turn-%d", index)
	}
	items := make([]any, 0)
	params, _ := raw["params"].(map[string]any)
	visibleInput := sanitizeUserContent(anySlice(params["input"]))
	visibleInputSignature := visibleUserSignature(visibleInput)
	if len(visibleInput) > 0 {
		items = append(items, map[string]any{
			"id": turnID + ":input", "type": "userMessage", "content": visibleInput,
			"mimiDesktopIPCMirror": true,
		})
	}
	for _, rawItem := range anySlice(raw["items"]) {
		item, ok := rawItem.(map[string]any)
		if !ok {
			continue
		}
		projected := projectItem(item)
		if projected != nil {
			if normalizeToken(stringValue(projected["type"])) == "usermessage" && visibleInputSignature != "" &&
				visibleUserSignature(anySlice(projected["content"])) == visibleInputSignature {
				continue
			}
			items = append(items, projected)
		}
	}
	return map[string]any{
		"id": turnID, "turnId": turnID,
		"status":      normalizeTurnStatus(raw["status"]),
		"error":       cloneValue(raw["error"]),
		"startedAt":   firstValue(raw, "startedAt", "started_at", "turnStartedAtMs", "turn_started_at_ms"),
		"completedAt": firstValue(raw, "completedAt", "completed_at"),
		"durationMs":  firstValue(raw, "durationMs", "duration_ms"),
		"items":       items,
	}
}

func projectItem(raw map[string]any) map[string]any {
	typeToken := normalizeToken(stringValue(raw["type"]))
	if typeToken == "message" && normalizeToken(stringValue(raw["role"])) == "user" {
		typeToken = "usermessage"
	}
	if !supportedItemTypes[typeToken] {
		return nil
	}
	copy := projectAllowedItemFields(raw, typeToken)
	if typeToken == "usermessage" {
		content := sanitizeUserContent(anySlice(copy["content"]))
		if len(content) == 0 {
			return nil
		}
		copy["content"] = content
	}
	if typeToken == "todolist" {
		copy["mimiProgressPlan"] = true
	}
	if canonicalType := mobileItemType[typeToken]; canonicalType != "" {
		if canonicalType != stringValue(raw["type"]) {
			copy["mimiDesktopIPCItemType"] = stringValue(raw["type"])
		}
		copy["type"] = canonicalType
	}
	if typeToken == "toolcall" {
		copy["mimiDesktopIPCItemType"] = stringValue(raw["type"])
	}
	copy["mimiDesktopIPCMirror"] = true
	return copy
}

func projectAllowedItemFields(raw map[string]any, typeToken string) map[string]any {
	fields := []string{
		"id", "itemId", "item_id", "status", "error", "createdAt", "created_at",
		"updatedAt", "updated_at", "startedAt", "started_at", "completedAt", "completed_at", "durationMs", "duration_ms",
	}
	switch typeToken {
	case "usermessage":
		fields = append(fields, "content")
	case "agentmessage", "assistantmessage", "message":
		fields = append(fields, "text", "message", "content", "phase")
	case "plan", "todolist":
		fields = append(fields, "text", "content", "plan", "steps", "items")
	case "reasoning":
		fields = append(fields, "text", "content", "summary", "summaryText", "summary_text")
	case "commandexecution":
		fields = append(fields, "command", "cwd", "aggregatedOutput", "aggregated_output", "output", "stdout", "stderr", "exitCode", "exit_code")
	case "filechange":
		fields = append(fields, "changes", "diff", "patch", "output")
	case "toolcall", "mcptoolcall", "dynamictoolcall", "collabagenttoolcall", "collabtoolcall":
		fields = append(fields, "name", "server", "tool", "arguments", "input", "output", "result", "response")
	case "websearch":
		fields = append(fields, "query", "action", "url", "results", "output")
	case "imageview", "imagegeneration":
		fields = append(fields, "path", "url", "imageUrl", "image_url", "alt", "text", "output")
	}
	projected := make(map[string]any, len(fields)+2)
	for _, key := range fields {
		if value, exists := raw[key]; exists {
			projected[key] = cloneValue(value)
		}
	}
	projected["type"] = raw["type"]
	return projected
}

func sanitizeUserContent(content []any) []any {
	visible := make([]any, 0, len(content))
	for _, entry := range content {
		switch value := entry.(type) {
		case string:
			if text := visibleUserText(value); text != "" {
				visible = append(visible, text)
			}
		case map[string]any:
			textKey := ""
			for _, key := range []string{"text", "message", "content"} {
				if _, ok := value[key].(string); ok {
					textKey = key
					break
				}
			}
			if textKey == "" {
				if safe := safeStructuredUserContent(value); safe != nil {
					visible = append(visible, safe)
				}
				continue
			}
			text := visibleUserText(stringValue(value[textKey]))
			if text == "" {
				continue
			}
			// User text can carry Desktop-only sibling metadata. Keep only the
			// display schema so private host context cannot reach mobile clients.
			entry := map[string]any{textKey: text}
			if typeValue := strings.TrimSpace(stringValue(value["type"])); typeValue != "" {
				entry["type"] = typeValue
			}
			visible = append(visible, entry)
		}
	}
	return visible
}

func safeStructuredUserContent(value map[string]any) map[string]any {
	typeToken := normalizeToken(stringValue(value["type"]))
	if typeToken != "image" && typeToken != "inputimage" && typeToken != "localimage" {
		return nil
	}
	allowed := []string{"type", "path", "url", "imageUrl", "image_url", "name", "mimeType", "mime_type"}
	result := make(map[string]any, len(allowed))
	for _, key := range allowed {
		if field, exists := value[key]; exists {
			result[key] = cloneValue(field)
		}
	}
	if len(result) <= 1 {
		return nil
	}
	return result
}

func visibleUserSignature(content []any) string {
	visible := sanitizeUserContent(content)
	parts := make([]string, 0, len(visible))
	for _, entry := range visible {
		switch value := entry.(type) {
		case string:
			parts = append(parts, value)
		case map[string]any:
			if text := firstString(value, "text", "message", "content"); text != "" {
				parts = append(parts, text)
			}
		}
	}
	return strings.Join(strings.Fields(strings.Join(parts, "\n")), " ")
}

func visibleUserText(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}
	for _, prefix := range []string{
		"<environment_context>", "<skill>", "<user_shell_command>", "<turn_aborted>",
		"<subagent_notification>", "<recommended_plugins>", "<goal_context>", "<user_action>",
		"# AGENTS.md instructions", "<codex_internal_context", "<external_",
	} {
		if strings.HasPrefix(strings.ToLower(trimmed), strings.ToLower(prefix)) {
			marker := "## My request for Codex:"
			if index := strings.LastIndex(trimmed, marker); index >= 0 {
				return strings.TrimSpace(trimmed[index+len(marker):])
			}
			return ""
		}
	}
	const requestMarker = "## My request for Codex:"
	if index := strings.LastIndex(trimmed, requestMarker); index >= 0 {
		return strings.TrimSpace(trimmed[index+len(requestMarker):])
	}
	return value
}

func normalizeTurnStatus(value any) string {
	switch normalizeToken(stringValue(value)) {
	case "inprogress", "running", "active", "processing":
		return "inProgress"
	case "interrupted", "cancelled", "canceled", "stopped":
		return "interrupted"
	case "failed", "error", "systemerror":
		return "failed"
	default:
		return "completed"
	}
}

func projectedThreadStatus(state map[string]any, activeTurnID string) any {
	if status := firstValue(state, "threadRuntimeStatus", "thread_runtime_status"); status != nil {
		return cloneValue(status)
	}
	if activeTurnID != "" {
		return map[string]any{"type": "active", "activeFlags": []any{}}
	}
	return map[string]any{"type": "idle"}
}

func threadPreview(turns []any) string {
	for _, rawTurn := range turns {
		turn, _ := rawTurn.(map[string]any)
		items := anySlice(turn["items"])
		for _, rawItem := range items {
			item, _ := rawItem.(map[string]any)
			if normalizeToken(stringValue(item["type"])) != "usermessage" {
				continue
			}
			if text := visibleUserSignature(anySlice(item["content"])); text != "" {
				return text
			}
		}
	}
	return ""
}

func anySlice(value any) []any {
	result, _ := value.([]any)
	return result
}

func firstValue(value map[string]any, keys ...string) any {
	for _, key := range keys {
		if result, exists := value[key]; exists && result != nil {
			return result
		}
	}
	return nil
}

func firstString(value map[string]any, keys ...string) string {
	for _, key := range keys {
		if result := stringValue(value[key]); result != "" {
			return result
		}
	}
	return ""
}

func stringValue(value any) string {
	result, _ := value.(string)
	return strings.TrimSpace(result)
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func normalizeToken(value string) string {
	return nonTokenCharacter.ReplaceAllString(strings.ToLower(strings.TrimSpace(value)), "")
}

func nullableString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func timestampValue(value any) any {
	switch typed := value.(type) {
	case float64:
		return typed
	case int64:
		return typed
	case int:
		return typed
	case string:
		if parsed, err := time.Parse(time.RFC3339Nano, typed); err == nil {
			return parsed.UnixMilli()
		}
	}
	return nil
}

func projectionJSON(value any) string {
	payload, _ := json.Marshal(value)
	return string(payload)
}

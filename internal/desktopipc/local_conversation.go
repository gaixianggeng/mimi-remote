package desktopipc

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
)

// LocalConversation converts the owning App Server's standard notifications
// into the conversationState consumed by Codex Desktop followers.
type LocalConversation struct {
	mu            sync.RWMutex
	threads       map[string]map[string]any
	pendingStarts map[string][]pendingTurnStart
	nextStartID   uint64
}

type pendingTurnStart struct {
	id     uint64
	params map[string]any
}

func NewLocalConversation() *LocalConversation {
	return &LocalConversation{
		threads: make(map[string]map[string]any), pendingStarts: make(map[string][]pendingTurnStart),
	}
}

func (c *LocalConversation) SeedThread(thread map[string]any) (string, map[string]any, error) {
	threadID := firstString(thread, "id", "threadId", "thread_id")
	if threadID == "" {
		return "", nil, fmt.Errorf("App Server thread is missing id")
	}
	c.mu.Lock()
	state := buildLocalConversationState(thread, c.threads[threadID], time.Now())
	c.threads[threadID] = state
	c.mu.Unlock()
	return threadID, cloneState(state), nil
}

func (c *LocalConversation) State(threadID string) (map[string]any, bool) {
	c.mu.RLock()
	state, ok := c.threads[strings.TrimSpace(threadID)]
	c.mu.RUnlock()
	if !ok {
		return nil, false
	}
	return cloneState(state), true
}

// RememberTurnStart keeps the initiating request until turn/started supplies
// the canonical turn ID. Desktop renders the initial prompt from params.input.
func (c *LocalConversation) RememberTurnStart(threadID string, params map[string]any) uint64 {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nextStartID++
	entry := pendingTurnStart{id: c.nextStartID, params: normalizeLocalTurnParams(threadID, "", params)}
	c.pendingStarts[threadID] = append(c.pendingStarts[threadID], entry)
	return entry.id
}

func (c *LocalConversation) ForgetTurnStart(threadID string, startID uint64) {
	if startID == 0 {
		return
	}
	threadID = strings.TrimSpace(threadID)
	c.mu.Lock()
	defer c.mu.Unlock()
	queue := c.pendingStarts[threadID]
	for index, entry := range queue {
		if entry.id != startID {
			continue
		}
		queue = append(queue[:index], queue[index+1:]...)
		if len(queue) == 0 {
			delete(c.pendingStarts, threadID)
		} else {
			c.pendingStarts[threadID] = queue
		}
		return
	}
}

func (c *LocalConversation) Apply(method string, params map[string]any) (string, map[string]any, bool) {
	threadID := firstString(params, "threadId", "thread_id")
	if method == "thread/started" {
		thread, _ := params["thread"].(map[string]any)
		seededID, state, err := c.SeedThread(thread)
		return seededID, state, err == nil
	}
	if threadID == "" {
		return "", nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	state := c.ensureThread(threadID)
	var pending map[string]any
	if method == "turn/started" {
		pending = c.consumeTurnStart(threadID)
	}
	changed := applyLocalNotification(state, method, params, pending)
	if !changed {
		return threadID, nil, false
	}
	state["updatedAt"] = time.Now().UnixMilli()
	return threadID, cloneState(state), true
}

func (c *LocalConversation) consumeTurnStart(threadID string) map[string]any {
	queue := c.pendingStarts[threadID]
	if len(queue) == 0 {
		return nil
	}
	entry := queue[0]
	if len(queue) == 1 {
		delete(c.pendingStarts, threadID)
	} else {
		c.pendingStarts[threadID] = queue[1:]
	}
	return entry.params
}

func (c *LocalConversation) RememberRequest(id any, method string, params map[string]any) (string, map[string]any, bool) {
	threadID := firstString(params, "threadId", "thread_id")
	if threadID == "" || id == nil {
		return "", nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	state := c.ensureThread(threadID)
	requests := removeLocalRequest(anySlice(state["requests"]), id)
	requests = append(requests, map[string]any{"id": cloneValue(id), "method": method, "params": cloneValue(params)})
	state["requests"] = requests
	return threadID, cloneState(state), true
}

func (c *LocalConversation) ResolveRequest(threadID string, id any) (map[string]any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	state, ok := c.threads[strings.TrimSpace(threadID)]
	if !ok {
		return nil, false
	}
	requests := anySlice(state["requests"])
	next := removeLocalRequest(requests, id)
	if len(next) == len(requests) {
		return nil, false
	}
	state["requests"] = next
	return cloneState(state), true
}

func (c *LocalConversation) ensureThread(threadID string) map[string]any {
	state := c.threads[threadID]
	if state == nil {
		state = emptyLocalConversationState(threadID, time.Now())
		c.threads[threadID] = state
	}
	return state
}

func buildLocalConversationState(thread, previous map[string]any, now time.Time) map[string]any {
	threadID := firstString(thread, "id", "threadId", "thread_id")
	state := emptyLocalConversationState(threadID, now)
	if previous != nil {
		for _, key := range []string{
			"requests", "latestReasoningEffort", "latestServiceTier", "previousTurnModel",
			"latestCollaborationMode", "hasUnreadTurn", "unreadMessageCount", "threadGoal",
			"completedThreadGoal", "latestTokenUsageInfo", "workspaceKind", "workspaceBrowserRoot",
			"projectlessOutputDirectory", "currentPermissions",
		} {
			if value, exists := previous[key]; exists {
				state[key] = cloneValue(value)
			}
		}
	}
	state["createdAt"] = localTimestampMillis(firstValue(thread, "createdAt", "created_at"), int64Value(previous, "createdAt"), now.UnixMilli())
	state["updatedAt"] = localTimestampMillis(firstValue(thread, "updatedAt", "updated_at"), now.UnixMilli())
	state["title"] = nullableString(firstNonEmptyString(firstString(thread, "name", "title"), firstString(previous, "title")))
	state["cwd"] = firstNonEmptyString(firstString(thread, "cwd"), firstString(previous, "cwd"))
	state["rolloutPath"] = firstNonEmptyString(firstString(thread, "path"), firstString(previous, "rolloutPath"))
	state["gitInfo"] = cloneValue(firstValue(thread, "gitInfo", "git_info"))
	if state["gitInfo"] == nil && previous != nil {
		state["gitInfo"] = cloneValue(previous["gitInfo"])
	}
	model := firstNonEmptyString(firstString(thread, "model", "modelProvider", "model_provider"), firstString(previous, "latestModel"))
	state["latestModel"] = model
	if previous == nil || state["latestCollaborationMode"] == nil {
		state["latestCollaborationMode"] = localCollaborationMode(model, "")
	}
	if status := firstValue(thread, "status"); status != nil {
		state["threadRuntimeStatus"] = cloneValue(status)
	} else if previous != nil {
		state["threadRuntimeStatus"] = cloneValue(previous["threadRuntimeStatus"])
	}
	state["turns"] = mergeLocalTurns(anySlice(thread["turns"]), anySlice(firstValue(previous, "turns")), threadID, stringValue(state["cwd"]), now)
	return state
}

func emptyLocalConversationState(threadID string, now time.Time) map[string]any {
	stamp := now.UnixMilli()
	return map[string]any{
		"id": threadID, "hostId": "local", "turns": []any{}, "requests": []any{},
		"createdAt": stamp, "updatedAt": stamp, "title": nil, "latestModel": "",
		"latestReasoningEffort": nil, "latestServiceTier": nil, "previousTurnModel": nil,
		"latestCollaborationMode": localCollaborationMode("", ""),
		"hasUnreadTurn":           false, "unreadMessageCount": 0, "threadGoal": nil, "completedThreadGoal": nil,
		"threadRuntimeStatus": nil, "rolloutPath": "", "cwd": "", "gitInfo": nil,
		"resumeState": "resumed", "latestTokenUsageInfo": nil, "workspaceKind": "project",
		"workspaceBrowserRoot": nil, "projectlessOutputDirectory": nil, "currentPermissions": nil,
	}
}

func mergeLocalTurns(rawTurns, previousTurns []any, threadID, cwd string, now time.Time) []any {
	previousByID := make(map[string]map[string]any)
	for _, raw := range previousTurns {
		turn, _ := raw.(map[string]any)
		if turnID := firstString(turn, "id", "turnId", "turn_id"); turnID != "" {
			previousByID[turnID] = turn
		}
	}
	if len(rawTurns) == 0 {
		return cloneSlice(previousTurns)
	}
	result := make([]any, 0, len(rawTurns))
	for _, raw := range rawTurns {
		turn, _ := raw.(map[string]any)
		turnID := firstString(turn, "id", "turnId", "turn_id")
		if turnID == "" {
			continue
		}
		result = append(result, buildLocalTurn(turn, threadID, cwd, previousByID[turnID], now))
	}
	return result
}

func buildLocalTurn(raw map[string]any, threadID, cwd string, previous map[string]any, now time.Time) map[string]any {
	turnID := firstString(raw, "id", "turnId", "turn_id")
	params, _ := previous["params"].(map[string]any)
	params = normalizeLocalTurnParams(threadID, cwd, params)
	if rawParams, ok := raw["params"].(map[string]any); ok {
		params = mergeLocalTurnParams(params, rawParams)
	}
	items := normalizeLocalItems(anySlice(raw["items"]))
	if len(items) == 0 {
		items = normalizeLocalItems(anySlice(previous["items"]))
	}
	turn := map[string]any{
		"id": turnID, "turnId": turnID, "params": params,
		"turnStartedAtMs":              localTimestampMillis(firstValue(raw, "startedAt", "started_at", "createdAt"), int64Value(previous, "turnStartedAtMs"), now.UnixMilli()),
		"durationMs":                   firstValue(raw, "durationMs", "duration_ms"),
		"firstTurnWorkItemStartedAtMs": firstValue(previous, "firstTurnWorkItemStartedAtMs"),
		"finalAssistantStartedAtMs":    firstValue(previous, "finalAssistantStartedAtMs"),
		"status":                       firstNonNil(firstValue(raw, "status"), firstValue(previous, "status"), "inProgress"),
		"error":                        cloneValue(firstNonNil(firstValue(raw, "error"), firstValue(previous, "error"))),
		"diff":                         cloneValue(firstValue(previous, "diff")), "hookRuns": cloneSlice(firstValue(previous, "hookRuns")),
		"commandExecutionStartedAtMsById": cloneMap(firstValue(previous, "commandExecutionStartedAtMsById")),
		"items":                           items,
	}
	if turn["durationMs"] == nil {
		turn["durationMs"] = firstValue(previous, "durationMs")
	}
	normalizeLocalInitialPrompt(turn)
	markLocalTurnTiming(turn, now.UnixMilli())
	return turn
}

func normalizeLocalTurnParams(threadID, cwd string, raw map[string]any) map[string]any {
	params := map[string]any{
		"threadId": threadID, "input": []any{}, "cwd": nullableString(cwd), "approvalPolicy": nil,
		"approvalsReviewer": nil, "sandboxPolicy": nil, "model": nil, "serviceTier": nil,
		"effort": nil, "summary": "none", "personality": nil, "outputSchema": nil,
		"collaborationMode": nil, "attachments": []any{},
	}
	return mergeLocalTurnParams(params, raw)
}

func mergeLocalTurnParams(base, raw map[string]any) map[string]any {
	result, _ := cloneObject(base)
	for key, value := range raw {
		result[key] = cloneValue(value)
	}
	result["input"] = normalizeDesktopInput(anySlice(result["input"]))
	if result["attachments"] == nil {
		result["attachments"] = []any{}
	}
	return result
}

func normalizeDesktopInput(input []any) []any {
	visible := sanitizeUserContent(input)
	result := make([]any, 0, len(visible))
	for _, entry := range visible {
		switch value := entry.(type) {
		case string:
			result = append(result, map[string]any{"type": "text", "text": value})
		case map[string]any:
			copy, _ := cloneObject(value)
			switch normalizeToken(stringValue(copy["type"])) {
			case "inputtext":
				copy["type"] = "text"
			case "imageurl":
				copy["type"] = "image"
				if copy["url"] == nil {
					copy["url"] = firstValue(copy, "image_url", "imageUrl")
				}
			}
			result = append(result, copy)
		}
	}
	return result
}

func normalizeLocalItems(items []any) []any {
	result := make([]any, 0, len(items))
	for _, raw := range items {
		item, _ := raw.(map[string]any)
		if normalized := normalizeLocalItem(item); normalized != nil {
			result = append(result, normalized)
		}
	}
	return result
}

func normalizeLocalItem(item map[string]any) map[string]any {
	if item == nil {
		return nil
	}
	copy, err := cloneObject(item)
	if err != nil {
		return nil
	}
	if isLocalUserItem(copy) {
		content := sanitizeUserContent(anySlice(copy["content"]))
		if len(content) == 0 {
			return nil
		}
		copy["content"] = content
	}
	if normalizeToken(stringValue(copy["type"])) == "collabagenttoolcall" {
		ids := anySlice(copy["receiverThreadIds"])
		threads := anySlice(copy["receiverThreads"])
		if copy["receiverThreadIds"] == nil {
			ids = make([]any, 0, len(threads))
			for _, rawThread := range threads {
				thread, _ := rawThread.(map[string]any)
				if id := firstString(thread, "threadId", "id"); id != "" {
					ids = append(ids, id)
				}
			}
			copy["receiverThreadIds"] = ids
		}
		if copy["receiverThreads"] == nil {
			threads = make([]any, 0, len(ids))
			for _, id := range ids {
				threads = append(threads, map[string]any{"threadId": id})
			}
			copy["receiverThreads"] = threads
		}
	}
	return copy
}

func normalizeLocalInitialPrompt(turn map[string]any) {
	params, _ := turn["params"].(map[string]any)
	input := normalizeDesktopInput(anySlice(params["input"]))
	params["input"] = input
	inputSignature := visibleUserSignature(input)
	items := anySlice(turn["items"])
	for index, raw := range items {
		item, _ := raw.(map[string]any)
		if !isLocalUserItem(item) {
			continue
		}
		content := anySlice(item["content"])
		if len(input) == 0 {
			params["input"] = normalizeDesktopInput(content)
			items = append(items[:index], items[index+1:]...)
		} else if visibleUserSignature(content) == inputSignature {
			items = append(items[:index], items[index+1:]...)
		}
		break
	}
	turn["items"] = items
}

func isLocalUserItem(item map[string]any) bool {
	typeToken := normalizeToken(stringValue(item["type"]))
	return typeToken == "usermessage" || (typeToken == "message" && normalizeToken(stringValue(item["role"])) == "user")
}

func applyLocalNotification(state map[string]any, method string, params, pendingStart map[string]any) bool {
	turnID := firstString(params, "turnId", "turn_id")
	switch method {
	case "thread/name/updated":
		state["title"] = nullableString(firstString(params, "threadName", "thread_name", "name", "title"))
		return true
	case "thread/status/changed":
		state["threadRuntimeStatus"] = cloneValue(params["status"])
		return true
	case "thread/tokenUsage/updated":
		state["latestTokenUsageInfo"] = cloneValue(firstNonNil(params["tokenUsage"], params["usage"]))
		return true
	case "thread/goal/updated":
		state["threadGoal"] = cloneValue(params["goal"])
		state["completedThreadGoal"] = nil
		return true
	case "thread/goal/cleared":
		state["threadGoal"], state["completedThreadGoal"] = nil, nil
		return true
	case "turn/started", "turn/completed":
		raw, _ := params["turn"].(map[string]any)
		if raw == nil {
			raw = map[string]any{"id": turnID}
		}
		if firstString(raw, "id", "turnId") == "" {
			raw["id"] = turnID
		}
		if method == "turn/started" {
			raw["status"] = "inProgress"
		} else if raw["status"] == nil {
			raw["status"] = firstNonEmptyString(stringValue(params["status"]), "completed")
		}
		previous := findLocalTurn(state, firstString(raw, "id", "turnId"))
		turn := buildLocalTurn(raw, stringValue(state["id"]), stringValue(state["cwd"]), previous, time.Now())
		if pendingStart != nil {
			turn["params"] = mergeLocalTurnParams(turn["params"].(map[string]any), pendingStart)
			normalizeLocalInitialPrompt(turn)
			applyLocalRuntimeMetadata(state, pendingStart)
		}
		upsertLocalTurn(state, turn)
		return true
	case "turn/diff/updated":
		turn := ensureLocalTurn(state, turnID)
		turn["diff"] = stringValue(params["diff"])
		return turnID != ""
	case "turn/plan/updated":
		if turnID == "" {
			return false
		}
		upsertLocalItem(state, turnID, map[string]any{
			"id": "todo-list-" + turnID, "type": "todo-list", "explanation": params["explanation"],
			"plan": cloneSlice(params["plan"]), "mimiProgressPlan": true,
		})
		return true
	case "item/started", "item/completed":
		item, _ := params["item"].(map[string]any)
		item = normalizeLocalItem(item)
		if item == nil || turnID == "" {
			return false
		}
		if method == "item/completed" && item["status"] == nil {
			item["status"] = "completed"
		}
		upsertLocalItem(state, turnID, item)
		markLocalTurnTiming(ensureLocalTurn(state, turnID), time.Now().UnixMilli())
		return true
	}
	if turnID == "" {
		return false
	}
	itemID := firstString(params, "itemId", "item_id")
	delta := stringValue(params["delta"])
	if itemID == "" || delta == "" {
		return false
	}
	index := numericIndex(params, "summaryIndex", "contentIndex")
	switch method {
	case "item/agentMessage/delta":
		appendLocalItemText(state, turnID, itemID, "agentMessage", "text", delta)
	case "item/plan/delta":
		appendLocalItemText(state, turnID, itemID, "plan", "text", delta)
	case "item/reasoning/summaryTextDelta":
		appendLocalItemArrayText(state, turnID, itemID, "reasoning", "summary", index, delta)
	case "item/reasoning/textDelta":
		appendLocalItemArrayText(state, turnID, itemID, "reasoning", "content", index, delta)
	case "item/commandExecution/outputDelta", "command/exec/outputDelta":
		appendLocalItemText(state, turnID, itemID, "commandExecution", "aggregatedOutput", delta)
	case "item/fileChange/outputDelta":
		appendLocalItemText(state, turnID, itemID, "fileChange", "aggregatedOutput", delta)
	case "item/toolCall/outputDelta":
		appendLocalItemText(state, turnID, itemID, "dynamicToolCall", "output", delta)
	default:
		return false
	}
	markLocalTurnTiming(ensureLocalTurn(state, turnID), time.Now().UnixMilli())
	return true
}

func applyLocalRuntimeMetadata(state, params map[string]any) {
	model := firstString(params, "model")
	effort := firstString(params, "effort", "reasoningEffort", "reasoning_effort")
	if model != "" {
		state["previousTurnModel"] = state["latestModel"]
		state["latestModel"] = model
	}
	if effort != "" {
		state["latestReasoningEffort"] = effort
	}
	if serviceTier := firstValue(params, "serviceTier", "service_tier"); serviceTier != nil {
		state["latestServiceTier"] = cloneValue(serviceTier)
	}
	if mode, ok := params["collaborationMode"].(map[string]any); ok {
		state["latestCollaborationMode"] = cloneValue(mode)
	} else if model != "" || effort != "" {
		state["latestCollaborationMode"] = localCollaborationMode(model, effort)
	}
}

func localCollaborationMode(model, effort string) map[string]any {
	return map[string]any{"mode": "default", "settings": map[string]any{
		"reasoning_effort": nullableString(effort), "model": model, "developer_instructions": nil,
	}}
}

func upsertLocalTurn(state map[string]any, turn map[string]any) {
	turnID := firstString(turn, "id", "turnId", "turn_id")
	turns := anySlice(state["turns"])
	for index, raw := range turns {
		current, _ := raw.(map[string]any)
		if firstString(current, "id", "turnId", "turn_id") == turnID {
			turns[index] = turn
			state["turns"] = turns
			return
		}
	}
	state["turns"] = append(turns, turn)
}

func upsertLocalItem(state map[string]any, turnID string, item map[string]any) {
	turn := ensureLocalTurn(state, turnID)
	itemID := firstString(item, "id", "itemId", "item_id")
	items := anySlice(turn["items"])
	for index, raw := range items {
		current, _ := raw.(map[string]any)
		if firstString(current, "id", "itemId", "item_id") == itemID {
			merged, _ := cloneObject(current)
			for key, value := range item {
				merged[key] = cloneValue(value)
			}
			items[index] = merged
			turn["items"] = items
			return
		}
	}
	if isLocalUserItem(item) {
		params, _ := turn["params"].(map[string]any)
		if visibleUserSignature(anySlice(params["input"])) == visibleUserSignature(anySlice(item["content"])) {
			return
		}
	}
	turn["items"] = append(items, item)
}

func appendLocalItemText(state map[string]any, turnID, itemID, itemType, field, delta string) {
	item := ensureLocalItem(state, turnID, itemID, itemType)
	item[field] = stringValue(item[field]) + delta
}

func appendLocalItemArrayText(state map[string]any, turnID, itemID, itemType, field string, index int, delta string) {
	item := ensureLocalItem(state, turnID, itemID, itemType)
	values := anySlice(item[field])
	for len(values) <= index {
		values = append(values, "")
	}
	values[index] = stringValue(values[index]) + delta
	item[field] = values
}

func ensureLocalItem(state map[string]any, turnID, itemID, itemType string) map[string]any {
	turn := ensureLocalTurn(state, turnID)
	for _, raw := range anySlice(turn["items"]) {
		item, _ := raw.(map[string]any)
		if firstString(item, "id", "itemId", "item_id") == itemID {
			return item
		}
	}
	item := map[string]any{"id": itemID, "type": itemType, "status": "inProgress"}
	turn["items"] = append(anySlice(turn["items"]), item)
	return item
}

func ensureLocalTurn(state map[string]any, turnID string) map[string]any {
	if turn := findLocalTurn(state, turnID); turn != nil {
		return turn
	}
	turn := buildLocalTurn(map[string]any{"id": turnID}, stringValue(state["id"]), stringValue(state["cwd"]), nil, time.Now())
	state["turns"] = append(anySlice(state["turns"]), turn)
	return turn
}

func findLocalTurn(state map[string]any, turnID string) map[string]any {
	for _, raw := range anySlice(state["turns"]) {
		turn, _ := raw.(map[string]any)
		if firstString(turn, "id", "turnId", "turn_id") == turnID {
			return turn
		}
	}
	return nil
}

func markLocalTurnTiming(turn map[string]any, now int64) {
	for _, raw := range anySlice(turn["items"]) {
		item, _ := raw.(map[string]any)
		if isLocalUserItem(item) {
			continue
		}
		if turn["firstTurnWorkItemStartedAtMs"] == nil {
			turn["firstTurnWorkItemStartedAtMs"] = now
		}
		if normalizeToken(stringValue(item["type"])) == "agentmessage" && turn["finalAssistantStartedAtMs"] == nil {
			turn["finalAssistantStartedAtMs"] = now
		}
	}
}

func removeLocalRequest(requests []any, id any) []any {
	key := requestIdentity(id)
	result := make([]any, 0, len(requests))
	for _, raw := range requests {
		request, _ := raw.(map[string]any)
		if requestIdentity(request["id"]) != key {
			result = append(result, raw)
		}
	}
	return result
}

func localTimestampMillis(value any, fallbacks ...int64) int64 {
	var result int64
	switch typed := value.(type) {
	case json.Number:
		parsed, _ := typed.Float64()
		result = int64(parsed)
	case float64:
		result = int64(typed)
	case int64:
		result = typed
	case int:
		result = int64(typed)
	case string:
		if parsed, err := time.Parse(time.RFC3339Nano, typed); err == nil {
			return parsed.UnixMilli()
		}
	}
	if result > 0 && result < 1_000_000_000_000 {
		return result * 1000
	}
	if result > 0 {
		return result
	}
	for _, fallback := range fallbacks {
		if fallback > 0 {
			return fallback
		}
	}
	return 0
}

func int64Value(value map[string]any, key string) int64 {
	if value == nil {
		return 0
	}
	return localTimestampMillis(value[key])
}

func numericIndex(value map[string]any, keys ...string) int {
	for _, key := range keys {
		switch typed := value[key].(type) {
		case json.Number:
			if parsed, err := typed.Int64(); err == nil && parsed >= 0 {
				return int(parsed)
			}
		case float64:
			if typed >= 0 {
				return int(typed)
			}
		case int:
			if typed >= 0 {
				return typed
			}
		}
	}
	return 0
}

func firstNonNil(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func cloneSlice(value any) []any {
	if values, ok := cloneValue(value).([]any); ok {
		return values
	}
	return []any{}
}

func cloneMap(value any) map[string]any {
	if object, ok := cloneValue(value).(map[string]any); ok {
		return object
	}
	return map[string]any{}
}

func requestIdentity(value any) string { return fmt.Sprint(value) }

func cloneState(state map[string]any) map[string]any {
	copy, _ := cloneObject(state)
	return copy
}

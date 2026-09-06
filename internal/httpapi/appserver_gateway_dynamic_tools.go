package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	mimiTasksNamespace            = "mimi_tasks"
	mimiTaskPromptMaxCharacters   = 20000
	mimiTaskResultTextMaxBytes    = 32 << 10
	mimiTaskThreadIDMaxCharacters = 256
	mimiTaskDynamicClaimTTL       = 10 * time.Minute
	mimiTaskDynamicClaimMax       = 4096
)

var mimiTaskToolNames = []string{
	"create_thread",
	"list_threads",
	"read_thread",
	"send_message_to_thread",
	"wait_threads",
}

type mimiTaskDynamicClaim struct {
	owner     *appServerGatewayPolicy
	createdAt time.Time
	state     mimiTaskDynamicClaimState
}

type mimiTaskDynamicClaimState uint8

const (
	mimiTaskDynamicClaimActive mimiTaskDynamicClaimState = iota
	mimiTaskDynamicClaimCompleted
	mimiTaskDynamicClaimAbandoned
)

var errMimiTaskDynamicCallAbandoned = errors.New("dynamic task call owner disconnected")

// canonicalMimiTaskDynamicTools treats the client payload only as a versioned opt-in.
// Descriptions and schemas are rebuilt here so an authenticated client cannot inject model tools.
func canonicalMimiTaskDynamicTools(value any) ([]any, bool) {
	entries, ok := value.([]any)
	if !ok || len(entries) != 1 {
		return nil, false
	}
	namespace, ok := entries[0].(map[string]any)
	if !ok || namespace["type"] != "namespace" || namespace["name"] != mimiTasksNamespace {
		return nil, false
	}
	tools, ok := namespace["tools"].([]any)
	if !ok || len(tools) != len(mimiTaskToolNames) {
		return nil, false
	}
	names := make([]string, 0, len(tools))
	for _, value := range tools {
		tool, ok := value.(map[string]any)
		name, nameOK := tool["name"].(string)
		if !ok || !nameOK || tool["type"] != "function" {
			return nil, false
		}
		names = append(names, name)
	}
	sort.Strings(names)
	want := append([]string(nil), mimiTaskToolNames...)
	sort.Strings(want)
	if !reflect.DeepEqual(names, want) {
		return nil, false
	}
	return canonicalMimiTaskDynamicToolDefinitions(), true
}

func canonicalMimiTaskDynamicToolDefinitions() []any {
	objectSchema := func(properties map[string]any, required ...string) map[string]any {
		return map[string]any{
			"type":       "object",
			"properties": properties,
			// 可选参数工具也必须编码为数组；nil 会变成无效的 JSON Schema null。
			"required":             append([]string{}, required...),
			"additionalProperties": false,
		}
	}
	threadIDSchema := map[string]any{"type": "string", "minLength": 1, "maxLength": 256}
	promptSchema := map[string]any{"type": "string", "minLength": 1, "maxLength": 20000}
	functions := []any{
		mimiTaskFunction("create_thread", "Create a user-visible, user-owned independent task on the current host and project. Use only when the user explicitly asks for a separate task; use subagents for internal parallel work.", objectSchema(map[string]any{"prompt": promptSchema}, "prompt")),
		mimiTaskFunction("list_threads", "List user-visible independent tasks from the current authorized Mimi host and project.", objectSchema(map[string]any{"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 50, "default": 20}})),
		mimiTaskFunction("read_thread", "Read one user-visible independent task from the current authorized Mimi host and project.", objectSchema(map[string]any{"threadId": threadIDSchema}, "threadId")),
		mimiTaskFunction("send_message_to_thread", "Continue one user-visible independent task in the current authorized Mimi host and project.", objectSchema(map[string]any{"threadId": threadIDSchema, "prompt": promptSchema}, "threadId", "prompt")),
		mimiTaskFunction("wait_threads", "Wait for user-visible independent tasks in the current authorized Mimi host and project.", objectSchema(map[string]any{
			"threadIds": map[string]any{"type": "array", "items": threadIDSchema, "minItems": 1, "maxItems": 8, "uniqueItems": true},
			"timeoutMs": map[string]any{"type": "integer", "minimum": 0, "maximum": 120000, "default": 30000},
		}, "threadIds")),
	}
	return []any{map[string]any{
		"type":        "namespace",
		"name":        mimiTasksNamespace,
		"description": "Manage user-visible, user-owned independent tasks on the current authorized Mimi host and project. Internal parallel work must use subagents.",
		"tools":       functions,
	}}
}

func mimiTaskFunction(name string, description string, schema map[string]any) map[string]any {
	return map[string]any{"type": "function", "name": name, "description": description, "inputSchema": schema}
}

func (p *appServerGatewayPolicy) setMimiTaskToolsEnabled(enabled bool) {
	p.mu.Lock()
	p.mimiTaskToolsEnabled = enabled
	p.mu.Unlock()
}

func (p *appServerGatewayPolicy) allowsMimiTaskTools() bool {
	p.mu.Lock()
	enabled := p.mimiTaskToolsEnabled
	p.mu.Unlock()
	return enabled
}

func (p *appServerGatewayPolicy) validateAndClaimMimiTaskCall(raw json.RawMessage) (string, error) {
	if normalizeAppServerRuntimeID(p.runtimeID) != "codex" || !p.allowsMimiTaskTools() {
		return "", fmt.Errorf("dynamic task tools were not enabled by this client")
	}
	params, err := decodeGatewayParams(raw)
	if err != nil || !gatewayObjectHasOnlyKeys(params, "threadId", "turnId", "callId", "namespace", "tool", "arguments") {
		return "", fmt.Errorf("item/tool/call params are invalid")
	}
	threadID, threadOK := gatewayStringParam(params, "threadId")
	turnID, turnOK := gatewayStringParam(params, "turnId")
	callID, callOK := gatewayStringParam(params, "callId")
	namespace, namespaceOK := gatewayStringParam(params, "namespace")
	tool, toolOK := gatewayStringParam(params, "tool")
	if !threadOK || !turnOK || !callOK || !namespaceOK || namespace != mimiTasksNamespace || !toolOK || !isMimiTaskTool(tool) {
		return "", fmt.Errorf("item/tool/call identity is invalid")
	}
	if utf8.RuneCountInString(threadID) > mimiTaskThreadIDMaxCharacters || utf8.RuneCountInString(turnID) > mimiTaskThreadIDMaxCharacters || utf8.RuneCountInString(callID) > mimiTaskThreadIDMaxCharacters {
		return "", fmt.Errorf("item/tool/call identity is too long")
	}
	if _, ok := p.allowedThread(threadID); !ok {
		return "", fmt.Errorf("item/tool/call thread is not authorized by this gateway connection")
	}
	parentThread, _ := p.allowedThread(threadID)
	arguments, ok := params["arguments"].(map[string]any)
	if !ok || p.validateMimiTaskArguments(tool, arguments, parentThread.scopeID) != nil {
		return "", fmt.Errorf("item/tool/call arguments are invalid")
	}
	key := threadID + "\x00" + turnID + "\x00" + callID
	if p.router == nil {
		return "", nil
	}
	switch p.router.claimMimiTaskDynamicCall(key, p, time.Now()) {
	case mimiTaskDynamicClaimAcquired:
		return key, nil
	case mimiTaskDynamicClaimWasAbandoned:
		return "", errMimiTaskDynamicCallAbandoned
	default:
		return "", nil
	}
}

func isMimiTaskTool(tool string) bool {
	for _, candidate := range mimiTaskToolNames {
		if tool == candidate {
			return true
		}
	}
	return false
}

func (p *appServerGatewayPolicy) validateMimiTaskArguments(tool string, arguments map[string]any, parentScopeID string) error {
	stringValue := func(key string, max int) bool {
		value, ok := arguments[key].(string)
		return ok && strings.TrimSpace(value) != "" && utf8.RuneCountInString(strings.TrimSpace(value)) <= max
	}
	targetThread := func(id string) bool {
		thread, ok := p.allowedThread(id)
		return ok && thread.scopeID == parentScopeID
	}
	switch tool {
	case "create_thread":
		if !gatewayObjectHasOnlyKeys(arguments, "prompt") || !stringValue("prompt", mimiTaskPromptMaxCharacters) {
			return fmt.Errorf("invalid prompt")
		}
	case "list_threads":
		if !gatewayObjectHasOnlyKeys(arguments, "limit") {
			return fmt.Errorf("invalid keys")
		}
		if value, exists := arguments["limit"]; exists {
			limit, ok := gatewayJSONNumberInt64(value)
			if !ok || limit < 1 || limit > 50 {
				return fmt.Errorf("invalid limit")
			}
		}
	case "read_thread":
		id, _ := arguments["threadId"].(string)
		if !gatewayObjectHasOnlyKeys(arguments, "threadId") || !stringValue("threadId", mimiTaskThreadIDMaxCharacters) || !targetThread(id) {
			return fmt.Errorf("invalid thread")
		}
	case "send_message_to_thread":
		id, _ := arguments["threadId"].(string)
		if !gatewayObjectHasOnlyKeys(arguments, "threadId", "prompt") || !stringValue("threadId", mimiTaskThreadIDMaxCharacters) || !targetThread(id) || !stringValue("prompt", mimiTaskPromptMaxCharacters) {
			return fmt.Errorf("invalid send")
		}
	case "wait_threads":
		if !gatewayObjectHasOnlyKeys(arguments, "threadIds", "timeoutMs") {
			return fmt.Errorf("invalid keys")
		}
		ids, ok := arguments["threadIds"].([]any)
		if !ok || len(ids) < 1 || len(ids) > 8 {
			return fmt.Errorf("invalid thread ids")
		}
		seen := map[string]struct{}{}
		for _, raw := range ids {
			id, ok := raw.(string)
			if !ok || strings.TrimSpace(id) == "" || utf8.RuneCountInString(strings.TrimSpace(id)) > mimiTaskThreadIDMaxCharacters || !targetThread(id) {
				return fmt.Errorf("invalid thread id")
			}
			if _, duplicate := seen[id]; duplicate {
				return fmt.Errorf("duplicate thread id")
			}
			seen[id] = struct{}{}
		}
		if value, exists := arguments["timeoutMs"]; exists {
			timeout, ok := gatewayJSONNumberInt64(value)
			if !ok || timeout < 0 || timeout > 120000 {
				return fmt.Errorf("invalid timeout")
			}
		}
	default:
		return fmt.Errorf("unknown tool")
	}
	return nil
}

type mimiTaskDynamicClaimResult uint8

const (
	mimiTaskDynamicClaimDropped mimiTaskDynamicClaimResult = iota
	mimiTaskDynamicClaimAcquired
	mimiTaskDynamicClaimWasAbandoned
)

func (r *Router) claimMimiTaskDynamicCall(key string, owner *appServerGatewayPolicy, now time.Time) mimiTaskDynamicClaimResult {
	r.mimiTaskClaimsMu.Lock()
	defer r.mimiTaskClaimsMu.Unlock()
	if r.mimiTaskClaims == nil {
		r.mimiTaskClaims = map[string]mimiTaskDynamicClaim{}
	}
	for candidate, claim := range r.mimiTaskClaims {
		if claim.createdAt.IsZero() || now.Sub(claim.createdAt) > mimiTaskDynamicClaimTTL {
			delete(r.mimiTaskClaims, candidate)
		}
	}
	if claim, exists := r.mimiTaskClaims[key]; exists {
		if claim.state == mimiTaskDynamicClaimAbandoned {
			return mimiTaskDynamicClaimWasAbandoned
		}
		return mimiTaskDynamicClaimDropped
	}
	if len(r.mimiTaskClaims) >= mimiTaskDynamicClaimMax {
		return mimiTaskDynamicClaimDropped
	}
	r.mimiTaskClaims[key] = mimiTaskDynamicClaim{owner: owner, createdAt: now, state: mimiTaskDynamicClaimActive}
	return mimiTaskDynamicClaimAcquired
}

func (r *Router) releaseMimiTaskDynamicClaim(key string, owner *appServerGatewayPolicy) {
	if key == "" {
		return
	}
	r.mimiTaskClaimsMu.Lock()
	if claim, ok := r.mimiTaskClaims[key]; ok && claim.owner == owner {
		delete(r.mimiTaskClaims, key)
	}
	r.mimiTaskClaimsMu.Unlock()
}

// completeMimiTaskDynamicClaim keeps a lightweight tombstone after a response.
// A late copy of the broadcast request must not execute a mutating tool twice.
func (r *Router) completeMimiTaskDynamicClaim(key string, owner *appServerGatewayPolicy) {
	if key == "" {
		return
	}
	r.mimiTaskClaimsMu.Lock()
	if claim, ok := r.mimiTaskClaims[key]; ok && claim.owner == owner {
		claim.owner = nil
		claim.createdAt = time.Now()
		claim.state = mimiTaskDynamicClaimCompleted
		r.mimiTaskClaims[key] = claim
	}
	r.mimiTaskClaimsMu.Unlock()
}

// abandonMimiTaskDynamicClaims converts in-flight claims into tombstones when a
// client disconnects. The side effect must not be replayed on another subscriber,
// but the closed connection and its authorization state must not stay retained.
func (r *Router) abandonMimiTaskDynamicClaims(owner *appServerGatewayPolicy) {
	if owner == nil {
		return
	}
	r.mimiTaskClaimsMu.Lock()
	now := time.Now()
	for key, claim := range r.mimiTaskClaims {
		if claim.owner == owner {
			claim.owner = nil
			claim.createdAt = now
			claim.state = mimiTaskDynamicClaimAbandoned
			r.mimiTaskClaims[key] = claim
		}
	}
	r.mimiTaskClaimsMu.Unlock()
}

func rewriteMimiTaskDynamicResponse(payload []byte) ([]byte, error) {
	var frame map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&frame); err != nil {
		return nil, fmt.Errorf("dynamic tool response is invalid")
	}
	result, ok := frame["result"].(map[string]any)
	if !ok || !gatewayObjectHasOnlyKeys(result, "contentItems", "success") {
		return nil, fmt.Errorf("dynamic tool response result is invalid")
	}
	success, ok := result["success"].(bool)
	items, itemsOK := result["contentItems"].([]any)
	if !ok || !itemsOK || len(items) != 1 {
		return nil, fmt.Errorf("dynamic tool response must contain one text item")
	}
	item, ok := items[0].(map[string]any)
	text, textOK := item["text"].(string)
	if !ok || !textOK || !gatewayObjectHasOnlyKeys(item, "type", "text") || item["type"] != "inputText" || len(text) > mimiTaskResultTextMaxBytes {
		return nil, fmt.Errorf("dynamic tool response text is invalid")
	}
	frame["result"] = map[string]any{"contentItems": []any{map[string]any{"type": "inputText", "text": text}}, "success": success}
	delete(frame, "error")
	return json.Marshal(frame)
}

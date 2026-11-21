package httpapi

import (
	"encoding/json"
	"fmt"
	"log"
	"path/filepath"
	"sort"
	"strings"
)

func sanitizedGatewayInitialTurnsPage(page map[string]any) map[string]any {
	// 空对象也必须补齐受控默认值，不能依赖上游可能变化的默认页大小。
	safe := map[string]any{
		"limit":         int64(appServerGatewayInitialTurnsMaxLimit),
		"sortDirection": "desc",
		"itemsView":     "full",
	}
	if limit := gatewayOptionalInt64Param(page, "limit"); limit > 0 && limit <= appServerGatewayInitialTurnsMaxLimit {
		safe["limit"] = limit
	}
	if direction := gatewayOptionalStringParam(page, "sortDirection"); direction == "desc" {
		safe["sortDirection"] = direction
	}
	if itemsView := gatewayOptionalStringParam(page, "itemsView"); itemsView == "summary" || itemsView == "full" {
		safe["itemsView"] = itemsView
	}
	return safe
}

func sanitizedGatewayThreadSandbox(runtimeID string, params map[string]any) string {
	normalizedRuntime := normalizeAppServerRuntimeID(runtimeID)
	if appServerRuntimeUsesAdapterSandbox(normalizedRuntime) {
		// 常驻适配器支持完全访问时原样下发；是否真的可用由 channel 的 SandboxModes
		// 与适配器探测声明表达，压缩层不做版本判断。
		if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "dangerfullaccess" {
			return "danger-full-access"
		}
		if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "readonly" {
			return "read-only"
		}
		return "workspace-write"
	}
	if normalizedRuntime == "deepseek" {
		// Harness 的沙盒由 Harness 自己管理，agentd 不转发也不可能施加沙盒参数
		// （validateDeepSeekPermissionParams 只放行完全访问）。这里如实回完全访问。
		return "danger-full-access"
	}
	if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "readonly" {
		return "read-only"
	}
	if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "workspacewrite" {
		return "workspace-write"
	}
	if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "dangerfullaccess" {
		return "danger-full-access"
	}
	return "danger-full-access"
}

func sanitizedGatewayTurnParams(runtimeID string, params map[string]any, cwd string) map[string]any {
	safe := copyGatewayParams(params, "threadId", "cwd", "input", "clientUserMessageId", "model", "serviceTier", "effort", "summary", "personality")
	if collaborationMode, ok := sanitizedGatewayCollaborationMode(params["collaborationMode"]); ok {
		safe["collaborationMode"] = collaborationMode
	}
	workspaceWrite := false
	fullAccess := false
	preserveSettings := gatewayPreservesThreadPermissionSettings(params)
	if !preserveSettings {
		if runtimeID == "codex" {
			if profileID, ok := gatewayPermissionProfileID(params["permissions"]); ok {
				safe["permissions"] = profileID
				fullAccess = strings.EqualFold(strings.TrimSpace(profileID), ":danger-full-access")
			} else {
				safe["sandboxPolicy"] = sanitizedGatewaySandboxPolicy(runtimeID, params["sandboxPolicy"], cwd)
				sandboxPolicy := safe["sandboxPolicy"].(map[string]any)
				workspaceWrite = normalizePolicyValue(sandboxPolicy["type"].(string)) == "workspacewrite"
				requestedSandbox, _ := params["sandboxPolicy"].(map[string]any)
				requestedType, requestedTypeOK := gatewayStringParam(requestedSandbox, "type")
				fullAccess = requestedTypeOK && normalizePolicyValue(requestedType) == "dangerfullaccess"
			}
		} else {
			safe["sandboxPolicy"] = sanitizedGatewaySandboxPolicy(runtimeID, params["sandboxPolicy"], cwd)
			sandboxPolicy := safe["sandboxPolicy"].(map[string]any)
			workspaceWrite = normalizePolicyValue(sandboxPolicy["type"].(string)) == "workspacewrite"
			fullAccess = normalizePolicyValue(sandboxPolicy["type"].(string)) == "dangerfullaccess"
		}
		safe["approvalPolicy"], safe["approvalsReviewer"] = sanitizedGatewayApproval(params, workspaceWrite, fullAccess)
	}
	// 默认模型必须交给 app-server 按账号 rollout 决定；gateway 只透传用户显式选择的 model。
	if effort, ok := gatewayStringParam(safe, "effort"); !ok || strings.TrimSpace(effort) == "" {
		safe["effort"] = defaultCodexReasoningEffort
	}
	return safe
}

func gatewayPreservesThreadPermissionSettings(params map[string]any) bool {
	preserve, _ := params[gatewayPreserveThreadPermissionsParam].(bool)
	return preserve
}

func sanitizedGatewayTurnSteerParams(params map[string]any) map[string]any {
	return copyGatewayParams(params, "threadId", "input", "clientUserMessageId", "expectedTurnId")
}

func sanitizedGatewayThreadSettingsParams(runtimeID string, params map[string]any, cwd string) map[string]any {
	safe := copyGatewayParams(params, "threadId", "cwd", "model", "serviceTier", "effort", "summary", "personality")
	if collaborationMode, ok := sanitizedGatewayCollaborationMode(params["collaborationMode"]); ok {
		safe["collaborationMode"] = collaborationMode
	}
	workspaceWrite := false
	fullAccess := false
	if profileID, ok := gatewayPermissionProfileID(params["permissions"]); ok {
		safe["permissions"] = profileID
		fullAccess = strings.EqualFold(profileID, ":danger-full-access")
	} else if value, exists := params["sandboxPolicy"]; exists && value != nil {
		safe["sandboxPolicy"] = sanitizedGatewaySandboxPolicy(runtimeID, value, cwd)
		policy := safe["sandboxPolicy"].(map[string]any)
		workspaceWrite = normalizePolicyValue(policy["type"].(string)) == "workspacewrite"
		fullAccess = normalizePolicyValue(policy["type"].(string)) == "dangerfullaccess"
	}
	if _, exists := params["approvalPolicy"]; exists {
		safe["approvalPolicy"], safe["approvalsReviewer"] = sanitizedGatewayApproval(params, workspaceWrite, fullAccess)
	}
	return safe
}

func logGatewayForwardedClientTurnSummary(method string, payload []byte) {
	if method == "thread/takeover" {
		logGatewayForwardedTakeoverSummary(payload)
		return
	}
	if method != "turn/start" && method != "turn/steer" {
		return
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		log.Printf("app-server gateway forwarded client turn method=%s summary_error=json", method)
		return
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		log.Printf("app-server gateway forwarded client turn method=%s summary_error=params", method)
		return
	}
	threadID, _ := gatewayStringParam(params, "threadId")
	expectedTurnID, _ := gatewayStringParam(params, "expectedTurnId")
	clientUserMessageID, _ := gatewayStringParam(params, "clientUserMessageId")
	// 这里只记录协议元信息，刻意不记录 input.text、图片 URL 或本地文件路径。
	log.Printf(
		"app-server gateway forwarded client turn method=%s threadId=%s cwdBase=%s input=%s collaborationMode=%s expectedTurnId=%s clientUserMessageId=%s",
		method,
		gatewayCompactLogToken(threadID),
		gatewayCWDBaseLabel(params),
		gatewayInputTypeSummary(params),
		gatewayCollaborationModeSummary(params),
		gatewayCompactLogToken(expectedTurnID),
		gatewayCompactLogToken(clientUserMessageID),
	)
}

func logGatewayForwardedTakeoverSummary(payload []byte) {
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		log.Printf("app-server gateway forwarded takeover method=thread/takeover summary_error=json")
		return
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		log.Printf("app-server gateway forwarded takeover method=thread/takeover summary_error=params")
		return
	}
	threadID, _ := gatewayStringParam(params, "threadId")
	log.Printf(
		"app-server gateway forwarded takeover method=thread/takeover threadId=%s cwdBase=%s",
		gatewayCompactLogToken(threadID),
		gatewayCWDBaseLabel(params),
	)
}

func gatewayInputTypeSummary(params map[string]any) string {
	raw, ok := params["input"]
	if !ok {
		return "absent"
	}
	items, ok := raw.([]any)
	if !ok {
		return "invalid"
	}
	counts := map[string]int{}
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			counts["invalid"]++
			continue
		}
		inputType, _ := gatewayStringParam(obj, "type")
		if inputType == "" {
			inputType = "unknown"
		}
		counts[inputType]++
	}
	keys := make([]string, 0, len(counts))
	for key := range counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := []string{fmt.Sprintf("count=%d", len(items))}
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", gatewayCompactLogToken(key), counts[key]))
	}
	return strings.Join(parts, ",")
}

func gatewayCollaborationModeSummary(params map[string]any) string {
	raw, ok := params["collaborationMode"]
	if !ok {
		return "absent"
	}
	mode, ok := raw.(map[string]any)
	if !ok {
		return "invalid"
	}
	modeValue, ok := gatewayStringParam(mode, "mode")
	if !ok {
		modeValue = "missing"
	}
	settings, _ := mode["settings"].(map[string]any)
	model, ok := gatewayStringParam(settings, "model")
	if !ok {
		model = "absent"
	}
	effort := "absent"
	if value, exists := settings["reasoning_effort"]; exists {
		switch typed := value.(type) {
		case nil:
			effort = "null"
		case string:
			effort = strings.TrimSpace(typed)
			if effort == "" {
				effort = "missing"
			}
		default:
			effort = "invalid"
		}
	}
	return fmt.Sprintf(
		"mode=%s,model=%s,effort=%s",
		gatewayCompactLogToken(modeValue),
		gatewayCompactLogToken(model),
		gatewayCompactLogToken(effort),
	)
}

func gatewayCWDBaseLabel(params map[string]any) string {
	cwd, ok := gatewayStringParam(params, "cwd")
	if !ok {
		return "absent"
	}
	base := filepath.Base(filepath.Clean(cwd))
	if base == "" {
		return "unknown"
	}
	return gatewayCompactLogToken(base)
}

func gatewayCompactLogToken(value string) string {
	value = strings.Join(strings.Fields(strings.TrimSpace(value)), "_")
	if value == "" {
		return "absent"
	}
	if len(value) <= 16 {
		return value
	}
	return value[:8] + "..." + value[len(value)-4:]
}

func sanitizedGatewayCollaborationMode(raw any) (map[string]any, bool) {
	mode, ok := raw.(map[string]any)
	if !ok {
		return nil, false
	}
	modeValue, ok := gatewayStringParam(mode, "mode")
	if !ok {
		return nil, false
	}
	settings, _ := mode["settings"].(map[string]any)
	safeSettings := map[string]any{
		"reasoning_effort":       nil,
		"developer_instructions": nil,
	}
	if modeValue == "default" {
		safeSettings["developer_instructions"] = gatewayDefaultCollaborationInstructions
	}
	if model, ok := gatewayStringParam(settings, "model"); ok {
		safeSettings["model"] = model
	}
	if effort, ok := settings["reasoning_effort"]; ok {
		safeSettings["reasoning_effort"] = effort
	}
	return map[string]any{
		"mode":     modeValue,
		"settings": safeSettings,
	}, true
}

func sanitizedGatewayApproval(params map[string]any, workspaceWrite bool, fullAccess bool) (string, string) {
	policy, _ := gatewayStringParam(params, "approvalPolicy")
	reviewer, _ := gatewayStringParam(params, "approvalsReviewer")
	if fullAccess {
		return "never", "user"
	}
	if workspaceWrite && normalizePolicyValue(policy) == "onrequest" && reviewer == "auto_review" {
		return "on-request", reviewer
	}
	return "on-request", "user"
}

func sanitizedGatewaySandboxPolicy(runtimeID string, raw any, cwd string) map[string]any {
	sandbox, _ := raw.(map[string]any)
	sandboxType, _ := gatewayStringParam(sandbox, "type")
	normalizedType := normalizePolicyValue(sandboxType)
	if appServerRuntimeUsesAdapterSandbox(runtimeID) {
		if normalizedType == "dangerfullaccess" {
			return map[string]any{"type": "dangerFullAccess"}
		}
		if normalizedType == "readonly" {
			return map[string]any{
				"type":          "readOnly",
				"networkAccess": false,
			}
		}
		return map[string]any{
			"type":          "workspaceWrite",
			"writableRoots": []any{cwd},
			"networkAccess": false,
		}
	}
	if normalizedType == "readonly" {
		return map[string]any{
			"type":          "readOnly",
			"networkAccess": false,
		}
	}
	if normalizedType == "dangerfullaccess" {
		return map[string]any{
			"type":          "dangerFullAccess",
			"networkAccess": false,
		}
	}
	if normalizedType == "workspacewrite" {
		return map[string]any{
			"type":          "workspaceWrite",
			"writableRoots": []any{cwd},
			"networkAccess": false,
		}
	}
	return map[string]any{
		"type":          "dangerFullAccess",
		"networkAccess": false,
	}
}

func copyGatewayParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		copyGatewayParam(copied, params, key)
	}
	return copied
}

func copyGatewayParam(dst map[string]any, src map[string]any, key string) {
	if value, ok := src[key]; ok {
		dst[key] = value
	}
}

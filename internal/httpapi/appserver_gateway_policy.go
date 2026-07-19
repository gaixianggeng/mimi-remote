package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	"github.com/gorilla/websocket"
)

func (p *appServerGatewayPolicy) validateClientFrame(messageType int, payload []byte) ([]byte, *appServerGatewayPolicyError) {
	if p.isClosed() {
		return nil, &appServerGatewayPolicyError{message: "app-server gateway 连接已关闭"}
	}
	if messageType != websocket.TextMessage {
		return nil, &appServerGatewayPolicyError{message: "app-server gateway 只允许 JSON text frame"}
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return nil, &appServerGatewayPolicyError{message: "JSON-RPC frame 无效"}
	}
	method := strings.TrimSpace(frame.Method)
	if method == "" {
		if frame.ID != nil && (len(frame.Result) > 0 || len(frame.Error) > 0) {
			rewritten, err := p.validateClientResponse(payload, &frame)
			if err != nil {
				return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
			}
			return rewritten, nil
		}
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "JSON-RPC frame 缺少 method"}
	}
	if method != "initialized" && frame.ID == nil {
		return nil, &appServerGatewayPolicyError{message: "app-server request 必须包含 id"}
	}
	if !p.methodAllowed(method) {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "app-server method 不允许：" + method}
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	validated, err := p.router.validateGatewayPolicyParams(normalizeAppServerRuntimeID(p.runtimeID), method, params)
	if err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if err := p.validateThreadCapability(&frame, method, params, validated); err != nil {
		p.router.releaseManagedWorktreePendingUse(validated.pendingManagedWorktreePath)
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if policyErr := p.reserveHistoryRequest(frame.ID, method, params, len(payload)); policyErr != nil {
		p.forgetPending(frame.ID)
		return nil, policyErr
	}
	rewritten, err := rewriteGatewaySafeDefaults(payload, normalizeAppServerRuntimeID(p.runtimeID), method, params, validated)
	if err != nil {
		p.cancelPendingHistoryRequest(frame.ID)
		p.forgetPending(frame.ID)
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if frame.ID != nil && normalizeAppServerRuntimeID(p.runtimeID) == "claude" && method == "model/list" {
		if err := p.rememberPendingClientRequest(frame.ID, method); err != nil {
			return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
		}
	}
	if p.isClosed() {
		p.cancelPendingHistoryRequest(frame.ID)
		p.forgetPending(frame.ID)
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "app-server gateway 连接已关闭"}
	}
	logGatewayForwardedClientTurnSummary(method, rewritten)
	return rewritten, nil
}

func (p *appServerGatewayPolicy) methodAllowed(method string) bool {
	_, ok := appServerAllowedMethodsForRuntime(p.runtimeID)[method]
	return ok
}

func (p *appServerGatewayPolicy) validateThreadCapability(frame *appServerGatewayFrame, method string, params map[string]any, validated appServerGatewayValidatedParams) error {
	cwd := validated.cwd
	scope := validated.cwdScope
	scopeOK := validated.cwdScopeOK

	switch method {
	case "thread/list", "thread/start":
		if method == "thread/list" {
			if err := validateGatewayThreadListParams(params); err != nil {
				return err
			}
		}
		if err := p.rememberPendingThreadResponseWithManagedUse(frame.ID, method, cwd, scope.id, validated.pendingManagedWorktreePath); err != nil {
			return err
		}
	case "thread/search":
		if err := validateGatewayThreadSearchParams(params); err != nil {
			return err
		}
		limit := int64(0)
		limitSet := false
		if value, ok := params["limit"]; ok && value != nil {
			limit, _ = gatewayJSONNumberInt64(value)
			limitSet = true
		}
		if err := p.rememberPendingThreadSearchResponse(frame.ID, limit, limitSet); err != nil {
			return err
		}
	case "thread/resume":
		if err := validateGatewayThreadResumeParams(params); err != nil {
			return err
		}
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if !scopeOK || scope.id != thread.scopeID {
			return fmt.Errorf("%s.cwd 必须匹配已授权 thread 的工作区", method)
		}
		if err := p.rememberPendingThreadResponseWithManagedUse(frame.ID, method, cwd, scope.id, validated.pendingManagedWorktreePath); err != nil {
			return err
		}
	case "thread/fork":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if !scopeOK {
			return fmt.Errorf("%s.cwd 必须来自已授权工作区", method)
		}
		if err := p.rememberPendingThreadResponseWithManagedUse(frame.ID, method, cwd, scope.id, validated.pendingManagedWorktreePath); err != nil {
			return err
		}
	case "thread/read", "thread/turns/list", "thread/name/set", "thread/compact/start", "thread/unsubscribe",
		"thread/goal/get", "thread/goal/set", "thread/goal/clear", "review/start":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if method == "thread/read" {
			if err := p.rememberPendingThreadResponse(frame.ID, method, "", ""); err != nil {
				return err
			}
		}
		if method == "thread/turns/list" {
			if err := validateGatewayThreadTurnsListParams(params); err != nil {
				return err
			}
		}
		if method == "thread/goal/set" {
			if err := validateGatewayGoalSetParams(params); err != nil {
				return err
			}
		}
		if method == "thread/name/set" {
			if err := validateGatewayThreadSetNameParams(params); err != nil {
				return err
			}
		}
		if method == "review/start" {
			if err := validateGatewayReviewStartParams(params); err != nil {
				return err
			}
		}
	case "thread/archive", "thread/unarchive":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
	case "turn/start":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		// 项目作用域：同项目内目录都可用；browse 作用域：scope id 是 canonical cwd 的
		// hash，等价于精确目录绑定，不允许切到允许根下的 sibling 目录。
		if !scopeOK || scope.id != thread.scopeID {
			return fmt.Errorf("%s.cwd 必须匹配已授权 thread 的工作区", method)
		}
	case "turn/steer":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if _, ok := gatewayStringParam(params, "expectedTurnId"); !ok {
			return fmt.Errorf("%s.expectedTurnId 不能为空", method)
		}
		if err := p.validateThreadInputPaths(method, params, thread); err != nil {
			return err
		}
	case "turn/interrupt":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
	}
	return nil
}

func (p *appServerGatewayPolicy) validateThreadInputPaths(method string, params map[string]any, thread appServerGatewayAllowedThread) error {
	inputPaths, err := collectUserInputPaths(method, params)
	if err != nil {
		return err
	}
	if len(inputPaths) == 0 {
		return nil
	}
	var scope gatewayScope
	var scopeOK bool
	if strings.TrimSpace(thread.cwd) != "" {
		scope, scopeOK = p.router.gatewayScopeForPath(thread.cwd)
	}
	for _, path := range inputPaths {
		if _, ok := p.router.projectForGatewayPath(path); ok {
			continue
		}
		// turn/steer 不携带 cwd，只能根据已授权 thread 的 cwd 还原 browse/worktree 精确边界。
		if scopeOK && scope.id == thread.scopeID && (scope.browse || scope.managed) && gatewayScopeContainsPath(scope, path) {
			continue
		}
		return fmt.Errorf("%s.input path 必须来自 projects allowlist", method)
	}
	return nil
}

func (p *appServerGatewayPolicy) validateClientResponse(payload []byte, frame *appServerGatewayFrame) ([]byte, error) {
	if frame.ID == nil {
		return nil, fmt.Errorf("JSON-RPC response 缺少 id")
	}
	request, ok := p.consumePendingServerRequest(frame.ID)
	if !ok {
		return nil, fmt.Errorf("JSON-RPC response id 未由 app-server 发起")
	}
	if len(frame.Error) > 0 {
		return payload, nil
	}
	if len(frame.Result) == 0 {
		return nil, fmt.Errorf("JSON-RPC response 缺少 result")
	}
	if !isPermissionsApprovalMethod(request.method) {
		return payload, nil
	}
	return rewriteGatewayPermissionsApprovalResponse(payload)
}

func rewriteGatewayPermissionsApprovalResponse(payload []byte) ([]byte, error) {
	var frame map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&frame); err != nil {
		return nil, fmt.Errorf("JSON-RPC response 无效")
	}
	frame["result"] = map[string]any{
		"permissions":      map[string]any{},
		"scope":            "turn",
		"strictAutoReview": true,
	}
	delete(frame, "error")
	rewritten, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("重写 permissions approval response 失败：%w", err)
	}
	return rewritten, nil
}

func isPermissionsApprovalMethod(method string) bool {
	return strings.Contains(strings.ToLower(strings.TrimSpace(method)), "permissions/requestapproval")
}

func rewriteGatewaySafeDefaults(payload []byte, runtimeID string, method string, params map[string]any, validated appServerGatewayValidatedParams) ([]byte, error) {
	var sanitized map[string]any
	switch method {
	case "initialize":
		sanitized = sanitizedGatewayInitializeParams(params)
	case "initialized", "model/list", "account/rateLimits/read":
		sanitized = map[string]any{}
	case "skills/list":
		sanitized = sanitizedGatewaySkillsListParams(params, validated.cwd)
	case "plugin/installed":
		sanitized = sanitizedGatewayPluginInstalledParams(validated.cwd)
	case "thread/list":
		sanitized = sanitizedGatewayThreadListParams(params)
	case "thread/search":
		sanitized = sanitizedGatewayThreadSearchParams(params)
	case "thread/read":
		sanitized = copyGatewayParams(params, "threadId", "includeTurns")
	case "thread/turns/list":
		sanitized = sanitizedGatewayThreadTurnsListParams(params)
	case "thread/goal/get", "thread/goal/clear":
		sanitized = copyGatewayParams(params, "threadId")
	case "thread/goal/set":
		sanitized = sanitizedGatewayGoalSetParams(params)
	case "thread/name/set":
		sanitized = copyGatewayParams(params, "threadId", "name")
	case "thread/compact/start", "thread/unsubscribe":
		sanitized = copyGatewayParams(params, "threadId")
	case "thread/archive", "thread/unarchive":
		sanitized = copyGatewayParams(params, "threadId")
	case "review/start":
		sanitized = sanitizedGatewayReviewStartParams(params)
	case "thread/start", "thread/resume", "thread/fork":
		sanitized = sanitizedGatewayThreadParams(runtimeID, method, params)
	case "turn/start":
		sanitized = sanitizedGatewayTurnParams(runtimeID, params, validated.cwd)
	case "turn/steer":
		sanitized = sanitizedGatewayTurnSteerParams(params)
	case "turn/interrupt":
		sanitized = copyGatewayParams(params, "threadId", "turnId")
	default:
		return payload, nil
	}
	if reflect.DeepEqual(params, sanitized) {
		return payload, nil
	}
	var frame map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&frame); err != nil {
		return nil, fmt.Errorf("JSON-RPC frame 无效")
	}
	frame["params"] = sanitized
	rewritten, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("重写 app-server 安全参数失败：%w", err)
	}
	return rewritten, nil
}

func sanitizedGatewaySkillsListParams(params map[string]any, cwd string) map[string]any {
	// 移动端只能扫描一个已经授权的工作区，不能借 skills/list 枚举任意目录。
	safe := map[string]any{"cwds": []any{cwd}}
	if forceReload, ok := gatewayBoolParam(params, "forceReload"); ok {
		safe["forceReload"] = forceReload
	}
	return safe
}

func sanitizedGatewayPluginInstalledParams(cwd string) map[string]any {
	// @ 候选只需要当前授权工作区内已安装的插件；不开放安装建议，避免把只读入口变成安装入口。
	return map[string]any{"cwds": []any{cwd}}
}

func sanitizedGatewayGoalSetParams(params map[string]any) map[string]any {
	// 目标本身由 Codex app-server 管理；gateway 只保留协议字段，避免把移动端额外配置透传到运行时。
	safe := copyGatewayParams(params, "threadId", "objective", "status", "tokenBudget")
	if _, ok := params["tokenBudget"]; !ok {
		if value, ok := params["token_budget"]; ok {
			safe["tokenBudget"] = value
		}
	}
	return safe
}

func validateGatewayThreadSetNameParams(params map[string]any) error {
	name, ok := gatewayStringParam(params, "name")
	if !ok {
		return fmt.Errorf("thread/name/set.name 必须是非空字符串")
	}
	// 名称只是列表展示字段，限制到足够日常使用的长度，避免移动端误把正文当作标题上传。
	if len(name) > 256 {
		return fmt.Errorf("thread/name/set.name 不能超过 256 bytes")
	}
	return nil
}

func validateGatewayReviewStartParams(params map[string]any) error {
	if delivery, exists := params["delivery"]; exists && delivery != nil {
		value, ok := delivery.(string)
		if !ok || strings.TrimSpace(value) != "inline" {
			// detached 会创建一个新 thread；第一批先只开放原 thread 内 review，避免绕过 thread 授权登记。
			return fmt.Errorf("review/start.delivery 只允许 inline")
		}
	}
	target, ok := params["target"].(map[string]any)
	if !ok {
		return fmt.Errorf("review/start.target 必须是对象")
	}
	targetType, ok := gatewayStringParam(target, "type")
	if !ok {
		return fmt.Errorf("review/start.target.type 不能为空")
	}
	requireNonEmptyString := func(key string) error {
		if _, ok := gatewayStringParam(target, key); !ok {
			return fmt.Errorf("review/start.target.%s 不能为空", key)
		}
		return nil
	}
	switch targetType {
	case "uncommittedChanges":
		return nil
	case "baseBranch":
		return requireNonEmptyString("branch")
	case "commit":
		if err := requireNonEmptyString("sha"); err != nil {
			return err
		}
		if title, exists := target["title"]; exists && title != nil {
			if _, ok := title.(string); !ok {
				return fmt.Errorf("review/start.target.title 必须是字符串或 null")
			}
		}
		return nil
	case "custom":
		// custom 等价于一段自由提示词，会绕过 turn/start 对沙盒和审批参数的统一改写。
		return fmt.Errorf("review/start.target.type 不允许远程使用：custom")
	default:
		return fmt.Errorf("review/start.target.type 不支持：%s", targetType)
	}
}

func sanitizedGatewayReviewStartParams(params map[string]any) map[string]any {
	target, _ := params["target"].(map[string]any)
	targetType, _ := gatewayStringParam(target, "type")
	safeTarget := map[string]any{"type": targetType}
	switch targetType {
	case "baseBranch":
		copyGatewayParam(safeTarget, target, "branch")
	case "commit":
		copyGatewayParam(safeTarget, target, "sha")
		copyGatewayParam(safeTarget, target, "title")
	}
	return map[string]any{
		"threadId": params["threadId"],
		"target":   safeTarget,
		// 强制 inline，确保响应不会产生一个尚未进入 gateway 授权缓存的新 thread。
		"delivery": "inline",
	}
}

func sanitizedGatewayThreadTurnsListParams(params map[string]any) map[string]any {
	safe := copyGatewayParams(params, "threadId", "cursor", "sortDirection", "itemsView")
	limit := int64(appServerGatewayThreadTurnsDefaultLimit)
	if value, ok := params["limit"]; ok && value != nil {
		if parsed, parsedOK := gatewayJSONNumberInt64(value); parsedOK {
			limit = parsed
		}
	}
	if limit > appServerGatewayThreadTurnsMaxLimit {
		limit = appServerGatewayThreadTurnsMaxLimit
	}
	if itemsView, ok := gatewayStringParam(params, "itemsView"); ok && itemsView == "full" && limit > appServerGatewayThreadTurnsFullMaxLimit {
		// full turn item 可能包含大量消息内容；移动端默认只拿小页，避免一次把完整历史打到 iPad。
		limit = appServerGatewayThreadTurnsFullMaxLimit
	}
	safe["limit"] = limit
	return safe
}

func sanitizedGatewayThreadListParams(params map[string]any) map[string]any {
	return copyGatewayParams(params, "cwd", "limit", "cursor", "sortKey", "sortDirection", "archived", "useStateDbOnly")
}

func sanitizedGatewayThreadSearchParams(params map[string]any) map[string]any {
	// searchTerm 是唯一必填字段，统一 trim；其余只重建 0.144.2 schema 中的字段，
	// 未知字段一律丢弃，避免未来/恶意 JSON 绕过 gateway 的显式策略边界。
	safe := copyGatewayParams(params, "cursor", "limit", "sortDirection", "sortKey", "archived", "sourceKinds")
	if searchTerm, ok := params["searchTerm"].(string); ok {
		safe["searchTerm"] = strings.TrimSpace(searchTerm)
	}
	return safe
}

func validateGatewayThreadSearchParams(params map[string]any) error {
	rawSearchTerm, ok := params["searchTerm"]
	if !ok {
		return fmt.Errorf("thread/search.searchTerm 不能为空")
	}
	searchTerm, ok := rawSearchTerm.(string)
	if !ok || strings.TrimSpace(searchTerm) == "" {
		return fmt.Errorf("thread/search.searchTerm 必须是非空字符串")
	}
	if len(strings.TrimSpace(searchTerm)) > appServerGatewayThreadSearchTermMaxBytes {
		return fmt.Errorf("thread/search.searchTerm 不能超过 %d bytes", appServerGatewayThreadSearchTermMaxBytes)
	}
	if value, ok := params["limit"]; ok {
		if value != nil {
			limit, parsed := gatewayJSONNumberInt64(value)
			if !parsed || limit < 0 {
				return fmt.Errorf("thread/search.limit 必须是非负整数")
			}
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayThreadSearchMaxLimit) {
			return fmt.Errorf("thread/search.limit 不能超过 %d", appServerGatewayThreadSearchMaxLimit)
		}
	}
	if value, ok := params["cursor"]; ok && value != nil {
		if _, ok := value.(string); !ok {
			return fmt.Errorf("thread/search.cursor 必须是字符串")
		}
	}
	if value, ok := params["sortDirection"]; ok && value != nil {
		sortDirection, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/search.sortDirection 必须是字符串")
		}
		switch sortDirection {
		case "asc", "desc":
		default:
			return fmt.Errorf("thread/search.sortDirection 不支持：%s", sortDirection)
		}
	}
	if value, ok := params["sortKey"]; ok && value != nil {
		sortKey, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/search.sortKey 必须是字符串")
		}
		switch sortKey {
		case "created_at", "updated_at", "recency_at":
		default:
			return fmt.Errorf("thread/search.sortKey 不支持：%s", sortKey)
		}
	}
	if value, ok := params["archived"]; ok && value != nil {
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("thread/search.archived 必须是布尔值")
		}
	}
	if value, ok := params["sourceKinds"]; ok && value != nil {
		sourceKinds, ok := value.([]any)
		if !ok {
			return fmt.Errorf("thread/search.sourceKinds 必须是字符串数组")
		}
		allowed := map[string]struct{}{
			"cli": {}, "vscode": {}, "exec": {}, "appServer": {}, "subAgent": {},
			"subAgentReview": {}, "subAgentCompact": {}, "subAgentThreadSpawn": {}, "subAgentOther": {}, "unknown": {},
		}
		for _, value := range sourceKinds {
			sourceKind, ok := value.(string)
			if !ok {
				return fmt.Errorf("thread/search.sourceKinds 必须是字符串数组")
			}
			if _, ok := allowed[sourceKind]; !ok {
				return fmt.Errorf("thread/search.sourceKinds 不支持：%s", sourceKind)
			}
		}
	}
	return nil
}

func validateGatewayGoalSetParams(params map[string]any) error {
	if value, ok := params["objective"]; ok {
		if value != nil {
			text, ok := value.(string)
			if !ok || strings.TrimSpace(text) == "" {
				return fmt.Errorf("thread/goal/set.objective 必须是非空字符串")
			}
		}
	}
	if value, ok := params["status"]; ok {
		if value != nil {
			status, ok := value.(string)
			if !ok {
				return fmt.Errorf("thread/goal/set.status 必须是字符串")
			}
			switch status {
			case "active", "paused", "blocked", "usageLimited", "budgetLimited", "complete":
			default:
				return fmt.Errorf("thread/goal/set.status 不支持：%s", status)
			}
		}
	}
	if value, ok := params["tokenBudget"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/goal/set.tokenBudget 必须是正数")
		}
	}
	if value, ok := params["token_budget"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/goal/set.token_budget 必须是正数")
		}
	}
	return nil
}

func validateGatewayThreadListParams(params map[string]any) error {
	if value, ok := params["limit"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/list.limit 必须是正整数")
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayThreadListMaxLimit) {
			return fmt.Errorf("thread/list.limit 不能超过 %d", appServerGatewayThreadListMaxLimit)
		}
	}
	if value, ok := params["cursor"]; ok && value != nil {
		if text, ok := value.(string); !ok || strings.TrimSpace(text) == "" {
			return fmt.Errorf("thread/list.cursor 必须是非空字符串")
		}
	}
	if value, ok := params["sortKey"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/list.sortKey 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "updated_at":
		default:
			return fmt.Errorf("thread/list.sortKey 不支持：%s", text)
		}
	}
	if value, ok := params["sortDirection"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/list.sortDirection 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "desc":
		default:
			return fmt.Errorf("thread/list.sortDirection 不支持：%s", text)
		}
	}
	if value, ok := params["archived"]; ok && value != nil {
		archived, ok := value.(bool)
		if !ok {
			return fmt.Errorf("thread/list.archived 必须是布尔值")
		}
		if archived {
			return fmt.Errorf("thread/list.archived 只允许 false")
		}
	}
	if value, ok := params["useStateDbOnly"]; ok && value != nil {
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("thread/list.useStateDbOnly 必须是布尔值")
		}
	}
	return nil
}

func validateGatewayThreadResumeParams(params map[string]any) error {
	value, ok := params["initialTurnsPage"]
	if !ok || value == nil {
		return nil
	}
	page, ok := value.(map[string]any)
	if !ok {
		return fmt.Errorf("thread/resume.initialTurnsPage 必须是对象")
	}
	if value, ok := page["limit"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/resume.initialTurnsPage.limit 必须是正整数")
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayInitialTurnsMaxLimit) {
			return fmt.Errorf("thread/resume.initialTurnsPage.limit 不能超过 %d", appServerGatewayInitialTurnsMaxLimit)
		}
	}
	if value, ok := page["sortDirection"]; ok && value != nil {
		text, ok := value.(string)
		if !ok || strings.TrimSpace(text) != "desc" {
			return fmt.Errorf("thread/resume.initialTurnsPage.sortDirection 只支持 desc")
		}
	}
	if value, ok := page["itemsView"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/resume.initialTurnsPage.itemsView 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "summary", "full":
		default:
			return fmt.Errorf("thread/resume.initialTurnsPage.itemsView 只支持 summary/full")
		}
	}
	return nil
}

func validateGatewayThreadTurnsListParams(params map[string]any) error {
	if value, ok := params["limit"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/turns/list.limit 必须是正整数")
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayThreadTurnsMaxLimit) {
			return fmt.Errorf("thread/turns/list.limit 不能超过 %d", appServerGatewayThreadTurnsMaxLimit)
		}
	}
	if value, ok := params["cursor"]; ok && value != nil {
		if text, ok := value.(string); !ok || strings.TrimSpace(text) == "" {
			return fmt.Errorf("thread/turns/list.cursor 必须是非空字符串")
		}
	}
	if value, ok := params["sortDirection"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/turns/list.sortDirection 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "asc", "desc":
		default:
			return fmt.Errorf("thread/turns/list.sortDirection 不支持：%s", text)
		}
	}
	if value, ok := params["itemsView"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/turns/list.itemsView 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "notLoaded", "summary", "full":
		default:
			return fmt.Errorf("thread/turns/list.itemsView 不支持：%s", text)
		}
	}
	return nil
}

func gatewayPositiveJSONNumber(value any) bool {
	switch typed := value.(type) {
	case json.Number:
		number, err := typed.Int64()
		return err == nil && number > 0
	case float64:
		return typed > 0 && typed == float64(int64(typed))
	case int:
		return typed > 0
	case int64:
		return typed > 0
	default:
		return false
	}
}

func gatewayJSONNumberGreaterThan(value any, max int64) bool {
	switch typed := value.(type) {
	case json.Number:
		number, err := typed.Int64()
		return err == nil && number > max
	case float64:
		return typed > float64(max)
	case int:
		return int64(typed) > max
	case int64:
		return typed > max
	default:
		return false
	}
}

func gatewayJSONNumberInt64(value any) (int64, bool) {
	switch typed := value.(type) {
	case json.Number:
		number, err := typed.Int64()
		return number, err == nil
	case float64:
		if typed != float64(int64(typed)) {
			return 0, false
		}
		return int64(typed), true
	case int:
		return int64(typed), true
	case int64:
		return typed, true
	default:
		return 0, false
	}
}

func sanitizedGatewayInitializeParams(params map[string]any) map[string]any {
	safe := map[string]any{}
	if clientInfo, ok := params["clientInfo"].(map[string]any); ok {
		sanitizedClientInfo := copyGatewayStringParams(clientInfo, "name", "title", "version")
		if len(sanitizedClientInfo) > 0 {
			safe["clientInfo"] = sanitizedClientInfo
		}
	}
	if capabilities, ok := params["capabilities"].(map[string]any); ok {
		sanitizedCapabilities := copyGatewayBoolParams(capabilities, "experimentalApi", "requestAttestation")
		if len(sanitizedCapabilities) > 0 {
			safe["capabilities"] = sanitizedCapabilities
		}
	}
	return safe
}

func sanitizedGatewayThreadParams(runtimeID string, method string, params map[string]any) map[string]any {
	safe := copyGatewayParams(params, "cwd", "serviceTier", "personality")
	if method == "thread/resume" || method == "thread/fork" {
		copyGatewayParam(safe, params, "threadId")
	}
	if method == "thread/resume" {
		safe["excludeTurns"] = true
		if page, ok := params["initialTurnsPage"].(map[string]any); ok {
			safe["initialTurnsPage"] = sanitizedGatewayInitialTurnsPage(page)
		}
	}
	safe["approvalPolicy"], safe["approvalsReviewer"] = sanitizedGatewayApproval(params)
	safe["sandbox"] = sanitizedGatewayThreadSandbox(runtimeID, params)
	return safe
}

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
	if normalizeAppServerRuntimeID(runtimeID) == "claude" {
		if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "readonly" {
			return "read-only"
		}
		return "workspace-write"
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
	safe["approvalPolicy"], safe["approvalsReviewer"] = sanitizedGatewayApproval(params)
	safe["sandboxPolicy"] = sanitizedGatewaySandboxPolicy(runtimeID, params["sandboxPolicy"], cwd)
	// 默认模型必须交给 app-server 按账号 rollout 决定；gateway 只透传用户显式选择的 model。
	if effort, ok := gatewayStringParam(safe, "effort"); !ok || strings.TrimSpace(effort) == "" {
		safe["effort"] = defaultCodexReasoningEffort
	}
	return safe
}

func sanitizedGatewayTurnSteerParams(params map[string]any) map[string]any {
	return copyGatewayParams(params, "threadId", "input", "clientUserMessageId", "expectedTurnId")
}

func logGatewayForwardedClientTurnSummary(method string, payload []byte) {
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
	// 默认模型不在 gateway 补齐；只有显式选择时才放进 collaboration settings。
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

func sanitizedGatewayApproval(params map[string]any) (string, string) {
	policy, _ := gatewayStringParam(params, "approvalPolicy")
	reviewer, _ := gatewayStringParam(params, "approvalsReviewer")
	// 移动端只放行一个有限自动审批组合：失败时交给 auto_review。
	// never / networkAccess 仍由 validateGatewayPolicyParams 统一拦截。
	if normalizePolicyValue(policy) == "onfailure" && reviewer == "auto_review" {
		return "on-failure", reviewer
	}
	return "on-request", "user"
}

func sanitizedGatewaySandboxPolicy(runtimeID string, raw any, cwd string) map[string]any {
	sandbox, _ := raw.(map[string]any)
	sandboxType, _ := gatewayStringParam(sandbox, "type")
	normalizedType := normalizePolicyValue(sandboxType)
	if normalizeAppServerRuntimeID(runtimeID) == "claude" {
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
	// 默认权限模式是“用户批准 + 完全访问”；网络仍默认关闭，避免无意放开外连能力。
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

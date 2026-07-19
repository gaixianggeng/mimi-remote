package httpapi

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func (r *Router) validateGatewayPolicyParams(runtimeID string, method string, params map[string]any) (appServerGatewayValidatedParams, error) {
	validated := appServerGatewayValidatedParams{}
	committedPendingUse := false
	defer func() {
		if !committedPendingUse {
			r.releaseManagedWorktreePendingUse(validated.pendingManagedWorktreePath)
		}
	}()
	if hasApprovalPolicyNever(params) {
		return validated, fmt.Errorf("approvalPolicy=never 不允许远程使用")
	}
	if hasDangerousConfigSandbox(params["config"]) {
		return validated, fmt.Errorf("dangerFullAccess 不允许通过 config 使用")
	}
	// Claude runtime 不在这里硬拒 dangerFullAccess：老客户端/默认草稿会在 thread/resume 上带全量沙盒，
	// 硬拒会让会话恢复进入确定性失败的重连死循环。rewriteGatewaySafeDefaults 的
	// sanitizedGatewayThreadSandbox / sanitizedGatewaySandboxPolicy 会把 Claude 的沙盒强制压回
	// workspace-write/read-only，所有 Claude 允许的方法都在改写覆盖范围内。
	if hasNetworkAccessEnabled(params) {
		return validated, fmt.Errorf("networkAccess=true 不允许远程使用")
	}
	if value, ok := params["collaborationMode"]; ok {
		if err := validateGatewayCollaborationMode(value); err != nil {
			return validated, err
		}
	}
	if method == "skills/list" {
		cwd, err := gatewaySingleListCWD(params, method)
		if err != nil {
			return validated, err
		}
		scope, ok := r.gatewayScopeForPath(cwd)
		if !ok {
			return validated, fmt.Errorf("skills/list.cwds 必须来自 projects allowlist 或 browse_roots")
		}
		if _, exists := params["forceReload"]; exists {
			if _, ok := gatewayBoolParam(params, "forceReload"); !ok {
				return validated, fmt.Errorf("skills/list.forceReload 必须是布尔值")
			}
		}
		validated.cwd = cwd
		validated.hasCWD = true
		validated.cwdScope = scope
		validated.cwdScopeOK = true
	}
	if method == "plugin/installed" {
		cwd, err := gatewaySingleListCWD(params, method)
		if err != nil {
			return validated, err
		}
		scope, ok := r.gatewayScopeForPath(cwd)
		if !ok {
			return validated, fmt.Errorf("plugin/installed.cwds 必须来自 projects allowlist 或 browse_roots")
		}
		if value, exists := params["installSuggestionPluginNames"]; exists && value != nil {
			return validated, fmt.Errorf("plugin/installed.installSuggestionPluginNames 尚未对移动端开放")
		}
		validated.cwd = cwd
		validated.hasCWD = true
		validated.cwdScope = scope
		validated.cwdScopeOK = true
	}
	if cwd, ok := gatewayStringParam(params, "cwd"); ok {
		scope, pendingManagedPath, scopeOK := r.gatewayScopeForPathWithPendingUse(cwd, gatewayMethodNeedsManagedPendingUse(method))
		if !scopeOK {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist 或 browse_roots", method)
		}
		validated.cwd = cwd
		validated.hasCWD = true
		validated.cwdScope = scope
		validated.cwdScopeOK = true
		validated.pendingManagedWorktreePath = pendingManagedPath
	}
	if requiresGatewayCWD(method) {
		if !validated.hasCWD {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist 或 browse_roots", method)
		}
	}
	roots, err := collectWritableRoots(params)
	if err != nil {
		return validated, err
	}
	seenRoots := map[string]struct{}{}
	for _, root := range roots {
		if root == validated.cwd && validated.cwdScopeOK {
			continue
		}
		if _, seen := seenRoots[root]; seen {
			continue
		}
		seenRoots[root] = struct{}{}
		// writableRoots 不随 browse_roots 放宽：browse workspace 的可写范围只有 cwd 本身
		//（上面 root == cwd 已放行），其余仍要求命中项目 allowlist。
		if _, ok := r.projectForGatewayPath(root); !ok {
			return validated, fmt.Errorf("sandboxPolicy.writableRoots 必须来自 projects allowlist")
		}
	}
	inputPaths, err := collectUserInputPaths(method, params)
	if err != nil {
		return validated, err
	}
	if method != "turn/steer" {
		for _, path := range inputPaths {
			if _, ok := r.projectForGatewayPath(path); ok {
				continue
			}
			// browse/worktree workspace 的结构化文件输入（图片/mention）允许引用绑定目录内的文件，
			// 但不允许引用允许根下的 sibling 目录，保持和 cwd 一样的精确边界。
			if validated.cwdScopeOK && (validated.cwdScope.browse || validated.cwdScope.managed) && gatewayScopeContainsPath(validated.cwdScope, path) {
				continue
			}
			return validated, fmt.Errorf("%s.input path 必须来自 projects allowlist", method)
		}
	}
	committedPendingUse = true
	return validated, nil
}

func gatewaySingleListCWD(params map[string]any, method string) (string, error) {
	raw, ok := params["cwds"]
	if !ok {
		return "", fmt.Errorf("%s.cwds 必须包含一个授权工作区", method)
	}
	values, ok := raw.([]any)
	if !ok || len(values) != 1 {
		return "", fmt.Errorf("%s.cwds 只能包含一个授权工作区", method)
	}
	cwd, ok := values[0].(string)
	cwd = strings.TrimSpace(cwd)
	if !ok || cwd == "" {
		return "", fmt.Errorf("%s.cwds 必须包含一个授权工作区", method)
	}
	return cwd, nil
}

func gatewayMethodNeedsManagedPendingUse(method string) bool {
	switch strings.TrimSpace(method) {
	case "thread/start", "thread/resume", "thread/fork":
		return true
	default:
		return false
	}
}

func requiresGatewayCWD(method string) bool {
	switch method {
	case "thread/list", "thread/start", "thread/resume", "thread/fork", "turn/start":
		return true
	default:
		return false
	}
}

func gatewayStringParam(params map[string]any, key string) (string, bool) {
	value, ok := params[key]
	if !ok {
		return "", false
	}
	text, ok := value.(string)
	return strings.TrimSpace(text), ok && strings.TrimSpace(text) != ""
}

func gatewayBoolParam(params map[string]any, key string) (bool, bool) {
	value, ok := params[key]
	if !ok {
		return false, false
	}
	typed, ok := value.(bool)
	return typed, ok
}

func collectUserInputPaths(method string, params map[string]any) ([]string, error) {
	raw, ok := params["input"]
	if !ok {
		return nil, nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("%s.input 必须是数组", method)
	}
	paths := []string{}
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s.input item 必须是 object", method)
		}
		inputType, _ := gatewayStringParam(obj, "type")
		switch inputType {
		case "localImage", "mention":
			path, ok := gatewayStringParam(obj, "path")
			if !ok {
				return nil, fmt.Errorf("%s.input.%s.path 不能为空", method, inputType)
			}
			paths = append(paths, path)
		case "skill":
			// Skill 可能来自用户级 / 管理员级 skill root 或插件缓存，不属于当前项目工作区；
			// gateway 只校验字段完整性，不把 skill.path 当作文件输入路径做 allowlist 限制。
			if _, ok := gatewayStringParam(obj, "path"); !ok {
				return nil, fmt.Errorf("%s.input.skill.path 不能为空", method)
			}
		case "image":
			url, ok := gatewayStringParam(obj, "url")
			if !ok {
				return nil, fmt.Errorf("%s.input.image.url 不能为空", method)
			}
			if strings.HasPrefix(strings.ToLower(url), "file:") {
				return nil, fmt.Errorf("%s.input.image.url 不允许 file URL，请使用 localImage.path", method)
			}
		case "text":
		default:
			return nil, fmt.Errorf("%s.input 类型不支持：%s", method, inputType)
		}
	}
	return paths, nil
}

func validateGatewayCollaborationMode(value any) error {
	mode, ok := value.(map[string]any)
	if !ok {
		return fmt.Errorf("collaborationMode 必须是 object")
	}
	if hasDangerousConfigSandbox(mode) {
		return fmt.Errorf("collaborationMode 不允许 dangerFullAccess")
	}
	modeValue, ok := gatewayStringParam(mode, "mode")
	if !ok {
		return fmt.Errorf("collaborationMode.mode 必须是 plan/default")
	}
	switch modeValue {
	case "plan", "default":
	default:
		return fmt.Errorf("collaborationMode.mode 不支持：%s", modeValue)
	}
	settings, ok := mode["settings"].(map[string]any)
	if !ok {
		return fmt.Errorf("collaborationMode.settings 必须是 object")
	}
	if model, ok := settings["model"]; ok && model != nil {
		if text, ok := model.(string); !ok || strings.TrimSpace(text) == "" {
			return fmt.Errorf("collaborationMode.settings.model 必须是非空字符串")
		}
	}
	if developerInstructions, ok := settings["developer_instructions"]; ok && developerInstructions != nil {
		return fmt.Errorf("collaborationMode.settings.developer_instructions 只能是 null")
	}
	if developerInstructions, ok := settings["developerInstructions"]; ok && developerInstructions != nil {
		return fmt.Errorf("collaborationMode.settings.developerInstructions 只能是 null")
	}
	if effort, ok := settings["reasoning_effort"]; ok && effort != nil {
		text, ok := effort.(string)
		if !ok {
			return fmt.Errorf("collaborationMode.settings.reasoning_effort 必须是字符串或 null")
		}
		switch text {
		case "none", "minimal", "low", "medium", "high", "xhigh":
		default:
			return fmt.Errorf("collaborationMode.settings.reasoning_effort 不支持：%s", text)
		}
	}
	return nil
}

func (r *Router) projectForGatewayPath(raw string) (projects.Project, bool) {
	project, _, ok := r.projectForGatewayPathWithRealPath(raw)
	return project, ok
}

func (r *Router) projectForGatewayPathWithRealPath(raw string) (projects.Project, string, bool) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return projects.Project{}, "", false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return projects.Project{}, "", false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return projects.Project{}, "", false
	}
	project, ok := r.projects.FindByPath(realPath)
	return project, realPath, ok
}

// gatewayScopeForPath 把路径解析成授权作用域：优先命中 projects allowlist（项目作用域），
// 否则若在 browse_roots 内则得到精确目录作用域；两者都不命中即未授权。
func (r *Router) gatewayScopeForPath(raw string) (gatewayScope, bool) {
	scope, _, ok := r.gatewayScopeForPathWithPendingUse(raw, false)
	return scope, ok
}

func (r *Router) gatewayScopeForPathWithPendingUse(raw string, acquirePendingUse bool) (gatewayScope, string, bool) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return gatewayScope{}, "", false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return gatewayScope{}, "", false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return gatewayScope{}, "", false
	}
	if project, ok := r.projects.FindByPath(realPath); ok {
		return gatewayScope{id: project.ID, realPath: realPath, project: project}, "", true
	}

	// managed checkout 的路径授权、LastUsedAt 推进和 pending-use 计数
	// 必须在同一 cleanup 临界区完成；否则普通 delete 可在“授权已通过、
	// pending thread 尚未登记”的窗口删掉 cwd。
	r.managedWorktreeCleanupMu.Lock()
	if worktree, ok := r.managedWorktreeForPathLocked(realPath); ok {
		pendingPath := ""
		if acquirePendingUse {
			pendingPath = worktree.Path
			r.acquireManagedWorktreePendingUseLocked(pendingPath)
		}
		r.managedWorktreeCleanupMu.Unlock()
		return gatewayScope{
			id:       workspaceIDForRealPath(worktree.Path),
			realPath: realPath,
			project:  worktree.RootProject,
			managed:  true,
		}, pendingPath, true
	}
	r.managedWorktreeCleanupMu.Unlock()
	if r.realPathInBrowseRoots(realPath) {
		return gatewayScope{id: workspaceIDForRealPath(realPath), realPath: realPath, browse: true}, "", true
	}
	return gatewayScope{}, "", false
}

// realPathInBrowseRoots 期望传入已 EvalSymlinks 的路径；browse root 自身每次惰性
// canonical 化，配置后新建的目录也能即时生效。
func (r *Router) realPathInBrowseRoots(realPath string) bool {
	for _, root := range r.cfg.BrowseRoots {
		value := strings.TrimSpace(root)
		if value == "" {
			continue
		}
		abs, err := filepath.Abs(value)
		if err != nil {
			continue
		}
		realRoot, err := filepath.EvalSymlinks(abs)
		if err != nil {
			continue
		}
		if realPathWithin(realRoot, realPath) {
			return true
		}
	}
	return false
}

func gatewayScopeContainsPath(scope gatewayScope, raw string) bool {
	path := strings.TrimSpace(raw)
	if path == "" {
		return false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return false
	}
	return realPathWithin(scope.realPath, realPath)
}

func realPathWithin(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)))
}

func collectWritableRoots(value any) ([]string, error) {
	var roots []string
	if err := collectWritableRootsInto(value, &roots); err != nil {
		return nil, err
	}
	return roots, nil
}

func collectWritableRootsInto(value any, roots *[]string) error {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if strings.EqualFold(key, "writableRoots") {
				items, ok := child.([]any)
				if !ok {
					return fmt.Errorf("sandboxPolicy.writableRoots 必须是字符串数组")
				}
				for _, item := range items {
					root, ok := item.(string)
					if !ok || strings.TrimSpace(root) == "" {
						return fmt.Errorf("sandboxPolicy.writableRoots 必须是字符串数组")
					}
					*roots = append(*roots, strings.TrimSpace(root))
				}
				continue
			}
			if err := collectWritableRootsInto(child, roots); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range typed {
			if err := collectWritableRootsInto(child, roots); err != nil {
				return err
			}
		}
	}
	return nil
}

func hasApprovalPolicyNever(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if normalizePolicyValue(key) == "approvalpolicy" {
				if text, ok := child.(string); ok && strings.EqualFold(strings.TrimSpace(text), "never") {
					return true
				}
			}
			if hasApprovalPolicyNever(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasApprovalPolicyNever(child) {
				return true
			}
		}
	}
	return false
}

func hasNetworkAccessEnabled(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if normalizePolicyValue(key) == "networkaccess" {
				if enabled, ok := child.(bool); ok && enabled {
					return true
				}
				if text, ok := child.(string); ok && strings.EqualFold(strings.TrimSpace(text), "true") {
					return true
				}
			}
			if hasNetworkAccessEnabled(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasNetworkAccessEnabled(child) {
				return true
			}
		}
	}
	return false
}

func hasDangerousConfigSandbox(value any) bool {
	return hasDangerousConfigSandboxValue(value, "")
}

func hasDangerousConfigSandboxValue(value any, parentKey string) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			normalizedKey := normalizePolicyValue(key)
			if normalizedKey == "dangerfullaccess" {
				return true
			}
			if normalizedKey == "sandbox" || normalizedKey == "sandboxmode" || (parentKey == "sandboxpolicy" && normalizedKey == "type") {
				if text, ok := child.(string); ok && normalizePolicyValue(text) == "dangerfullaccess" {
					return true
				}
			}
			if hasDangerousConfigSandboxValue(child, normalizedKey) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasDangerousConfigSandboxValue(child, parentKey) {
				return true
			}
		}
	}
	return false
}

func normalizePolicyValue(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.ReplaceAll(value, "-", "")
	value = strings.ReplaceAll(value, "_", "")
	return value
}

func writeGatewayPolicyError(conn *websocket.Conn, mu *sync.Mutex, policyErr *appServerGatewayPolicyError) bool {
	id := json.RawMessage("null")
	if policyErr.id != nil && len(*policyErr.id) > 0 {
		id = *policyErr.id
	}
	errorBody := map[string]any{
		"code":    appServerPolicyErrorCode,
		"message": policyErr.message,
	}
	if len(policyErr.data) > 0 {
		errorBody["data"] = policyErr.data
	}
	payload, err := json.Marshal(map[string]any{
		"id":    id,
		"error": errorBody,
	})
	if err != nil {
		return false
	}
	return writeWebSocketFrame(conn, mu, websocket.TextMessage, payload) == nil
}

func sanitizeGatewayURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return "[invalid-url]"
	}
	parsed.User = nil
	parsed.RawQuery = ""
	return parsed.String()
}

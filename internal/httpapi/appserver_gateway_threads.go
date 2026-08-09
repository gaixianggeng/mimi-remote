package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func (p *appServerGatewayPolicy) rememberPendingThreadResponse(id *json.RawMessage, method string, cwd string, scopeID string) error {
	return p.rememberPendingThreadResponseWithManagedUse(id, method, cwd, scopeID, "")
}

func (p *appServerGatewayPolicy) rememberPendingThreadResponseWithManagedUse(id *json.RawMessage, method string, cwd string, scopeID string, managedWorktreePath string) error {
	return p.rememberPendingThreadRequest(id, appServerGatewayPendingThreadRequest{
		method: method, cwd: cwd, scopeID: scopeID, managedWorktreePath: managedWorktreePath,
	})
}

func (p *appServerGatewayPolicy) rememberPendingThreadSearchResponse(id *json.RawMessage, limit int64, limitSet bool) error {
	return p.rememberPendingThreadRequest(id, appServerGatewayPendingThreadRequest{
		method: "thread/search", responseLimit: limit, responseLimitSet: limitSet,
	})
}

func (p *appServerGatewayPolicy) rememberPendingThreadRequest(id *json.RawMessage, pending appServerGatewayPendingThreadRequest) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		if pending.managedWorktreePath != "" {
			return fmt.Errorf("gateway pending thread 请求缺少 id")
		}
		return nil
	}
	if p.beforePendingRemember != nil {
		p.beforePendingRemember()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return fmt.Errorf("app-server gateway 连接已关闭")
	}
	now := time.Now()
	p.prunePendingThreadsLocked(now)
	if _, exists := p.pendingThreads[key]; !exists && len(p.pendingThreads) >= appServerGatewayPendingThreadMax {
		return fmt.Errorf("gateway pending thread 请求过多")
	}
	if _, exists := p.pendingThreads[key]; exists {
		return fmt.Errorf("gateway pending thread 请求 id 重复")
	}
	pending.createdAt = now
	p.pendingThreads[key] = pending
	return nil
}

func (p *appServerGatewayPolicy) prunePendingThreadsLocked(now time.Time) {
	for id, pending := range p.pendingThreads {
		if pending.managedWorktreePath != "" {
			// managed checkout 的 lease 不能因本地 TTL 自动释放：上游可能仍在
			// 创建/恢复 thread。只有明确响应、明确失败或 policy.close()
			// 才能证明该 cwd 不再处于未完成使用窗口。
			continue
		}
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingThreadTTL {
			delete(p.pendingThreads, id)
		}
	}
}

func (p *appServerGatewayPolicy) allowedThread(threadID string) (appServerGatewayAllowedThread, bool) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	p.mu.Lock()
	thread, ok := p.allowedThreads[threadID]
	p.mu.Unlock()
	if ok {
		return thread, true
	}
	if p.router == nil {
		return appServerGatewayAllowedThread{}, false
	}
	return p.router.gatewayThread(p.runtimeID, threadID)
}

func (r *Router) gatewayThread(runtimeID string, threadID string) (appServerGatewayAllowedThread, bool) {
	runtimeID = normalizeAppServerRuntimeID(runtimeID)
	if runtimeID == "" {
		runtimeID = "codex"
	}
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	key := gatewayThreadCacheKey(runtimeID, threadID)
	now := time.Now()
	r.gatewayThreadsMu.Lock()
	defer r.gatewayThreadsMu.Unlock()
	thread, ok := r.gatewayThreads[key]
	if !ok {
		return appServerGatewayAllowedThread{}, false
	}
	if gatewayThreadCacheExpired(thread, now) {
		delete(r.gatewayThreads, key)
		return appServerGatewayAllowedThread{}, false
	}
	// 全局授权表只服务断线重连的短期恢复；命中时刷新 lastSeen，让活跃 thread 不被容量裁剪误删。
	thread.lastSeen = now
	r.gatewayThreads[key] = thread
	return thread, ok
}

func (p *appServerGatewayPolicy) observeUpstreamFrame(messageType int, payload []byte) ([]byte, bool, *appServerGatewayPolicyError) {
	if messageType != websocket.TextMessage {
		return payload, true, nil
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return payload, true, nil
	}
	if strings.TrimSpace(frame.Method) != "" && frame.ID != nil {
		if !appServerServerRequestAllowed(p.runtimeID, frame.Method) {
			return payload, false, &appServerGatewayPolicyError{
				id:      frame.ID,
				message: "app-server server request 尚未被移动端支持：" + strings.TrimSpace(frame.Method),
				data: map[string]any{
					"reason": "unsupported_server_request",
					"method": strings.TrimSpace(frame.Method),
				},
			}
		}
		if err := p.rememberPendingServerRequest(frame.ID, frame.Method, frame.Params); err != nil {
			return payload, false, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
		}
		return payload, true, nil
	}
	if strings.TrimSpace(frame.Method) != "" && frame.ID == nil {
		if p.runtimeID == "codex" && p.router.isAutoThreadTitleNotification(frame.Params) {
			return payload, false, nil
		}
		if rewritten, ok := p.rewriteOwnedThreadHandoffLifecycle(&frame, payload); ok {
			// coordinator 自己触发的 archive 生命周期不是用户结束会话。改写为
			// 私有通知，让新版 iOS 只失效 resume binding，跳过 closed 终态投影。
			return rewritten, true, nil
		}
		p.clearPendingServerRequestsForNotification(&frame)
		p.rememberReplayedServerRequests(&frame)
		// 用户停留在完成页时也要释放 resident app-server 的 writer lock。
		// coordinator 先留出续问/本地队列窗口；新的 turn/start 会取消该任务。
		p.scheduleThreadHandoffAfterTerminal(&frame)
		if appServerRuntimeRedactsInlineImages(p.runtimeID) && appServerMediaRedactNotificationsEnabled() {
			if redacted, changed := p.router.redactInlineHistoryImagesInGatewayResponse(payload); changed {
				payload = redacted
			}
		}
		p.allowRelatedThreadsFromNotification(frame.Params)
		return payload, true, nil
	}
	if gatewayFrameIsResponse(&frame) {
		p.rememberAccountTokenUsageResponse(&frame, time.Now())
		if pending, ok := p.consumePendingHistoryRequest(frame.ID); ok {
			if len(frame.Error) == 0 && len(frame.Result) > 0 {
				if redacted, changed := p.router.redactInlineHistoryImagesInGatewayResponse(payload); changed {
					payload = redacted
				}
				if !pending.redactOnly &&
					appServerGatewayHistoryResponseCapBytes > 0 &&
					len(payload) > appServerGatewayHistoryResponseCapBytes {
					// 单个 turn 仍可能因命令、MCP 或 diff 输出超过 full cap。
					// 只在原响应必然被阻断时把这些过程输出改成短预览 + 鉴权引用，
					// 普通历史继续原样透传，不为小响应增加缓存或协议复杂度。
					if dehydrated, changed := p.router.dehydrateOversizedHistoryOutputs(payload); changed {
						payload = dehydrated
					}
				}
			}
			blocked := !pending.redactOnly && len(frame.Error) == 0 && len(frame.Result) > 0 && appServerGatewayHistoryResponseCapBytes > 0 && len(payload) > appServerGatewayHistoryResponseCapBytes
			p.recordHistoryResponseMetrics(pending.method, len(payload), blocked)
			if !pending.redactOnly {
				if blocked {
					// 被 cap 阻断的响应从未写回 iPad，不能计入保护下行链路的历史预算：
					// 否则这次未转发的大 full（如 9.78MB）会打满全局/本 key 响应预算，
					// 让紧随其后的小 summary 回退被 history_budget_limited 饿死，也会挡住
					// 后续 full 自适应缩页重试。这里只保留诊断指标，不消耗下载预算。
					p.forgetPending(frame.ID)
					return payload, false, &appServerGatewayPolicyError{
						id:      frame.ID,
						message: fmt.Sprintf("%s history response 过大（%d bytes > %d bytes），gateway 已阻断；请降低 limit/itemsView 或改用分页读取", pending.method, len(payload), appServerGatewayHistoryResponseCapBytes),
						data: gatewayPolicyErrorData("history_response_too_large", appServerGatewayHistoryBudgetWindow, map[string]any{
							"method":           pending.method,
							"threadId":         pending.threadID,
							"cwd":              pending.cwd,
							"itemsView":        pending.itemsView,
							"responseBytes":    len(payload),
							"maxResponseBytes": appServerGatewayHistoryResponseCapBytes,
						}),
						target:                 "client",
						historyResponseBlocked: true,
					}
				}
				p.recordHistoryResponseBudget(pending, len(payload))
			}
		}
	}
	if !p.hasPendingThreadResponses() {
		return payload, true, nil
	}
	if frame.ID == nil || len(frame.Result) == 0 || len(frame.Error) > 0 {
		p.forgetPending(frame.ID)
		return payload, true, nil
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return payload, true, nil
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	p.mu.Unlock()
	if !ok {
		return payload, true, nil
	}
	if pending.method == "thread/search" {
		rewritten, threads, err := p.sanitizeThreadSearchResponse(payload, pending)
		if err != nil {
			p.forgetPending(frame.ID)
			return payload, false, &appServerGatewayPolicyError{
				id: frame.ID, message: err.Error(), target: "client",
			}
		}
		p.completePendingThreadResponse(key, pending, threads)
		return rewritten, true, nil
	}
	if pending.method == "thread/list" && pending.globalDiscovery {
		rewritten, threads, err := p.sanitizeGlobalThreadListResponse(payload, pending)
		if err != nil {
			p.forgetPending(frame.ID)
			return payload, false, &appServerGatewayPolicyError{
				id: frame.ID, message: err.Error(), target: "client",
			}
		}
		p.completePendingThreadResponse(key, pending, threads)
		return rewritten, true, nil
	}
	if pending.method == "thread/turns/list" {
		p.completePendingThreadResponse(key, pending, p.relatedThreadsFromResult(frame.Result, pending))
		return payload, true, nil
	}
	if pending.method == "thread/read" {
		if err := p.validateReadOnlyThreadResponse(frame.Result, pending); err != nil {
			p.forgetPending(frame.ID)
			return payload, false, &appServerGatewayPolicyError{
				id:      frame.ID,
				message: err.Error(),
				data: gatewayPolicyErrorData("thread_read_scope_mismatch", 0, map[string]any{
					"threadId": pending.threadID,
				}),
				target: "client",
			}
		}
		payload = p.enforceReadOnlyThreadResponse(payload, pending.threadID)
	}
	p.completePendingThreadResponse(key, pending, p.threadsFromResult(frame.Result, pending))
	// 成功响应先把 thread 写入连接级与全局 gateway 授权表，再释放
	// pending-use。转换期间至少有一种保护存在，cleanup 看不到可删除窗口。
	return payload, true, nil
}

func (p *appServerGatewayPolicy) resolveGlobalListCursor(params map[string]any) error {
	raw, exists := params["cursor"]
	if !exists || raw == nil {
		return nil
	}
	token, ok := raw.(string)
	token = strings.TrimSpace(token)
	if !ok || token == "" {
		return fmt.Errorf("thread/list.cursor 必须是非空字符串")
	}
	p.mu.Lock()
	upstream, found := p.globalListCursors[token]
	p.mu.Unlock()
	if !found || strings.TrimSpace(upstream) == "" {
		return fmt.Errorf("thread/list.cursor 已失效或不属于当前授权连接")
	}
	params["cursor"] = upstream
	return nil
}

func (p *appServerGatewayPolicy) storeGlobalListCursor(upstream string) (string, error) {
	upstream = strings.TrimSpace(upstream)
	if upstream == "" {
		return "", nil
	}
	raw := make([]byte, 18)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("生成 thread/list 安全 cursor 失败")
	}
	token := "mimi_" + base64.RawURLEncoding.EncodeToString(raw)
	p.mu.Lock()
	if p.globalListCursors == nil || len(p.globalListCursors) >= appServerGatewayGlobalCursorMax {
		// cursor 只在当前 gateway 连接内有效。容量到顶时整体换代比逐项 LRU 更简单，
		// 旧页继续请求会明确失败，不会退回接受 upstream 原始 cursor。
		p.globalListCursors = map[string]string{}
	}
	p.globalListCursors[token] = upstream
	p.mu.Unlock()
	return token, nil
}

func (p *appServerGatewayPolicy) sanitizeGlobalThreadListResponse(
	payload []byte,
	pending appServerGatewayPendingThreadRequest,
) ([]byte, []appServerGatewayAllowedThread, error) {
	var response map[string]json.RawMessage
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, nil, fmt.Errorf("thread/list response 无效")
	}
	var resultFields map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &resultFields) != nil {
		return nil, nil, fmt.Errorf("thread/list response.result 必须是对象")
	}
	dataRaw, ok := resultFields["data"]
	if !ok || bytes.Equal(bytes.TrimSpace(dataRaw), []byte("null")) {
		return nil, nil, fmt.Errorf("thread/list response.data 必须是数组")
	}
	var rawItems []json.RawMessage
	if err := json.Unmarshal(dataRaw, &rawItems); err != nil {
		return nil, nil, fmt.Errorf("thread/list response.data 必须是数组")
	}

	limit := int64(appServerGatewayThreadListMaxLimit)
	if pending.responseLimitSet {
		limit = pending.responseLimit
	}
	if limit <= 0 || limit > appServerGatewayThreadListMaxLimit {
		limit = appServerGatewayThreadListMaxLimit
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	projectByCommonDir := p.authorizedProjectsByGitCommonDir(ctx)
	safeItems := make([]map[string]any, 0, min(len(rawItems), int(limit)))
	allowedThreads := make([]appServerGatewayAllowedThread, 0, cap(safeItems))
	for _, rawItem := range rawItems {
		if int64(len(safeItems)) >= limit || ctx.Err() != nil {
			break
		}
		var itemFields map[string]json.RawMessage
		var thread appServerGatewayThreadWire
		if json.Unmarshal(rawItem, &itemFields) != nil || json.Unmarshal(rawItem, &thread) != nil {
			continue
		}
		threadIDRaw := firstNonEmptyRaw(thread.ID, thread.ThreadID, thread.SessionID)
		cwdRaw := firstNonEmptyRaw(thread.CWD, thread.Path)
		threadID := strings.TrimSpace(threadIDRaw)
		cwd := strings.TrimSpace(cwdRaw)
		if threadID == "" || threadID != threadIDRaw || cwd == "" || cwd != cwdRaw || !filepath.IsAbs(cwd) {
			continue
		}
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		info, err := os.Stat(scope.realPath)
		if err != nil || !info.IsDir() {
			continue
		}
		project, ok := projectForGlobalThread(ctx, scope, projectByCommonDir)
		if !ok {
			continue
		}

		// 外部 browse-root Worktree 和所有显式 parent 子会话都只有“可读发现”资格。
		// 上游即使声明 canAcceptDirectInput=true，也不能越过 Phase 1 父会话管理边界。
		forceReadOnly := scope.browse || strings.TrimSpace(thread.ParentThreadID) != ""
		canAccept := false
		directInputKnown := forceReadOnly || thread.CanAcceptDirectInput != nil
		if thread.CanAcceptDirectInput != nil && !forceReadOnly {
			canAccept = *thread.CanAcceptDirectInput
		}

		safeThread := copyGatewayRawFields(itemFields,
			"id", "sessionId", "threadId", "parentThreadId", "cwd", "path",
			"name", "preview", "status", "modelProvider", "source", "threadSource",
			"agentNickname", "agentRole", "gitInfo", "createdAt", "updatedAt", "recencyAt",
			"canAcceptDirectInput",
		)
		if forceReadOnly {
			safeThread["canAcceptDirectInput"] = false
		}
		safeThread["mimiRemote"] = map[string]any{
			"projectId":   project.ID,
			"projectName": project.Name,
			"projectPath": project.Path,
			"discovery":   "global",
			"readOnly":    forceReadOnly,
		}
		safeItems = append(safeItems, safeThread)
		allowedThreads = append(allowedThreads, appServerGatewayAllowedThread{
			id:                   threadID,
			runtimeID:            normalizeAppServerRuntimeID(p.runtimeID),
			cwd:                  scope.realPath,
			scopeID:              scope.id,
			canAcceptDirectInput: canAccept,
			directInputKnown:     directInputKnown,
			readOnly:             forceReadOnly,
		})
	}

	safeResult := map[string]any{"data": safeItems}
	if rawCursor, exists := resultFields["nextCursor"]; exists && !bytes.Equal(bytes.TrimSpace(rawCursor), []byte("null")) {
		var upstreamCursor string
		if json.Unmarshal(rawCursor, &upstreamCursor) == nil && strings.TrimSpace(upstreamCursor) != "" {
			cursor, err := p.storeGlobalListCursor(upstreamCursor)
			if err != nil {
				return nil, nil, err
			}
			safeResult["nextCursor"] = cursor
		}
	} else if exists {
		safeResult["nextCursor"] = nil
	}
	safeResponse := map[string]any{
		"jsonrpc": "2.0",
		"id":      response["id"],
		"result":  safeResult,
	}
	rewritten, err := json.Marshal(safeResponse)
	if err != nil {
		return nil, nil, fmt.Errorf("重写 thread/list response 失败：%w", err)
	}
	return rewritten, allowedThreads, nil
}

func (p *appServerGatewayPolicy) enforceReadOnlyThreadResponse(payload []byte, threadID string) []byte {
	allowed, ok := p.allowedThread(threadID)
	if !ok || !allowed.readOnly {
		return payload
	}
	var response map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if decoder.Decode(&response) != nil {
		return payload
	}
	result, ok := response["result"].(map[string]any)
	if !ok {
		return payload
	}
	thread, ok := result["thread"].(map[string]any)
	if !ok {
		return payload
	}
	actualID, _ := gatewayStringParam(thread, "id")
	if actualID == "" {
		actualID, _ = gatewayStringParam(thread, "threadId")
	}
	if actualID != "" && actualID != strings.TrimSpace(threadID) {
		return payload
	}
	thread["canAcceptDirectInput"] = false
	annotation, _ := thread["mimiRemote"].(map[string]any)
	if annotation == nil {
		annotation = map[string]any{}
	}
	annotation["readOnly"] = true
	thread["mimiRemote"] = annotation
	rewritten, err := json.Marshal(response)
	if err != nil {
		return payload
	}
	return rewritten
}

func (p *appServerGatewayPolicy) validateReadOnlyThreadResponse(
	raw json.RawMessage,
	pending appServerGatewayPendingThreadRequest,
) error {
	allowed, ok := p.allowedThread(pending.threadID)
	if !ok || !allowed.readOnly {
		return nil
	}

	// receiverThreadIds 只提供关联线索，不能证明子 Thread 自身仍位于父会话作用域。
	// 对只读 Thread 的首次/后续读取都重新核对响应中的真实 cwd；缺失或跨作用域时
	// fail-closed，避免先借父 cwd 获得临时授权，再读取未授权目录中的会话正文。
	var result struct {
		Thread appServerGatewayThreadWire `json:"thread"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return fmt.Errorf("thread/read 返回的只读子会话无法完成作用域校验")
	}
	threadIDRaw := firstNonEmptyRaw(result.Thread.ID, result.Thread.ThreadID, result.Thread.SessionID)
	threadID := strings.TrimSpace(threadIDRaw)
	if threadID == "" || threadID != threadIDRaw || threadID != strings.TrimSpace(pending.threadID) {
		return fmt.Errorf("thread/read 返回的只读子会话身份与请求不一致")
	}
	cwdRaw := firstNonEmptyRaw(result.Thread.CWD, result.Thread.Path)
	cwd := strings.TrimSpace(cwdRaw)
	if cwd == "" || cwd != cwdRaw || !filepath.IsAbs(cwd) || p.router == nil {
		return fmt.Errorf("thread/read 返回的只读子会话缺少可验证的 cwd")
	}
	scope, ok := p.router.gatewayScopeForPath(cwd)
	if !ok || scope.id != allowed.scopeID {
		return fmt.Errorf("thread/read 返回的只读子会话不在授权作用域")
	}
	info, err := os.Stat(scope.realPath)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("thread/read 返回的只读子会话 cwd 不可用")
	}
	return nil
}

func (p *appServerGatewayPolicy) authorizedProjectsByGitCommonDir(ctx context.Context) map[string]projects.Project {
	grouped := map[string][]projects.Project{}
	out := map[string]projects.Project{}
	for _, project := range p.router.projects.List() {
		commonDir, ok := gitCommonDirectory(ctx, project.RealPath)
		if !ok {
			continue
		}
		grouped[commonDir] = append(grouped[commonDir], project)
	}
	for commonDir, candidates := range grouped {
		if project, ok := selectAuthorizedProjectForGitCommonDir(commonDir, candidates); ok {
			out[commonDir] = project
		}
	}
	return out
}

func selectAuthorizedProjectForGitCommonDir(commonDir string, candidates []projects.Project) (projects.Project, bool) {
	if len(candidates) == 1 {
		return candidates[0], true
	}

	var primary projects.Project
	primaryCount := 0
	for _, project := range candidates {
		// linked worktree 的 .git 是指向 common-dir/worktrees/* 的文件；只有普通
		// 主工作树的 .git 目录（或其目录 symlink）会解析到仓库 common-dir。
		// 多 Project 共仓时据此稳定归属到唯一主项目，缺失或重复主项目仍 fail-closed。
		gitMarker := filepath.Join(project.RealPath, ".git")
		info, err := os.Stat(gitMarker)
		if err != nil || !info.IsDir() {
			continue
		}
		realGitMarker, err := filepath.EvalSymlinks(gitMarker)
		if err != nil || filepath.Clean(realGitMarker) != filepath.Clean(commonDir) {
			continue
		}
		primary = project
		primaryCount++
	}
	if primaryCount != 1 {
		return projects.Project{}, false
	}
	return primary, true
}

func projectForGlobalThread(
	ctx context.Context,
	scope gatewayScope,
	projectByCommonDir map[string]projects.Project,
) (projects.Project, bool) {
	if strings.TrimSpace(scope.project.ID) != "" {
		return scope.project, true
	}
	if !scope.browse {
		return projects.Project{}, false
	}
	commonDir, ok := gitCommonDirectory(ctx, scope.realPath)
	if !ok {
		return projects.Project{}, false
	}
	project, ok := projectByCommonDir[commonDir]
	return project, ok
}

func copyGatewayRawFields(src map[string]json.RawMessage, keys ...string) map[string]any {
	dst := make(map[string]any, len(keys))
	for _, key := range keys {
		if raw, ok := src[key]; ok {
			dst[key] = raw
		}
	}
	return dst
}

func (p *appServerGatewayPolicy) sanitizeThreadSearchResponse(payload []byte, pending appServerGatewayPendingThreadRequest) ([]byte, []appServerGatewayAllowedThread, error) {
	var response map[string]json.RawMessage
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, nil, fmt.Errorf("thread/search response 无效")
	}
	var resultFields map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &resultFields) != nil {
		return nil, nil, fmt.Errorf("thread/search response.result 必须是对象")
	}
	dataRaw, ok := resultFields["data"]
	if !ok || bytes.Equal(bytes.TrimSpace(dataRaw), []byte("null")) {
		return nil, nil, fmt.Errorf("thread/search response.data 必须是数组")
	}
	var rawItems []json.RawMessage
	if err := json.Unmarshal(dataRaw, &rawItems); err != nil {
		return nil, nil, fmt.Errorf("thread/search response.data 必须是数组")
	}

	limit := int64(appServerGatewayThreadSearchMaxLimit)
	if pending.responseLimitSet {
		limit = pending.responseLimit
	}
	if limit < 0 || limit > appServerGatewayThreadSearchMaxLimit {
		limit = appServerGatewayThreadSearchMaxLimit
	}
	safeItems := make([]map[string]any, 0, min(len(rawItems), int(limit)))
	allowedThreads := make([]appServerGatewayAllowedThread, 0, cap(safeItems))
	for _, rawItem := range rawItems {
		if int64(len(safeItems)) >= limit {
			break
		}
		var item map[string]json.RawMessage
		if json.Unmarshal(rawItem, &item) != nil {
			continue
		}
		var snippet string
		if raw := item["snippet"]; len(raw) == 0 || json.Unmarshal(raw, &snippet) != nil {
			continue
		}
		threadRaw := item["thread"]
		var thread appServerGatewayThreadWire
		if len(threadRaw) == 0 || bytes.Equal(bytes.TrimSpace(threadRaw), []byte("null")) || json.Unmarshal(threadRaw, &thread) != nil {
			continue
		}
		threadID := strings.TrimSpace(thread.ID)
		cwd := strings.TrimSpace(thread.CWD)
		// 0.144.2 schema 要求 Thread.id 与绝对 cwd。不能让 filepath.Abs 把相对路径
		// 悄悄解释成 agentd 当前目录，也不能把 trim 后与客户端看到值不同的 thread 登记进授权表。
		if threadID == "" || threadID != thread.ID || cwd == "" || cwd != thread.CWD || !filepath.IsAbs(cwd) {
			continue
		}
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		info, err := os.Stat(scope.realPath)
		if err != nil || !info.IsDir() {
			continue
		}
		safeItems = append(safeItems, map[string]any{
			"thread":  threadRaw,
			"snippet": snippet,
		})
		allowedThreads = append(allowedThreads, appServerGatewayAllowedThread{
			id: threadID, runtimeID: normalizeAppServerRuntimeID(p.runtimeID), cwd: scope.realPath, scopeID: scope.id,
		})
	}

	// 只重建协议声明字段：被过滤条目的 snippet 与 result 级未知字段都不会残留在下行 JSON。
	safeResult := map[string]any{"data": safeItems}
	copyGatewaySearchCursor(safeResult, resultFields, "nextCursor")
	copyGatewaySearchCursor(safeResult, resultFields, "backwardsCursor")
	safeResponse := map[string]any{
		"jsonrpc": "2.0",
		"id":      response["id"],
		"result":  safeResult,
	}
	rewritten, err := json.Marshal(safeResponse)
	if err != nil {
		return nil, nil, fmt.Errorf("重写 thread/search response 失败：%w", err)
	}
	return rewritten, allowedThreads, nil
}

func copyGatewaySearchCursor(dst map[string]any, src map[string]json.RawMessage, key string) {
	raw, ok := src[key]
	if !ok {
		return
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		dst[key] = nil
		return
	}
	var cursor string
	if json.Unmarshal(raw, &cursor) == nil {
		dst[key] = cursor
	}
}

func appServerServerRequestAllowed(runtimeID string, method string) bool {
	// Codex 与 Claude 都只开放 iOS 已实现的反向请求。bridge 是外部进程，未知方法同样必须
	// fail closed，避免移动端无法响应时让 Claude turn 永久等待。
	_ = runtimeID
	_, ok := appServerAllowedServerRequestMethods[strings.TrimSpace(method)]
	return ok
}

// 直播 turn 事件里的内联图（imageGeneration 裸 base64、mcpToolCall/dynamicToolCall
// 图片 result、data:image URL）在 codex 和 claude 两条 runtime 上形状一致，都会把
// 大 base64 顺着 WS + 隧道推一遍。两条链路统一改写成短 URL，避免 Claude 通道漏改导致
// 带宽打满或单帧撞 gateway cap。其它未知 runtime 仍保持原样透传，不改既有语义。
func appServerRuntimeRedactsInlineImages(runtimeID string) bool {
	switch normalizeAppServerRuntimeID(runtimeID) {
	case "codex", "claude":
		return true
	default:
		return false
	}
}

func appServerMediaRedactNotificationsEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(appServerMediaRedactNotifyEnv))) {
	case "0", "false", "off", "no":
		return false
	default:
		return true
	}
}

func gatewayFrameIsResponse(frame *appServerGatewayFrame) bool {
	return frame != nil &&
		strings.TrimSpace(frame.Method) == "" &&
		frame.ID != nil &&
		(len(frame.Result) > 0 || len(frame.Error) > 0)
}

func (p *appServerGatewayPolicy) rememberPendingClientRequest(id *json.RawMessage, method string) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("%s 请求缺少 id", method)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingClientRequestsLocked(now)
	if p.pendingClientRequests == nil {
		p.pendingClientRequests = map[string]appServerGatewayPendingClientRequest{}
	}
	if _, exists := p.pendingClientRequests[key]; !exists && len(p.pendingClientRequests) >= appServerGatewayPendingClientRequestMax {
		return fmt.Errorf("gateway pending client request 过多")
	}
	p.pendingClientRequests[key] = appServerGatewayPendingClientRequest{method: method, createdAt: now}
	return nil
}

func (p *appServerGatewayPolicy) consumePendingClientRequest(id *json.RawMessage) (appServerGatewayPendingClientRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingClientRequest{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingClientRequestsLocked(time.Now())
	request, ok := p.pendingClientRequests[key]
	if ok {
		delete(p.pendingClientRequests, key)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) prunePendingClientRequestsLocked(now time.Time) {
	for id, pending := range p.pendingClientRequests {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingClientRequestTTL {
			delete(p.pendingClientRequests, id)
		}
	}
}

// rememberReplayedServerRequests re-registers the server requests a resident
// bridge reports as still unanswered when a connection attaches.
//
// The pending table is per-connection, but the requests it guards are not:
// the bridge holds an approval prompt open across a disconnect, and announces
// the survivors in a `serverRequest/replay` notification. That frame carries
// no JSON-RPC id of its own, so without this the ids inside it were never
// registered and `validateClientResponse` rejected the user's answer as "not
// issued by app-server" — the prompt would come back after a reconnect and
// then refuse to be answered.
func (p *appServerGatewayPolicy) rememberReplayedServerRequests(frame *appServerGatewayFrame) {
	if strings.TrimSpace(frame.Method) != claudeBridgeServerRequestReplayMethod || len(frame.Params) == 0 {
		return
	}
	var params struct {
		Outstanding []struct {
			ID     *json.RawMessage `json:"id"`
			Method string           `json:"method"`
			Params json.RawMessage  `json:"params"`
		} `json:"outstanding"`
	}
	if err := json.Unmarshal(frame.Params, &params); err != nil {
		log.Printf("claude bridge serverRequest/replay 解析失败 err=%v", err)
		return
	}
	for _, entry := range params.Outstanding {
		if entry.ID == nil || strings.TrimSpace(entry.Method) == "" {
			continue
		}
		if !appServerServerRequestAllowed(p.runtimeID, entry.Method) {
			// The client cannot render it, so it will never answer it; leaving
			// it unregistered keeps the pending table honest.
			continue
		}
		if err := p.rememberPendingServerRequest(entry.ID, entry.Method, entry.Params); err != nil {
			log.Printf("claude bridge 重放 server request 登记失败 method=%s err=%v",
				sanitizeGatewayDiagnostic(entry.Method), err)
		}
	}
}

func (p *appServerGatewayPolicy) rememberPendingServerRequest(id *json.RawMessage, method string, rawParams json.RawMessage) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("app-server request 缺少 id")
	}
	threadID, turnID, itemID := appServerGatewayServerRequestScope(rawParams)
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingServerRequestsLocked(now)
	if p.pendingServerRequests == nil {
		p.pendingServerRequests = map[string]appServerGatewayPendingServerRequest{}
	}
	if _, exists := p.pendingServerRequests[key]; !exists && len(p.pendingServerRequests) >= appServerGatewayPendingServerRequestMax {
		return fmt.Errorf("gateway pending server request 过多")
	}
	p.pendingServerRequests[key] = appServerGatewayPendingServerRequest{
		method:    method,
		threadID:  threadID,
		turnID:    turnID,
		itemID:    itemID,
		createdAt: now,
	}
	return nil
}

func appServerGatewayServerRequestScope(rawParams json.RawMessage) (string, string, string) {
	params, err := decodeGatewayParams(rawParams)
	if err != nil {
		return "", "", ""
	}
	threadID, _ := gatewayStringParam(params, "threadId")
	if threadID == "" {
		threadID, _ = gatewayStringParam(params, "sessionId")
	}
	turnID, _ := gatewayStringParam(params, "turnId")
	if turnID == "" {
		if turn, ok := params["turn"].(map[string]any); ok {
			turnID, _ = gatewayStringParam(turn, "id")
		}
	}
	itemID, _ := gatewayStringParam(params, "itemId")
	if itemID == "" {
		for _, key := range []string{"requestId", "approvalId", "callId"} {
			if itemID, _ = gatewayStringParam(params, key); itemID != "" {
				break
			}
		}
	}
	return threadID, turnID, itemID
}

func (p *appServerGatewayPolicy) clearPendingServerRequestsForNotification(frame *appServerGatewayFrame) {
	method := strings.TrimSpace(frame.Method)
	switch method {
	case "serverRequest/resolved":
		var params struct {
			RequestID  json.RawMessage `json:"requestId"`
			RequestID2 json.RawMessage `json:"request_id"`
			ID         json.RawMessage `json:"id"`
			ApprovalID json.RawMessage `json:"approvalId"`
			ItemID     json.RawMessage `json:"itemId"`
			ItemID2    json.RawMessage `json:"item_id"`
		}
		if err := json.Unmarshal(frame.Params, &params); err != nil {
			return
		}
		p.mu.Lock()
		for _, id := range []json.RawMessage{
			params.RequestID,
			params.RequestID2,
			params.ID,
			params.ApprovalID,
			params.ItemID,
			params.ItemID2,
		} {
			if key := gatewayRequestIDKey(rawMessagePointer(id)); key != "" {
				delete(p.pendingServerRequests, key)
			}
		}
		threadID, _, itemID := appServerGatewayServerRequestScope(frame.Params)
		if threadID != "" && itemID != "" {
			for id, pending := range p.pendingServerRequests {
				if pending.threadID == threadID && pending.itemID == itemID {
					delete(p.pendingServerRequests, id)
				}
			}
		}
		p.mu.Unlock()
	case "turn/completed", "thread/closed", "error":
		threadID, turnID, _ := appServerGatewayServerRequestScope(frame.Params)
		if threadID == "" {
			return
		}
		p.mu.Lock()
		for id, pending := range p.pendingServerRequests {
			if pending.threadID != threadID {
				continue
			}
			if method != "thread/closed" && turnID != "" && pending.turnID != "" && pending.turnID != turnID {
				continue
			}
			delete(p.pendingServerRequests, id)
		}
		p.mu.Unlock()
	}
}

func rawMessagePointer(value json.RawMessage) *json.RawMessage {
	if len(value) == 0 || string(value) == "null" {
		return nil
	}
	return &value
}

func (p *appServerGatewayPolicy) consumePendingServerRequest(id *json.RawMessage) (appServerGatewayPendingServerRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingServerRequest{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingServerRequestsLocked(time.Now())
	request, ok := p.pendingServerRequests[key]
	if ok {
		delete(p.pendingServerRequests, key)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) prunePendingServerRequestsLocked(now time.Time) {
	for id, pending := range p.pendingServerRequests {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingServerRequestTTL {
			delete(p.pendingServerRequests, id)
		}
	}
}

func (p *appServerGatewayPolicy) hasPendingThreadResponses() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingThreadsLocked(time.Now())
	return len(p.pendingThreads) > 0
}

func (p *appServerGatewayPolicy) forgetPending(id *json.RawMessage) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	if ok {
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	if ok {
		p.router.releaseManagedWorktreePendingUse(pending.managedWorktreePath)
	}
}

func (p *appServerGatewayPolicy) isClosed() bool {
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	return closed
}

func (p *appServerGatewayPolicy) close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	paths := make([]string, 0, len(p.pendingThreads))
	for key, pending := range p.pendingThreads {
		if pending.managedWorktreePath != "" {
			paths = append(paths, pending.managedWorktreePath)
		}
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	for _, path := range paths {
		p.router.releaseManagedWorktreePendingUse(path)
	}
}

func (p *appServerGatewayPolicy) threadsFromResult(raw json.RawMessage, pending appServerGatewayPendingThreadRequest) []appServerGatewayAllowedThread {
	var threads []appServerGatewayThreadWire
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err == nil {
		appendThreadWire := func(value json.RawMessage) {
			var thread appServerGatewayThreadWire
			if len(value) > 0 && !bytes.Equal(bytes.TrimSpace(value), []byte("null")) && json.Unmarshal(value, &thread) == nil {
				threads = append(threads, thread)
			}
		}
		appendThreadWire(object["thread"])
		for _, key := range []string{"data", "threads"} {
			if value := object[key]; len(value) > 0 {
				var list []appServerGatewayThreadWire
				if err := json.Unmarshal(value, &list); err == nil {
					threads = append(threads, list...)
				}
			}
		}
	}
	if len(threads) == 0 {
		var list []appServerGatewayThreadWire
		if err := json.Unmarshal(raw, &list); err == nil {
			threads = append(threads, list...)
		}
	}

	out := make([]appServerGatewayAllowedThread, 0, len(threads))
	for _, item := range threads {
		id := firstNonEmpty(item.ID, item.ThreadID, item.SessionID)
		if strings.TrimSpace(id) == "" {
			continue
		}
		cwd := firstNonEmpty(item.CWD, item.Path, pending.cwd)
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		if pending.scopeID != "" && scope.id != pending.scopeID {
			continue
		}
		out = append(out, appServerGatewayAllowedThread{
			id:                   strings.TrimSpace(id),
			runtimeID:            normalizeAppServerRuntimeID(p.runtimeID),
			canAcceptDirectInput: item.CanAcceptDirectInput != nil && *item.CanAcceptDirectInput,
			directInputKnown:     item.CanAcceptDirectInput != nil,
			autoTitleEligible:    pending.method == "thread/start" && normalizeAppServerRuntimeID(p.runtimeID) == "codex",
			// browse 作用域用 canonical 路径绑定，避免同一目录的不同写法绕过精确匹配。
			cwd:     scope.realPath,
			scopeID: scope.id,
		})
		out = append(out, relatedThreadsForParent(
			receiverThreadIDsFromWireTurns(item.Turns),
			normalizeAppServerRuntimeID(p.runtimeID),
			scope.realPath,
			scope.id,
		)...)
	}
	if pending.threadID != "" {
		out = append(out, p.relatedThreadsFromResult(raw, pending)...)
	}
	return out
}

func receiverThreadIDsFromWireTurns(turns []struct {
	Items []struct {
		Type              string         `json:"type"`
		ReceiverThreadIDs []string       `json:"receiverThreadIds"`
		AgentsStates      map[string]any `json:"agentsStates"`
	} `json:"items"`
}) []string {
	var ids []string
	for _, turn := range turns {
		for _, item := range turn.Items {
			if item.Type != "collabAgentToolCall" {
				continue
			}
			ids = append(ids, item.ReceiverThreadIDs...)
		}
	}
	return ids
}

func (p *appServerGatewayPolicy) relatedThreadsFromResult(
	raw json.RawMessage,
	pending appServerGatewayPendingThreadRequest,
) []appServerGatewayAllowedThread {
	parent, ok := p.allowedThread(pending.threadID)
	if !ok {
		return nil
	}
	return relatedThreadsForParent(
		receiverThreadIDsFromJSON(raw),
		normalizeAppServerRuntimeID(p.runtimeID),
		parent.cwd,
		parent.scopeID,
	)
}

func (p *appServerGatewayPolicy) allowRelatedThreadsFromNotification(raw json.RawMessage) {
	var params map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&params) != nil {
		return
	}
	parentID, _ := gatewayStringParam(params, "threadId")
	if parentID == "" {
		if thread, ok := params["thread"].(map[string]any); ok {
			parentID, _ = gatewayStringParam(thread, "id")
		}
	}
	parent, ok := p.allowedThread(parentID)
	if !ok {
		return
	}
	for _, related := range relatedThreadsForParent(
		receiverThreadIDsFromAny(params),
		normalizeAppServerRuntimeID(p.runtimeID),
		parent.cwd,
		parent.scopeID,
	) {
		p.allowThread(related)
	}
}

func receiverThreadIDsFromJSON(raw json.RawMessage) []string {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&value) != nil {
		return nil
	}
	return receiverThreadIDsFromAny(value)
}

func receiverThreadIDsFromAny(value any) []string {
	var ids []string
	var walk func(any, int)
	walk = func(current any, depth int) {
		if depth > 12 {
			return
		}
		switch typed := current.(type) {
		case map[string]any:
			itemType, _ := gatewayStringParam(typed, "type")
			if itemType == "collabAgentToolCall" {
				if rawIDs, ok := typed["receiverThreadIds"].([]any); ok {
					for _, rawID := range rawIDs {
						id, ok := rawID.(string)
						if ok && id != "" && id == strings.TrimSpace(id) {
							ids = append(ids, id)
						}
					}
				}
			}
			for _, child := range typed {
				walk(child, depth+1)
			}
		case []any:
			for _, child := range typed {
				walk(child, depth+1)
			}
		}
	}
	walk(value, 0)
	return ids
}

func relatedThreadsForParent(ids []string, runtimeID string, cwd string, scopeID string) []appServerGatewayAllowedThread {
	seen := map[string]struct{}{}
	out := make([]appServerGatewayAllowedThread, 0, len(ids))
	for _, rawID := range ids {
		id := strings.TrimSpace(rawID)
		if id == "" || id != rawID {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, appServerGatewayAllowedThread{
			id:                   id,
			runtimeID:            runtimeID,
			cwd:                  cwd,
			scopeID:              scopeID,
			canAcceptDirectInput: false,
			directInputKnown:     true,
			// MIM-24 Phase 1 只允许从父会话查看子 Thread。即使后续
			// thread/read 返回 true，也不能把父侧派生出的权限升级成可写。
			readOnly: true,
		})
	}
	return out
}

func (p *appServerGatewayPolicy) allowThread(thread appServerGatewayAllowedThread) {
	thread, ok := p.normalizeAllowedThread(thread)
	if !ok {
		return
	}
	p.mu.Lock()
	p.allowedThreads[thread.id] = thread
	p.mu.Unlock()
	p.router.allowGatewayThread(thread)
}

func (p *appServerGatewayPolicy) normalizeAllowedThread(thread appServerGatewayAllowedThread) (appServerGatewayAllowedThread, bool) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
		return appServerGatewayAllowedThread{}, false
	}
	if existing, ok := p.allowedThread(thread.id); ok {
		if existing.readOnly {
			thread.readOnly = true
			thread.directInputKnown = true
			thread.canAcceptDirectInput = false
		} else if !thread.directInputKnown && existing.directInputKnown {
			thread.directInputKnown = true
			thread.canAcceptDirectInput = existing.canAcceptDirectInput
		}
	}
	if strings.TrimSpace(thread.runtimeID) == "" {
		thread.runtimeID = normalizeAppServerRuntimeID(p.runtimeID)
	}
	thread.lastSeen = time.Now()
	return thread, true
}

func (p *appServerGatewayPolicy) completePendingThreadResponse(key string, pending appServerGatewayPendingThreadRequest, threads []appServerGatewayAllowedThread) {
	normalized := make([]appServerGatewayAllowedThread, 0, len(threads))
	for _, thread := range threads {
		if item, ok := p.normalizeAllowedThread(thread); ok {
			normalized = append(normalized, item)
		}
	}

	if pending.managedWorktreePath == "" {
		p.mu.Lock()
		current, ok := p.pendingThreads[key]
		if p.closed || !ok || current.createdAt != pending.createdAt {
			p.mu.Unlock()
			return
		}
		delete(p.pendingThreads, key)
		for _, thread := range normalized {
			p.allowedThreads[thread.id] = thread
			p.router.allowGatewayThread(thread)
		}
		p.mu.Unlock()
		return
	}

	// 固定锁顺序 cleanupMu -> policy.mu -> gatewayThreadsMu。policy.mu 与
	// pending entry 一起充当 close barrier：close 若先发生，晚到响应
	// 不得重新登记 thread；响应若先发生，则在同一 cleanup
	// 临界区内完成全局授权与 lease 释放。
	p.router.managedWorktreeCleanupMu.Lock()
	p.mu.Lock()
	current, ok := p.pendingThreads[key]
	if p.closed || !ok || current.managedWorktreePath != pending.managedWorktreePath || current.createdAt != pending.createdAt {
		p.mu.Unlock()
		p.router.managedWorktreeCleanupMu.Unlock()
		return
	}
	if p.beforeManagedComplete != nil {
		p.beforeManagedComplete()
	}
	delete(p.pendingThreads, key)
	for _, thread := range normalized {
		p.allowedThreads[thread.id] = thread
		p.router.allowGatewayThread(thread)
	}
	p.router.releaseManagedWorktreePendingUseLocked(pending.managedWorktreePath)
	p.mu.Unlock()
	p.router.managedWorktreeCleanupMu.Unlock()
}

func (r *Router) allowGatewayThread(thread appServerGatewayAllowedThread) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
		return
	}
	if strings.TrimSpace(thread.runtimeID) == "" {
		thread.runtimeID = "codex"
	}
	thread.runtimeID = normalizeAppServerRuntimeID(thread.runtimeID)
	// 新建资格只属于发起 thread/start 的 gateway 连接。全局表服务断线恢复，
	// 不能让一次 resume 在重连后把历史线程误判成新会话。
	thread.autoTitleEligible = false
	now := time.Now()
	thread.lastSeen = now
	r.gatewayThreadsMu.Lock()
	if existing, ok := r.gatewayThreads[gatewayThreadCacheKey(thread.runtimeID, thread.id)]; ok {
		if existing.readOnly {
			thread.readOnly = true
			thread.directInputKnown = true
			thread.canAcceptDirectInput = false
		} else if !thread.directInputKnown && existing.directInputKnown {
			thread.directInputKnown = true
			thread.canAcceptDirectInput = existing.canAcceptDirectInput
		}
	}
	r.gatewayThreads[gatewayThreadCacheKey(thread.runtimeID, thread.id)] = thread
	r.pruneGatewayThreadsLocked(now)
	r.gatewayThreadsMu.Unlock()
}

func gatewayThreadCacheKey(runtimeID string, threadID string) string {
	return normalizeAppServerRuntimeID(runtimeID) + "\x00" + strings.TrimSpace(threadID)
}

func (r *Router) pruneGatewayThreadsLocked(now time.Time) {
	for id, thread := range r.gatewayThreads {
		if gatewayThreadCacheExpired(thread, now) {
			delete(r.gatewayThreads, id)
		}
	}
	for len(r.gatewayThreads) > appServerGatewayThreadCacheMax {
		oldestID := ""
		oldestSeen := time.Time{}
		for id, thread := range r.gatewayThreads {
			seen := thread.lastSeen
			if seen.IsZero() {
				seen = now.Add(-appServerGatewayThreadCacheTTL - time.Nanosecond)
			}
			if oldestID == "" || seen.Before(oldestSeen) {
				oldestID = id
				oldestSeen = seen
			}
		}
		if oldestID == "" {
			return
		}
		delete(r.gatewayThreads, oldestID)
	}
}

func gatewayThreadCacheExpired(thread appServerGatewayAllowedThread, now time.Time) bool {
	if thread.lastSeen.IsZero() {
		return false
	}
	return now.Sub(thread.lastSeen) > appServerGatewayThreadCacheTTL
}

func gatewayRequestIDKey(id *json.RawMessage) string {
	if id == nil || len(bytes.TrimSpace(*id)) == 0 {
		return ""
	}
	return string(bytes.TrimSpace(*id))
}

func decodeGatewayParams(raw json.RawMessage) (map[string]any, error) {
	if len(bytes.TrimSpace(raw)) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return map[string]any{}, nil
	}
	var params map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	// 官方 app-server 当前使用命名参数；远程 gateway 不支持 positional params，避免校验策略时漏掉 cwd/sandbox 字段。
	if err := decoder.Decode(&params); err != nil {
		return nil, fmt.Errorf("JSON-RPC params 必须是对象")
	}
	return params, nil
}

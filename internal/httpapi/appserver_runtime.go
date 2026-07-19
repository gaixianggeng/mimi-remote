package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

const (
	appServerRuntimeListBatch = 80
	appServerRuntimeScanLimit = 1000
	defaultRuntimeMessagePage = 120
	maxRuntimeTraceEvents     = 256
)

type AppServerRPC interface {
	Call(ctx context.Context, method string, params any, result any) error
}

type CodexAppServerRuntime struct {
	registry *projects.Registry
	client   AppServerRPC

	mu          sync.Mutex
	snapshots   map[string]session.SessionSnapshot
	activeTurns map[string]string
	traces      map[string][]session.TraceEvent
	rateLimit   *session.RateLimitSummary

	eventOnce     sync.Once
	subscriptions map[string]map[chan runtimeStreamEvent]struct{}
	eventSeq      map[string]int64

	pendingApprovals map[string]chan appServerApprovalDecision
}

func NewCodexAppServerRuntime(registry *projects.Registry, client AppServerRPC) *CodexAppServerRuntime {
	return &CodexAppServerRuntime{
		registry:         registry,
		client:           client,
		snapshots:        map[string]session.SessionSnapshot{},
		activeTurns:      map[string]string{},
		traces:           map[string][]session.TraceEvent{},
		subscriptions:    map[string]map[chan runtimeStreamEvent]struct{}{},
		eventSeq:         map[string]int64{},
		pendingApprovals: map[string]chan appServerApprovalDecision{},
	}
}

func (r *CodexAppServerRuntime) SetClient(client AppServerRPC) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.client = client
}

func (r *CodexAppServerRuntime) AppServerDiagnostics() appserver.Diagnostics {
	r.mu.Lock()
	client := r.client
	r.mu.Unlock()
	source, ok := client.(interface{ Diagnostics() appserver.Diagnostics })
	if !ok || source == nil {
		return appserver.Diagnostics{}
	}
	// control-plane 只读取运行态计数；敏感诊断仍留在 doctor/日志的脱敏路径中。
	return source.Diagnostics()
}

func (r *CodexAppServerRuntime) ListSessions(ctx context.Context, projectID string, limit int, cursor sessionPageCursor, hasCursor bool) (SessionListPage, error) {
	project, hasProject, err := r.projectFilter(projectID)
	if err != nil {
		return SessionListPage{}, err
	}
	r.refreshRateLimits(ctx)
	collected := make([]session.SessionSnapshot, 0, appServerPageCapacity(limit))
	rpcCursor := ""
	scanned := 0

	for {
		params := map[string]any{
			"limit":         appServerRuntimeListBatch,
			"sortKey":       "updated_at",
			"sortDirection": "desc",
			"archived":      false,
		}
		if rpcCursor != "" {
			params["cursor"] = rpcCursor
		}
		if hasProject {
			// 移动端只能传 project_id；真正的 cwd 永远由 allowlist 项目解析出来。
			params["cwd"] = project.RealPath
		}

		var response appServerThreadListResponse
		if err := r.call(ctx, "thread/list", params, &response); err != nil {
			return SessionListPage{}, err
		}
		for _, thread := range response.Data {
			scanned++
			snapshot, ok := r.snapshotFromThread(thread, project, hasProject)
			if !ok {
				continue
			}
			r.storeSnapshot(snapshot)
			if hasCursor && !sessionBeforeCursor(snapshot, cursor) {
				continue
			}
			collected = append(collected, snapshot)
			if limit > 0 && len(collected) > limit {
				break
			}
		}
		if limit > 0 && len(collected) > limit {
			break
		}
		if scanned >= appServerRuntimeScanLimit || strings.TrimSpace(response.NextCursor) == "" {
			break
		}
		rpcCursor = response.NextCursor
	}

	page, nextCursor, hasMore := paginateSessions(collected, sessionPageCursor{}, false, limit)
	return SessionListPage{Sessions: page, NextCursor: nextCursor, HasMore: hasMore}, nil
}

func (r *CodexAppServerRuntime) CreateSession(ctx context.Context, req RuntimeCreateRequest) (RuntimeCreateResult, error) {
	var response appServerThreadEnvelope
	method := "thread/start"
	params := safeThreadStartParams(req.Project)
	if strings.TrimSpace(req.ResumeID) != "" {
		method = "thread/resume"
		params = safeThreadResumeParams(req.Project, req.ResumeID)
	}
	if err := r.call(ctx, method, params, &response); err != nil {
		return RuntimeCreateResult{}, err
	}
	if strings.TrimSpace(response.Thread.ID) == "" {
		return RuntimeCreateResult{}, fmt.Errorf("app-server %s 未返回 thread.id", method)
	}
	snapshot, ok := r.snapshotFromThread(response.Thread, req.Project, true)
	if !ok {
		snapshot = snapshotFromProjectThread(req.Project, response.Thread)
	}
	if strings.TrimSpace(req.Title) != "" {
		snapshot.Title = strings.TrimSpace(req.Title)
	}
	snapshot.Status = "running"
	r.storeSnapshot(snapshot)
	r.appendTrace(snapshot.ID, session.TraceEvent{Type: "app_server_thread_ready", Reason: method})

	prompt := strings.TrimSpace(req.Prompt)
	if prompt != "" {
		turnID, err := r.startTurn(ctx, response.Thread.ID, req.Project, prompt, req.ClientMessageID)
		if err != nil {
			r.appendTrace(snapshot.ID, session.TraceEvent{Type: "app_server_turn_failed", Reason: err.Error()})
			return RuntimeCreateResult{}, err
		}
		snapshot.ActiveTurnID = turnID
		snapshot.Status = "running"
		r.setActiveTurn(snapshot.ID, turnID)
		r.appendTrace(snapshot.ID, session.TraceEvent{Type: "app_server_turn_started", Reason: turnID})
	}
	if cached, ok := r.cachedSnapshot(snapshot.ID); ok {
		snapshot = cached
	}

	return RuntimeCreateResult{Snapshot: snapshot}, nil
}

func (r *CodexAppServerRuntime) SessionDetail(ctx context.Context, id string, afterSeq int64) (SessionDetail, error) {
	r.refreshRateLimits(ctx)
	threadID := threadIDFromMobileSessionID(id)
	var response appServerThreadEnvelope
	if err := r.call(ctx, "thread/read", map[string]any{"threadId": threadID, "includeTurns": true}, &response); err != nil {
		return SessionDetail{}, err
	}
	snapshot, ok := r.snapshotFromThread(response.Thread, projects.Project{}, false)
	if !ok {
		if cached, hit := r.cachedSnapshot(id); hit {
			snapshot = cached
		} else {
			return SessionDetail{}, fmt.Errorf("session 不存在")
		}
	}
	r.storeSnapshot(snapshot)
	return SessionDetail{Snapshot: snapshot, LastSeq: snapshot.LastSeq}, nil
}

func (r *CodexAppServerRuntime) StopSession(ctx context.Context, id string) error {
	turnID := r.activeTurn(id)
	if turnID == "" {
		turnID = r.findActiveTurn(ctx, id)
	}
	if turnID == "" {
		r.appendTrace(id, session.TraceEvent{Type: "app_server_turn_interrupt_skipped", Reason: "no_active_turn"})
		return nil
	}
	if err := r.call(ctx, "turn/interrupt", map[string]any{
		"threadId": threadIDFromMobileSessionID(id),
		"turnId":   turnID,
	}, nil); err != nil {
		return err
	}
	r.setActiveTurn(id, "")
	r.appendTrace(id, session.TraceEvent{Type: "app_server_turn_interrupted", Reason: turnID})
	return nil
}

func (r *CodexAppServerRuntime) SessionMessages(ctx context.Context, id string, before string, limit int) (codexhistory.MessagePage, error) {
	var response appServerThreadEnvelope
	if err := r.call(ctx, "thread/read", map[string]any{"threadId": threadIDFromMobileSessionID(id), "includeTurns": true}, &response); err != nil {
		return emptyMessagePage(), nil
	}
	messages := messagesFromAppServerThread(response.Thread)
	return paginateAppServerMessages(messages, before, limit), nil
}

func (r *CodexAppServerRuntime) SessionTrace(ctx context.Context, id string) ([]session.TraceEvent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	trace, ok := r.traces[id]
	if !ok {
		if _, hasSnapshot := r.snapshots[id]; !hasSnapshot {
			return nil, fmt.Errorf("session 不存在")
		}
	}
	return append([]session.TraceEvent(nil), trace...), nil
}

type RuntimeTurnResult struct {
	TurnID  string
	Message *agentMessage
}

func (r *CodexAppServerRuntime) StartTurnForSession(ctx context.Context, id string, prompt string, clientMessageID string) (RuntimeTurnResult, error) {
	prompt = strings.TrimSpace(prompt)
	if prompt == "" {
		return RuntimeTurnResult{}, fmt.Errorf("输入不能为空")
	}
	snapshot, err := r.snapshotForTurn(ctx, id)
	if err != nil {
		return RuntimeTurnResult{}, err
	}
	project, ok := r.registry.Get(snapshot.ProjectID)
	if !ok {
		return RuntimeTurnResult{}, fmt.Errorf("项目不存在：%s", snapshot.ProjectID)
	}
	turnID, err := r.startTurn(ctx, threadIDFromMobileSessionID(id), project, prompt, clientMessageID)
	if err != nil {
		r.appendTrace(id, session.TraceEvent{Type: "app_server_ws_turn_failed", Reason: err.Error()})
		return RuntimeTurnResult{}, err
	}
	r.setActiveTurn(id, turnID)
	r.appendTrace(id, session.TraceEvent{Type: "app_server_ws_turn_started", Reason: turnID})

	result := RuntimeTurnResult{TurnID: turnID}
	if message, ok := userMessageConfirmation(id, strings.TrimSpace(clientMessageID), prompt, time.Now().UTC()); ok {
		result.Message = &message
	}
	return result, nil
}

func (r *CodexAppServerRuntime) Subscribe(ctx context.Context, id string) (<-chan runtimeStreamEvent, func(), error) {
	if _, ok := r.notificationSource(); !ok {
		return nil, nil, fmt.Errorf("codex app-server runtime 不支持通知订阅")
	}
	r.ensureEventPump()
	ch := make(chan runtimeStreamEvent, 128)
	r.mu.Lock()
	if r.subscriptions[id] == nil {
		r.subscriptions[id] = map[chan runtimeStreamEvent]struct{}{}
	}
	r.subscriptions[id][ch] = struct{}{}
	r.mu.Unlock()
	detach := func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		if subscribers := r.subscriptions[id]; subscribers != nil {
			delete(subscribers, ch)
			if len(subscribers) == 0 {
				delete(r.subscriptions, id)
			}
		}
	}
	return ch, detach, nil
}

func (r *CodexAppServerRuntime) snapshotForTurn(ctx context.Context, id string) (session.SessionSnapshot, error) {
	if snapshot, ok := r.cachedSnapshot(id); ok {
		return snapshot, nil
	}
	detail, err := r.SessionDetail(ctx, id, 0)
	if err != nil {
		return session.SessionSnapshot{}, err
	}
	return detail.Snapshot, nil
}

type appServerNotificationSource interface {
	Notifications() <-chan appserver.Notification
}

type runtimeStreamEvent struct {
	Type            string
	Data            string
	SessionID       string
	TurnID          string
	ItemID          string
	MessageID       string
	Status          string
	Message         *agentMessage
	Seq             int64
	Revision        int64
	Diff            map[string]any
	Approval        map[string]any
	Warning         map[string]any
	Row             *session.SessionSnapshot
	Usage           *session.UsageSummary
	RateLimit       *session.RateLimitSummary
	PendingApproval *session.ApprovalSummary
	Context         *session.ContextSnapshot
	Error           string
}

type appServerApprovalDecision struct {
	Decision string
	Message  string
}

func (r *CodexAppServerRuntime) notificationSource() (appServerNotificationSource, bool) {
	source, ok := r.client.(appServerNotificationSource)
	return source, ok
}

func (r *CodexAppServerRuntime) ensureEventPump() {
	r.eventOnce.Do(func() {
		source, ok := r.notificationSource()
		if !ok {
			return
		}
		go r.pumpNotifications(source.Notifications())
	})
}

func (r *CodexAppServerRuntime) pumpNotifications(notifications <-chan appserver.Notification) {
	for notification := range notifications {
		for _, event := range r.eventsFromNotification(notification) {
			r.broadcast(event)
		}
	}
}

func (r *CodexAppServerRuntime) eventsFromNotification(notification appserver.Notification) []runtimeStreamEvent {
	params := map[string]any{}
	if len(notification.Params) > 0 {
		_ = json.Unmarshal(notification.Params, &params)
	}
	if notification.Method == "account/rateLimits/updated" {
		r.setRateLimit(rateLimitSummaryFromPayload(params))
		return nil
	}
	threadID := stringParam(params, "threadId")
	if threadID == "" && notification.Method == "thread/started" {
		if thread := appServerThreadFromParam(params, "thread"); strings.TrimSpace(thread.ID) != "" {
			project, projectOK := r.registry.FindByPath(thread.CWD)
			snapshot := snapshotFromProjectThread(project, thread)
			if !projectOK {
				snapshot.ProjectID = thread.CWD
				snapshot.Project = thread.CWD
				snapshot.Dir = thread.CWD
			}
			snapshot.Status = appServerThreadStatusValueToSessionStatus(thread.Status)
			r.storeSnapshot(snapshot)
			context := snapshot.Context
			event := runtimeStreamEvent{
				Type:      "session_context",
				SessionID: snapshot.ID,
				Context:   cloneContextSnapshot(context),
			}
			event.Seq = r.nextEventSeq(snapshot.ID)
			event.Revision = event.Seq
			r.applyRuntimeEventState(&event)
			return []runtimeStreamEvent{event}
		}
	}
	if threadID == "" {
		return nil
	}
	sessionID := mobileSessionID(threadID)
	item := mapParam(params, "item")
	base := runtimeStreamEvent{
		SessionID: sessionID,
		TurnID:    firstNonEmpty(stringParam(params, "turnId"), nestedStringParam(params, "turn", "id")),
		ItemID:    firstNonEmpty(stringParam(params, "itemId"), stringParam(item, "id")),
	}
	base.MessageID = runtimeMessageID(base.TurnID, base.ItemID)

	switch notification.Method {
	case "turn/started":
		base.Type = "turn_started"
	case "item/agentMessage/delta":
		base.Type = "assistant_delta"
		base.Data = firstNonEmptyRaw(rawStringParam(params, "delta"), rawStringParam(params, "text"))
	case "item/started":
		context := contextSnapshotFromItemParams(sessionID, threadID, params)
		if context == nil {
			return nil
		}
		base.Type = "session_context"
		base.Context = context
	case "item/completed":
		completed, ok := completedAgentMessageEvent(base, item)
		if ok {
			base = completed
		} else if context := contextSnapshotFromItemParams(sessionID, threadID, params); context != nil {
			base.Type = "session_context"
			base.Context = context
		} else {
			return nil
		}
	case "item/commandExecution/outputDelta", "command/exec/outputDelta", "commandExecution/outputDelta", "command/execution/outputDelta", "process/outputDelta":
		base.Type = "log_delta"
		base.Data = firstNonEmptyRaw(
			rawStringParam(params, "delta"),
			rawStringParam(params, "data"),
			rawStringParam(params, "text"),
			rawStringParam(params, "chunk"),
		)
	case "item/fileChange/patchUpdated", "fileChange/patchUpdated", "turn/diff/updated":
		base.Type = "diff_updated"
		base.Diff = diffSummaryFromParams(params)
		base.Context = contextSnapshotFromDiffParams(sessionID, threadID, params)
	case "turn/completed":
		base.Type = "turn_completed"
	case "thread/tokenUsage/updated":
		usage := usageSummaryFromPayload(params)
		if usage == nil {
			return nil
		}
		base.Type = "session_status"
		base.Status = "running"
		base.Usage = usage
	case "thread/status/changed":
		base.Type = "session_status"
		base.Status = appServerStatusParam(params)
		base.Context = contextSnapshotFromStatusParams(sessionID, threadID, params)
	case "warning":
		base.Type = "warning"
		base.Warning = map[string]any{"message": firstNonEmpty(stringParam(params, "message"), "app-server warning")}
	case "error":
		base.Type = "error"
		base.Error = firstNonEmpty(stringParam(params, "message"), stringParam(params, "error"), "app-server error")
	default:
		return nil
	}
	if base.Type == "assistant_delta" && base.Data == "" {
		return nil
	}
	base.Seq = r.nextEventSeq(sessionID)
	base.Revision = base.Seq
	if base.Message != nil && base.Message.Revision == 0 {
		base.Message.Revision = int(base.Revision)
	}
	r.applyRuntimeEventState(&base)
	return []runtimeStreamEvent{base}
}

func completedAgentMessageEvent(base runtimeStreamEvent, item map[string]any) (runtimeStreamEvent, bool) {
	if item == nil || stringParam(item, "type") != "agentMessage" {
		return runtimeStreamEvent{}, false
	}
	text := strings.TrimSpace(firstNonEmpty(stringParam(item, "text"), stringParam(item, "content")))
	if text == "" {
		return runtimeStreamEvent{}, false
	}
	role := "assistant"
	kind := "message"
	if stringParam(item, "phase") == "commentary" {
		role = "system"
		kind = "reasoning_summary"
	}
	base.Type = "message_completed"
	base.ItemID = firstNonEmpty(base.ItemID, stringParam(item, "id"))
	base.MessageID = runtimeMessageID(base.TurnID, base.ItemID)
	// app-server 官方协议说明 item/completed 是权威最终状态；delta 只用于流式预览。
	// 这里用同一个稳定 id 覆盖 iOS 里的 streaming 气泡，避免只显示前半段回复。
	base.Message = &agentMessage{
		ID:         base.MessageID,
		SessionID:  base.SessionID,
		TurnID:     base.TurnID,
		ItemID:     base.ItemID,
		Role:       role,
		Kind:       kind,
		Content:    text,
		CreatedAt:  time.Now().UTC(),
		SendStatus: "confirmed",
	}
	return base, true
}

func (r *CodexAppServerRuntime) nextEventSeq(sessionID string) int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.eventSeq[sessionID]++
	return r.eventSeq[sessionID]
}

func (r *CodexAppServerRuntime) broadcast(event runtimeStreamEvent) {
	r.mu.Lock()
	subscribers := make([]chan runtimeStreamEvent, 0, len(r.subscriptions[event.SessionID]))
	for ch := range r.subscriptions[event.SessionID] {
		subscribers = append(subscribers, ch)
	}
	r.mu.Unlock()
	for _, ch := range subscribers {
		select {
		case ch <- event:
		default:
			r.appendTrace(event.SessionID, session.TraceEvent{Type: "app_server_ws_event_dropped", Reason: event.Type})
		}
	}
}

func (r *CodexAppServerRuntime) HandleServerRequest(ctx context.Context, req appserver.ServerRequest) (any, *appserver.RPCError) {
	params := map[string]any{}
	if len(req.Params) > 0 {
		_ = json.Unmarshal(req.Params, &params)
	}
	if !isMobileApprovalRequest(req.Method) {
		return nil, &appserver.RPCError{Code: -32601, Message: "app-server server request 不在移动端 allowlist: " + req.Method}
	}
	if strings.Contains(strings.ToLower(req.Method), "requestuserinput") {
		return map[string]any{"answers": map[string]any{}}, nil
	}
	event := r.approvalEventFromServerRequest(req.Method, params)
	approvalID := approvalIDFromEvent(event)
	var decisionCh <-chan appServerApprovalDecision
	var unregister func()
	if event.SessionID != "" && approvalID != "" {
		decisionCh, unregister = r.registerPendingApproval(event.SessionID, approvalID)
		defer unregister()
	}
	if event.SessionID != "" {
		event.Seq = r.nextEventSeq(event.SessionID)
		event.Revision = event.Seq
		r.applyRuntimeEventState(&event)
		r.broadcast(event)
		r.appendTrace(event.SessionID, session.TraceEvent{Type: "app_server_approval_requested", Reason: req.Method})
	}
	if decisionCh == nil {
		return appserver.FailClosedServerRequestResult(req, "approval request has no mobile session")
	}
	select {
	case decision := <-decisionCh:
		r.broadcastApprovalResolved(event.SessionID, decision.Decision)
		r.appendTrace(event.SessionID, session.TraceEvent{Type: "app_server_approval_" + decision.Decision, Reason: req.Method})
		return approvalResultForServerRequest(req, decision)
	case <-ctx.Done():
		r.broadcastApprovalResolved(event.SessionID, "timeout")
		r.appendTrace(event.SessionID, session.TraceEvent{Type: "app_server_approval_timeout", Reason: req.Method})
		return appserver.FailClosedServerRequestResult(req, "approval timeout")
	}
}

func (r *CodexAppServerRuntime) approvalEventFromServerRequest(method string, params map[string]any) runtimeStreamEvent {
	threadID := firstNonEmpty(stringParam(params, "threadId"), stringParam(params, "conversationId"))
	sessionID := ""
	if threadID != "" {
		sessionID = mobileSessionID(threadID)
	}
	itemID := firstNonEmpty(stringParam(params, "itemId"), stringParam(params, "callId"), stringParam(params, "approvalId"))
	kind := approvalKind(method)
	title := approvalTitle(kind, params)
	body := approvalBody(kind, params)
	event := runtimeStreamEvent{
		Type:      "approval_request",
		SessionID: sessionID,
		TurnID:    stringParam(params, "turnId"),
		ItemID:    itemID,
		MessageID: itemID,
		Approval: map[string]any{
			"id":    firstNonEmpty(stringParam(params, "approvalId"), itemID, method),
			"title": title,
			"body":  body,
			"kind":  kind,
			"risk":  "high",
		},
	}
	if event.SessionID != "" {
		event.PendingApproval = approvalSummaryFromEvent(event.Approval)
	}
	return event
}

func isMobileApprovalRequest(method string) bool {
	lower := strings.ToLower(method)
	return strings.Contains(lower, "approval") || strings.Contains(lower, "requestuserinput")
}

func approvalIDFromEvent(event runtimeStreamEvent) string {
	if event.Approval == nil {
		return ""
	}
	return stringParam(event.Approval, "id")
}

func (r *CodexAppServerRuntime) registerPendingApproval(sessionID string, approvalID string) (<-chan appServerApprovalDecision, func()) {
	key := pendingApprovalKey(sessionID, approvalID)
	ch := make(chan appServerApprovalDecision, 1)
	r.mu.Lock()
	r.pendingApprovals[key] = ch
	r.mu.Unlock()
	return ch, func() {
		r.mu.Lock()
		if current := r.pendingApprovals[key]; current == ch {
			delete(r.pendingApprovals, key)
		}
		r.mu.Unlock()
	}
}

func (r *CodexAppServerRuntime) ResolveApproval(sessionID string, approvalID string, decision string, message string) error {
	normalized := normalizeMobileApprovalDecision(decision)
	if normalized == "" {
		return fmt.Errorf("未知审批决定：%s", decision)
	}
	key := pendingApprovalKey(sessionID, approvalID)
	r.mu.Lock()
	ch := r.pendingApprovals[key]
	r.mu.Unlock()
	if ch == nil {
		return fmt.Errorf("审批不存在或已过期")
	}
	select {
	case ch <- appServerApprovalDecision{Decision: normalized, Message: strings.TrimSpace(message)}:
		return nil
	default:
		return fmt.Errorf("审批已经处理")
	}
}

func pendingApprovalKey(sessionID string, approvalID string) string {
	return strings.TrimSpace(sessionID) + "\x00" + strings.TrimSpace(approvalID)
}

func normalizeMobileApprovalDecision(decision string) string {
	switch strings.ToLower(strings.TrimSpace(decision)) {
	case "accept", "accepted", "approve", "approved":
		return "accept"
	case "decline", "declined", "deny", "denied", "reject", "rejected":
		return "decline"
	case "cancel", "cancelled", "canceled", "abort":
		return "cancel"
	default:
		return ""
	}
}

func approvalResultForServerRequest(req appserver.ServerRequest, decision appServerApprovalDecision) (any, *appserver.RPCError) {
	lower := strings.ToLower(req.Method)
	switch {
	case strings.Contains(lower, "permissions/requestapproval"):
		// iPad 端不授予额外权限；即使用户点通过，也只解除“等待”状态，不扩大沙箱。
		return map[string]any{
			"permissions":      map[string]any{},
			"scope":            "turn",
			"strictAutoReview": true,
		}, nil
	case strings.Contains(lower, "commandexecution/requestapproval"), strings.Contains(lower, "filechange/requestapproval"):
		return map[string]any{"decision": decision.Decision}, nil
	case strings.Contains(lower, "execcommandapproval"), strings.Contains(lower, "applypatchapproval"):
		legacyDecision := map[string]string{
			"accept":  "approved",
			"decline": "denied",
			"cancel":  "abort",
		}[decision.Decision]
		return map[string]any{"decision": legacyDecision}, nil
	default:
		return appserver.FailClosedServerRequestResult(req, "unsupported approval method")
	}
}

func (r *CodexAppServerRuntime) broadcastApprovalResolved(sessionID string, decision string) {
	if strings.TrimSpace(sessionID) == "" {
		return
	}
	event := runtimeStreamEvent{
		Type:      "session_status",
		SessionID: sessionID,
		Status:    "running",
	}
	event.Seq = r.nextEventSeq(sessionID)
	event.Revision = event.Seq
	r.applyRuntimeEventState(&event)
	r.broadcast(event)
}

func approvalKind(method string) string {
	lower := strings.ToLower(method)
	switch {
	case strings.Contains(lower, "file"):
		return "file_change"
	case strings.Contains(lower, "permission"):
		return "permission"
	case strings.Contains(lower, "requestuserinput"):
		return "user_input"
	default:
		return "command"
	}
}

func approvalTitle(kind string, params map[string]any) string {
	switch kind {
	case "file_change":
		return "Codex 请求文件变更审批"
	case "permission":
		return "Codex 请求权限扩展"
	case "user_input":
		return "Codex 请求补充输入"
	default:
		command := commandSummary(params)
		if command != "" {
			return "Codex 请求执行命令：" + command
		}
		return "Codex 请求命令审批"
	}
}

func approvalBody(kind string, params map[string]any) string {
	reason := stringParam(params, "reason")
	if kind == "command" {
		command := commandSummary(params)
		if reason != "" && command != "" {
			return command + "\n\n" + reason
		}
		return firstNonEmpty(command, reason)
	}
	return reason
}

func commandSummary(params map[string]any) string {
	if command := stringParam(params, "command"); command != "" {
		return command
	}
	if raw, ok := params["command"].([]any); ok {
		parts := make([]string, 0, len(raw))
		for _, part := range raw {
			parts = append(parts, fmt.Sprint(part))
		}
		return strings.Join(parts, " ")
	}
	return ""
}

func (r *CodexAppServerRuntime) call(ctx context.Context, method string, params any, result any) error {
	if r.client == nil {
		return fmt.Errorf("codex app-server client 未初始化")
	}
	if !appServerRuntimeMethodAllowed(method) {
		return fmt.Errorf("app-server method 不在移动端 allowlist：%s", method)
	}
	return r.client.Call(ctx, method, params, result)
}

func appServerRuntimeMethodAllowed(method string) bool {
	switch method {
	case "thread/list", "thread/start", "thread/resume", "thread/read", "turn/start", "turn/interrupt", "account/rateLimits/read":
		return true
	default:
		return false
	}
}

func (r *CodexAppServerRuntime) projectFilter(projectID string) (projects.Project, bool, error) {
	projectID = strings.TrimSpace(projectID)
	if projectID == "" {
		return projects.Project{}, false, nil
	}
	project, ok := r.registry.Get(projectID)
	if !ok {
		return projects.Project{}, false, fmt.Errorf("项目不存在")
	}
	return project, true, nil
}

func (r *CodexAppServerRuntime) snapshotFromThread(thread appServerThread, preferred projects.Project, hasPreferred bool) (session.SessionSnapshot, bool) {
	project := preferred
	ok := hasPreferred
	if !ok {
		project, ok = r.registry.FindByPath(thread.CWD)
	}
	if !ok {
		return session.SessionSnapshot{}, false
	}
	snapshot := snapshotFromProjectThread(project, thread)
	r.applyCachedSnapshotState(&snapshot)
	return snapshot, true
}

func snapshotFromProjectThread(project projects.Project, thread appServerThread) session.SessionSnapshot {
	createdAt := unixTime(thread.CreatedAt)
	updatedAt := unixTime(thread.UpdatedAt)
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}
	if updatedAt.IsZero() {
		updatedAt = createdAt
	}
	title := strings.TrimSpace(thread.Name)
	if title == "" {
		title = strings.TrimSpace(thread.Preview)
	}
	if title == "" {
		title = "Codex app-server 会话"
	}
	snapshot := session.SessionSnapshot{
		ID:              mobileSessionID(thread.ID),
		ProjectID:       project.ID,
		Project:         project.Name,
		Dir:             project.Path,
		Title:           trimRuntimeRunes(title, 48),
		Status:          appServerThreadStatusValueToSessionStatus(thread.Status),
		Source:          "codex",
		ResumeID:        thread.ID,
		HistoryThreadID: thread.ID,
		CreatedAt:       createdAt,
		UpdatedAt:       updatedAt,
		Preview:         trimRuntimeRunes(thread.Preview, 160),
	}
	snapshot.Context = contextSnapshotFromThread(project, thread, snapshot.ID)
	return snapshot
}

const maxContextTasks = 8

func contextSnapshotFromThread(project projects.Project, thread appServerThread, sessionID string) *session.ContextSnapshot {
	threadID := firstNonEmpty(thread.ID, thread.SessionID, threadIDFromMobileSessionID(sessionID))
	context := &session.ContextSnapshot{
		SessionID: sessionID,
		ThreadID:  threadID,
		Status: &session.ContextStatus{
			Type:        firstNonEmpty(thread.Status.Type, "notLoaded"),
			ActiveFlags: append([]string(nil), thread.Status.ActiveFlags...),
		},
		Environment: &session.ContextEnvironment{
			ID:       "local",
			Kind:     "local",
			Label:    "本地",
			CWD:      firstNonEmpty(thread.CWD, project.Path),
			Provider: firstNonEmpty(thread.ModelProvider, "openai"),
		},
		Tasks:     contextTasksFromThread(thread),
		Sources:   contextSourcesFromThread(thread),
		Subagents: contextSubagentsFromThread(thread),
		UpdatedAt: time.Now().UTC(),
	}
	if thread.GitInfo != nil {
		context.Git = &session.ContextGitInfo{
			SHA:       strings.TrimSpace(thread.GitInfo.SHA),
			Branch:    strings.TrimSpace(thread.GitInfo.Branch),
			OriginURL: strings.TrimSpace(thread.GitInfo.OriginURL),
		}
		if context.Git.SHA == "" && context.Git.Branch == "" && context.Git.OriginURL == "" {
			context.Git = nil
		}
	}
	return context
}

func contextSourcesFromThread(thread appServerThread) []session.ContextSource {
	sources := make([]session.ContextSource, 0, 3)
	if label := appServerSourceLabel(thread.Source); label != "" {
		sources = append(sources, session.ContextSource{
			ID:       "session_source",
			Kind:     "session",
			Label:    label,
			Subtitle: "session source",
		})
	}
	if strings.TrimSpace(thread.ThreadSource) != "" {
		sources = append(sources, session.ContextSource{
			ID:       "thread_source",
			Kind:     "thread",
			Label:    strings.TrimSpace(thread.ThreadSource),
			Subtitle: "thread source",
		})
	}
	if strings.TrimSpace(thread.ForkedFromID) != "" {
		sources = append(sources, session.ContextSource{
			ID:       "forked_from",
			Kind:     "fork",
			Label:    trimRuntimeRunes(thread.ForkedFromID, 32),
			Subtitle: "forked from",
		})
	}
	return sources
}

func contextSubagentsFromThread(thread appServerThread) []session.ContextSubagent {
	parentThreadID := strings.TrimSpace(thread.ParentThreadID)
	if parentThreadID == "" {
		return nil
	}
	return []session.ContextSubagent{{
		ID:             firstNonEmpty(thread.ID, thread.SessionID),
		ParentThreadID: parentThreadID,
		Nickname:       strings.TrimSpace(thread.AgentNickname),
		Role:           strings.TrimSpace(thread.AgentRole),
		Status:         appServerThreadStatusValueToSessionStatus(thread.Status),
	}}
}

func contextTasksFromThread(thread appServerThread) []session.ContextTask {
	if len(thread.Turns) == 0 {
		return nil
	}
	tasks := make([]session.ContextTask, 0, maxContextTasks)
	for turnIndex := len(thread.Turns) - 1; turnIndex >= 0 && len(tasks) < maxContextTasks; turnIndex-- {
		items := thread.Turns[turnIndex].Items
		for itemIndex := len(items) - 1; itemIndex >= 0 && len(tasks) < maxContextTasks; itemIndex-- {
			if task, ok := contextTaskFromItem(thread.Turns[turnIndex], items[itemIndex]); ok {
				tasks = append(tasks, task)
			}
		}
	}
	return tasks
}

func contextTaskFromItem(turn appServerTurn, item appServerThreadItem) (session.ContextTask, bool) {
	id := firstNonEmpty(item.ID, turn.ID)
	switch item.Type {
	case "commandExecution":
		title := firstNonEmpty(item.Command, item.ProcessID, "命令执行")
		return session.ContextTask{
			ID:       id,
			Kind:     "command",
			Title:    trimRuntimeRunes(title, 80),
			Subtitle: trimRuntimeRunes(firstNonEmpty(item.CWD, commandActionSummary(item.CommandActions)), 96),
			Status:   firstNonEmpty(item.Status, turn.Status),
		}, true
	case "fileChange":
		title := "文件变更"
		if len(item.Changes) > 0 {
			title = fmt.Sprintf("文件变更 x%d", len(item.Changes))
		}
		return session.ContextTask{
			ID:       id,
			Kind:     "file_change",
			Title:    title,
			Subtitle: trimRuntimeRunes(fileChangeSummary(item.Changes), 96),
			Status:   firstNonEmpty(item.Status, turn.Status),
		}, true
	case "mcpToolCall":
		return session.ContextTask{
			ID:       id,
			Kind:     "mcp_tool",
			Title:    trimRuntimeRunes(firstNonEmpty(item.Server+"."+item.Tool, item.Tool, "MCP 工具"), 80),
			Subtitle: trimRuntimeRunes(firstNonEmpty(item.PluginID, "MCP"), 96),
			Status:   firstNonEmpty(item.Status, turn.Status),
		}, true
	case "dynamicToolCall":
		title := firstNonEmpty(item.Tool, "动态工具")
		if strings.TrimSpace(item.Namespace) != "" {
			title = item.Namespace + "." + title
		}
		return session.ContextTask{
			ID:       id,
			Kind:     "dynamic_tool",
			Title:    trimRuntimeRunes(title, 80),
			Subtitle: "dynamic tool",
			Status:   firstNonEmpty(item.Status, turn.Status),
		}, true
	case "collabAgentToolCall":
		return session.ContextTask{
			ID:       id,
			Kind:     "subagent",
			Title:    trimRuntimeRunes(firstNonEmpty(item.Tool, "子 agent"), 80),
			Subtitle: "collab agent",
			Status:   firstNonEmpty(item.Status, turn.Status),
		}, true
	default:
		return session.ContextTask{}, false
	}
}

func commandActionSummary(actions []appServerCommandAction) string {
	for _, action := range actions {
		if action.Name != "" || action.Path != "" {
			return strings.TrimSpace(action.Name + " " + action.Path)
		}
		if action.Query != "" {
			return action.Query
		}
	}
	return ""
}

func fileChangeSummary(changes []appServerFileChange) string {
	if len(changes) == 0 {
		return ""
	}
	parts := make([]string, 0, min(len(changes), 3))
	for _, change := range changes {
		if len(parts) >= 3 {
			break
		}
		parts = append(parts, strings.TrimSpace(firstNonEmpty(change.Path, change.Kind)))
	}
	if len(changes) > len(parts) {
		parts = append(parts, fmt.Sprintf("+%d", len(changes)-len(parts)))
	}
	return strings.Join(parts, ", ")
}

func appServerSourceLabel(source any) string {
	switch typed := source.(type) {
	case string:
		return strings.TrimSpace(typed)
	case map[string]any:
		if custom, ok := typed["custom"]; ok {
			return trimRuntimeRunes(fmt.Sprint(custom), 48)
		}
		if sub, ok := typed["subAgent"]; ok {
			return "subAgent " + trimRuntimeRunes(fmt.Sprint(sub), 48)
		}
	}
	return ""
}

func appServerThreadFromParam(params map[string]any, key string) appServerThread {
	raw, ok := params[key]
	if !ok || raw == nil {
		return appServerThread{}
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return appServerThread{}
	}
	var thread appServerThread
	if err := json.Unmarshal(data, &thread); err != nil {
		return appServerThread{}
	}
	return thread
}

func contextSnapshotFromStatusParams(sessionID string, threadID string, params map[string]any) *session.ContextSnapshot {
	status := appServerThreadStatusFromParam(params["status"])
	if status.Type == "" && len(status.ActiveFlags) == 0 {
		return nil
	}
	return &session.ContextSnapshot{
		SessionID: sessionID,
		ThreadID:  threadID,
		Status: &session.ContextStatus{
			Type:        status.Type,
			ActiveFlags: append([]string(nil), status.ActiveFlags...),
		},
		UpdatedAt: time.Now().UTC(),
	}
}

func appServerThreadStatusFromParam(raw any) appServerThreadStatus {
	switch typed := raw.(type) {
	case string:
		return appServerThreadStatus{Type: strings.TrimSpace(typed)}
	case map[string]any:
		return appServerThreadStatus{
			Type:        stringParam(typed, "type"),
			ActiveFlags: stringSliceParam(typed, "activeFlags"),
		}
	default:
		return appServerThreadStatus{}
	}
}

func contextSnapshotFromDiffParams(sessionID string, threadID string, params map[string]any) *session.ContextSnapshot {
	diff := diffSummaryFromParams(params)
	path := strings.TrimSpace(fmt.Sprint(diff["path"]))
	status := strings.TrimSpace(fmt.Sprint(diff["status"]))
	if path == "" && status == "" {
		return nil
	}
	return &session.ContextSnapshot{
		SessionID: sessionID,
		ThreadID:  threadID,
		Tasks: []session.ContextTask{{
			ID:       firstNonEmpty(stringParam(params, "itemId"), stringParam(params, "id"), path),
			Kind:     "file_change",
			Title:    "文件变更",
			Subtitle: trimRuntimeRunes(path, 96),
			Status:   status,
		}},
		UpdatedAt: time.Now().UTC(),
	}
}

func contextSnapshotFromItemParams(sessionID string, threadID string, params map[string]any) *session.ContextSnapshot {
	item := mapParam(params, "item")
	if item == nil {
		return nil
	}
	data, err := json.Marshal(item)
	if err != nil {
		return nil
	}
	var threadItem appServerThreadItem
	if err := json.Unmarshal(data, &threadItem); err != nil {
		return nil
	}
	turn := appServerTurn{
		ID:     firstNonEmpty(stringParam(params, "turnId"), nestedStringParam(params, "turn", "id")),
		Status: stringParam(params, "status"),
	}
	task, ok := contextTaskFromItem(turn, threadItem)
	if !ok {
		return nil
	}
	return &session.ContextSnapshot{
		SessionID: sessionID,
		ThreadID:  threadID,
		Tasks:     []session.ContextTask{task},
		UpdatedAt: time.Now().UTC(),
	}
}

func appServerThreadStatusToSessionStatus(status string) string {
	switch strings.TrimSpace(status) {
	case "active", "idle":
		return "running"
	case "systemError":
		return "failed"
	default:
		return "history"
	}
}

func appServerThreadStatusValueToSessionStatus(status appServerThreadStatus) string {
	if containsString(status.ActiveFlags, "waitingOnApproval") {
		return "waiting_for_approval"
	}
	if containsString(status.ActiveFlags, "waitingOnUserInput") {
		return "waiting_for_input"
	}
	return appServerThreadStatusToSessionStatus(status.Type)
}

func safeThreadStartParams(project projects.Project) map[string]any {
	return map[string]any{
		"cwd":               project.RealPath,
		"approvalPolicy":    "on-request",
		"approvalsReviewer": "user",
		"sandbox":           "danger-full-access",
		"ephemeral":         false,
	}
}

func safeThreadResumeParams(project projects.Project, threadID string) map[string]any {
	params := safeThreadStartParams(project)
	params["threadId"] = threadID
	params["excludeTurns"] = true
	delete(params, "ephemeral")
	return params
}

func safeTurnStartParams(threadID string, project projects.Project, prompt string, clientMessageID string) map[string]any {
	params := map[string]any{
		"threadId": threadID,
		"cwd":      project.RealPath,
		"input": []map[string]any{{
			"type":          "text",
			"text":          prompt,
			"text_elements": []any{},
		}},
		"approvalPolicy":    "on-request",
		"approvalsReviewer": "user",
		"effort":            defaultCodexReasoningEffort,
		"sandboxPolicy": map[string]any{
			"type":          "dangerFullAccess",
			"networkAccess": false,
		},
	}
	if strings.TrimSpace(clientMessageID) != "" {
		params["clientUserMessageId"] = strings.TrimSpace(clientMessageID)
	}
	return params
}

func (r *CodexAppServerRuntime) startTurn(ctx context.Context, threadID string, project projects.Project, prompt string, clientMessageID string) (string, error) {
	var response appServerTurnEnvelope
	if err := r.call(ctx, "turn/start", safeTurnStartParams(threadID, project, prompt, clientMessageID), &response); err != nil {
		return "", err
	}
	return strings.TrimSpace(response.Turn.ID), nil
}

func (r *CodexAppServerRuntime) findActiveTurn(ctx context.Context, id string) string {
	var response appServerThreadEnvelope
	if err := r.call(ctx, "thread/read", map[string]any{"threadId": threadIDFromMobileSessionID(id), "includeTurns": true}, &response); err != nil {
		return ""
	}
	for i := len(response.Thread.Turns) - 1; i >= 0; i-- {
		if response.Thread.Turns[i].Status == "inProgress" {
			return response.Thread.Turns[i].ID
		}
	}
	return ""
}

func (r *CodexAppServerRuntime) storeSnapshot(snapshot session.SessionSnapshot) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.mergeSnapshotStateLocked(&snapshot)
	r.snapshots[snapshot.ID] = snapshot
	r.attachSnapshotAsSubagentLocked(snapshot)
}

func (r *CodexAppServerRuntime) cachedSnapshot(id string) (session.SessionSnapshot, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	snapshot, ok := r.snapshots[id]
	return snapshot, ok
}

func (r *CodexAppServerRuntime) setActiveTurn(id string, turnID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if strings.TrimSpace(turnID) == "" {
		delete(r.activeTurns, id)
		if snapshot, ok := r.snapshots[id]; ok {
			snapshot.ActiveTurnID = ""
			r.snapshots[id] = snapshot
		}
		return
	}
	r.activeTurns[id] = turnID
	if snapshot, ok := r.snapshots[id]; ok {
		snapshot.ActiveTurnID = turnID
		snapshot.Status = "running"
		snapshot.UpdatedAt = time.Now().UTC()
		r.snapshots[id] = snapshot
	}
}

func (r *CodexAppServerRuntime) activeTurn(id string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.activeTurns[id]
}

func (r *CodexAppServerRuntime) refreshRateLimits(ctx context.Context) {
	var response map[string]any
	if err := r.call(ctx, "account/rateLimits/read", nil, &response); err != nil {
		// rate-limit 是展示增强信号，不应让实验协议波动影响核心会话 API。
		return
	}
	r.setRateLimit(rateLimitSummaryFromPayload(response))
}

func (r *CodexAppServerRuntime) setRateLimit(rateLimit *session.RateLimitSummary) {
	if rateLimit == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.rateLimit = cloneRateLimitSummary(rateLimit)
	for id, snapshot := range r.snapshots {
		snapshot.RateLimit = cloneRateLimitSummary(rateLimit)
		r.snapshots[id] = snapshot
	}
}

func (r *CodexAppServerRuntime) applyCachedSnapshotState(snapshot *session.SessionSnapshot) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.mergeSnapshotStateLocked(snapshot)
}

func (r *CodexAppServerRuntime) mergeSnapshotStateLocked(snapshot *session.SessionSnapshot) {
	if snapshot == nil || strings.TrimSpace(snapshot.ID) == "" {
		return
	}
	if cached, ok := r.snapshots[snapshot.ID]; ok {
		if cached.Status == "running" || cached.Status == "waiting_for_approval" {
			snapshot.Status = cached.Status
		}
		if cached.Preview != "" && snapshot.Preview == "" {
			snapshot.Preview = cached.Preview
		}
		if cached.ActiveTurnID != "" {
			snapshot.ActiveTurnID = cached.ActiveTurnID
		}
		if cached.LastSeq > snapshot.LastSeq {
			snapshot.LastSeq = cached.LastSeq
		}
		if cached.Revision > snapshot.Revision {
			snapshot.Revision = cached.Revision
		}
		if cached.Usage != nil {
			snapshot.Usage = cloneUsageSummary(cached.Usage)
		}
		if cached.PendingApproval != nil {
			snapshot.PendingApproval = cloneApprovalSummary(cached.PendingApproval)
		}
		if cached.RateLimit != nil {
			snapshot.RateLimit = cloneRateLimitSummary(cached.RateLimit)
		}
		snapshot.Context = mergeContextSnapshots(cached.Context, snapshot.Context)
	}
	if r.rateLimit != nil && snapshot.RateLimit == nil {
		snapshot.RateLimit = cloneRateLimitSummary(r.rateLimit)
	}
}

func (r *CodexAppServerRuntime) attachSnapshotAsSubagentLocked(snapshot session.SessionSnapshot) {
	if snapshot.Context == nil || len(snapshot.Context.Subagents) == 0 {
		return
	}
	for _, subagent := range snapshot.Context.Subagents {
		parentThreadID := strings.TrimSpace(subagent.ParentThreadID)
		if parentThreadID == "" {
			continue
		}
		parentSessionID := mobileSessionID(parentThreadID)
		parent := r.snapshots[parentSessionID]
		if parent.ID == "" {
			parent.ID = parentSessionID
			parent.ResumeID = parentThreadID
			parent.HistoryThreadID = parentThreadID
			parent.Source = "codex"
			parent.Status = "running"
			parent.Title = "Codex app-server 会话"
			now := time.Now().UTC()
			parent.CreatedAt = now
			parent.UpdatedAt = now
		}
		parent.Context = mergeContextSnapshots(parent.Context, &session.ContextSnapshot{
			SessionID: parentSessionID,
			ThreadID:  parentThreadID,
			Subagents: []session.ContextSubagent{{
				ID:             firstNonEmpty(subagent.ID, snapshot.ID),
				ParentThreadID: parentThreadID,
				Nickname:       firstNonEmpty(subagent.Nickname, snapshot.Context.ThreadID, snapshot.ID),
				Role:           subagent.Role,
				Status:         firstNonEmpty(subagent.Status, snapshot.Status),
			}},
			UpdatedAt: time.Now().UTC(),
		})
		r.snapshots[parentSessionID] = parent
	}
}

func (r *CodexAppServerRuntime) applyRuntimeEventState(event *runtimeStreamEvent) {
	if event == nil || strings.TrimSpace(event.SessionID) == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	snapshot := r.snapshots[event.SessionID]
	if snapshot.ID == "" {
		snapshot.ID = event.SessionID
		snapshot.ResumeID = threadIDFromMobileSessionID(event.SessionID)
		snapshot.HistoryThreadID = snapshot.ResumeID
		snapshot.Source = "codex"
		snapshot.Title = "Codex app-server 会话"
		snapshot.Status = "running"
		now := time.Now().UTC()
		snapshot.CreatedAt = now
		snapshot.UpdatedAt = now
	}
	if event.Status != "" {
		snapshot.Status = event.Status
	}
	switch event.Type {
	case "turn_started":
		snapshot.ActiveTurnID = event.TurnID
		snapshot.Status = "running"
		snapshot.PendingApproval = nil
	case "turn_completed":
		snapshot.ActiveTurnID = ""
		snapshot.PendingApproval = nil
	case "approval_request":
		snapshot.Status = "waiting_for_approval"
		if event.PendingApproval != nil {
			snapshot.PendingApproval = cloneApprovalSummary(event.PendingApproval)
		}
	case "session_status":
		if event.Status != "waiting_for_approval" {
			snapshot.PendingApproval = nil
		}
	}
	if event.Usage != nil {
		snapshot.Usage = cloneUsageSummary(event.Usage)
	}
	if event.RateLimit != nil {
		snapshot.RateLimit = cloneRateLimitSummary(event.RateLimit)
	} else if r.rateLimit != nil && snapshot.RateLimit == nil {
		snapshot.RateLimit = cloneRateLimitSummary(r.rateLimit)
	}
	if event.Context != nil {
		snapshot.Context = mergeContextSnapshots(snapshot.Context, event.Context)
	}
	if snapshot.Context != nil {
		snapshot.Context.SessionID = snapshot.ID
		snapshot.Context.ThreadID = firstNonEmpty(snapshot.Context.ThreadID, snapshot.HistoryThreadID, snapshot.ResumeID, threadIDFromMobileSessionID(snapshot.ID))
		if event.Status != "" {
			if snapshot.Context.Status == nil {
				snapshot.Context.Status = &session.ContextStatus{}
			}
			snapshot.Context.Status.Type = statusTypeFromSessionStatus(event.Status)
		}
		snapshot.Context.UpdatedAt = time.Now().UTC()
	}
	if event.Seq > 0 {
		snapshot.LastSeq = event.Seq
	}
	if event.Revision > 0 {
		snapshot.Revision = event.Revision
	}
	snapshot.UpdatedAt = time.Now().UTC()
	r.snapshots[event.SessionID] = snapshot
	r.attachSnapshotAsSubagentLocked(snapshot)
	row := snapshot
	event.Row = &row
	event.Context = cloneContextSnapshot(snapshot.Context)
}

func (r *CodexAppServerRuntime) appendTrace(id string, event session.TraceEvent) {
	event.Time = time.Now().UTC()
	r.mu.Lock()
	defer r.mu.Unlock()
	trace := append(r.traces[id], event)
	if len(trace) > maxRuntimeTraceEvents {
		trace = trace[len(trace)-maxRuntimeTraceEvents:]
	}
	r.traces[id] = trace
}

func mobileSessionID(threadID string) string {
	threadID = strings.TrimSpace(threadID)
	if strings.HasPrefix(threadID, "codex_") {
		return threadID
	}
	return "codex_" + threadID
}

func threadIDFromMobileSessionID(id string) string {
	id = strings.TrimSpace(id)
	if strings.HasPrefix(id, "codex_") {
		return strings.TrimPrefix(id, "codex_")
	}
	return id
}

func appServerPageCapacity(limit int) int {
	if limit <= 0 {
		return 128
	}
	return limit + 1
}

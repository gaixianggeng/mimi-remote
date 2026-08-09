package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	appServerThreadHandoffPath            = "/api/app-server/thread-handoff"
	appServerThreadHandoffLifecycleMethod = "_mimi/threadHandoff/lifecycle"
	appServerThreadHandoffPollInterval    = 2 * time.Second
	appServerThreadHandoffRPCTimeout      = 6 * time.Second
	appServerThreadHandoffRetryDelay      = 2 * time.Second
	appServerThreadHandoffCloseTimeout    = 8 * time.Second
	// 必须早于 iOS 单次 JSON-RPC 的 60 秒 deadline 返回“明确未转发”。否则客户端
	// 已超时后旧 frame 仍可能迟到执行，与用户手动重试形成重复 turn。
	appServerThreadHandoffReclaimWaitTimeout = 4 * time.Second
	appServerThreadHandoffRetryAfter         = 250 * time.Millisecond
	appServerThreadHandoffLifecycleMax       = appServerGatewayWriteWindow + 2*time.Second
	// unarchive 广播可能先于其他连接上排队的 closed/notLoaded 到达；短暂保留来源
	// 标记，避免迟到通知被误投影为用户主动结束。窗口结束后普通 closed 恢复原语义。
	appServerThreadHandoffLifecycleGrace = 2 * time.Second
	// completion 后留出一个很短的续问窗口。本地 FIFO 会在这段时间内发出
	// turn/start 并取消 handoff；无后续输入时仍能在 10 秒验收窗口内释放 writer。
	appServerTerminalHandoffGrace = 2 * time.Second
)

var errAppServerThreadHandoffExecuting = errors.New("thread handoff is executing")

type appServerThreadHandoffRequest struct {
	ThreadID string `json:"thread_id"`
}

type appServerThreadHandoffResponse struct {
	ThreadID string `json:"thread_id"`
	Status   string `json:"status"`
}

type appServerThreadHandoffOutcome string

const (
	appServerThreadHandoffReleased        appServerThreadHandoffOutcome = "released"
	appServerThreadHandoffAlreadyReleased appServerThreadHandoffOutcome = "already_released"
)

type appServerThreadHandoffRunFunc func(
	ctx context.Context,
	threadID string,
	markExecuting func() bool,
) (appServerThreadHandoffOutcome, error)

type appServerThreadHandoffEntry struct {
	cancel       context.CancelFunc
	executing    bool
	everExecuted bool
	done         chan struct{}
	stateChanged chan struct{}
}

// appServerThreadHandoffCoordinator 只在内存里保留“等待空闲”的调度队列；
// 一旦准备 archive，恢复责任会先写入 durable journal，由重启恢复接管。
type appServerThreadHandoffCoordinator struct {
	mu      sync.Mutex
	closed  bool
	entries map[string]*appServerThreadHandoffEntry
	run     appServerThreadHandoffRunFunc
	// gateway 可能在单帧写回客户端时阻塞到 write deadline。entry 完成后保留
	// 有界 tombstone，让该连接随后才读到的第一条 closed 仍能识别来源。
	lifecycleUntil map[string]time.Time
	// requiresRecovery 只在 durable journal 仍有记录时返回 true。此状态不可被
	// 新 turn 取消；调用方必须等 unarchive 与日志清理都完成后才能继续写入。
	requiresRecovery func(string) bool
	wg               sync.WaitGroup
}

func newAppServerThreadHandoffCoordinator(router *Router) *appServerThreadHandoffCoordinator {
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		requiresRecovery: func(threadID string) bool {
			return router.threadHandoffRecovery != nil &&
				router.threadHandoffRecovery.RequiresUnarchive(threadID)
		},
	}
	coordinator.run = func(ctx context.Context, threadID string, markExecuting func() bool) (appServerThreadHandoffOutcome, error) {
		return router.runCodexThreadHandoff(ctx, threadID, markExecuting, appServerThreadHandoffPollInterval)
	}
	return coordinator
}

func (c *appServerThreadHandoffCoordinator) Schedule(threadID string) bool {
	return c.ScheduleAfter(threadID, 0)
}

func (c *appServerThreadHandoffCoordinator) ScheduleAfter(threadID string, delay time.Duration) bool {
	if c == nil {
		return false
	}
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return false
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return false
	}
	if _, exists := c.entries[threadID]; exists {
		c.mu.Unlock()
		return true
	}
	ctx, cancel := context.WithCancel(context.Background())
	recovering := c.recoveryRequired(threadID)
	entry := &appServerThreadHandoffEntry{
		cancel:       cancel,
		executing:    recovering,
		everExecuted: recovering,
		done:         make(chan struct{}),
		stateChanged: make(chan struct{}, 1),
	}
	c.entries[threadID] = entry
	c.wg.Add(1)
	c.mu.Unlock()

	go c.runEntry(ctx, threadID, entry, delay)
	return true
}

func (c *appServerThreadHandoffCoordinator) runEntry(
	ctx context.Context,
	threadID string,
	entry *appServerThreadHandoffEntry,
	delay time.Duration,
) {
	defer c.wg.Done()
	defer c.removeEntry(threadID, entry)
	if !waitThreadHandoff(ctx, delay) {
		return
	}

	for {
		outcome, err := c.run(ctx, threadID, func() bool {
			return c.markExecuting(threadID, entry)
		})
		if err == nil {
			log.Printf("app-server thread handoff completed thread_id=%s status=%s", threadID, outcome)
			return
		}
		if ctx.Err() != nil {
			return
		}
		if c.recoveryRequired(threadID) {
			// archive 可能已经发生；durable marker 清掉以前始终保持不可取消，
			// 避免续问穿过失败恢复窗口后命中仍处于 archived 的 thread。
			c.markExecuting(threadID, entry)
		} else {
			c.markPending(threadID, entry)
		}
		log.Printf("app-server thread handoff retry thread_id=%s err=%v", threadID, err)
		if !waitThreadHandoff(ctx, appServerThreadHandoffRetryDelay) {
			return
		}
	}
}

func (c *appServerThreadHandoffCoordinator) markExecuting(threadID string, entry *appServerThreadHandoffEntry) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.entries[threadID] != entry {
		return false
	}
	entry.executing = true
	entry.everExecuted = true
	return true
}

func (c *appServerThreadHandoffCoordinator) markPending(threadID string, entry *appServerThreadHandoffEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries[threadID] == entry {
		entry.executing = false
		// 已经在等待 executing 的续问需要立刻重新检查，并取消后续 retry。
		// channel 带一个缓冲即可：首个 waiter 会移除 entry，其余 waiter 随 done 唤醒。
		select {
		case entry.stateChanged <- struct{}{}:
		default:
		}
	}
}

func (c *appServerThreadHandoffCoordinator) removeEntry(threadID string, entry *appServerThreadHandoffEntry) {
	c.mu.Lock()
	if c.entries[threadID] == entry {
		delete(c.entries, threadID)
		if entry.everExecuted {
			if c.lifecycleUntil == nil {
				c.lifecycleUntil = map[string]time.Time{}
			}
			now := time.Now()
			for existingThreadID, expiresAt := range c.lifecycleUntil {
				if !now.Before(expiresAt) {
					delete(c.lifecycleUntil, existingThreadID)
				}
			}
			c.lifecycleUntil[threadID] = now.Add(appServerThreadHandoffLifecycleMax)
		}
	}
	c.mu.Unlock()
	entry.cancel()
	close(entry.done)
}

func (c *appServerThreadHandoffCoordinator) recoveryRequired(threadID string) bool {
	return c != nil && c.requiresRecovery != nil && c.requiresRecovery(threadID)
}

// OwnsLifecycle 只在 coordinator 已经进入不可取消的 archive/unarchive 窗口时返回 true。
// gateway 用它区分“handoff 造成的 closed”与用户真正结束 thread 的 closed。
func (c *appServerThreadHandoffCoordinator) OwnsLifecycle(threadID string) bool {
	if c == nil {
		return false
	}
	threadID = strings.TrimSpace(threadID)
	now := time.Now()
	c.mu.Lock()
	entry := c.entries[threadID]
	ownedByEntry := entry != nil && entry.everExecuted
	tombstoneUntil, ownedByTombstone := c.lifecycleUntil[threadID]
	if ownedByTombstone && !now.Before(tombstoneUntil) {
		delete(c.lifecycleUntil, threadID)
		ownedByTombstone = false
	}
	c.mu.Unlock()
	return ownedByEntry || ownedByTombstone || c.recoveryRequired(threadID)
}

// Reclaim 表示移动端重新使用该 thread。尚在等待空闲时直接取消交接；已经进入
// archive/unarchive 的窗口则等待恢复完成，但拒绝原 frame，要求客户端重新 resume。
// 这是因为执行窗口内会产生 thread/closed/notLoaded，原 observation 已经失效。
func (c *appServerThreadHandoffCoordinator) Reclaim(threadID string) error {
	return c.ReclaimContext(context.Background(), threadID)
}

func (c *appServerThreadHandoffCoordinator) ReclaimContext(ctx context.Context, threadID string) error {
	if c == nil {
		return nil
	}
	threadID = strings.TrimSpace(threadID)
	waitedForExecution := false
	for {
		c.mu.Lock()
		entry := c.entries[threadID]
		if entry == nil {
			c.mu.Unlock()
			if waitedForExecution {
				// 执行窗口内会产生 thread/closed/notLoaded。即使恢复已经完成，
				// 原 frame 也不能继续转发；客户端必须用新的 observation 重新 resume。
				return errAppServerThreadHandoffExecuting
			}
			return nil
		}
		if !entry.executing && !c.recoveryRequired(threadID) {
			delete(c.entries, threadID)
			c.mu.Unlock()
			entry.cancel()
			if waitedForExecution {
				return errAppServerThreadHandoffExecuting
			}
			return nil
		}
		waitedForExecution = true
		done := entry.done
		stateChanged := entry.stateChanged
		c.mu.Unlock()
		select {
		case <-ctx.Done():
			return fmt.Errorf("%w: %v", errAppServerThreadHandoffExecuting, ctx.Err())
		case <-done:
			// 完成通知与新的调度可能并发；醒来后重新检查该 thread 的当前 entry。
		case <-stateChanged:
			// unarchive 已完成但 archive 响应不确定时，entry 会退回 pending；
			// 续问可以取消 retry 并继续使用原本仍由 Mimi 持有的 thread。
		}
	}
}

func (c *appServerThreadHandoffCoordinator) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	entries := make([]*appServerThreadHandoffEntry, 0, len(c.entries))
	for _, entry := range c.entries {
		entries = append(entries, entry)
	}
	c.mu.Unlock()
	for _, entry := range entries {
		entry.cancel()
	}

	done := make(chan struct{})
	go func() {
		c.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(appServerThreadHandoffCloseTimeout):
		log.Printf("app-server thread handoff shutdown timed out pending=%d", len(entries))
	}
}

func (r *Router) appServerThreadHandoffHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload appServerThreadHandoffRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	threadID := strings.TrimSpace(payload.ThreadID)
	if threadID == "" {
		writeError(w, http.StatusBadRequest, "thread_id 不能为空")
		return
	}
	thread, ok := r.gatewayThread("codex", threadID)
	if !ok {
		writeError(w, http.StatusForbidden, "thread_id 未由当前设备授权")
		return
	}
	if gatewayThreadRejectsWrites(thread) {
		writeError(w, http.StatusForbidden, "只读子会话不能执行跨应用交接")
		return
	}
	if r.threadHandoffs == nil || !r.threadHandoffs.Schedule(threadID) {
		writeError(w, http.StatusServiceUnavailable, "Codex thread 交接服务暂不可用")
		return
	}
	writeJSON(w, http.StatusAccepted, appServerThreadHandoffResponse{
		ThreadID: threadID,
		Status:   "scheduled",
	})
}

func (r *Router) reclaimCodexThreadHandoff(ctx context.Context, threadID string) error {
	if r == nil || r.threadHandoffs == nil {
		return nil
	}
	waitCtx, cancel := context.WithTimeout(ctx, appServerThreadHandoffReclaimWaitTimeout)
	defer cancel()
	return r.threadHandoffs.ReclaimContext(waitCtx, threadID)
}

func (p *appServerGatewayPolicy) scheduleThreadHandoffAfterTerminal(frame *appServerGatewayFrame) {
	if p == nil || p.router == nil || normalizeAppServerRuntimeID(p.runtimeID) != "codex" ||
		strings.TrimSpace(frame.Method) != "turn/completed" || !p.supportsThreadHandoff() {
		return
	}
	threadID, _, _ := appServerGatewayServerRequestScope(frame.Params)
	thread, ok := p.allowedThread(threadID)
	if !ok || gatewayThreadRejectsWrites(thread) || p.router.threadHandoffs == nil {
		return
	}
	p.router.threadHandoffs.ScheduleAfter(threadID, appServerTerminalHandoffGrace)
}

func (p *appServerGatewayPolicy) rewriteOwnedThreadHandoffLifecycle(
	frame *appServerGatewayFrame,
	payload []byte,
) ([]byte, bool) {
	if p == nil || p.router == nil || p.router.threadHandoffs == nil ||
		normalizeAppServerRuntimeID(p.runtimeID) != "codex" || frame == nil {
		return nil, false
	}
	method := strings.TrimSpace(frame.Method)
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return nil, false
	}
	threadID, ok := gatewayStringParam(params, "threadId")
	if !ok {
		return nil, false
	}
	isLifecycle := method == "thread/archived" || method == "thread/unarchived" || method == "thread/closed"
	if method == "thread/status/changed" {
		statusType, _ := params["status"].(string)
		if status, ok := params["status"].(map[string]any); ok {
			statusType, _ = status["type"].(string)
		}
		isLifecycle = strings.EqualFold(strings.TrimSpace(statusType), "notLoaded")
	}
	if !isLifecycle {
		return nil, false
	}

	ownedNow := p.router.threadHandoffs.OwnsLifecycle(threadID)
	now := time.Now()
	p.mu.Lock()
	if p.threadHandoffLifecycle == nil {
		p.threadHandoffLifecycle = map[string]time.Time{}
	}
	for existingThreadID, existingExpiry := range p.threadHandoffLifecycle {
		if !now.Before(existingExpiry) {
			delete(p.threadHandoffLifecycle, existingThreadID)
		}
	}
	_, remembered := p.threadHandoffLifecycle[threadID]
	owned := ownedNow || remembered
	if owned && method == "thread/unarchived" {
		p.threadHandoffLifecycle[threadID] = now.Add(appServerThreadHandoffLifecycleGrace)
	} else if ownedNow && !remembered {
		p.threadHandoffLifecycle[threadID] = now.Add(appServerThreadHandoffLifecycleMax)
	}
	p.mu.Unlock()
	if !owned {
		return nil, false
	}

	params["originalMethod"] = method
	return rewriteAppServerNotification(payload, appServerThreadHandoffLifecycleMethod, params)
}

func rewriteAppServerNotification(payload []byte, method string, params map[string]any) ([]byte, bool) {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(payload, &object); err != nil {
		return nil, false
	}
	methodRaw, err := json.Marshal(method)
	if err != nil {
		return nil, false
	}
	paramsRaw, err := json.Marshal(params)
	if err != nil {
		return nil, false
	}
	object["method"] = methodRaw
	object["params"] = paramsRaw
	rewritten, err := json.Marshal(object)
	return rewritten, err == nil
}

func (r *Router) runCodexThreadHandoff(
	ctx context.Context,
	threadID string,
	markExecuting func() bool,
	pollInterval time.Duration,
) (appServerThreadHandoffOutcome, error) {
	if r.threadHandoffRecovery != nil && r.threadHandoffRecovery.RequiresUnarchive(threadID) {
		if !markExecuting() {
			return "", context.Canceled
		}
		return r.recoverCodexThreadHandoff(ctx, threadID)
	}
	rpc, closeConnection, err := r.openThreadHandoffRPC(ctx)
	if err != nil {
		return "", err
	}
	defer closeConnection()

	for {
		status, err := readThreadHandoffStatus(ctx, rpc, threadID)
		if err != nil {
			return "", err
		}
		switch status {
		case "notLoaded":
			return appServerThreadHandoffAlreadyReleased, nil
		case "active":
			if !waitThreadHandoff(ctx, pollInterval) {
				return "", ctx.Err()
			}
			continue
		case "idle", "systemError":
			return r.releaseIdleCodexThread(ctx, threadID, rpc, markExecuting)
		default:
			return "", fmt.Errorf("thread/read 返回未知状态：%s", status)
		}
	}
}

func (r *Router) openThreadHandoffRPC(ctx context.Context) (*runtimeWebSocketRPC, func(), error) {
	upstreamURL, err := r.appServerUpstreamWebSocketURL()
	if err != nil {
		return nil, nil, err
	}
	headers, err := r.appServerUpstreamHeaders()
	if err != nil {
		return nil, nil, err
	}
	dialCtx, cancel := context.WithTimeout(ctx, appServerThreadHandoffRPCTimeout)
	defer cancel()
	dialer := websocket.Dialer{HandshakeTimeout: appServerThreadHandoffRPCTimeout}
	conn, response, err := dialer.DialContext(dialCtx, upstreamURL, headers)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return nil, nil, err
	}
	rpc := &runtimeWebSocketRPC{conn: conn, dropNotifications: true}
	initializeCtx, initializeCancel := context.WithTimeout(ctx, appServerThreadHandoffRPCTimeout)
	defer initializeCancel()
	if _, err := rpc.initializeClient(initializeCtx, "mimi_remote_thread_handoff", "Mimi Remote Thread Handoff", "0.1.0"); err != nil {
		_ = conn.Close()
		return nil, nil, err
	}
	return rpc, func() { _ = conn.Close() }, nil
}

func readThreadHandoffStatus(ctx context.Context, rpc *runtimeWebSocketRPC, threadID string) (string, error) {
	callCtx, cancel := context.WithTimeout(ctx, appServerThreadHandoffRPCTimeout)
	defer cancel()
	var response appServerThreadEnvelope
	if err := rpc.call(callCtx, "thread/read", map[string]any{
		"threadId":     threadID,
		"includeTurns": false,
	}, &response); err != nil {
		return "", err
	}
	if strings.TrimSpace(response.Thread.ID) != threadID {
		return "", fmt.Errorf("thread/read 返回了不匹配的 thread.id")
	}
	return strings.TrimSpace(response.Thread.Status.Type), nil
}

func (r *Router) releaseIdleCodexThread(
	ctx context.Context,
	threadID string,
	rpc *runtimeWebSocketRPC,
	markExecuting func() bool,
) (appServerThreadHandoffOutcome, error) {
	// 进入 executing 后不再继承移动端请求 context。即使 iOS 在后台被挂起，
	// 也必须尽最大努力完成 unarchive，不能把用户会话永久留在归档列表。
	releaseCtx, cancel := context.WithTimeout(ctx, appServerThreadHandoffRPCTimeout)
	defer cancel()
	status, err := readThreadHandoffStatus(releaseCtx, rpc, threadID)
	if err != nil {
		return "", err
	}
	if status == "notLoaded" {
		return appServerThreadHandoffAlreadyReleased, nil
	}
	if status != "idle" && status != "systemError" {
		return "", fmt.Errorf("thread 在交接前恢复为非空闲状态：%s", status)
	}
	if r.threadHandoffRecovery == nil {
		return "", fmt.Errorf("thread handoff 恢复日志未初始化")
	}
	// durable marker 是 archive 的写前日志。落盘失败时绝不能继续 archive，
	// 否则进程退出后没有任何证据能把会话恢复到未归档状态。
	if err := r.threadHandoffRecovery.MarkUnarchiveRequired(threadID); err != nil {
		return "", fmt.Errorf("写入 thread handoff 恢复日志失败：%w", err)
	}
	// durable marker 落盘后 ReclaimContext 已会 fail closed；此时再进入 executing，
	// 让 tombstone 只代表真正准备发送 archive 的窗口，而不是前置状态检查失败。
	if !markExecuting() {
		if err := r.threadHandoffRecovery.ClearUnarchiveRequired(threadID); err != nil {
			return "", fmt.Errorf("取消 archive 前清理恢复日志失败：%w", err)
		}
		return "", context.Canceled
	}

	var archiveResult map[string]any
	archiveErr := rpc.call(releaseCtx, "thread/archive", map[string]any{"threadId": threadID}, &archiveResult)
	// archive 的响应可能在服务端落盘后丢失，因此无论 archiveErr 是否为空都尝试
	// unarchive。重复 unarchive 是可恢复操作，漏掉它却会把会话留在归档状态。
	unarchiveErr := r.ensureCodexThreadUnarchived(ctx, threadID, rpc)
	if unarchiveErr != nil {
		return "", fmt.Errorf("thread/unarchive 恢复失败：%w", unarchiveErr)
	}
	if err := r.threadHandoffRecovery.ClearUnarchiveRequired(threadID); err != nil {
		return "", fmt.Errorf("清理 thread handoff 恢复日志失败：%w", err)
	}
	if archiveErr != nil {
		return "", fmt.Errorf("thread/archive 释放失败：%w", archiveErr)
	}
	return appServerThreadHandoffReleased, nil
}

func (r *Router) recoverCodexThreadHandoff(ctx context.Context, threadID string) (appServerThreadHandoffOutcome, error) {
	rpc, closeConnection, err := r.openThreadHandoffRPC(ctx)
	if err != nil {
		return "", err
	}
	defer closeConnection()
	// 启动恢复的第一条业务 RPC 必须是 unarchive，不能先 thread/read 后把
	// archived thread 的 notLoaded 错当成“已经释放”。
	if err := r.ensureCodexThreadUnarchived(ctx, threadID, rpc); err != nil {
		return "", fmt.Errorf("thread/unarchive 启动恢复失败：%w", err)
	}
	if err := r.threadHandoffRecovery.ClearUnarchiveRequired(threadID); err != nil {
		return "", fmt.Errorf("清理 thread handoff 恢复日志失败：%w", err)
	}
	return appServerThreadHandoffReleased, nil
}

func (r *Router) ensureCodexThreadUnarchived(ctx context.Context, threadID string, rpc *runtimeWebSocketRPC) error {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		recoveryCtx, cancel := context.WithTimeout(ctx, appServerThreadHandoffRPCTimeout)
		currentRPC := rpc
		closeConnection := func() {}
		if attempt > 0 {
			var err error
			currentRPC, closeConnection, err = r.openThreadHandoffRPC(recoveryCtx)
			if err != nil {
				lastErr = err
				cancel()
				continue
			}
		}
		var result map[string]any
		lastErr = currentRPC.call(recoveryCtx, "thread/unarchive", map[string]any{"threadId": threadID}, &result)
		closeConnection()
		cancel()
		if lastErr == nil {
			return nil
		}
	}
	return lastErr
}

func waitThreadHandoff(ctx context.Context, delay time.Duration) bool {
	if delay <= 0 {
		return ctx.Err() == nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

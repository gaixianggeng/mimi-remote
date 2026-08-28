package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/desktopipc"
)

const (
	desktopIPCLocalOwnerID              = "agentd-local-owner"
	desktopIPCLocalOwnerConnectTimeout  = 5 * time.Second
	desktopIPCLocalOwnerPublishQueueMax = 512
)

type desktopIPCLocalPublish struct {
	threadID   string
	state      map[string]any
	force      bool
	activation string
}

// desktopIPCLocalOwnerHub owns the Mimi App Server writer for the agentd
// process. Mobile WebSockets attach to it, but their lifetime never releases
// the writer or the Desktop follower handler.
type desktopIPCLocalOwnerHub struct {
	router  *Router
	bridge  *desktopipc.Bridge
	ownerID string
	local   *desktopipc.LocalConversation

	mu           sync.Mutex
	session      *desktopIPCLocalOwnerSession
	recoveryDone chan struct{}
	closed       bool
	ownedThreads map[string]struct{}
	allowed      map[string]appServerGatewayAllowedThread
	settings     map[string]map[string]any

	publishMu    sync.Mutex
	publishQueue []desktopIPCLocalPublish
	publishWake  chan struct{}
	stopPublish  chan struct{}
	publishDone  chan struct{}
}

type desktopIPCLocalOwnerSession struct {
	conn    *websocket.Conn
	writeMu sync.Mutex
	policy  *appServerGatewayPolicy
	overlay *desktopIPCGatewayOverlay
	cancel  context.CancelFunc
	done    chan struct{}
}

func newDesktopIPCLocalOwnerHub(router *Router, bridge *desktopipc.Bridge) *desktopIPCLocalOwnerHub {
	hub := &desktopIPCLocalOwnerHub{
		router: router, bridge: bridge, ownerID: desktopIPCLocalOwnerID,
		local: desktopipc.NewLocalConversation(), ownedThreads: make(map[string]struct{}),
		allowed: make(map[string]appServerGatewayAllowedThread), settings: make(map[string]map[string]any),
		publishWake: make(chan struct{}, 1),
		stopPublish: make(chan struct{}), publishDone: make(chan struct{}),
	}
	go hub.runPublisher()
	return hub
}

func (h *desktopIPCLocalOwnerHub) Close() {
	if h == nil {
		return
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.closed = true
	session := h.session
	recoveryDone := h.recoveryDone
	h.mu.Unlock()
	close(h.stopPublish)
	<-h.publishDone
	if session != nil {
		session.cancel()
		_ = session.conn.Close()
		<-session.done
	}
	if recoveryDone != nil {
		<-recoveryDone
	}
	h.releaseAllOwners()
}

func (h *desktopIPCLocalOwnerHub) claimPermitted(threadID string) error {
	return h.claim(threadID, "permitted")
}

func (h *desktopIPCLocalOwnerHub) claimNew(threadID string) error {
	return h.claim(threadID, "new")
}

func (h *desktopIPCLocalOwnerHub) claimOffline(threadID string) error {
	return h.claim(threadID, "offline")
}

func (h *desktopIPCLocalOwnerHub) claim(threadID, mode string) error {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return fmt.Errorf("local owner thread is missing")
	}
	allowed, authorized := h.router.gatewayThread("codex", threadID)
	if !authorized {
		h.mu.Lock()
		allowed, authorized = h.allowed[threadID]
		h.mu.Unlock()
		if !authorized {
			return fmt.Errorf("local owner thread is not authorized")
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), desktopIPCLocalOwnerConnectTimeout)
	defer cancel()
	var session *desktopIPCLocalOwnerSession
	for {
		var err error
		session, err = h.ensureSession(ctx)
		if err != nil {
			return err
		}
		h.mu.Lock()
		if h.session != session {
			h.mu.Unlock()
			if ctx.Err() != nil {
				return ctx.Err()
			}
			continue
		}
		h.allowed[threadID] = allowed
		h.mu.Unlock()
		session.policy.mu.Lock()
		session.policy.allowedThreads[threadID] = allowed
		session.policy.mu.Unlock()
		break
	}
	if h.bridge.LocalOwnerIs(threadID, h.ownerID) {
		h.rememberOwnedThread(threadID)
		return nil
	}
	var err error
	switch mode {
	case "permitted":
		err = h.bridge.ClaimPermittedLocalOwner(threadID, h.ownerID, h.handleDesktopFollowerRequest)
	case "new":
		err = h.bridge.ClaimNewLocalOwner(threadID, h.ownerID, h.handleDesktopFollowerRequest)
	case "offline":
		err = h.bridge.ClaimOfflineLocalOwner(threadID, h.ownerID, h.handleDesktopFollowerRequest)
	default:
		err = fmt.Errorf("unknown local owner claim mode")
	}
	if err != nil {
		return err
	}
	h.rememberOwnedThread(threadID)
	if state, ok := h.local.State(threadID); ok {
		h.enqueuePublish(threadID, state, true, "")
	}
	// 认领成功就要挂载 Desktop follower，不能依赖本地缓存是否已经有状态。
	// Desktop 关着时 bridge 只记录路由意图，等它重新连上再恢复。
	h.enqueueActivation(threadID, mode == "new")
	return nil
}

func (h *desktopIPCLocalOwnerHub) rememberOwnedThread(threadID string) {
	h.mu.Lock()
	h.ownedThreads[strings.TrimSpace(threadID)] = struct{}{}
	h.mu.Unlock()
}

func (h *desktopIPCLocalOwnerHub) handleDesktopFollowerRequest(
	ctx context.Context,
	method string,
	raw json.RawMessage,
) (any, error) {
	session, err := h.ensureSession(ctx)
	if err != nil {
		return nil, err
	}
	return session.overlay.handleDesktopFollowerRequest(ctx, method, raw)
}

func (h *desktopIPCLocalOwnerHub) ensureSession(ctx context.Context) (*desktopIPCLocalOwnerSession, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for h.recoveryDone != nil {
		done := h.recoveryDone
		h.mu.Unlock()
		select {
		case <-done:
		case <-ctx.Done():
			h.mu.Lock()
			return nil, ctx.Err()
		}
		h.mu.Lock()
	}
	if h.closed {
		return nil, fmt.Errorf("Mimi owner hub is closed")
	}
	if h.session != nil {
		return h.session, nil
	}
	upstreamURL, err := h.router.appServerUpstreamWebSocketURL()
	if err != nil {
		return nil, err
	}
	headers, err := h.router.appServerUpstreamHeaders()
	if err != nil {
		return nil, err
	}
	dialer, err := h.router.appServerUpstreamDialer(desktopIPCLocalOwnerConnectTimeout)
	if err != nil {
		return nil, err
	}
	conn, response, err := dialer.DialContext(ctx, upstreamURL, headers)
	if err != nil {
		if response != nil {
			_ = response.Body.Close()
		}
		return nil, fmt.Errorf("connect Mimi owner App Server: %w", err)
	}
	if err := initializeDesktopIPCLocalOwner(ctx, conn, h.router.version); err != nil {
		_ = conn.Close()
		return nil, err
	}
	configureGatewayReadConn(conn)
	policy := newAppServerGatewayPolicy(h.router)
	for threadID, allowed := range h.allowed {
		policy.allowedThreads[threadID] = allowed
	}
	overlay := newDesktopIPCGatewayOverlayWithHub(
		h.bridge, policy, conn, nil, h, true,
	)
	sessionCtx, cancel := context.WithCancel(context.Background())
	session := &desktopIPCLocalOwnerSession{
		conn: conn, policy: policy, overlay: overlay, cancel: cancel, done: make(chan struct{}),
	}
	overlay.upstreamWriteMu = &session.writeMu
	h.session = session
	go h.runSession(sessionCtx, session)
	return session, nil
}

func initializeDesktopIPCLocalOwner(ctx context.Context, conn *websocket.Conn, version string) error {
	requestID := fmt.Sprintf("mimi-local-owner-init-%d", time.Now().UnixNano())
	payload, err := json.Marshal(map[string]any{
		"id": requestID, "method": "initialize",
		"params": map[string]any{
			"clientInfo": map[string]any{
				"name": "mimi_remote_owner", "title": "Mimi Remote Owner", "version": version,
			},
			"capabilities": map[string]any{"experimentalApi": true, "requestAttestation": false},
		},
	})
	if err != nil {
		return err
	}
	deadline := time.Now().Add(desktopIPCLocalOwnerConnectTimeout)
	if value, ok := ctx.Deadline(); ok && value.Before(deadline) {
		deadline = value
	}
	_ = conn.SetWriteDeadline(deadline)
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		return fmt.Errorf("initialize Mimi owner App Server: %w", err)
	}
	_ = conn.SetReadDeadline(deadline)
	for {
		messageType, raw, err := conn.ReadMessage()
		if err != nil {
			return fmt.Errorf("initialize Mimi owner App Server: %w", err)
		}
		if messageType != websocket.TextMessage {
			continue
		}
		var frame appServerGatewayFrame
		if json.Unmarshal(raw, &frame) != nil || frame.ID == nil || gatewayRequestIDKey(frame.ID) != scalarRequestIDKey(requestID) {
			continue
		}
		if len(frame.Error) > 0 && string(frame.Error) != "null" {
			return fmt.Errorf("initialize Mimi owner App Server was rejected")
		}
		break
	}
	_ = conn.SetWriteDeadline(deadline)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"method":"initialized","params":{}}`)); err != nil {
		return fmt.Errorf("confirm Mimi owner App Server initialization: %w", err)
	}
	_ = conn.SetReadDeadline(time.Time{})
	_ = conn.SetWriteDeadline(time.Time{})
	return nil
}

func (h *desktopIPCLocalOwnerHub) runSession(ctx context.Context, session *desktopIPCLocalOwnerSession) {
	defer close(session.done)
	reasons := make(chan string, 2)
	go func() { reasons <- h.readSession(ctx, session) }()
	go func() {
		reasons <- pingGatewayConnection(ctx, session.conn, &session.writeMu, "owner_upstream_ping_write")
	}()
	reason := <-reasons
	session.cancel()
	_ = session.conn.Close()
	session.overlay.failPendingUpstream(errors.New("Mimi owner App Server connection closed"))
	session.policy.releaseAllHistoryInflight()
	session.policy.close()
	h.mu.Lock()
	current := h.session == session
	threads := []string(nil)
	if current {
		threads = sortedDesktopIPCOwnedThreads(h.ownedThreads)
	}
	h.mu.Unlock()
	// Fence the old recovery epoch before exposing session=nil. A complete
	// history request that waits for the replacement session must capture this
	// new epoch, otherwise it can succeed without reopening mutations.
	for _, threadID := range threads {
		h.bridge.MarkLocalOwnerRecoveryRequired(threadID, h.ownerID)
	}
	var recoveryDone chan struct{}
	if current {
		h.mu.Lock()
		if h.session == session {
			h.session = nil
			recoveryDone = make(chan struct{})
			h.recoveryDone = recoveryDone
		}
		h.mu.Unlock()
	}
	for _, threadID := range threads {
		// Request IDs are scoped to one App Server connection. Keeping them after
		// reconnect would show approvals that the new connection cannot answer.
		h.local.DropTransportPending(threadID)
		if state, ok := h.local.State(threadID); ok {
			// Resolve stale cards locally without writing the Desktop socket. A
			// blocked socket must not delay replacement-session history recovery.
			_ = h.bridge.StageLocalConversationRecovery(threadID, h.ownerID, state)
		}
	}
	if recoveryDone != nil {
		h.mu.Lock()
		if h.recoveryDone == recoveryDone {
			close(recoveryDone)
			h.recoveryDone = nil
		}
		h.mu.Unlock()
	}
	log.Printf("Desktop IPC local owner App Server disconnected reason=%s", reason)
}

func (h *desktopIPCLocalOwnerHub) readSession(ctx context.Context, session *desktopIPCLocalOwnerSession) string {
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		default:
		}
		messageType, payload, err := session.conn.ReadMessage()
		if err != nil {
			return gatewayCloseReason("owner_upstream_read", err)
		}
		if session.overlay.consumeInternalUpstreamResponse(messageType, payload) {
			continue
		}
		forwardPayload, forward, policyErr := session.policy.observeUpstreamFrame(messageType, payload)
		if policyErr != nil {
			if !writeGatewayPolicyError(session.conn, &session.writeMu, policyErr) {
				return "owner_upstream_policy_error_write_failed"
			}
			continue
		}
		if forward {
			session.overlay.observeAcceptedUpstreamFrame(forwardPayload)
		}
	}
}

func (h *desktopIPCLocalOwnerHub) releaseAllOwners() {
	h.mu.Lock()
	threads := sortedDesktopIPCOwnedThreads(h.ownedThreads)
	h.ownedThreads = make(map[string]struct{})
	h.allowed = make(map[string]appServerGatewayAllowedThread)
	h.settings = make(map[string]map[string]any)
	h.mu.Unlock()
	for _, threadID := range threads {
		h.bridge.ReleaseLocalOwner(threadID, h.ownerID)
		h.local.Remove(threadID)
	}
}

func (h *desktopIPCLocalOwnerHub) releaseThread(threadID string) {
	threadID = strings.TrimSpace(threadID)
	h.mu.Lock()
	delete(h.ownedThreads, threadID)
	delete(h.allowed, threadID)
	delete(h.settings, threadID)
	session := h.session
	h.mu.Unlock()
	if session != nil {
		session.policy.mu.Lock()
		delete(session.policy.allowedThreads, threadID)
		session.policy.mu.Unlock()
	}
	h.bridge.ReleaseLocalOwner(threadID, h.ownerID)
	h.local.Remove(threadID)
}

// enqueueActivation mounts the Desktop follower route behind the publish queue
// so Desktop never receives a route for state this hub has not published yet.
func (h *desktopIPCLocalOwnerHub) enqueueActivation(threadID string, newThread bool) {
	if h == nil || strings.TrimSpace(threadID) == "" {
		return
	}
	activation := "existing"
	if newThread {
		activation = "new"
	}
	h.enqueueUpdate(desktopIPCLocalPublish{
		threadID: strings.TrimSpace(threadID), activation: activation,
	})
}

func (h *desktopIPCLocalOwnerHub) enqueuePublish(threadID string, state map[string]any, force bool, activation string) {
	if h == nil || strings.TrimSpace(threadID) == "" || state == nil {
		return
	}
	h.enqueueUpdate(desktopIPCLocalPublish{
		threadID: strings.TrimSpace(threadID), state: cloneAnyMap(state), force: force, activation: activation,
	})
}

func (h *desktopIPCLocalOwnerHub) enqueueUpdate(update desktopIPCLocalPublish) {
	h.publishMu.Lock()
	if len(h.publishQueue) >= desktopIPCLocalOwnerPublishQueueMax {
		replaced := false
		for index := len(h.publishQueue) - 1; index >= 0; index-- {
			if h.publishQueue[index].threadID == update.threadID {
				// Coalescing must not drop the other half of the queued work:
				// an activation-only entry keeps the pending state, and a state
				// update keeps a pending route activation.
				previous := h.publishQueue[index]
				if update.state == nil {
					update.state = previous.state
				}
				if update.activation == "" {
					update.activation = previous.activation
				} else if previous.activation == "new" {
					update.activation = "new"
				}
				update.force = true
				h.publishQueue[index] = update
				replaced = true
				break
			}
		}
		if !replaced {
			h.publishQueue = append(h.publishQueue, update)
		}
	} else {
		h.publishQueue = append(h.publishQueue, update)
	}
	h.publishMu.Unlock()
	select {
	case h.publishWake <- struct{}{}:
	default:
	}
}

func (h *desktopIPCLocalOwnerHub) runPublisher() {
	defer close(h.publishDone)
	for {
		select {
		case <-h.stopPublish:
			return
		case <-h.publishWake:
			for {
				h.publishMu.Lock()
				if len(h.publishQueue) == 0 {
					h.publishMu.Unlock()
					break
				}
				update := h.publishQueue[0]
				h.publishQueue = h.publishQueue[1:]
				h.publishMu.Unlock()
				switch {
				case update.state == nil:
				case update.force:
					_, _ = h.bridge.ForcePublishLocalConversationAndNotify(update.threadID, h.ownerID, update.state)
				default:
					_ = h.bridge.PublishLocalConversationAndNotify(update.threadID, h.ownerID, update.state)
				}
				switch update.activation {
				case "new":
					_ = h.bridge.ActivateNewLocalThread(update.threadID, h.ownerID)
				case "existing":
					_ = h.bridge.ActivateLocalThread(update.threadID, h.ownerID)
				}
			}
		}
	}
}

func (h *desktopIPCLocalOwnerHub) rememberSettings(threadID string, settings map[string]any) {
	h.mu.Lock()
	current := h.settings[threadID]
	if current == nil {
		current = map[string]any{}
	}
	for key, value := range settings {
		current[key] = cloneAnyValue(value)
	}
	h.settings[threadID] = current
	h.mu.Unlock()
}

func (h *desktopIPCLocalOwnerHub) applySettings(threadID string, params map[string]any) {
	h.mu.Lock()
	settings := cloneAnyMap(h.settings[threadID])
	h.mu.Unlock()
	for key, value := range settings {
		params[key] = value
	}
}

func newAppServerGatewayPolicy(router *Router) *appServerGatewayPolicy {
	return &appServerGatewayPolicy{
		router: router, runtimeID: "codex",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
}

func sortedDesktopIPCOwnedThreads(values map[string]struct{}) []string {
	threads := make([]string, 0, len(values))
	for threadID := range values {
		threads = append(threads, threadID)
	}
	sort.Strings(threads)
	return threads
}

package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/desktopipc"
)

const (
	desktopIPCProjectionWait             = 2 * time.Second
	desktopIPCOwnerDiscoveryWait         = 12 * time.Second
	desktopIPCUpstreamLateResponseWindow = 2 * time.Minute
	desktopIPCLocalForwardMethod         = "mimi-owner-forward-appserver"
)

type desktopIPCGatewayOverlay struct {
	bridge          *desktopipc.Bridge
	policy          *appServerGatewayPolicy
	upstream        *websocket.Conn
	upstreamWriteMu *sync.Mutex
	ownerID         string
	local           *desktopipc.LocalConversation
	ownerHub        *desktopIPCLocalOwnerHub
	isHubTransport  bool
	nextRequestID   atomic.Uint64

	mu                  sync.Mutex
	pendingActions      map[string]desktopipc.ServerRequest
	pendingActionLocal  map[string]bool
	pendingLocalReplay  map[string]string
	uncertainActions    map[string]bool
	pendingUpstream     map[string]chan desktopIPCUpstreamResult
	forwardedClient     map[string]desktopIPCForwardedClientRequest
	localServerRequests map[string]desktopIPCServerRequest
	localSettings       map[string]map[string]any
	ownedThreads        map[string]struct{}
}

type desktopIPCUpstreamResult struct {
	result json.RawMessage
	err    error
}

type desktopIPCForwardedClientRequest struct {
	method           string
	threadID         string
	pendingTurnStart uint64
}

type desktopIPCServerRequest struct {
	id       any
	method   string
	threadID string
	params   map[string]any
}

func newDesktopIPCGatewayOverlay(
	bridge *desktopipc.Bridge,
	policy *appServerGatewayPolicy,
	upstream *websocket.Conn,
	upstreamWriteMu *sync.Mutex,
) *desktopIPCGatewayOverlay {
	return newDesktopIPCGatewayOverlayWithHub(bridge, policy, upstream, upstreamWriteMu, nil, false)
}

func newDesktopIPCGatewayOverlayWithHub(
	bridge *desktopipc.Bridge,
	policy *appServerGatewayPolicy,
	upstream *websocket.Conn,
	upstreamWriteMu *sync.Mutex,
	ownerHub *desktopIPCLocalOwnerHub,
	isHubTransport bool,
) *desktopIPCGatewayOverlay {
	ownerID := fmt.Sprintf("gateway-%p", policy)
	local := desktopipc.NewLocalConversation()
	if ownerHub != nil {
		ownerID = ownerHub.ownerID
		local = ownerHub.local
	}
	return &desktopIPCGatewayOverlay{
		bridge: bridge, policy: policy, upstream: upstream, upstreamWriteMu: upstreamWriteMu,
		ownerID: ownerID, local: local, ownerHub: ownerHub, isHubTransport: isHubTransport,
		pendingActions:      make(map[string]desktopipc.ServerRequest),
		pendingActionLocal:  make(map[string]bool),
		pendingLocalReplay:  make(map[string]string),
		uncertainActions:    make(map[string]bool),
		pendingUpstream:     make(map[string]chan desktopIPCUpstreamResult),
		forwardedClient:     make(map[string]desktopIPCForwardedClientRequest),
		localServerRequests: make(map[string]desktopIPCServerRequest),
		localSettings:       make(map[string]map[string]any), ownedThreads: make(map[string]struct{}),
	}
}

func (o *desktopIPCGatewayOverlay) enabled() bool {
	if o == nil || o.bridge == nil {
		return false
	}
	status := o.bridge.Status()
	if !status.Enabled {
		return false
	}
	switch status.State {
	case desktopipc.StateDisabled, desktopipc.StateNotInstalled,
		desktopipc.StateDesktopNotRunning, desktopipc.StateLegacyCleanupRequired:
		return false
	default:
		return true
	}
}

func (o *desktopIPCGatewayOverlay) trackingEnabled() bool {
	if o == nil || o.bridge == nil {
		return false
	}
	status := o.bridge.Status()
	return status.Enabled && status.State != desktopipc.StateLegacyCleanupRequired
}

func (o *desktopIPCGatewayOverlay) close() {
	if o == nil || o.bridge == nil {
		return
	}
	if o.ownerHub != nil {
		// The process-level hub owns the writer. Closing a mobile WebSocket only
		// detaches that frontend and must not release Desktop following.
		return
	}
	o.mu.Lock()
	threads := make([]string, 0, len(o.ownedThreads))
	for threadID := range o.ownedThreads {
		threads = append(threads, threadID)
	}
	o.ownedThreads = make(map[string]struct{})
	o.mu.Unlock()
	for _, threadID := range threads {
		o.bridge.ReleaseLocalOwner(threadID, o.ownerID)
	}
}

func (o *desktopIPCGatewayOverlay) routeClientFrame(ctx context.Context, payload []byte) (bool, []byte, *appServerGatewayPolicyError) {
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return false, nil, nil
	}
	if strings.TrimSpace(frame.Method) == "" && frame.ID != nil {
		key := gatewayRequestIDKey(frame.ID)
		o.mu.Lock()
		action, pendingDesktopResponse := o.pendingActions[key]
		pendingLocalResponse := o.pendingActionLocal[key]
		o.mu.Unlock()
		if pendingDesktopResponse && !pendingLocalResponse && !o.enabled() {
			o.restorePolicyPendingAction(action)
			o.mu.Lock()
			delete(o.uncertainActions, key)
			o.mu.Unlock()
			return true, nil, &appServerGatewayPolicyError{
				id: frame.ID, message: "Codex Desktop 会话暂时不可用，审批响应未发送", target: "client",
				data: map[string]any{
					"reason": "desktop_sync_owner_unknown", "accepted": false, "retryable": true,
					"response_to_server_request": true,
				},
			}
		}
		if !o.enabled() && !pendingLocalResponse {
			return false, nil, nil
		}
		return o.routeServerRequestResponse(ctx, frame, payload)
	}
	status := o.bridge.Status()
	method := strings.TrimSpace(frame.Method)
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return true, nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error(), target: "client"}
	}
	threadID, _ := gatewayStringParam(params, "threadId")
	if threadID == "" {
		return false, nil, nil
	}
	// Once the resident hub owns a Thread, mobile writes must keep using that
	// App Server transport even while Desktop is closed or reconnecting.
	if o.ownerHub != nil && o.bridge.LocalOwnerIs(threadID, o.ownerID) {
		return o.routeLocalOwner(ctx, frame.ID, method, threadID, params)
	}
	// When Desktop is confirmed closed, establish the process-level App Server
	// writer before the first mutation. Otherwise a mobile disconnect between
	// the ACK and turn/started leaves Desktop's delayed owner probe unanswered.
	if o.ownerHub != nil && status.Enabled && status.State == desktopipc.StateDesktopNotRunning &&
		desktopIPCMethodClaimsLocalOwner(method) {
		if err := o.claimOfflineLocalOwner(threadID); err != nil {
			return true, nil, &appServerGatewayPolicyError{
				id: frame.ID, message: err.Error(), target: "client",
				data: map[string]any{"reason": "desktop_sync_owner_conflict", "accepted": false, "retryable": true},
			}
		}
		return o.routeLocalOwner(ctx, frame.ID, method, threadID, params)
	}
	if !o.enabled() {
		return false, nil, nil
	}
	if status.State != desktopipc.StateReady && desktopIPCMethodWritesThread(method) {
		return true, nil, desktopIPCOwnerUnknownError(frame.ID, nil)
	}
	if o.bridge.HasLocalOwner(threadID) {
		// Recovery always wins over the same-owner fast path. A previous timeout
		// may have reached App Server, so no new write can bypass full history.
		if o.bridge.LocalOwnerNeedsRecovery(threadID) && desktopIPCMethodWritesThread(method) {
			return o.routeLocalOwner(ctx, frame.ID, method, threadID, params)
		}
		// 当前 Gateway 就是唯一 writer 时，请求必须继续直达它自己的 App Server。
		// 只有其他 Gateway 才需要通过 follower handler 转交给 owner。
		if o.bridge.LocalOwnerIs(threadID, o.ownerID) {
			if o.ownerHub != nil && !o.isHubTransport {
				return o.routeLocalOwner(ctx, frame.ID, method, threadID, params)
			}
			return false, nil, nil
		}
		return o.routeLocalOwner(ctx, frame.ID, method, threadID, params)
	}
	projection, desktopOwned := o.bridge.DesktopProjection(threadID)
	if !desktopOwned && desktopIPCMethodCanDiscoverOwner(method) {
		if status.State != desktopipc.StateReady {
			if desktopIPCMethodWritesThread(method) {
				return true, nil, &appServerGatewayPolicyError{
					id: frame.ID, message: "Codex Desktop 会话所有权暂时无法确认", target: "client",
					data: map[string]any{
						"reason": "desktop_sync_owner_unknown", "accepted": false, "retryable": true,
					},
				}
			}
			// 连接建立前只允许读取独立 App Server 的历史，不认领 writer。
			return false, nil, nil
		}
		projection, desktopOwned, err = o.discoverDesktopOwner(ctx, threadID)
		if err != nil {
			return true, nil, desktopIPCOwnerUnknownError(frame.ID, err)
		}
	}
	if !desktopOwned {
		if desktopIPCMethodClaimsLocalOwner(method) {
			if err := o.ensurePermittedLocalOwner(threadID); err != nil {
				return true, nil, &appServerGatewayPolicyError{
					id: frame.ID, message: err.Error(), target: "client",
					data: map[string]any{"reason": "desktop_sync_owner_conflict", "accepted": false, "retryable": true},
				}
			}
			if o.bridge.LocalOwnerNeedsRecovery(threadID) {
				return o.routeLocalOwner(ctx, frame.ID, method, threadID, params)
			}
			if o.ownerHub != nil {
				return o.routeLocalOwner(ctx, frame.ID, method, threadID, params)
			}
		}
		return false, nil, nil
	}
	if desktopIPCMethodWritesThread(method) && projection.Thread == nil {
		return true, nil, desktopIPCSnapshotUnavailableError(frame.ID)
	}

	switch method {
	case "thread/resume", "thread/read":
		if projection.Thread == nil {
			return true, nil, desktopIPCSnapshotUnavailableError(frame.ID)
		}
		return o.syntheticResult(frame.ID, map[string]any{
			"thread":               projection.Thread,
			"mimiDesktopIPCMirror": true,
		})
	case "thread/turns/list":
		if projection.Thread == nil {
			return true, nil, desktopIPCSnapshotUnavailableError(frame.ID)
		}
		return true, nil, desktopIPCTurnsListUnsupportedError(frame.ID)
	case "thread/unsubscribe":
		return o.syntheticResult(frame.ID, map[string]any{})
	case "turn/start":
		if projection.ActiveTurnID != "" {
			return true, nil, desktopIPCActiveTurnError(frame.ID, projection.ActiveTurnID)
		}
		startParams := map[string]any{
			"conversationId": threadID,
			"turnStart": map[string]any{
				"request": params,
				"context": map[string]any{"inheritThreadSettings": true},
			},
		}
		result, err := o.bridge.RequestDesktopTurnStart(ctx, map[string]any{
			"conversationId": threadID, "threadSettings": desktopThreadSettings(params),
		}, startParams)
		return o.desktopFollowerResponse(frame.ID, "thread-follower-start-turn", startParams, result, err)
	case "turn/steer":
		requestedTurnID := strings.TrimSpace(firstStringFromAnyMap(params, "expectedTurnId"))
		if !projection.ActiveTurnIDTrusted || requestedTurnID == "" || requestedTurnID != projection.ActiveTurnID {
			return true, nil, desktopIPCActiveTurnUnconfirmedError(frame.ID)
		}
		followerParams, err := o.desktopSteerFollowerParams(threadID, params, projection)
		if err != nil {
			return true, nil, desktopIPCWorkspaceMismatchError(frame.ID)
		}
		return o.desktopFollowerResult(
			ctx,
			frame.ID,
			"thread-follower-steer-turn",
			followerParams,
		)
	case "turn/interrupt":
		requestedTurnID := strings.TrimSpace(firstStringFromAnyMap(params, "turnId"))
		logDesktopIPCTrace("gateway_interrupt_received", threadID, requestedTurnID,
			"projected_turn_id", projection.ActiveTurnID,
			"trusted", fmt.Sprint(projection.ActiveTurnIDTrusted))
		if !projection.ActiveTurnIDTrusted || requestedTurnID == "" || requestedTurnID != projection.ActiveTurnID {
			logDesktopIPCTrace("gateway_interrupt_rejected", threadID, requestedTurnID,
				"reason", "active_turn_unconfirmed")
			return true, nil, desktopIPCActiveTurnUnconfirmedError(frame.ID)
		}
		return o.desktopFollowerResult(ctx, frame.ID, "thread-follower-interrupt-turn", map[string]any{
			"conversationId": threadID,
			"mode":           "user-stop",
			"expectedTurnId": projection.ActiveTurnID,
		})
	case "thread/compact/start":
		return o.desktopFollowerResult(ctx, frame.ID, "thread-follower-compact-thread", map[string]any{
			"conversationId": threadID,
		})
	case "thread/goal/get":
		return o.syntheticResult(frame.ID, map[string]any{"goal": nil})
	default:
		if desktopIPCMethodWritesThread(method) {
			return true, nil, &appServerGatewayPolicyError{
				id: frame.ID, message: "此操作尚未被 Codex Desktop 会话同步支持", target: "client",
				data: map[string]any{
					"reason": "desktop_sync_method_unsupported", "accepted": false, "retryable": false,
				},
			}
		}
		return false, nil, nil
	}
}

// 已验证的 Desktop profile 在处理 follower Steer 时会用 restoreMessage 创建本地待发送消息。
// 只传 App Server 的 input 会让 Desktop 在读取 restoreMessage.cwd 时直接拒绝请求。
func (o *desktopIPCGatewayOverlay) desktopSteerFollowerParams(
	threadID string,
	params map[string]any,
	projection desktopipc.Projection,
) (map[string]any, error) {
	allowedThread, allowed := o.policy.allowedThread(threadID)
	cwd := strings.TrimSpace(allowedThread.cwd)
	projectedCWD := strings.TrimSpace(firstStringFromAnyMap(projection.Thread, "cwd"))
	if !allowed || cwd == "" || projectedCWD == "" ||
		filepath.Clean(cwd) != filepath.Clean(projectedCWD) {
		return nil, fmt.Errorf("Desktop projection cwd does not match the authorized thread workspace")
	}
	prompt := desktopIPCSteerPrompt(params["input"])
	clientUserMessageID := strings.TrimSpace(firstStringFromAnyMap(params, "clientUserMessageId"))
	restoreID := clientUserMessageID
	if restoreID == "" {
		restoreID = fmt.Sprintf("mimi-steer-%d-%d", time.Now().UnixMilli(), o.nextRequestID.Add(1))
	}
	followerParams := map[string]any{
		"conversationId": threadID,
		"input":          params["input"],
		"serviceTier":    projection.Thread["serviceTier"],
		"attachments":    []any{},
		"restoreMessage": map[string]any{
			"id": restoreID, "text": prompt, "cwd": cwd, "createdAt": time.Now().UnixMilli(),
			"context": map[string]any{
				"prompt": prompt, "addedFiles": []any{}, "fileAttachments": []any{},
				"ideContext": nil, "imageAttachments": []any{}, "workspaceRoots": []any{cwd},
			},
		},
	}
	if clientUserMessageID != "" {
		followerParams["clientUserMessageId"] = clientUserMessageID
	}
	return followerParams, nil
}

func desktopIPCSteerPrompt(raw any) string {
	input, _ := raw.([]any)
	parts := make([]string, 0, len(input))
	for _, rawItem := range input {
		item, _ := rawItem.(map[string]any)
		if !strings.EqualFold(strings.TrimSpace(firstStringFromAnyMap(item, "type")), "text") {
			continue
		}
		if text := strings.TrimSpace(firstStringFromAnyMap(item, "text")); text != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

func (o *desktopIPCGatewayOverlay) discoverDesktopOwner(ctx context.Context, threadID string) (desktopipc.Projection, bool, error) {
	if err := o.bridge.FollowThread(ctx, threadID); err != nil {
		return desktopipc.Projection{}, false, err
	}
	if _, projected := o.bridge.DesktopProjection(threadID); !projected {
		// 已验证的 Desktop profile waits up to 10 seconds for all connected clients to reject an
		// owner probe before it returns the only safe fallback signal: no-client-found.
		discoveryCtx, discoveryCancel := context.WithTimeout(ctx, desktopIPCOwnerDiscoveryWait)
		owned, err := o.bridge.DiscoverDesktopOwner(discoveryCtx, threadID)
		discoveryCancel()
		if err != nil {
			return desktopipc.Projection{}, false, err
		}
		if !owned {
			return desktopipc.Projection{}, false, nil
		}
	}
	history, err := o.bridge.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		if desktopipc.SafeToFallback(err) {
			return desktopipc.Projection{}, false, nil
		}
		return desktopipc.Projection{}, false, err
	}
	var complete struct {
		Revision int64 `json:"revision"`
	}
	if json.Unmarshal(history, &complete) != nil || complete.Revision <= 0 {
		return desktopipc.Projection{}, false, fmt.Errorf("Desktop complete-history response is invalid")
	}
	waitCtx, cancel := context.WithTimeout(ctx, desktopIPCProjectionWait)
	projection, ok := o.bridge.WaitDesktopProjectionRevision(waitCtx, threadID, complete.Revision)
	cancel()
	if ok && o.bridge.ConfirmDesktopHistory(threadID, complete.Revision) {
		return projection, true, nil
	}
	// A positive discovery is enough to route writes. Reads still require the
	// complete state broadcast requested by thread-stream-following-changed.
	return desktopipc.Projection{}, true, nil
}

func (o *desktopIPCGatewayOverlay) fallbackToLocalOwner(
	threadID string,
	id *json.RawMessage,
) (bool, []byte, *appServerGatewayPolicyError) {
	if err := o.ensurePermittedLocalOwner(threadID); err != nil {
		return true, nil, &appServerGatewayPolicyError{
			id: id, message: err.Error(), target: "client",
			data: map[string]any{"reason": "desktop_sync_owner_conflict", "accepted": false, "retryable": true},
		}
	}
	return false, nil, nil
}

func (o *desktopIPCGatewayOverlay) ensurePermittedLocalOwner(threadID string) error {
	if o.bridge.HasLocalOwner(threadID) {
		if o.bridge.LocalOwnerIs(threadID, o.ownerID) {
			return nil
		}
		return fmt.Errorf("thread already has an active writer")
	}
	if o.ownerHub != nil {
		return o.ownerHub.claimPermitted(threadID)
	}
	if err := o.bridge.ClaimPermittedLocalOwner(threadID, o.ownerID, o.handleDesktopFollowerRequest); err != nil {
		return err
	}
	o.rememberOwnedThread(threadID)
	return nil
}

func (o *desktopIPCGatewayOverlay) claimNewLocalOwner(threadID string) error {
	if o.bridge.HasLocalOwner(threadID) {
		if o.bridge.LocalOwnerIs(threadID, o.ownerID) {
			return nil
		}
		return fmt.Errorf("thread already has an active writer")
	}
	if o.ownerHub != nil {
		return o.ownerHub.claimNew(threadID)
	}
	if err := o.bridge.ClaimNewLocalOwner(threadID, o.ownerID, o.handleDesktopFollowerRequest); err != nil {
		return err
	}
	o.rememberOwnedThread(threadID)
	return nil
}

func (o *desktopIPCGatewayOverlay) claimOfflineLocalOwner(threadID string) error {
	if o.bridge.HasLocalOwner(threadID) {
		if o.bridge.LocalOwnerIs(threadID, o.ownerID) {
			return nil
		}
		return fmt.Errorf("thread already has an active writer")
	}
	if o.ownerHub != nil {
		return o.ownerHub.claimOffline(threadID)
	}
	if err := o.bridge.ClaimOfflineLocalOwner(threadID, o.ownerID, o.handleDesktopFollowerRequest); err != nil {
		return err
	}
	o.rememberOwnedThread(threadID)
	return nil
}

func (o *desktopIPCGatewayOverlay) rememberOwnedThread(threadID string) {
	if o.ownerHub != nil {
		o.ownerHub.rememberOwnedThread(threadID)
		return
	}
	o.mu.Lock()
	o.ownedThreads[threadID] = struct{}{}
	o.mu.Unlock()
}

func (o *desktopIPCGatewayOverlay) routeLocalOwner(
	ctx context.Context,
	id *json.RawMessage,
	method string,
	threadID string,
	params map[string]any,
) (bool, []byte, *appServerGatewayPolicyError) {
	if method == "thread/unsubscribe" {
		return o.syntheticResult(id, map[string]any{})
	}
	if method == "thread/turns/list" {
		result, err := o.bridge.RequestLocalOwner(ctx, threadID, desktopIPCLocalForwardMethod, map[string]any{
			"conversationId": threadID, "method": method, "params": params,
		})
		if err != nil {
			return true, nil, desktopIPCPolicyError(id, err)
		}
		return o.syntheticResult(id, result)
	}
	if method == "thread/read" || method == "thread/resume" || method == "thread/goal/get" {
		projection, ok := o.bridge.LocalProjection(threadID)
		// 缓存 projection 不能清除上一任 Gateway 的不确定交付。恢复门存在时
		// 必须再次读取权威完整历史，成功后才允许新的写操作。
		if !ok || o.bridge.LocalOwnerNeedsRecovery(threadID) {
			if _, err := o.bridge.RequestLocalOwner(ctx, threadID, "thread-follower-load-complete-history", map[string]any{
				"conversationId": threadID,
			}); err != nil {
				return true, nil, desktopIPCPolicyError(id, err)
			}
			projection, ok = o.bridge.LocalProjection(threadID)
		}
		if !ok {
			return true, nil, &appServerGatewayPolicyError{
				id: id, message: "Mimi owner 尚未提供完整会话", target: "client",
				data: map[string]any{"reason": "desktop_sync_snapshot_unavailable", "accepted": false, "retryable": true},
			}
		}
		switch method {
		case "thread/goal/get":
			return o.syntheticResult(id, map[string]any{"goal": nil})
		default:
			o.deferLocalReplay(id, threadID)
			return o.syntheticResult(id, map[string]any{"thread": projection.Thread, "mimiDesktopIPCMirror": true})
		}
	}
	followerMethod, followerParams, ok := localFollowerRoute(method, threadID, params, id)
	if !ok {
		if desktopIPCMethodWritesThread(method) {
			result, err := o.bridge.RequestLocalOwner(ctx, threadID, desktopIPCLocalForwardMethod, map[string]any{
				"conversationId": threadID, "method": method, "params": params,
			})
			if err != nil {
				return true, nil, desktopIPCPolicyError(id, err)
			}
			if o.ownerHub != nil && method == "thread/archive" {
				o.ownerHub.releaseThread(threadID)
			}
			return o.syntheticResult(id, result)
		}
		return false, nil, nil
	}
	result, err := o.bridge.RequestLocalOwner(ctx, threadID, followerMethod, followerParams)
	if err != nil {
		return true, nil, desktopIPCPolicyError(id, err)
	}
	if followerMethod == "thread-follower-start-turn" {
		if wrapper, ok := result.(map[string]any); ok {
			result = wrapper["result"]
		}
	}
	return o.syntheticResult(id, result)
}

func localFollowerRoute(method, threadID string, params map[string]any, id *json.RawMessage) (string, map[string]any, bool) {
	switch method {
	case "turn/start":
		return "thread-follower-start-turn", map[string]any{
			"conversationId": threadID,
			"turnStart": map[string]any{
				"request": params,
				"context": map[string]any{"inheritThreadSettings": true},
			},
		}, true
	case "turn/steer":
		return "thread-follower-steer-turn", map[string]any{
			"conversationId": threadID, "expectedTurnId": params["expectedTurnId"], "input": params["input"],
			"clientUserMessageId": params["clientUserMessageId"], "additionalContext": params["additionalContext"],
			"responsesapiClientMetadata": params["responsesapiClientMetadata"],
		}, true
	case "turn/interrupt":
		return "thread-follower-interrupt-turn", map[string]any{
			"conversationId": threadID, "mode": "user-stop", "expectedTurnId": params["turnId"],
		}, true
	case "thread/compact/start":
		return "thread-follower-compact-thread", map[string]any{"conversationId": threadID}, true
	case "thread/unsubscribe":
		return "", nil, false
	default:
		return "", nil, false
	}
}

func (o *desktopIPCGatewayOverlay) syntheticResult(id *json.RawMessage, result any) (bool, []byte, *appServerGatewayPolicyError) {
	payload, err := json.Marshal(map[string]any{"id": rawGatewayID(id), "result": result})
	if err != nil {
		return true, nil, &appServerGatewayPolicyError{id: id, message: "Desktop sync 响应编码失败", target: "client"}
	}
	return true, payload, nil
}

func (o *desktopIPCGatewayOverlay) desktopFollowerResult(
	ctx context.Context,
	id *json.RawMessage,
	method string,
	params map[string]any,
) (bool, []byte, *appServerGatewayPolicyError) {
	startedAt := time.Now()
	if method == "thread-follower-interrupt-turn" {
		logDesktopIPCTrace("desktop_ipc_interrupt_forwarded",
			firstStringFromAnyMap(params, "conversationId"),
			firstStringFromAnyMap(params, "expectedTurnId"))
	}
	result, err := o.bridge.RequestDesktopOwner(ctx, method, params)
	if method == "thread-follower-interrupt-turn" {
		logDesktopIPCInterruptResult(params, result, err, time.Since(startedAt))
	}
	return o.desktopFollowerResponse(id, method, params, result, err)
}

func (o *desktopIPCGatewayOverlay) desktopFollowerResponse(
	id *json.RawMessage,
	method string,
	params map[string]any,
	result json.RawMessage,
	err error,
) (bool, []byte, *appServerGatewayPolicyError) {
	if err != nil {
		if errors.Is(err, desktopipc.ErrDesktopStartInFlight) {
			return true, nil, desktopIPCActiveTurnUnconfirmedError(id)
		}
		if desktopipc.SafeToFallback(err) {
			return o.fallbackToLocalOwner(firstStringFromAnyMap(params, "conversationId"), id)
		}
		return true, nil, desktopIPCPolicyError(id, err)
	}
	var decoded any
	if len(result) > 0 && string(result) != "null" {
		if json.Unmarshal(result, &decoded) != nil {
			return true, nil, &appServerGatewayPolicyError{id: id, message: "Desktop sync 响应无效", target: "client"}
		}
	}
	if decoded == nil {
		decoded = map[string]any{}
	}
	if method == "thread-follower-start-turn" {
		if wrapper, ok := decoded.(map[string]any); ok {
			if result, exists := wrapper["result"]; exists {
				decoded = result
			}
		}
	}
	return o.syntheticResult(id, decoded)
}

func desktopThreadSettings(params map[string]any) map[string]any {
	settings := map[string]any{"serviceTier": nil}
	if model := firstStringFromAnyMap(params, "model"); model != "" {
		settings["model"] = model
	}
	if effort := firstStringFromAnyMap(params, "effort", "reasoningEffort", "reasoning_effort"); effort != "" {
		settings["effort"] = effort
	}
	if value, exists := params["serviceTier"]; exists {
		settings["serviceTier"] = value
	} else if value, exists := params["service_tier"]; exists {
		settings["serviceTier"] = value
	}
	if collaborationMode, exists := params["collaborationMode"]; exists {
		settings["collaborationMode"] = collaborationMode
	}
	return settings
}

func (o *desktopIPCGatewayOverlay) handleDesktopFollowerRequest(
	ctx context.Context,
	method string,
	raw json.RawMessage,
) (any, error) {
	var params map[string]any
	if err := json.Unmarshal(raw, &params); err != nil {
		return nil, err
	}
	threadID := firstStringFromAnyMap(params, "conversationId", "threadId")
	if threadID == "" {
		return nil, fmt.Errorf("Desktop follower request is missing conversationId")
	}
	switch method {
	case desktopIPCLocalForwardMethod:
		forwardMethod := firstStringFromAnyMap(params, "method")
		forwardParams, _ := params["params"].(map[string]any)
		if !desktopIPCMethodWritesThread(forwardMethod) && forwardMethod != "thread/turns/list" {
			return nil, fmt.Errorf("unsupported local owner method %q", forwardMethod)
		}
		result, err := o.requestUpstream(ctx, forwardMethod, cloneAnyMap(forwardParams))
		if err != nil {
			return nil, err
		}
		if forwardMethod == "thread/fork" {
			o.seedFromGatewayResult("", forwardMethod, result)
		}
		return decodeRawGatewayResult(result), nil
	case "thread-follower-load-complete-history":
		result, err := o.requestUpstream(ctx, "thread/read", map[string]any{
			"threadId": threadID, "includeTurns": true,
		})
		if err != nil {
			return nil, err
		}
		thread, err := threadFromGatewayResult(result)
		if err == nil {
			_, state, seedErr := o.local.SeedThread(thread)
			if seedErr != nil {
				return nil, seedErr
			}
			revision, publishErr := o.forcePublishLocalConversation(threadID, state)
			if publishErr != nil {
				return nil, publishErr
			}
			return map[string]any{"revision": revision}, nil
		}
		state, ok := o.local.State(threadID)
		if !ok {
			return nil, err
		}
		revision, publishErr := o.forcePublishLocalConversation(threadID, state)
		return map[string]any{"revision": revision}, publishErr
	case "thread-follower-start-turn":
		turnStart, _ := params["turnStart"].(map[string]any)
		turnParams, _ := turnStart["request"].(map[string]any)
		turnParams = cloneAnyMap(turnParams)
		turnParams["threadId"] = threadID
		o.applyLocalSettings(threadID, turnParams)
		pendingTurnStart := o.local.RememberTurnStart(threadID, turnParams)
		result, err := o.requestUpstream(ctx, "turn/start", turnParams)
		if err != nil {
			o.local.ForgetTurnStart(threadID, pendingTurnStart)
			return nil, err
		}
		return map[string]any{"result": decodeRawGatewayResult(result)}, nil
	case "thread-follower-steer-turn":
		state, ok := o.local.State(threadID)
		if !ok {
			return nil, fmt.Errorf("Mimi owner state is unavailable")
		}
		activeTurnID, ok := desktopipc.RealActiveTurnID(state)
		if !ok {
			return nil, fmt.Errorf("Mimi owner has no verified active Turn")
		}
		return o.requestUpstreamDecoded(ctx, "turn/steer", map[string]any{
			"threadId": threadID, "input": params["input"], "expectedTurnId": activeTurnID,
			"clientUserMessageId": params["clientUserMessageId"], "additionalContext": params["additionalContext"],
			"responsesapiClientMetadata": params["responsesapiClientMetadata"],
		})
	case "thread-follower-interrupt-turn":
		state, ok := o.local.State(threadID)
		if !ok {
			return nil, fmt.Errorf("Mimi owner state is unavailable")
		}
		activeTurnID, ok := desktopipc.RealActiveTurnID(state)
		if !ok || activeTurnID != firstStringFromAnyMap(params, "expectedTurnId") {
			return nil, fmt.Errorf("Mimi owner active Turn does not match the interrupt request")
		}
		return o.requestUpstreamDecoded(ctx, "turn/interrupt", map[string]any{
			"threadId": threadID, "turnId": activeTurnID,
		})
	case "thread-follower-compact-thread":
		return o.requestUpstreamDecoded(ctx, "thread/compact/start", map[string]any{"threadId": threadID})
	case "thread-follower-update-thread-settings":
		settings, _ := params["threadSettings"].(map[string]any)
		o.rememberLocalSettings(threadID, settings)
		return map[string]any{}, nil
	case "thread-follower-command-approval-decision":
		return o.forwardDesktopServerRequestResponse(ctx, threadID, params, map[string]any{"decision": params["decision"]})
	case "thread-follower-file-approval-decision":
		return o.forwardDesktopServerRequestResponse(ctx, threadID, params, map[string]any{"decision": params["decision"]})
	case "thread-follower-permissions-request-approval-response",
		"thread-follower-submit-user-input", "thread-follower-submit-mcp-server-elicitation-response":
		response, _ := params["response"].(map[string]any)
		return o.forwardDesktopServerRequestResponse(ctx, threadID, params, response)
	default:
		return nil, fmt.Errorf("unsupported Desktop follower request %q", method)
	}
}

func (o *desktopIPCGatewayOverlay) requestUpstream(ctx context.Context, method string, params map[string]any) (json.RawMessage, error) {
	threadID := firstStringFromAnyMap(params, "threadId", "thread_id")
	if err := o.bridge.ValidateLocalOwnerLease(ctx, threadID); err != nil {
		return nil, err
	}
	id := fmt.Sprintf("mimi-desktop-owner-%d", o.nextRequestID.Add(1))
	idJSON, _ := json.Marshal(id)
	idRaw := json.RawMessage(idJSON)
	idKey := gatewayRequestIDKey(&idRaw)
	payload, err := json.Marshal(map[string]any{"id": id, "method": method, "params": params})
	if err != nil {
		return nil, err
	}
	payload, policyErr := o.policy.validateClientFrameContext(ctx, websocket.TextMessage, payload)
	if policyErr != nil {
		return nil, fmt.Errorf("Gateway policy rejected Desktop follower request: %s", policyErr.message)
	}
	if err := o.bridge.ValidateLocalOwnerLease(ctx, threadID); err != nil {
		o.policy.abortValidatedRequest(payload)
		return nil, err
	}
	waiter := make(chan desktopIPCUpstreamResult, 1)
	o.mu.Lock()
	o.pendingUpstream[idKey] = waiter
	o.mu.Unlock()
	if err := writeWebSocketFrame(o.upstream, o.upstreamWriteMu, websocket.TextMessage, payload); err != nil {
		o.retirePendingUpstreamLater(idKey, waiter, &idRaw)
		return nil, err
	}
	select {
	case result := <-waiter:
		return result.result, result.err
	case <-ctx.Done():
		// Delivery is uncertain. Keep a short-lived tombstone so a late App Server
		// response is consumed instead of leaking to the mobile JSON-RPC client.
		o.retirePendingUpstreamLater(idKey, waiter, &idRaw)
		return nil, ctx.Err()
	}
}

func (o *desktopIPCGatewayOverlay) retirePendingUpstreamLater(
	idKey string,
	waiter chan desktopIPCUpstreamResult,
	id *json.RawMessage,
) {
	time.AfterFunc(desktopIPCUpstreamLateResponseWindow, func() {
		o.mu.Lock()
		removed := false
		if o.pendingUpstream[idKey] == waiter {
			delete(o.pendingUpstream, idKey)
			removed = true
		}
		o.mu.Unlock()
		if removed {
			o.policy.cancelPendingHistoryRequest(id)
			o.policy.forgetPending(id)
		}
	})
}

func (o *desktopIPCGatewayOverlay) requestUpstreamDecoded(ctx context.Context, method string, params map[string]any) (any, error) {
	result, err := o.requestUpstream(ctx, method, params)
	if err != nil {
		return nil, err
	}
	return decodeRawGatewayResult(result), nil
}

func (o *desktopIPCGatewayOverlay) forwardDesktopServerRequestResponse(
	ctx context.Context,
	threadID string,
	params map[string]any,
	response map[string]any,
) (any, error) {
	if err := o.bridge.ValidateLocalOwnerLease(ctx, threadID); err != nil {
		return nil, err
	}
	requestID := params["requestId"]
	key := scalarRequestIDKey(requestID)
	o.mu.Lock()
	pending, ok := o.localServerRequests[key]
	o.mu.Unlock()
	if !ok || pending.threadID != threadID {
		return nil, fmt.Errorf("Desktop follower response does not match a pending App Server request")
	}
	response = desktopFollowerServerResponse(pending, response)
	payload, err := json.Marshal(map[string]any{"id": pending.id, "result": response})
	if err != nil {
		return nil, err
	}
	payload, policyErr := o.policy.validateClientFrameContext(ctx, websocket.TextMessage, payload)
	if policyErr != nil {
		return nil, fmt.Errorf("Gateway policy rejected Desktop follower response: %s", policyErr.message)
	}
	if err := o.bridge.ValidateLocalOwnerLease(ctx, threadID); err != nil {
		o.restorePolicyLocalServerRequest(pending)
		return nil, err
	}
	if err := writeWebSocketFrame(o.upstream, o.upstreamWriteMu, websocket.TextMessage, payload); err != nil {
		// A failed WebSocket write can still have reached App Server. Do not restore
		// the response token; the Bridge blocks further writes until full history.
		o.mu.Lock()
		delete(o.localServerRequests, key)
		o.mu.Unlock()
		return nil, err
	}
	o.mu.Lock()
	delete(o.localServerRequests, key)
	o.mu.Unlock()
	if state, changed := o.local.ResolveRequest(threadID, pending.id); changed {
		o.publishLocalConversation(threadID, state)
	}
	return map[string]any{}, nil
}

func (o *desktopIPCGatewayOverlay) restorePolicyLocalServerRequest(pending desktopIPCServerRequest) {
	pendingID, err := json.Marshal(pending.id)
	if err != nil {
		return
	}
	pendingParams, err := json.Marshal(pending.params)
	if err != nil {
		return
	}
	pendingIDRaw := json.RawMessage(pendingID)
	_ = o.policy.rememberPendingServerRequest(&pendingIDRaw, pending.method, pendingParams)
}

func desktopFollowerServerResponse(pending desktopIPCServerRequest, response map[string]any) map[string]any {
	if pending.method != "item/permissions/requestApproval" || response["permissions"] != nil {
		return response
	}
	decision := firstStringFromAnyMap(response, "decision")
	permissions, _ := pending.params["permissions"].(map[string]any)
	if decision != "accept" && decision != "acceptForSession" {
		permissions = map[string]any{}
	}
	scope := "turn"
	if decision == "acceptForSession" {
		scope = "session"
	}
	return map[string]any{"permissions": cloneAnyMap(permissions), "scope": scope}
}

func (o *desktopIPCGatewayOverlay) rememberLocalSettings(threadID string, settings map[string]any) {
	if o.ownerHub != nil {
		o.ownerHub.rememberSettings(threadID, settings)
		return
	}
	o.mu.Lock()
	current := o.localSettings[threadID]
	if current == nil {
		current = map[string]any{}
	}
	for key, value := range settings {
		current[key] = cloneAnyValue(value)
	}
	o.localSettings[threadID] = current
	o.mu.Unlock()
}

func (o *desktopIPCGatewayOverlay) applyLocalSettings(threadID string, params map[string]any) {
	if o.ownerHub != nil {
		o.ownerHub.applySettings(threadID, params)
		return
	}
	o.mu.Lock()
	settings := cloneAnyMap(o.localSettings[threadID])
	o.mu.Unlock()
	for key, value := range settings {
		params[key] = value
	}
}

func (o *desktopIPCGatewayOverlay) publishLocalConversation(threadID string, state map[string]any) {
	if o.ownerHub != nil {
		o.ownerHub.enqueuePublish(threadID, state, false, "")
		return
	}
	_ = o.bridge.PublishLocalConversation(threadID, o.ownerID, state)
}

func (o *desktopIPCGatewayOverlay) forcePublishLocalConversation(threadID string, state map[string]any) (int64, error) {
	if o.ownerHub != nil && o.isHubTransport {
		return o.bridge.ForcePublishLocalConversationAndNotify(threadID, o.ownerID, state)
	}
	return o.bridge.ForcePublishLocalConversation(threadID, o.ownerID, state)
}

func (o *desktopIPCGatewayOverlay) deferLocalReplay(id *json.RawMessage, threadID string) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return
	}
	o.mu.Lock()
	o.pendingLocalReplay[key] = threadID
	o.mu.Unlock()
}

func (o *desktopIPCGatewayOverlay) afterClientResponse(payload []byte) {
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil || frame.ID == nil {
		return
	}
	key := gatewayRequestIDKey(frame.ID)
	o.mu.Lock()
	threadID := o.pendingLocalReplay[key]
	delete(o.pendingLocalReplay, key)
	o.mu.Unlock()
	if threadID != "" {
		_ = o.bridge.NotifyLocalConversation(threadID, o.ownerID, true)
	}
}

func (o *desktopIPCGatewayOverlay) routeServerRequestResponse(
	ctx context.Context,
	frame appServerGatewayFrame,
	payload []byte,
) (bool, []byte, *appServerGatewayPolicyError) {
	key := gatewayRequestIDKey(frame.ID)
	o.mu.Lock()
	action, ok := o.pendingActions[key]
	localOwnerAction := o.pendingActionLocal[key]
	o.mu.Unlock()
	if !ok {
		return false, nil, nil
	}
	var response map[string]any
	if json.Unmarshal(payload, &response) != nil || response["error"] != nil {
		o.restorePolicyPendingAction(action)
		o.mu.Lock()
		delete(o.uncertainActions, key)
		o.mu.Unlock()
		return true, nil, &appServerGatewayPolicyError{
			id: frame.ID, message: "Desktop sync 不接受失败的审批响应", target: "client",
			data: map[string]any{"reason": "desktop_sync_response_unsupported", "accepted": false},
		}
	}
	method, params, err := desktopFollowerResponse(action, response["result"])
	if err != nil {
		o.restorePolicyPendingAction(action)
		o.mu.Lock()
		delete(o.uncertainActions, key)
		o.mu.Unlock()
		return true, nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error(), target: "client"}
	}
	var requestErr error
	if localOwnerAction {
		threadID := firstStringFromAnyMap(action.Params, "threadId", "thread_id")
		_, requestErr = o.bridge.RequestLocalOwner(ctx, threadID, method, params)
	} else {
		_, requestErr = o.bridge.RequestDesktopOwner(ctx, method, params)
	}
	if requestErr != nil {
		var ipcRequestErr *desktopipc.RequestError
		if errors.As(requestErr, &ipcRequestErr) && ipcRequestErr.Delivery == desktopipc.DeliveryUncertain {
			o.mu.Lock()
			o.uncertainActions[key] = true
			o.mu.Unlock()
		} else {
			o.restorePolicyPendingAction(action)
			o.mu.Lock()
			delete(o.uncertainActions, key)
			o.mu.Unlock()
		}
		return true, nil, desktopIPCPolicyError(frame.ID, requestErr)
	}
	o.mu.Lock()
	delete(o.pendingActions, key)
	delete(o.uncertainActions, key)
	delete(o.pendingActionLocal, key)
	o.mu.Unlock()
	// Responses to server requests are fire-and-forget on the App Server wire.
	return true, nil, nil
}

func (o *desktopIPCGatewayOverlay) restorePolicyPendingAction(action desktopipc.ServerRequest) bool {
	if o == nil || o.policy == nil {
		return false
	}
	actionParams, err := json.Marshal(action.Params)
	if err != nil {
		return false
	}
	actionID, err := json.Marshal(action.ID)
	if err != nil {
		return false
	}
	actionIDRaw := json.RawMessage(actionID)
	return o.policy.rememberPendingServerRequest(&actionIDRaw, action.Method, actionParams) == nil
}

func desktopFollowerResponse(action desktopipc.ServerRequest, result any) (string, map[string]any, error) {
	resultObject, _ := result.(map[string]any)
	conversationID := firstStringFromAnyMap(action.Params, "threadId", "thread_id")
	base := map[string]any{"conversationId": conversationID, "requestId": action.ID}
	switch action.Method {
	case "item/commandExecution/requestApproval":
		base["decision"] = firstStringFromAnyMap(resultObject, "decision")
		return "thread-follower-command-approval-decision", base, nil
	case "item/fileChange/requestApproval", "item/fileRead/requestApproval":
		base["decision"] = firstStringFromAnyMap(resultObject, "decision")
		return "thread-follower-file-approval-decision", base, nil
	case "item/permissions/requestApproval":
		base["response"] = resultObject
		return "thread-follower-permissions-request-approval-response", base, nil
	case "item/tool/requestUserInput":
		base["response"] = resultObject
		return "thread-follower-submit-user-input", base, nil
	case "mcpServer/elicitation/request":
		base["response"] = resultObject
		return "thread-follower-submit-mcp-server-elicitation-response", base, nil
	default:
		return "", nil, fmt.Errorf("Desktop sync server request response is unsupported")
	}
}

func (o *desktopIPCGatewayOverlay) observeClientForward(payload []byte) {
	if !o.trackingEnabled() {
		return
	}
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return
	}
	if strings.TrimSpace(frame.Method) == "" && frame.ID != nil {
		key := gatewayRequestIDKey(frame.ID)
		o.mu.Lock()
		pending, ok := o.localServerRequests[key]
		if ok {
			delete(o.localServerRequests, key)
		}
		o.mu.Unlock()
		if ok {
			if state, changed := o.local.ResolveRequest(pending.threadID, rawGatewayID(frame.ID)); changed {
				o.publishLocalConversation(pending.threadID, state)
			}
		}
		return
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return
	}
	threadID := firstStringFromAnyMap(params, "threadId", "thread_id")
	if frame.ID == nil {
		return
	}
	if strings.TrimSpace(frame.Method) == "thread/start" || strings.TrimSpace(frame.Method) == "thread/fork" {
		o.mu.Lock()
		o.forwardedClient[gatewayRequestIDKey(frame.ID)] = desktopIPCForwardedClientRequest{method: frame.Method}
		o.mu.Unlock()
		return
	}
	if strings.TrimSpace(frame.Method) == "thread/resume" || strings.TrimSpace(frame.Method) == "thread/read" {
		o.mu.Lock()
		o.forwardedClient[gatewayRequestIDKey(frame.ID)] = desktopIPCForwardedClientRequest{
			method: strings.TrimSpace(frame.Method), threadID: threadID,
		}
		o.mu.Unlock()
		return
	}
	if threadID == "" || !o.bridge.LocalOwnerIs(threadID, o.ownerID) {
		return
	}
	if strings.TrimSpace(frame.Method) == "turn/start" {
		settings := map[string]any{}
		for _, key := range []string{"model", "effort", "reasoningEffort", "serviceTier", "collaborationMode"} {
			if value, exists := params[key]; exists {
				settings[key] = value
			}
		}
		o.rememberLocalSettings(threadID, settings)
		pendingTurnStart := o.local.RememberTurnStart(threadID, params)
		o.mu.Lock()
		o.forwardedClient[gatewayRequestIDKey(frame.ID)] = desktopIPCForwardedClientRequest{
			method: frame.Method, threadID: threadID, pendingTurnStart: pendingTurnStart,
		}
		o.mu.Unlock()
		_ = o.bridge.ActivateLocalThread(threadID, o.ownerID)
		return
	}
	o.mu.Lock()
	o.forwardedClient[gatewayRequestIDKey(frame.ID)] = desktopIPCForwardedClientRequest{
		method: strings.TrimSpace(frame.Method), threadID: threadID,
	}
	o.mu.Unlock()
}

// consumeInternalUpstreamResponse consumes responses created by Desktop follower
// actions. It applies the same Gateway policy before the private waiter sees them.
func (o *desktopIPCGatewayOverlay) consumeInternalUpstreamResponse(messageType int, payload []byte) bool {
	if o == nil {
		return false
	}
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return false
	}
	if strings.TrimSpace(frame.Method) == "" && frame.ID != nil {
		key := gatewayRequestIDKey(frame.ID)
		o.mu.Lock()
		waiter, internal := o.pendingUpstream[key]
		if internal {
			delete(o.pendingUpstream, key)
		}
		o.mu.Unlock()
		if internal {
			_, _, policyErr := o.policy.observeUpstreamFrame(messageType, payload)
			result := desktopIPCUpstreamResult{result: frame.Result}
			if policyErr != nil {
				result.err = fmt.Errorf("Gateway policy rejected App Server response: %s", policyErr.message)
			} else if len(frame.Error) > 0 && string(frame.Error) != "null" {
				result.err = fmt.Errorf("App Server %s failed", key)
			}
			waiter <- result
			return true
		}
	}
	return false
}

func (o *desktopIPCGatewayOverlay) failPendingUpstream(err error) {
	if o == nil {
		return
	}
	o.mu.Lock()
	pending := o.pendingUpstream
	o.pendingUpstream = make(map[string]chan desktopIPCUpstreamResult)
	o.mu.Unlock()
	for _, waiter := range pending {
		select {
		case waiter <- desktopIPCUpstreamResult{err: err}:
		default:
		}
	}
}

// observeAcceptedUpstreamFrame mirrors only Gateway-policy-approved App Server
// responses and lifecycle messages into Desktop state.
func (o *desktopIPCGatewayOverlay) observeAcceptedUpstreamFrame(payload []byte) {
	if !o.trackingEnabled() {
		return
	}
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return
	}
	method := strings.TrimSpace(frame.Method)
	if method == "" && frame.ID != nil {
		key := gatewayRequestIDKey(frame.ID)
		o.mu.Lock()
		forwarded, tracked := o.forwardedClient[key]
		if tracked {
			delete(o.forwardedClient, key)
		}
		o.mu.Unlock()
		if tracked && len(frame.Error) > 0 && string(frame.Error) != "null" {
			o.local.ForgetTurnStart(forwarded.threadID, forwarded.pendingTurnStart)
		}
		if tracked && len(frame.Result) > 0 {
			o.seedFromGatewayResult(forwarded.threadID, forwarded.method, frame.Result)
		}
		return
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return
	}
	if frame.ID != nil {
		if o.isHubTransport {
			threadID := firstStringFromAnyMap(params, "threadId", "thread_id")
			if !o.bridge.LocalOwnerIs(threadID, o.ownerID) {
				return
			}
		}
		threadID, state, changed := o.local.RememberRequest(rawGatewayID(frame.ID), method, params)
		if changed {
			o.mu.Lock()
			o.localServerRequests[gatewayRequestIDKey(frame.ID)] = desktopIPCServerRequest{
				id: rawGatewayID(frame.ID), method: method, threadID: threadID, params: cloneAnyMap(params),
			}
			o.mu.Unlock()
			o.publishLocalConversation(threadID, state)
		}
		return
	}
	if o.isHubTransport {
		threadID := firstStringFromAnyMap(params, "threadId", "thread_id")
		if method == "thread/started" {
			thread, _ := params["thread"].(map[string]any)
			threadID = firstStringFromAnyMap(thread, "id", "threadId", "thread_id")
		}
		if !o.bridge.LocalOwnerIs(threadID, o.ownerID) {
			return
		}
	}
	threadID, state, changed := o.local.Apply(method, params)
	if changed {
		var claimErr error
		if !o.bridge.LocalOwnerIs(threadID, o.ownerID) {
			claimErr = o.claimOfflineLocalOwner(threadID)
		}
		if claimErr == nil {
			o.publishLocalConversation(threadID, state)
			if method == "thread/started" && o.ownerHub == nil {
				_ = o.bridge.ActivateNewLocalThread(threadID, o.ownerID)
			}
		}
	}
}

func (o *desktopIPCGatewayOverlay) seedFromGatewayResult(
	expectedThreadID string,
	method string,
	result json.RawMessage,
) {
	thread, err := threadFromGatewayResult(result)
	if err != nil {
		return
	}
	threadID, state, err := o.local.SeedThread(thread)
	if err != nil || (expectedThreadID != "" && threadID != expectedThreadID) {
		return
	}
	if o.bridge.LocalOwnerIs(threadID, o.ownerID) {
		o.publishLocalConversation(threadID, state)
		if o.ownerHub == nil && (method == "thread/start" || method == "thread/fork") {
			_ = o.bridge.ActivateNewLocalThread(threadID, o.ownerID)
		}
		return
	}
	// 只读 read/resume 只能填充本地缓存，不能建立 writer ownership。
	// thread/start 和 thread/fork 的 Thread ID 则由当前 App Server 新生成。
	if method == "thread/start" || method == "thread/fork" {
		if o.claimNewLocalOwner(threadID) == nil {
			o.publishLocalConversation(threadID, state)
			if o.ownerHub == nil {
				_ = o.bridge.ActivateNewLocalThread(threadID, o.ownerID)
			}
		}
	}
}

func threadFromGatewayResult(result json.RawMessage) (map[string]any, error) {
	var decoded map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(result)))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return nil, err
	}
	thread, _ := decoded["thread"].(map[string]any)
	if thread == nil {
		return nil, fmt.Errorf("App Server response is missing thread")
	}
	return thread, nil
}

func decodeRawGatewayResult(result json.RawMessage) any {
	if len(result) == 0 || string(result) == "null" {
		return map[string]any{}
	}
	var decoded any
	decoder := json.NewDecoder(strings.NewReader(string(result)))
	decoder.UseNumber()
	if decoder.Decode(&decoded) != nil {
		return map[string]any{}
	}
	return decoded
}

func cloneAnyMap(value map[string]any) map[string]any {
	copy := map[string]any{}
	for key, entry := range value {
		copy[key] = cloneAnyValue(entry)
	}
	return copy
}

func cloneAnyValue(value any) any {
	payload, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	var copy any
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	decoder.UseNumber()
	if decoder.Decode(&copy) != nil {
		return nil
	}
	return copy
}

func (o *desktopIPCGatewayOverlay) forwardEvents(
	ctx context.Context,
	client *websocket.Conn,
	clientWriteMu *sync.Mutex,
	monitor *relayGatewayConnMonitor,
) string {
	updates, unsubscribe := o.bridge.Subscribe()
	defer unsubscribe()
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		case event, ok := <-updates:
			if !ok {
				return "desktop_ipc_closed"
			}
			if _, allowed := o.policy.allowedThread(event.ThreadID); !allowed {
				continue
			}
			logDesktopIPCProjectionTrace(event)
			messages := []desktopipc.AppServerMessage(nil)
			if event.Stale {
				messages = append(messages, desktopipc.AppServerMessage{
					Method: "thread/status/changed",
					Params: map[string]any{
						"threadId": event.ThreadID, "status": map[string]any{"type": "notLoaded"},
						"mimiDesktopIPCMirror": true,
					},
				})
			} else {
				messages = desktopipc.ProjectionMessages(event.ThreadID, event.Previous, event.Projection)
			}
			messages = append(messages, o.syncServerRequests(event)...)
			for _, message := range messages {
				payload, err := desktopipc.MarshalAppServerMessage(message)
				if err != nil {
					continue
				}
				forwardPayload, forward, policyErr := o.policy.observeUpstreamFrame(websocket.TextMessage, payload)
				if policyErr != nil || !forward {
					continue
				}
				if err := writeWebSocketFrame(client, clientWriteMu, websocket.TextMessage, forwardPayload); err != nil {
					return gatewayCloseReason("desktop_ipc_client_write", err)
				}
				monitor.recordForward("desktop_ipc_to_client", len(payload), len(forwardPayload), 0, 0, forwardPayload)
			}
		}
	}
}

func (o *desktopIPCGatewayOverlay) syncServerRequests(event desktopipc.ThreadEvent) []desktopipc.AppServerMessage {
	next := make(map[string]desktopipc.ServerRequest)
	for _, request := range event.Requests {
		key := scalarRequestIDKey(request.ID)
		if key != "" {
			next[key] = request
		}
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	messages := make([]desktopipc.AppServerMessage, 0)
	for key, pending := range o.pendingActions {
		if firstStringFromAnyMap(pending.Params, "threadId") != event.ThreadID {
			continue
		}
		if _, exists := next[key]; !exists {
			messages = append(messages, desktopipc.AppServerMessage{
				Method: "serverRequest/resolved",
				Params: map[string]any{"threadId": event.ThreadID, "requestId": pending.ID, "mimiDesktopIPCMirror": true},
			})
			delete(o.pendingActions, key)
			delete(o.uncertainActions, key)
			delete(o.pendingActionLocal, key)
		}
	}
	for key, request := range next {
		if _, exists := o.pendingActions[key]; exists {
			o.pendingActionLocal[key] = event.LocalOwner
			if event.HistoryConfirmed && o.uncertainActions[key] && o.restorePolicyPendingAction(request) {
				o.pendingActions[key] = request
				delete(o.uncertainActions, key)
				messages = append(messages, desktopipc.AppServerMessage{
					ID: request.ID, Method: request.Method, Params: request.Params,
				})
			}
			continue
		}
		o.pendingActions[key] = request
		o.pendingActionLocal[key] = event.LocalOwner
		messages = append(messages, desktopipc.AppServerMessage{ID: request.ID, Method: request.Method, Params: request.Params})
	}
	return messages
}

func logDesktopIPCInterruptResult(params map[string]any, result json.RawMessage, err error, duration time.Duration) {
	threadID := firstStringFromAnyMap(params, "conversationId")
	expectedTurnID := firstStringFromAnyMap(params, "expectedTurnId")
	if err != nil {
		outcome := "other"
		var requestErr *desktopipc.RequestError
		if errors.As(err, &requestErr) {
			outcome = string(requestErr.Delivery)
		} else if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			outcome = "context_done"
		}
		logDesktopIPCTrace("desktop_ipc_interrupt_failed", threadID, expectedTurnID,
			"outcome", outcome, "duration_ms", fmt.Sprint(duration.Milliseconds()))
		return
	}
	var ack map[string]any
	_ = json.Unmarshal(result, &ack)
	interruptedTurnID := firstStringFromAnyMap(ack, "interruptedTurnId")
	ok, _ := ack["ok"].(bool)
	logDesktopIPCTrace("desktop_ipc_interrupt_ack", threadID, expectedTurnID,
		"ack_turn_id", interruptedTurnID,
		"ok", fmt.Sprint(ok),
		"matched", fmt.Sprint(interruptedTurnID != "" && interruptedTurnID == expectedTurnID),
		"goal_pause_error", fmt.Sprint(ack["goalPauseError"] != nil),
		"duration_ms", fmt.Sprint(duration.Milliseconds()))
}

func logDesktopIPCProjectionTrace(event desktopipc.ThreadEvent) {
	if event.Stale {
		logDesktopIPCTrace("desktop_projection_stale", event.ThreadID, "")
		return
	}
	if event.Previous != nil && event.Previous.ActiveTurnID != event.Projection.ActiveTurnID {
		if previousTurnID := event.Previous.ActiveTurnID; previousTurnID != "" {
			status := desktopIPCProjectionTurnStatus(event.Projection, previousTurnID)
			if status == "" {
				status = desktopIPCProjectionTurnStatus(*event.Previous, previousTurnID)
			}
			eventName := "desktop_projection_turn_terminal"
			if desktopIPCTraceName(status) == "interrupted" {
				eventName = "desktop_projection_interrupted"
			}
			logDesktopIPCTrace(eventName, event.ThreadID, previousTurnID, "status", status)
		}
		if event.Projection.ActiveTurnID != "" {
			logDesktopIPCTrace("desktop_projection_turn_started", event.ThreadID, event.Projection.ActiveTurnID,
				"trusted", fmt.Sprint(event.Projection.ActiveTurnIDTrusted))
		}
	}
	previousItems := desktopIPCCommandTraceItems(desktopipc.Projection{})
	if event.Previous != nil {
		previousItems = desktopIPCCommandTraceItems(*event.Previous)
	}
	for key, current := range desktopIPCCommandTraceItems(event.Projection) {
		previous, existed := previousItems[key]
		if existed && previous.status == current.status {
			continue
		}
		logDesktopIPCTrace("desktop_tool_item_state", event.ThreadID, current.turnID,
			"item_id", current.itemID,
			"status", current.status,
			"duration_ms", current.durationMilliseconds)
	}
}

type desktopIPCCommandTraceItem struct {
	turnID               string
	itemID               string
	status               string
	durationMilliseconds string
}

func desktopIPCCommandTraceItems(projection desktopipc.Projection) map[string]desktopIPCCommandTraceItem {
	items := make(map[string]desktopIPCCommandTraceItem)
	for _, rawTurn := range projection.Turns {
		turn, _ := rawTurn.(map[string]any)
		turnID := firstStringFromAnyMap(turn, "id", "turnId", "turn_id")
		turnItems, _ := turn["items"].([]any)
		for _, rawItem := range turnItems {
			item, _ := rawItem.(map[string]any)
			if desktopIPCTraceName(firstStringFromAnyMap(item, "type")) != "commandexecution" {
				continue
			}
			itemID := firstStringFromAnyMap(item, "id", "itemId", "item_id")
			if itemID == "" {
				continue
			}
			status := desktopIPCTraceToken(firstStringFromAnyMap(item, "status"))
			items[turnID+"\x00"+itemID] = desktopIPCCommandTraceItem{
				turnID: turnID, itemID: itemID, status: status,
				durationMilliseconds: desktopIPCTraceNumber(item["durationMs"]),
			}
		}
	}
	return items
}

func desktopIPCProjectionTurnStatus(projection desktopipc.Projection, turnID string) string {
	for _, rawTurn := range projection.Turns {
		turn, _ := rawTurn.(map[string]any)
		if firstStringFromAnyMap(turn, "id", "turnId", "turn_id") == turnID {
			return firstStringFromAnyMap(turn, "status")
		}
	}
	return ""
}

func desktopIPCTraceNumber(value any) string {
	switch typed := value.(type) {
	case json.Number:
		return typed.String()
	case float64:
		return fmt.Sprintf("%.0f", typed)
	case float32:
		return fmt.Sprintf("%.0f", typed)
	case int:
		return fmt.Sprint(typed)
	case int64:
		return fmt.Sprint(typed)
	default:
		return "absent"
	}
}

func desktopIPCTraceToken(value string) string {
	return gatewayCompactLogToken(desktopIPCTraceName(value))
}

func desktopIPCTraceName(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.NewReplacer("-", "", "_", "", " ", "").Replace(value)
	if len(value) > 64 {
		return "invalid"
	}
	return value
}

func logDesktopIPCTrace(event string, threadID string, turnID string, fields ...string) {
	parts := []string{
		"event=" + desktopIPCTraceName(event),
		"thread=" + desktopIPCTraceIdentifier(threadID),
		"turn=" + desktopIPCTraceIdentifier(turnID),
	}
	for index := 0; index+1 < len(fields); index += 2 {
		key := desktopIPCTraceName(fields[index])
		value := gatewayCompactLogToken(fields[index+1])
		if strings.HasSuffix(key, "id") {
			value = desktopIPCTraceIdentifier(fields[index+1])
		}
		parts = append(parts, key+"="+value)
	}
	// 这条 Trace 只记录协议阶段、脱敏关联标识、状态和耗时；不记录提示词、
	// command、cwd、socket、IPC client ID 或原始 conversationState。
	log.Printf("desktop_ipc_trace %s", strings.Join(parts, " "))
}

func desktopIPCTraceIdentifier(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "absent"
	}
	digest := sha256.Sum256([]byte(value))
	return fmt.Sprintf("%x", digest[:4])
}

func desktopIPCPolicyError(id *json.RawMessage, err error) *appServerGatewayPolicyError {
	delivery := desktopipc.DeliveryUncertain
	var requestErr *desktopipc.RequestError
	if errors.As(err, &requestErr) {
		delivery = requestErr.Delivery
	}
	return &appServerGatewayPolicyError{
		id: id, message: "Codex Desktop 会话同步暂时无法确认操作结果", target: "client",
		data: map[string]any{
			"reason": "desktop_sync_delivery_uncertain", "accepted": nil, "retryable": true,
			"delivery": string(delivery),
		},
	}
}

func desktopIPCActiveTurnError(id *json.RawMessage, activeTurnID string) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id: id, message: "Codex Desktop 当前 Turn 仍在运行；请等待完成或使用调整方向", target: "client",
		data: map[string]any{
			"reason": "desktop_sync_active_turn", "accepted": false, "retryable": true,
			"active_turn_id": activeTurnID,
		},
	}
}

func desktopIPCActiveTurnUnconfirmedError(id *json.RawMessage) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id: id, message: "Codex Desktop 当前活跃 Turn 尚未确认", target: "client",
		data: map[string]any{
			"reason": "desktop_sync_active_turn_unconfirmed", "accepted": false, "retryable": true,
		},
	}
}

func desktopIPCTurnsListUnsupportedError(id *json.RawMessage) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id: id, message: "thread/turns/list is not supported by Desktop sync；请回退 thread/read", target: "client",
		data: map[string]any{
			"reason": "desktop_sync_method_unsupported", "accepted": false, "retryable": false,
			"method": "thread/turns/list",
		},
	}
}

func desktopIPCOwnerUnknownError(id *json.RawMessage, _ error) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id: id, message: "Codex Desktop 会话所有权暂时无法确认", target: "client",
		data: map[string]any{
			"reason": "desktop_sync_owner_unknown", "accepted": false, "retryable": true,
		},
	}
}

func desktopIPCSnapshotUnavailableError(id *json.RawMessage) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id: id, message: "Codex Desktop 尚未提供完整会话快照", target: "client",
		data: map[string]any{
			"reason": "desktop_sync_snapshot_unavailable", "accepted": false, "retryable": true,
		},
	}
}

func desktopIPCWorkspaceMismatchError(id *json.RawMessage) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id: id, message: "Codex Desktop 会话工作区与当前授权不一致", target: "client",
		data: map[string]any{
			"reason": "desktop_sync_workspace_mismatch", "accepted": false, "retryable": false,
		},
	}
}

func desktopIPCMethodCanDiscoverOwner(method string) bool {
	switch method {
	case "thread/resume", "thread/read", "thread/turns/list", "thread/goal/get",
		"turn/start", "turn/steer", "turn/interrupt", "thread/compact/start":
		return true
	default:
		return desktopIPCMethodWritesThread(method)
	}
}

func desktopIPCMethodWritesThread(method string) bool {
	switch method {
	case "thread/fork", "thread/name/set", "thread/archive", "thread/unarchive",
		"thread/goal/set", "thread/goal/clear", "review/start", "thread/compact/start",
		"turn/start", "turn/steer", "turn/interrupt":
		return true
	default:
		return false
	}
}

func desktopIPCMethodClaimsLocalOwner(method string) bool {
	return desktopIPCMethodWritesThread(method)
}

func rawGatewayID(id *json.RawMessage) any {
	if id == nil {
		return nil
	}
	var value any
	decoder := json.NewDecoder(strings.NewReader(string(*id)))
	decoder.UseNumber()
	if decoder.Decode(&value) == nil {
		return value
	}
	return nil
}

func firstAny(value map[string]any, keys ...string) any {
	for _, key := range keys {
		if result, ok := value[key]; ok {
			return result
		}
	}
	return nil
}

func scalarRequestIDKey(value any) string {
	payload, _ := json.Marshal(value)
	raw := json.RawMessage(payload)
	return gatewayRequestIDKey(&raw)
}

func firstStringFromAnyMap(value map[string]any, keys ...string) string {
	for _, key := range keys {
		if result, ok := value[key].(string); ok && strings.TrimSpace(result) != "" {
			return strings.TrimSpace(result)
		}
	}
	return ""
}

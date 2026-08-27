package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	nextRequestID   atomic.Uint64

	mu                  sync.Mutex
	pendingActions      map[string]desktopipc.ServerRequest
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
	return &desktopIPCGatewayOverlay{
		bridge: bridge, policy: policy, upstream: upstream, upstreamWriteMu: upstreamWriteMu,
		ownerID: fmt.Sprintf("gateway-%p", policy), local: desktopipc.NewLocalConversation(),
		pendingActions:      make(map[string]desktopipc.ServerRequest),
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
		desktopipc.StateUnsupportedBuild, desktopipc.StateLegacyCleanupRequired:
		return false
	default:
		return true
	}
}

func (o *desktopIPCGatewayOverlay) close() {
	if o == nil || o.bridge == nil {
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
	if !o.enabled() {
		return false, nil, nil
	}
	status := o.bridge.Status()
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return false, nil, nil
	}
	if strings.TrimSpace(frame.Method) == "" && frame.ID != nil {
		return o.routeServerRequestResponse(ctx, frame, payload)
	}
	method := strings.TrimSpace(frame.Method)
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return true, nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error(), target: "client"}
	}
	threadID, _ := gatewayStringParam(params, "threadId")
	if threadID == "" {
		return false, nil, nil
	}
	if o.bridge.HasLocalOwner(threadID) {
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
			if err := o.ensureLocalOwner(threadID); err != nil {
				return true, nil, &appServerGatewayPolicyError{
					id: frame.ID, message: err.Error(), target: "client",
					data: map[string]any{"reason": "desktop_sync_owner_conflict", "accepted": false, "retryable": true},
				}
			}
		}
		return false, nil, nil
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
		return o.syntheticResult(frame.ID, desktopTurnsListResult(projection.Turns, params))
	case "thread/unsubscribe":
		return o.syntheticResult(frame.ID, map[string]any{})
	case "turn/start":
		if err := o.syncDesktopThreadSettings(ctx, threadID, params); err != nil {
			if desktopipc.SafeToFallback(err) {
				return o.fallbackToLocalOwner(threadID, frame.ID)
			}
			return true, nil, desktopIPCPolicyError(frame.ID, err)
		}
		return o.desktopFollowerResult(ctx, frame.ID, "thread-follower-start-turn", map[string]any{
			"conversationId": threadID,
			"turnStart": map[string]any{
				"request": params,
				"context": map[string]any{"inheritThreadSettings": true},
			},
		})
	case "turn/steer":
		return o.desktopFollowerResult(ctx, frame.ID, "thread-follower-steer-turn", map[string]any{
			"conversationId":      threadID,
			"input":               params["input"],
			"restoreMessage":      params["restoreMessage"],
			"serviceTier":         firstAny(params, "serviceTier", "service_tier"),
			"attachments":         params["attachments"],
			"clientUserMessageId": params["clientUserMessageId"],
			"additionalContext":   params["additionalContext"],
		})
	case "turn/interrupt":
		return o.desktopFollowerResult(ctx, frame.ID, "thread-follower-interrupt-turn", map[string]any{
			"conversationId": threadID,
			"mode":           "user-stop",
			"expectedTurnId": params["turnId"],
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

func (o *desktopIPCGatewayOverlay) discoverDesktopOwner(ctx context.Context, threadID string) (desktopipc.Projection, bool, error) {
	if err := o.bridge.FollowThread(ctx, threadID); err != nil {
		return desktopipc.Projection{}, false, err
	}
	if _, projected := o.bridge.DesktopProjection(threadID); !projected {
		// Desktop 7119 waits up to 10 seconds for all connected clients to reject an
		// owner probe before it returns the only safe fallback signal: no-client-found.
		discoveryCtx, discoveryCancel := context.WithTimeout(ctx, desktopIPCOwnerDiscoveryWait)
		owned, err := o.bridge.DiscoverDesktopOwner(discoveryCtx, threadID)
		discoveryCancel()
		if err != nil {
			return desktopipc.Projection{}, false, err
		}
		if !owned {
			o.bridge.ReleaseDesktopOwner(threadID)
			return desktopipc.Projection{}, false, nil
		}
	}
	history, err := o.bridge.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		if desktopipc.SafeToFallback(err) {
			o.bridge.ReleaseDesktopOwner(threadID)
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
	if ok {
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
	o.bridge.ReleaseDesktopOwner(threadID)
	if err := o.ensureLocalOwner(threadID); err != nil {
		return true, nil, &appServerGatewayPolicyError{
			id: id, message: err.Error(), target: "client",
			data: map[string]any{"reason": "desktop_sync_owner_conflict", "accepted": false, "retryable": true},
		}
	}
	return false, nil, nil
}

func (o *desktopIPCGatewayOverlay) ensureLocalOwner(threadID string) error {
	if o.bridge.HasLocalOwner(threadID) {
		if o.bridge.LocalOwnerIs(threadID, o.ownerID) {
			return nil
		}
		return fmt.Errorf("thread already has an active writer")
	}
	if err := o.bridge.ClaimLocalOwner(threadID, o.ownerID, o.handleDesktopFollowerRequest); err != nil {
		return err
	}
	o.mu.Lock()
	o.ownedThreads[threadID] = struct{}{}
	o.mu.Unlock()
	return nil
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
	if method == "thread/read" || method == "thread/resume" || method == "thread/turns/list" || method == "thread/goal/get" {
		projection, ok := o.bridge.LocalProjection(threadID)
		if !ok {
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
		case "thread/turns/list":
			return o.syntheticResult(id, desktopTurnsListResult(projection.Turns, params))
		case "thread/goal/get":
			return o.syntheticResult(id, map[string]any{"goal": nil})
		default:
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
			"conversationId": threadID, "input": params["input"],
			"restoreMessage": params["restoreMessage"], "serviceTier": firstAny(params, "serviceTier", "service_tier"),
			"attachments": params["attachments"], "clientUserMessageId": params["clientUserMessageId"],
			"additionalContext": params["additionalContext"],
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
	result, err := o.bridge.RequestDesktopOwner(ctx, method, params)
	if err != nil {
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

func (o *desktopIPCGatewayOverlay) syncDesktopThreadSettings(
	ctx context.Context,
	threadID string,
	params map[string]any,
) error {
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
	_, err := o.bridge.RequestDesktopOwner(ctx, "thread-follower-update-thread-settings", map[string]any{
		"conversationId": threadID, "threadSettings": settings,
	})
	return err
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
		if !desktopIPCMethodWritesThread(forwardMethod) {
			return nil, fmt.Errorf("unsupported local owner method %q", forwardMethod)
		}
		result, err := o.requestUpstream(ctx, forwardMethod, cloneAnyMap(forwardParams))
		if err != nil {
			return nil, err
		}
		if forwardMethod == "thread/fork" {
			o.seedFromGatewayResult("", result)
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
			revision, publishErr := o.bridge.ForcePublishLocalConversation(threadID, state)
			if publishErr != nil {
				return nil, publishErr
			}
			return map[string]any{"revision": revision}, nil
		}
		state, ok := o.local.State(threadID)
		if !ok {
			return nil, err
		}
		revision, publishErr := o.bridge.ForcePublishLocalConversation(threadID, state)
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
		return o.requestUpstreamDecoded(ctx, "turn/steer", map[string]any{
			"threadId": threadID, "input": params["input"], "expectedTurnId": params["expectedTurnId"],
		})
	case "thread-follower-interrupt-turn":
		return o.requestUpstreamDecoded(ctx, "turn/interrupt", map[string]any{
			"threadId": threadID, "turnId": params["expectedTurnId"],
		})
	case "thread-follower-compact-thread":
		return o.requestUpstreamDecoded(ctx, "thread/compact/start", map[string]any{"threadId": threadID})
	case "thread-follower-update-thread-settings":
		settings, _ := params["threadSettings"].(map[string]any)
		o.rememberLocalSettings(threadID, settings)
		return map[string]any{}, nil
	case "thread-follower-command-approval-decision":
		return o.forwardDesktopServerRequestResponse(threadID, params, map[string]any{"decision": params["decision"]})
	case "thread-follower-file-approval-decision":
		return o.forwardDesktopServerRequestResponse(threadID, params, map[string]any{"decision": params["decision"]})
	case "thread-follower-permissions-request-approval-response",
		"thread-follower-submit-user-input", "thread-follower-submit-mcp-server-elicitation-response":
		response, _ := params["response"].(map[string]any)
		return o.forwardDesktopServerRequestResponse(threadID, params, response)
	default:
		return nil, fmt.Errorf("unsupported Desktop follower request %q", method)
	}
}

func (o *desktopIPCGatewayOverlay) requestUpstream(ctx context.Context, method string, params map[string]any) (json.RawMessage, error) {
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
	waiter := make(chan desktopIPCUpstreamResult, 1)
	o.mu.Lock()
	o.pendingUpstream[idKey] = waiter
	o.mu.Unlock()
	if err := writeWebSocketFrame(o.upstream, o.upstreamWriteMu, websocket.TextMessage, payload); err != nil {
		o.mu.Lock()
		delete(o.pendingUpstream, idKey)
		o.mu.Unlock()
		o.policy.cancelPendingHistoryRequest(&idRaw)
		o.policy.forgetPending(&idRaw)
		return nil, err
	}
	select {
	case result := <-waiter:
		return result.result, result.err
	case <-ctx.Done():
		// Delivery is uncertain. Keep a short-lived tombstone so a late App Server
		// response is consumed instead of leaking to the mobile JSON-RPC client.
		time.AfterFunc(desktopIPCUpstreamLateResponseWindow, func() {
			o.mu.Lock()
			removed := false
			if o.pendingUpstream[idKey] == waiter {
				delete(o.pendingUpstream, idKey)
				removed = true
			}
			o.mu.Unlock()
			if removed {
				o.policy.cancelPendingHistoryRequest(&idRaw)
				o.policy.forgetPending(&idRaw)
			}
		})
		return nil, ctx.Err()
	}
}

func (o *desktopIPCGatewayOverlay) requestUpstreamDecoded(ctx context.Context, method string, params map[string]any) (any, error) {
	result, err := o.requestUpstream(ctx, method, params)
	if err != nil {
		return nil, err
	}
	return decodeRawGatewayResult(result), nil
}

func (o *desktopIPCGatewayOverlay) forwardDesktopServerRequestResponse(
	threadID string,
	params map[string]any,
	response map[string]any,
) (any, error) {
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
	payload, policyErr := o.policy.validateClientFrameContext(context.Background(), websocket.TextMessage, payload)
	if policyErr != nil {
		return nil, fmt.Errorf("Gateway policy rejected Desktop follower response: %s", policyErr.message)
	}
	if err := writeWebSocketFrame(o.upstream, o.upstreamWriteMu, websocket.TextMessage, payload); err != nil {
		pendingID, _ := json.Marshal(pending.id)
		pendingIDRaw := json.RawMessage(pendingID)
		pendingParams, _ := json.Marshal(pending.params)
		_ = o.policy.rememberPendingServerRequest(&pendingIDRaw, pending.method, pendingParams)
		return nil, err
	}
	o.mu.Lock()
	delete(o.localServerRequests, key)
	o.mu.Unlock()
	if state, changed := o.local.ResolveRequest(threadID, pending.id); changed {
		_ = o.bridge.PublishLocalConversation(threadID, state)
	}
	return map[string]any{}, nil
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
	o.mu.Lock()
	settings := cloneAnyMap(o.localSettings[threadID])
	o.mu.Unlock()
	for key, value := range settings {
		params[key] = value
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
	o.mu.Unlock()
	if !ok {
		return false, nil, nil
	}
	var response map[string]any
	if json.Unmarshal(payload, &response) != nil || response["error"] != nil {
		return true, nil, &appServerGatewayPolicyError{
			id: frame.ID, message: "Desktop sync 不接受失败的审批响应", target: "client",
			data: map[string]any{"reason": "desktop_sync_response_unsupported", "accepted": false},
		}
	}
	method, params, err := desktopFollowerResponse(action, response["result"])
	if err != nil {
		return true, nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error(), target: "client"}
	}
	_, requestErr := o.bridge.RequestDesktopOwner(ctx, method, params)
	if requestErr != nil {
		actionParams, _ := json.Marshal(action.Params)
		actionID, _ := json.Marshal(action.ID)
		actionIDRaw := json.RawMessage(actionID)
		_ = o.policy.rememberPendingServerRequest(&actionIDRaw, action.Method, actionParams)
		return true, nil, desktopIPCPolicyError(frame.ID, requestErr)
	}
	o.mu.Lock()
	delete(o.pendingActions, key)
	o.mu.Unlock()
	// Responses to server requests are fire-and-forget on the App Server wire.
	return true, nil, nil
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
	if !o.enabled() {
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
				_ = o.bridge.PublishLocalConversation(pending.threadID, state)
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
	if strings.TrimSpace(frame.Method) == "thread/start" {
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
	if !o.enabled() {
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

// observeAcceptedUpstreamFrame mirrors only Gateway-policy-approved App Server
// responses and lifecycle messages into Desktop state.
func (o *desktopIPCGatewayOverlay) observeAcceptedUpstreamFrame(payload []byte) {
	if !o.enabled() {
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
			o.seedFromGatewayResult(forwarded.threadID, frame.Result)
		}
		return
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return
	}
	if frame.ID != nil {
		threadID, state, changed := o.local.RememberRequest(rawGatewayID(frame.ID), method, params)
		if changed {
			o.mu.Lock()
			o.localServerRequests[gatewayRequestIDKey(frame.ID)] = desktopIPCServerRequest{
				id: rawGatewayID(frame.ID), method: method, threadID: threadID, params: cloneAnyMap(params),
			}
			o.mu.Unlock()
			_ = o.bridge.PublishLocalConversation(threadID, state)
		}
		return
	}
	threadID, state, changed := o.local.Apply(method, params)
	if changed {
		_ = o.ensureLocalOwner(threadID)
		_ = o.bridge.PublishLocalConversation(threadID, state)
	}
}

func (o *desktopIPCGatewayOverlay) seedFromGatewayResult(expectedThreadID string, result json.RawMessage) {
	thread, err := threadFromGatewayResult(result)
	if err != nil {
		return
	}
	threadID, state, err := o.local.SeedThread(thread)
	if err != nil || (expectedThreadID != "" && threadID != expectedThreadID) {
		return
	}
	if o.ensureLocalOwner(threadID) == nil {
		_ = o.bridge.PublishLocalConversation(threadID, state)
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
			messages := desktopipc.ProjectionMessages(event.ThreadID, event.Previous, event.Projection)
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
		}
	}
	for key, request := range next {
		if _, exists := o.pendingActions[key]; exists {
			continue
		}
		o.pendingActions[key] = request
		messages = append(messages, desktopipc.AppServerMessage{ID: request.ID, Method: request.Method, Params: request.Params})
	}
	return messages
}

func desktopTurnsListResult(turns []any, params map[string]any) map[string]any {
	ordered := append([]any(nil), turns...)
	direction := strings.ToLower(firstStringFromAnyMap(params, "sortDirection"))
	if direction != "asc" {
		for left, right := 0, len(ordered)-1; left < right; left, right = left+1, right-1 {
			ordered[left], ordered[right] = ordered[right], ordered[left]
		}
	}
	limit := appServerGatewayThreadTurnsDefaultLimit
	if number, ok := params["limit"].(json.Number); ok {
		if value, err := number.Int64(); err == nil && value > 0 {
			limit = int(value)
		}
	} else if number, ok := params["limit"].(float64); ok && number > 0 {
		limit = int(number)
	}
	if len(ordered) > limit {
		ordered = ordered[:limit]
	}
	return map[string]any{"data": ordered, "nextCursor": nil, "hasMore": false, "mimiDesktopIPCMirror": true}
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

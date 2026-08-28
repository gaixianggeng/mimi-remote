package desktopipc

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

var desktopFollowProcessNonce = newDesktopFollowProcessNonce()

const (
	desktopFollowMaterializationWait = 5 * time.Second
	desktopFollowConfirmWait         = 1500 * time.Millisecond
	desktopFollowStatusWait          = 150 * time.Millisecond
	desktopFollowPollInterval        = 50 * time.Millisecond
	desktopFollowMaxAttempts         = 3
)

// DesktopThreadActivator mounts one exact Codex Desktop route. The nonce keeps
// repeated activation attempts observable by Desktop even when the same Thread
// is already selected.
type DesktopThreadActivator func(context.Context, string, string) error

// ActivateLocalThread mounts an already-materialized Mimi-owned Thread.
func (b *Bridge) ActivateLocalThread(threadID, ownerID string) error {
	return b.activateLocalThread(threadID, ownerID, false)
}

// ActivateNewLocalThread waits for a newly-created rollout before mounting it.
func (b *Bridge) ActivateNewLocalThread(threadID, ownerID string) error {
	return b.activateLocalThread(threadID, ownerID, true)
}

// activateLocalThread records the most recent route even while Desktop is
// closed or connecting. Once IPC becomes ready, only that route is mounted;
// Mimi's App Server remains the sole writer throughout.
func (b *Bridge) activateLocalThread(threadID, ownerID string, waitForMaterialization bool) error {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	if threadID == "" || ownerID == "" {
		return fmt.Errorf("local Desktop follow identity is incomplete")
	}
	if b.activateDesktopThread == nil {
		return nil
	}
	requestedAt := time.Now()
	b.mu.Lock()
	owner := b.owners[threadID]
	if owner.kind != threadOwnerMimi || owner.ownerID != ownerID {
		b.mu.Unlock()
		return fmt.Errorf("Mimi owner lease does not match this thread")
	}
	ownerEpoch := b.ownerEpochs[threadID]
	intent := b.latestLocalFollowIntent
	sameIntentOwner := intent.threadID == threadID && intent.ownerID == ownerID && intent.ownerEpoch == ownerEpoch
	intentChanged := !sameIntentOwner || intent.waitForMaterialization && !waitForMaterialization
	if intentChanged {
		b.nextLocalFollowIntent++
		intent = localFollowIntent{
			token: b.nextLocalFollowIntent, threadID: threadID, ownerID: ownerID,
			ownerEpoch: ownerEpoch, waitForMaterialization: waitForMaterialization,
		}
		b.latestLocalFollowIntent = intent
		// Desktop has one foreground route. A newer intent makes every older
		// activation ineligible before it can open another Thread.
		b.localFollowActivations = make(map[string]localFollowActivation)
	}
	generation := b.connectionGeneration
	activation, started := b.startLocalFollowActivationLocked(intent, generation)
	ready := generation != 0 && b.connectionGeneration == generation &&
		b.client.ConnectionGeneration() == generation
	alreadyFollowing := owner.confirmedFollowerID != ""
	b.mu.Unlock()
	if intentChanged || started {
		reason := "existing_thread"
		if waitForMaterialization {
			reason = "new_thread"
		}
		desktopRouteTrace(desktopRouteTraceRequested, threadID, 0, reason, 0)
	}
	if started {
		_ = b.launchLocalFollowActivation(threadID, activation)
	} else if intentChanged {
		switch {
		case alreadyFollowing:
			desktopRouteTrace(desktopRouteTraceFollowingConfirmed, threadID, 0, "already_following", time.Since(requestedAt))
		case !ready:
			desktopRouteTrace(
				desktopRouteTraceDeferred,
				threadID,
				0,
				desktopRouteStateReason(b.client.Status().State),
				time.Since(requestedAt),
			)
		}
	}
	return nil
}

// startLocalFollowActivationLocked starts only the exact latest intent. Ready
// recovery uses this compare-and-start path so an older captured intent cannot
// replace a newer foreground route.
func (b *Bridge) startLocalFollowActivationLocked(
	intent localFollowIntent,
	generation uint64,
) (localFollowActivation, bool) {
	if intent.token == 0 || b.latestLocalFollowIntent != intent || generation == 0 ||
		b.connectionGeneration != generation || b.client.ConnectionGeneration() != generation {
		return localFollowActivation{}, false
	}
	owner := b.owners[intent.threadID]
	if owner.kind != threadOwnerMimi || owner.ownerID != intent.ownerID ||
		b.ownerEpochs[intent.threadID] != intent.ownerEpoch || owner.confirmedFollowerID != "" {
		return localFollowActivation{}, false
	}
	if pending, ok := b.localFollowActivations[intent.threadID]; ok &&
		pending.intentToken == intent.token && pending.ownerID == intent.ownerID &&
		pending.ownerEpoch == intent.ownerEpoch && pending.connectionGeneration == generation {
		return localFollowActivation{}, false
	}
	b.nextLocalFollowToken++
	activation := localFollowActivation{
		token:                  b.nextLocalFollowToken,
		intentToken:            intent.token,
		ownerID:                intent.ownerID,
		ownerEpoch:             intent.ownerEpoch,
		connectionGeneration:   generation,
		waitForMaterialization: intent.waitForMaterialization,
	}
	b.localFollowActivations[intent.threadID] = activation
	return activation, true
}

func (b *Bridge) launchLocalFollowActivation(threadID string, activation localFollowActivation) <-chan struct{} {
	broadcastDone := make(chan struct{})
	if current, _ := b.localFollowActivationState(threadID, activation); !current {
		close(broadcastDone)
		return broadcastDone
	}
	go func() {
		// Recheck the lease after scheduling. A newer route or connection may
		// have made this activation stale before the background path started.
		if current, _ := b.localFollowActivationState(threadID, activation); !current {
			close(broadcastDone)
			return
		}
		// 已挂载的 renderer 可以直接回答状态，不必触发可见导航。广播必须
		// 先于路由激活，但两者都放在后台路径，避免 Desktop 读取慢时阻塞调用者。
		_ = b.client.BroadcastGeneration("thread-stream-following-status-requested", map[string]any{
			"hostId": "local", "conversationId": threadID,
		}, activation.connectionGeneration)
		close(broadcastDone)
		b.runLocalFollowActivation(threadID, activation)
	}()
	return broadcastDone
}

func (b *Bridge) runLocalFollowActivation(threadID string, activation localFollowActivation) {
	activationStartedAt := time.Now()
	ctx, cancel := context.WithTimeout(
		b.activationCtx,
		desktopFollowMaterializationWait+desktopFollowStatusWait+
			desktopFollowConfirmWait*desktopFollowMaxAttempts+time.Second,
	)
	defer cancel()
	defer b.finishLocalFollowActivation(threadID, activation)

	if b.waitForLocalFollower(ctx, threadID, activation, desktopFollowStatusWait) {
		desktopRouteTrace(desktopRouteTraceFollowingConfirmed, threadID, 0, "already_following", time.Since(activationStartedAt))
		return
	}
	if activation.waitForMaterialization {
		b.waitForLocalRollout(ctx, threadID, activation)
	}
	if current, followed := b.localFollowActivationState(threadID, activation); !current {
		return
	} else if followed {
		desktopRouteTrace(desktopRouteTraceFollowingConfirmed, threadID, 0, "already_following", time.Since(activationStartedAt))
		return
	}
	exhaustedReason := "following_confirmation_timeout"
	for attempt := 1; attempt <= desktopFollowMaxAttempts; attempt++ {
		current, followed := b.localFollowActivationState(threadID, activation)
		if !current {
			return
		}
		if followed {
			desktopRouteTrace(desktopRouteTraceFollowingConfirmed, threadID, attempt-1, "already_following", time.Since(activationStartedAt))
			return
		}
		nonce := desktopFollowNonce(activation.token, attempt)
		// Codex Desktop has one foreground navigation surface. Serialize the
		// actual route dispatch and recheck the lease after waiting so two Mimi
		// Threads cannot issue competing deep links at the same time.
		b.localFollowRouteMu.Lock()
		current, followed = b.localFollowActivationState(threadID, activation)
		if !current {
			b.localFollowRouteMu.Unlock()
			return
		}
		if followed {
			b.localFollowRouteMu.Unlock()
			desktopRouteTrace(desktopRouteTraceFollowingConfirmed, threadID, attempt-1, "already_following", time.Since(activationStartedAt))
			return
		}
		attemptStartedAt := time.Now()
		err := b.activateDesktopThread(ctx, threadID, nonce)
		b.localFollowRouteMu.Unlock()
		if err != nil {
			exhaustedReason = desktopRouteDeferredReason(err)
			desktopRouteTrace(desktopRouteTraceDeferred, threadID, attempt, exhaustedReason, time.Since(attemptStartedAt))
		} else {
			exhaustedReason = "following_confirmation_timeout"
			desktopRouteTrace(desktopRouteTraceOpened, threadID, attempt, "", time.Since(attemptStartedAt))
		}
		if b.waitForLocalFollower(ctx, threadID, activation, desktopFollowConfirmWait) {
			desktopRouteTrace(desktopRouteTraceFollowingConfirmed, threadID, attempt, "", time.Since(attemptStartedAt))
			return
		}
		if err == nil {
			desktopRouteTrace(desktopRouteTraceConfirmationTimeout, threadID, attempt, "following_not_confirmed", time.Since(attemptStartedAt))
		}
	}
	desktopRouteTrace(desktopRouteTraceExhausted, threadID, desktopFollowMaxAttempts, exhaustedReason, time.Since(activationStartedAt))
}

func newDesktopFollowProcessNonce() string {
	var value [8]byte
	if _, err := rand.Read(value[:]); err == nil {
		return fmt.Sprintf("%x", value[:])
	}
	return fmt.Sprintf("%x", time.Now().UnixNano())
}

func desktopFollowNonce(token uint64, attempt int) string {
	return fmt.Sprintf("%s-%d-%d", desktopFollowProcessNonce, token, attempt)
}

func (b *Bridge) waitForLocalRollout(ctx context.Context, threadID string, activation localFollowActivation) {
	deadline := time.NewTimer(desktopFollowMaterializationWait)
	ticker := time.NewTicker(desktopFollowPollInterval)
	deferredLogged := false
	defer deadline.Stop()
	defer ticker.Stop()
	for {
		current, followed := b.localFollowActivationState(threadID, activation)
		if !current || followed {
			return
		}
		b.mu.RLock()
		stream, ok := b.localStreams[threadID]
		b.mu.RUnlock()
		if ok {
			rolloutPath := strings.TrimSpace(stringValue(stream.state["rolloutPath"]))
			if rolloutPath != "" {
				if info, err := os.Stat(rolloutPath); err == nil && info.Mode().IsRegular() {
					return
				} else if err != nil && !errors.Is(err, os.ErrNotExist) {
					return
				}
			}
		}
		if !deferredLogged {
			deferredLogged = true
			desktopRouteTrace(desktopRouteTraceDeferred, threadID, 0, "materialization_pending", 0)
		}
		select {
		case <-ctx.Done():
			return
		case <-deadline.C:
			// Match Remodex's bounded fallback: a delayed catalog must not prevent
			// all future route activation attempts.
			return
		case <-ticker.C:
		}
	}
}

func (b *Bridge) waitForLocalFollower(
	ctx context.Context,
	threadID string,
	activation localFollowActivation,
	wait time.Duration,
) bool {
	deadline := time.NewTimer(wait)
	ticker := time.NewTicker(desktopFollowPollInterval)
	defer deadline.Stop()
	defer ticker.Stop()
	for {
		current, followed := b.localFollowActivationState(threadID, activation)
		if !current {
			return false
		}
		if followed {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-deadline.C:
			return false
		case <-ticker.C:
		}
	}
}

func (b *Bridge) localFollowActivationState(
	threadID string,
	activation localFollowActivation,
) (bool, bool) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	current, ok := b.localFollowActivations[threadID]
	owner := b.owners[threadID]
	intent := b.latestLocalFollowIntent
	leaseCurrent := ok && current == activation && owner.kind == threadOwnerMimi &&
		owner.ownerID == activation.ownerID && b.ownerEpochs[threadID] == activation.ownerEpoch &&
		intent.token == activation.intentToken && intent.threadID == threadID &&
		b.connectionGeneration == activation.connectionGeneration &&
		b.client.ConnectionGeneration() == activation.connectionGeneration
	if !leaseCurrent {
		return false, false
	}
	return true, owner.confirmedFollowerID != ""
}

func (b *Bridge) finishLocalFollowActivation(threadID string, activation localFollowActivation) {
	b.mu.Lock()
	if current, ok := b.localFollowActivations[threadID]; ok && current == activation {
		delete(b.localFollowActivations, threadID)
	}
	b.mu.Unlock()
}

func (b *Bridge) handleFollowingChanged(broadcast Broadcast) {
	if expected, ok := MethodVersion(broadcast.Method); !ok || broadcast.Version != expected {
		b.client.status.update(func(status *Status) { status.State = StateProtocolError })
		return
	}
	if broadcast.ConnectionGeneration == 0 ||
		broadcast.ConnectionGeneration != b.client.ConnectionGeneration() {
		return
	}
	var params struct {
		ConversationID string `json:"conversationId"`
		Following      bool   `json:"following"`
	}
	if json.Unmarshal(broadcast.Params, &params) != nil || strings.TrimSpace(params.ConversationID) == "" {
		return
	}
	threadID := strings.TrimSpace(params.ConversationID)
	clientID := strings.TrimSpace(broadcast.SourceClientID)
	if clientID == "" || clientID == b.client.ClientID() {
		return
	}
	b.mu.Lock()
	if b.connectionGeneration != broadcast.ConnectionGeneration {
		b.mu.Unlock()
		return
	}
	owner := b.owners[threadID]
	if owner.kind != threadOwnerMimi || owner.handle == nil {
		b.mu.Unlock()
		return
	}
	if !params.Following {
		if owner.confirmedFollowerID == clientID {
			owner.confirmedFollowerID = ""
		}
		if owner.followerClientID == clientID {
			if _, pending := b.localInFlight[threadID]; pending {
				b.localUncertain[threadID] = true
			}
			owner.followerClientID = ""
		}
		b.owners[threadID] = owner
		b.mu.Unlock()
		return
	}
	if owner.followerClientID != "" && owner.followerClientID != clientID {
		if _, pending := b.localInFlight[threadID]; pending {
			b.localUncertain[threadID] = true
		}
	}
	owner.followerClientID = clientID
	owner.confirmedFollowerID = clientID
	b.owners[threadID] = owner
	ownerID := owner.ownerID
	b.mu.Unlock()
	_, _ = b.ForceRepublishLocalConversation(threadID, ownerID)
}

func (b *Bridge) handleClientStatusChanged(broadcast Broadcast) {
	if expected, ok := MethodVersion(broadcast.Method); !ok || broadcast.Version != expected {
		return
	}
	if broadcast.ConnectionGeneration == 0 ||
		broadcast.ConnectionGeneration != b.client.ConnectionGeneration() {
		return
	}
	var params struct {
		ClientID string `json:"clientId"`
		Status   string `json:"status"`
	}
	if json.Unmarshal(broadcast.Params, &params) != nil ||
		!strings.EqualFold(strings.TrimSpace(params.Status), "disconnected") {
		return
	}
	clientID := strings.TrimSpace(params.ClientID)
	if clientID == "" {
		clientID = strings.TrimSpace(broadcast.SourceClientID)
	}
	if clientID == "" {
		return
	}
	b.mu.Lock()
	if b.connectionGeneration != broadcast.ConnectionGeneration {
		b.mu.Unlock()
		return
	}
	for threadID, owner := range b.owners {
		if owner.kind != threadOwnerMimi || owner.followerClientID != clientID {
			continue
		}
		if _, pending := b.localInFlight[threadID]; pending {
			b.localUncertain[threadID] = true
		}
		owner.followerClientID = ""
		owner.confirmedFollowerID = ""
		b.owners[threadID] = owner
	}
	b.mu.Unlock()
}

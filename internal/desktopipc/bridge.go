package desktopipc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"
)

type ThreadEvent struct {
	ThreadID         string
	Projection       Projection
	Previous         *Projection
	Requests         []ServerRequest
	Stale            bool
	HistoryConfirmed bool
}

type ServerRequest struct {
	ID     any
	Method string
	Params map[string]any
}

type LocalOwnerHandler func(context.Context, string, json.RawMessage) (any, error)

type BridgeOptions struct {
	Enabled               bool
	SocketPath            string
	DesktopVersion        string
	DesktopBuild          string
	LegacyCleanupRequired bool
	InitialState          State
	ClientOptions         ClientOptions
}

type threadOwnerKind uint8

const (
	threadOwnerDesktop threadOwnerKind = iota + 1
	threadOwnerMimi
)

type threadOwner struct {
	kind                 threadOwnerKind
	ownerID              string
	handle               LocalOwnerHandler
	connectionGeneration uint64
	followerClientID     string
}

type localStream struct {
	revision    int64
	state       map[string]any
	broadcasted bool
}

var ErrDesktopStartInFlight = errors.New("Desktop start is already pending or uncertain")
var ErrDesktopDeliveryUncertain = errors.New("Desktop delivery is uncertain; complete history is required")

type desktopStartReservation struct {
	token                uint64
	ownerEpoch           uint64
	connectionGeneration uint64
	baselineTurnIDs      map[string]struct{}
	expectedTurnID       string
}

type localOwnerLease struct {
	threadID             string
	ownerID              string
	ownerEpoch           uint64
	connectionGeneration uint64
	followerClientID     string
}

type localOwnerClaimPermit struct {
	token                uint64
	ownerEpoch           uint64
	connectionGeneration uint64
}

type localRequestInFlight struct {
	requestID            string
	ownerID              string
	ownerEpoch           uint64
	connectionGeneration uint64
}

type desktopHistoryCheckpoint struct {
	token                uint64
	ownerID              string
	ownerEpoch           uint64
	connectionGeneration uint64
	uncertaintyEpoch     uint64
	startToken           uint64
	revision             int64
}

type localOwnerLeaseContextKey struct{}

// Bridge is the only Desktop IPC connection and ownership coordinator in an
// agentd process. Gateway connections subscribe to it instead of opening their
// own IPC clients.
type Bridge struct {
	client *Client
	store  *ThreadStore

	mu                      sync.RWMutex
	eventsMu                sync.Mutex
	projections             map[string]Projection
	owners                  map[string]threadOwner
	ownerEpochs             map[string]uint64
	subscribers             map[uint64]chan ThreadEvent
	nextSubID               uint64
	localStreams            map[string]localStream
	publishers              map[string]*sync.Mutex
	followed                map[string]struct{}
	refollow                map[string]struct{}
	resyncing               map[string]uint64
	desktopStarts           map[string]desktopStartReservation
	nextDesktopStart        uint64
	desktopHistory          map[string]desktopHistoryCheckpoint
	nextDesktopHistory      uint64
	desktopUncertaintyEpoch map[string]uint64
	incomingOps             map[string]*sync.Mutex
	localInFlight           map[string]localRequestInFlight
	localUncertain          map[string]bool
	desktopUncertain        map[string]bool
	localClaimPermits       map[string]localOwnerClaimPermit
	nextLocalClaimPermit    uint64
	connectionGeneration    uint64
}

func NewBridge(options BridgeOptions) (*Bridge, error) {
	bridge := &Bridge{
		store:                   NewThreadStore(),
		projections:             make(map[string]Projection),
		owners:                  make(map[string]threadOwner),
		ownerEpochs:             make(map[string]uint64),
		subscribers:             make(map[uint64]chan ThreadEvent),
		localStreams:            make(map[string]localStream),
		publishers:              make(map[string]*sync.Mutex),
		followed:                make(map[string]struct{}),
		refollow:                make(map[string]struct{}),
		resyncing:               make(map[string]uint64),
		desktopStarts:           make(map[string]desktopStartReservation),
		desktopHistory:          make(map[string]desktopHistoryCheckpoint),
		desktopUncertaintyEpoch: make(map[string]uint64),
		incomingOps:             make(map[string]*sync.Mutex),
		localInFlight:           make(map[string]localRequestInFlight),
		localUncertain:          make(map[string]bool),
		desktopUncertain:        make(map[string]bool),
		localClaimPermits:       make(map[string]localOwnerClaimPermit),
	}
	clientOptions := options.ClientOptions
	clientOptions.Enabled = options.Enabled && !options.LegacyCleanupRequired && options.InitialState == ""
	clientOptions.SocketPath = options.SocketPath
	clientOptions.DesktopVersion = options.DesktopVersion
	clientOptions.DesktopBuild = options.DesktopBuild
	clientOptions.OnBroadcast = bridge.handleBroadcast
	clientOptions.OnReady = bridge.handleReady
	clientOptions.OnDisconnect = bridge.handleDisconnect
	clientOptions.CanHandle = bridge.canHandleIncoming
	clientOptions.HandleRequest = bridge.handleIncoming
	clientOptions.OnResponseSent = bridge.handleIncomingResponse
	client, err := NewClient(clientOptions)
	if err != nil {
		return nil, err
	}
	bridge.client = client
	if options.LegacyCleanupRequired {
		bridge.client.status.update(func(status *Status) {
			status.Enabled = options.Enabled
			status.State = StateLegacyCleanupRequired
		})
	}
	if options.InitialState != "" {
		bridge.client.status.update(func(status *Status) {
			status.Enabled = options.Enabled
			status.State = options.InitialState
		})
	}
	return bridge, nil
}

func NewSystemBridge(enabled bool, legacyCleanupRequired bool, codexBin string, env map[string]string) (*Bridge, error) {
	if !enabled && !legacyCleanupRequired {
		return NewBridge(BridgeOptions{})
	}
	if legacyCleanupRequired {
		return NewBridge(BridgeOptions{Enabled: enabled, LegacyCleanupRequired: true})
	}
	info, err := InspectDesktop(codexBin, env)
	if err != nil {
		return NewBridge(BridgeOptions{Enabled: enabled, InitialState: StateProtocolError})
	}
	initialState := State("")
	if !info.Installed {
		initialState = StateNotInstalled
	}
	return NewBridge(BridgeOptions{
		Enabled: enabled, SocketPath: info.Socket,
		DesktopVersion: info.Version, DesktopBuild: info.Build,
		InitialState: initialState,
		ClientOptions: ClientOptions{
			Preflight: func() (State, error) {
				running, err := desktopRunning()
				if err != nil {
					return StateProtocolError, err
				}
				if !running {
					return StateDesktopNotRunning, nil
				}
				return StateConnecting, nil
			},
		},
	})
}

func (b *Bridge) Start(ctx context.Context) { b.client.Start(ctx) }
func (b *Bridge) Close()                    { b.client.Close() }
func (b *Bridge) Status() Status            { return b.client.Status() }

func (b *Bridge) Subscribe() (<-chan ThreadEvent, func()) {
	b.mu.Lock()
	b.nextSubID++
	id := b.nextSubID
	updates := make(chan ThreadEvent, 32)
	b.subscribers[id] = updates
	b.mu.Unlock()
	return updates, func() {
		b.mu.Lock()
		delete(b.subscribers, id)
		b.mu.Unlock()
	}
}

func (b *Bridge) FollowThread(_ context.Context, threadID string) error {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return fmt.Errorf("thread id is required")
	}
	generation := b.client.ConnectionGeneration()
	if err := b.client.BroadcastGeneration("thread-stream-following-changed", map[string]any{
		"hostId":         "local",
		"conversationId": threadID,
		"following":      true,
	}, generation); err != nil {
		return err
	}
	b.mu.Lock()
	if b.connectionGeneration != generation || generation == 0 {
		b.mu.Unlock()
		return fmt.Errorf("Desktop IPC connection generation changed while following thread")
	}
	b.followed[threadID] = struct{}{}
	b.mu.Unlock()
	return nil
}

func (b *Bridge) DiscoverDesktopOwner(ctx context.Context, threadID string) (bool, error) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return false, fmt.Errorf("thread id is required")
	}
	b.mu.RLock()
	startEpoch := b.ownerEpochs[threadID]
	startGeneration := b.connectionGeneration
	current := b.owners[threadID]
	b.mu.RUnlock()
	if current.kind == threadOwnerMimi {
		return false, fmt.Errorf("thread already has an active Mimi writer")
	}
	if startGeneration == 0 {
		return false, fmt.Errorf("Desktop IPC connection generation is unavailable")
	}
	ownerClientID, err := b.client.FindHandlerGeneration(ctx, "thread-owner-discovery", map[string]any{
		"hostId": "local", "conversationId": threadID,
	}, startGeneration)
	if err != nil {
		if SafeToFallback(err) {
			b.mu.Lock()
			defer b.mu.Unlock()
			current = b.owners[threadID]
			if b.connectionGeneration != startGeneration || b.ownerEpochs[threadID] != startEpoch {
				if current.kind == threadOwnerDesktop && current.connectionGeneration == b.connectionGeneration {
					return true, nil
				}
				return false, fmt.Errorf("thread owner changed during Desktop discovery")
			}
			if current.kind == threadOwnerMimi {
				return false, fmt.Errorf("thread owner changed to Mimi during Desktop discovery")
			}
			if b.desktopFallbackBlockedLocked(threadID) {
				return false, ErrDesktopDeliveryUncertain
			}
			if current.kind == threadOwnerDesktop {
				b.clearOwnerLocked(threadID)
			}
			b.clearDesktopRecoveryLocked(threadID)
			delete(b.projections, threadID)
			b.store.Remove(threadID)
			b.issueLocalClaimPermitLocked(threadID)
			return false, nil
		}
		return false, err
	}
	if strings.TrimSpace(ownerClientID) == "" {
		return false, fmt.Errorf("Desktop owner discovery response is missing handledByClientId")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	current = b.owners[threadID]
	if current.kind == threadOwnerMimi {
		return false, fmt.Errorf("thread owner changed to Mimi during Desktop discovery")
	}
	if current.kind == threadOwnerDesktop {
		if current.ownerID != ownerClientID || current.connectionGeneration != b.connectionGeneration {
			return false, fmt.Errorf("Desktop owner changed during discovery")
		}
		return true, nil
	}
	if b.ownerEpochs[threadID] != startEpoch || b.connectionGeneration == 0 ||
		b.connectionGeneration != startGeneration {
		return false, fmt.Errorf("thread owner changed during Desktop discovery")
	}
	b.setOwnerLocked(threadID, threadOwner{
		kind: threadOwnerDesktop, ownerID: ownerClientID,
		connectionGeneration: b.connectionGeneration,
	})
	return true, nil
}

func (b *Bridge) DesktopProjection(threadID string) (Projection, bool) {
	return b.desktopProjection(threadID, false)
}

func (b *Bridge) desktopProjection(threadID string, allowResync bool) (Projection, bool) {
	if b.Status().State != StateReady {
		return Projection{}, false
	}
	threadID = strings.TrimSpace(threadID)
	b.mu.RLock()
	projection, ok := b.projections[threadID]
	owner := b.owners[threadID]
	resyncing := b.resyncing[threadID] != 0
	generation := b.connectionGeneration
	b.mu.RUnlock()
	return projection, ok && (allowResync || !resyncing) && owner.kind == threadOwnerDesktop &&
		owner.ownerID != "" && owner.connectionGeneration == generation && generation != 0
}

func (b *Bridge) LocalProjection(threadID string) (Projection, bool) {
	threadID = strings.TrimSpace(threadID)
	b.mu.RLock()
	stream, streamed := b.localStreams[threadID]
	owner := b.owners[threadID]
	b.mu.RUnlock()
	if owner.kind != threadOwnerMimi || !streamed {
		return Projection{}, false
	}
	projection, err := ProjectConversationState(threadID, stream.state, time.Now())
	return projection, err == nil
}

func (b *Bridge) HasLocalOwner(threadID string) bool {
	b.mu.RLock()
	owner := b.owners[strings.TrimSpace(threadID)]
	b.mu.RUnlock()
	return owner.kind == threadOwnerMimi
}

func (b *Bridge) LocalOwnerIs(threadID, ownerID string) bool {
	b.mu.RLock()
	owner := b.owners[strings.TrimSpace(threadID)]
	b.mu.RUnlock()
	return owner.kind == threadOwnerMimi && owner.ownerID == strings.TrimSpace(ownerID)
}

func (b *Bridge) LocalOwnerNeedsRecovery(threadID string) bool {
	threadID = strings.TrimSpace(threadID)
	b.mu.RLock()
	defer b.mu.RUnlock()
	_, responsePending := b.localInFlight[threadID]
	return b.localUncertain[threadID] || responsePending || b.desktopFallbackBlockedLocked(threadID)
}

func (b *Bridge) RequestLocalOwner(ctx context.Context, threadID, method string, params any) (any, error) {
	payload, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	threadID = strings.TrimSpace(threadID)
	incoming := b.incomingForThread(threadID)
	incoming.Lock()
	defer incoming.Unlock()
	b.mu.Lock()
	owner := b.owners[threadID]
	if owner.kind != threadOwnerMimi || owner.handle == nil {
		b.mu.Unlock()
		return nil, fmt.Errorf("no-client-found: Mimi owner is unavailable")
	}
	if (b.localUncertain[threadID] || b.desktopFallbackBlockedLocked(threadID)) &&
		desktopFollowerMethodMutates(method) {
		b.mu.Unlock()
		return nil, fmt.Errorf("Mimi owner delivery is uncertain; complete history is required")
	}
	if _, pending := b.localInFlight[threadID]; pending && desktopFollowerMethodMutates(method) {
		b.mu.Unlock()
		return nil, fmt.Errorf("Mimi owner response is awaiting IPC delivery")
	}
	lease := localOwnerLease{
		threadID: threadID, ownerID: owner.ownerID, ownerEpoch: b.ownerEpochs[threadID],
		connectionGeneration: b.connectionGeneration, followerClientID: owner.followerClientID,
	}
	b.mu.Unlock()
	result, err := owner.handle(context.WithValue(ctx, localOwnerLeaseContextKey{}, lease), method, payload)
	b.mu.Lock()
	leaseStillCurrent := b.localOwnerLeaseStillCurrentLocked(lease)
	current := b.owners[threadID]
	ownerStillCurrent := current.kind == threadOwnerMimi && current.ownerID == lease.ownerID &&
		b.ownerEpochs[threadID] == lease.ownerEpoch
	if desktopFollowerMethodMutates(method) && ownerStillCurrent && (err != nil || !leaseStillCurrent) {
		b.localUncertain[threadID] = true
	} else if leaseStillCurrent && err == nil && method == "thread-follower-load-complete-history" {
		delete(b.localUncertain, threadID)
	}
	b.mu.Unlock()
	return result, err
}

func (b *Bridge) WaitDesktopProjection(ctx context.Context, threadID string) (Projection, bool) {
	updates, unsubscribe := b.Subscribe()
	defer unsubscribe()
	if projection, ok := b.DesktopProjection(threadID); ok {
		return projection, true
	}
	for {
		select {
		case <-ctx.Done():
			return Projection{}, false
		case event, ok := <-updates:
			if !ok {
				return Projection{}, false
			}
			if event.ThreadID == strings.TrimSpace(threadID) {
				if event.Stale {
					return Projection{}, false
				}
				return event.Projection, true
			}
		}
	}
}

func (b *Bridge) WaitDesktopProjectionRevision(ctx context.Context, threadID string, minimumRevision int64) (Projection, bool) {
	threadID = strings.TrimSpace(threadID)
	updates, unsubscribe := b.Subscribe()
	defer unsubscribe()
	if projection, ok := b.desktopProjection(threadID, true); ok {
		if _, revision, stored := b.store.Get(threadID); stored && revision >= minimumRevision {
			return projection, true
		}
	}
	for {
		select {
		case <-ctx.Done():
			return Projection{}, false
		case event, ok := <-updates:
			if !ok {
				return Projection{}, false
			}
			if event.ThreadID != threadID {
				continue
			}
			if event.Stale {
				return Projection{}, false
			}
			if _, revision, stored := b.store.Get(threadID); stored && revision >= minimumRevision {
				projection, projected := b.desktopProjection(threadID, true)
				return projection, projected
			}
		}
	}
}

// ConfirmDesktopHistory clears an uncertain Desktop delivery only after the
// complete-history snapshot named by the Desktop response is authoritative for
// the same owner and connection generation.
func (b *Bridge) ConfirmDesktopHistory(threadID string, minimumRevision int64) bool {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" || minimumRevision <= 0 {
		return false
	}
	b.mu.Lock()
	owner := b.owners[threadID]
	recovery, recovered := b.desktopHistory[threadID]
	if owner.kind != threadOwnerDesktop || owner.ownerID == "" || b.connectionGeneration == 0 ||
		owner.connectionGeneration != b.connectionGeneration ||
		owner.connectionGeneration != b.client.ConnectionGeneration() || !recovered ||
		recovery.ownerID != owner.ownerID || recovery.ownerEpoch != b.ownerEpochs[threadID] ||
		recovery.connectionGeneration != owner.connectionGeneration || recovery.revision != minimumRevision ||
		recovery.uncertaintyEpoch != b.desktopUncertaintyEpoch[threadID] {
		b.mu.Unlock()
		return false
	}
	state, revision, stored := b.store.Get(threadID)
	if !stored || revision < minimumRevision {
		b.mu.Unlock()
		return false
	}
	projection, projected := b.projections[threadID]
	if !projected {
		b.mu.Unlock()
		return false
	}
	// A complete-history response is the recovery barrier for an uncertain
	// start. If it contains no new Turn, the start was not committed. If it
	// contains one, normal snapshot reconciliation keeps the reservation until
	// that Turn reaches a terminal state.
	if b.desktopUncertain[threadID] && recovery.startToken != 0 {
		if reservation, pending := b.desktopStarts[threadID]; pending && reservation.token == recovery.startToken {
			reservation.ownerEpoch = b.ownerEpochs[threadID]
			reservation.connectionGeneration = owner.connectionGeneration
			b.desktopStarts[threadID] = reservation
			b.reconcileDesktopStartLocked(threadID, state)
			if reservation, stillPending := b.desktopStarts[threadID]; stillPending && reservation.expectedTurnID == "" {
				newTurnCount := 0
				for turnID := range conversationStateTurnIDs(state) {
					if _, existed := reservation.baselineTurnIDs[turnID]; !existed {
						newTurnCount++
					}
				}
				if newTurnCount == 0 {
					delete(b.desktopStarts, threadID)
				}
			}
		}
	}
	delete(b.desktopUncertain, threadID)
	delete(b.desktopHistory, threadID)
	subscribers := b.subscribersLocked()
	requests := ProjectPendingServerRequests(threadID, state)
	b.mu.Unlock()
	previous := projection
	b.publishThreadEvent(subscribers, ThreadEvent{
		ThreadID: threadID, Projection: projection, Previous: &previous,
		Requests: requests, HistoryConfirmed: true,
	})
	return true
}

func (b *Bridge) beginDesktopHistoryLocked(threadID string, owner threadOwner, ownerEpoch uint64) desktopHistoryCheckpoint {
	b.nextDesktopHistory++
	checkpoint := desktopHistoryCheckpoint{
		token: b.nextDesktopHistory, ownerID: owner.ownerID, ownerEpoch: ownerEpoch,
		connectionGeneration: owner.connectionGeneration,
		uncertaintyEpoch:     b.desktopUncertaintyEpoch[threadID],
	}
	if reservation, pending := b.desktopStarts[threadID]; pending {
		checkpoint.startToken = reservation.token
	}
	return checkpoint
}

func (b *Bridge) completeDesktopHistory(threadID string, checkpoint desktopHistoryCheckpoint, raw json.RawMessage) {
	revision, ok := completeHistoryRevision(raw)
	if !ok || checkpoint.token == 0 {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	owner := b.owners[threadID]
	if owner.kind != threadOwnerDesktop || owner.ownerID != checkpoint.ownerID ||
		b.ownerEpochs[threadID] != checkpoint.ownerEpoch ||
		owner.connectionGeneration != checkpoint.connectionGeneration ||
		b.desktopUncertaintyEpoch[threadID] != checkpoint.uncertaintyEpoch {
		return
	}
	if current, exists := b.desktopHistory[threadID]; exists && current.token > checkpoint.token {
		return
	}
	checkpoint.revision = revision
	b.desktopHistory[threadID] = checkpoint
}

func (b *Bridge) markDesktopUncertainLocked(threadID string) {
	b.desktopUncertaintyEpoch[threadID]++
	b.desktopUncertain[threadID] = true
	delete(b.desktopHistory, threadID)
}

func (b *Bridge) clearDesktopRecoveryLocked(threadID string) {
	b.desktopUncertaintyEpoch[threadID]++
	delete(b.desktopUncertain, threadID)
	delete(b.desktopStarts, threadID)
	delete(b.desktopHistory, threadID)
}

func (b *Bridge) desktopFallbackBlockedLocked(threadID string) bool {
	if b.desktopUncertain[threadID] || b.resyncing[threadID] != 0 {
		return true
	}
	if _, pending := b.desktopStarts[threadID]; pending {
		return true
	}
	if _, pending := b.refollow[threadID]; pending {
		return true
	}
	if projection, ok := b.projections[threadID]; ok && projection.ActiveTurnID != "" {
		return true
	}
	if state, _, stored := b.store.Get(threadID); stored && len(ProjectPendingServerRequests(threadID, state)) > 0 {
		return true
	}
	return false
}

func (b *Bridge) issueLocalClaimPermitLocked(threadID string) {
	b.nextLocalClaimPermit++
	b.localClaimPermits[threadID] = localOwnerClaimPermit{
		token: b.nextLocalClaimPermit, ownerEpoch: b.ownerEpochs[threadID],
		connectionGeneration: b.connectionGeneration,
	}
}

func (b *Bridge) RequestDesktopOwner(ctx context.Context, method string, params any) (json.RawMessage, error) {
	if b.Status().State != StateReady {
		return nil, &RequestError{
			Method: method, Delivery: DeliveryNotSent, Cause: errors.New("Desktop IPC is not ready"),
		}
	}
	payload, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	threadID := conversationIDFromParams(payload)
	b.mu.Lock()
	owner := b.owners[threadID]
	ownerEpoch := b.ownerEpochs[threadID]
	recoveryRequired := b.desktopUncertain[threadID]
	if owner.kind != threadOwnerDesktop || owner.ownerID == "" ||
		owner.connectionGeneration != b.client.ConnectionGeneration() {
		b.mu.Unlock()
		return nil, &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: errors.New("Desktop owner is unknown")}
	}
	if desktopFollowerMethodMutates(method) {
		if b.desktopUncertain[threadID] {
			b.mu.Unlock()
			return nil, &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: ErrDesktopDeliveryUncertain}
		}
		if b.resyncing[threadID] != 0 {
			b.mu.Unlock()
			return nil, &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: ErrSnapshotRequired}
		}
		if _, projected := b.projections[threadID]; !projected {
			b.mu.Unlock()
			return nil, &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: errors.New("Desktop snapshot is unavailable")}
		}
	}
	historyCheckpoint := desktopHistoryCheckpoint{}
	if method == "thread-follower-load-complete-history" {
		historyCheckpoint = b.beginDesktopHistoryLocked(threadID, owner, ownerEpoch)
	}
	startToken := uint64(0)
	if method == "thread-follower-start-turn" {
		if _, exists := b.desktopStarts[threadID]; exists || b.projections[threadID].ActiveTurnID != "" {
			b.mu.Unlock()
			return nil, &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: ErrDesktopStartInFlight}
		}
		baselineState, _, _ := b.store.Get(threadID)
		b.nextDesktopStart++
		startToken = b.nextDesktopStart
		b.desktopStarts[threadID] = desktopStartReservation{
			token: startToken, ownerEpoch: ownerEpoch,
			connectionGeneration: owner.connectionGeneration,
			baselineTurnIDs:      conversationStateTurnIDs(baselineState),
		}
	}
	b.mu.Unlock()
	result, err := b.client.RequestToGeneration(ctx, owner.ownerID, method, params, owner.connectionGeneration)
	if err == nil && historyCheckpoint.token != 0 {
		b.completeDesktopHistory(threadID, historyCheckpoint, result)
	}
	if startToken != 0 {
		result, err = b.finishDesktopStartRequest(threadID, startToken, result, err)
	}
	b.recordDesktopRequestOutcome(threadID, owner, ownerEpoch, method, err)
	if recoveryRequired && SafeToFallback(err) {
		return result, &RequestError{
			Method: method, Delivery: DeliveryNotSent, Cause: ErrDesktopDeliveryUncertain,
		}
	}
	return result, err
}

// RequestDesktopTurnStart keeps the start reservation across the settings
// update and the actual start. Concurrent gateways cannot overwrite settings
// in the ACK-to-snapshot window and then attempt a second Turn.
func (b *Bridge) RequestDesktopTurnStart(
	ctx context.Context,
	settingsParams any,
	startParams any,
) (json.RawMessage, error) {
	payload, err := json.Marshal(startParams)
	if err != nil {
		return nil, err
	}
	threadID := conversationIDFromParams(payload)
	b.mu.Lock()
	owner := b.owners[threadID]
	ownerEpoch := b.ownerEpochs[threadID]
	if b.Status().State != StateReady || owner.kind != threadOwnerDesktop || owner.ownerID == "" ||
		owner.connectionGeneration != b.client.ConnectionGeneration() {
		b.mu.Unlock()
		return nil, &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryNotSent,
			Cause: errors.New("Desktop owner is unknown"),
		}
	}
	if b.resyncing[threadID] != 0 {
		b.mu.Unlock()
		return nil, &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryNotSent, Cause: ErrSnapshotRequired,
		}
	}
	if b.desktopUncertain[threadID] {
		b.mu.Unlock()
		return nil, &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryNotSent, Cause: ErrDesktopDeliveryUncertain,
		}
	}
	projection, projected := b.projections[threadID]
	if !projected {
		b.mu.Unlock()
		return nil, &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryNotSent,
			Cause: errors.New("Desktop snapshot is unavailable"),
		}
	}
	if _, exists := b.desktopStarts[threadID]; exists || projection.ActiveTurnID != "" {
		b.mu.Unlock()
		return nil, &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryNotSent, Cause: ErrDesktopStartInFlight,
		}
	}
	baselineState, _, _ := b.store.Get(threadID)
	b.nextDesktopStart++
	startToken := b.nextDesktopStart
	b.desktopStarts[threadID] = desktopStartReservation{
		token: startToken, ownerEpoch: ownerEpoch, connectionGeneration: owner.connectionGeneration,
		baselineTurnIDs: conversationStateTurnIDs(baselineState),
	}
	b.mu.Unlock()

	_, err = b.client.RequestToGeneration(
		ctx, owner.ownerID, "thread-follower-update-thread-settings", settingsParams, owner.connectionGeneration,
	)
	if err != nil {
		_, err = b.finishDesktopStartRequest(threadID, startToken, nil, err)
		b.recordDesktopRequestOutcome(
			threadID, owner, ownerEpoch, "thread-follower-update-thread-settings", err,
		)
		return nil, err
	}
	b.mu.RLock()
	current := b.owners[threadID]
	leaseCurrent := b.ownerEpochs[threadID] == ownerEpoch && current.kind == threadOwnerDesktop &&
		current.ownerID == owner.ownerID && current.connectionGeneration == owner.connectionGeneration &&
		b.resyncing[threadID] == 0 && !b.desktopUncertain[threadID]
	b.mu.RUnlock()
	if !leaseCurrent {
		err = &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryNotSent,
			Cause: errors.New("Desktop owner changed after settings update"),
		}
		_, err = b.finishDesktopStartRequest(threadID, startToken, nil, err)
		return nil, err
	}
	result, err := b.client.RequestToGeneration(
		ctx, owner.ownerID, "thread-follower-start-turn", startParams, owner.connectionGeneration,
	)
	result, err = b.finishDesktopStartRequest(threadID, startToken, result, err)
	b.recordDesktopRequestOutcome(threadID, owner, ownerEpoch, "thread-follower-start-turn", err)
	return result, err
}

func (b *Bridge) recordDesktopRequestOutcome(
	threadID string,
	owner threadOwner,
	ownerEpoch uint64,
	method string,
	requestErr error,
) {
	if requestErr == nil {
		return
	}
	var typed *RequestError
	if !errors.As(requestErr, &typed) {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if typed.Delivery == DeliveryUncertain && desktopFollowerMethodMutates(method) {
		b.markDesktopUncertainLocked(threadID)
		return
	}
	current := b.owners[threadID]
	ownerStillCurrent := b.ownerEpochs[threadID] == ownerEpoch && current.kind == threadOwnerDesktop &&
		current.ownerID == owner.ownerID && current.connectionGeneration == owner.connectionGeneration
	if !ownerStillCurrent {
		return
	}
	if typed.Delivery == DeliveryNoClient {
		// no-client 只证明当前没有逻辑 handler，不能证明已 ACK 的 Turn、
		// revision 恢复或待处理审批已经终止。恢复屏障存在时保持原 owner。
		if b.desktopFallbackBlockedLocked(threadID) {
			delete(b.desktopHistory, threadID)
			return
		}
		b.clearOwnerLocked(threadID)
		delete(b.projections, threadID)
		b.store.Remove(threadID)
		b.clearDesktopRecoveryLocked(threadID)
		b.issueLocalClaimPermitLocked(threadID)
	}
}

func (b *Bridge) finishDesktopStartRequest(
	threadID string,
	token uint64,
	result json.RawMessage,
	requestErr error,
) (json.RawMessage, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	reservation, ok := b.desktopStarts[threadID]
	if !ok || reservation.token != token {
		return result, requestErr
	}
	if requestErr != nil {
		var typed *RequestError
		if !errors.As(requestErr, &typed) || typed.Delivery != DeliveryUncertain {
			delete(b.desktopStarts, threadID)
		}
		return result, requestErr
	}
	turnID := desktopStartTurnID(result)
	if turnID == "" {
		return nil, &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryUncertain,
			Cause: errors.New("Desktop start acknowledgement is missing turn id"),
		}
	}
	if reservation.expectedTurnID != "" && reservation.expectedTurnID != turnID {
		return nil, &RequestError{
			Method: "thread-follower-start-turn", Delivery: DeliveryUncertain,
			Cause: errors.New("Desktop start acknowledgement does not match the projected Turn"),
		}
	}
	reservation.expectedTurnID = turnID
	b.desktopStarts[threadID] = reservation
	if state, _, stored := b.store.Get(threadID); stored && conversationStateTurnIsTerminal(state, turnID) {
		delete(b.desktopStarts, threadID)
	}
	return result, nil
}

func desktopStartTurnID(raw json.RawMessage) string {
	var decoded map[string]any
	if json.Unmarshal(raw, &decoded) != nil {
		return ""
	}
	result, _ := decoded["result"].(map[string]any)
	if result == nil {
		result = decoded
	}
	turn, _ := result["turn"].(map[string]any)
	return firstString(turn, "id", "turnId", "turn_id")
}

func conversationStateTurnIsTerminal(state map[string]any, turnID string) bool {
	for _, raw := range conversationTurns(state) {
		turn, _ := raw.(map[string]any)
		if firstString(turn, "id", "turnId", "turn_id") != turnID {
			continue
		}
		switch normalizeToken(stringValue(turn["status"])) {
		case "completed", "succeeded", "success", "failed", "error", "systemerror",
			"interrupted", "cancelled", "canceled", "stopped", "rejected", "denied":
			return true
		default:
			return false
		}
	}
	return false
}

func conversationStateTurnIDs(state map[string]any) map[string]struct{} {
	ids := make(map[string]struct{})
	for _, raw := range conversationTurns(state) {
		turn, _ := raw.(map[string]any)
		if turnID := firstString(turn, "id", "turnId", "turn_id"); turnID != "" {
			ids[turnID] = struct{}{}
		}
	}
	return ids
}

func (b *Bridge) reconcileDesktopStartLocked(threadID string, state map[string]any) {
	reservation, ok := b.desktopStarts[threadID]
	if !ok {
		return
	}
	owner := b.owners[threadID]
	if owner.kind != threadOwnerDesktop || b.ownerEpochs[threadID] != reservation.ownerEpoch ||
		owner.connectionGeneration != reservation.connectionGeneration {
		if b.desktopUncertain[threadID] {
			return
		}
		delete(b.desktopStarts, threadID)
		return
	}
	if reservation.expectedTurnID != "" {
		if conversationStateTurnIsTerminal(state, reservation.expectedTurnID) {
			delete(b.desktopStarts, threadID)
		}
		return
	}
	newTurnIDs := make([]string, 0, 1)
	for turnID := range conversationStateTurnIDs(state) {
		if _, existed := reservation.baselineTurnIDs[turnID]; !existed {
			newTurnIDs = append(newTurnIDs, turnID)
		}
	}
	if len(newTurnIDs) != 1 {
		return
	}
	reservation.expectedTurnID = newTurnIDs[0]
	if conversationStateTurnIsTerminal(state, reservation.expectedTurnID) {
		delete(b.desktopStarts, threadID)
		return
	}
	b.desktopStarts[threadID] = reservation
}

// ClaimNewLocalOwner is only for a Thread ID returned by this App Server's
// thread/start response. Existing Threads must use a no-client permit or the
// explicit Desktop-offline path below.
func (b *Bridge) ClaimNewLocalOwner(threadID, ownerID string, handler LocalOwnerHandler) error {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	if threadID == "" || ownerID == "" || handler == nil {
		return fmt.Errorf("local owner identity is incomplete")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.claimLocalOwnerLocked(threadID, ownerID, handler)
}

// ClaimPermittedLocalOwner atomically consumes the one-shot permit produced by
// an exact no-client result. A stale discovery result cannot be replayed after
// the owner epoch or IPC generation changes.
func (b *Bridge) ClaimPermittedLocalOwner(threadID, ownerID string, handler LocalOwnerHandler) error {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	if threadID == "" || ownerID == "" || handler == nil {
		return fmt.Errorf("local owner identity is incomplete")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	permit, ok := b.localClaimPermits[threadID]
	if !ok || permit.token == 0 || permit.ownerEpoch != b.ownerEpochs[threadID] ||
		permit.connectionGeneration != b.connectionGeneration || b.desktopFallbackBlockedLocked(threadID) {
		return fmt.Errorf("Desktop fallback permit is unavailable")
	}
	delete(b.localClaimPermits, threadID)
	return b.claimLocalOwnerLocked(threadID, ownerID, handler)
}

// ClaimOfflineLocalOwner is used only after an App Server mutation was already
// accepted while Desktop was confirmed absent. A live or connecting Desktop
// can never be converted to a Mimi writer through this path.
func (b *Bridge) ClaimOfflineLocalOwner(threadID, ownerID string, handler LocalOwnerHandler) error {
	state := b.Status().State
	if state != StateDesktopNotRunning && state != StateNotInstalled && state != StateDisabled {
		return fmt.Errorf("Desktop is not confirmed offline")
	}
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	if threadID == "" || ownerID == "" || handler == nil {
		return fmt.Errorf("local owner identity is incomplete")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.connectionGeneration != 0 {
		return fmt.Errorf("Desktop IPC connected while claiming local owner")
	}
	// Desktop process absence is the only offline transition that can discharge
	// stale Desktop delivery state. No App Server read response performs it.
	if state == StateDesktopNotRunning {
		b.clearDesktopRecoveryLocked(threadID)
		delete(b.refollow, threadID)
	}
	return b.claimLocalOwnerLocked(threadID, ownerID, handler)
}

func (b *Bridge) claimLocalOwnerLocked(
	threadID string,
	ownerID string,
	handler LocalOwnerHandler,
) error {
	current := b.owners[threadID]
	if current.kind == threadOwnerDesktop {
		return fmt.Errorf("Desktop already owns this thread")
	}
	if current.kind == threadOwnerMimi && current.ownerID != ownerID {
		return fmt.Errorf("thread already has an active writer")
	}
	if b.desktopFallbackBlockedLocked(threadID) {
		return ErrDesktopDeliveryUncertain
	}
	b.setOwnerLocked(threadID, threadOwner{kind: threadOwnerMimi, ownerID: ownerID, handle: handler})
	delete(b.localClaimPermits, threadID)
	return nil
}

func (b *Bridge) ReleaseLocalOwner(threadID, ownerID string) {
	threadID = strings.TrimSpace(threadID)
	incoming := b.incomingForThread(threadID)
	incoming.Lock()
	defer incoming.Unlock()
	publisher := b.publisherForThread(threadID)
	publisher.Lock()
	defer publisher.Unlock()
	b.mu.Lock()
	current := b.owners[threadID]
	if current.kind == threadOwnerMimi && current.ownerID == strings.TrimSpace(ownerID) {
		_, responsePending := b.localInFlight[threadID]
		uncertain := b.localUncertain[threadID] || responsePending
		b.clearOwnerLocked(threadID)
		delete(b.localStreams, threadID)
		delete(b.localInFlight, threadID)
		if uncertain {
			b.localUncertain[threadID] = true
		} else {
			delete(b.localUncertain, threadID)
		}
	}
	b.mu.Unlock()
}

func (b *Bridge) setOwnerLocked(threadID string, owner threadOwner) {
	b.ownerEpochs[threadID]++
	b.owners[threadID] = owner
	delete(b.localClaimPermits, threadID)
}

func (b *Bridge) clearOwnerLocked(threadID string) {
	b.ownerEpochs[threadID]++
	delete(b.owners, threadID)
	delete(b.localClaimPermits, threadID)
}

func (b *Bridge) PublishLocalConversation(threadID, ownerID string, state map[string]any) error {
	_, err := b.publishLocalConversation(threadID, ownerID, state, false)
	return err
}

func (b *Bridge) ForcePublishLocalConversation(threadID, ownerID string, state map[string]any) (int64, error) {
	return b.publishLocalConversation(threadID, ownerID, state, true)
}

func (b *Bridge) publishLocalConversation(threadID, ownerID string, state map[string]any, forceSnapshot bool) (int64, error) {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	next, err := cloneObject(state)
	if err != nil {
		return 0, err
	}
	publisher := b.publisherForThread(threadID)
	publisher.Lock()
	defer publisher.Unlock()
	b.mu.Lock()
	owner := b.owners[threadID]
	ownerEpoch := b.ownerEpochs[threadID]
	connectionGeneration := b.connectionGeneration
	if owner.kind != threadOwnerMimi || owner.ownerID != ownerID {
		b.mu.Unlock()
		return 0, fmt.Errorf("Mimi owner lease does not match this thread")
	}
	current, hasBaseline := b.localStreams[threadID]
	hasBaseline = hasBaseline && current.broadcasted
	if forceSnapshot {
		hasBaseline = false
		delete(b.localStreams, threadID)
	}
	change := map[string]any{}
	if !hasBaseline {
		current = localStream{revision: 1, state: next, broadcasted: true}
		change = map[string]any{"type": "snapshot", "revision": current.revision, "conversationState": next}
	} else {
		patches := diffTopLevelState(current.state, next)
		if len(patches) == 0 {
			b.mu.Unlock()
			return current.revision, nil
		}
		change = map[string]any{
			"type": "patches", "baseRevision": current.revision,
			"revision": current.revision + 1, "patches": patches,
		}
		current = localStream{revision: current.revision + 1, state: next, broadcasted: true}
	}
	b.localStreams[threadID] = current
	b.mu.Unlock()
	err = b.client.BroadcastGeneration("thread-stream-state-changed", map[string]any{
		"conversationId":  threadID,
		"hostId":          "local",
		"mimiOwnerSource": "agentd-desktop-ipc",
		"change":          change,
	}, connectionGeneration)
	if err != nil {
		// Delivery is uncertain. Force the next successful publish to send a full
		// snapshot instead of a patch against a baseline Desktop may not have.
		b.mu.Lock()
		currentOwner := b.owners[threadID]
		if currentOwner.kind == threadOwnerMimi && currentOwner.ownerID == owner.ownerID && b.ownerEpochs[threadID] == ownerEpoch {
			b.localStreams[threadID] = localStream{state: next}
		}
		b.mu.Unlock()
		return 0, err
	}
	return current.revision, nil
}

func (b *Bridge) publisherForThread(threadID string) *sync.Mutex {
	b.mu.Lock()
	defer b.mu.Unlock()
	publisher := b.publishers[threadID]
	if publisher == nil {
		publisher = &sync.Mutex{}
		b.publishers[threadID] = publisher
	}
	return publisher
}

func diffTopLevelState(previous, next map[string]any) []ConversationPatch {
	patches := make([]ConversationPatch, 0)
	previousKeys := make([]string, 0, len(previous))
	for key := range previous {
		previousKeys = append(previousKeys, key)
	}
	sort.Strings(previousKeys)
	for _, key := range previousKeys {
		if _, exists := next[key]; !exists {
			patches = append(patches, ConversationPatch{Operation: "remove", Path: []any{key}})
		}
	}
	nextKeys := make([]string, 0, len(next))
	for key := range next {
		nextKeys = append(nextKeys, key)
	}
	sort.Strings(nextKeys)
	for _, key := range nextKeys {
		value := next[key]
		old, exists := previous[key]
		if exists && reflect.DeepEqual(old, value) {
			continue
		}
		operation := "replace"
		if !exists {
			operation = "add"
		}
		patches = append(patches, ConversationPatch{Operation: operation, Path: []any{key}, Value: cloneValue(value)})
	}
	return patches
}

func (b *Bridge) handleReady(connectionGeneration uint64) {
	type localRepublish struct {
		ownerID string
		state   map[string]any
	}
	b.mu.Lock()
	b.connectionGeneration = connectionGeneration
	b.localClaimPermits = make(map[string]localOwnerClaimPermit)
	states := make(map[string]localRepublish, len(b.localStreams))
	for threadID, stream := range b.localStreams {
		owner := b.owners[threadID]
		if owner.kind != threadOwnerMimi || owner.ownerID == "" {
			continue
		}
		state, _ := cloneObject(stream.state)
		states[threadID] = localRepublish{ownerID: owner.ownerID, state: state}
		b.localStreams[threadID] = localStream{state: state}
	}
	threads := make([]string, 0, len(b.refollow))
	for threadID := range b.refollow {
		threads = append(threads, threadID)
	}
	for threadID, owner := range b.owners {
		if owner.kind == threadOwnerMimi && owner.followerClientID != "" {
			owner.followerClientID = ""
			b.owners[threadID] = owner
		}
	}
	b.mu.Unlock()
	go func() {
		for threadID, pending := range states {
			_ = b.PublishLocalConversation(threadID, pending.ownerID, pending.state)
		}
		for _, threadID := range threads {
			b.restoreDesktopFollow(threadID, connectionGeneration)
		}
	}()
}

func (b *Bridge) handleDisconnect(connectionGeneration uint64) {
	b.mu.Lock()
	if b.connectionGeneration != connectionGeneration {
		b.mu.Unlock()
		return
	}
	b.connectionGeneration = 0
	b.localClaimPermits = make(map[string]localOwnerClaimPermit)
	b.resyncing = make(map[string]uint64)
	type staleProjection struct {
		threadID string
		previous Projection
	}
	stale := make([]staleProjection, 0)
	for threadID, owner := range b.owners {
		switch {
		case owner.kind == threadOwnerDesktop && owner.connectionGeneration == connectionGeneration:
			b.markDesktopUncertainLocked(threadID)
			if previous, ok := b.projections[threadID]; ok {
				stale = append(stale, staleProjection{threadID: threadID, previous: previous})
			}
			delete(b.projections, threadID)
			b.clearOwnerLocked(threadID)
			if _, followed := b.followed[threadID]; followed {
				b.refollow[threadID] = struct{}{}
			}
		case owner.kind == threadOwnerMimi:
			if inFlight, ok := b.localInFlight[threadID]; ok && inFlight.connectionGeneration == connectionGeneration {
				b.localUncertain[threadID] = true
				delete(b.localInFlight, threadID)
			}
			owner.followerClientID = ""
			b.owners[threadID] = owner
		}
	}
	subscribers := b.subscribersLocked()
	b.mu.Unlock()
	for _, item := range stale {
		b.store.Remove(item.threadID)
		previous := item.previous
		b.publishThreadEvent(subscribers, ThreadEvent{
			ThreadID: item.threadID, Previous: &previous, Stale: true,
		})
	}
}

func (b *Bridge) restoreDesktopFollow(threadID string, connectionGeneration uint64) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := b.FollowThread(ctx, threadID); err != nil {
		return
	}
	owned, err := b.DiscoverDesktopOwner(ctx, threadID)
	if err != nil || !owned || b.client.ConnectionGeneration() != connectionGeneration {
		return
	}
	result, err := b.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	})
	if err != nil {
		return
	}
	revision, ok := completeHistoryRevision(result)
	if !ok {
		return
	}
	if _, ok := b.WaitDesktopProjectionRevision(ctx, threadID, revision); !ok ||
		b.client.ConnectionGeneration() != connectionGeneration || !b.ConfirmDesktopHistory(threadID, revision) {
		return
	}
	_, appliedRevision, stored := b.store.Get(threadID)
	b.mu.Lock()
	owner := b.owners[threadID]
	if stored && appliedRevision >= revision && b.connectionGeneration == connectionGeneration &&
		owner.kind == threadOwnerDesktop && owner.connectionGeneration == connectionGeneration {
		delete(b.refollow, threadID)
	}
	b.mu.Unlock()
}

func (b *Bridge) handleBroadcast(broadcast Broadcast) {
	if broadcast.Method != "thread-stream-state-changed" {
		return
	}
	if expected, ok := MethodVersion(broadcast.Method); !ok || broadcast.Version != expected {
		b.client.status.update(func(status *Status) { status.State = StateProtocolError })
		return
	}
	var params struct {
		ConversationID  string          `json:"conversationId"`
		MimiOwnerSource string          `json:"mimiOwnerSource"`
		Change          json.RawMessage `json:"change"`
	}
	if json.Unmarshal(broadcast.Params, &params) != nil || strings.TrimSpace(params.ConversationID) == "" {
		return
	}
	if params.MimiOwnerSource != "" {
		return
	}
	sourceClientID := strings.TrimSpace(broadcast.SourceClientID)
	if sourceClientID == "" {
		b.client.status.update(func(status *Status) { status.State = StateProtocolError })
		return
	}
	var change StreamChange
	if json.Unmarshal(params.Change, &change) != nil {
		b.client.status.update(func(status *Status) { status.State = StateProtocolError })
		return
	}

	b.mu.Lock()
	owner := b.owners[params.ConversationID]
	if owner.kind == threadOwnerMimi {
		b.mu.Unlock()
		return
	}
	if b.connectionGeneration == 0 ||
		owner.kind == threadOwnerDesktop &&
			(owner.ownerID != sourceClientID || owner.connectionGeneration != b.connectionGeneration) {
		b.mu.Unlock()
		b.client.status.update(func(status *Status) { status.State = StateProtocolError })
		return
	}
	state, err := b.store.Apply(params.ConversationID, change)
	if errors.Is(err, ErrSnapshotRequired) {
		generation := b.connectionGeneration
		previous, hadPrevious := b.projections[params.ConversationID]
		delete(b.projections, params.ConversationID)
		subscribers := b.subscribersLocked()
		if b.resyncing[params.ConversationID] == generation {
			b.mu.Unlock()
			if hadPrevious {
				b.publishThreadEvent(subscribers, ThreadEvent{
					ThreadID: params.ConversationID, Previous: &previous, Stale: true,
				})
			}
			return
		}
		b.resyncing[params.ConversationID] = generation
		b.mu.Unlock()
		if hadPrevious {
			b.publishThreadEvent(subscribers, ThreadEvent{
				ThreadID: params.ConversationID, Previous: &previous, Stale: true,
			})
		}
		go b.resyncDesktopThread(params.ConversationID, sourceClientID, generation)
		return
	}
	if err != nil {
		b.mu.Unlock()
		b.client.status.update(func(status *Status) { status.State = StateProtocolError })
		return
	}
	projection, err := ProjectConversationState(params.ConversationID, state, time.Now())
	if err != nil {
		b.store.Remove(params.ConversationID)
		b.mu.Unlock()
		b.client.status.update(func(status *Status) { status.State = StateProtocolError })
		return
	}
	requests := ProjectPendingServerRequests(params.ConversationID, state)
	if owner.kind == 0 {
		b.setOwnerLocked(params.ConversationID, threadOwner{
			kind: threadOwnerDesktop, ownerID: sourceClientID,
			connectionGeneration: b.connectionGeneration,
		})
	}
	b.reconcileDesktopStartLocked(params.ConversationID, state)
	previous, hadPrevious := b.projections[params.ConversationID]
	b.projections[params.ConversationID] = projection
	subscribers := b.subscribersLocked()
	b.mu.Unlock()
	event := ThreadEvent{ThreadID: params.ConversationID, Projection: projection, Requests: requests}
	if hadPrevious {
		event.Previous = &previous
	}
	b.publishThreadEvent(subscribers, event)
}

func (b *Bridge) resyncDesktopThread(threadID, sourceClientID string, generation uint64) {
	defer func() {
		b.mu.Lock()
		if b.resyncing[threadID] == generation {
			delete(b.resyncing, threadID)
		}
		b.mu.Unlock()
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	b.mu.Lock()
	owner := b.owners[threadID]
	if owner.kind != threadOwnerDesktop || owner.ownerID != sourceClientID ||
		owner.connectionGeneration != generation {
		b.mu.Unlock()
		return
	}
	historyCheckpoint := b.beginDesktopHistoryLocked(threadID, owner, b.ownerEpochs[threadID])
	b.mu.Unlock()
	result, err := b.client.RequestToGeneration(ctx, sourceClientID, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	}, generation)
	if err != nil || b.client.ConnectionGeneration() != generation {
		return
	}
	revision, ok := completeHistoryRevision(result)
	if !ok {
		return
	}
	b.completeDesktopHistory(threadID, historyCheckpoint, result)
	if _, ok := b.WaitDesktopProjectionRevision(ctx, threadID, revision); ok {
		b.ConfirmDesktopHistory(threadID, revision)
	}
}

func completeHistoryRevision(raw json.RawMessage) (int64, bool) {
	var result struct {
		Revision int64 `json:"revision"`
	}
	if json.Unmarshal(raw, &result) != nil || result.Revision <= 0 {
		return 0, false
	}
	return result.Revision, true
}

func (b *Bridge) publishThreadEvent(subscribers []chan ThreadEvent, event ThreadEvent) {
	b.eventsMu.Lock()
	defer b.eventsMu.Unlock()
	for _, subscriber := range subscribers {
		select {
		case subscriber <- event:
			continue
		default:
		}
		// A slow subscriber must not receive a revision gap. Replace queued deltas
		// with the newest full projection so its next frame is self-contained.
		for {
			select {
			case <-subscriber:
				continue
			default:
			}
			break
		}
		snapshot := event
		snapshot.Previous = nil
		subscriber <- snapshot
	}
}

func (b *Bridge) subscribersLocked() []chan ThreadEvent {
	subscribers := make([]chan ThreadEvent, 0, len(b.subscribers))
	for _, subscriber := range b.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	return subscribers
}

func (b *Bridge) canHandleIncoming(request IncomingRequest) bool {
	if b.Status().State != StateReady {
		return false
	}
	if request.ConnectionGeneration == 0 || request.ConnectionGeneration != b.client.ConnectionGeneration() {
		return false
	}
	switch request.Method {
	case "thread-owner-discovery", "thread-follower-start-turn", "thread-follower-load-complete-history",
		"thread-follower-compact-thread", "thread-follower-steer-turn", "thread-follower-interrupt-turn",
		"thread-follower-update-thread-settings", "thread-follower-command-approval-decision",
		"thread-follower-file-approval-decision", "thread-follower-permissions-request-approval-response",
		"thread-follower-submit-user-input", "thread-follower-submit-mcp-server-elicitation-response":
	default:
		return false
	}
	threadID := conversationIDFromParams(request.Params)
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.bindFollowerClientLocked(threadID, request.Method, request.SourceClientID)
}

func (b *Bridge) handleIncoming(ctx context.Context, request IncomingRequest) (any, error) {
	if b.Status().State != StateReady {
		return nil, fmt.Errorf("Desktop IPC is not ready")
	}
	threadID := conversationIDFromParams(request.Params)
	incoming := b.incomingForThread(threadID)
	incoming.Lock()
	defer incoming.Unlock()
	b.mu.Lock()
	if request.ConnectionGeneration == 0 || request.ConnectionGeneration != b.connectionGeneration {
		b.mu.Unlock()
		return nil, fmt.Errorf("Desktop IPC connection generation changed")
	}
	if !b.bindFollowerClientLocked(threadID, request.Method, request.SourceClientID) {
		b.mu.Unlock()
		return nil, fmt.Errorf("no-client-found: Mimi owner is unavailable")
	}
	owner := b.owners[threadID]
	if b.localUncertain[threadID] && desktopFollowerMethodMutates(request.Method) {
		b.mu.Unlock()
		return nil, fmt.Errorf("Mimi owner delivery is uncertain; complete history is required")
	}
	lease := localOwnerLease{
		threadID: threadID, ownerID: owner.ownerID, ownerEpoch: b.ownerEpochs[threadID],
		connectionGeneration: request.ConnectionGeneration, followerClientID: request.SourceClientID,
	}
	mutates := desktopFollowerMethodMutates(request.Method)
	recoversHistory := request.Method == "thread-follower-load-complete-history" && b.localUncertain[threadID]
	if mutates || recoversHistory {
		if _, pending := b.localInFlight[threadID]; pending {
			b.mu.Unlock()
			return nil, fmt.Errorf("Mimi owner response is awaiting IPC delivery")
		}
		b.localInFlight[threadID] = localRequestInFlight{
			requestID: rawMessageKey(request.RequestID), ownerID: owner.ownerID,
			ownerEpoch: b.ownerEpochs[threadID], connectionGeneration: request.ConnectionGeneration,
		}
	}
	b.mu.Unlock()
	if request.Method == "thread-owner-discovery" {
		return map[string]any{}, nil
	}
	result, err := owner.handle(context.WithValue(ctx, localOwnerLeaseContextKey{}, lease), request.Method, request.Params)
	b.mu.Lock()
	leaseStillCurrent := b.localOwnerLeaseStillCurrentLocked(lease)
	current := b.owners[threadID]
	ownerStillCurrent := current.kind == threadOwnerMimi && current.ownerID == lease.ownerID &&
		b.ownerEpochs[threadID] == lease.ownerEpoch
	if mutates && ownerStillCurrent && (err != nil || !leaseStillCurrent) {
		b.localUncertain[threadID] = true
		if inFlight, ok := b.localInFlight[threadID]; ok &&
			inFlight.requestID == rawMessageKey(request.RequestID) &&
			inFlight.connectionGeneration == request.ConnectionGeneration {
			delete(b.localInFlight, threadID)
		}
	} else if recoversHistory && (err != nil || !leaseStillCurrent) {
		if inFlight, ok := b.localInFlight[threadID]; ok &&
			inFlight.requestID == rawMessageKey(request.RequestID) &&
			inFlight.connectionGeneration == request.ConnectionGeneration {
			delete(b.localInFlight, threadID)
		}
	}
	b.mu.Unlock()
	return result, err
}

func (b *Bridge) handleIncomingResponse(request IncomingRequest, writeErr error) {
	mutates := desktopFollowerMethodMutates(request.Method)
	recoversHistory := request.Method == "thread-follower-load-complete-history"
	if !mutates && !recoversHistory {
		return
	}
	threadID := conversationIDFromParams(request.Params)
	requestID := rawMessageKey(request.RequestID)
	b.mu.Lock()
	defer b.mu.Unlock()
	inFlight, ok := b.localInFlight[threadID]
	if !ok || inFlight.requestID != requestID ||
		inFlight.connectionGeneration != request.ConnectionGeneration {
		return
	}
	delete(b.localInFlight, threadID)
	owner := b.owners[threadID]
	ownerStillCurrent := owner.kind == threadOwnerMimi && owner.ownerID == inFlight.ownerID &&
		b.ownerEpochs[threadID] == inFlight.ownerEpoch
	if recoversHistory && ownerStillCurrent {
		if writeErr == nil {
			delete(b.localUncertain, threadID)
		} else {
			b.localUncertain[threadID] = true
		}
		return
	}
	if writeErr != nil && ownerStillCurrent {
		b.localUncertain[threadID] = true
	}
}

func (b *Bridge) incomingForThread(threadID string) *sync.Mutex {
	threadID = strings.TrimSpace(threadID)
	b.mu.Lock()
	defer b.mu.Unlock()
	incoming := b.incomingOps[threadID]
	if incoming == nil {
		incoming = &sync.Mutex{}
		b.incomingOps[threadID] = incoming
	}
	return incoming
}

func desktopFollowerMethodMutates(method string) bool {
	switch method {
	case "thread-owner-discovery", "thread-follower-load-complete-history":
		return false
	default:
		return true
	}
}

// ValidateLocalOwnerLease rejects a follower side effect after its IPC
// generation, logical Desktop follower, or Mimi gateway owner changed.
func (b *Bridge) ValidateLocalOwnerLease(ctx context.Context, threadID string) error {
	lease, ok := ctx.Value(localOwnerLeaseContextKey{}).(localOwnerLease)
	if !ok {
		return fmt.Errorf("Mimi owner lease is missing")
	}
	threadID = strings.TrimSpace(threadID)
	b.mu.RLock()
	valid := lease.threadID == threadID && b.localOwnerLeaseStillCurrentLocked(lease)
	b.mu.RUnlock()
	if !valid {
		return fmt.Errorf("Mimi owner lease changed before follower delivery")
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		return nil
	}
}

func (b *Bridge) localOwnerLeaseStillCurrentLocked(lease localOwnerLease) bool {
	owner := b.owners[lease.threadID]
	return lease.connectionGeneration == b.connectionGeneration &&
		lease.connectionGeneration == b.client.ConnectionGeneration() &&
		lease.ownerEpoch == b.ownerEpochs[lease.threadID] && owner.kind == threadOwnerMimi &&
		owner.ownerID == lease.ownerID && owner.followerClientID == lease.followerClientID
}

func (b *Bridge) bindFollowerClientLocked(threadID, method, sourceClientID string) bool {
	owner := b.owners[strings.TrimSpace(threadID)]
	sourceClientID = strings.TrimSpace(sourceClientID)
	if owner.kind != threadOwnerMimi || owner.handle == nil || sourceClientID == "" {
		return false
	}
	if owner.followerClientID == "" {
		if method != "thread-owner-discovery" && method != "thread-follower-load-complete-history" {
			return false
		}
		owner.followerClientID = sourceClientID
		b.owners[strings.TrimSpace(threadID)] = owner
		return true
	}
	return owner.followerClientID == sourceClientID
}

func conversationIDFromParams(raw json.RawMessage) string {
	var params map[string]any
	if json.Unmarshal(raw, &params) != nil {
		return ""
	}
	return firstString(params, "conversationId", "conversation_id", "threadId", "thread_id")
}

func ProjectPendingServerRequests(threadID string, state map[string]any) []ServerRequest {
	allowed := map[string]bool{
		"item/commandExecution/requestApproval": true,
		"item/fileChange/requestApproval":       true,
		"item/fileRead/requestApproval":         true,
		"item/permissions/requestApproval":      true,
		"item/tool/requestUserInput":            true,
		"mcpServer/elicitation/request":         true,
	}
	result := make([]ServerRequest, 0)
	for _, raw := range anySlice(state["requests"]) {
		request, ok := raw.(map[string]any)
		if !ok || request["completed"] == true {
			continue
		}
		method := stringValue(request["method"])
		if !allowed[method] || request["id"] == nil {
			continue
		}
		params, _ := cloneValue(request["params"]).(map[string]any)
		if params == nil {
			params = map[string]any{}
		}
		params["threadId"] = firstNonEmptyString(firstString(params, "threadId", "thread_id"), threadID)
		params["mimiDesktopIPCMirror"] = true
		result = append(result, ServerRequest{ID: request["id"], Method: method, Params: params})
	}
	return result
}

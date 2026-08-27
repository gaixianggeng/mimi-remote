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
	ThreadID   string
	Projection Projection
	Previous   *Projection
	Requests   []ServerRequest
	Stale      bool
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

// Bridge is the only Desktop IPC connection and ownership coordinator in an
// agentd process. Gateway connections subscribe to it instead of opening their
// own IPC clients.
type Bridge struct {
	client *Client
	store  *ThreadStore

	mu                   sync.RWMutex
	eventsMu             sync.Mutex
	projections          map[string]Projection
	owners               map[string]threadOwner
	ownerEpochs          map[string]uint64
	subscribers          map[uint64]chan ThreadEvent
	nextSubID            uint64
	localStreams         map[string]localStream
	publishers           map[string]*sync.Mutex
	followed             map[string]struct{}
	refollow             map[string]struct{}
	connectionGeneration uint64
}

func NewBridge(options BridgeOptions) (*Bridge, error) {
	bridge := &Bridge{
		store:        NewThreadStore(),
		projections:  make(map[string]Projection),
		owners:       make(map[string]threadOwner),
		ownerEpochs:  make(map[string]uint64),
		subscribers:  make(map[uint64]chan ThreadEvent),
		localStreams: make(map[string]localStream),
		publishers:   make(map[string]*sync.Mutex),
		followed:     make(map[string]struct{}),
		refollow:     make(map[string]struct{}),
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
	if err := b.client.Broadcast("thread-stream-following-changed", map[string]any{
		"hostId":         "local",
		"conversationId": threadID,
		"following":      true,
	}); err != nil {
		return err
	}
	b.mu.Lock()
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
	current := b.owners[threadID]
	b.mu.RUnlock()
	if current.kind == threadOwnerMimi {
		return false, fmt.Errorf("thread already has an active Mimi writer")
	}
	ownerClientID, err := b.client.FindHandler(ctx, "thread-owner-discovery", map[string]any{
		"hostId": "local", "conversationId": threadID,
	})
	if err != nil {
		if SafeToFallback(err) {
			b.ReleaseDesktopOwner(threadID)
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
	if b.ownerEpochs[threadID] != startEpoch || b.connectionGeneration == 0 {
		return false, fmt.Errorf("thread owner changed during Desktop discovery")
	}
	b.setOwnerLocked(threadID, threadOwner{
		kind: threadOwnerDesktop, ownerID: ownerClientID,
		connectionGeneration: b.connectionGeneration,
	})
	return true, nil
}

func (b *Bridge) DesktopProjection(threadID string) (Projection, bool) {
	if b.Status().State != StateReady {
		return Projection{}, false
	}
	b.mu.RLock()
	projection, ok := b.projections[strings.TrimSpace(threadID)]
	owner := b.owners[strings.TrimSpace(threadID)]
	b.mu.RUnlock()
	return projection, ok && owner.kind == threadOwnerDesktop && owner.ownerID != ""
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

func (b *Bridge) RequestLocalOwner(ctx context.Context, threadID, method string, params any) (any, error) {
	payload, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	b.mu.RLock()
	owner := b.owners[strings.TrimSpace(threadID)]
	b.mu.RUnlock()
	if owner.kind != threadOwnerMimi || owner.handle == nil {
		return nil, fmt.Errorf("no-client-found: Mimi owner is unavailable")
	}
	return owner.handle(ctx, method, payload)
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
	if projection, ok := b.DesktopProjection(threadID); ok {
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
				return event.Projection, true
			}
		}
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
	b.mu.RLock()
	owner := b.owners[threadID]
	b.mu.RUnlock()
	if owner.kind != threadOwnerDesktop || owner.ownerID == "" ||
		owner.connectionGeneration != b.client.ConnectionGeneration() {
		return nil, &RequestError{Method: method, Delivery: DeliveryNotSent, Cause: errors.New("Desktop owner is unknown")}
	}
	return b.client.RequestTo(ctx, owner.ownerID, method, params)
}

func (b *Bridge) ClaimLocalOwner(threadID, ownerID string, handler LocalOwnerHandler) error {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	if threadID == "" || ownerID == "" || handler == nil {
		return fmt.Errorf("local owner identity is incomplete")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	current := b.owners[threadID]
	if current.kind == threadOwnerDesktop {
		return fmt.Errorf("Desktop already owns this thread")
	}
	if current.kind == threadOwnerMimi && current.ownerID != ownerID {
		return fmt.Errorf("thread already has an active writer")
	}
	b.setOwnerLocked(threadID, threadOwner{kind: threadOwnerMimi, ownerID: ownerID, handle: handler})
	return nil
}

// ReleaseDesktopOwner is only valid after Desktop explicitly returned
// no-client-found. It prevents a stale snapshot from blocking the independent
// App Server when the Desktop owner no longer exists.
func (b *Bridge) ReleaseDesktopOwner(threadID string) {
	threadID = strings.TrimSpace(threadID)
	b.mu.Lock()
	if b.owners[threadID].kind == threadOwnerDesktop {
		b.clearOwnerLocked(threadID)
	}
	delete(b.projections, threadID)
	b.mu.Unlock()
	b.store.Remove(threadID)
}

func (b *Bridge) ReleaseLocalOwner(threadID, ownerID string) {
	threadID = strings.TrimSpace(threadID)
	b.mu.Lock()
	current := b.owners[threadID]
	if current.kind == threadOwnerMimi && current.ownerID == strings.TrimSpace(ownerID) {
		b.clearOwnerLocked(threadID)
		delete(b.localStreams, threadID)
	}
	b.mu.Unlock()
}

func (b *Bridge) setOwnerLocked(threadID string, owner threadOwner) {
	b.ownerEpochs[threadID]++
	b.owners[threadID] = owner
}

func (b *Bridge) clearOwnerLocked(threadID string) {
	b.ownerEpochs[threadID]++
	delete(b.owners, threadID)
}

func (b *Bridge) PublishLocalConversation(threadID string, state map[string]any) error {
	_, err := b.publishLocalConversation(threadID, state, false)
	return err
}

func (b *Bridge) ForcePublishLocalConversation(threadID string, state map[string]any) (int64, error) {
	return b.publishLocalConversation(threadID, state, true)
}

func (b *Bridge) publishLocalConversation(threadID string, state map[string]any, forceSnapshot bool) (int64, error) {
	threadID = strings.TrimSpace(threadID)
	next, err := cloneObject(state)
	if err != nil {
		return 0, err
	}
	publisher := b.publisherForThread(threadID)
	publisher.Lock()
	defer publisher.Unlock()
	b.mu.Lock()
	if b.owners[threadID].kind != threadOwnerMimi {
		b.mu.Unlock()
		return 0, fmt.Errorf("Mimi does not own this thread")
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
	err = b.client.Broadcast("thread-stream-state-changed", map[string]any{
		"conversationId":  threadID,
		"hostId":          "local",
		"mimiOwnerSource": "agentd-desktop-ipc",
		"change":          change,
	})
	if err != nil {
		// Delivery is uncertain. Force the next successful publish to send a full
		// snapshot instead of a patch against a baseline Desktop may not have.
		b.mu.Lock()
		if b.owners[threadID].kind == threadOwnerMimi {
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
	b.mu.Lock()
	b.connectionGeneration = connectionGeneration
	states := make(map[string]map[string]any, len(b.localStreams))
	for threadID, stream := range b.localStreams {
		states[threadID], _ = cloneObject(stream.state)
		b.localStreams[threadID] = localStream{state: states[threadID]}
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
		for threadID, state := range states {
			_ = b.PublishLocalConversation(threadID, state)
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
	type staleProjection struct {
		threadID string
		previous Projection
	}
	stale := make([]staleProjection, 0)
	for threadID, owner := range b.owners {
		switch {
		case owner.kind == threadOwnerDesktop && owner.connectionGeneration == connectionGeneration:
			if previous, ok := b.projections[threadID]; ok {
				stale = append(stale, staleProjection{threadID: threadID, previous: previous})
			}
			delete(b.projections, threadID)
			b.clearOwnerLocked(threadID)
			if _, followed := b.followed[threadID]; followed {
				b.refollow[threadID] = struct{}{}
			}
		case owner.kind == threadOwnerMimi:
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
	if _, err := b.RequestDesktopOwner(ctx, "thread-follower-load-complete-history", map[string]any{
		"conversationId": threadID,
	}); err != nil {
		return
	}
	b.mu.Lock()
	delete(b.refollow, threadID)
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
		b.mu.Unlock()
		go func(threadID string) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			_, _ = b.client.RequestTo(ctx, sourceClientID, "thread-follower-load-complete-history", map[string]any{
				"conversationId": threadID,
			})
		}(params.ConversationID)
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
	b.mu.Lock()
	if !b.bindFollowerClientLocked(threadID, request.Method, request.SourceClientID) {
		b.mu.Unlock()
		return nil, fmt.Errorf("no-client-found: Mimi owner is unavailable")
	}
	owner := b.owners[threadID]
	b.mu.Unlock()
	if request.Method == "thread-owner-discovery" {
		return map[string]any{}, nil
	}
	return owner.handle(ctx, request.Method, request.Params)
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

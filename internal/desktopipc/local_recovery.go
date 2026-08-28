package desktopipc

import (
	"fmt"
	"strings"
	"time"
)

// MarkLocalOwnerRecoveryRequired keeps the Mimi writer fenced while its
// resident App Server transport is being rebuilt. Only complete history can
// reopen mutations.
func (b *Bridge) MarkLocalOwnerRecoveryRequired(threadID, ownerID string) {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	b.mu.Lock()
	owner := b.owners[threadID]
	if owner.kind == threadOwnerMimi && owner.ownerID == ownerID {
		b.localRecoveryEpoch[threadID]++
		b.localUncertain[threadID] = true
		owner.followerClientID = ""
		owner.confirmedFollowerID = ""
		b.owners[threadID] = owner
	}
	b.mu.Unlock()
}

// StageLocalConversationRecovery replaces process-local state after an App
// Server transport loss. It deliberately does not write Desktop IPC: a stale
// socket must not delay the replacement App Server session or its history
// response. The next normal publish sends a full snapshot.
func (b *Bridge) StageLocalConversationRecovery(threadID, ownerID string, state map[string]any) error {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	next, err := cloneObject(state)
	if err != nil {
		return err
	}
	publisher := b.publisherForThread(threadID)
	publisher.Lock()
	defer publisher.Unlock()

	b.mu.Lock()
	owner := b.owners[threadID]
	current := b.localStreams[threadID]
	if owner.kind != threadOwnerMimi || owner.ownerID != ownerID {
		b.mu.Unlock()
		return fmt.Errorf("Mimi owner lease does not match this thread")
	}
	var previous *Projection
	if current.state != nil {
		if projected, projectErr := ProjectConversationState(threadID, current.state, time.Now()); projectErr == nil {
			previous = &projected
		}
	}
	projection, err := ProjectConversationState(threadID, next, time.Now())
	if err != nil {
		b.mu.Unlock()
		return err
	}
	b.localStreams[threadID] = localStream{revision: current.revision, state: next}
	requests := ProjectPendingServerRequests(threadID, next)
	subscribers := b.subscribersLocked()
	b.mu.Unlock()
	b.publishThreadEvent(subscribers, ThreadEvent{
		ThreadID: threadID, Projection: projection, Previous: previous, Requests: requests,
		LocalOwner: true,
	})
	return nil
}

// NotifyLocalConversation replays the current local projection to attached
// mobile gateways without changing the Desktop revision.
func (b *Bridge) NotifyLocalConversation(threadID, ownerID string, historyConfirmed bool) error {
	threadID, ownerID = strings.TrimSpace(threadID), strings.TrimSpace(ownerID)
	b.mu.RLock()
	owner := b.owners[threadID]
	stream := b.localStreams[threadID]
	if owner.kind != threadOwnerMimi || owner.ownerID != ownerID || stream.state == nil {
		b.mu.RUnlock()
		return fmt.Errorf("Mimi owner state is unavailable")
	}
	projection, err := ProjectConversationState(threadID, stream.state, time.Now())
	if err != nil {
		b.mu.RUnlock()
		return err
	}
	requests := ProjectPendingServerRequests(threadID, stream.state)
	subscribers := b.subscribersLocked()
	b.mu.RUnlock()
	b.publishThreadEvent(subscribers, ThreadEvent{
		ThreadID: threadID, Projection: projection, Requests: requests,
		HistoryConfirmed: historyConfirmed, LocalOwner: true,
	})
	return nil
}

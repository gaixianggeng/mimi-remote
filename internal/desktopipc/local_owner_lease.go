package desktopipc

import (
	"context"
	"fmt"
	"strings"
)

// localOwnerLease 描述一次交给 Mimi owner 执行的请求，用来判断结果送达时这个
// owner 是否仍然有效。
type localOwnerLease struct {
	threadID   string
	ownerID    string
	ownerEpoch uint64
	// connectionGeneration 和 followerClientID 只描述发起请求的那条 Desktop IPC
	// 连接，因此只有 desktopOriginated 的租约才校验它们。Mimi 自己发起的写请求
	// 直达它自己的 App Server，Desktop 连接的建立或断开不改变其交付结果。
	connectionGeneration uint64
	followerClientID     string
	desktopOriginated    bool
}

type localOwnerLeaseContextKey struct{}

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
	if owner.kind != threadOwnerMimi || owner.ownerID != lease.ownerID ||
		lease.ownerEpoch != b.ownerEpochs[lease.threadID] {
		return false
	}
	if !lease.desktopOriginated {
		return true
	}
	return lease.connectionGeneration == b.connectionGeneration &&
		lease.connectionGeneration == b.client.ConnectionGeneration() &&
		owner.followerClientID == lease.followerClientID
}

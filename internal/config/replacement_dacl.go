package config

import "errors"

// install applies this sampled descriptor to the pinned replacement handle.
type daclSnapshot struct {
	fileDACL
	install func() error
}

type replaceDACLOps struct {
	destination func() (daclSnapshot, error)
	move        func() error
	replacement func() (fileDACL, error)
	displaced   func() (daclSnapshot, error) // Old inode's existing rollback link, if available.
	lockDown    func() error
	retainStage bool // A forward stage kept for retry, never a hard-linked rollback source.
}

func replaceWithDACL(original, staged fileDACL, ops replaceDACLOps) error {
	if !original.preservedBy(staged) {
		return &PermissionConflict{Cause: errPermissionsChanged}
	}
	before, err := ops.destination()
	if err != nil {
		return &PermissionConflict{Cause: err}
	}
	if !original.equal(before.fileDACL) {
		// The retained file already contains credentials. Honor a newly
		// observed revocation there too, without touching the destination.
		if ops.retainStage && !staged.within(before.fileDACL) {
			if changed := enforceReplacementDACL(before, original, ops); changed != nil {
				changed.Published = false
				return changed
			}
		}
		return &PermissionConflict{Cause: errPermissionsChanged}
	}
	// MoveFileEx has no DACL compare-and-swap. Even back-to-back calls leave
	// a microsecond-scale (unbounded if descheduled) window for an editor to
	// revoke access on the displaced inode. Only an existing rollback link
	// can reveal that revocation afterwards. Already opened handles retain access.
	if err := ops.move(); err != nil {
		return err
	}
	conflict := enforceReplacementDACL(before, before.fileDACL, ops)
	if conflict != nil && conflict.Recovery {
		return conflict
	}
	if ops.displaced != nil {
		old, err := ops.displaced()
		if err != nil {
			return lockDownReplacement(ops, err)
		}
		if !old.equal(before.fileDACL) {
			// Honor a revocation on the old inode during MoveFileEx. Neither
			// snapshot may introduce grants missing from the other.
			if changed := enforceReplacementDACL(old, before.fileDACL, ops); changed != nil {
				return changed
			}
			return &PermissionConflict{Published: true, Cause: errPermissionsChanged}
		}
	}
	if conflict != nil {
		return conflict
	}
	return nil
}

func enforceReplacementDACL(limit daclSnapshot, before fileDACL, ops replaceDACLOps) *PermissionConflict {
	current, err := ops.replacement()
	if err != nil {
		return lockDownReplacement(ops, err)
	}
	if limit.preservedBy(current) && current.within(before) {
		return nil
	}
	changed := &PermissionConflict{Published: true, Cause: errPermissionsChanged}
	if current.within(limit.fileDACL) && current.within(before) {
		return changed // Preserve a concurrent narrowing, including an explicit deny.
	}
	if limit.within(current) && limit.within(before) {
		// SetSecurityInfo has no CAS either. A simultaneous edit after this
		// read can be lost even if the corrective write verifies successfully.
		if err = limit.install(); err == nil {
			current, err = ops.replacement()
			if err == nil && current.within(limit.fileDACL) && current.within(before) {
				return changed
			}
		}
	}
	// A mixed edit, an unreadable policy, or failed/inherited repair cannot
	// safely be overwritten with a descriptor that might re-grant access.
	return lockDownReplacement(ops, errors.Join(errPermissionsChanged, err))
}

func lockDownReplacement(ops replaceDACLOps, cause error) *PermissionConflict {
	return &PermissionConflict{Published: true, Recovery: true, Cause: errors.Join(cause, ops.lockDown())}
}

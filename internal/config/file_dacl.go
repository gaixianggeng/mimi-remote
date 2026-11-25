package config

import "slices"

// fileDACL describes a regular Windows file. The reader rejects NULL DACLs and
// checks ownership separately. Of the descriptor control flags, only protection
// is part of the policy we copy.
type fileDACL struct {
	protected bool
	entries   []fileACE
}

type fileACE struct {
	encoded   string // Complete native ACE, including its flags.
	inherited bool
	allowSID  string // Set only for ordinary allow ACEs effective on this file.
	allowMask uint32
}

func (source fileDACL) preservedBy(stage fileDACL) bool {
	if source.protected != stage.protected {
		return false
	}
	if slices.Equal(source.entries, stage.entries) {
		return true
	}
	if source.protected {
		return false
	}
	// Access checks evaluate ACEs in order. Keep the prefix through the last
	// deny or special ACE intact. In the remaining allow-only tail, Windows
	// accumulates grants, so inherited allows can split, merge or reorder.
	prefix, explicit, grants := source.splitGrants()
	stagePrefix, stageExplicit, stageGrants := stage.splitGrants()
	if !slices.Equal(prefix, stagePrefix) || !slices.Equal(explicit, stageExplicit) {
		return false
	}
	for sid, mask := range stageGrants {
		if mask&^grants[sid] != 0 {
			return false
		}
	}
	return true
}

func (acl fileDACL) splitGrants() (ordered []fileACE, explicit []string, grants map[string]uint32) {
	tail := len(acl.entries)
	for tail > 0 && acl.entries[tail-1].allowSID != "" {
		tail--
	}
	grants = make(map[string]uint32)
	for _, ace := range acl.entries[tail:] {
		if !ace.inherited {
			explicit = append(explicit, ace.encoded)
		}
		grants[ace.allowSID] |= ace.allowMask
	}
	return acl.entries[:tail], explicit, grants
}

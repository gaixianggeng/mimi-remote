package config

import "slices"

// fileDACL describes the owner, access-governing system ACEs and discretionary
// access policy of a regular Windows file.
type fileDACL struct {
	revision           byte
	inheritanceControl uint16
	owner              string
	systemACEs         []string
	protected          bool
	unrestricted       bool // NULL or absent DACL observed after publication.
	entries            []fileACE
}

type fileACE struct {
	encoded   string // Complete native ACE, including its flags.
	deny      bool   // An additional ordinary deny cannot introduce a grant.
	inherited bool
	allowSID  string // Set only for ordinary allow ACEs effective on this file.
	allowMask uint32
}

func (source fileDACL) preservedBy(stage fileDACL) bool {
	if source.unrestricted != stage.unrestricted || source.owner != stage.owner || source.protected != stage.protected || !slices.Equal(source.systemACEs, stage.systemACEs) {
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

func (a fileDACL) equal(b fileDACL) bool {
	return a.revision == b.revision && a.inheritanceControl == b.inheritanceControl &&
		a.owner == b.owner && a.protected == b.protected && a.unrestricted == b.unrestricted &&
		slices.Equal(a.systemACEs, b.systemACEs) && slices.Equal(a.entries, b.entries)
}

// within proves a bound on effective access to this file. Unlike creation-time
// fidelity, an editor may remove explicit grants, even from a protected DACL.
// Compare ordinary allows between ordered barriers. A new deny only restricts
// access. OWNER RIGHTS and other special ACEs must still match in order.
func (a fileDACL) within(limit fileDACL) bool {
	if limit.unrestricted {
		return true
	}
	if a.unrestricted || a.owner != limit.owner || !slices.Equal(a.systemACEs, limit.systemACEs) {
		return false
	}
	entries := a.entries
	ceiling := limit.entries
	for {
		grants := make(map[string]uint32)
		for len(ceiling) > 0 && ceiling[0].allowSID != "" {
			ace := ceiling[0]
			grants[ace.allowSID] |= ace.allowMask
			ceiling = ceiling[1:]
		}
		for len(entries) > 0 {
			ace := entries[0]
			if len(ceiling) > 0 && ace == ceiling[0] {
				break
			}
			if !ace.deny && (ace.allowSID == "" || ace.allowMask&^grants[ace.allowSID] != 0) {
				return false
			}
			entries = entries[1:]
		}
		if len(ceiling) == 0 || len(entries) == 0 {
			return len(ceiling) == 0 && len(entries) == 0
		}
		entries, ceiling = entries[1:], ceiling[1:]
	}
}

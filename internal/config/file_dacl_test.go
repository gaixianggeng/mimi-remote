package config

import (
	"fmt"
	"testing"
)

func TestFileDACLPreservation(t *testing.T) {
	allow := func(sid string, mask uint32, inherited bool) fileACE {
		return fileACE{
			encoded:   fmt.Sprintf("allow %s %d inherited=%v", sid, mask, inherited),
			inherited: inherited, allowSID: sid, allowMask: mask,
		}
	}
	owner := allow("owner", 3, false)
	read := allow("group", 1, true)
	write := allow("group", 2, true)
	full := allow("group", 3, true)
	metadata := allow("users", 4, true)
	explicitRead := allow("group", 1, false)
	deny := fileACE{encoded: "deny group read", inherited: true}
	ownerRights := fileACE{encoded: "allow OWNER RIGHTS read", inherited: true}
	opaque := fileACE{encoded: "conditional ACE", inherited: true}
	for _, tc := range []struct {
		name          string
		source, stage []fileACE
		want          bool
	}{
		{"explicit policy unchanged", []fileACE{owner}, []fileACE{owner}, true},
		{"reordered and merged inherited grants", []fileACE{owner, read, metadata, write}, []fileACE{owner, full, metadata}, true},
		{"duplicate inherited grant", []fileACE{owner}, []fileACE{owner, allow("owner", 1, true)}, true},
		{"narrower inheritance", []fileACE{owner, full, metadata}, []fileACE{owner, read}, true},
		{"new inherited trustee", []fileACE{owner, read}, []fileACE{owner, read, metadata}, false},
		{"new right for existing trustee", []fileACE{owner, read}, []fileACE{owner, full}, false},
		{"empty DACL cannot gain a grant", nil, []fileACE{read}, false},
		{"cannot replace explicit grant with inherited", []fileACE{explicitRead}, []fileACE{read}, false},
		{"cannot freeze inherited grant as explicit", []fileACE{read}, []fileACE{explicitRead}, false},
		{"cannot lose explicit grant", []fileACE{owner, explicitRead}, []fileACE{owner}, false},
		{"cannot reorder explicit grants", []fileACE{owner, explicitRead}, []fileACE{explicitRead, owner}, false},
		{"ordered deny preserved", []fileACE{deny, read}, []fileACE{deny, read}, true},
		{"narrower inheritance after a deny", []fileACE{deny, full}, []fileACE{deny, read}, true},
		{"cannot move allow ahead of deny", []fileACE{deny, read}, []fileACE{read, deny}, false},
		{"cannot lose deny", []fileACE{deny, read}, []fileACE{read}, false},
		{"cannot restore implicit owner access", []fileACE{ownerRights, read}, []fileACE{read}, false},
		{"cannot lose opaque ACE", []fileACE{opaque, read}, []fileACE{read}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			source := fileDACL{entries: tc.source}
			stage := fileDACL{entries: tc.stage}
			if got := source.preservedBy(stage); got != tc.want {
				t.Fatalf("preservedBy = %v, want %v", got, tc.want)
			}
		})
	}
	protected := fileDACL{protected: true, entries: []fileACE{owner}}
	inheriting := fileDACL{entries: []fileACE{owner}}
	if !protected.preservedBy(protected) || protected.preservedBy(inheriting) || inheriting.preservedBy(protected) {
		t.Fatal("stage must preserve DACL protection")
	}
}

package config

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestReplaceWithDACL(t *testing.T) {
	allow := func(sid string, mask uint32) fileACE {
		return fileACE{encoded: fmt.Sprintf("%s:%d", sid, mask), allowSID: sid, allowMask: mask}
	}
	policy := func(entries ...fileACE) fileDACL {
		return fileDACL{owner: "owner", protected: true, entries: entries}
	}
	read, write := allow("group", 1), allow("group", 3)
	narrow, wide := policy(read), policy(write)
	denied := policy(fileACE{encoded: "deny group write", deny: true}, write)
	mixed := policy(allow("other", 2))
	quarantine := policy(fileACE{encoded: "deny owner rights", deny: true})
	fault := errors.New("injected ACL failure")

	for _, tc := range []struct {
		name               string
		staging, pre, post fileDACL
		displaced          *fileDACL
		readErr, writeErr  error
		ignoreWrite        bool
		want               fileDACL
		trace              string
		conflict, recovery bool
	}{
		{name: "unchanged", staging: wide, pre: wide, post: wide, want: wide, trace: "pre move post"},
		{name: "revoked before rename", staging: wide, pre: narrow, post: wide, want: narrow, trace: "pre post set post", conflict: true},
		{name: "broadened before rename also conflicts", staging: narrow, pre: wide, post: narrow, want: narrow, trace: "pre", conflict: true},
		{name: "renamed file gained write", staging: narrow, pre: narrow, post: wide, want: narrow, trace: "pre move post set post", conflict: true},
		{name: "NULL DACL after rename", staging: narrow, pre: narrow, post: fileDACL{unrestricted: true}, want: narrow, trace: "pre move post set post", conflict: true},
		{name: "explicit grant narrowed after rename", staging: wide, pre: wide, post: narrow, want: narrow, trace: "pre move post", conflict: true},
		{name: "deny added after rename", staging: wide, pre: wide, post: denied, want: denied, trace: "pre move post", conflict: true},
		{name: "revocation on displaced inode", staging: wide, pre: wide, post: wide, displaced: &narrow, want: narrow, trace: "pre move post old post set post", conflict: true},
		{name: "revocations on both inodes", staging: wide, pre: wide, post: denied, displaced: &narrow, want: quarantine, trace: "pre move post old post lock", conflict: true, recovery: true},
		{name: "mixed edit cannot safely restore snapshot", staging: narrow, pre: narrow, post: mixed, want: quarantine, trace: "pre move post lock", conflict: true, recovery: true},
		{name: "read failure", staging: narrow, pre: narrow, post: wide, readErr: fault, want: quarantine, trace: "pre move post lock", conflict: true, recovery: true},
		{name: "set failure", staging: narrow, pre: narrow, post: wide, writeErr: fault, want: quarantine, trace: "pre move post set lock", conflict: true, recovery: true},
		{name: "parent grants reappear at readback", staging: narrow, pre: narrow, post: wide, ignoreWrite: true, want: quarantine, trace: "pre move post set post lock", conflict: true, recovery: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls []string
			published := false
			current := tc.staging
			sample := func(policy fileDACL) daclSnapshot {
				return daclSnapshot{policy, func() error {
					calls = append(calls, "set")
					if tc.writeErr == nil && !tc.ignoreWrite {
						current = policy
					}
					return tc.writeErr
				}}
			}
			ops := replaceDACLOps{
				destination: func() (daclSnapshot, error) {
					calls = append(calls, "pre")
					return sample(tc.pre), nil
				},
				move: func() error {
					calls = append(calls, "move")
					current, published = tc.post, true
					return nil
				},
				retainStage: true,
				replacement: func() (fileDACL, error) {
					calls = append(calls, "post")
					return current, tc.readErr
				},
				lockDown: func() error {
					calls = append(calls, "lock")
					current = quarantine
					return nil
				},
			}
			if tc.displaced != nil {
				ops.displaced = func() (daclSnapshot, error) {
					calls = append(calls, "old")
					return sample(*tc.displaced), nil
				}
			}
			err := replaceWithDACL(tc.staging, tc.staging, ops)
			var conflict *PermissionConflict
			if (err != nil) != tc.conflict || (err != nil && (!errors.As(err, &conflict) ||
				conflict.Published != published || conflict.Recovery != tc.recovery)) {
				t.Fatalf("unexpected conflict: %+v", err)
			}
			if got := strings.Join(calls, " "); got != tc.trace || !current.equal(tc.want) {
				t.Fatalf("operations %q, final policy %+v", got, current)
			}
			if (tc.readErr != nil || tc.writeErr != nil) && !errors.Is(err, fault) {
				t.Fatal("lost ACL failure")
			}
		})
	}
}

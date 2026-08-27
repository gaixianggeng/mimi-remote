package desktopipc

import (
	"errors"
	"testing"
)

func TestThreadStoreAppliesContiguousSnapshotPatches(t *testing.T) {
	store := NewThreadStore()
	state, err := store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 7,
		ConversationState: map[string]any{"title": "Before", "turns": []any{}},
	})
	if err != nil || state["title"] != "Before" {
		t.Fatalf("snapshot failed: state=%v err=%v", state, err)
	}
	state, err = store.Apply("thread-1", StreamChange{
		Type: "patches", BaseRevision: 7, Revision: 8,
		Patches: []ConversationPatch{
			{Operation: "replace", Path: []any{"title"}, Value: "After"},
			{Operation: "add", Path: []any{"turns", 0}, Value: map[string]any{"id": "turn-1"}},
		},
	})
	if err != nil || state["title"] != "After" {
		t.Fatalf("patch failed: state=%v err=%v", state, err)
	}
	turns, _ := state["turns"].([]any)
	if len(turns) != 1 {
		t.Fatalf("turn patch was not applied: %#v", state)
	}
}

func TestThreadStoreDropsBaselineOnRevisionGap(t *testing.T) {
	store := NewThreadStore()
	_, _ = store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 2, ConversationState: map[string]any{"title": "Before"},
	})
	_, err := store.Apply("thread-1", StreamChange{
		Type: "patches", BaseRevision: 3, Revision: 4,
		Patches: []ConversationPatch{{Operation: "replace", Path: []any{"title"}, Value: "After"}},
	})
	if !errors.Is(err, ErrSnapshotRequired) {
		t.Fatalf("revision gap must request a snapshot: %v", err)
	}
	if _, _, ok := store.Get("thread-1"); ok {
		t.Fatal("invalid baseline must be discarded")
	}
}

func TestThreadStoreDropsBaselineWhenPatchCannotApply(t *testing.T) {
	store := NewThreadStore()
	_, _ = store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 1, ConversationState: map[string]any{"title": "Before"},
	})
	_, err := store.Apply("thread-1", StreamChange{
		Type: "patches", BaseRevision: 1, Revision: 2,
		Patches: []ConversationPatch{{Operation: "replace", Path: []any{"missing", "field"}, Value: "After"}},
	})
	if !errors.Is(err, ErrSnapshotRequired) {
		t.Fatalf("invalid patch must request a snapshot: %v", err)
	}
}

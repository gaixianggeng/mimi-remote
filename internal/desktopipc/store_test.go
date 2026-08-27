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

func TestThreadStoreIgnoresDelayedOlderSnapshot(t *testing.T) {
	store := NewThreadStore()
	_, _ = store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 12, ConversationState: map[string]any{"title": "Current"},
	})
	state, err := store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 10, ConversationState: map[string]any{"title": "Stale"},
	})
	if err != nil || state["title"] != "Current" {
		t.Fatalf("older snapshot replaced current state: state=%#v err=%v", state, err)
	}
	_, revision, ok := store.Get("thread-1")
	if !ok || revision != 12 {
		t.Fatalf("older snapshot changed the revision: revision=%d ok=%t", revision, ok)
	}
}

func TestThreadStoreGapHighWaterRejectsDelayedOlderSnapshotsUntilRecovery(t *testing.T) {
	store := NewThreadStore()
	_, err := store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 12, ConversationState: map[string]any{"title": "rev12"},
	})
	if err != nil {
		t.Fatalf("initial snapshot failed: %v", err)
	}
	_, err = store.Apply("thread-1", StreamChange{
		Type:         "patches",
		BaseRevision: 13,
		Revision:     14,
		Patches: []ConversationPatch{{
			Operation: "replace", Path: []any{"title"}, Value: "gap-rev14",
		}},
	})
	if !errors.Is(err, ErrSnapshotRequired) {
		t.Fatalf("revision gap must request a snapshot: %v", err)
	}
	if state, revision, ok := store.Get("thread-1"); ok || state != nil || revision != 0 {
		t.Fatalf("gap must make the store unreadable: state=%#v revision=%d ok=%t", state, revision, ok)
	}

	for _, revision := range []int64{10, 13} {
		state, applyErr := store.Apply("thread-1", StreamChange{
			Type: "snapshot", Revision: revision,
			ConversationState: map[string]any{"title": "delayed"},
		})
		if !errors.Is(applyErr, ErrSnapshotRequired) {
			t.Fatalf("delayed revision %d must remain below the gap high-water: state=%#v err=%v", revision, state, applyErr)
		}
		if state, storedRevision, ok := store.Get("thread-1"); ok || state != nil || storedRevision != 0 {
			t.Fatalf("delayed revision %d restored or changed invalid state: state=%#v revision=%d ok=%t", revision, state, storedRevision, ok)
		}
	}

	state, err := store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 14, ConversationState: map[string]any{"title": "rev14"},
	})
	if err != nil || state["title"] != "rev14" {
		t.Fatalf("revision 14 snapshot did not restore the store: state=%#v err=%v", state, err)
	}
	state, revision, ok := store.Get("thread-1")
	if !ok || revision != 14 || state["title"] != "rev14" {
		t.Fatalf("recovered store has wrong state: state=%#v revision=%d ok=%t", state, revision, ok)
	}

	state, err = store.Apply("thread-1", StreamChange{
		Type: "snapshot", Revision: 13, ConversationState: map[string]any{"title": "late-rev13"},
	})
	if err != nil || state["title"] != "rev14" {
		t.Fatalf("delayed snapshot rolled the recovered store back: state=%#v err=%v", state, err)
	}
	state, revision, ok = store.Get("thread-1")
	if !ok || revision != 14 || state["title"] != "rev14" {
		t.Fatalf("delayed snapshot changed recovered state: state=%#v revision=%d ok=%t", state, revision, ok)
	}
}

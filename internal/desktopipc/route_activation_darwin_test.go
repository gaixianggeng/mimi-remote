//go:build darwin

package desktopipc

import (
	"context"
	"testing"
)

func TestDesktopThreadRouteURLUsesUniqueFollowQuery(t *testing.T) {
	target, err := desktopThreadRouteURL("01a047d2-1028-7542-b715-3cf91dd75efd", "7-2")
	if err != nil {
		t.Fatal(err)
	}
	if target != "codex://threads/01a047d2-1028-7542-b715-3cf91dd75efd?mimi-follow=7-2" {
		t.Fatalf("unexpected Desktop route %q", target)
	}
	for _, threadID := range []string{"", "bad/id", "bad?id", "bad#id"} {
		if _, err := desktopThreadRouteURL(threadID, "1-1"); err == nil {
			t.Fatalf("invalid Thread ID %q was accepted", threadID)
		}
	}
	if _, err := desktopThreadRouteURL("thread-1", ""); err == nil {
		t.Fatal("empty follow nonce was accepted")
	}
}

func TestActivateDesktopThreadRouteDoesNotOpenWhenDesktopIsClosed(t *testing.T) {
	originalCommandOutput := desktopCommandOutput
	originalRouteOpen := desktopRouteOpen
	t.Cleanup(func() {
		desktopCommandOutput = originalCommandOutput
		desktopRouteOpen = originalRouteOpen
	})
	desktopCommandOutput = func(context.Context, string, ...string) ([]byte, error) {
		return nil, nil
	}
	opened := false
	desktopRouteOpen = func(context.Context, string) error {
		opened = true
		return nil
	}
	if err := activateDesktopThreadRoute(context.Background(), "thread-1", "1-1"); err == nil {
		t.Fatal("closed Desktop was treated as a valid activation target")
	}
	if opened {
		t.Fatal("route opener was called while Desktop was closed")
	}
}

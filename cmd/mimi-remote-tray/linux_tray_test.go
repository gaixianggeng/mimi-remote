//go:build linux

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func readyLinuxSnapshot() linuxTraySnapshot {
	return linuxTraySnapshot{HasStatus: true, Status: agentStatus{Version: "test", Endpoint: "http://100.64.0.1:8787", ProcessOK: true, ServiceOK: true, DoctorOK: true}}
}
func TestLinuxRefreshFailurePreservesStatusAndDisablesServiceActions(t *testing.T) {
	count := 0
	app := &linuxTrayApplication{ctx: context.Background(), operation: make(chan struct{}, 1), controller: &linuxController{runner: func(_ context.Context, args ...string) ([]byte, error) {
		count++
		if count == 1 {
			return json.Marshal(readyLinuxSnapshot().Status)
		}
		return nil, fmt.Errorf("temporary failure")
	}}}
	app.refresh(false)
	app.refresh(false)
	snapshot := app.snapshot()
	if !snapshot.HasStatus || !snapshot.Status.ServiceOK || snapshot.Error == "" || snapshot.Busy {
		t.Fatalf("last good status lost: %+v", snapshot)
	}
	for _, item := range flattenLinuxMenu(linuxMenuItems(snapshot)) {
		if (strings.HasPrefix(item.Action, "pair-") || item.Action == "stop" || item.Action == "restart" || item.Action == "start") && item.Enabled {
			t.Fatalf("stale action enabled: %s", item.Action)
		}
	}
	app.controller.runner = func(context.Context, ...string) ([]byte, error) { return json.Marshal(readyLinuxSnapshot().Status) }
	app.refresh(false)
	if app.snapshot().Error != "" {
		t.Fatal("successful refresh did not recover")
	}
}
func TestLinuxMenuDispatchRespectsDisabledItems(t *testing.T) {
	clicked := make(chan string, 2)
	m := &linuxDBusMenu{dispatch: func(action string) { clicked <- action }}
	m.update(linuxMenuItems(linuxTraySnapshot{}))
	_ = m.Event(108, "clicked", dbus.MakeVariant(""), 0)
	_ = m.Event(101, "clicked", dbus.MakeVariant(""), 0)
	select {
	case action := <-clicked:
		if action != "refresh" {
			t.Fatal(action)
		}
	case <-time.After(time.Second):
		t.Fatal("refresh was not dispatched")
	}
	_, layout, err := m.GetLayout(0, 1, []string{"label"})
	if err != nil || len(layout.Children) == 0 || dbus.SignatureOf(layout).String() != "(ia{sv}av)" {
		t.Fatalf("incompatible wire layout: %+v %v", layout, err)
	}
	_, leaf, err := m.GetLayout(108, 0, nil)
	if err != nil || leaf.Properties["enabled"].Value() != false {
		t.Fatal("disabled property missing")
	}
}
func TestLinuxPairingAcceptsOnlyUnexpiredShortTicket(t *testing.T) {
	expires := time.Now().Add(time.Minute).UTC().Truncate(time.Second).Format(time.RFC3339)
	query := url.Values{"endpoint": {"http://100.64.0.1:8787"}, "issued_at": {time.Now().UTC().Format(time.RFC3339)}, "expires_at": {expires}, "pair_sig": {"short-signature"}}
	calls := 0
	c := &linuxController{runner: func(_ context.Context, args ...string) ([]byte, error) {
		if strings.Join(args, " ") != "pair --network tailscale --qr-only --json" {
			t.Fatal("unsafe pairing arguments", args)
		}
		calls++
		return json.Marshal(linuxPairingInfo{PairURL: "mimiremote://pair?" + query.Encode(), PairExpiresAt: expires})
	}}
	if _, err := c.pairing(context.Background(), "tailscale"); err != nil {
		t.Fatal(err)
	}
	exactExpiry, _ := time.Parse(time.RFC3339, expires)
	query.Set("expires_at", exactExpiry.Add(250*time.Millisecond).Format(time.RFC3339Nano))
	if _, err := c.pairing(context.Background(), "tailscale"); err != nil {
		t.Fatal("agentd nanosecond ticket rejected", err)
	}
	query.Set("token", "long-lived-secret")
	if _, err := c.pairing(context.Background(), "tailscale"); err == nil {
		t.Fatal("legacy token accepted")
	}
	query.Del("token")
	expires = time.Now().Add(-time.Minute).Format(time.RFC3339)
	query.Set("expires_at", expires)
	if _, err := c.pairing(context.Background(), "tailscale"); err == nil {
		t.Fatal("expired ticket accepted")
	}
	if calls != 4 {
		t.Fatal(calls)
	}
}
func TestLinuxControllerUsesServiceSafeArgumentsAndRedactsDiagnostics(t *testing.T) {
	c := &linuxController{runner: func(_ context.Context, args ...string) ([]byte, error) {
		if strings.Join(args, " ") != "restart --wait 20s --no-pair" {
			t.Fatal(args)
		}
		return []byte("safe line\nauthorization=Bearer sensitive\nmimiremote://pair?pair_sig=short\nhttp://user:password@host"), nil
	}}
	result, err := c.action(context.Background(), "restart")
	if err != nil || !strings.Contains(result, "safe line") || strings.Contains(result, "sensitive") || strings.Contains(result, "pair_sig") || strings.Contains(result, "user:") {
		t.Fatal(result, err)
	}
	if _, err = c.action(context.Background(), "serve; echo unsafe"); err == nil {
		t.Fatal("unknown action accepted")
	}
	b := &boundedTrayOutput{remaining: 4}
	n, err := b.Write([]byte("123456"))
	if n != 6 || err != nil || !b.truncated || b.String() != "1234" {
		t.Fatal("output bound failed")
	}
}
func TestLinuxConcurrentActionsDoNotOverlap(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	app := &linuxTrayApplication{ctx: context.Background(), state: readyLinuxSnapshot(), operation: make(chan struct{}, 1)}
	entered := make(chan struct{})
	release := make(chan struct{})
	app.controller = &linuxController{runner: func(context.Context, ...string) ([]byte, error) {
		close(entered)
		<-release
		return []byte("logs"), nil
	}}
	done := make(chan struct{})
	go func() { defer close(done); _, _, _ = app.perform("logs") }()
	<-entered
	if _, _, err := app.perform("stop"); err == nil {
		t.Fatal("concurrent service action accepted")
	}
	close(release)
	<-done
	if app.snapshot().Busy {
		t.Fatal("busy flag was not cleared")
	}
}

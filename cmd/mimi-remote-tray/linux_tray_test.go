//go:build linux

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
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
	for _, item := range linuxMenuItems(snapshot) {
		if (item.Action == "pair" || item.Action == "stop" || item.Action == "restart" || item.Action == "start") && item.Enabled {
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
		if strings.Join(args, " ") != "pair --qr-only --json" {
			t.Fatal("unsafe pairing arguments", args)
		}
		calls++
		return json.Marshal(linuxPairingInfo{PairURL: "mimiremote://pair?" + query.Encode(), PairExpiresAt: expires})
	}}
	if _, err := c.pairing(context.Background()); err != nil {
		t.Fatal(err)
	}
	exactExpiry, _ := time.Parse(time.RFC3339, expires)
	query.Set("expires_at", exactExpiry.Add(250*time.Millisecond).Format(time.RFC3339Nano))
	if _, err := c.pairing(context.Background()); err != nil {
		t.Fatal("agentd nanosecond ticket rejected", err)
	}
	query.Set("token", "long-lived-secret")
	if _, err := c.pairing(context.Background()); err == nil {
		t.Fatal("legacy token accepted")
	}
	query.Del("token")
	expires = time.Now().Add(-time.Minute).Format(time.RFC3339)
	query.Set("expires_at", expires)
	if _, err := c.pairing(context.Background()); err == nil {
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
func TestLinuxPanelRequiresExplicitSameOriginConfirmation(t *testing.T) {
	var stops atomic.Int32
	app := &linuxTrayApplication{ctx: context.Background(), state: readyLinuxSnapshot(), operation: make(chan struct{}, 1)}
	app.controller = &linuxController{runner: func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "stop" {
			stops.Add(1)
			return nil, nil
		}
		return json.Marshal(readyLinuxSnapshot().Status)
	}}
	p, err := newLinuxTrayPanel(app)
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	request := func(method, path, origin, csrf string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(url.Values{"csrf": {csrf}}.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", origin)
		w := httptest.NewRecorder()
		p.ServeHTTP(w, r)
		return w
	}
	w := request("GET", p.base+"stop", "", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), "确认停止服务") || stops.Load() != 0 {
		t.Fatal("GET must only show confirmation", w.Code)
	}
	for _, attempt := range []struct{ path, origin, csrf string }{{p.base + "stop", "https://evil.test", p.nonce}, {p.base + "stop", p.origin, "wrong"}, {"http://evil.test/" + p.nonce + "/stop", p.origin, p.nonce}} {
		w = request("POST", attempt.path, attempt.origin, attempt.csrf)
		if w.Code < 400 || stops.Load() != 0 {
			t.Fatal("cross-origin/forged command accepted", w.Code)
		}
	}
	w = request("POST", p.base+"stop", p.origin, p.nonce)
	if w.Code != 303 || stops.Load() != 1 {
		t.Fatal("explicit command not executed exactly once", w.Code, stops.Load())
	}
	if w.Header().Get("Referrer-Policy") != "same-origin" {
		t.Fatal("native form origin would be suppressed")
	}
	if w.Header().Get("Cache-Control") != "no-store" || !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatal("panel caching/framing allowed")
	}
}
func TestLinuxPanelExpiresTicketAndEscapesLogs(t *testing.T) {
	app := &linuxTrayApplication{ctx: context.Background(), state: readyLinuxSnapshot()}
	p, err := newLinuxTrayPanel(app)
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	p.results["pair"] = linuxPanelResult{Pair: &linuxPairingInfo{PairURL: "private-expired-ticket", PairExpiresAt: time.Now().Add(-time.Second).Format(time.RFC3339)}, Output: "<script>untrusted</script>"}
	w := httptest.NewRecorder()
	p.ServeHTTP(w, httptest.NewRequest(http.MethodGet, p.base+"pair", nil))
	body := w.Body.String()
	if strings.Contains(body, "private-expired-ticket") || strings.Contains(body, "<script>untrusted") || !strings.Contains(body, "已过期") {
		t.Fatal("expired or unsafe content rendered")
	}
}
func TestLinuxConcurrentActionsDoNotOverlap(t *testing.T) {
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

func TestLinuxQuitDoesNotTerminateBrowser(t *testing.T) {
	directory := t.TempDir()
	started := filepath.Join(directory, "browser.pid")
	launcher := filepath.Join(directory, "xdg-open")
	script := "#!/bin/sh\necho $$ > '" + started + "'\nexec sleep 30\n"
	if err := os.WriteFile(launcher, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	app := &linuxTrayApplication{ctx: ctx}
	panel, err := newLinuxTrayPanel(app)
	if err != nil {
		t.Fatal(err)
	}
	defer panel.close()
	if err = panel.open("http://127.0.0.1/example"); err != nil {
		t.Fatal(err)
	}
	var pid int
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(started); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(data)))
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if pid == 0 {
		t.Fatal("browser did not launch")
	}
	defer syscall.Kill(pid, syscall.SIGTERM)
	cancel()
	panel.close()
	if err = syscall.Kill(pid, 0); err != nil {
		t.Fatal("tray quit terminated the browser", err)
	}
}

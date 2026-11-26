//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func TestLinuxMenuUsesD2OrderAndTranslatesFourAssistants(t *testing.T) {
	state := readyLinuxSnapshot()
	state.Status.NetworkStatus = &networkStatus{Mode: "tailscale", AllowLAN: true}
	state.Status.RuntimeStatus = &runtimeStatus{Runtimes: []runtimeEntry{
		{ID: "codex", Title: "Codex", Enabled: true, State: "connected"},
		{ID: "claude", Title: "Claude Code", Enabled: true, State: "signed_out"},
		{ID: "agy", Title: "Antigravity", Enabled: true, State: "available"},
		{ID: "deepseek", Title: "DeepSeek", Enabled: true, State: "unavailable"},
	}}
	items := flattenLinuxMenu(linuxMenuItems(state))
	pos := map[string]int{}
	labels := make([]string, 0, len(items))
	for i, item := range items {
		if item.Action != "" {
			pos[item.Action] = i
		}
		labels = append(labels, item.Label)
	}
	if _, found := pos["pair-tailscale"]; !found || !(pos["pair-tailscale"] < pos["pair-tailcat"] && pos["pair-tailcat"] < pos["pair-lan"]) {
		t.Fatalf("Linux pairing menu does not follow D2 order (Tailscale > Tailcat > LAN): %+v", pos)
	}
	joined := strings.Join(labels, "\n")
	for _, want := range []string{"Codex · 已连接", "Claude Code · 未登录", "Antigravity · 运行时可用", "DeepSeek · 不可用"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("Linux menu missing translated assistant label %q in:\n%s", want, joined)
		}
	}
}

func TestLinuxPairMenuCopiesExactLinkAndExposesOnlyMenuControls(t *testing.T) {
	screen, calls := linuxTerminalFixture(t)
	a := screen.app
	t.Cleanup(a.clearMenuPair)
	a.state.Tailcat.Enabled, a.state.Tailcat.Running = true, true
	runner := a.controller.runner
	var issued linuxPairingInfo
	a.controller.runner = func(ctx context.Context, args ...string) ([]byte, error) {
		payload, err := runner(ctx, args...)
		if err == nil && json.Unmarshal(payload, &issued) != nil {
			t.Fatal("invalid test receipt")
		}
		return payload, err
	}
	var copied string
	a.clipboardCopy = func(_ context.Context, value string) error { copied = value; return nil }
	a.terminalOpener = func(string) { t.Fatal("pairing menu opened a terminal") }
	menu := &linuxDBusMenu{dispatch: a.dispatch}
	items := linuxMenuItems(a.snapshot())
	menu.update(linuxMenuItems(a.snapshot()))
	expected := &linuxDBusMenu{}
	for i := range items {
		if items[i].Action == "copy-pair-link" {
			items[i].Enabled = true
		}
	}
	expected.update(items)
	_, want, _ := expected.GetLayout(0, -1, nil)
	for i, id := range []int32{410, 402, 411} {
		copied = ""
		menu.Event(id, "clicked", dbus.MakeVariant(""), 0)
		if len(*calls) != i+1 || copied == "" || copied != issued.PairURL || copied == a.snapshot().Status.Endpoint {
			t.Fatal("channel selection did not copy exactly one newly issued ticket")
		}
		state := a.snapshot()
		if !state.HasPairLink || state.UIError != "" {
			t.Fatal("current ticket unavailable for another copy")
		}
		// Starting from the pre-issuance menu, only enable the copy control.
		// Compare full wire layouts including nested properties and binary data.
		menu.update(linuxMenuItems(state))
		_, layout, err := menu.GetLayout(0, -1, nil)
		if err != nil || !reflect.DeepEqual(layout, want) {
			t.Fatal("issuing a ticket added data to the public D-Bus layout")
		}
		props, groupErr := menu.GetGroupProperties(nil, []string{"icon-data"})
		if groupErr != nil || len(props) == 0 {
			t.Fatal("missing D-Bus menu properties")
		}
		for _, row := range props {
			if len(row.Properties) != 0 {
				t.Fatal("menu exported an image over D-Bus")
			}
			if _, propErr := menu.GetProperty(row.ID, "icon-data"); propErr == nil {
				t.Fatal("icon-data was readable for a menu item")
			}
		}
		copied = ""
		menu.Event(119, "clicked", dbus.MakeVariant(""), 0)
		if copied != issued.PairURL || len(*calls) != i+1 {
			t.Fatal("copy-current used a different ticket or issued another")
		}
	}
	menu.Event(0, "closed", dbus.MakeVariant(""), 0)
	copied = ""
	a.dispatch("copy-pair-link")
	if copied != "" || a.snapshot().HasPairLink || a.pairVault.HasActive("") {
		t.Fatal("menu close retained a copyable ticket")
	}
}

func TestLinuxPairMenuNeverPublishesIssuanceOrClipboardErrors(t *testing.T) {
	screen, _ := linuxTerminalFixture(t)
	a := screen.app
	t.Cleanup(a.clearMenuPair)
	runner := a.controller.runner
	a.controller.runner = func(context.Context, ...string) ([]byte, error) {
		t.Fatal("disabled Tailcat invoked a command")
		return nil, nil
	}
	a.dispatch("pair-tailcat")
	if !strings.Contains(a.snapshot().UIError, "Tailcat 尚未就绪") {
		t.Fatal("missing not-ready explanation")
	}

	a.terminalOpener = func(string) { t.Fatal("clipboard failure opened a terminal") }
	const private = "fixture-secret"
	a.clipboardCopy = func(_ context.Context, link string) error { return errors.New(link + private) }
	a.controller.runner = runner
	a.dispatch("pair-tailscale")
	if a.snapshot().UIError != "无法复制配对链接，请检查剪贴板工具后重试" {
		t.Fatal("clipboard error reached the public UI")
	}
	a.controller.runner = func(context.Context, ...string) ([]byte, error) {
		return []byte(private), errors.New(private)
	}
	a.dispatch("pair-lan")
	if a.snapshot().UIError != "无法生成配对链接，请刷新状态后重试" || a.pairVault.HasActive("") {
		t.Fatal("failed channel switch exposed CLI output or retained the previous ticket")
	}
	a.state.Error = "stale status"
	a.controller.runner = func(context.Context, ...string) ([]byte, error) {
		t.Fatal("stale status permitted pairing")
		return nil, nil
	}
	a.dispatch("pair-tailscale")
}

func TestLinuxMenuPairExpires(t *testing.T) {
	screen, _ := linuxTerminalFixture(t)
	a := screen.app
	t.Cleanup(a.clearMenuPair)
	var mu sync.Mutex
	now := time.Now()
	a.pairVault.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	a.pairTickInterval = 10 * time.Millisecond
	copies := 0
	a.clipboardCopy = func(context.Context, string) error { copies++; return nil }
	a.dispatch("pair-lan")
	if !a.snapshot().HasPairLink || copies != 1 {
		t.Fatal("ticket did not become copyable")
	}
	mu.Lock()
	now = now.Add(5 * time.Minute)
	mu.Unlock()
	deadline := time.Now().Add(time.Second)
	for a.snapshot().HasPairLink && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if a.snapshot().HasPairLink {
		t.Fatal("expiry watcher left copy enabled")
	}
	a.dispatch("copy-pair-link")
	if copies != 1 || a.pairVault.HasActive("") {
		t.Fatal("expired ticket remained copyable")
	}
}

func TestLinuxPairMenuPendingCopyLifetime(t *testing.T) {
	for _, tc := range []struct {
		action string
		copies int
	}{
		{"menu-closed", 1}, // Auto-closing desktops deliver the requested copy once.
		{"leave-pair-page", 0},
	} {
		t.Run(tc.action, func(t *testing.T) {
			screen, _ := linuxTerminalFixture(t)
			a := screen.app
			t.Cleanup(a.clearMenuPair)
			runner := a.controller.runner
			entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
			a.controller.runner = func(ctx context.Context, args ...string) ([]byte, error) {
				close(entered)
				<-release
				return runner(ctx, args...)
			}
			copies := 0
			a.clipboardCopy = func(context.Context, string) error { copies++; return nil }
			menu := &linuxDBusMenu{dispatch: a.dispatch}
			menu.update(linuxMenuItems(a.snapshot()))
			go func() { defer close(done); menu.Event(410, "clicked", dbus.MakeVariant(""), 0) }()
			<-entered
			if tc.action == "menu-closed" {
				menu.Event(0, "closed", dbus.MakeVariant(""), 0)
			} else {
				a.dispatch(tc.action)
			}
			close(release)
			<-done
			if copies != tc.copies || a.snapshot().HasPairLink || a.pairVault.HasActive("") {
				t.Fatal("late response retained a ticket or copied unexpectedly")
			}
		})
	}
}

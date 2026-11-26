//go:build linux

package main

import (
	"bytes"
	"context"
	"errors"
	"image/png"
	"strings"
	"sync"
	"testing"
	"time"
)

func inlinePairFixture(t *testing.T) *linuxTrayApplication {
	t.Helper()
	screen, _ := linuxTerminalFixture(t)
	a := screen.app
	a.state.InlineQR = true
	a.state.Tailcat.Enabled, a.state.Tailcat.Running = true, true
	t.Cleanup(a.clearMenuPair)
	return a
}

func TestLinuxInlinePairExpandCollapseSwitchAndExpiry(t *testing.T) {
	a := inlinePairFixture(t)
	for _, network := range []string{"tailcat", "tailscale", "lan"} {
		a.dispatch("pair-" + network)
		pair := a.snapshot().PairMenu
		if pair == nil || pair.Error != "" || pair.Loading || len(pair.PNG) == 0 {
			t.Fatal("pair image was not generated")
		}
		img, err := png.Decode(bytes.NewReader(pair.PNG))
		if err != nil || img.Bounds().Dx() != img.Bounds().Dy() || img.Bounds().Dx()%6 != 0 {
			t.Fatal("invalid integer-scale PNG", err)
		}
		for x := 0; x < img.Bounds().Dx(); x++ {
			for y := 0; y < 4*6; y++ {
				r, g, b, _ := img.At(x, y).RGBA()
				if r != 65535 || g != r || b != r {
					t.Fatal("quiet zone was cropped")
				}
			}
		}
		m := &linuxDBusMenu{}
		m.update(linuxMenuItems(a.snapshot()))
		icon, dbusErr := m.GetProperty(200, "icon-data")
		if dbusErr != nil || icon.Signature().String() != "ay" || !bytes.Equal(icon.Value().([]byte), pair.PNG) {
			t.Fatal("host cannot receive the PNG")
		}
		a.dispatch("refresh-pair")
		refreshed := a.snapshot().PairMenu
		if refreshed == pair || len(refreshed.PNG) == 0 {
			t.Fatal("refresh failed")
		}
		a.expireMenuPair(pair)
		if a.snapshot().PairMenu != refreshed {
			t.Fatal("old expiration removed a new ticket")
		}
		a.expireMenuPair(refreshed)
		if len(a.snapshot().PairMenu.PNG) != 0 || !strings.Contains(a.snapshot().PairMenu.Error, "过期") {
			t.Fatal("expired image remains visible")
		}
		a.dispatch("pair-" + network)
		if a.snapshot().PairMenu != nil {
			t.Fatal("collapse retained ticket")
		}
	}
	a.dispatch("pair-tailcat")
	a.dispatch("pair-tailscale")
	if a.snapshot().PairMenu.Action != "pair-tailscale" {
		t.Fatal("network switch failed")
	}
}

func TestLinuxInlinePairCloseDuringGeneration(t *testing.T) {
	a := inlinePairFixture(t)
	runner := a.controller.runner
	entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	a.controller.runner = func(ctx context.Context, args ...string) ([]byte, error) {
		close(entered)
		<-release
		return runner(ctx, args...)
	}
	go func() { defer close(done); a.dispatch("pair-tailcat") }()
	<-entered
	a.dispatch("pair-tailcat")
	close(release)
	<-done
	if a.snapshot().PairMenu != nil {
		t.Fatal("late CLI response reopened the code")
	}
}

func TestLinuxInlinePairFailureDoesNotLeakOrEnableTailcat(t *testing.T) {
	a := inlinePairFixture(t)
	a.state.Tailcat.Enabled = false
	a.controller.runner = func(context.Context, ...string) ([]byte, error) {
		t.Fatal("disabled Tailcat invoked a command")
		return nil, nil
	}
	a.dispatch("pair-tailcat")
	if a.snapshot().PairMenu.Error == "" {
		t.Fatal("missing not-ready explanation")
	}
	a.controller.runner = func(context.Context, ...string) ([]byte, error) {
		return nil, errors.New("mimiremote://pair?pair_sig=secret\x1b[2J")
	}
	a.dispatch("pair-tailscale")
	for _, item := range linuxMenuItems(a.snapshot()) {
		if strings.Contains(item.Label, "secret") || strings.Contains(item.Label, "\x1b") || len(item.IconData) > 0 {
			t.Fatal("failed request published credentials or an image")
		}
	}
	a.clearMenuPair()
	a.state.Error = "stale status"
	a.dispatch("pair-tailscale")
	if !strings.Contains(a.snapshot().PairMenu.Error, "不可用") {
		t.Fatal("expanded button bypassed status guard")
	}
}

func TestLinuxInlinePairTimerRemovesImage(t *testing.T) {
	a := inlinePairFixture(t)
	pair := &linuxMenuPair{Action: "pair-tailcat", PNG: []byte("test")}
	a.state.PairMenu = pair
	done := make(chan struct{})
	a.pairTimer = time.AfterFunc(time.Millisecond, func() { a.expireMenuPair(pair); close(done) })
	<-done
	if len(a.snapshot().PairMenu.PNG) > 0 {
		t.Fatal("timer did not remove image")
	}
	a.clearMenuPair()
	if a.snapshot().PairMenu != nil || a.pairTimer != nil {
		t.Fatal("shutdown retained pairing state")
	}
}

func TestLinuxMenuUsesD2OrderAndTranslatesFourAssistants(t *testing.T) {
	state := readyLinuxSnapshot()
	state.Status.NetworkStatus = &networkStatus{Mode: "tailscale", AllowLAN: true}
	state.Status.RuntimeStatus = &runtimeStatus{Runtimes: []runtimeEntry{
		{ID: "codex", Title: "Codex", Enabled: true, State: "connected"},
		{ID: "claude", Title: "Claude Code", Enabled: true, State: "signed_out"},
		{ID: "agy", Title: "Antigravity", Enabled: true, State: "available"},
		{ID: "deepseek", Title: "DeepSeek", Enabled: true, State: "unavailable"},
	}}
	items := linuxMenuItems(state)
	pos := map[string]int{}
	labels := make([]string, 0, len(items))
	for i, item := range items {
		if item.Action != "" {
			pos[item.Action] = i
		}
		labels = append(labels, item.Label)
	}
	if !(pos["pair-tailscale"] < pos["pair-tailcat"] && pos["pair-tailcat"] < pos["pair-lan"]) {
		t.Fatalf("Linux pairing menu does not follow D2 order (Tailscale > Tailcat > LAN): %+v", pos)
	}
	joined := strings.Join(labels, "\n")
	for _, want := range []string{"Codex · 已连接", "Claude Code · 未登录", "Antigravity · 运行时可用", "DeepSeek · 不可用"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("Linux menu missing translated assistant label %q in:\n%s", want, joined)
		}
	}
}

func TestLinuxFakeClipboardCopiesRealPairURLOnlyAndNeverLeaksOrOpensTerminal(t *testing.T) {
	a := inlinePairFixture(t)
	var clockMu sync.Mutex
	now := time.Now()
	a.pairVault.now = func() time.Time {
		clockMu.Lock()
		defer clockMu.Unlock()
		return now
	}
	a.pairTickInterval = 10 * time.Millisecond

	var copied []string
	var copyErr error
	a.clipboardCopy = func(_ context.Context, value string) error {
		if copyErr != nil {
			return copyErr
		}
		copied = append(copied, value)
		return nil
	}
	terminalOpens := 0
	a.terminalOpener = func(string) {
		terminalOpens++
	}

	// Before issuing any ticket, copy must NOT copy Status.Endpoint and must NOT open a terminal.
	a.dispatch("copy-pair-link")
	a.dispatch("copy")
	if len(copied) != 0 || terminalOpens != 0 {
		t.Fatalf("copy before issuance copied=%v terminalOpens=%d", copied, terminalOpens)
	}

	// Issue Tailscale ticket and verify fake clipboard receives the exact redeemable pair_url.
	a.dispatch("pair-tailscale")
	if !a.snapshot().HasPairLink || a.snapshot().PairMenu == nil || !a.snapshot().PairMenu.CanCopyLink {
		t.Fatalf("issued pair menu should allow copying real link: %+v", a.snapshot().PairMenu)
	}
	a.dispatch("copy-pair-link")
	if len(copied) != 1 || !strings.HasPrefix(copied[0], "mimiremote://pair?") || !strings.Contains(copied[0], "pair_sig=") {
		t.Fatalf("fake clipboard did not receive redeemable pair_url: %v", copied)
	}
	if copied[0] == a.snapshot().Status.Endpoint {
		t.Fatal("copy-pair-link copied Status.Endpoint instead of pair_url")
	}

	// Verify D-Bus menu layout and snapshot never expose the ticket or pair_sig.
	m := &linuxDBusMenu{}
	items := linuxMenuItems(a.snapshot())
	m.update(items)
	for _, item := range flattenLinuxMenu(items) {
		if strings.Contains(item.Label, "pair_sig") || strings.Contains(item.Label, "mimiremote://") {
			t.Fatalf("D-Bus menu leaked ticket in label: %q", item.Label)
		}
	}
	if strings.Contains(a.snapshot().UIError, "pair_sig") || strings.Contains(a.snapshot().UIError, "mimiremote://") {
		t.Fatalf("UIError leaked ticket: %q", a.snapshot().UIError)
	}

	// Clipboard failure must stay in tray with retry hint and NEVER open a terminal.
	copyErr = errors.New("clipboard unavailable")
	a.dispatch("copy-pair-link")
	a.dispatch("copy-endpoint")
	if terminalOpens != 0 {
		t.Fatalf("clipboard failure accidentally opened terminal %d times", terminalOpens)
	}
	if a.snapshot().UIError == "" || strings.Contains(a.snapshot().UIError, "pair_sig") {
		t.Fatalf("unexpected UIError after clipboard failure: %q", a.snapshot().UIError)
	}
	copyErr = nil

	// Channel switch replaces the redeemable link; switching to a failing channel leaves nothing copyable.
	a.dispatch("pair-tailcat")
	a.dispatch("copy-pair-link")
	if len(copied) != 2 || !strings.Contains(copied[1], "transport=tailcat") {
		t.Fatalf("channel switch did not yield new tailcat pair_url: %v", copied)
	}

	// Collapse / page leave clears the link so it is no longer copyable.
	a.dispatch("pair-tailcat")
	a.dispatch("copy-pair-link")
	if a.snapshot().HasPairLink || len(copied) != 2 {
		t.Fatalf("link remained copyable after collapse/page leave: copied=%v", copied)
	}

	// Re-issue and verify 1-second expiry cleanup wipes the link and disables copy.
	a.dispatch("pair-lan")
	if !a.snapshot().HasPairLink {
		t.Fatal("expected active lan pair link")
	}
	clockMu.Lock()
	now = now.Add(5 * time.Minute)
	clockMu.Unlock()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && a.snapshot().HasPairLink {
		time.Sleep(15 * time.Millisecond)
	}
	if a.snapshot().HasPairLink {
		t.Fatal("expiry cleanup did not clear HasPairLink")
	}
	a.dispatch("copy-pair-link")
	if len(copied) != 2 {
		t.Fatalf("expired ticket remained copyable: %v", copied)
	}
}

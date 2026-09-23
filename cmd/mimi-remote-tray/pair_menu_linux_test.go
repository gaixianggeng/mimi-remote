//go:build linux

package main

import (
	"bytes"
	"context"
	"errors"
	"image/png"
	"strings"
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

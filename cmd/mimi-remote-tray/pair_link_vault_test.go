package main

import (
	"context"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestOrderedPairingTransportsFollowsD2(t *testing.T) {
	want := []string{"tailscale", "tailcat", "lan"}
	if got := orderedPairingTransports(); !reflect.DeepEqual(got, want) {
		t.Fatalf("orderedPairingTransports() = %v, want %v", got, want)
	}
}

func TestPairingLinkVaultFakeClipboardLifecycle(t *testing.T) {
	var clockMu sync.Mutex
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	vault := &pairingLinkVault{
		now: func() time.Time {
			clockMu.Lock()
			defer clockMu.Unlock()
			return now
		},
	}

	var clipboard string
	copyCount := 0
	copyFromVault := func(channel string) bool {
		link, ok := vault.RedeemableURL(channel)
		if !ok {
			return false
		}
		clipboard = link
		copyCount++
		return true
	}

	// Before any issuance nothing is copyable.
	if vault.HasActive("") || copyFromVault("pair-tailscale") {
		t.Fatal("vault must not be copyable before issuance")
	}

	// Issue a valid redeemable link on Tailscale.
	tsURL := "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&pair_sig=ts-redeemable-1"
	gen1 := vault.Begin("pair-tailscale")
	if !vault.Store(gen1, "pair-tailscale", tsURL, now.Add(5*time.Minute)) {
		t.Fatal("failed to store valid tailscale link")
	}
	if !copyFromVault("pair-tailscale") || clipboard != tsURL {
		t.Fatalf("fake clipboard got %q, want %q", clipboard, tsURL)
	}
	if strings.HasPrefix(clipboard, "http://") {
		t.Fatalf("clipboard copied raw endpoint instead of pair_url: %q", clipboard)
	}

	// Channel switch immediately wipes the previous link and rejects late responses.
	gen2 := vault.Begin("pair-tailcat")
	if vault.HasActive("") || copyFromVault("") {
		t.Fatal("previous channel link remained copyable after channel switch")
	}
	if vault.Store(gen1, "pair-tailscale", tsURL, now.Add(5*time.Minute)) {
		t.Fatal("late response from superseded generation was accepted")
	}
	tcURL := "mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&transport=tailcat&tailcat_pair_address=node-1&pair_sig=tc-redeemable-2"
	if !vault.Store(gen2, "pair-tailcat", tcURL, now.Add(3*time.Second)) {
		t.Fatal("failed to store tailcat link")
	}
	if !copyFromVault("pair-tailcat") || clipboard != tcURL {
		t.Fatalf("fake clipboard got %q, want %q", clipboard, tcURL)
	}

	// Page leave wipes the link and rejects late writes.
	vault.Clear()
	if vault.HasActive("") || copyFromVault("") {
		t.Fatal("link remained copyable after leaving pairing page")
	}
	if vault.Store(gen2, "pair-tailcat", tcURL, now.Add(3*time.Second)) {
		t.Fatal("late response accepted after page leave")
	}

	// 1-second expiry cleanup wipes expired tickets automatically.
	gen3 := vault.Begin("pair-lan")
	lanURL := "mimiremote://pair?endpoint=http%3A%2F%2F192.168.1.20%3A8787&pair_sig=lan-redeemable-3"
	if !vault.Store(gen3, "pair-lan", lanURL, now.Add(2*time.Second)) {
		t.Fatal("failed to store lan link")
	}
	expiredCh := make(chan string, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go runPairingExpiryLoop(ctx, vault, 10*time.Millisecond, func(channel string, _ uint64) {
		expiredCh <- channel
	})

	clockMu.Lock()
	now = now.Add(3 * time.Second)
	clockMu.Unlock()

	select {
	case ch := <-expiredCh:
		if ch != "pair-lan" {
			t.Fatalf("expired channel = %q, want pair-lan", ch)
		}
	case <-time.After(time.Second):
		t.Fatal("expiry cleanup loop did not clear expired ticket")
	}
	prevCopies := copyCount
	if vault.HasActive("") || copyFromVault("pair-lan") || copyCount != prevCopies {
		t.Fatal("expired ticket remained copyable after expiry cleanup")
	}
}

func TestFormatPairingExpiryAtUsesRealRemainingLifetime(t *testing.T) {
	now := time.Date(2026, 11, 26, 10, 0, 0, 0, time.UTC)
	if got := formatPairingExpiryAt(now.Add(4*time.Minute+30*time.Second).Format(time.RFC3339), now); !strings.Contains(got, "剩余 4 分 30 秒") || strings.Contains(got, "10 分钟") {
		t.Fatalf("unexpected real remaining expiry = %q", got)
	}
	if got := formatPairingExpiryAt(now.Add(45*time.Second).Format(time.RFC3339Nano), now); !strings.Contains(got, "剩余 45 秒") {
		t.Fatalf("unexpected short remaining expiry = %q", got)
	}
	if got := formatPairingExpiryAt(now.Add(-time.Second).Format(time.RFC3339), now); got != "已过期" {
		t.Fatalf("expired formatting = %q, want 已过期", got)
	}
}

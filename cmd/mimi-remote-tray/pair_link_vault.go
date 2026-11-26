package main

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"
)

// orderedPairingTransports returns the D2 recommendation order shared across
// desktop clients: Tailscale > Built-in connection (Tailcat) > Same LAN.
func orderedPairingTransports() []string {
	return []string{"tailscale", "tailcat", "lan"}
}

// trayAssistantSpec enumerates the four supported assistants in canonical UI order.
type trayAssistantSpec struct {
	ID    string
	Title string
}

var trayAssistants = []trayAssistantSpec{
	{ID: "codex", Title: "Codex"},
	{ID: "claude", Title: "Claude Code"},
	{ID: "agy", Title: "Antigravity"},
	{ID: "deepseek", Title: "DeepSeek"},
}

func trayAssistantTitle(id, title string) string {
	if trimmed := strings.TrimSpace(title); trimmed != "" {
		return trimmed
	}
	for _, spec := range trayAssistants {
		if strings.EqualFold(spec.ID, strings.TrimSpace(id)) {
			return spec.Title
		}
	}
	return fallbackText(strings.ToUpper(strings.TrimSpace(id)), "助手")
}

// pairingLinkVault holds the active short-lived redeemable pair_url strictly in
// process-private memory. It is never serialized into D-Bus snapshots, menu
// labels, tooltips, logs, or persisted configuration.
type pairingLinkVault struct {
	mu         sync.Mutex
	generation uint64
	channel    string
	pairURL    string
	expiresAt  time.Time
	now        func() time.Time
}

func (v *pairingLinkVault) currentTime() time.Time {
	if v.now != nil {
		return v.now()
	}
	return time.Now()
}

// Begin starts a new pairing issuance generation for channel and immediately
// wipes any previously stored pair_url so switching channels or refreshing never
// leaves a stale link copyable.
func (v *pairingLinkVault) Begin(channel string) uint64 {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.generation++
	v.channel = channel
	v.pairURL = ""
	v.expiresAt = time.Time{}
	return v.generation
}

// Store records a newly issued redeemable pair_url only if generation and
// channel still match the active issuance and the ticket has not expired.
func (v *pairingLinkVault) Store(generation uint64, channel, pairURL string, expiresAt time.Time) bool {
	if !isValidOnboardingPairURL(pairURL) || expiresAt.IsZero() {
		return false
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if generation == 0 || generation != v.generation || channel != v.channel {
		return false
	}
	if !expiresAt.After(v.currentTime()) {
		v.pairURL = ""
		v.expiresAt = time.Time{}
		return false
	}
	v.pairURL = pairURL
	v.expiresAt = expiresAt
	return true
}

// RedeemableURL returns the active unexpired pair_url (optionally verified
// against channel). If the stored ticket has expired, it is wiped immediately.
func (v *pairingLinkVault) RedeemableURL(channel string) (string, time.Time, bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.pairURL == "" {
		return "", time.Time{}, false
	}
	if channel != "" && v.channel != channel {
		return "", time.Time{}, false
	}
	if !v.expiresAt.After(v.currentTime()) {
		v.pairURL = ""
		v.expiresAt = time.Time{}
		return "", time.Time{}, false
	}
	return v.pairURL, v.expiresAt, true
}

// HasActive reports whether an unexpired pair_url is currently copyable without
// exposing the secret link itself.
func (v *pairingLinkVault) HasActive(channel string) bool {
	_, _, ok := v.RedeemableURL(channel)
	return ok
}

// ExpireIfDue checks the stored ticket against current time and wipes it once
// expired. Intended to be invoked on a 1-second cleanup interval.
func (v *pairingLinkVault) ExpireIfDue() (expired bool, channel string, generation uint64) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.expireIfDueLocked()
}

func (v *pairingLinkVault) expireIfDueLocked() (expired bool, channel string, generation uint64) {
	if v.pairURL == "" {
		return false, "", v.generation
	}
	if v.expiresAt.After(v.currentTime()) {
		return false, v.channel, v.generation
	}
	channel = v.channel
	generation = v.generation
	v.pairURL = ""
	v.expiresAt = time.Time{}
	return true, channel, generation
}

// Clear wipes any stored pair_url and advances the generation so late in-flight
// CLI responses cannot repopulate the vault after leaving the pairing view or
// collapsing the pairing menu.
func (v *pairingLinkVault) Clear() uint64 {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.generation++
	v.channel = ""
	v.pairURL = ""
	v.expiresAt = time.Time{}
	return v.generation
}

// runPairingExpiryLoop polls vault.ExpireIfDue on interval (default 1 second)
// until ctx is cancelled or the ticket expires, calling onExpire when wiped.
func runPairingExpiryLoop(ctx context.Context, vault *pairingLinkVault, generation uint64, interval time.Duration, onExpire func(channel string, generation uint64)) {
	if interval <= 0 {
		interval = time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			vault.mu.Lock()
			if vault.generation != generation {
				vault.mu.Unlock()
				return
			}
			expired, channel, _ := vault.expireIfDueLocked()
			vault.mu.Unlock()
			if expired || channel == "" {
				if onExpire != nil {
					onExpire(channel, generation)
				}
				return
			}
		}
	}
}

// formatPairingExpiryAt formats a pairing ticket expiry timestamp using its
// real remaining lifetime relative to now instead of a hardcoded duration.
func formatPairingExpiryAt(value string, now time.Time) string {
	trimmed := strings.TrimSpace(value)
	expiresAt, err := time.Parse(time.RFC3339Nano, trimmed)
	if err != nil {
		expiresAt, err = time.Parse(time.RFC3339, trimmed)
		if err != nil {
			return fallbackText(trimmed, "短期有效")
		}
	}
	remaining := expiresAt.Sub(now)
	if remaining <= 0 {
		return "已过期"
	}
	totalSeconds := int((remaining + time.Second - 1) / time.Second)
	minutes := totalSeconds / 60
	seconds := totalSeconds % 60
	clock := expiresAt.Local().Format("15:04:05")
	if minutes > 0 {
		return fmt.Sprintf("%s（剩余 %d 分 %02d 秒）", clock, minutes, seconds)
	}
	return fmt.Sprintf("%s（剩余 %d 秒）", clock, seconds)
}

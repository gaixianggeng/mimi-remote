package main

import (
	"context"
	"testing"
	"testing/synctest"

	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
)

func TestWindowsWatchImmediatelyRevokesLANAndReopensOnlyAfterFreshPrivate(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		observed := make(chan string)
		subscribed := make(chan func(bool), 1)
		stopped := make(chan struct{})
		gate := networkaccess.NewLANGate(func(ctx context.Context) string {
			select {
			case code := <-observed:
				return code
			case <-ctx.Done():
				return "probe_timeout"
			}
		})
		go watchLANPolicy(context.Background(), gate, func(f func(bool)) (func(), error) {
			subscribed <- f
			return func() { close(stopped) }, nil
		})
		changed := <-subscribed
		check := func(want string) {
			t.Helper()
			synctest.Wait()
			if got := gate.Diagnostic(); got != want {
				t.Fatalf("gate status=%q, want %q", got, want)
			}
		}
		observed <- ""
		check("")
		for _, code := range []string{"lan_public_network_blocked", "lan_firewall_blocked", "probe_timeout", ""} {
			changed(false)
			if gate.Diagnostic() == "" {
				t.Fatal("event left prior grant active")
			}
			observed <- code
			check(code)
		}
		changed(true)
		<-stopped
		check("lan_firewall_blocked")
	})
}

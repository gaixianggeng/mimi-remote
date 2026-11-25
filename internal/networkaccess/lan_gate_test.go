package networkaccess

import (
	"context"
	"errors"
	"net"
	"testing"
)

func TestLANGateRevokesExistingSocketsAndPreservesOtherTransports(t *testing.T) {
	code := ""
	gate := NewLANGate(func(context.Context) string { return code })
	policy := Policy{LAN: true, Tailscale: true}
	connect := func(local, remote string, allowed bool) *testConn {
		t.Helper()
		raw := &testConn{local: &net.TCPAddr{IP: net.ParseIP(local)}, remote: &net.TCPAddr{IP: net.ParseIP(remote)}}
		l := WrapWithLANGate(&testListener{conns: []net.Conn{raw}}, policy, gate)
		c, err := l.Accept()
		if allowed {
			if err != nil || raw.closed || c == nil {
				t.Fatalf("socket rejected: %v", err)
			}
			t.Cleanup(func() { _ = c.Close() })
		} else if !errors.Is(err, net.ErrClosed) || !raw.closed || c != nil {
			t.Fatal("socket was not closed before dispatch")
		}
		return raw
	}
	lan := func(ok bool) *testConn { return connect("192.168.50.1", "192.168.50.2", ok) }
	lan(false)
	local := connect("127.0.0.1", "127.0.0.1", true)
	tunnel := connect("100.64.0.2", "100.64.0.3", true)
	gate.Invalidate(true)
	for _, denial := range []string{"lan_public_network_blocked", "lan_firewall_blocked", "probe_timeout"} {
		code = ""
		if c := gate.Confirm(context.Background()); c != "" {
			t.Fatal(c)
		}
		active := lan(true)
		code = denial
		if c := gate.Confirm(context.Background()); c != denial || !active.closed {
			t.Fatalf("denial %q did not revoke existing LAN socket (code %q)", denial, c)
		}
		lan(false)
		if local.closed || tunnel.closed {
			t.Fatal("LAN denial disconnected an eligible transport")
		}
	}
	code = ""
	if c := gate.Confirm(context.Background()); c != "" {
		t.Fatal(c)
	}
	again := lan(true)
	gate.Invalidate(false)
	if !again.closed || gate.Confirm(context.Background()) == "" {
		t.Fatal("lost watcher retained grant")
	}
}

func TestLANGateIgnoresProbeForPriorNetworkGeneration(t *testing.T) {
	started, done := make(chan struct{}), make(chan struct{})
	gate := NewLANGate(func(context.Context) string { close(started); <-done; return "" })
	gate.Invalidate(true)
	result := make(chan string, 1)
	go func() { result <- gate.Confirm(context.Background()) }()
	<-started
	gate.Invalidate(true)
	close(done)
	if <-result == "" || gate.admit(&testConn{}) != nil {
		t.Fatal("old Private result reopened LAN after a network event")
	}
}

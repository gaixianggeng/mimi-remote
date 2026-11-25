package networkaccess

import (
	"context"
	"net"
	"sync"
)

// LANGate starts closed. The Windows service arms it only after subscribing
// to both OS change streams. One probe at a time can publish for its generation.
type LANGate struct {
	mu         sync.Mutex
	generation uint64
	watching   bool
	diagnostic string
	live       map[*lanConn]struct{}
	probe      func(context.Context) string
	slot       chan struct{}
}

func NewLANGate(probe func(context.Context) string) *LANGate {
	return &LANGate{probe: probe, diagnostic: "probe_timeout", slot: make(chan struct{}, 1)}
}

type lanConn struct {
	net.Conn
	gate *LANGate
}

func (c *lanConn) Close() error {
	c.gate.mu.Lock()
	delete(c.gate.live, c)
	c.gate.mu.Unlock()
	return c.Conn.Close()
}

func (g *LANGate) admit(conn net.Conn) net.Conn {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.watching || g.diagnostic != "" {
		return nil
	}
	if g.live == nil {
		g.live = make(map[*lanConn]struct{})
	}
	c := &lanConn{Conn: conn, gate: g}
	g.live[c] = struct{}{}
	return c
}

func (g *LANGate) Availability(ctx context.Context) (bool, bool) {
	tailscale, lan := AvailabilityContext(ctx)
	return tailscale, lan && g.Diagnostic() == ""
}

// Diagnostic reads the last observation without queuing a policy query.
func (g *LANGate) Diagnostic() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.diagnostic
}

// Invalidate immediately closes active LAN connections, including hijacked
// WebSockets. Nothing is admitted until a check for this generation succeeds.
func (g *LANGate) Invalidate(watching bool) {
	g.mu.Lock()
	g.generation++
	g.watching = watching
	g.diagnostic = "probe_timeout"
	if !watching {
		g.diagnostic = "lan_firewall_blocked"
	}
	live := g.live
	g.live = nil
	g.mu.Unlock()
	for c := range live {
		_ = c.Conn.Close()
	}
}

// Confirm runs for OS notifications, bounded periodic checks, and every LAN
// issuance. It returns a public diagnostic code, or empty on success.
func (g *LANGate) Confirm(ctx context.Context) string {
	select {
	case g.slot <- struct{}{}:
		defer func() { <-g.slot }()
	case <-ctx.Done():
		g.deny()
		return "probe_timeout"
	}
	g.mu.Lock()
	generation, watching := g.generation, g.watching
	g.mu.Unlock()
	if !watching {
		return "lan_firewall_blocked"
	}
	code := g.probe(ctx)
	if ctx.Err() != nil {
		code = "probe_timeout"
	}
	g.mu.Lock()
	if generation != g.generation {
		g.mu.Unlock()
		return "lan_firewall_blocked"
	}
	g.diagnostic = code
	var live map[*lanConn]struct{}
	if code != "" {
		live = g.live
		g.live = nil
	}
	g.mu.Unlock()
	for c := range live {
		_ = c.Conn.Close()
	}
	return code
}

func (g *LANGate) deny() {
	g.mu.Lock()
	g.generation++
	g.diagnostic = "probe_timeout"
	live := g.live
	g.live = nil
	g.mu.Unlock()
	for c := range live {
		_ = c.Conn.Close()
	}
}

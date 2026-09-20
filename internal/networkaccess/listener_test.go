package networkaccess

import (
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func TestPolicyIndependentIngress(t *testing.T) {
	tests := []struct {
		name, local, remote string
		ts, lan, want       bool
	}{
		{"all off local control", "127.0.0.1", "127.0.0.1", false, false, true},
		{"ipv6 local control", "::1", "::1", false, false, true},
		{"TS only", "100.64.0.2", "100.64.0.3", true, false, true},
		{"TS blocked while LAN on", "100.64.0.2", "100.64.0.3", false, true, false},
		{"LAN only", "192.168.50.2", "192.168.50.3", false, true, true},
		{"LAN blocked while TS on", "192.168.50.2", "192.168.50.3", true, false, false},
		{"TS peer cannot bypass via LAN destination", "192.168.50.2", "100.64.0.3", false, true, false},
		{"LAN peer cannot bypass via TS destination", "100.64.0.2", "192.168.50.3", true, false, false},
		{"both enabled TS", "100.64.0.2", "100.64.0.3", true, true, true},
		{"both enabled LAN", "10.1.1.2", "172.16.1.3", true, true, true},
		{"mapped IPv4", "::ffff:192.168.50.2", "::ffff:192.168.50.3", false, true, true},
		{"public source rejected", "192.168.50.2", "198.51.100.3", true, true, false},
		{"public bind rejected", "198.51.100.2", "192.168.50.3", true, true, false},
		{"external to loopback rejected", "127.0.0.1", "100.64.0.3", true, true, false},
		{"unknown address rejected", "bad", "127.0.0.1", true, true, false},
		{"external IPv6 rejected", "fd00::2", "fd00::3", true, true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := (Policy{Tailscale: tt.ts, LAN: tt.lan}).Allows(net.ParseIP(tt.local), net.ParseIP(tt.remote)); got != tt.want {
				t.Fatalf("Allows=%v want %v", got, tt.want)
			}
		})
	}
}

type testConn struct {
	local, remote net.Addr
	closed        bool
}

func (c *testConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (c *testConn) Write(p []byte) (int, error)      { return len(p), nil }
func (c *testConn) Close() error                     { c.closed = true; return nil }
func (c *testConn) LocalAddr() net.Addr              { return c.local }
func (c *testConn) RemoteAddr() net.Addr             { return c.remote }
func (c *testConn) SetDeadline(time.Time) error      { return nil }
func (c *testConn) SetReadDeadline(time.Time) error  { return nil }
func (c *testConn) SetWriteDeadline(time.Time) error { return nil }

type testListener struct{ conns []net.Conn }

func (l *testListener) Accept() (net.Conn, error) {
	if len(l.conns) == 0 {
		return nil, net.ErrClosed
	}
	c := l.conns[0]
	l.conns = l.conns[1:]
	return c, nil
}
func (*testListener) Close() error   { return nil }
func (*testListener) Addr() net.Addr { return &net.TCPAddr{IP: net.IPv4zero, Port: 8787} }

func TestListenerClosesDeniedConnectionsBeforeHTTPAndContinuesAccepting(t *testing.T) {
	denied := &testConn{local: &net.TCPAddr{IP: net.ParseIP("100.64.0.2")}, remote: &net.TCPAddr{IP: net.ParseIP("100.64.0.3")}}
	allowed := &testConn{local: &net.TCPAddr{IP: net.ParseIP("192.168.50.2")}, remote: &net.TCPAddr{IP: net.ParseIP("192.168.50.3")}}
	listener := Wrap(&testListener{conns: []net.Conn{denied, allowed}}, Policy{LAN: true})
	conn, err := listener.Accept()
	if err != nil || conn != allowed || !denied.closed || allowed.closed {
		t.Fatalf("incorrect socket filtering: conn=%v err=%v denied=%v", conn, err, denied.closed)
	}
	if _, err = listener.Accept(); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("error not propagated: %v", err)
	}
}

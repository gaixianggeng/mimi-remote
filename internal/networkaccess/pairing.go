package networkaccess

import (
	"context"
	"net"
	"syscall"

	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

// DirectListenerReachable checks the concrete advertised address against bound
// sockets and current interfaces. A wildcard bind alone proves neither route.
func DirectListenerReachable(ctx context.Context, listeners []net.Listener, candidate *net.TCPAddr) bool {
	if ctx.Err() != nil || candidate == nil || candidate.Port <= 0 || candidate.IP == nil || candidate.IP.IsLoopback() || candidate.IP.IsUnspecified() {
		return false
	}
	covered := false
	for _, listener := range listeners {
		if listenerCovers(listener, candidate) {
			covered = true
			break
		}
	}
	if !covered {
		return false
	}
	ifaces, err := net.Interfaces()
	if err != nil {
		return false
	}
	if isTailscaleAddress(candidate.IP) {
		return assignedToTunnel(candidate.IP, ifaces, (*net.Interface).Addrs) && tailscaleinfo.TunnelAvailable(ctx)
	}
	if candidate.IP.To4() == nil || !candidate.IP.IsPrivate() {
		return false
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || virtualInterface(iface.Name) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ip, _, err := net.ParseCIDR(a.String())
			if err == nil && ip.Equal(candidate.IP) {
				return ctx.Err() == nil
			}
		}
	}
	return false
}

// Control keeps the listener descriptor live during inspection. Addr alone
// keeps reporting its old value even after Close, and an IPv6 wildcard may
// or may not accept IPv4 depending on how the socket was bound.
func listenerCovers(listener net.Listener, candidate *net.TCPAddr) bool {
	if wrapped, ok := listener.(*policyListener); ok {
		listener = wrapped.Listener
	}
	tcp, ok := listener.(*net.TCPListener)
	if !ok {
		return false
	}
	addr, ok := tcp.Addr().(*net.TCPAddr)
	if !ok || addr.Port != candidate.Port {
		return false
	}
	raw, err := tcp.SyscallConn()
	if err != nil {
		return false
	}
	matches := false
	err = raw.Control(func(fd uintptr) {
		switch {
		case addr.IP.Equal(candidate.IP):
			matches = true
		case !addr.IP.IsUnspecified():
		case (addr.IP.To4() == nil) == (candidate.IP.To4() == nil):
			matches = true
		case addr.IP.To4() == nil:
			v6only, err := syscall.GetsockoptInt(socketHandle(fd), syscall.IPPROTO_IPV6, syscall.IPV6_V6ONLY)
			matches = err == nil && v6only == 0
		}
	})
	return err == nil && matches
}

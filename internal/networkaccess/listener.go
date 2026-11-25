// Package networkaccess implements Mimi-only TCP ingress policy. It never
// changes system interfaces, routes, Tailscale state or firewall rules.
package networkaccess

import (
	"context"
	"net"
	"net/netip"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

type Policy struct{ Tailscale, LAN bool }

func IsTailscaleIPv4(ip net.IP) bool {
	v4 := ip.To4()
	return v4 != nil && v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
}

// isTailscaleAddress covers both tailnet families. The iOS client prefers the
// MagicDNS name, which may resolve to the Tailscale IPv6 address, so an
// IPv4-only check would reject the Tailscale route the client tries first.
func isTailscaleAddress(ip net.IP) bool {
	addr, ok := netip.AddrFromSlice(ip)
	return ok && tailscaleinfo.IsTailscaleAddress(addr)
}

// Allows uses kernel socket addresses, not Host/X-Forwarded-For. Checking the
// source as well prevents a tailnet peer using a LAN destination to bypass a
// disabled Tailscale channel. Local control/Tailcat remains on loopback and
// continues through the existing authenticated HTTP handlers.
func (p Policy) Allows(local, remote net.IP) bool {
	if local == nil || remote == nil {
		return false
	}
	if local.IsLoopback() && remote.IsLoopback() {
		return true
	}
	if isTailscaleAddress(local) || isTailscaleAddress(remote) {
		return p.Tailscale && isTailscaleAddress(local) && isTailscaleAddress(remote)
	}
	return p.LAN && local.To4() != nil && remote.To4() != nil &&
		local.IsPrivate() && remote.IsPrivate() && !local.IsLoopback() && !remote.IsLoopback()
}

type policyListener struct {
	net.Listener
	policy  Policy
	lanGate *LANGate
}

func Wrap(listener net.Listener, policy Policy) net.Listener {
	return WrapWithLANGate(listener, policy, nil)
}

func WrapWithLANGate(listener net.Listener, policy Policy, gate *LANGate) net.Listener {
	return &policyListener{Listener: listener, policy: policy, lanGate: gate}
}

func (l *policyListener) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		local, localOK := conn.LocalAddr().(*net.TCPAddr)
		remote, remoteOK := conn.RemoteAddr().(*net.TCPAddr)
		if localOK && remoteOK && l.policy.Allows(local.IP, remote.IP) {
			if l.lanGate == nil || local.IP.IsLoopback() || isTailscaleAddress(local.IP) {
				return conn, nil
			}
			if tracked := l.lanGate.admit(conn); tracked != nil {
				return tracked, nil
			}
		}
		_ = conn.Close()
	}
}

// Availability means an address is present, not that a mobile device is online.
// Virtual/container LANs are not advertised as phone pairing opportunities.
func Availability() (tailscale, lan bool) {
	return AvailabilityContext(context.Background())
}

// AvailabilityContext lets a cancelled status request stop the optional CLI check.
func AvailabilityContext(ctx context.Context) (tailscale, lan bool) {
	return availability(ctx, net.Interfaces, (*net.Interface).Addrs, tailscaleinfo.TunnelAvailable)
}

func availability(ctx context.Context, list func() ([]net.Interface, error), addrs func(*net.Interface) ([]net.Addr, error), confirmTunnel func(context.Context) bool) (tailscale, lan bool) {
	interfaces, err := list()
	if err != nil {
		return false, false
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := addrs(&iface)
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err != nil {
				continue
			}
			if IsTailscaleIPv4(ip) && tailscaleinfo.IsTunnelInterface(iface.Name) {
				tailscale = true
			}
			if ip.To4() != nil && ip.IsPrivate() && !virtualInterface(iface.Name) {
				lan = true
			}
		}
	}
	return tailscale && confirmTunnel(ctx), lan
}

func virtualInterface(name string) bool {
	if tailscaleinfo.IsTunnelInterface(name) {
		return true
	}
	name = strings.ToLower(name)
	for _, prefix := range []string{"utun", "tun", "tap", "bridge", "veth", "docker", "vmnet", "vmenet", "awdl", "llw", "ipsec", "ppp"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	for _, marker := range []string{"virtual", "vmware", "hyper-v", "wsl"} {
		if strings.Contains(name, marker) {
			return true
		}
	}
	return false
}

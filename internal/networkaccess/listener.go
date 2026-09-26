// Package networkaccess implements Mimi-only TCP ingress policy. It never
// changes system interfaces, routes, Tailscale state or firewall rules.
package networkaccess

import (
	"net"
	"strings"
)

type Policy struct{ Tailscale, LAN bool }

func IsTailscaleIPv4(ip net.IP) bool {
	v4 := ip.To4()
	return v4 != nil && v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
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
	if IsTailscaleIPv4(local) || IsTailscaleIPv4(remote) {
		return p.Tailscale && IsTailscaleIPv4(local) && IsTailscaleIPv4(remote)
	}
	return p.LAN && local.To4() != nil && remote.To4() != nil &&
		local.IsPrivate() && remote.IsPrivate() && !local.IsLoopback() && !remote.IsLoopback()
}

type policyListener struct {
	net.Listener
	policy Policy
}

func Wrap(listener net.Listener, policy Policy) net.Listener {
	return &policyListener{Listener: listener, policy: policy}
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
			return conn, nil
		}
		_ = conn.Close()
	}
}

// Availability means an address is present, not that a mobile device is online.
// Virtual/container LANs are not advertised as phone pairing opportunities.
func Availability() (tailscale, lan bool) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return false, false
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err != nil {
				continue
			}
			if IsTailscaleIPv4(ip) {
				tailscale = true
			}
			if ip.To4() != nil && ip.IsPrivate() && !virtualInterface(iface.Name) {
				lan = true
			}
		}
	}
	return tailscale, lan
}

func virtualInterface(name string) bool {
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

package httpapi

import (
	"net"
	"net/http"
	"strings"
)

// moduleAccessMiddleware is a per-Mimi boundary. It does not trust Host,
// Forwarded or X-Forwarded-For and never changes the machine's VPN/firewall.
// Tailcat's authenticated sidecar and local administration use loopback; their
// own existing authentication/control paths remain responsible for access.
func (r *Router) moduleAccessMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if r.cfg.Network.TailscaleEnabled != nil && !r.moduleConnectionAllowed(req) {
			writeJSON(w, http.StatusForbidden, map[string]string{
				"error": "connection_disabled", "message": "此连接方式已在 Mimi Remote 中关闭。",
			})
			return
		}
		if !r.cfg.Codex.IsEnabled() && codexOnlyModulePath(req) {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"error": "runtime_disabled", "message": "Codex 已在 Mimi Remote 中关闭。",
			})
			return
		}
		next.ServeHTTP(w, req)
	})
}

func (r *Router) moduleConnectionAllowed(req *http.Request) bool {
	remote := moduleAddressIP(req.RemoteAddr)
	localAddr, ok := req.Context().Value(http.LocalAddrContextKey).(net.Addr)
	if !ok || remote == nil {
		return false
	}
	local := moduleAddressIP(localAddr.String())
	if local == nil {
		return false
	}
	if local.IsLoopback() {
		return remote.IsLoopback()
	}
	if moduleTailscaleIP(local) || moduleTailscaleIP(remote) {
		return r.cfg.Network.AllowsTailscale()
	}
	return r.cfg.Network.AllowLAN && local.IsPrivate()
}

func moduleAddressIP(address string) net.IP {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return nil
	}
	if i := strings.LastIndexByte(host, '%'); i >= 0 {
		host = host[:i]
	}
	return net.ParseIP(host)
}

func moduleTailscaleIP(ip net.IP) bool {
	if v4 := ip.To4(); v4 != nil {
		return v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
	}
	// Tailscale's IPv6 ULA range; checking a private address alone would
	// incorrectly treat it as LAN when the IPv4 wildcard policy evolves.
	_, prefix, _ := net.ParseCIDR("fd7a:115c:a1e0::/48")
	return ip != nil && prefix.Contains(ip)
}

func codexOnlyModulePath(req *http.Request) bool {
	switch req.URL.Path {
	case "/api/app-server/ws":
		// The gateway validates unknown sources itself. An omitted source is
		// the historic Codex route; Claude must remain usable independently.
		return normalizeAppServerRuntimeID(req.URL.Query().Get("runtime")) == "codex"
	}
	return strings.HasPrefix(req.URL.Path, "/api/debug/codex/") ||
		strings.HasPrefix(req.URL.Path, "/api/app-server/history-media/") ||
		strings.HasPrefix(req.URL.Path, "/api/app-server/history-output/")
}

func (r *Router) codexModulePlaceholder() runtimeAccountStatus {
	status := runtimeAccountStatus{ID: "codex", Title: "Codex", Enabled: r.cfg.Codex.IsEnabled(), State: runtimeStateUnavailable, Reason: "refresh_in_progress"}
	if !status.Enabled {
		status.State = runtimeStateDisabled
		status.Reason = "disabled"
	}
	return status
}

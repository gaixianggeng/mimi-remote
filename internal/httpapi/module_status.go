package httpapi

import (
	"context"
	"net/http"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func (r *Router) moduleStatusHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !runtimeStatusLoopbackRequest(req) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	tailscale, lan := r.networkAvailability(req.Context())
	writeJSON(w, http.StatusOK, config.ModuleStatus{
		CodexEnabled: r.cfg.Codex.IsEnabled(), ClaudeEnabled: r.cfg.Claude.Enabled, AgyEnabled: r.cfg.Agy.Enabled,
		TailscaleEnabled: r.cfg.TailscaleAccessEnabled(), LANEnabled: r.cfg.LANAccessEnabled(),
		TailscaleAvailable: tailscale, LANAvailable: lan,
	})
}

// LAN issuance asks the resident Windows service to inspect its effective
// executable/firewall rule and revoke sockets on denial before returning.
func (r *Router) confirmLANHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if !isLoopbackPairingRequest(req) || req.Header.Get("Origin") != "" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	code := "lan_firewall_blocked"
	if r.confirmLANPolicy != nil && r.cfg.LANAccessEnabled() {
		ctx, cancel := context.WithTimeout(req.Context(), 25*time.Second)
		defer cancel()
		code = r.confirmLANPolicy(ctx)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"allowed": code == "", "code": code})
}

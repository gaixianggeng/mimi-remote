package httpapi

import (
	"net/http"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
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
	tailscale, lan := networkaccess.Availability()
	writeJSON(w, http.StatusOK, config.ModuleStatus{
		CodexEnabled: r.cfg.Codex.IsEnabled(), ClaudeEnabled: r.cfg.Claude.Enabled,
		TailscaleEnabled: r.cfg.TailscaleAccessEnabled(), LANEnabled: r.cfg.LANAccessEnabled(),
		TailscaleAvailable: tailscale, LANAvailable: lan,
	})
}

package httpapi

import (
	"net/http"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func (r *Router) preflightHost(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !isLoopbackPairingRequest(req) || req.Header.Get("Origin") != "" {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	age := time.Since(time.Unix(0, r.preflightReadyAt.Load()))
	h := setup.PreflightHost{Version: r.version, Ready: age >= 0 && age <= 15*time.Second,
		Assistants: map[string]bool{"codex": r.cfg.Codex.IsEnabled(), "claude": r.cfg.Claude.Enabled, "agy": r.cfg.Agy.Enabled, "deepseek": r.cfg.DeepSeek.Enabled},
		Networks:   map[string]bool{"tailscale": r.cfg.TailscaleAccessEnabled(), "lan": r.cfg.LANAccessEnabled(), "tailcat": r.cfg.Tailcat.Enabled},
		Accounts:   r.runtimeStatus.preflightAccounts(), FolderDenied: r.doctor.CachedFolderDenied()}
	if s, ok := r.tailcat.(*tailcatSidecarSupervisor); ok && s.mu.TryLock() {
		h.Networks["tailcat"] = s.config.Enabled
		h.TailcatRunning = s.config.Enabled && s.cmd != nil && !s.starting && !s.closing && s.stoppingCmd == nil && !s.readyAt.IsZero()
		s.mu.Unlock()
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, h)
}

// Reading the existing generation must never schedule a refresh, even on miss.
func (c *runtimeStatusSnapshotCache) preflightAccounts() map[string]string {
	accounts := map[string]string{}
	if c == nil {
		return accounts
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || !c.hasResult || c.snapshot.CheckedAt == nil {
		return accounts
	}
	age := c.now().Sub(*c.snapshot.CheckedAt)
	ttl := c.successTTL
	if runtimeStatusHasFailure(c.snapshot) {
		ttl = c.failureTTL
	}
	if age < 0 || age >= ttl {
		return accounts
	}
	for _, s := range c.snapshot.Runtimes {
		switch {
		case s.ID == "codex" && s.State == runtimeStateUnavailable && (s.Reason == "upstream_unavailable" || s.Reason == "shared_local_session_unavailable"):
			accounts[s.ID] = "upstream_unavailable"
		case s.State == runtimeStateSignedOut:
			accounts[s.ID] = "signed_out"
		case s.State == runtimeStateConnected || s.State == runtimeStateAvailable && (s.ID == "deepseek" && s.Reason == "ready" || s.ID == "agy" && (s.Reason == "" || s.Reason == "quota_refresh_in_progress")):
			accounts[s.ID] = "connected"
		case s.ID == "deepseek" && s.Reason == "models_unavailable":
			accounts[s.ID] = "no_models"
		case s.ID == "deepseek" && s.Reason == "credentials_unavailable":
			accounts[s.ID] = "auth_failed"
		}
	}
	return accounts
}

package httpapi

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

func pairingFailure(code, step string) *tailcatActionFailure {
	status := http.StatusServiceUnavailable
	if code == "workspace_confirmation_required" {
		status = http.StatusConflict
	}
	d := setup.OnboardingDiagnostic(code, step, "pair", true, "")
	return &tailcatActionFailure{status: status, code: code, err: &setup.PairingDiagnostic{Code: code, Step: step, Message: d.Message}}
}

func writePairingFailure(w http.ResponseWriter, f *tailcatActionFailure) {
	var d *setup.PairingDiagnostic
	if errors.As(f.err, &d) {
		markPairingFailure(w, d.Code, d.Step)
	}
	if f.code == "no_enabled_assistant" {
		writeError(w, f.status, "全部 AI 编程助手已关闭，请先启用助手")
		return
	}
	writeError(w, f.status, f.err.Error())
}

// Only Tailcat switch/relay settings can be applied in-process. Other edits
// require a new Router and new assistant observations before pairing.
func (r *Router) appliedPairingGeneration() string {
	snap := config.ReadPreflightSnapshot(r.configPath)
	if !snap.Configured || snap.Code != "" || r.cfg.SourceGeneration() == "" {
		return ""
	}
	exact := snap.Config.SourceGeneration() == r.cfg.SourceGeneration()
	s, ok := r.tailcat.(*tailcatSidecarSupervisor)
	if !ok {
		if exact {
			return snap.Config.SourceGeneration()
		}
		return ""
	}
	if !exact && !r.cfg.SamePairingSettings(snap.Config) {
		return ""
	}
	s.mu.Lock()
	live := s.config
	s.mu.Unlock()
	saved := snap.Config.Tailcat
	if exact {
		saved = r.cfg.Tailcat
	}
	if live.Enabled != saved.Enabled || live.ConnectionMode() != saved.ConnectionMode() || live.DERPMapURL != saved.DERPMapURL || live.PreviousDERPMapURL != saved.PreviousDERPMapURL {
		return ""
	}
	return snap.Config.SourceGeneration()
}

// The caller has already authenticated the bearer, ticket, or native loopback
// request. Reinspect both the saved generation and roots after any probe wait.
func (r *Router) pairingGate(parent context.Context, route func(context.Context) *tailcatActionFailure) *tailcatActionFailure {
	ctx, cancel := context.WithTimeout(parent, 25*time.Second)
	defer cancel()
	if !r.cfg.WorkspaceConfirmed() {
		return pairingFailure("workspace_confirmation_required", "workspace_root")
	}
	if !r.cfg.HasEnabledAgent() {
		return pairingFailure("no_enabled_assistant", "assistant_any")
	}
	if r.pairingGeneration == nil {
		return pairingFailure("service_not_running", "service_daemon")
	}
	generation := r.pairingGeneration()
	if generation == "" {
		return pairingFailure("service_version_mismatch", "service_daemon")
	}
	if strings.TrimSpace(r.cfg.Auth.Token) == "" || r.doctor == nil || !r.doctor.RunReadiness(ctx).OK {
		return pairingFailure("pair_host_unreachable", "service_daemon")
	}
	if len(r.cfg.ScanRoots) == 0 || len(r.cfg.BrowseRoots) == 0 {
		return pairingFailure("workspace_confirmation_required", "workspace_root")
	}
	if failure := r.checkPairingAssistant(ctx, generation); failure != nil {
		return failure
	}
	if route != nil {
		if failure := route(ctx); failure != nil {
			return failure
		}
	}
	for _, roots := range [][]string{r.cfg.ScanRoots, r.cfg.BrowseRoots} {
		for _, path := range roots {
			path = config.ExpandPath(path)
			if !filepath.IsAbs(path) {
				return pairingFailure("workspace_not_found", "workspace_root")
			}
			if _, code := config.InspectWorkspaceRoot(path); code != "" {
				return pairingFailure(code, "workspace_root")
			}
		}
	}
	if ctx.Err() != nil {
		return pairingFailure("probe_timeout", "service_daemon")
	}
	if r.pairingGeneration() != generation {
		return pairingFailure("service_version_mismatch", "service_daemon")
	}
	// A slow policy or node check can outlive the evidence that admitted it.
	if !r.pairingStatus.stillFreshForPairing(generation) {
		return pairingFailure("probe_timeout", "assistant_any")
	}
	return nil
}

func (r *Router) directRoute(ctx context.Context, raw string) *tailcatActionFailure {
	bad := func() *tailcatActionFailure { return pairingFailure("network_selection_required", "network_any") }
	endpoint, err := url.Parse(raw)
	if err != nil || endpoint.Scheme != "http" || raw != "http://"+endpoint.Host {
		return bad()
	}
	address, err := netip.ParseAddrPort(endpoint.Host)
	if err != nil || address.Port() == 0 || address.Addr().Zone() != "" {
		return bad()
	}
	ip := address.Addr()
	switch {
	case tailscaleinfo.IsTailscaleAddress(ip):
		if !r.cfg.TailscaleAccessEnabled() {
			return bad()
		}
		if !r.directReachable(ctx, net.TCPAddrFromAddrPort(address)) {
			return pairingFailure("tailscale_not_connected", "network_tailscale")
		}
	case ip.Is4() && ip.IsPrivate():
		if !r.cfg.LANAccessEnabled() {
			return bad()
		}
		if !r.directReachable(ctx, net.TCPAddrFromAddrPort(address)) {
			return pairingFailure("lan_unavailable", "network_lan")
		}
		if r.confirmLANPolicy != nil {
			if code := r.confirmLANPolicy(ctx); code != "" {
				return pairingFailure(code, "network_lan")
			}
		}
	default:
		return bad()
	}
	return nil
}

func (r *Router) tailcatRoute(ctx context.Context) *tailcatActionFailure {
	if r.tailcat != nil {
		s := r.tailcat.Status(ctx)
		if s.Enabled && s.Running && s.Error == "" {
			return nil
		}
	}
	return pairingFailure("tailcat_relay_unreachable", "network_tailcat")
}

func (r *Router) localPairIssue(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if !r.isAuthorizedTailcatLocalRequest(req) {
		writeError(w, http.StatusForbidden, "本机配对控制凭据无效")
		return
	}
	var input struct {
		Network             setup.PairingNetwork
		Version, Generation string
	}
	if !decodeJSONRequest(w, req, &input) {
		return
	}
	fail := func(f *tailcatActionFailure) {
		step := "network_tailcat"
		var diagnostic *setup.PairingDiagnostic
		if errors.As(f.err, &diagnostic) {
			step = diagnostic.Step
		}
		writeJSON(w, f.status, map[string]string{"code": f.code, "step": step, "error": f.err.Error()})
	}
	if input.Version == "" || !setup.AgentVersionsCompatible(input.Version, r.version) || input.Generation == "" || input.Generation != r.pairingGeneration() {
		fail(pairingFailure("service_version_mismatch", "service_daemon"))
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 25*time.Second)
	defer cancel()
	if input.Network == setup.PairingNetworkTailcat {
		if !r.tailcatControlMu.TryLock() {
			fail(pairingFailure("tailcat_busy", "network_tailcat"))
			return
		}
		defer r.tailcatControlMu.Unlock()
		status, f := r.pairTailcat(ctx)
		if f != nil {
			fail(f)
			return
		}
		pair, f := r.signTailcatPair(ctx, status)
		if f != nil {
			fail(f)
			return
		}
		if input.Generation != r.pairingGeneration() {
			fail(pairingFailure("service_version_mismatch", "service_daemon"))
			return
		}
		writeJSON(w, http.StatusOK, pair)
		return
	}
	network, err := setup.ParsePairingNetwork(string(input.Network))
	if err != nil {
		writeError(w, http.StatusBadRequest, "配对网络无效")
		return
	}
	var candidate setup.Result
	if f := r.pairingGate(ctx, func(ctx context.Context) *tailcatActionFailure {
		var failure *tailcatActionFailure
		candidate, failure = r.liveDirectCandidate(ctx, network)
		return failure
	}); f != nil {
		fail(f)
		return
	}
	if r.pairingGeneration() != input.Generation {
		fail(pairingFailure("service_version_mismatch", "service_daemon"))
		return
	}
	writeJSON(w, http.StatusOK, candidate.SignDirectPair())
}

func (r *Router) liveDirectCandidate(ctx context.Context, network setup.PairingNetwork) (setup.Result, *tailcatActionFailure) {
	candidate, err := r.directCandidate(ctx, r.configPath, r.cfg, network)
	if err != nil {
		var d *setup.PairingDiagnostic
		if errors.As(err, &d) {
			return setup.Result{}, pairingFailure(d.Code, d.Step)
		}
		return setup.Result{}, pairingFailure("pair_host_unreachable", "service_daemon")
	}
	if failure := r.directRoute(ctx, candidate.Endpoint); failure != nil {
		if network == setup.PairingNetworkAuto && candidate.Network == setup.PairingNetworkTailscale && r.cfg.LANAccessEnabled() {
			return r.liveDirectCandidate(ctx, setup.PairingNetworkLAN)
		}
		return setup.Result{}, failure
	}
	return candidate, nil
}

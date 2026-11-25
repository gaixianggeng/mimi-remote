package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// System metadata on an unavailable mount may outlive the request. Keep those
// workers separately bounded across overlapping requests; runtime discovery
// and its child processes have their own slots.
var preflightSlots = make(chan struct{}, 24)

func boundedPreflight[T any](ctx context.Context, fn func() T) (T, bool) {
	var zero T
	if ctx.Err() != nil {
		return zero, false
	}
	select {
	case preflightSlots <- struct{}{}:
	case <-ctx.Done():
		return zero, false
	}
	result := make(chan T, 1)
	go func() {
		defer func() { <-preflightSlots }()
		result <- fn()
	}()
	select {
	case v := <-result:
		return v, true
	case <-ctx.Done():
		return zero, false
	}
}

func RunPreflight(ctx context.Context, o PreflightOptions, progress func(PreflightCheck)) PreflightReport {
	return InspectPreflight(cliinspect.WithParentLifetime(ctx), o, PreflightProbes{Platform: runtime.GOOS, Host: FetchPreflightHost, Member: observePreflightMember, HomebrewOwner: preflightHomebrewOwner}, progress)
}

func InspectPreflight(parent context.Context, o PreflightOptions, p PreflightProbes, progress func(PreflightCheck)) PreflightReport {
	ctx, cancel := context.WithTimeout(parent, 20*time.Second)
	defer cancel()
	if o.Stage == "" {
		o.Stage = "setup"
	}
	if o.ConfigPath == "" {
		o.ConfigPath = config.DefaultPath()
	}
	r := PreflightReport{Schema: "mimi.onboarding.preflight/v1", Stage: o.Stage, ConfigPath: config.ExpandPath(o.ConfigPath), Checks: preflightRows(p.Platform)}
	indices := map[string]int{}
	for i, row := range r.Checks {
		indices[row.ID] = i
		if progress != nil {
			progress(row)
		}
	}
	metadataCtx, stopMetadata := context.WithTimeout(ctx, 2*time.Second)
	snapshot, ok := boundedPreflight(metadataCtx, func() config.PreflightSnapshot { return config.ReadPreflightSnapshot(r.ConfigPath) })
	stopMetadata()
	if !ok {
		snapshot.Code = "probe_timeout"
	}
	r.Configured, r.WorkspaceConfirmed = snapshot.Configured, snapshot.Confirmed
	cfg := snapshot.Config
	complete := func(id, code string) {
		row := &r.Checks[indices[id]]
		row.finish(&r, code)
		if row.ID == "service_daemon" && code == "pair_host_unreachable" {
			row.Detail = "后台服务已响应，尚无近期的就绪检查记录。请在启动完成后重新检查。"
		}
		if r.Stage == "setup" && strings.HasSuffix(code, "_signed_out") && !explicitAssistant(o, snapshot, row.ID) {
			row.State = "optional"
		}
		if progress != nil {
			progress(*row)
		}
	}
	pair := r.Stage == "pair"
	code := snapshot.Code
	if pair && code == "" && !r.Configured {
		code = "config_missing"
	}
	if code == "config_invalid" || code == "config_recovery_required" || code == "legacy_codex_residue" {
		r.Checks[indices["config_store"]].ConfigPath = "<配置目录>/config.json"
	}
	complete("config_store", code)
	home, _ := os.UserHomeDir()
	scan, scanValid := proposedRoot(o.ScanRoot, cfg.ScanRoots, filepath.Join(home, "code"))
	browse, browseValid := proposedRoot(o.BrowseRoot, cfg.BrowseRoots, scan)
	r.ScanRoot, r.BrowseRoot = scan, browse
	type rootResult struct {
		exists bool
		code   string
	}
	rootCtx, stopRoots := context.WithTimeout(ctx, 2*time.Second)
	roots, ok := boundedPreflight(rootCtx, func() rootResult {
		if !scanValid {
			return rootResult{false, "workspace_not_found"}
		}
		exists, code := config.InspectWorkspaceRoot(scan)
		if !browseValid && code == "" {
			code = "workspace_not_found"
		}
		if code == "" && browse != scan {
			_, code = config.InspectWorkspaceRoot(browse)
		}
		if pair && code == "" {
			for _, stored := range [][]string{cfg.ScanRoots, cfg.BrowseRoots} {
				for i := 1; i < len(stored); i++ {
					if rootCtx.Err() != nil {
						return rootResult{exists, "probe_timeout"}
					}
					path := config.ExpandPath(stored[i])
					if !filepath.IsAbs(path) {
						return rootResult{exists, "workspace_not_found"}
					}
					if _, code := config.InspectWorkspaceRoot(path); code != "" {
						return rootResult{exists, code}
					}
				}
			}
		}
		return rootResult{exists, code}
	})
	stopRoots()
	if !ok {
		roots.code = "probe_timeout"
	}
	r.ScanRootExists = roots.exists
	if pair && roots.code == "" && (!r.WorkspaceConfirmed || len(cfg.ScanRoots) == 0 || len(cfg.BrowseRoots) == 0) {
		roots.code = "workspace_confirmation_required"
	}
	complete("workspace_root", roots.code)

	var host PreflightHost
	serviceCode := "service_not_running"
	if snapshot.Configured && snapshot.Code == "" && p.Host != nil {
		type hostResult struct {
			h   PreflightHost
			err error
		}
		peekCtx, stop := context.WithTimeout(ctx, 2*time.Second)
		result, done := boundedPreflight(peekCtx, func() hostResult { h, e := p.Host(peekCtx, cfg); return hostResult{h, e} })
		stop()
		var hostErr PreflightHostError
		switch {
		case !done:
			serviceCode = "probe_timeout"
		case errors.As(result.err, &hostErr):
			serviceCode = string(hostErr)
		case result.err != nil:
		case !AgentVersionsCompatible(o.Version, result.h.Version):
			serviceCode = "service_version_mismatch"
		default:
			host, serviceCode = result.h, ""
			if !host.Ready {
				serviceCode = "pair_host_unreachable"
			}
		}
	}
	complete("service_daemon", serviceCode)
	for _, row := range r.Checks {
		if row.Group == "permission" {
			code := "permission_unobserved"
			if row.ID == "permission_folder_access" && host.FolderDenied {
				code = "permission_folder_denied"
			}
			complete(row.ID, code)
		}
	}
	type result struct {
		id          string
		observation PreflightObservation
	}
	results := make(chan result, len(r.Checks))
	pending := map[string]bool{}
	for _, row := range r.Checks {
		if row.Enabled == nil && row.ID != "service_owner_conflict" {
			continue
		}
		id := row.ID
		pending[id] = true
		go func() {
			obs, ok := boundedPreflight(ctx, func() PreflightObservation {
				if id == "service_owner_conflict" {
					if p.HomebrewOwner != nil && p.HomebrewOwner(ctx) {
						return PreflightObservation{Code: "homebrew_service_active"}
					}
					return PreflightObservation{}
				}
				return p.Member(ctx, id, cfg, o.RuntimePaths[strings.TrimPrefix(id, "assistant_")], host)
			})
			if !ok {
				obs = PreflightObservation{Code: "probe_timeout"}
			}
			results <- result{id, obs}
		}()
	}
	for len(pending) > 0 {
		var res result
		select {
		case res = <-results:
		case <-ctx.Done():
			// Finalize unobserved members even when a kernel call has not returned.
			for id := range pending {
				res = result{id, PreflightObservation{Code: "probe_timeout"}}
				break
			}
		}
		if !pending[res.id] {
			continue
		}
		delete(pending, res.id)
		row := &r.Checks[indices[res.id]]
		code := res.observation.Code
		if row.Enabled != nil {
			code = projectMember(row, res.observation, o, cfg, r.Configured, host)
		}
		complete(res.id, code)
		if row.Enabled != nil {
			aggregate := row.Group + "_any"
			if r.Checks[indices[aggregate]].State == "checking" {
				if ready, code := r.aggregate(row.Group); ready {
					complete(aggregate, code)
				}
			}
		}
	}
	r.OK = true
	r.RecommendedNext = "network_any"
	if !pair && !r.Configured {
		r.RecommendedNext = "config_store"
	}
	for _, row := range r.Checks {
		if row.Group == "network" && row.Available != nil && *row.Available != nil && **row.Available && r.RecommendedTransport == nil {
			name := strings.TrimPrefix(row.ID, "network_")
			r.RecommendedTransport = &name
		}
		if r.OK && row.Blocking {
			r.RecommendedNext = row.ID
			r.OK = false
		}
	}
	return r
}

func proposedRoot(override string, stored []string, fallback string) (string, bool) {
	if override != "" {
		return config.ExpandPath(override), true
	}
	if len(stored) > 0 {
		if root := config.ExpandPath(stored[0]); filepath.IsAbs(root) {
			return root, true
		}
		return fallback, false
	}
	return fallback, true
}

func (r *PreflightReport) aggregate(group string) (bool, string) {
	pending := false
	var route string
	for _, m := range r.Checks {
		if m.Group != group || m.Enabled == nil {
			continue
		}
		if m.State == "ok" {
			return true, ""
		}
		if m.State == "checking" {
			pending = true
		}
		if m.Available != nil && *m.Available != nil && **m.Available && route == "" {
			route = strings.TrimPrefix(m.ID, "network_")
		}
	}
	if pending {
		return false, ""
	}
	if group == "assistant" {
		return true, "no_enabled_assistant"
	}
	if route == "" {
		return true, "no_network_available"
	}
	r.RecommendedTransport = &route
	if route == "tailcat" {
		for _, m := range r.Checks {
			if m.ID == "network_lan" && m.Available != nil && *m.Available != nil && **m.Available {
				return true, "network_selection_required"
			}
		}
		return true, "no_direct_network"
	}
	return true, "network_selection_required"
}

func (row *PreflightCheck) finish(r *PreflightReport, code string) {
	if code == "" {
		row.State = "ok"
		row.Detail = "检查通过。"
		return
	}
	row.Code = code
	row.State = preflightDiagnostics[code].state
	if row.State == "optional" && row.Enabled != nil && *row.Enabled && code != "runtime_unsupported_platform" {
		row.State = "action_needed"
	}
	switch row.ID {
	case "workspace_root", "config_store":
		row.Blocking = r.Stage == "pair" || row.State == "error"
	case "service_daemon", "assistant_any", "network_any":
		row.Blocking = r.Stage == "pair"
	}
	route := ""
	if r.RecommendedTransport != nil {
		route = *r.RecommendedTransport
	}
	d := OnboardingDiagnostic(code, row.ID, r.Stage, r.Configured, route)
	row.Fix, row.Detail = &d.Fix, d.Message
}

func projectMember(row *PreflightCheck, obs PreflightObservation, o PreflightOptions, cfg config.Config, configured bool, host PreflightHost) string {
	_, name, _ := strings.Cut(row.ID, "_")
	available := obs.Available != nil && *obs.Available
	row.Available = &obs.Available
	if row.Candidates != nil {
		if obs.Candidates != nil {
			row.Candidates = &obs.Candidates
		}
		row.Source, row.DetectedVersion, row.MinVersion = obs.Source, obs.DetectedVersion, obs.MinVersion
	}
	enabled := false
	if o.Stage == "pair" {
		if row.Group == "assistant" {
			enabled = host.Assistants[name]
		} else {
			enabled = host.Networks[name]
		}
	} else if row.Group == "assistant" {
		switch o.Assistants[name] {
		case "enabled":
			enabled = true
		case "disabled":
		case "auto":
			enabled = available
		default:
			if configured {
				switch name {
				case "codex":
					enabled = cfg.Codex.IsEnabled()
				case "claude":
					enabled = cfg.Claude.Enabled
				case "agy":
					enabled = cfg.Agy.Enabled
				case "deepseek":
					enabled = cfg.DeepSeek.Enabled
				}
			} else {
				enabled = name != "deepseek" && available
			}
		}
	} else if configured {
		switch name {
		case "tailscale":
			enabled = cfg.TailscaleAccessEnabled()
		case "lan":
			enabled = cfg.LANAccessEnabled()
		case "tailcat":
			enabled = cfg.Tailcat.Enabled
		}
	}
	row.Enabled = &enabled
	if obs.Code != "" {
		return obs.Code
	}
	if !available {
		return "probe_timeout"
	}
	if enabled {
		return ""
	}
	if row.Group == "assistant" {
		return "assistant_disabled"
	}
	return name + "_disabled"
}

func explicitAssistant(o PreflightOptions, s config.PreflightSnapshot, id string) bool {
	name := strings.TrimPrefix(id, "assistant_")
	if intent := o.Assistants[name]; intent != "" {
		return intent == "enabled"
	}
	if !s.Configured {
		return false
	}
	switch name {
	case "codex":
		return s.Config.Codex.Activation == "enabled" || s.Config.Codex.Activation == "" && s.Config.Codex.Enabled != nil && *s.Config.Codex.Enabled
	case "claude":
		return s.ClaudeActivation == "enabled" || s.ClaudeActivation == "" && s.Config.Claude.Enabled
	case "agy":
		return s.Config.Agy.Activation == "enabled" || s.Config.Agy.Activation == "" && s.Config.Agy.Enabled
	}
	return false
}

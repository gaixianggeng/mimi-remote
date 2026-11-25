package setup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func knownAvailability(ok bool) *bool { return &ok }
func unavailable(code string) PreflightObservation {
	return PreflightObservation{Code: code, Available: knownAvailability(false)}
}

func inspectPreflightRuntime(ctx context.Context, name string, cfg config.Config, override string, host PreflightHost) PreflightObservation {
	if name == "deepseek" {
		switch host.Accounts[name] {
		case "connected":
			return PreflightObservation{Available: knownAvailability(true)}
		case "auth_failed", "signed_out":
			return unavailable("deepseek_auth_failed")
		case "no_models":
			return unavailable("deepseek_no_models")
		}
		if cfg.DeepSeek.BaseURL == "" {
			probe, stop := context.WithTimeout(ctx, 2*time.Second)
			defer stop()
			if _, err := currentDeepSeekLaunchAgentPID(probe); err != nil {
				if probe.Err() != nil {
					return PreflightObservation{Code: "probe_timeout"}
				}
				return unavailable("deepseek_not_running")
			}
		}
		if cfg.DeepSeek.BaseURL != "" {
			if cfg.DeepSeek.TokenFile == "" {
				return unavailable("deepseek_auth_failed")
			}
			if _, err := os.Lstat(config.ExpandPath(cfg.DeepSeek.TokenFile)); errors.Is(err, os.ErrNotExist) {
				return unavailable("deepseek_auth_failed")
			}
		}
		// Harness API access exchanges a startup token for a new session. Wait
		// for existing authenticated evidence instead of renewing that credential.
		return PreflightObservation{Code: "runtime_probe_failed"}
	}
	if name == "codex" && cfg.AppServer.Transport == "ssh" {
		// Never start ssh for a poll. A remote runtime has its own executable and
		// account; a locally installed CLI cannot provide evidence for either.
		switch host.Accounts[name] {
		case "connected", "signed_out":
			obs := PreflightObservation{Available: knownAvailability(true), Candidates: []PreflightCandidate{{Path: "<已连接的 SSH 主机>/codex", Outcome: "selected"}}}
			if host.Accounts[name] == "signed_out" {
				obs.Available = knownAvailability(false)
				obs.Code = "codex_signed_out"
			}
			return obs
		}
		return PreflightObservation{Code: "codex_upstream_unavailable"}
	}
	req := CodexRuntime(cfg.Codex, cfg.AppServer.Transport)
	req.MinimumVersion = appserver.MinimumCodexVersion
	adapterCode := ""
	if name == "codex" {
		// Even --version and app-server --help create argument shims in CODEX_HOME.
		// Point these two metadata commands at a known non-directory. Account
		// evidence below still reads the original, effective runtime home.
		executable, err := os.Executable()
		if err != nil {
			return PreflightObservation{Code: "runtime_probe_failed"}
		}
		env := req.Environment[:0]
		for _, entry := range req.Environment {
			key, _, _ := strings.Cut(entry, "=")
			if !strings.EqualFold(key, "CODEX_HOME") {
				env = append(env, entry)
			}
		}
		req.Environment = append(env, "CODEX_HOME="+executable)
	} else {
		req, adapterCode = preflightAdapter(ctx, name, cfg)
	}
	req.Override = override
	d := NewRuntimeDiscovery()
	if req.MinimumVersion != "" && publicRuntimeVersion(req.MinimumVersion) == "" {
		return PreflightObservation{Code: "runtime_probe_failed"}
	}
	obs := PreflightObservation{MinVersion: publicRuntimeVersion(req.MinimumVersion)}
	selected := map[string]int{}
	candidate, err := d.resolve(ctx, req, func(path, version, outcome string) {
		selected[path] = len(obs.Candidates)
		// The UI's picker returns its own executable. Never send the actual user
		// path, which may include an account name or an arbitrary secret.
		alias := fmt.Sprintf("<候选程序 %d>/%s", len(obs.Candidates)+1, name)
		obs.Candidates = append(obs.Candidates, PreflightCandidate{Path: alias, Version: publicRuntimeVersion(version), Outcome: outcome})
	})
	obs.Source = candidate.Source
	if obs.Source == "override" {
		obs.Source = "pin"
	}
	obs.DetectedVersion = publicRuntimeVersion(candidate.Version)
	switch {
	case ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded):
		obs.Code = "probe_timeout"
	case err != nil && (candidate.Source == "override" || candidate.Source == "pin" || candidate.Source == "env"):
		obs.Code = "runtime_path_invalid"
		obs.Available = knownAvailability(false)
	case adapterCode != "":
		obs.Code = adapterCode
		obs.Available = knownAvailability(false)
	case errors.Is(err, ErrRuntimeIncompatible):
		obs.Code = "runtime_incompatible"
		obs.Available = knownAvailability(false)
		if req.MinimumVersion != "" && claudebridge.Compare(candidate.Version, req.MinimumVersion) < 0 {
			obs.Code = name + "_version_too_old"
		}
	case errors.Is(err, os.ErrNotExist) || errors.Is(err, exec.ErrNotFound):
		obs.Code = name + "_not_found"
		obs.Available = knownAvailability(false)
	case err != nil:
		obs.Code = "runtime_probe_failed"
	default:
		obs.Candidates[selected[candidate.Path]].Outcome = "selected"
		// An explicit picker may name a different installation/account from the
		// running service. Inspect its own account when a passive query exists.
		account := ""
		if override == "" {
			account = host.Accounts[name]
		}
		if account == "" {
			account = passiveFileAccount(cfg, name)
		}
		switch account {
		case "upstream_unavailable":
			if name == "codex" {
				obs.Code = "codex_upstream_unavailable"
				obs.Available = knownAvailability(false)
			} else {
				obs.Code = "runtime_probe_failed"
			}
		case "connected":
			obs.Available = knownAvailability(true)
		case "signed_out":
			obs.Code = name + "_signed_out"
			obs.Available = knownAvailability(false)

		default:
			obs.Code = "runtime_probe_failed"
		}
	}
	return obs
}

func preflightAdapter(parent context.Context, name string, cfg config.Config) (RuntimeRequest, string) {
	ctx, stop := context.WithTimeout(parent, 4*time.Second)
	defer stop()
	if name == "agy" {
		req := AgyRuntime(cfg.Agy, "", agybridge.BuildEnv(cfg.Agy.Env))
		path, ok := agybridge.ResolveBinary(cfg.Agy.AdapterBin)
		if !ok {
			return req, "agy_adapter_missing"
		}
		caps, err := agybridge.ReadAdapterCapabilities(ctx, path, cfg.Agy.Args, req.Environment)
		if ctx.Err() != nil {
			return req, "probe_timeout"
		}
		if err != nil || !agybridge.IsSupported(caps.Version) {
			return req, "agy_adapter_missing"
		}
		req.MinimumVersion = caps.Agy.MinimumVersion
		return req, ""
	}
	req := ClaudeRuntime(cfg.Claude, "", claudeCommandEnvironment(cfg.Claude.Env))
	path, ok := claudebridge.ResolveBinary(cfg.Claude.BridgeBin, cfg.Claude.LegacyBridge)
	if !ok {
		return req, "claude_bridge_missing"
	}
	banner, err := cliinspect.Stdout(ctx, path, req.Environment, append(append([]string{}, cfg.Claude.Args...), "--version")...)
	v, parsed := claudebridge.ParseVersion(string(banner))
	if ctx.Err() != nil {
		return req, "probe_timeout"
	}
	if err != nil || !parsed || !claudebridge.IsSupported(v) {
		return req, "claude_bridge_missing"
	}
	if claudebridge.IsAdapterVersionOutput(string(banner)) {
		caps, err := claudebridge.ReadAdapterCapabilities(ctx, path, cfg.Claude.Args, req.Environment)
		if ctx.Err() != nil {
			return req, "probe_timeout"
		}
		if err != nil {
			return req, "claude_bridge_missing"
		}
		req.MinimumVersion = caps.ClaudeCode.MinimumVersion
	}
	return req, ""
}

// Banners and adapter capabilities are child output. Only the public numeric
// release component is useful to a picker; arbitrary build labels stay local.
var releaseVersion = regexp.MustCompile(`^([0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9})(?:[-+][A-Za-z0-9.+-]{1,64})?$`)

func publicRuntimeVersion(raw string) string {
	m := releaseVersion.FindStringSubmatch(raw)
	if m == nil {
		return ""
	}
	return m[1]
}

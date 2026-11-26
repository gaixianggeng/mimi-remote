package setup

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
	"github.com/gaixianggeng/mimi-remote/internal/tailcatsidecar"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

func observePreflightMember(ctx context.Context, id string, cfg config.Config, override string, host PreflightHost) PreflightObservation {
	if name, ok := strings.CutPrefix(id, "assistant_"); ok {
		return inspectPreflightRuntime(ctx, name, cfg, override, host)
	}
	switch id {
	case "network_tailscale":
		ip := tailscaleinfo.FirstIPv4(ctx)
		if ip != "" && tailscaleinfo.TunnelAvailable(ctx) {
			break
		}
		if _, err := tailscaleinfo.FindCLI(); err != nil {
			return unavailable("tailscale_not_installed")
		}
		return unavailable("tailscale_not_connected")
	case "network_tailcat":
		path, err := tailcatsidecar.Resolve(cfg.Tailcat.SidecarBin)
		if err != nil {
			return unavailable("tailcat_unavailable")
		}
		child, stop := context.WithTimeout(ctx, 4*time.Second)
		defer stop()
		raw, err := cliinspect.Stdout(child, path, nil, "version")
		if child.Err() != nil {
			return PreflightObservation{Code: "probe_timeout"}
		}
		v := strings.TrimSpace(string(raw))
		if err != nil || v == "" || len(v) > 64 || strings.ContainsAny(v, "\r\n") {
			return unavailable("tailcat_unavailable")
		}
		if host.Networks["tailcat"] && !host.TailcatRunning {
			return unavailable("tailcat_relay_unreachable")
		}
	case "network_lan":
		enabled, applied := host.Networks["lan"]
		if !applied {
			enabled = cfg.LANAccessEnabled()
		}
		var code string
		if enabled && host.LANPolicyCode != nil {
			// The resident service already watches the rule for its executable.
			// Keep passive preflight within budget on PowerShell cold starts.
			code = *host.LANPolicyCode
			switch code {
			case "", "probe_timeout", "lan_public_network_blocked", "lan_firewall_blocked":
			default:
				code = "lan_firewall_blocked"
			}
		} else {
			code = preflightLANPolicy(ctx, enabled)
		}
		if code != "" {
			if code == "probe_timeout" {
				return PreflightObservation{Code: code}
			}
			return unavailable(code)
		}
		_, lan := networkaccess.AvailabilityContext(ctx)
		if !lan {
			return unavailable("lan_unavailable")
		}

	}
	return PreflightObservation{Available: knownAvailability(true)}
}

func preflightHomebrewOwner(ctx context.Context) bool {
	child, stop := context.WithTimeout(ctx, time.Second)
	defer stop()
	output, err := cliinspect.Stdout(child, "/bin/launchctl", nil, "print", fmt.Sprintf("gui/%d/homebrew.mxcl.%s", os.Getuid(), config.AppName))
	return err == nil && strings.Contains(string(output), "state = running")
}

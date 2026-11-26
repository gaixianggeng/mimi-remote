package httpapi

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
)

const (
	pairingEvidenceTTL    = 15 * time.Second
	pairingRefreshTimeout = 20 * time.Second
)

type pairingProbeMode int

const (
	explicitPairing pairingProbeMode = iota
	passivePairing
)

// Pairing joins a probe already in flight. The menu's manual Refresh requests
// a subsequent generation, which can exceed the entire pairing budget.
func (c *runtimeStatusSnapshotCache) pairingSnapshot(ctx context.Context, generation string, mode pairingProbeMode) runtimeStatusResponse {
	c.mu.Lock()
	defer c.mu.Unlock()
	for generation != "" && !c.closed && ctx.Err() == nil {
		if generation == c.pairingGeneration {
			snapshot, fresh := c.freshPairingSnapshotLocked()
			if fresh && !c.needsExplicitRefresh(mode, snapshot) {
				return snapshot
			}
		}
		if !c.refreshing {
			// This cache has one in-flight refresh. Never relabel an active
			// probe or its evidence when another configuration becomes live.
			c.hasResult = false
			c.pairingGeneration = generation
			c.pairingMode = mode
			probe := c.probe
			if mode == passivePairing {
				probe = c.passivePairingProbe
			}
			c.startProbeLocked(probe)
		}
		joined := c.pairingGeneration == generation
		target := c.refreshGen
		done := c.refreshDoneLocked(target)
		c.mu.Unlock()
		select {
		case <-ctx.Done():
		case <-done:
		}
		c.mu.Lock()
		// A waiter for another generation may start or join its refresh using
		// the time remaining from its original 20-second budget.
		if !joined || (c.refreshing && c.refreshGen != target) {
			continue
		}
		if c.closed || ctx.Err() != nil || c.publishedGen < target || c.pairingGeneration != generation {
			return runtimeStatusResponse{}
		}
		snapshot, fresh := c.freshPairingSnapshotLocked()
		if fresh && c.needsExplicitRefresh(mode, snapshot) {
			continue
		}
		return snapshot
	}
	return runtimeStatusResponse{}
}

// An explicit action can start an adapter that passive discovery found offline.
func (c *runtimeStatusSnapshotCache) needsExplicitRefresh(mode pairingProbeMode, snapshot runtimeStatusResponse) bool {
	return mode == explicitPairing && c.pairingMode == passivePairing && len(snapshot.Runtimes) == 0
}

func (c *runtimeStatusSnapshotCache) freshPairingSnapshotLocked() (runtimeStatusResponse, bool) {
	if c.hasResult && c.snapshot.CheckedAt != nil {
		age := c.now().Sub(*c.snapshot.CheckedAt)
		if age >= 0 && age <= pairingEvidenceTTL {
			return c.snapshot, true
		}
	}
	return runtimeStatusResponse{}, false
}

func (c *runtimeStatusSnapshotCache) stillFreshForPairing(generation string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	snapshot, fresh := c.freshPairingSnapshotLocked()
	return !c.closed && c.pairingGeneration == generation && fresh && len(snapshot.Runtimes) > 0
}

func (r *Router) checkPairingAssistant(ctx context.Context, generation string, mode pairingProbeMode) *tailcatActionFailure {
	if r.pairingStatus == nil || !r.cfg.HasEnabledAgent() {
		return pairingFailure("no_enabled_assistant", "assistant_any")
	}
	ctx, cancel := context.WithTimeout(ctx, pairingRefreshTimeout)
	defer cancel()
	snapshot := r.pairingStatus.pairingSnapshot(ctx, generation, mode)
	if ctx.Err() != nil || snapshot.CheckedAt == nil {
		return pairingFailure("probe_timeout", "assistant_any")
	}
	for _, row := range snapshot.Runtimes {
		if row.Enabled && row.State == runtimeStateAvailable && r.pairingAssistantEnabled(row.ID) {
			return nil
		}
	}
	return pairingFailure("no_enabled_assistant", "assistant_any")
}

func (r *Router) pairingAssistantEnabled(id string) bool {
	switch id {
	case "codex":
		return r.cfg.Codex.IsEnabled()
	case "claude":
		return r.cfg.Claude.Enabled
	case "agy":
		return r.cfg.Agy.Enabled
	case "deepseek":
		return r.cfg.DeepSeek.Enabled
	}
	return false
}

// Publish the first usable assistant as soon as its account and handshake are
// known. Waiting for a slow sibling could age an otherwise current observation.
func (r *Router) refreshPairingAssistants(ctx context.Context, mode pairingProbeMode) runtimeStatusResponse {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	probes := [...]struct {
		id      string
		timeout time.Duration
		run     func(context.Context, pairingProbeMode) bool
	}{
		{"codex", codexRuntimeProbeTimeout, r.pairingCodex},
		{"claude", 8 * time.Second, r.pairingClaude},
		{"agy", pairingRefreshTimeout, r.pairingAgy},
		{"deepseek", 4 * time.Second, r.pairingDeepSeek},
	}
	results := make(chan runtimeAccountStatus, len(probes))
	pending := 0
	timedOut := false
	for i, probe := range probes {
		if !r.pairingAssistantEnabled(probe.id) {
			continue
		}
		slot := &r.pairingWorkers.slots[i]
		if !slot.TryLock() {
			timedOut = true
			continue
		}
		pending++
		r.pairingWorkers.wg.Go(func() {
			probeCtx, stop := context.WithTimeout(ctx, probe.timeout)
			status := runtimeAccountStatus{ID: probe.id, Enabled: true, State: runtimeStateUnavailable}
			if probe.run(probeCtx, mode) && probeCtx.Err() == nil {
				status.State = runtimeStateAvailable
			} else if probeCtx.Err() != nil {
				status.Reason = "probe_timeout"
			}
			stop()
			slot.Unlock()
			results <- status
		})
	}
	for ; pending > 0; pending-- {
		select {
		case <-ctx.Done():
			return runtimeStatusResponse{}
		case row := <-results:
			timedOut = timedOut || row.Reason == "probe_timeout"
			if row.State == runtimeStateAvailable {
				now := time.Now().UTC()
				return runtimeStatusResponse{CheckedAt: &now, Runtimes: []runtimeAccountStatus{row}}
			}
		}
	}
	if timedOut {
		return runtimeStatusResponse{}
	}
	now := time.Now().UTC()
	return runtimeStatusResponse{CheckedAt: &now}
}

func (r *Router) pairingCodex(ctx context.Context, mode pairingProbeMode) bool {
	// A local or SSH connection can activate the Mac launchd front door.
	// Discovery can reuse an account observed by a host status request.
	if mode == passivePairing && !strings.EqualFold(r.cfg.AppServer.Transport, "ws") {
		return false
	}
	status := r.readCodexRuntime(ctx, false)
	if mode == explicitPairing && status.Reason == "upstream_unavailable" && ctx.Err() == nil && r.appServerSSH != nil {
		if r.appServerSSH.EnsureReady(ctx) == nil {
			status = r.readCodexRuntime(ctx, false)
		}
	}
	return codexPairingAccount(status)
}

func codexPairingAccount(status runtimeAccountStatus) bool {
	// A supported account selected by the running upstream is sufficient.
	// Spend-based provider accounts do not have a non-billable turn probe.
	return status.Version != "" && (status.State == runtimeStateConnected || status.State == runtimeStateAvailable &&
		(status.AuthMode == "api_key" || status.AuthMode == "bedrock"))
}

// Publish the account observation before the optional quota request. A passive
// discovery request may use it for 15 seconds without dialing an activation socket.
func (c *runtimeStatusSnapshotCache) observeCodexAccount(generation string, status runtimeAccountStatus) {
	if c == nil || generation == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.refreshing || (c.pairingGeneration != "" && c.pairingGeneration != generation) {
		return
	}
	if !codexPairingAccount(status) {
		if len(c.snapshot.Runtimes) == 1 && c.snapshot.Runtimes[0].ID == "codex" {
			c.hasResult = false
		}
		return
	}
	now := c.now()
	c.snapshot = runtimeStatusResponse{CheckedAt: &now, Runtimes: []runtimeAccountStatus{{ID: "codex", Enabled: true, State: runtimeStateAvailable}}}
	c.pairingGeneration, c.hasResult = generation, true
}

func (r *Router) pairingDeepSeek(ctx context.Context, _ pairingProbeMode) bool {
	status := r.readDeepSeekRuntime(ctx, false)
	return status.State == runtimeStateAvailable && status.Reason == "ready"
}

func (r *Router) pairingClaude(ctx context.Context, mode pairingProbeMode) bool {
	if mode == passivePairing && r.claudeBridge.runningSince() == nil {
		return false
	}
	r.refreshClaudeBridgeProbeIfStale()
	probe := r.claudeBridgeProbe()
	env := probe.launchEnv(r.cfg.Claude)
	if !probe.Healthy || probe.cliPath == "" || !r.pairingAdapterHandshake(ctx, mode, r.claudeBridge, probe.Path, r.cfg.Claude.Args, env) {
		return false
	}
	// Supported Claude authentication is reported by the selected CLI in the
	// bridge environment. Quota and the bridge's account/read stub are unrelated.
	raw, err := cliinspect.Stdout(ctx, probe.cliPath, buildClaudeBridgeEnv(env), "auth", "status")
	var account struct {
		LoggedIn bool `json:"loggedIn"`
	}
	return err == nil && json.Unmarshal(raw, &account) == nil && account.LoggedIn
}

func (r *Router) pairingAgy(ctx context.Context, mode pairingProbeMode) bool {
	if mode == passivePairing && r.agyAdapter.runningSince() == nil {
		return false
	}
	probe := r.inspectAgyAdapter(ctx, func(path string, env []string) (agybridge.AgyAuthState, string) {
		return agybridge.CheckAgyAuthStatus(ctx, path, env)
	})
	return probe.Healthy && r.pairingAdapterHandshake(ctx, mode, r.agyAdapter, probe.Path, r.cfg.Agy.Args, probe.launchEnv(r.cfg.Agy))
}

func (r *Router) pairingAdapterHandshake(ctx context.Context, mode pairingProbeMode, supervisor *claudeBridgeSupervisor, path string, args []string, env map[string]string) bool {
	if supervisor == nil || ctx.Err() != nil {
		return false
	}
	if _, err := supervisor.ensureRunning(path, args, env, mode == explicitPairing); err != nil || ctx.Err() != nil {
		return false
	}
	rpc, err := dialResidentAdapterRPC(ctx, supervisor, "pairing")
	if err != nil {
		return false
	}
	defer rpc.close()
	userAgent, err := rpc.initializeClient(ctx, "mimi_remote_pairing", "Mimi Remote Pairing", r.version)
	return err == nil && userAgent != ""
}

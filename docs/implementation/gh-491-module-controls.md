# GH-491: Mac module controls

Refs #491; implementation PR #524. This document describes implementation boundaries, not device-test results.

## Ownership and intent

The menu and Settings use `ModuleControlsGroup` and the same `HostStore`. Codex and Claude have equal entries; DeepSeek has no switch. The former Experiments window is removed. Tailcat relay editing and identity reset live in Settings, with their existing independent confirmations.

The header describes the **Mac service**, not connected mobile devices. Agent details show only that agent's quota windows. Missing/non-finite values are unknown, never an invented 0%. Disabled agents and stale snapshots do not render a quota ring.

`/api/host/modules` requires the normal bearer authentication and a loopback peer. The `agentd status --json` command includes its response as `module_status`. These flags come from the running server, not the command's potentially newer disk configuration. A network or Codex mutation succeeds in the UI only after the reloaded daemon confirms its state. Older daemons can still decode but cannot supply a successful new-style state confirmation.

## Persistent configuration and compatibility

- `codex.enabled` is optional. Absence retains legacy enabled behavior. `codex.activation` records `auto`, `enabled`, or `disabled`. Automatic reconciliation must not override an explicit disabled preference.
- `network.allow_tailscale` is optional. Absence retains the legacy listener behavior. The first explicit connection change records both effective Tailscale and LAN intentions, preserving the unselected connection.
- Codex and network writes use one parsed snapshot, preserve unknown JSON fields and tokens, and commit via the existing private-file byte-CAS transaction. Restore commands compare the fields they changed against the applied state before restoring the original nullable preferences. They refuse to overwrite a newer conflicting choice and preserve unrelated edits.
- Existing Claude and Tailcat control paths remain responsible for their respective configuration and runtime lifecycle. Switching an agent does not delete the other agent's enabled configuration.

## Network boundary

With explicit module controls, `listen` supplies the port. At least one enabled external direct connection uses an IPv4 wildcard socket **wrapped by a connection policy**; the wildcard alone is not the security boundary. Both external switches off binds loopback only. The policy is checked before HTTP or WebSocket handling:

| Socket local and remote addresses | Required intent |
| --- | --- |
| Both loopback | Always allowed; existing local authentication still applies |
| Both Tailscale `100.64.0.0/10` IPv4 | Tailscale enabled |
| Both private RFC1918 IPv4, neither loopback | LAN enabled |
| Mixed Tailscale/LAN, public, unknown, or external IPv6 | Rejected |

This uses actual TCP addresses, not Host or forwarded headers. A Tailscale source cannot use a LAN destination to bypass a disabled Tailscale module. Tailcat retains its separately authenticated sidecar and loopback control paths. No system Tailscale, system interfaces, routes, or firewall rules are changed by the Mac switches. All three connection methods can be enabled simultaneously.

This is an IPv4 application ingress boundary, not a system firewall or protection against malicious same-user local forwarding. Availability means a local usable interface address is present, **not** that a phone is online or an end-to-end path has passed a test. Reconnecting/changing interfaces should be followed by a status refresh; explicit controls no longer depend on the old saved Tailscale bind address.

## Pairing and changes in behavior

Pair generation is read-only: neither refresh nor startup fallback enables LAN or reloads the service. Only enabled, locally available routes are offered. All agents off or all usable connections off produces an actionable empty state, not a loopback QR pretending to work remotely. Disabling/changing a module invalidates pending QR generations; delayed responses cannot restore the stale QR. No token rotation, installation identity change, or pairing deletion occurs during ordinary switches. Tailcat identity reset and relay changes retain their separate explicit warnings.

Codex disabled skips CLI repair, transport migration/start, provider/usage probing, and Codex WebSocket access. Claude remains independently advertised. Codex-backed transcription and debug Codex history are also unavailable while it is disabled. An all-disabled host may still run its local management service.

The current process architecture reloads agentd for Codex, Claude and direct-network changes. The UI warns **before** changes that all mobile connections may disconnect and in-flight work may be affected. It does not promise uninterrupted tasks. The shared Codex Desktop process is not terminated. Closing Tailcat affects Tailcat connections only. The close action offers an explicit re-enable action; this is not a claim that previously interrupted work can be undone.

## Verification handoff

Automated regressions cover independent socket policy, disabled Codex, persistent intent, exact network/Codex restore, conflicting edits, all-disabled pairing, resident-state decoding and Mac state controls. Their execution results belong in the PR, not inferred from the presence of tests.

Device validation still required: toggle each module individually and after restart; enable Claude with Codex disabled; check all-off empty states; after the documented service reload, confirm the disabled direct ingress remains blocked while the phone can reconnect on another enabled method; verify existing pairing credentials remain valid after re-enable; exercise failed reload/recovery; check Tailcat sidecar/relay behavior, dark/light appearances, keyboard navigation, VoiceOver, and narrow menu/window bounds.

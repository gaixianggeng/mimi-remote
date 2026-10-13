# GH-491: Mac module controls

Refs #491; implementation PR #524. This document describes implementation boundaries, not device-test results.

## Ownership and intent

The menu and Settings use `ModuleControlsGroup` and the same `HostStore`. Codex and Claude have equal entries; DeepSeek has no switch. The former Experiments window is removed. Tailcat relay editing and identity reset live in Settings, with their existing independent confirmations.

The header describes the **Mac service**, not connected mobile devices. Agent details show only that agent's quota windows. Missing/non-finite values are unknown, never an invented 0%. Disabled agents and stale snapshots do not render a quota ring.

`/api/host/modules` requires the normal bearer authentication and a loopback peer. The `agentd status --json` command includes its response as `module_status`. These flags come from the running server, not the command's potentially newer disk configuration. A network or Codex mutation succeeds in the UI only after the reloaded daemon confirms its state. Older daemons can still decode but cannot supply a successful new-style state confirmation.

## Persistent configuration and compatibility

- `codex.enabled` is optional. Absence retains legacy enabled behavior. `codex.activation` records `auto`, `enabled`, or `disabled`. Automatic reconciliation must not override an explicit disabled preference.
- `network.allow_tailscale` is optional. Absence retains the legacy listener behavior. The first explicit connection change records both effective Tailscale and LAN intentions, preserving the unselected connection.
- Without `network.allow_tailscale`, the effective intentions come from the legacy config. Tailscale is on for `allow_lan`, a wildcard `listen`, or a `listen` on a Tailscale address. IPv4 `100.64.0.0/10` and IPv6 `fd7a:115c:a1e0::/48` are treated the same way: neither needs `allow_lan`, and neither turns LAN on. LAN is on for `allow_lan`, a wildcard, or a private IPv4 `listen`. A hand-written Tailscale IPv6 `listen` therefore keeps Tailscale on when the first explicit change moves the config onto module controls, instead of leaving only loopback. Other IPv6 ULAs are still treated as LAN and still require `allow_lan`.
- Codex and network writes use one parsed snapshot, preserve unknown JSON fields and tokens, and commit via the existing private-file byte-CAS transaction. Restore commands compare the fields they changed against the applied state before restoring the original nullable preferences. They refuse to overwrite a newer conflicting choice and preserve unrelated edits.
- Existing Claude and Tailcat control paths remain responsible for their respective configuration and runtime lifecycle. Switching an agent does not delete the other agent's enabled configuration.

## Network boundary

With explicit module controls, `listen` supplies the port. At least one enabled external direct connection uses separate `tcp4` (`0.0.0.0`) and `tcp6` (`[::]`) wildcard sockets **wrapped by a connection policy**; the wildcard alone is not the security boundary. Both external switches off binds loopback only, plus `::1` when the configuration bound IPv6 loopback. The IPv6 wildcard already accepts `::1`, so it is not bound a second time. IPv4-mapped IPv6 support is not required; when the OS has no IPv6 support, only the added IPv6 wildcard is skipped. Port conflicts and permission errors still fail startup. The policy is checked before HTTP or WebSocket handling:

| Socket local and remote addresses | Required intent |
| --- | --- |
| Both loopback | Always allowed; existing local authentication still applies |
| Both Tailscale `100.64.0.0/10` IPv4 or `fd7a:115c:a1e0::/48` IPv6 | Tailscale enabled |
| Both private RFC1918 IPv4, neither loopback | LAN enabled |
| Mixed Tailscale/LAN, public, unknown, or other IPv6 (ULA, link-local, global) | Rejected |

Disabling one direct connection only changes the policy. It never rewrites `listen` to loopback, so an enabled Tailscale connection remains reachable after LAN is disabled (#529), for wildcard, Tailscale-address and loopback `listen` values alike. Local control and the Tailcat sidecar always connect to `127.0.0.1:<port>`, which every listener set covers. Tailscale IPv6 is accepted because the iOS client tries the MagicDNS name first, and that name may resolve to the Tailscale IPv6 address.

This uses actual TCP addresses, not Host or forwarded headers. A Tailscale source cannot use a LAN destination to bypass a disabled Tailscale module. Tailcat retains its separately authenticated sidecar and loopback control paths. No system Tailscale, system interfaces, routes, or firewall rules are changed by the Mac switches. All three connection methods can be enabled simultaneously.

This is an application ingress boundary for IPv4 and Tailscale IPv6, not a system firewall or protection against malicious same-user local forwarding. Availability means a local usable interface address is present, **not** that a phone is online or an end-to-end path has passed a test. Reconnecting/changing interfaces should be followed by a status refresh; explicit controls no longer depend on the old saved Tailscale bind address.

## Pairing and changes in behavior

Pair generation is read-only: neither refresh nor startup fallback enables LAN or reloads the service. Only enabled, locally available routes are offered. All agents off or all usable connections off produces an actionable empty state, not a loopback QR pretending to work remotely. Disabling/changing a module invalidates pending QR generations; delayed responses cannot restore the stale QR. No token rotation, installation identity change, or pairing deletion occurs during ordinary switches. Tailcat identity reset and relay changes retain their separate explicit warnings.

Codex disabled skips CLI repair, transport migration/start, provider/usage probing, and Codex WebSocket access. Claude remains independently advertised. Codex-backed transcription and debug Codex history are also unavailable while it is disabled. An all-disabled host may still run its local management service.

The current process architecture reloads agentd for Codex, Claude and direct-network changes. The UI warns **before** changes that all mobile connections may disconnect and in-flight work may be affected. It does not promise uninterrupted tasks. The shared Codex Desktop process is not terminated. Closing Tailcat affects Tailcat connections only. The close action offers an explicit re-enable action; this is not a claim that previously interrupted work can be undone.

## Verification handoff

Automated regressions cover independent socket policy, disabled Codex, persistent intent, exact network/Codex restore, conflicting edits, all-disabled pairing, resident-state decoding and Mac state controls. Their execution results belong in the PR, not inferred from the presence of tests.

Device validation still required: toggle each module individually and after restart; enable Claude with Codex disabled; check all-off empty states; after the documented service reload, confirm the disabled direct ingress remains blocked while the phone can reconnect on another enabled method; verify existing pairing credentials remain valid after re-enable; exercise failed reload/recovery; check Tailcat sidecar/relay behavior, dark/light appearances, keyboard navigation, VoiceOver, and narrow menu/window bounds.

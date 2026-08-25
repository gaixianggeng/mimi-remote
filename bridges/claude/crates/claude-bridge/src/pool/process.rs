//! `ClaudeProcessHandle` — spawns one `claude -p ...` subprocess bound to a
//! specific cwd + thread_id and exposes a writer mpsc + broadcast event
//! channel API on top of its line-delimited JSON stdio.
//!
//! Wire model (live probe documented in `claude_protocol.rs`):
//!
//! - bridge → claude: one JSON object per stdin line, shaped as
//!   [`ClaudeInbound`] (`{type:"user", message:{...}}`).
//! - claude → bridge: one JSON object per stdout line, deserialized to
//!   [`ClaudeOutbound`] and broadcast as a [`ClaudeEvent`].
//!
//! Two background tasks per process, mirroring `pi-bridge/src/pool/process.rs`:
//!
//! - **writer** drains a `mpsc::UnboundedReceiver<String>` and writes each
//!   already-serialized JSON line to claude's stdin, terminating with `\n`.
//! - **reader** reads claude's stdout line-by-line, deserializes each line as
//!   [`ClaudeOutbound`], captures the very first `system/init` payload to a
//!   one-shot init slot (waking [`ClaudeProcessHandle::wait_for_init`]), and
//!   broadcasts every event to all subscribers.
//!
//! The init readiness gate is the bridge's signal that the child is fully up.
//! Without it, an early user message racing with claude's startup would be
//! silently swallowed (claude buffers stdin but only starts the streaming
//! turn loop after init publishes).
//!
//! Both halves shut down cleanly when stdin is closed (claude exits on EOF +
//! a writable input format), or the [`ClaudeProcessHandle`] is dropped
//! (`kill_on_drop(true)` plus the abort cleanup in [`TaskSet::drop`]).

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use alleycat_bridge_core::{
    ChildProcess, ChildStderr, ChildStdin, ChildStdout, ProcessLauncher, ProcessRole, ProcessSpec,
    StdioMode,
};
use anyhow::{Context, Result, anyhow};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, Notify, broadcast, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use uuid::Uuid;

use super::claude_protocol::{
    ClaudeEvent, ClaudeInbound, ClaudeOutbound, ControlRequestBody, ControlRequestEnvelope,
    ControlResponseBody, SystemEvent, SystemInit,
};

/// How many events to buffer before slow subscribers start losing events
/// (broadcast::Receiver returns `Lagged(n)` past this watermark). Claude can
/// emit content_block_delta lines at sub-millisecond cadence during streaming
/// (text + thinking interleaved), so this needs headroom.
const EVENT_CHANNEL_CAPACITY: usize = 1024;

/// Default timeout the bridge gives claude to publish its first
/// `system/init` line. Cold start is ~3s in the live probe; warm cache is
/// ~1.3s. 30s leaves headroom for slow disks / first-time MCP server scans
/// without hanging connection setup forever.
pub const DEFAULT_INIT_TIMEOUT: Duration = Duration::from_secs(30);

/// Spawn-time configuration. The bridge mints `thread_id` (the codex thread
/// id, used as claude's `--session-id`) and `cwd`; everything else is
/// optional and overrideable per-thread via `ThreadStartParams` / defaults.
#[derive(Debug, Clone)]
pub struct ClaudeSpawnConfig {
    /// UUIDv7 used as both codex `thread_id` and claude `--session-id`.
    pub thread_id: String,
    /// Bound via `Command::current_dir` AND `--add-dir`. Both are set for
    /// belt-and-suspenders: `current_dir` is what claude actually uses for
    /// relative paths; `--add-dir` keeps the wire log readable.
    pub cwd: PathBuf,
    /// Path of the `claude` binary to spawn. Set from
    /// `CLAUDE_BRIDGE_CLAUDE_BIN` or `which claude`.
    pub claude_bin: PathBuf,
    /// Optional model override (`--model <s>`). Accepts full model ids and the
    /// established `opus` / `sonnet` / `haiku` aliases claude understands directly.
    pub model: Option<String>,
    /// Optional `--effort <level>` applied before the first user envelope.
    pub effort_level: Option<String>,
    /// Optional `--permission-mode <mode>` applied before the first user envelope.
    pub permission_mode: Option<String>,
    /// Optional `--append-system-prompt <s>`.
    pub append_system_prompt: Option<String>,
    /// True for `thread/resume`: spawn with `--resume <thread_id>` so claude
    /// rehydrates the on-disk JSONL transcript.
    pub resume: bool,
    /// When true, spawn with `--dangerously-skip-permissions` (matches the
    /// user's local `claude` shell alias; every tool call auto-approves).
    /// When false, spawn with `--permission-prompt-tool stdio` so claude
    /// asks the bridge for tool permission via inbound
    /// `control_request{subtype:"can_use_tool"}` and the bridge in turn
    /// surfaces a codex `item/{...}/requestApproval` to the connected client.
    /// Default flipped in [`super::PoolPolicy`] / `host.toml`.
    pub bypass_permissions: bool,
}

#[derive(Debug, Error)]
pub enum ClaudeProcessError {
    #[error("claude process exited before publishing system/init")]
    InitTimeout,

    #[error("failed to write user envelope to claude stdin: {0}")]
    WriterClosed(String),

    #[error("control request `{request_id}` timed out after {elapsed:?}")]
    ControlTimeout {
        request_id: String,
        elapsed: Duration,
    },

    #[error(
        "control request `{request_id}` was cancelled (process exited or response routed elsewhere)"
    )]
    ControlCancelled { request_id: String },

    #[error("control request `{request_id}` failed: {message}")]
    ControlError { request_id: String, message: String },

    #[error("runtime override `{field}`={value:?} failed: {source}")]
    RuntimeOverride {
        field: &'static str,
        value: String,
        #[source]
        source: Box<ClaudeProcessError>,
    },

    #[error(transparent)]
    Json(#[from] serde_json::Error),

    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl ClaudeProcessError {
    /// Transport failures leave the child lifecycle or runtime state
    /// uncertain. A turn that has not sent its user envelope yet may safely
    /// replace the process and retry these failures once.
    pub(crate) fn is_process_transport_failure(&self) -> bool {
        match self {
            Self::WriterClosed(_)
            | Self::ControlTimeout { .. }
            | Self::ControlCancelled { .. }
            | Self::Io(_) => true,
            Self::RuntimeOverride { source, .. } => source.is_process_transport_failure(),
            Self::InitTimeout | Self::ControlError { .. } | Self::Json(_) => false,
        }
    }

    pub(crate) fn failure_kind(&self) -> &'static str {
        match self {
            Self::InitTimeout => "init_timeout",
            Self::WriterClosed(_) => "writer_closed",
            Self::ControlTimeout { .. } => "control_timeout",
            Self::ControlCancelled { .. } => "control_cancelled",
            Self::ControlError { .. } => "control_error",
            Self::RuntimeOverride { source, .. } => source.failure_kind(),
            Self::Json(_) => "json",
            Self::Io(_) => "io",
        }
    }

    pub(crate) fn runtime_field(&self) -> Option<&'static str> {
        match self {
            Self::RuntimeOverride { field, .. } => Some(*field),
            _ => None,
        }
    }
}

// Claude Code versions have used both `subtype:"error"` and a nominally
// successful control response carrying `{accepted:false}` for rejected
// setters. Normalize the latter so callers never treat a refused model as
// applied and cache it as live runtime state.
fn rejected_control_response(response: Option<&serde_json::Value>) -> Option<String> {
    let value = response?;
    if value.get("accepted").and_then(serde_json::Value::as_bool) != Some(false) {
        return None;
    }
    for key in ["error", "message", "reason"] {
        if let Some(message) = value
            .get(key)
            .and_then(serde_json::Value::as_str)
            .filter(|message| !message.trim().is_empty())
        {
            return Some(message.to_string());
        }
    }
    Some("Claude runtime did not accept the control request".to_string())
}

/// Handle to a single live `claude -p` subprocess. Cloning via `Arc` shares
/// the writer mpsc + broadcast event sender + init slot, so multiple bridge
/// callers (one per active turn or utility query) can drive the same claude
/// session through separate `Arc<ClaudeProcessHandle>`s.
#[derive(Debug)]
pub struct ClaudeProcessHandle {
    cwd: PathBuf,
    claude_bin: PathBuf,
    thread_id: String,
    /// Stable identity for this process instance. A thread can own several
    /// generations over its lifetime after crash recovery.
    generation: String,
    pid: Option<u32>,
    /// Sender end of the writer mpsc — closing this is the signal to the
    /// writer task to drop claude's stdin (which makes claude exit cleanly).
    writer_tx: mpsc::UnboundedSender<String>,
    /// Broadcast end for events. Cloned via `subscribe_events()`.
    events_tx: broadcast::Sender<ClaudeEvent>,
    /// 独立于 broadcast sender 的进程退出信号。handle 本身会持有
    /// `events_tx`，因此仅等待 broadcast::Closed 无法识别子进程异常退出。
    exit_tx: watch::Sender<bool>,
    /// Init readiness slot. Set by the reader task when the first
    /// `system/init` line lands; `wait_for_init` reads it back.
    init_slot: Arc<InitSlot>,
    /// In-flight `control_request` envelopes awaiting a matching
    /// `control_response`. Keyed by the `request_id` we sent. The reader task
    /// peels each `control_response` out, looks up the entry, and resolves
    /// the oneshot. Cancelled entries (timeout / process exit) are dropped.
    pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<ControlResponseBody>>>>,
    /// Per-handle live runtime config — model / native effort level /
    /// permission mode currently applied to the child process. Mutated only
    /// after a successful control_request, so `apply_runtime_overrides`
    /// can diff and skip no-op writes (avoids burning a request RTT per turn
    /// when nothing changes).
    runtime_state: Arc<Mutex<RuntimeState>>,
    /// Serializes the read → control request → cache write transaction for
    /// per-turn runtime overrides. The active-turn guard is registered later,
    /// so concurrent turn/start calls can otherwise race in this window.
    runtime_override_gate: Arc<Mutex<()>>,
    /// Background tasks. Held so they keep running for the handle's lifetime
    /// and abort cleanly on drop.
    _tasks: Arc<TaskSet>,
}

/// Tokio doesn't have a "watch with no current value" type that fits this
/// pattern cleanly, so we pair a `Notify` with a `Mutex<Option<SystemInit>>`.
/// The reader task `notify_one`s after writing the slot; `wait_for_init`
/// loops on `notified()` until the slot is populated (so a `wait` issued
/// *after* init has already landed still returns immediately).
#[derive(Debug, Default)]
struct InitSlot {
    notify: Notify,
    payload: Mutex<Option<SystemInit>>,
}

/// Mirror of the runtime config currently applied to the child process. Any
/// field set to `Some(_)` here means the bridge has confirmed claude is
/// running with that value (either via spawn args or a successful set_*
/// control_request). `None` means "we never told claude to apply this", which
/// claude takes as its compiled-in default.
#[derive(Debug, Default)]
struct RuntimeState {
    model: Option<String>,
    effort_level: Option<String>,
    effort_level_unsupported: bool,
    permission_mode: Option<String>,
}

struct TaskSet {
    writer: Mutex<Option<JoinHandle<()>>>,
    reader: Mutex<Option<JoinHandle<()>>>,
    stderr: Mutex<Option<JoinHandle<()>>>,
    /// The owning Child handle. Held so the kernel doesn't reap claude
    /// before our reader sees EOF; explicit shutdown goes through
    /// `shutdown()` which kills the child if needed.
    child: Mutex<Option<Box<dyn ChildProcess>>>,
}

impl std::fmt::Debug for TaskSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TaskSet").finish_non_exhaustive()
    }
}

impl Drop for TaskSet {
    fn drop(&mut self) {
        // Best-effort cleanup mirroring pi-bridge/process.rs:106-124.
        if let Some(h) = self.writer.try_lock().ok().and_then(|mut g| g.take()) {
            h.abort();
        }
        if let Some(h) = self.reader.try_lock().ok().and_then(|mut g| g.take()) {
            h.abort();
        }
        if let Some(h) = self.stderr.try_lock().ok().and_then(|mut g| g.take()) {
            h.abort();
        }
        // Drop the child — `LocalLauncher` sets `kill_on_drop(true)`, and
        // alternative launchers are responsible for their own reap-on-drop
        // semantics.
        if let Some(_child) = self.child.try_lock().ok().and_then(|mut g| g.take()) {}
    }
}

impl ClaudeProcessHandle {
    /// Spawn `claude -p ...` per `config` using the default
    /// [`alleycat_bridge_core::LocalLauncher`]. Convenience wrapper over
    /// [`Self::launch_with`] for callers that don't need a custom launcher.
    pub async fn spawn(config: ClaudeSpawnConfig) -> Result<Self> {
        let launcher: Arc<dyn ProcessLauncher> = Arc::new(alleycat_bridge_core::LocalLauncher);
        Self::launch_with(launcher, config).await
    }

    /// Spawn `claude -p ...` per `config` via the supplied [`ProcessLauncher`].
    /// The returned handle is ready to accept `subscribe_events()` /
    /// `send_user_envelope()` calls immediately, but callers MUST `await
    /// wait_for_init(...)` before sending the first user envelope so claude
    /// has finished publishing its `system/init` and is consuming stdin.
    pub async fn launch_with(
        launcher: Arc<dyn ProcessLauncher>,
        config: ClaudeSpawnConfig,
    ) -> Result<Self> {
        let ClaudeSpawnConfig {
            thread_id,
            cwd,
            claude_bin,
            model,
            effort_level,
            permission_mode,
            append_system_prompt,
            resume,
            bypass_permissions,
        } = config;

        let mut args: Vec<OsString> = Vec::new();
        args.push("-p".into());
        args.push("--input-format".into());
        args.push("stream-json".into());
        args.push("--output-format".into());
        args.push("stream-json".into());
        args.push("--include-partial-messages".into());
        args.push("--verbose".into());
        apply_platform_security_args(&mut args);
        if bypass_permissions {
            args.push("--dangerously-skip-permissions".into());
        } else {
            // HITL mode: claude emits inbound control_request{can_use_tool}
            // over stdout for every tool call; the bridge responds via
            // outbound control_response{...{behavior:"allow"|"deny"}}.
            args.push("--permission-prompt-tool".into());
            args.push("stdio".into());
            if let Some(mode) = permission_mode.as_deref() {
                args.push("--permission-mode".into());
                args.push(mode.into());
            }
        }
        args.push("--add-dir".into());
        args.push(cwd.clone().into_os_string());
        // `--session-id` and `--resume` are mutually exclusive on the
        // claude CLI: `--session-id` creates a new session with that id,
        // `--resume` opens the existing one. Passing both together makes
        // claude accept the session but silently swallow stdin from then
        // on (observed in conformance reproductions: every turn/start
        // hits the bridge but never produces an assistant reply).
        if resume {
            args.push("--resume".into());
            args.push(thread_id.clone().into());
        } else {
            args.push("--session-id".into());
            args.push(thread_id.clone().into());
        }
        if let Some(m) = model.as_deref() {
            args.push("--model".into());
            args.push(m.into());
        }
        if let Some(level) = effort_level.as_deref() {
            args.push("--effort".into());
            args.push(level.into());
        }
        if let Some(prompt) = append_system_prompt.as_deref() {
            args.push("--append-system-prompt".into());
            args.push(prompt.into());
        }

        let spec = ProcessSpec {
            role: ProcessRole::Agent,
            program: claude_bin.clone(),
            args,
            cwd: Some(cwd.clone()),
            env: Vec::new(),
            env_clear: false,
            stdin: StdioMode::Piped,
            stdout: StdioMode::Piped,
            stderr: StdioMode::Piped,
        };
        let mut child = launcher.launch(spec).await.with_context(|| {
            format!(
                "spawning {} (cwd={}, cwd_exists={}, claude_bin_exists={})",
                claude_bin.display(),
                cwd.display(),
                cwd.is_dir(),
                claude_bin.exists()
            )
        })?;

        let pid = child.id();
        let stdin = child
            .take_stdin()
            .ok_or_else(|| anyhow!("claude child has no stdin pipe"))?;
        let stdout = child
            .take_stdout()
            .ok_or_else(|| anyhow!("claude child has no stdout pipe"))?;
        let stderr = child
            .take_stderr()
            .ok_or_else(|| anyhow!("claude child has no stderr pipe"))?;

        let generation = Uuid::now_v7().to_string();
        let (writer_tx, writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        let (exit_tx, _exit_rx) = watch::channel(false);
        let init_slot: Arc<InitSlot> = Arc::new(InitSlot::default());
        let pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<ControlResponseBody>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        // Spawn-time flags are already live. Cache them so cold recovery does
        // not repeat the same runtime control that retired the prior process.
        let runtime_state = Arc::new(Mutex::new(RuntimeState {
            model: model.clone(),
            effort_level: effort_level.clone(),
            effort_level_unsupported: false,
            permission_mode: if bypass_permissions {
                None
            } else {
                permission_mode.clone()
            },
        }));

        let writer = tokio::spawn(writer_task(
            stdin,
            writer_rx,
            pending_controls.clone(),
            exit_tx.clone(),
            thread_id.clone(),
            generation.clone(),
            pid,
        ));
        let reader = tokio::spawn(reader_task(
            stdout,
            init_slot.clone(),
            events_tx.clone(),
            pending_controls.clone(),
            exit_tx.clone(),
        ));
        let stderr_handle = tokio::spawn(stderr_task(stderr, pid));

        let tasks = Arc::new(TaskSet {
            writer: Mutex::new(Some(writer)),
            reader: Mutex::new(Some(reader)),
            stderr: Mutex::new(Some(stderr_handle)),
            child: Mutex::new(Some(child)),
        });

        Ok(Self {
            cwd,
            claude_bin,
            thread_id,
            generation,
            pid,
            writer_tx,
            events_tx,
            exit_tx,
            init_slot,
            pending_controls,
            runtime_state,
            runtime_override_gate: Arc::new(Mutex::new(())),
            _tasks: tasks,
        })
    }

    /// Working directory claude was bound to at spawn time.
    pub fn cwd(&self) -> &Path {
        &self.cwd
    }

    /// Path of the claude binary spawned for this handle.
    pub fn claude_bin(&self) -> &Path {
        &self.claude_bin
    }

    /// Codex thread id == claude session id this handle was spawned for.
    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }

    /// Stable identity for this child-process generation.
    pub fn generation(&self) -> &str {
        &self.generation
    }

    /// OS process id (when the spawn surfaced one).
    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    /// Subscribe to the broadcast event channel. New subscribers see only
    /// events emitted *after* they subscribe. Per-turn translator state is
    /// kept on the bridge side, not replayed by the pool.
    pub fn subscribe_events(&self) -> broadcast::Receiver<ClaudeEvent> {
        self.events_tx.subscribe()
    }

    /// Subscribe to the child-process terminal signal. `watch` preserves the
    /// latest value, so a driver created just after an early process exit still
    /// observes it immediately.
    pub fn subscribe_exit(&self) -> watch::Receiver<bool> {
        self.exit_tx.subscribe()
    }

    /// Whether this child generation can no longer serve requests.
    ///
    /// `watch` keeps the terminal value, so callers can reject a dead pooled
    /// handle even when the event driver has not finished its cleanup yet.
    pub fn has_exited(&self) -> bool {
        *self.exit_tx.borrow()
    }

    /// Wait until claude has emitted its `system/init` line, returning a
    /// clone of the captured payload. If init has already landed, returns
    /// immediately.
    ///
    /// Errors with [`ClaudeProcessError::InitTimeout`] if `deadline` elapses
    /// before init lands (in which case the caller should consider the
    /// child unhealthy and tear it down via `shutdown()`).
    pub async fn wait_for_init(
        &self,
        deadline: Duration,
    ) -> Result<SystemInit, ClaudeProcessError> {
        // Fast path: init already captured.
        if let Some(payload) = self.init_slot.payload.lock().await.clone() {
            return Ok(payload);
        }
        // Slow path: register interest, then re-check (avoids a TOCTOU race
        // between the early peek and the actual `notified()` await).
        let wait_loop = async {
            loop {
                let notified = self.init_slot.notify.notified();
                if let Some(payload) = self.init_slot.payload.lock().await.clone() {
                    return Ok::<_, ClaudeProcessError>(payload);
                }
                notified.await;
                if let Some(payload) = self.init_slot.payload.lock().await.clone() {
                    return Ok(payload);
                }
            }
        };
        match timeout(deadline, wait_loop).await {
            Ok(result) => result,
            Err(_) => Err(ClaudeProcessError::InitTimeout),
        }
    }

    /// Send a single line (caller-serialized JSON) to claude's stdin. Used
    /// by `turn::handle_turn_start` / `turn/steer` to push a user envelope.
    /// Lines do not include the trailing newline — the writer task adds it.
    pub fn send_line(&self, line: String) -> Result<(), ClaudeProcessError> {
        if self.has_exited() {
            return Err(ClaudeProcessError::WriterClosed(
                "claude process generation is terminal".to_string(),
            ));
        }
        self.writer_tx
            .send(line)
            .map_err(|e| ClaudeProcessError::WriterClosed(e.to_string()))
    }

    /// Convenience: serialize `value` to a single JSON line and queue it on
    /// the writer.
    pub fn send_serialized<T: serde::Serialize>(
        &self,
        value: &T,
    ) -> Result<(), ClaudeProcessError> {
        let line = serde_json::to_string(value)?;
        self.send_line(line)
    }

    /// Send a typed `control_request` and await the matching
    /// `control_response`. Mints a UUID for the request id, registers a
    /// pending oneshot, writes the envelope, and waits up to `deadline`.
    ///
    /// Returns the success body (with any subtype-specific extras), or one of:
    /// - [`ClaudeProcessError::ControlError`] when claude replies with
    ///   `subtype:"error"`.
    /// - [`ClaudeProcessError::ControlTimeout`] when `deadline` elapses.
    /// - [`ClaudeProcessError::ControlCancelled`] when the process exits or
    ///   the response gets routed to a different waiter.
    /// - [`ClaudeProcessError::WriterClosed`] when stdin is gone before the
    ///   envelope could be written.
    ///
    /// Used by `turn/interrupt`, `thread/rollback`, and the runtime config
    /// setters (`set_model`, `set_permission_mode`, `apply_flag_settings`).
    pub async fn request_control(
        &self,
        request: ControlRequestBody,
        deadline: Duration,
    ) -> Result<ControlResponseBody, ClaudeProcessError> {
        let request_id = Uuid::now_v7().to_string();
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.pending_controls.lock().await;
            // Serialize registration with terminal cleanup. Otherwise a
            // waiter can be inserted just after cleanup and hang until its
            // full deadline on a generation that is already dead.
            if *self.exit_tx.borrow() {
                return Err(ClaudeProcessError::WriterClosed(
                    "claude process generation is terminal".to_string(),
                ));
            }
            pending.insert(request_id.clone(), tx);
        }
        let envelope = ClaudeInbound::ControlRequest(ControlRequestEnvelope {
            request_id: request_id.clone(),
            request,
        });
        if let Err(err) = self.send_serialized(&envelope) {
            // Pull the slot back so we don't leak a sender.
            let mut pending = self.pending_controls.lock().await;
            pending.remove(&request_id);
            drop(pending);
            mark_process_terminal(&self.pending_controls, &self.exit_tx).await;
            return Err(err);
        }
        match timeout(deadline, rx).await {
            Ok(Ok(body)) => match body {
                ControlResponseBody::Success { response } => {
                    if let Some(message) = rejected_control_response(response.as_ref()) {
                        return Err(ClaudeProcessError::ControlError {
                            request_id,
                            message,
                        });
                    }
                    Ok(ControlResponseBody::Success { response })
                }
                ControlResponseBody::Error { error } => Err(ClaudeProcessError::ControlError {
                    request_id,
                    message: error,
                }),
            },
            Ok(Err(_)) => {
                mark_process_terminal(&self.pending_controls, &self.exit_tx).await;
                Err(ClaudeProcessError::ControlCancelled { request_id })
            }
            Err(_) => {
                // A timed-out setter leaves both the child lifecycle and its
                // runtime state uncertain. Retire the whole generation so a
                // late response cannot make later turns reuse poisoned state.
                mark_process_terminal(&self.pending_controls, &self.exit_tx).await;
                Err(ClaudeProcessError::ControlTimeout {
                    request_id,
                    elapsed: deadline,
                })
            }
        }
    }

    /// Apply per-turn runtime overrides via `control_request` setters and
    /// remember what was applied so subsequent calls only dispatch the diff.
    ///
    /// `None` means "leave the current value alone" (do not dispatch);
    /// `Some(_)` means "ensure claude is running with this value" (dispatch
    /// only if it differs from the cached state).
    ///
    /// On setter failure the runtime cache is not updated. Explicit effort
    /// rejection degrades only that turn; only a method-level unsupported
    /// response disables future effort requests for this process. Transport,
    /// timeout, and process-exit failures remain fatal.
    pub async fn apply_runtime_overrides(
        &self,
        model: Option<&str>,
        effort_level: Option<&str>,
        permission_mode: Option<&str>,
        deadline: Duration,
    ) -> Result<(), ClaudeProcessError> {
        let _runtime_override_guard = self.runtime_override_gate.lock().await;
        if let Some(want) = model {
            let need_dispatch = {
                let guard = self.runtime_state.lock().await;
                guard.model.as_deref() != Some(want)
            };
            if need_dispatch {
                self.request_control(
                    ControlRequestBody::SetModel {
                        model: want.to_string(),
                    },
                    deadline,
                )
                .await
                .map_err(|source| ClaudeProcessError::RuntimeOverride {
                    field: "model",
                    value: want.to_string(),
                    source: Box::new(source),
                })?;
                let mut guard = self.runtime_state.lock().await;
                guard.model = Some(want.to_string());
            }
        }
        if let Some(want) = effort_level {
            let need_dispatch = {
                let guard = self.runtime_state.lock().await;
                !guard.effort_level_unsupported && guard.effort_level.as_deref() != Some(want)
            };
            if need_dispatch {
                let result = self
                    .request_control(
                        ControlRequestBody::ApplyFlagSettings {
                            settings: serde_json::json!({"effortLevel": want}),
                        },
                        deadline,
                    )
                    .await;
                match result {
                    Ok(_) => {
                        let mut guard = self.runtime_state.lock().await;
                        guard.effort_level = Some(want.to_string());
                    }
                    Err(source @ ClaudeProcessError::ControlError { .. }) => {
                        let globally_unsupported = effort_control_is_globally_unsupported(&source);
                        tracing::warn!(
                            error = %source,
                            effort_level = want,
                            globally_unsupported,
                            "claude runtime rejected effortLevel; continuing with its default"
                        );
                        if globally_unsupported {
                            let mut guard = self.runtime_state.lock().await;
                            guard.effort_level_unsupported = true;
                        }
                    }
                    Err(source) => {
                        return Err(ClaudeProcessError::RuntimeOverride {
                            field: "effortLevel",
                            value: want.to_string(),
                            source: Box::new(source),
                        });
                    }
                }
            }
        }
        if let Some(want) = permission_mode {
            let need_dispatch = {
                let guard = self.runtime_state.lock().await;
                guard.permission_mode.as_deref() != Some(want)
            };
            if need_dispatch {
                self.request_control(
                    ControlRequestBody::SetPermissionMode {
                        mode: want.to_string(),
                    },
                    deadline,
                )
                .await
                .map_err(|source| ClaudeProcessError::RuntimeOverride {
                    field: "permissionMode",
                    value: want.to_string(),
                    source: Box::new(source),
                })?;
                let mut guard = self.runtime_state.lock().await;
                guard.permission_mode = Some(want.to_string());
            }
        }
        Ok(())
    }

    /// Snapshot the runtime cache. Cheap clone of three small Options. Useful
    /// for diagnostics and tests.
    pub async fn runtime_snapshot(&self) -> (Option<String>, Option<String>, Option<String>) {
        let guard = self.runtime_state.lock().await;
        (
            guard.model.clone(),
            guard.effort_level.clone(),
            guard.permission_mode.clone(),
        )
    }

    /// Close stdin to signal a clean shutdown, then wait for claude to exit
    /// and reap the child. Idempotent.
    pub async fn shutdown(&self) {
        // A generation already marked terminal reached shutdown through a
        // failure path. Keep its eventual exit status visible at the default
        // production log level; routine eviction remains debug-only.
        let was_terminal = self.has_exited();
        // 先通知 driver，保证显式 interrupt/release 即使随后 abort reader，
        // 也会把当前 turn 收敛为 Failed，而不是永久停在 InProgress。
        mark_process_terminal(&self.pending_controls, &self.exit_tx).await;
        // Aborting the writer task drops its `ChildStdin`, which closes
        // claude's stdin pipe and causes a clean exit.
        if let Some(handle) = self._tasks.writer.lock().await.take() {
            handle.abort();
        }
        if let Some(handle) = self._tasks.stderr.lock().await.take() {
            handle.abort();
        }
        if let Some(mut child) = self._tasks.child.lock().await.take() {
            // kill is a no-op if the child has already exited via stdin EOF.
            // We still call it as a safety net for stuck children.
            let kill_error = child.kill().await.err();
            match child.wait().await {
                Ok(status) if was_terminal => tracing::warn!(
                    thread_id = %self.thread_id,
                    generation = %self.generation,
                    pid = ?self.pid,
                    exit_code = ?status.code(),
                    exit_status = %status,
                    ?kill_error,
                    "reaped terminal claude process generation"
                ),
                Ok(status) => tracing::debug!(
                    thread_id = %self.thread_id,
                    generation = %self.generation,
                    pid = ?self.pid,
                    exit_code = ?status.code(),
                    exit_status = %status,
                    ?kill_error,
                    "reaped claude process generation"
                ),
                Err(wait_error) => tracing::warn!(
                    thread_id = %self.thread_id,
                    generation = %self.generation,
                    pid = ?self.pid,
                    ?kill_error,
                    ?wait_error,
                    "failed to reap claude process generation"
                ),
            }
        }
        if let Some(handle) = self._tasks.reader.lock().await.take() {
            handle.abort();
        }
    }
}

fn apply_platform_security_args(args: &mut Vec<OsString>) {
    if cfg!(windows) {
        // Claude Code does not support its Bash sandbox on native Windows.
        // Do not silently run a shell outside the sandbox: disable the shell
        // tool while retaining stdio permission prompts for built-in tools.
        args.push("--disallowedTools".into());
        args.push("Bash".into());
        args.push("PowerShell".into());
        return;
    }
    // Use a temporary override so the bridge never edits project or user
    // settings. If the platform sandbox is unavailable, fail closed.
    args.push("--settings".into());
    args.push(
        serde_json::json!({
            "sandbox": {
                "enabled": true,
                "failIfUnavailable": true,
                "allowUnsandboxedCommands": false,
                "autoAllowBashIfSandboxed": false
            }
        })
        .to_string()
        .into(),
    );
}

fn effort_control_is_globally_unsupported(error: &ClaudeProcessError) -> bool {
    let ClaudeProcessError::ControlError { message, .. } = error else {
        return false;
    };
    let normalized = message.to_ascii_lowercase();
    let names_method =
        normalized.contains("apply_flag_settings") || normalized.contains("apply flag settings");
    names_method
        && [
            "unknown control request",
            "unsupported control request",
            "method not found",
            "not implemented",
        ]
        .iter()
        .any(|marker| normalized.contains(marker))
}

fn redact_url_userinfo(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut copied_through = 0;
    let mut search_from = 0;
    while let Some(relative_scheme_end) = value[search_from..].find("://") {
        let scheme_end = search_from + relative_scheme_end;
        let scheme_start = value[..scheme_end]
            .rfind(|character: char| {
                !character.is_ascii_alphanumeric() && !matches!(character, '+' | '-' | '.')
            })
            .map_or(0, |index| index + 1);
        let scheme = &value[scheme_start..scheme_end];
        let authority_start = scheme_end + 3;
        if scheme.is_empty() || !scheme.as_bytes()[0].is_ascii_alphabetic() {
            search_from = authority_start;
            continue;
        }
        if authority_start >= value.len() {
            break;
        }
        let authority_end = value[authority_start..]
            .find(|character: char| {
                character.is_whitespace() || matches!(character, '/' | '?' | '#')
            })
            .map_or(value.len(), |offset| authority_start + offset);
        let authority = &value[authority_start..authority_end];
        if let Some(userinfo_end) = authority.rfind('@') {
            result.push_str(&value[copied_through..authority_start]);
            result.push_str("<redacted>@");
            result.push_str(&authority[userinfo_end + 1..]);
            copied_through = authority_end;
        }
        search_from = authority_end.max(authority_start + 1).min(value.len());
    }
    result.push_str(&value[copied_through..]);
    result
}

impl alleycat_bridge_core::pool::PoolMember for ClaudeProcessHandle {
    async fn shutdown(&self) {
        ClaudeProcessHandle::shutdown(self).await
    }
}

async fn mark_process_terminal(
    pending_controls: &Arc<Mutex<HashMap<String, oneshot::Sender<ControlResponseBody>>>>,
    exit_tx: &watch::Sender<bool>,
) -> usize {
    // Keep the terminal transition and waiter cleanup in one critical
    // section. request_control checks the watch value while holding this same
    // lock, so it cannot insert a waiter after cleanup.
    let mut pending = pending_controls.lock().await;
    exit_tx.send_replace(true);
    let cancelled = pending.len();
    pending.clear();
    cancelled
}

async fn writer_task(
    mut stdin: ChildStdin,
    mut rx: mpsc::UnboundedReceiver<String>,
    pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<ControlResponseBody>>>>,
    exit_tx: watch::Sender<bool>,
    thread_id: String,
    generation: String,
    pid: Option<u32>,
) {
    let mut terminal_reason = "writer_channel_closed";
    while let Some(mut line) = rx.recv().await {
        line.push('\n');
        if let Err(err) = stdin.write_all(line.as_bytes()).await {
            terminal_reason = "stdin_write_failed";
            tracing::warn!(
                %thread_id,
                %generation,
                ?pid,
                ?err,
                "claude writer task: stdin write failed; retiring generation"
            );
            break;
        }
        if let Err(err) = stdin.flush().await {
            terminal_reason = "stdin_flush_failed";
            tracing::warn!(
                %thread_id,
                %generation,
                ?pid,
                ?err,
                "claude writer task: stdin flush failed; retiring generation"
            );
            break;
        }
    }
    let cancelled_controls = mark_process_terminal(&pending_controls, &exit_tx).await;
    tracing::debug!(
        %thread_id,
        %generation,
        ?pid,
        terminal_reason,
        cancelled_controls,
        "claude writer task entered terminal state"
    );
    // Dropping `stdin` here closes claude's input pipe, prompting it to exit.
}

async fn reader_task(
    stdout: ChildStdout,
    init_slot: Arc<InitSlot>,
    events_tx: broadcast::Sender<ClaudeEvent>,
    pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<ControlResponseBody>>>>,
    exit_tx: watch::Sender<bool>,
) {
    let reader = BufReader::new(stdout);
    let mut lines = reader.lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => {
                tracing::debug!("claude reader task: stdout closed");
                break;
            }
            Err(err) => {
                tracing::warn!(?err, "claude reader task: read error; exiting");
                break;
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<ClaudeOutbound>(trimmed) {
            Ok(payload) => {
                // Capture init the first time we see it. Subsequent inits
                // (claude does not emit them today, but if a future version
                // re-publishes after a model swap we want the latest) replace
                // the slot — translator subscribers see the broadcast either
                // way.
                if let ClaudeOutbound::System(SystemEvent::Init(ref init_payload)) = payload {
                    let mut slot = init_slot.payload.lock().await;
                    *slot = Some((**init_payload).clone());
                    drop(slot);
                    init_slot.notify.notify_waiters();
                }
                // Route control_responses to their pending waiter before
                // broadcasting. `request_id` lives nested inside the outer
                // `response` per the SDK's wire shape. The translator silently
                // drops the broadcast copy (KeepAlive-style), so missing the
                // route doesn't cause a crash — but waiters will time out.
                if let ClaudeOutbound::ControlResponse(ref env) = payload {
                    let request_id = env.response.request_id().to_string();
                    let waiter = {
                        let mut pending = pending_controls.lock().await;
                        pending.remove(&request_id)
                    };
                    if let Some(tx) = waiter {
                        let _ = tx.send(ControlResponseBody::from_inner(env.response.clone()));
                    } else {
                        tracing::debug!(
                            %request_id,
                            "control_response had no matching pending waiter (timed out or stray)"
                        );
                    }
                }
                let event = ClaudeEvent::new(payload);
                // `send` returns Err when there are no subscribers; that's
                // normal early in startup and not a fault.
                let _ = events_tx.send(event);
            }
            Err(err) => {
                let line = redact_url_userinfo(trimmed);
                tracing::warn!(?err, line = %line, "claude reader task: failed to parse line");
            }
        }
    }
    // Process exit drains every waiter so they error with ControlCancelled
    // instead of hanging on the deadline.
    mark_process_terminal(&pending_controls, &exit_tx).await;
}

async fn stderr_task(stderr: ChildStderr, pid: Option<u32>) {
    let reader = BufReader::new(stderr);
    let mut lines = reader.lines();
    while let Ok(Some(line)) = lines.next_line().await {
        // Claude prints diagnostic chatter to stderr; surface it through
        // tracing so debug builds get it without polluting the codex
        // JSON-RPC channel.
        let line = redact_url_userinfo(&line);
        tracing::debug!(?pid, "claude stderr: {line}");
    }
}

#[cfg(any(test, feature = "test-helpers"))]
impl ClaudeProcessHandle {
    /// Build a [`ClaudeProcessHandle`] that is *not* attached to any
    /// subprocess. Used by `pool` unit tests that exercise pool bookkeeping
    /// without needing a real claude child. Sending lines or waiting for
    /// init against a dangling handle will hang or error; tests must not
    /// call `send_line` / `wait_for_init` on a dangling handle.
    pub fn __test_dangling(
        writer_tx: mpsc::UnboundedSender<String>,
        events_tx: broadcast::Sender<ClaudeEvent>,
        cwd: PathBuf,
    ) -> Self {
        Self {
            cwd,
            claude_bin: PathBuf::from("/dev/null"),
            thread_id: "test-thread".into(),
            generation: "test-generation".into(),
            pid: None,
            writer_tx,
            events_tx,
            exit_tx: watch::channel(false).0,
            init_slot: Arc::new(InitSlot::default()),
            pending_controls: Arc::new(Mutex::new(HashMap::new())),
            runtime_state: Arc::new(Mutex::new(RuntimeState::default())),
            runtime_override_gate: Arc::new(Mutex::new(())),
            _tasks: Arc::new(TaskSet {
                writer: Mutex::new(None),
                reader: Mutex::new(None),
                stderr: Mutex::new(None),
                child: Mutex::new(None),
            }),
        }
    }

    /// Test-only handle to the pending-controls table so the request_control
    /// tests below can simulate the reader resolving a waiter.
    #[cfg(test)]
    fn pending_controls_handle(
        &self,
    ) -> Arc<Mutex<HashMap<String, oneshot::Sender<ControlResponseBody>>>> {
        self.pending_controls.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pool::claude_protocol::SystemInit;

    #[test]
    fn platform_security_never_runs_an_unsandboxed_windows_shell() {
        let mut args = Vec::new();
        apply_platform_security_args(&mut args);
        let args: Vec<String> = args
            .into_iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        if cfg!(windows) {
            assert_eq!(args, ["--disallowedTools", "Bash", "PowerShell"]);
        } else {
            assert_eq!(args.first().map(String::as_str), Some("--settings"));
            assert!(
                args.get(1)
                    .is_some_and(|settings| { settings.contains(r#""failIfUnavailable":true"#) })
            );
        }
    }

    #[test]
    fn child_diagnostics_redact_url_userinfo() {
        let diagnostic = redact_url_userinfo(
            "connect http://alice:hunter%402@proxy.example:8080 via socks5://bob:secret@proxy:1080",
        );
        assert_eq!(
            diagnostic,
            "connect http://<redacted>@proxy.example:8080 via socks5://<redacted>@proxy:1080"
        );
        for secret in ["alice", "hunter%402", "bob", "secret"] {
            assert!(!diagnostic.contains(secret));
        }
    }

    #[tokio::test]
    async fn wait_for_init_returns_immediately_when_already_set() {
        let (writer_tx, _writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle =
            ClaudeProcessHandle::__test_dangling(writer_tx, events_tx, PathBuf::from("/tmp"));
        // Pre-populate the init slot.
        let init = SystemInit {
            session_id: "s1".into(),
            cwd: "/tmp".into(),
            model: "haiku".into(),
            tools: vec![],
            mcp_servers: vec![],
            slash_commands: vec![],
            agents: vec![],
            skills: vec![],
            permission_mode: None,
            api_key_source: None,
            claude_code_version: None,
            output_style: None,
            uuid: None,
            extra: Default::default(),
        };
        *handle.init_slot.payload.lock().await = Some(init.clone());
        // Tiny deadline — should return well before it elapses.
        let got = handle
            .wait_for_init(Duration::from_millis(50))
            .await
            .expect("init");
        assert_eq!(got.session_id, "s1");
    }

    #[tokio::test]
    async fn shutdown_notifies_process_exit_subscribers() {
        let (writer_tx, _writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle =
            ClaudeProcessHandle::__test_dangling(writer_tx, events_tx, PathBuf::from("/tmp"));
        let mut exit_rx = handle.subscribe_exit();
        let pending = handle.pending_controls_handle();
        let (waiter_tx, waiter_rx) = oneshot::channel();
        pending.lock().await.insert("pending".into(), waiter_tx);

        handle.shutdown().await;
        exit_rx
            .changed()
            .await
            .expect("exit signal sender remains live");
        assert!(*exit_rx.borrow());
        assert!(pending.lock().await.is_empty());
        assert!(waiter_rx.await.is_err(), "shutdown must cancel waiters");
    }

    #[tokio::test]
    async fn writer_pipe_failure_marks_generation_terminal_and_cancels_waiters() {
        let (stdin, peer) = tokio::io::duplex(64);
        drop(peer);
        let (writer_tx, writer_rx) = mpsc::unbounded_channel::<String>();
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let (waiter_tx, waiter_rx) = oneshot::channel();
        pending.lock().await.insert("pending".into(), waiter_tx);
        let (exit_tx, mut exit_rx) = watch::channel(false);

        let writer = tokio::spawn(writer_task(
            Box::new(stdin),
            writer_rx,
            pending.clone(),
            exit_tx,
            "thread-broken-pipe".into(),
            "generation-1".into(),
            Some(42),
        ));
        writer_tx.send("queued-control".into()).unwrap();

        timeout(Duration::from_secs(1), exit_rx.changed())
            .await
            .expect("writer must signal terminal without waiting for control deadline")
            .expect("exit sender remains live");
        assert!(*exit_rx.borrow());
        assert!(pending.lock().await.is_empty());
        assert!(
            waiter_rx.await.is_err(),
            "writer failure must cancel waiters"
        );
        writer.await.expect("writer task");
    }

    #[tokio::test]
    async fn wait_for_init_times_out_when_never_set() {
        let (writer_tx, _writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle =
            ClaudeProcessHandle::__test_dangling(writer_tx, events_tx, PathBuf::from("/tmp"));
        let result = handle.wait_for_init(Duration::from_millis(50)).await;
        assert!(matches!(result, Err(ClaudeProcessError::InitTimeout)));
    }

    #[tokio::test]
    async fn request_control_resolves_when_reader_routes_success() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();
        let h2 = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            h2.request_control(ControlRequestBody::Interrupt, Duration::from_secs(2))
                .await
        });
        // Drain the queued envelope and extract its request_id.
        let line = writer_rx.recv().await.expect("writer line");
        let parsed: serde_json::Value = serde_json::from_str(&line).expect("json");
        let request_id = parsed["request_id"]
            .as_str()
            .expect("request_id")
            .to_string();
        assert_eq!(parsed["type"], "control_request");
        assert_eq!(parsed["request"]["subtype"], "interrupt");
        // Simulate the reader routing the matching control_response.
        let waiter = {
            let mut p = pending.lock().await;
            p.remove(&request_id).expect("waiter must be registered")
        };
        waiter
            .send(ControlResponseBody::Success { response: None })
            .unwrap();
        let body = task.await.expect("join").expect("ok");
        assert!(matches!(body, ControlResponseBody::Success { .. }));
    }

    #[tokio::test]
    async fn request_control_propagates_error_subtype() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();
        let h2 = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            h2.request_control(
                ControlRequestBody::SetModel {
                    model: "ghost".into(),
                },
                Duration::from_secs(2),
            )
            .await
        });
        let line = writer_rx.recv().await.expect("writer line");
        let parsed: serde_json::Value = serde_json::from_str(&line).expect("json");
        let request_id = parsed["request_id"].as_str().unwrap().to_string();
        let waiter = pending.lock().await.remove(&request_id).unwrap();
        waiter
            .send(ControlResponseBody::Error {
                error: "no such model: ghost".into(),
            })
            .unwrap();
        let err = task.await.expect("join").expect_err("error expected");
        match err {
            ClaudeProcessError::ControlError { message, .. } => {
                assert_eq!(message, "no such model: ghost")
            }
            other => panic!("expected ControlError, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn accepted_false_control_response_is_an_explicit_rejection() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();
        let h2 = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            h2.apply_runtime_overrides(Some("unknown-model"), None, None, Duration::from_secs(2))
                .await
        });
        let line = writer_rx.recv().await.expect("writer line");
        let parsed: serde_json::Value = serde_json::from_str(&line).expect("json");
        let request_id = parsed["request_id"].as_str().unwrap().to_string();
        pending
            .lock()
            .await
            .remove(&request_id)
            .unwrap()
            .send(ControlResponseBody::Success {
                response: Some(serde_json::json!({
                    "accepted": false,
                    "message": "not a recognized model id"
                })),
            })
            .unwrap();

        let err = task.await.expect("join").expect_err("rejection expected");
        match err {
            ClaudeProcessError::RuntimeOverride {
                field,
                value,
                source,
            } => {
                assert_eq!(field, "model");
                assert_eq!(value, "unknown-model");
                assert!(matches!(
                    source.as_ref(),
                    ClaudeProcessError::ControlError { message, .. }
                        if message == "not a recognized model id"
                ));
            }
            other => panic!("expected model RuntimeOverride error, got {other:?}"),
        }
        assert_eq!(handle.runtime_snapshot().await.0, None);
    }

    #[tokio::test]
    async fn request_control_times_out_and_reclaims_slot() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();
        let h2 = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            h2.request_control(ControlRequestBody::Interrupt, Duration::from_millis(60))
                .await
        });
        // Consume the queued line so the channel doesn't back up.
        let _ = writer_rx.recv().await.unwrap();
        let err = task.await.expect("join").expect_err("timeout expected");
        assert!(matches!(err, ClaudeProcessError::ControlTimeout { .. }));
        // A timed-out generation must not accept another control request.
        assert!(handle.has_exited());
        assert!(pending.lock().await.is_empty());
        let retry = handle
            .request_control(ControlRequestBody::Interrupt, Duration::from_secs(1))
            .await
            .expect_err("terminal generation must reject a new request");
        assert!(matches!(retry, ClaudeProcessError::WriterClosed(_)));
        assert!(writer_rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn request_control_errors_when_writer_closed() {
        let (writer_tx, writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        // Drop the receiver so the writer side reports closed on send.
        drop(writer_rx);
        let handle =
            ClaudeProcessHandle::__test_dangling(writer_tx, events_tx, PathBuf::from("/tmp"));
        let err = handle
            .request_control(ControlRequestBody::Interrupt, Duration::from_secs(1))
            .await
            .expect_err("writer closed");
        assert!(matches!(err, ClaudeProcessError::WriterClosed(_)));
    }

    #[tokio::test]
    async fn runtime_override_applies_native_effort_and_skips_duplicate() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();
        let h2 = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            h2.apply_runtime_overrides(None, Some("xhigh"), None, Duration::from_secs(2))
                .await
        });

        let line = writer_rx.recv().await.expect("writer line");
        let parsed: serde_json::Value = serde_json::from_str(&line).expect("json");
        assert_eq!(parsed["request"]["subtype"], "apply_flag_settings");
        assert_eq!(parsed["request"]["settings"]["effortLevel"], "xhigh");

        let request_id = parsed["request_id"].as_str().unwrap().to_string();
        let waiter = pending.lock().await.remove(&request_id).unwrap();
        waiter
            .send(ControlResponseBody::Success { response: None })
            .unwrap();
        task.await.expect("join").expect("override");

        assert_eq!(
            handle.runtime_snapshot().await,
            (None, Some("xhigh".into()), None)
        );
        handle
            .apply_runtime_overrides(None, Some("xhigh"), None, Duration::from_millis(50))
            .await
            .expect("duplicate is a no-op");
        assert!(writer_rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn unsupported_effort_falls_back_and_other_overrides_continue() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();
        let h2 = Arc::clone(&handle);
        let task = tokio::spawn(async move {
            h2.apply_runtime_overrides(
                None,
                Some("medium"),
                Some("default"),
                Duration::from_secs(2),
            )
            .await
        });

        let effort_line = writer_rx.recv().await.expect("effort writer line");
        let effort: serde_json::Value = serde_json::from_str(&effort_line).expect("json");
        let request_id = effort["request_id"].as_str().unwrap().to_string();
        pending
            .lock()
            .await
            .remove(&request_id)
            .unwrap()
            .send(ControlResponseBody::Error {
                error: "unknown control request apply_flag_settings".into(),
            })
            .unwrap();

        let permission_line = writer_rx.recv().await.expect("permission writer line");
        let permission: serde_json::Value = serde_json::from_str(&permission_line).expect("json");
        assert_eq!(permission["request"]["subtype"], "set_permission_mode");
        let request_id = permission["request_id"].as_str().unwrap().to_string();
        pending
            .lock()
            .await
            .remove(&request_id)
            .unwrap()
            .send(ControlResponseBody::Success { response: None })
            .unwrap();

        task.await.expect("join").expect("fallback succeeds");
        assert_eq!(
            handle.runtime_snapshot().await,
            (None, None, Some("default".into()))
        );
        handle
            .apply_runtime_overrides(None, Some("xhigh"), None, Duration::from_millis(50))
            .await
            .expect("unsupported effort remains a no-op");
        assert!(writer_rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn value_specific_effort_rejection_does_not_disable_future_effort() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();

        let first_handle = Arc::clone(&handle);
        let first = tokio::spawn(async move {
            first_handle
                .apply_runtime_overrides(None, Some("max"), None, Duration::from_secs(2))
                .await
        });
        let first_line = writer_rx.recv().await.expect("first effort line");
        let first_request: serde_json::Value = serde_json::from_str(&first_line).expect("json");
        let first_id = first_request["request_id"].as_str().unwrap().to_string();
        pending
            .lock()
            .await
            .remove(&first_id)
            .unwrap()
            .send(ControlResponseBody::Error {
                error: "effort max is not available for the current model".into(),
            })
            .unwrap();
        first
            .await
            .expect("join")
            .expect("value rejection falls back");

        let second_handle = Arc::clone(&handle);
        let second = tokio::spawn(async move {
            second_handle
                .apply_runtime_overrides(None, Some("medium"), None, Duration::from_secs(2))
                .await
        });
        let second_line = writer_rx.recv().await.expect("second effort line");
        let second_request: serde_json::Value = serde_json::from_str(&second_line).expect("json");
        assert_eq!(
            second_request["request"]["settings"]["effortLevel"],
            "medium"
        );
        let second_id = second_request["request_id"].as_str().unwrap().to_string();
        pending
            .lock()
            .await
            .remove(&second_id)
            .unwrap()
            .send(ControlResponseBody::Success { response: None })
            .unwrap();
        second
            .await
            .expect("join")
            .expect("supported effort retries");
        assert_eq!(handle.runtime_snapshot().await.1.as_deref(), Some("medium"));
    }

    #[tokio::test]
    async fn concurrent_runtime_overrides_are_serialized() {
        let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let pending = handle.pending_controls_handle();

        let first_handle = Arc::clone(&handle);
        let first = tokio::spawn(async move {
            first_handle
                .apply_runtime_overrides(None, Some("medium"), None, Duration::from_secs(2))
                .await
        });
        let first_line = writer_rx.recv().await.expect("first effort line");
        let first_request: serde_json::Value = serde_json::from_str(&first_line).expect("json");

        let second_handle = Arc::clone(&handle);
        let second = tokio::spawn(async move {
            second_handle
                .apply_runtime_overrides(None, Some("high"), None, Duration::from_secs(2))
                .await
        });
        tokio::task::yield_now().await;
        assert!(
            writer_rx.try_recv().is_err(),
            "second override must wait until the first cache transaction completes"
        );

        let first_id = first_request["request_id"].as_str().unwrap().to_string();
        pending
            .lock()
            .await
            .remove(&first_id)
            .unwrap()
            .send(ControlResponseBody::Success { response: None })
            .unwrap();
        first.await.expect("first join").expect("first override");

        let second_line = writer_rx.recv().await.expect("second effort line");
        let second_request: serde_json::Value = serde_json::from_str(&second_line).expect("json");
        assert_eq!(second_request["request"]["settings"]["effortLevel"], "high");
        let second_id = second_request["request_id"].as_str().unwrap().to_string();
        pending
            .lock()
            .await
            .remove(&second_id)
            .unwrap()
            .send(ControlResponseBody::Success { response: None })
            .unwrap();
        second.await.expect("second join").expect("second override");
        assert_eq!(handle.runtime_snapshot().await.1.as_deref(), Some("high"));
    }

    #[tokio::test]
    async fn wait_for_init_unblocks_when_slot_populated_after_subscribe() {
        let (writer_tx, _writer_rx) = mpsc::unbounded_channel::<String>();
        let (events_tx, _events_rx) = broadcast::channel(8);
        let handle = Arc::new(ClaudeProcessHandle::__test_dangling(
            writer_tx,
            events_tx,
            PathBuf::from("/tmp"),
        ));
        let h2 = Arc::clone(&handle);
        let waiter = tokio::spawn(async move { h2.wait_for_init(Duration::from_secs(2)).await });
        // Yield, then publish.
        tokio::time::sleep(Duration::from_millis(20)).await;
        let init = SystemInit {
            session_id: "s2".into(),
            cwd: "/tmp".into(),
            model: "sonnet".into(),
            tools: vec![],
            mcp_servers: vec![],
            slash_commands: vec![],
            agents: vec![],
            skills: vec![],
            permission_mode: None,
            api_key_source: None,
            claude_code_version: None,
            output_style: None,
            uuid: None,
            extra: Default::default(),
        };
        *handle.init_slot.payload.lock().await = Some(init);
        handle.init_slot.notify.notify_waiters();
        let got = waiter.await.expect("join").expect("init");
        assert_eq!(got.session_id, "s2");
    }
}

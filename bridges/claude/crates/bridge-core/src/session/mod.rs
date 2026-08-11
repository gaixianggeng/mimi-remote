//! Session layer that decouples bridge state from a single iroh stream.
//!
//! A `Session` is keyed by `(client_node_id, agent)` and outlives any one
//! attached stream. When a client disconnects, the underlying agent process,
//! the writer-bound replay ring, and the pending server-request table all
//! survive — so a reattaching client can resume mid-turn without losing
//! events or in-flight approval prompts.

pub mod registry;
pub mod ring;

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::sync::{Notify, mpsc, oneshot};

use crate::state::{Capabilities, PendingServerRequest, ServerRequestError};

pub use registry::{AttachKind, ResolvedAttach, SessionRegistry, SessionRegistryConfig};
pub use ring::{ReplayError, ReplayRing, Sequenced};

/// Identifier for a coding-agent backend. Stored as a static string slice
/// throughout to keep keying cheap.
pub type AgentId = &'static str;

/// Cryptographic node id for a paired client. Stored as a hex string so the
/// session module is independent of `iroh` types.
pub type NodeId = String;

/// Outstanding server→client request that has been delivered but not yet
/// answered. Distinct from [`PendingServerRequest`]: that one owns the
/// oneshot responder; this one carries the params we replay on reattach so
/// the client can re-render its approval UI.
#[derive(Debug, Clone)]
pub struct OutstandingRequest {
    pub method: String,
    pub params: serde_json::Value,
}

/// What an `attach` call discovered about prior session state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachOutcome {
    /// Session was minted by this attach; ring is empty.
    Fresh,
    /// Session existed and the cursor is within the replay window.
    Resumed,
    /// Session existed but the cursor predates the floor — the client must
    /// reload state from authoritative storage before treating attach as
    /// successful.
    DriftReload,
}

/// Handed back from `Session::install_attachment` to the caller, who is
/// responsible for spawning the drainer task that flushes `backlog` and then
/// `live_rx` to the iroh sink.
pub struct AttachHandle {
    pub outcome: AttachOutcome,
    pub current_seq: u64,
    pub floor_seq: u64,
    /// Frames the client missed while detached, in seq order.
    pub backlog: Vec<Sequenced>,
    /// Synthetic `serverRequest/replay` frame to emit after the backlog, if
    /// there are any outstanding requests at attach time. None only when
    /// nothing is waiting on the user.
    pub replay_redelivery: Option<Value>,
    /// New live channel; producers `enqueue` after this point will push here.
    pub live_rx: mpsc::UnboundedReceiver<Sequenced>,
    /// Which attachment this handle owns. Hand it back to
    /// [`Session::drop_attachment`] so a connection only ever tears down its
    /// own stream.
    pub generation: u64,
}

#[derive(Debug)]
struct Attachment {
    live_tx: mpsc::UnboundedSender<Sequenced>,
    /// Monotonic counter incremented on every fresh `install_attachment`.
    generation: u64,
}

#[derive(Debug)]
struct DetachState {
    /// When the session became unattached. None while attached.
    detached_at: Option<Instant>,
}

pub struct Session {
    pub agent: AgentId,
    pub node_id: NodeId,
    /// Short stable disambiguator used in server-side request ids.
    session_short: String,
    ring: Mutex<ReplayRing>,
    attachment: Mutex<Option<Attachment>>,
    pending: Mutex<HashMap<String, PendingServerRequest>>,
    outstanding: Mutex<HashMap<String, OutstandingRequest>>,
    capabilities: Mutex<Capabilities>,
    request_counter: AtomicU64,
    attachment_generation: AtomicU64,
    detach: Mutex<DetachState>,
    /// Highest `seq` the drainer has *attempted* to write to the wire,
    /// updated via `fetch_max` immediately before each `write_json_line`.
    ///
    /// The drainer is dead by the time we read this on reattach — but the
    /// counter persists on the session. It lets the server auto-resume
    /// from "what the previous drainer last got to" when a reconnecting
    /// client doesn't send an explicit resume cursor.
    ///
    /// "Attempted" rather than "delivered": a write that returned `Ok` may
    /// still have been buffered in the kernel/QUIC layer and lost on a
    /// hard disconnect, while one that returned `Err` may have partially
    /// reached the peer. Both cases collapse to "uncertain"; the auto-
    /// resume policy replays from `last_attempted_seq.saturating_sub(1)`,
    /// so the most recent uncertain frame is re-sent — duplicates over
    /// missing data.
    last_attempted_seq: AtomicU64,
    /// Turns currently executing against this session, held up by
    /// [`Session::begin_turn`] guards.
    ///
    /// The reaper measures idleness as "how long since a client detached",
    /// which says nothing about whether work is still running: a long tool
    /// call can go minutes without emitting a frame. Without this counter a
    /// phone that closes the app mid-task would have its session dropped out
    /// from under a turn that is still going, and the turn would keep filling
    /// a replay ring nobody can reach again.
    active_turns: AtomicUsize,
    /// Connections that have claimed this session but have not installed
    /// their attachment yet.
    ///
    /// Resolving an attach and installing it are necessarily separate — the
    /// ack goes out in between — and in that gap the session still looks
    /// detached and idle. Without a claim the reaper drops it right out from
    /// under the connection that just picked it up: that connection keeps
    /// serving from an Arc no longer in the registry, and the next reconnect
    /// mints a blank session instead of resuming.
    attach_reservations: AtomicUsize,
    /// Set once the session has been abandoned and reclaimed. Producers watch
    /// it so a turn still running against a session nobody can reach any more
    /// stops instead of burning tokens into a ring with no reader.
    cancelled: AtomicBool,
    cancel_signal: Notify,
}

/// Keeps a session marked busy for as long as a turn is running. Drop order
/// does the bookkeeping, so a panicking or cancelled turn still releases it.
#[derive(Debug)]
pub struct TurnGuard {
    session: Arc<Session>,
}

impl Drop for TurnGuard {
    fn drop(&mut self) {
        self.session.active_turns.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Holds a session against the reaper from the moment a connection claims it
/// until that connection is done with it.
#[derive(Debug)]
pub struct AttachReservation {
    session: Arc<Session>,
}

impl Drop for AttachReservation {
    fn drop(&mut self) {
        self.session
            .attach_reservations
            .fetch_sub(1, Ordering::SeqCst);
    }
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("agent", &self.agent)
            .field("node_id", &self.node_id)
            .field("session_short", &self.session_short)
            .finish()
    }
}

impl Session {
    pub fn new(
        agent: AgentId,
        node_id: NodeId,
        ring_max_msgs: usize,
        ring_max_bytes: usize,
    ) -> Self {
        let session_short = format!("{:08x}", short_hash(&node_id, agent));
        Self {
            agent,
            node_id,
            session_short,
            ring: Mutex::new(ReplayRing::new(ring_max_msgs, ring_max_bytes)),
            attachment: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            outstanding: Mutex::new(HashMap::new()),
            capabilities: Mutex::new(Capabilities::default()),
            request_counter: AtomicU64::new(0),
            attachment_generation: AtomicU64::new(0),
            detach: Mutex::new(DetachState { detached_at: None }),
            last_attempted_seq: AtomicU64::new(0),
            active_turns: AtomicUsize::new(0),
            attach_reservations: AtomicUsize::new(0),
            cancelled: AtomicBool::new(false),
            cancel_signal: Notify::new(),
        }
    }

    /// Record that the drainer is about to attempt writing `seq` to the
    /// wire. Idempotent under concurrent calls (uses `fetch_max`). Called
    /// from the drainer in bridge-core / pi-bridge / claude-bridge.
    pub fn note_drainer_attempt(&self, seq: u64) {
        self.last_attempted_seq.fetch_max(seq, Ordering::Relaxed);
    }

    /// Snapshot of the highest seq the drainer has tried to write. Used
    /// by `SessionRegistry::resolve_attach` to compute the server-side
    /// resume cursor when the client didn't supply one.
    pub fn last_attempted_seq(&self) -> u64 {
        self.last_attempted_seq.load(Ordering::Relaxed)
    }

    /// Push a frame into the replay ring and forward to the live drainer if
    /// one is attached. Returns the assigned seq.
    ///
    /// The payload is stamped with `_alleycat_seq: <seq>` as a top-level
    /// field on JSON object payloads so a future cursor-aware client can
    /// read it off the wire. Codex's JSON-RPC envelopes use serde without
    /// `deny_unknown_fields`, so existing litter-side parsers ignore it.
    /// Non-object payloads are passed through unstamped.
    pub fn enqueue(&self, payload: Value) -> u64 {
        self.enqueue_inner(payload)
    }

    /// Enqueue a frame that is only meaningful to one attachment — a response
    /// to a request that arrived on it. Returns `None` without touching the
    /// ring when that attachment has already been replaced.
    ///
    /// Dropping is the whole point: the successor stream numbers its requests
    /// from scratch, so delivering a response minted for the previous one
    /// answers whatever request reused the id.
    pub fn enqueue_for_generation(&self, mut payload: Value, generation: u64) -> Option<u64> {
        // generation 校验、序号分配和 live 投递必须以 attachment 锁作为同一个
        // 临界区。否则连接可能在校验后、ring 写入前被替换，旧响应仍会占用
        // replay 容量，极端情况下还会挤掉真正需要重放的通知。
        //
        // 锁顺序与 install_attachment / publish_server_request 一致：
        // attachment → ring，避免引入反向等待。
        let attachment = self.attachment.lock().unwrap();
        let current = attachment
            .as_ref()
            .filter(|attachment| attachment.generation == generation)?;

        let seq = {
            let mut ring = self.ring.lock().unwrap();
            let next = ring.next_seq_peek();
            stamp_alleycat_seq(&mut payload, next);
            let assigned = ring.push(payload.clone());
            debug_assert_eq!(assigned, next, "ring assigned a different seq than peeked");
            assigned
        };
        let _ = current.live_tx.send(Sequenced {
            seq,
            payload,
            bytes: 0,
        });
        Some(seq)
    }

    fn enqueue_inner(&self, mut payload: Value) -> u64 {
        let seq = {
            let mut ring = self.ring.lock().unwrap();
            let next = ring.next_seq_peek();
            stamp_alleycat_seq(&mut payload, next);
            let assigned = ring.push(payload.clone());
            debug_assert_eq!(assigned, next, "ring assigned a different seq than peeked");
            assigned
        };
        let attachment = self.attachment.lock().unwrap();
        if let Some(attachment) = attachment.as_ref() {
            // Best-effort: if the drainer is gone, the message is still in
            // the ring and a future reattach will replay it.
            let _ = attachment.live_tx.send(Sequenced {
                seq,
                payload,
                bytes: 0,
            });
        }
        seq
    }

    /// Publish a server→client request: make it outstanding and put it on the
    /// wire as one indivisible step.
    ///
    /// Doing these separately leaves a window that a reattach can land in.
    /// Registered-but-not-yet-enqueued, the request is in the replay snapshot
    /// while its frame is not yet in the ring — so the client gets the
    /// synthetic replay, and then `enqueue` hands the *original* request to
    /// the attachment that was just installed. Two copies of one prompt, and
    /// the second arrives by the ordinary request path, which a client that
    /// has not rehydrated may answer on its own.
    ///
    /// The attachment lock is the barrier: `install_attachment` holds it
    /// across its entire snapshot, so the two cannot interleave. Lock order
    /// here is attachment → pending → outstanding → ring; `enqueue` releases
    /// the ring before touching the attachment, so nothing ever holds ring
    /// while waiting for attachment and the orders cannot invert.
    pub fn publish_server_request(
        &self,
        id: String,
        method: String,
        params: Value,
        responder: oneshot::Sender<Result<Value, ServerRequestError>>,
        mut payload: Value,
    ) -> u64 {
        let attachment = self.attachment.lock().unwrap();
        self.pending.lock().unwrap().insert(
            id.clone(),
            PendingServerRequest {
                method: method.clone(),
                responder,
            },
        );
        self.outstanding
            .lock()
            .unwrap()
            .insert(id, OutstandingRequest { method, params });

        let seq = {
            let mut ring = self.ring.lock().unwrap();
            let next = ring.next_seq_peek();
            stamp_alleycat_seq(&mut payload, next);
            ring.push(payload.clone())
        };
        if let Some(attachment) = attachment.as_ref() {
            // Best-effort, exactly as in `enqueue`: with no live drainer the
            // frame still sits in the ring for the next reattach.
            let _ = attachment.live_tx.send(Sequenced {
                seq,
                payload,
                bytes: 0,
            });
        }
        seq
    }

    /// Mint a fresh server-side request id (string form), prefixed for
    /// human-readable logs and namespaced to this session.
    pub fn next_request_id(&self) -> String {
        let n = self.request_counter.fetch_add(1, Ordering::Relaxed) + 1;
        format!("bridge-{}-{}", self.session_short, n)
    }

    pub fn capabilities(&self) -> Capabilities {
        self.capabilities.lock().unwrap().clone()
    }

    pub fn set_capabilities(&self, capabilities: Capabilities) {
        *self.capabilities.lock().unwrap() = capabilities;
    }

    pub fn should_emit(&self, method: &str) -> bool {
        !self
            .capabilities
            .lock()
            .unwrap()
            .opt_out_notification_methods
            .contains(method)
    }

    /// Stash a pending server→client request and the params we'd replay on
    /// reattach. Both tables are kept in lockstep. Bridges convert their
    /// envelope-specific request id type to a string at this boundary.
    pub fn register_pending(
        &self,
        id: String,
        method: String,
        params: Value,
        responder: oneshot::Sender<Result<Value, ServerRequestError>>,
    ) {
        self.pending.lock().unwrap().insert(
            id.clone(),
            PendingServerRequest {
                method: method.clone(),
                responder,
            },
        );
        self.outstanding
            .lock()
            .unwrap()
            .insert(id, OutstandingRequest { method, params });
    }

    /// Resolve a pending request; returns `true` if we had it. Always clears
    /// the matching outstanding entry too.
    pub fn resolve_pending(&self, id: &str, result: Result<Value, ServerRequestError>) -> bool {
        let pending = self.pending.lock().unwrap().remove(id);
        self.outstanding.lock().unwrap().remove(id);
        match pending {
            Some(entry) => {
                let _ = entry.responder.send(result);
                true
            }
            None => false,
        }
    }

    /// Drain pending without notifying outstanding — used when the request
    /// failed to enqueue at all, so there's nothing to replay later.
    pub fn forget_pending(&self, id: &str) {
        self.pending.lock().unwrap().remove(id);
        self.outstanding.lock().unwrap().remove(id);
    }

    pub fn cancel_all_pending(&self) {
        let drained: Vec<_> = self.pending.lock().unwrap().drain().collect();
        self.outstanding.lock().unwrap().clear();
        for (_, entry) in drained {
            let _ = entry
                .responder
                .send(Err(ServerRequestError::ConnectionClosed));
        }
    }

    /// Install a new attachment, replacing any prior one. Returns the
    /// replay backlog (frames the reattaching client missed) plus a fresh
    /// `live_rx` the caller drives to deliver subsequent frames.
    ///
    /// Lock order: attachment → ring → outstanding (all released before
    /// returning). `enqueue` takes ring then attachment, never overlapping,
    /// so deadlock is impossible.
    pub fn install_attachment(&self, last_seen: Option<u64>) -> AttachHandle {
        let mut attachment_slot = self.attachment.lock().unwrap();
        let ring_guard = self.ring.lock().unwrap();
        let current_seq = ring_guard.current_seq();
        let floor_seq = ring_guard.floor_seq();

        let (outcome, backlog) = match last_seen {
            None => (AttachOutcome::Fresh, Vec::new()),
            Some(cursor) => match ring_guard.replay_from(cursor) {
                Ok(frames) => (AttachOutcome::Resumed, frames),
                Err(ReplayError::Drift { .. }) => (AttachOutcome::DriftReload, Vec::new()),
            },
        };
        drop(ring_guard);

        let outstanding = self.outstanding.lock().unwrap();
        // A prompt raised while the client was away sits in two places: the
        // ring, because it was enqueued like any frame, and the outstanding
        // table. Delivering both hands the client the same approval twice —
        // and the first copy arrives as an ordinary server request, which a
        // client that has not yet rehydrated may auto-dismiss, answering it
        // upstream for real. The synthetic replay would then draw a card for
        // a request that is already resolved. So the replay notification is
        // the single restoration path, and the ring copies step aside.
        let backlog: Vec<Sequenced> = backlog
            .into_iter()
            .filter(|frame| !is_unanswered_server_request(&frame.payload, &outstanding))
            // A response belongs to exactly one request on exactly one
            // attachment, and that attachment is gone by definition here. The
            // client that reattaches numbers its requests from scratch, so a
            // replayed response can land on a live request that merely reuses
            // the old id — `model/list` and `thread/list` both answer
            // `{data, nextCursor}`, so the model catalogue silently becomes
            // the recent-thread list. Nothing downstream can tell the two
            // apart, so the frame must not be replayed at all.
            .filter(|frame| !is_client_request_response(&frame.payload))
            .collect();
        // Whatever we could or couldn't replay, a prompt still waiting on the
        // user is state the client has to be told about — it is the whole
        // reason the session is still here. DriftReload is where this matters
        // most: the backlog is empty precisely because a lot happened while
        // they were gone, so the replay notification is the only thing that
        // tells them the turn is parked on a question rather than stuck.
        let replay_redelivery = outstanding_replay_message(&outstanding);
        drop(outstanding);

        let (live_tx, live_rx) = mpsc::unbounded_channel();
        let generation = self.attachment_generation.fetch_add(1, Ordering::Relaxed) + 1;
        // Replacing drops the previous live_tx; the previous drainer's
        // live_rx closes and that task exits.
        *attachment_slot = Some(Attachment {
            live_tx,
            generation,
        });

        // Clear detach bookkeeping while still holding the attachment lock, so
        // "is attached" and "when did it detach" can never disagree. Dropping
        // the slot lock first leaves a window where a concurrent detach writes
        // its timestamp after we cleared it, marking a session detached that
        // someone is attached to — and handing a live session to the reaper.
        self.detach.lock().unwrap().detached_at = None;
        drop(attachment_slot);

        AttachHandle {
            outcome,
            current_seq,
            floor_seq,
            backlog,
            replay_redelivery,
            live_rx,
            generation,
        }
    }

    /// Clear the attachment slot owned by `generation`. Producer enqueues
    /// continue to go into the ring; only the live forwarding stops.
    ///
    /// The generation check is what makes a handover safe. A client that
    /// reconnects before the old connection has noticed it is dead preempts
    /// the slot, and the old reader then finishes and calls this — without
    /// the check it would tear down the *new* client's stream and mark a
    /// session detached that in fact has someone attached, handing it to the
    /// reaper. Returns whether this call actually detached anything.
    pub fn drop_attachment(&self, generation: u64) -> bool {
        let mut slot = self.attachment.lock().unwrap();
        match slot.as_ref() {
            Some(current) if current.generation != generation => return false,
            None => return false,
            _ => {}
        }
        *slot = None;
        // Timestamp under the same lock that cleared the slot — see
        // `install_attachment` for why the two must move together.
        self.detach.lock().unwrap().detached_at = Some(Instant::now());
        drop(slot);
        true
    }

    pub fn is_attached(&self) -> bool {
        self.attachment.lock().unwrap().is_some()
    }

    /// Generation of the most recently installed attachment. Useful for log
    /// correlation; a connection tearing down its own stream should pass the
    /// generation from its own [`AttachHandle`] instead, so it cannot detach
    /// a successor that preempted it.
    pub fn attachment_generation(&self) -> u64 {
        self.attachment_generation.load(Ordering::Relaxed)
    }

    /// True when the session has been detached for at least `grace`. While
    /// attached, always returns false.
    pub fn detached_for(&self, grace: Duration) -> bool {
        match self.detach.lock().unwrap().detached_at {
            Some(at) => at.elapsed() >= grace,
            None => false,
        }
    }

    pub fn has_outstanding_requests(&self) -> bool {
        !self.outstanding.lock().unwrap().is_empty()
    }

    /// Mark a turn as running until the returned guard is dropped. Callers
    /// hold it for the whole turn — from accepting the prompt to emitting the
    /// terminal event — so the session survives a client that goes away in
    /// the middle.
    pub fn begin_turn(self: &Arc<Self>) -> TurnGuard {
        self.active_turns.fetch_add(1, Ordering::SeqCst);
        TurnGuard {
            session: Arc::clone(self),
        }
    }

    pub fn has_active_turns(&self) -> bool {
        self.active_turns.load(Ordering::SeqCst) > 0
    }

    /// Claim the session on behalf of a connection that is about to attach.
    /// Held until that connection is finished, so the reaper cannot drop a
    /// session mid-handover.
    pub fn reserve_attach(self: &Arc<Self>) -> AttachReservation {
        self.attach_reservations.fetch_add(1, Ordering::SeqCst);
        AttachReservation {
            session: Arc::clone(self),
        }
    }

    /// Reclaim an abandoned session: fail everything waiting on the client
    /// and tell any running turn to stop.
    ///
    /// Removing the registry's `Arc` is not enough to free anything — an
    /// approval future holds the session through its own chain of `Arc`s, so
    /// the pending responder, the ring and the agent process all stay alive,
    /// now permanently unreachable. Cancelling is what actually unwinds them:
    /// the awaiting handlers resolve with `ConnectionClosed` and drop their
    /// references, and the turn observing [`Session::cancelled`] winds down
    /// and releases its process.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.cancel_signal.notify_waiters();
        self.cancel_all_pending();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Resolves once the session has been reclaimed. Producers select on it
    /// alongside their own work so an abandoned turn does not run on forever.
    pub async fn cancelled(&self) {
        if self.is_cancelled() {
            return;
        }
        let notified = self.cancel_signal.notified();
        // Re-check after arming: `cancel` may have fired in between, and the
        // notification it sent has no waiter to wake.
        if self.is_cancelled() {
            return;
        }
        notified.await;
    }

    /// Whether a connection is partway through taking this session over.
    /// Even the hard backstop respects it: dropping a session while a client
    /// is attaching would strand that connection on an unregistered Arc.
    pub fn has_pending_attach(&self) -> bool {
        self.attach_reservations.load(Ordering::SeqCst) > 0
    }

    /// Whether the session has work or a claim that must not be thrown away:
    /// a turn in flight, an approval prompt waiting on a human, or a
    /// connection partway through attaching. The first two are states the
    /// user expects to still be there when they reopen the app; the third is
    /// a client that is picking the session up right now.
    pub fn is_busy(&self) -> bool {
        self.has_active_turns()
            || self.has_outstanding_requests()
            || self.attach_reservations.load(Ordering::SeqCst) > 0
    }

    /// Read-only snapshot of `(current_seq, floor_seq)`. Useful for probing
    /// the ring before deciding whether a reattach can succeed.
    pub fn peek_seq(&self) -> (u64, u64) {
        let ring = self.ring.lock().unwrap();
        (ring.current_seq(), ring.floor_seq())
    }

    /// Probe the ring for whether `last_seen` is still within the replay
    /// window. Does not change state. `Ok(())` means a future reattach with
    /// the same cursor would be `Resumed`; `Err(Drift)` means it would be
    /// `DriftReload`.
    pub fn peek_replay(&self, last_seen: u64) -> Result<(), ReplayError> {
        self.ring.lock().unwrap().replay_from(last_seen).map(|_| ())
    }
}

/// Stamp a JSON object payload with `_alleycat_seq: <seq>` as a top-level
/// field. No-op for non-object values (arrays, scalars, null) — those don't
/// need a cursor and stamping would change their shape.
fn stamp_alleycat_seq(payload: &mut Value, seq: u64) {
    if let Some(obj) = payload.as_object_mut() {
        obj.insert("_alleycat_seq".to_string(), Value::from(seq));
    }
}

/// True when `payload` is a server→client request whose id is still unanswered
/// — one the replay notification is about to restore, so the ring's copy of it
/// must not go out as well.
fn is_unanswered_server_request(
    payload: &Value,
    outstanding: &HashMap<String, OutstandingRequest>,
) -> bool {
    if outstanding.is_empty() || payload.get("method").and_then(Value::as_str).is_none() {
        return false;
    }
    // Request ids are keyed by their `Display` form, which is the bare string
    // for string ids and the digits for numeric ones.
    let key = match payload.get("id") {
        Some(Value::String(id)) => id.clone(),
        Some(Value::Number(id)) => id.to_string(),
        _ => return false,
    };
    outstanding.contains_key(&key)
}

/// True when `payload` is a response to a client→server request: it carries an
/// id and a `result`/`error`, and no `method` of its own. Server→client
/// requests also carry an id but always name a `method`, and they stay
/// replayable — the client still has to answer them.
fn is_client_request_response(payload: &Value) -> bool {
    let Some(object) = payload.as_object() else {
        return false;
    };
    if object.contains_key("method") {
        return false;
    }
    if !matches!(object.get("id"), Some(Value::String(_) | Value::Number(_))) {
        return false;
    }
    object.contains_key("result") || object.contains_key("error")
}

fn outstanding_replay_message(outstanding: &HashMap<String, OutstandingRequest>) -> Option<Value> {
    if outstanding.is_empty() {
        return None;
    }
    let entries: Vec<Value> = outstanding
        .iter()
        .map(|(id, entry)| {
            serde_json::json!({
                "id": id,
                "method": entry.method,
                "params": entry.params,
            })
        })
        .collect();
    Some(serde_json::json!({
        "jsonrpc": "2.0",
        "method": "serverRequest/replay",
        "params": { "outstanding": entries },
    }))
}

fn short_hash(node_id: &str, agent: &str) -> u32 {
    // Cheap non-cryptographic mixer — only used to disambiguate request ids
    // in logs. FNV-1a 32-bit.
    let mut hash: u32 = 0x811c9dc5;
    for byte in node_id
        .as_bytes()
        .iter()
        .chain(b":".iter())
        .chain(agent.as_bytes())
    {
        hash ^= *byte as u32;
        hash = hash.wrapping_mul(0x01000193);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notif(method: &str) -> Value {
        serde_json::json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": {},
        })
    }

    #[test]
    fn enqueue_assigns_increasing_seqs() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        assert_eq!(session.enqueue(notif("a")), 1);
        assert_eq!(session.enqueue(notif("b")), 2);
    }

    #[test]
    fn fresh_attach_yields_empty_backlog() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        session.enqueue(notif("a"));
        let handle = session.install_attachment(None);
        assert_eq!(handle.outcome, AttachOutcome::Fresh);
        assert!(handle.backlog.is_empty());
    }

    #[test]
    fn resumed_attach_replays_backlog() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        session.enqueue(notif("a"));
        session.enqueue(notif("b"));
        let handle = session.install_attachment(Some(1));
        assert_eq!(handle.outcome, AttachOutcome::Resumed);
        let seqs: Vec<_> = handle.backlog.iter().map(|f| f.seq).collect();
        assert_eq!(seqs, vec![2]);
    }

    #[tokio::test]
    async fn response_for_a_replaced_attachment_is_dropped_not_handed_to_its_successor() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        let first = session.install_attachment(None);
        let mut second = session.install_attachment(None);

        // The first stream's request finishes after its client was replaced.
        let dropped = session.enqueue_for_generation(
            serde_json::json!({"jsonrpc": "2.0", "id": 3, "result": {"data": []}}),
            first.generation,
        );
        assert_eq!(dropped, None, "陈旧响应不能进环，更不能投给继任连接");
        assert!(
            session
                .enqueue_for_generation(
                    serde_json::json!({"jsonrpc": "2.0", "id": 1, "result": {"data": []}}),
                    second.generation,
                )
                .is_some()
        );

        let delivered = second.live_rx.recv().await.expect("当前连接的响应仍要送达");
        assert_eq!(delivered.seq, 1, "陈旧响应不能消耗 replay 序号");
        assert_eq!(delivered.payload["id"], 1);
    }

    #[test]
    fn resumed_attach_never_replays_client_request_responses() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        session.enqueue(notif("a"));
        // The reattaching client restarts its request ids at 1, so replaying
        // this would answer its next request with a model catalogue.
        session.enqueue(serde_json::json!({
            "jsonrpc": "2.0",
            "id": 3,
            "result": {"data": [{"id": "sonnet"}], "nextCursor": null},
        }));
        session.enqueue(serde_json::json!({
            "jsonrpc": "2.0",
            "id": 4,
            "error": {"code": -32600, "message": "nope"},
        }));
        // Server→client requests carry an id too, but the client still owes
        // them an answer, so they stay in the backlog.
        session.enqueue(serde_json::json!({
            "jsonrpc": "2.0",
            "id": "req-1",
            "method": "applyPatchApproval",
            "params": {},
        }));
        session.enqueue(notif("b"));

        let handle = session.install_attachment(Some(1));
        assert_eq!(handle.outcome, AttachOutcome::Resumed);
        let seqs: Vec<_> = handle.backlog.iter().map(|f| f.seq).collect();
        assert_eq!(seqs, vec![4, 5]);
    }

    #[test]
    fn drift_attach_returns_no_backlog() {
        // Tiny ring, force eviction past cursor.
        let session = Session::new("pi", "node-abc".into(), 1, 1 << 20);
        session.enqueue(notif("a"));
        session.enqueue(notif("b"));
        session.enqueue(notif("c"));
        let handle = session.install_attachment(Some(0));
        assert_eq!(handle.outcome, AttachOutcome::DriftReload);
        assert!(handle.backlog.is_empty());
    }

    #[tokio::test]
    async fn live_enqueue_after_attach_reaches_drainer() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        let mut handle = session.install_attachment(None);
        session.enqueue(notif("a"));
        let received = handle
            .live_rx
            .recv()
            .await
            .expect("live frame should arrive");
        assert_eq!(received.seq, 1);
    }

    #[tokio::test]
    async fn second_attach_preempts_first() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        let mut first = session.install_attachment(None);
        let mut second = session.install_attachment(None);
        session.enqueue(notif("a"));
        // First's live_rx must close (its tx was dropped on replace).
        assert!(first.live_rx.recv().await.is_none());
        // Second receives the frame.
        let frame = second.live_rx.recv().await.expect("second receives");
        assert_eq!(frame.seq, 1);
    }

    #[test]
    fn next_request_id_is_unique_and_prefixed() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        let a = session.next_request_id();
        let b = session.next_request_id();
        assert_ne!(a, b);
        assert!(a.starts_with("bridge-"));
    }

    #[test]
    fn outstanding_replay_emitted_whenever_something_awaits_the_user() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        session.enqueue(notif("first"));
        let (tx, _rx) = oneshot::channel();
        session.register_pending(
            "req-1".into(),
            "command/approve".into(),
            serde_json::json!({"command": "rm -rf /"}),
            tx,
        );
        // However the client arrives, it has to learn that a prompt is
        // parked on it — otherwise the turn just looks stuck.
        let h_fresh = session.install_attachment(None);
        assert!(h_fresh.replay_redelivery.is_some());
        session.enqueue(notif("second"));
        let h_resume = session.install_attachment(Some(1));
        assert!(h_resume.replay_redelivery.is_some());
    }

    #[test]
    fn outstanding_replay_survives_a_drifted_reattach() {
        // Came back after a long absence: the ring rolled over, so there is
        // no backlog to replay. The waiting approval is exactly what the
        // client still needs, and it is all it will get.
        let session = Session::new("pi", "node-abc".into(), 2, 1 << 20);
        let (tx, _rx) = oneshot::channel();
        session.register_pending(
            "req-1".into(),
            "command/approve".into(),
            serde_json::json!({"command": "cargo install"}),
            tx,
        );
        for _ in 0..5 {
            session.enqueue(notif("chatter"));
        }
        let handle = session.install_attachment(Some(0));
        assert!(matches!(handle.outcome, AttachOutcome::DriftReload));
        assert!(handle.backlog.is_empty());
        assert!(handle.replay_redelivery.is_some());
    }

    #[test]
    fn no_replay_redelivery_when_nothing_awaits_the_user() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        session.enqueue(notif("first"));
        session.enqueue(notif("second"));
        let handle = session.install_attachment(Some(1));
        assert!(handle.replay_redelivery.is_none());
    }

    #[test]
    fn cancel_all_pending_clears_outstanding() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        let (tx, rx) = oneshot::channel();
        session.register_pending(
            "req-1".into(),
            "command/approve".into(),
            serde_json::json!({}),
            tx,
        );
        session.cancel_all_pending();
        assert!(!session.has_outstanding_requests());
        // Responder fires with ConnectionClosed.
        match rx.blocking_recv() {
            Ok(Err(ServerRequestError::ConnectionClosed)) => {}
            other => panic!("expected ConnectionClosed, got {other:?}"),
        }
    }

    #[test]
    fn detached_for_tracks_attachment_state() {
        let session = Session::new("pi", "node-abc".into(), 16, 1 << 20);
        assert!(!session.detached_for(Duration::from_millis(0)));
        let _h = session.install_attachment(None);
        assert!(!session.detached_for(Duration::from_millis(0)));
        session.drop_attachment(session.attachment_generation());
        assert!(session.detached_for(Duration::from_millis(0)));
    }
}

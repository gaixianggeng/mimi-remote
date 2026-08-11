use std::collections::HashSet;
use std::net::SocketAddr;
#[cfg(unix)]
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
#[cfg(unix)]
use tokio::net::UnixListener;
use tokio::net::{TcpListener, TcpStream};
use tracing::{debug, warn};

use crate::envelope::{InboundMessage, JsonRpcError, JsonRpcResponse, JsonRpcVersion, error_codes};
use crate::framing::{read_json_line, write_json_line};
use crate::notify::NotificationSender;
use crate::session::{
    AgentId, AttachHandle, AttachKind, ResolvedAttach, Session, SessionRegistry,
    SessionRegistryConfig,
};
use crate::state::Capabilities;

/// Method of the optional transport-level preamble a socket client sends as
/// its very first line to claim a named, daemon-lifetime session and resume
/// from a cursor. Underscore-prefixed like `_alleycat_seq` to keep it clearly
/// out of the bridge's own JSON-RPC surface.
pub const ATTACH_METHOD: &str = "_alleycat/attach";

/// Method of the ack the server writes back before any replayed frame, so the
/// client learns whether it resumed and how far the ring reaches.
pub const ATTACHED_METHOD: &str = "_alleycat/attached";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AttachParams {
    /// Client-chosen key identifying which session to resume. Distinct keys
    /// get distinct sessions; reusing a key is what makes replay possible.
    session_key: String,
    /// Highest seq the client has durably handed to its own consumer. `None`
    /// lets the registry auto-resume from the previous drainer's high-water
    /// mark.
    #[serde(default)]
    last_seen: Option<u64>,
}

/// Per-stream context handed to bridge handlers. Wraps the session so
/// handlers can emit notifications, issue server→client requests, and read
/// negotiated capabilities — all of which now live on the session and
/// survive the iroh stream lifetime.
#[derive(Clone)]
pub struct Conn {
    session: Arc<Session>,
    notifier: NotificationSender,
}

impl Conn {
    pub fn from_session(session: Arc<Session>) -> Self {
        let notifier = NotificationSender::new(Arc::clone(&session));
        Self { session, notifier }
    }

    pub fn session(&self) -> &Arc<Session> {
        &self.session
    }

    pub fn notifier(&self) -> &NotificationSender {
        &self.notifier
    }

    pub fn capabilities(&self) -> Capabilities {
        self.session.capabilities()
    }

    pub fn should_emit(&self, method: &str) -> bool {
        self.session.should_emit(method)
    }

    pub fn set_initialize_capabilities(&self, params: &Value) {
        let client_info = params.get("clientInfo");
        let capabilities = params.get("capabilities");
        let opt_out = capabilities
            .and_then(|value| value.get("optOutNotificationMethods"))
            .and_then(|value| value.as_array())
            .map(|values| {
                values
                    .iter()
                    .filter_map(|value| value.as_str().map(ToOwned::to_owned))
                    .collect::<HashSet<_>>()
            })
            .unwrap_or_default();
        self.session.set_capabilities(Capabilities {
            experimental_api: capabilities
                .and_then(|value| value.get("experimentalApi"))
                .and_then(|value| value.as_bool())
                .unwrap_or(false),
            opt_out_notification_methods: opt_out,
            client_name: client_info
                .and_then(|value| value.get("name"))
                .and_then(|value| value.as_str())
                .map(ToOwned::to_owned),
            client_title: client_info
                .and_then(|value| value.get("title"))
                .and_then(|value| value.as_str())
                .map(ToOwned::to_owned),
            client_version: client_info
                .and_then(|value| value.get("version"))
                .and_then(|value| value.as_str())
                .map(ToOwned::to_owned),
        });
    }
}

#[async_trait]
pub trait Bridge: Send + Sync + 'static {
    async fn initialize(&self, ctx: &Conn, params: Value) -> Result<Value, JsonRpcError>;
    async fn dispatch(
        &self,
        ctx: &Conn,
        method: &str,
        params: Value,
    ) -> Result<Value, JsonRpcError>;

    async fn notification(&self, _ctx: &Conn, _method: &str, _params: Value) {}

    /// Called once during daemon graceful shutdown. Bridges that spawn
    /// long-lived child processes (ACP agents, claude, opencode, …)
    /// should override this to kill their children synchronously rather
    /// than relying on the tokio runtime's Drop chain — Drop may not
    /// run all the way through during process exit, which leaves
    /// orphaned children behind across restarts.
    async fn shutdown(&self) {}
}

#[derive(Debug, Clone)]
#[cfg(unix)]
pub struct ServerOptions {
    pub socket_path: PathBuf,
    pub unlink_stale: bool,
    /// Agent half of the session key. One socket server serves one agent.
    pub agent: AgentId,
    pub registry: SessionRegistryConfig,
}

/// Options for a loopback-only TCP bridge server.
///
/// TCP is used by the Windows service host, where Unix domain sockets are not
/// available. Restricting the listener to a loopback address is intentional:
/// the JSONL transport has no network authentication layer.
#[derive(Debug, Clone)]
pub struct TcpServerOptions {
    pub listen_addr: SocketAddr,
    /// Agent half of the session key. One TCP server serves one agent.
    pub agent: AgentId,
    pub registry: SessionRegistryConfig,
}

/// Bind a TCP listener after enforcing that it cannot be exposed off-host.
pub async fn bind_loopback_tcp(addr: SocketAddr) -> anyhow::Result<TcpListener> {
    anyhow::ensure!(
        addr.ip().is_loopback(),
        "TCP bridge listener must use a loopback address, got {addr}"
    );
    Ok(TcpListener::bind(addr).await?)
}

/// Serve a loopback TCP listener for the lifetime of the process.
///
/// Accepted streams use the same JSONL framing, attach handshake, session
/// registry, replay ring, and request dispatch path as the Unix socket
/// transport.
pub async fn serve_tcp<B>(bridge: Arc<B>, options: TcpServerOptions) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
{
    let listener = bind_loopback_tcp(options.listen_addr).await?;
    serve_tcp_listener(
        bridge,
        listener,
        options.agent,
        SessionRegistry::new(options.registry),
    )
    .await
}

/// Serve an already-bound loopback listener.
///
/// Exposed primarily for service supervisors and integration tests that bind
/// port `0` and need to inspect the selected local port before accepting.
pub async fn serve_tcp_listener<B>(
    bridge: Arc<B>,
    listener: TcpListener,
    agent: AgentId,
    registry: Arc<SessionRegistry>,
) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
{
    let local_addr = listener.local_addr()?;
    anyhow::ensure!(
        local_addr.ip().is_loopback(),
        "TCP bridge listener must use a loopback address, got {local_addr}"
    );
    let _reaper = registry.spawn_reaper();
    loop {
        let (stream, peer_addr) = listener.accept().await?;
        if !peer_addr.ip().is_loopback() {
            warn!(%peer_addr, "rejecting non-loopback TCP bridge client");
            drop(stream);
            continue;
        }
        if let Err(error) = stream.set_nodelay(true) {
            warn!(%peer_addr, %error, "failed to enable TCP_NODELAY");
        }
        spawn_attached_connection(Arc::clone(&bridge), stream, Arc::clone(&registry), agent);
    }
}

fn spawn_attached_connection<B>(
    bridge: Arc<B>,
    stream: TcpStream,
    registry: Arc<SessionRegistry>,
    agent: AgentId,
) where
    B: Bridge + ?Sized,
{
    tokio::spawn(async move {
        if let Err(error) = serve_stream_attached(bridge, stream, &registry, agent).await {
            tracing::debug!("bridge connection ended: {error:#}");
        }
    });
}

/// Serve a Unix socket for the lifetime of the process, with sessions that
/// outlive any one connection.
///
/// This is what makes a resident bridge worth running: the registry, the
/// replay rings and the outstanding server-request tables all live as long as
/// the listener, so a client whose socket drops mid-turn can reconnect, send
/// [`ATTACH_METHOD`] with the same `sessionKey`, and pick the stream back up
/// where it left off. Connections that send no preamble keep the old
/// one-shot behaviour.
#[cfg(unix)]
pub async fn serve_unix<B>(bridge: Arc<B>, options: ServerOptions) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
{
    bind_unix_socket(&options.socket_path, options.unlink_stale)?;
    let listener = UnixListener::bind(&options.socket_path)?;
    let registry = SessionRegistry::new(options.registry.clone());
    // Reaps sessions whose client never came back: cancels their outstanding
    // approval prompts after `pending_grace`, drops them after `idle_ttl`.
    let _reaper = registry.spawn_reaper();
    let agent = options.agent;
    loop {
        let (stream, _) = listener.accept().await?;
        let bridge = Arc::clone(&bridge);
        let registry = Arc::clone(&registry);
        tokio::spawn(async move {
            if let Err(error) = serve_stream_attached(bridge, stream, &registry, agent).await {
                debug!("bridge connection ended: {error:#}");
            }
        });
    }
}

/// Drive a stream that may open with an [`ATTACH_METHOD`] preamble.
///
/// With a preamble the stream is bound to the registry session named by
/// `sessionKey`, an ack is written before anything else, and the session
/// survives the stream. Without one the stream gets an isolated session that
/// never enters the registry — identical to [`serve_stream`], including
/// cancelling pending server-requests on close.
pub async fn serve_stream_attached<B, S>(
    bridge: Arc<B>,
    stream: S,
    registry: &Arc<SessionRegistry>,
    agent: AgentId,
) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (reader, mut writer) = tokio::io::split(stream);
    let mut reader = BufReader::new(reader);

    // The preamble is positional, so we have to read a frame before we know
    // whether it is one. A non-preamble first frame is replayed into the
    // dispatcher rather than dropped.
    let Some(first) = read_json_line::<Value, _>(&mut reader).await? else {
        return Ok(());
    };
    let claims_attach = first.get("method").and_then(Value::as_str) == Some(ATTACH_METHOD);

    if let Some(params) = attach_params(&first) {
        let resolved = registry.resolve_attach(params.session_key.clone(), agent, params.last_seen);
        write_json_line(&mut writer, &attached_ack(&params.session_key, &resolved)).await?;
        // Held for the whole connection: it covers the gap between claiming
        // the session and installing the attachment, and costs nothing after
        // that, since an attached session is never idle anyway.
        let _reservation = resolved.reservation;
        return serve_split_with_session(
            bridge,
            reader,
            writer,
            resolved.session,
            resolved.effective_last_seen,
            None,
        )
        .await;
    }

    if claims_attach {
        warn!(raw = %first, "ignoring malformed attach preamble; serving an isolated session");
    }
    let config = registry.config();
    let session = Arc::new(Session::new(
        agent,
        "anonymous".into(),
        config.ring_max_msgs,
        config.ring_max_bytes,
    ));
    let pending = if claims_attach { None } else { Some(first) };
    let result =
        serve_split_with_session(bridge, reader, writer, Arc::clone(&session), None, pending).await;
    session.cancel_all_pending();
    result
}

fn attach_params(value: &Value) -> Option<AttachParams> {
    if value.get("method").and_then(Value::as_str) != Some(ATTACH_METHOD) {
        return None;
    }
    let params = value.get("params").cloned().unwrap_or(Value::Null);
    let params: AttachParams = serde_json::from_value(params).ok()?;
    if params.session_key.is_empty() {
        return None;
    }
    Some(params)
}

fn attached_ack(session_key: &str, resolved: &ResolvedAttach) -> Value {
    let kind = match resolved.kind {
        AttachKind::Fresh => "fresh",
        AttachKind::Resumed => "resumed",
        AttachKind::DriftReload => "driftReload",
    };
    serde_json::json!({
        "jsonrpc": "2.0",
        "method": ATTACHED_METHOD,
        "params": {
            "sessionKey": session_key,
            "kind": kind,
            "currentSeq": resolved.current_seq,
            "floorSeq": resolved.floor_seq,
        },
    })
}

#[cfg(unix)]
fn bind_unix_socket(path: &Path, unlink_stale: bool) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if unlink_stale {
        match std::fs::remove_file(path) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

/// Legacy entry point: anonymous one-shot session that lives for the duration
/// of the stream. Used by callers that don't yet participate in the session
/// registry (Unix-socket bridge servers, conformance tests). Cancels pending
/// server-requests when the stream closes.
pub async fn serve_stream<B, S>(bridge: Arc<B>, stream: S) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let registry = SessionRegistry::new(SessionRegistryConfig::default());
    let session = registry.get_or_create("anonymous".into(), "anonymous");
    let result = serve_stream_with_session(bridge, stream, Arc::clone(&session), None).await;
    session.cancel_all_pending();
    result
}

/// Drive a `Bridge` over the process's own `stdin`/`stdout`. Used by bridge
/// binaries when they're launched in stdio mode (no `--socket` flag) — every
/// such `main.rs` used to roll its own `tokio::io::split` + reader/writer
/// plumbing; this helper centralizes it.
///
/// Internally this constructs an `AsyncRead + AsyncWrite` duplex from the two
/// halves and delegates to [`serve_stream`].
pub async fn serve_stdio<B>(bridge: Arc<B>) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
{
    let stream = StdioStream::new();
    serve_stream(bridge, stream).await
}

/// Combines `tokio::io::stdin()` and `tokio::io::stdout()` into a single
/// `AsyncRead + AsyncWrite` value so the existing `serve_stream` plumbing can
/// drive them. `stdin()` and `stdout()` are themselves `Unpin`, so this
/// wrapper is too.
struct StdioStream {
    stdin: tokio::io::Stdin,
    stdout: tokio::io::Stdout,
}

impl StdioStream {
    fn new() -> Self {
        Self {
            stdin: tokio::io::stdin(),
            stdout: tokio::io::stdout(),
        }
    }
}

impl AsyncRead for StdioStream {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.stdin).poll_read(cx, buf)
    }
}

impl AsyncWrite for StdioStream {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.stdout).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.stdout).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.stdout).poll_shutdown(cx)
    }
}

/// Drive a stream against a registry-owned session, returning when the
/// reader half closes. The caller is expected to have already validated
/// auth and resolved the resume cursor; on stream close, the caller decides
/// whether to retain the session (for reattach) or drop it.
///
/// `last_seen` is the client's resume cursor. `None` means a fresh attach
/// (no replay).
pub async fn serve_stream_with_session<B, S>(
    bridge: Arc<B>,
    stream: S,
    session: Arc<Session>,
    last_seen: Option<u64>,
) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (reader, writer) = tokio::io::split(stream);
    serve_split_with_session(
        bridge,
        BufReader::new(reader),
        writer,
        session,
        last_seen,
        None,
    )
    .await
}

/// Shared body behind [`serve_stream_with_session`] and
/// [`serve_stream_attached`], taking the halves already split so a caller that
/// had to read a frame during handshake can hand it back via `pending`.
async fn serve_split_with_session<B, R, W>(
    bridge: Arc<B>,
    mut reader: BufReader<R>,
    writer: W,
    session: Arc<Session>,
    last_seen: Option<u64>,
    pending: Option<Value>,
) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let conn = Conn::from_session(Arc::clone(&session));

    let attach = session.install_attachment(last_seen);
    // Only this connection's own attachment may be torn down below. A client
    // that reconnects before we notice this socket is dead has already
    // preempted the slot, and detaching it here would kill the live stream it
    // just set up — and mark a session detached that someone is attached to,
    // which hands a live session to the reaper.
    let generation = attach.generation;
    let writer_task = tokio::spawn(drain_attachment(writer, attach, Arc::clone(&session)));

    if let Some(value) = pending {
        dispatch_inbound(&bridge, &conn, value, generation).await;
    }
    let result = run_reader(bridge, &conn, &mut reader, generation).await;
    session.drop_attachment(generation);
    let _ = writer_task.await;
    result
}

/// Background drainer that flushes the attachment's replay backlog and
/// optional `serverRequest/replay` notification, then live-tails the
/// session's mpsc until it closes (because the attachment was preempted or
/// dropped).
///
/// Updates `session.last_attempted_seq` via `fetch_max` immediately before
/// each `write_json_line` — that's the high-water mark the next reattach
/// uses to auto-resume, even if the client didn't send an explicit cursor.
async fn drain_attachment<W>(mut writer: W, attach: AttachHandle, session: Arc<Session>)
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    let AttachHandle {
        backlog,
        replay_redelivery,
        mut live_rx,
        ..
    } = attach;

    for sequenced in backlog {
        session.note_drainer_attempt(sequenced.seq);
        if write_json_line(&mut writer, &sequenced.payload)
            .await
            .is_err()
        {
            return;
        }
    }
    match replay_redelivery {
        Some(payload) if write_json_line(&mut writer, &payload).await.is_err() => return,
        _ => {}
    }
    while let Some(sequenced) = live_rx.recv().await {
        session.note_drainer_attempt(sequenced.seq);
        if write_json_line(&mut writer, &sequenced.payload)
            .await
            .is_err()
        {
            break;
        }
    }
    let _ = writer.shutdown().await;
}

async fn run_reader<B, R>(
    bridge: Arc<B>,
    conn: &Conn,
    reader: &mut BufReader<R>,
    generation: u64,
) -> anyhow::Result<()>
where
    B: Bridge + ?Sized,
    R: AsyncRead + Unpin + Send,
{
    while let Some(value) = read_json_line::<Value, _>(reader).await? {
        dispatch_inbound(&bridge, conn, value, generation).await;
    }
    Ok(())
}

/// `generation` is the attachment the frame arrived on. A response is only
/// ever written back while that attachment is still the installed one.
async fn dispatch_inbound<B>(bridge: &Arc<B>, conn: &Conn, value: Value, generation: u64)
where
    B: Bridge + ?Sized,
{
    let inbound = match InboundMessage::from_value(value.clone()) {
        Ok(inbound) => inbound,
        Err(error) => {
            warn!(raw = %value, "discarding malformed json-rpc frame: {error}");
            return;
        }
    };
    match inbound {
        InboundMessage::Request(request) => {
            tracing::info!(method = %request.method, id = %request.id, "json-rpc request");
            let bridge = Arc::clone(bridge);
            let conn = conn.clone();
            tokio::spawn(async move {
                let id = request.id;
                let method = request.method;
                let params = request.params.unwrap_or(Value::Null);
                let result = if method == "initialize" {
                    conn.set_initialize_capabilities(&params);
                    bridge.initialize(&conn, params).await
                } else {
                    bridge.dispatch(&conn, &method, params).await
                };
                let response = match result {
                    Ok(result) => JsonRpcResponse {
                        jsonrpc: JsonRpcVersion,
                        id,
                        result: Some(result),
                        error: None,
                    },
                    Err(error) => JsonRpcResponse {
                        jsonrpc: JsonRpcVersion,
                        id,
                        result: None,
                        error: Some(error),
                    },
                };
                // The client that asked is gone once its attachment has been
                // replaced, and the successor numbers its requests from
                // scratch: handing it this response answers whatever request
                // happens to reuse the id. `model/list` and `thread/list` both
                // return `{data, nextCursor}`, so the model catalogue lands in
                // the recent-thread list looking like real sessions (MIM-120).
                // Nothing downstream can tell the frames apart, so a response
                // that outlived its stream is dropped instead.
                if matches!(
                    conn.notifier().send_response(response, generation),
                    Ok(false)
                ) {
                    debug!(method = %method, "dropped response whose client stream was replaced");
                }
            });
        }
        InboundMessage::Notification(notification) => {
            bridge
                .notification(
                    conn,
                    &notification.method,
                    notification.params.unwrap_or(Value::Null),
                )
                .await;
        }
        InboundMessage::Response(response) => {
            conn.notifier().resolve_response(response).await;
        }
    }
}

pub fn json_error_from_anyhow(error: anyhow::Error) -> JsonRpcError {
    JsonRpcError {
        code: error_codes::INTERNAL_ERROR,
        message: format!("{error:#}"),
        data: None,
    }
}

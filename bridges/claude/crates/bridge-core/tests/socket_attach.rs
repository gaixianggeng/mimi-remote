//! Socket attach handshake: a connection that opens with `_alleycat/attach`
//! binds to a registry session that outlives the stream, so a client whose
//! socket drops mid-turn reconnects and replays what it missed.
//!
//! These drive [`serve_stream_attached`] over a duplex pair, which is the same
//! entry point `serve_unix` uses per accepted connection.

use std::sync::Arc;

use alleycat_bridge_core::session::{SessionRegistry, SessionRegistryConfig};
use alleycat_bridge_core::{
    Bridge, Conn, JsonRpcError, JsonRpcRequest, JsonRpcVersion, RequestId,
    framing::{read_json_line, write_json_line},
    serve_stream_attached,
};
use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{BufReader, DuplexStream, ReadHalf, WriteHalf};

/// Emits one notification per `dispatch` so tests can put known frames into
/// the session ring through the real notifier path.
struct EmitBridge;

#[async_trait]
impl Bridge for EmitBridge {
    async fn initialize(&self, _ctx: &Conn, _params: Value) -> Result<Value, JsonRpcError> {
        Ok(json!({"userAgent":"test"}))
    }

    async fn dispatch(
        &self,
        ctx: &Conn,
        method: &str,
        _params: Value,
    ) -> Result<Value, JsonRpcError> {
        ctx.notifier()
            .send_notification("event", json!({"from": method}))
            .unwrap();
        Ok(json!({"ok": true}))
    }
}

type ClientRead = BufReader<ReadHalf<DuplexStream>>;
type ClientWrite = WriteHalf<DuplexStream>;

/// Open a connection to a fresh server task and send the attach preamble.
/// Returns the client halves plus the ack params.
async fn attach(
    registry: &Arc<SessionRegistry>,
    session_key: &str,
    last_seen: Option<u64>,
) -> (ClientRead, ClientWrite, Value) {
    let (client, server) = tokio::io::duplex(1 << 16);
    let registry_for_task = Arc::clone(registry);
    tokio::spawn(async move {
        let _ =
            serve_stream_attached(Arc::new(EmitBridge), server, &registry_for_task, "claude").await;
    });

    let (read, mut write) = tokio::io::split(client);
    let mut read = BufReader::new(read);
    let mut params = json!({"sessionKey": session_key});
    if let Some(cursor) = last_seen {
        params["lastSeen"] = json!(cursor);
    }
    write_json_line(
        &mut write,
        &json!({"jsonrpc":"2.0","method":"_alleycat/attach","params": params}),
    )
    .await
    .unwrap();

    let ack: Value = read_json_line(&mut read).await.unwrap().unwrap();
    assert_eq!(ack["method"], "_alleycat/attached");
    (read, write, ack["params"].clone())
}

async fn request(write: &mut ClientWrite, id: i64, method: &str) {
    write_json_line(
        write,
        &JsonRpcRequest {
            jsonrpc: JsonRpcVersion,
            id: RequestId::Integer(id),
            method: method.to_string(),
            params: Some(json!({})),
        },
    )
    .await
    .unwrap();
}

/// Read frames until one carries `method == "event"`, returning it. Responses
/// and notifications interleave because requests are dispatched on their own
/// task.
async fn next_event(read: &mut ClientRead) -> Value {
    loop {
        let frame: Value = read_json_line(read).await.unwrap().unwrap();
        if frame["method"] == "event" {
            return frame;
        }
    }
}

fn registry() -> Arc<SessionRegistry> {
    SessionRegistry::new(SessionRegistryConfig::default())
}

#[tokio::test]
async fn first_attach_is_fresh_and_stamps_sequence_numbers() {
    let registry = registry();
    let (mut read, mut write, ack) = attach(&registry, "device-A", None).await;

    assert_eq!(ack["kind"], "fresh");
    assert_eq!(ack["sessionKey"], "device-A");
    assert_eq!(ack["currentSeq"], 0);

    request(&mut write, 1, "turn/start").await;
    let event = next_event(&mut read).await;
    assert_eq!(event["params"]["from"], "turn/start");
    assert_eq!(event["_alleycat_seq"], 1);
}

#[tokio::test]
async fn reattach_replays_frames_produced_while_disconnected() {
    let registry = registry();
    let (mut read, mut write, _) = attach(&registry, "device-A", None).await;
    request(&mut write, 1, "first").await;
    let first = next_event(&mut read).await;
    let cursor = first["_alleycat_seq"].as_u64().unwrap();

    // Client vanishes mid-turn.
    drop(read);
    drop(write);

    // The producer keeps running while nothing is attached. Reaching for the
    // session through the registry is what a still-live turn would do.
    let session = registry
        .get("device-A", "claude")
        .expect("session outlives the stream");
    session.enqueue(json!({"jsonrpc":"2.0","method":"event","params":{"from":"while-detached"}}));

    let (mut read, _write, ack) = attach(&registry, "device-A", Some(cursor)).await;
    assert_eq!(ack["kind"], "resumed");

    // Everything after the cursor comes back in order, except responses to the
    // vanished client's own requests: those belong to continuations that died
    // with the old stream, and the reattaching client numbers its requests from
    // scratch, so replaying one answers whatever request happens to reuse that
    // id. Seqs stay strictly increasing but may skip the dropped responses.
    let mut seqs = Vec::new();
    let replayed = loop {
        let frame: Value = read_json_line(&mut read).await.unwrap().unwrap();
        assert!(
            frame["method"].is_string(),
            "a response frame must never be replayed: {frame}"
        );
        seqs.push(frame["_alleycat_seq"].as_u64().unwrap());
        if frame["params"]["from"] == "while-detached" {
            break frame;
        }
    };
    assert_eq!(replayed["method"], "event");
    assert!(
        seqs.first().is_some_and(|first| *first > cursor),
        "replay must start after the cursor: {seqs:?}"
    );
    assert!(
        seqs.windows(2).all(|pair| pair[0] < pair[1]),
        "replay must stay in order: {seqs:?}"
    );
}

#[tokio::test]
async fn distinct_session_keys_do_not_share_a_ring() {
    let registry = registry();
    let (mut read_a, mut write_a, _) = attach(&registry, "device-A", None).await;
    request(&mut write_a, 1, "for-a").await;
    next_event(&mut read_a).await;

    let (_read_b, _write_b, ack_b) = attach(&registry, "device-B", None).await;
    assert_eq!(ack_b["kind"], "fresh");
    assert_eq!(ack_b["currentSeq"], 0, "B must not see A's frames");
}

#[tokio::test]
async fn connection_without_preamble_still_dispatches_its_first_frame() {
    let registry = registry();
    let (client, server) = tokio::io::duplex(1 << 16);
    let registry_for_task = Arc::clone(&registry);
    tokio::spawn(async move {
        let _ =
            serve_stream_attached(Arc::new(EmitBridge), server, &registry_for_task, "claude").await;
    });

    let (read, mut write) = tokio::io::split(client);
    let mut read = BufReader::new(read);
    request(&mut write, 1, "no-preamble").await;

    let event = next_event(&mut read).await;
    assert_eq!(event["params"]["from"], "no-preamble");
    assert!(
        registry.get("anonymous", "claude").is_none(),
        "preamble-less connections stay out of the registry"
    );
}
